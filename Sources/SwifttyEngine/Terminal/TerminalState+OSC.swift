import Foundation

/// Operating system commands: titles, working directory, colours,
/// clipboard, notifications.
extension TerminalState {
  // MARK: OSC

  mutating func oscDispatch(
    _ data: UnsafeBufferPointer<UInt8>,
    terminatedByBell: Bool
  ) {
    graphemes.releaseTail()
    var command = 0
    var i = 0
    while i < data.count, data[i] != 0x3B {
      // No OSC number has more than a few digits; a longer one would overflow.
      guard (0x30 ... 0x39).contains(data[i]), i < 9 else { return }
      command = command * 10 + Int(data[i] - 0x30)
      i += 1
    }
    let rest =
      i < data.count
      ? UnsafeBufferPointer(rebasing: data[(i + 1)...])
      : UnsafeBufferPointer(rebasing: data[data.count...])
    let st = terminatedByBell ? "\u{07}" : "\u{1B}\\"
    switch command {
    case 0, 2: if Self.replace(&titleBytes, with: rest) { titleChanged = true }
    case 4:
      let parts = String(decoding: rest, as: UTF8.self)
        .split(separator: ";", omittingEmptySubsequences: false)
      var k = 0
      while k + 1 < parts.count {
        if let index = Int(parts[k]), (0 ..< 256).contains(index) {
          if parts[k + 1] == "?" {
            reply(
              "\u{1B}]4;\(index);\(Self.formatColor(palette.colors[index]))\(st)"
            )
          } else if let rgb = Self.parseColor(parts[k + 1]) {
            palette.colors[index] = rgb
            damage.setFull()
          }
        }
        k += 2
      }
    case 7:
      if Self.replace(&directoryBytes, with: rest) { directoryChanged = true }
    case 9:
      let text = String(decoding: rest, as: UTF8.self)
      if text.hasPrefix("4;") {
        let parts = text.split(separator: ";", omittingEmptySubsequences: false)
        let state = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let percent =
          parts.count > 2 ? Int(parts[2]).map { min(max($0, 0), 100) } : nil
        events.append(.progress(state: state, percent: percent))
      } else if !text.isEmpty {
        events.append(.notification(title: "", body: text))
      }
    case 777:
      let parts = String(decoding: rest, as: UTF8.self)
        .split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
      if parts.first == "notify" {
        events.append(
          .notification(
            title: parts.count > 1 ? String(parts[1]) : "",
            body: parts.count > 2 ? String(parts[2]) : "",
          )
        )
      }
    case 8: hyperlink(rest)
    case 21: kittyColors(rest, terminator: st)
    case 22: setPointerShape(rest)
    case 133: semanticPrompt(rest)
    case 5522: kittyClipboard(rest, terminator: st)
    case 72: kittyDragAndDrop(rest, terminator: st)
    case 7501: programStatusCommand(rest, terminator: st)
    case 10, 11, 12:
      let spec = String(decoding: rest, as: UTF8.self)
      if spec == "?" {
        let rgb =
          command == 10
          ? palette.foreground
          : command == 11 ? palette.background : palette.cursor
        reply("\u{1B}]\(command);\(Self.formatColor(rgb))\(st)")
      } else if let rgb = Self.parseColor(Substring(spec)) {
        switch command {
        case 10: palette.foreground = rgb
        case 11: palette.background = rgb
        default: palette.cursor = rgb
        }
        damage.setFull()
      }
    case 52:
      let s = String(decoding: rest, as: UTF8.self)
      guard let semi = s.firstIndex(of: ";") else { return }
      let payload = s[s.index(after: semi)...]
      // Clipboard reads ("?") are refused: they would leak data to the app.
      if payload != "?", let decoded = Self.decodeClipboardPayload(payload) {
        events.append(.clipboard(String(decoding: decoded, as: UTF8.self)))
      }
    case 104:
      if rest.isEmpty {
        palette.colors = defaultPalette.colors
      } else {
        for part in String(decoding: rest, as: UTF8.self).split(separator: ";")
        {
          if let index = Int(part), (0 ..< 256).contains(index) {
            palette.colors[index] = defaultPalette.colors[index]
          }
        }
      }
      damage.setFull()
    case 110:
      palette.foreground = defaultPalette.foreground;
      damage.setFull()
    case 111:
      palette.background = defaultPalette.background;
      damage.setFull()
    case 112:
      palette.cursor = defaultPalette.cursor;
      damage.setFull()
    default: break  // 1 (icon title) and others are ignored
    }
  }

  private static func decodeClipboardPayload(_ payload: Substring) -> Data? {
    let remainder = payload.utf8.count % 4
    if let start = payload.firstIndex(of: "=") {
      // Foundation accepts excess padding, even an all-padding value.
      // Explicit padding must finish a complete four-byte quantum.
      let padding = payload[start...]
      guard remainder == 0, padding == "=" || padding == "==" else {
        return nil
      }
      return Data(base64Encoded: String(payload))
    }
    guard remainder != 1 else { return nil }
    // OSC 52 has no error reply; tolerate an otherwise valid unpadded tail.
    let padding =
      remainder == 0 ? "" : String(repeating: "=", count: 4 - remainder)
    return Data(base64Encoded: String(payload) + padding)
  }

  static func formatColor(_ rgb: UInt32) -> String {
    func c(_ v: UInt32) -> String {
      let s = String(v & 0xFF, radix: 16)
      let byte = s.count == 1 ? "0" + s : s
      return byte + byte
    }
    return "rgb:\(c(rgb >> 16))/\(c(rgb >> 8))/\(c(rgb))"
  }

  /// Parses `rgb:R/G/B` or `#RGB`, with 1–4 hex digits per component.
  /// Hash notation supplies the high bits; `rgb:` scales each component.
  static func parseColor(_ spec: Substring) -> UInt32? {
    if spec.hasPrefix("#") {
      let digits = spec.dropFirst()
      let count = digits.count
      guard [3, 6, 9, 12].contains(count), digits.allSatisfy(\.isHexDigit)
      else { return nil }
      let width = count / 3
      var rgb: UInt32 = 0
      var start = digits.startIndex
      for _ in 0 ..< 3 {
        let end = digits.index(start, offsetBy: width)
        guard let value = UInt32(digits[start ..< end], radix: 16) else {
          return nil
        }
        // X11 places the specified bits at the top of a 16-bit channel.
        // The palette stores its most significant byte.
        let byte = (value << (16 - width * 4)) >> 8
        rgb = rgb << 8 | byte
        start = end
      }
      return rgb
    }
    guard spec.hasPrefix("rgb:") else { return nil }
    let parts = spec.dropFirst(4)
      .split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }
    var rgb: UInt32 = 0
    for part in parts {
      guard (1 ... 4).contains(part.count), part.allSatisfy(\.isHexDigit),
        let v = UInt32(part, radix: 16)
      else { return nil }
      let maxValue = (UInt32(1) << (4 * UInt32(part.count))) - 1
      rgb = rgb << 8 | (v * 255 + maxValue / 2) / maxValue
    }
    return rgb
  }

  /// OSC 8 `params;URI`: an empty URI ends the link. As in Ghostty, an
  /// `id=` parameter and the URI identify a link; without one every OSC 8
  /// opens a link of its own.
  private mutating func hyperlink(_ rest: UnsafeBufferPointer<UInt8>) {
    guard let semi = rest.firstIndex(of: 0x3B) else { return }
    let uri = UnsafeBufferPointer(rebasing: rest[(semi + 1)...])
    guard !uri.isEmpty else {
      setLink(0)
      return
    }
    // `key=value` pairs separated by colons; an empty id is no id.
    var explicit: UnsafeBufferPointer<UInt8>?
    var start = 0
    while start < semi {
      let end = rest[start ..< semi].firstIndex(of: 0x3A) ?? semi
      if end - start > 3, rest[start] == 0x69, rest[start + 1] == 0x64,
        rest[start + 2] == 0x3D
      {
        explicit = UnsafeBufferPointer(rebasing: rest[(start + 3) ..< end])
      }
      start = end + 1
    }
    var key: UInt64 = 0
    if let explicit {
      key = HyperlinkTable.explicitKey(explicit, uri)
      if let id = hyperlinks.link(explicit: explicit, uri: uri, key: key) {
        setLink(id)
        return
      }
    }
    // Reuse only an id no cell still carries; otherwise the link goes
    // unlabelled rather than retargeting older cells.
    guard let id = unusedHyperlinkID() else {
      setLink(0)
      return
    }
    hyperlinks.assign(
      id,
      uri: uri,
      explicit: explicit,
      key: key,
      pinned: isAlternateScreen
    )
    setLink(id)
  }

  /// Absolute rows were renumbered (history cleared, reflow): recorded
  /// rows no longer apply, so only a scan can free an id.
  mutating func forgetHyperlinkRows() {
    for i in hyperlinks.lastRow.indices { hyperlinks.lastRow[i] = .max }
    hyperlinks.closed.removeAll(keepingCapacity: true)
    hyperlinks.closedHead = 0
  }

  /// Switches the pen's link.
  private mutating func setLink(_ id: UInt32) {
    penLinkWillChange(to: id)
    cursor.pen.link = id
  }

  /// Bookkeeping for any change of the pen's link (OSC 8, DECRC): the
  /// ending link can only have been written down to the current screen
  /// bottom; the starting one is live again.
  mutating func penLinkWillChange(to id: UInt32) {
    let old = cursor.pen.link
    guard old != id else { return }
    if hyperlinks.isLive(old) {
      let index = Int(old) - 1
      if isAlternateScreen { hyperlinks.pinned[index] = true }
      // A saved cursor still holding the link may write with it again.
      let held = savedPrimary.pen.link == old || savedAlternate.pen.link == old
      if held || hyperlinks.pinned[index] {
        hyperlinks.lastRow[index] = .max
      } else {
        let row = absoluteRow(viewportRow: 0) + viewportOffset + rows - 1
        hyperlinks.lastRow[index] = row
        hyperlinks.closed.append((old, row))
      }
    }
    holdHyperlink(id)
  }

  /// Marks `id` live: no row bound applies.
  mutating func holdHyperlink(_ id: UInt32) {
    guard hyperlinks.isLive(id) else { return }
    hyperlinks.lastRow[Int(id) - 1] = .max
    if isAlternateScreen { hyperlinks.pinned[Int(id) - 1] = true }
  }

  /// The screens are about to switch: the pen's link may be written on
  /// both, so primary rows no longer bound its cells.
  mutating func pinPenLink() {
    let id = cursor.pen.link
    if hyperlinks.isLive(id) { hyperlinks.pinned[Int(id) - 1] = true }
  }

  /// An id that appears in no cell. Cheap paths: a freed id, or a closed
  /// link whose last possible row has left history. Past a threshold of
  /// links in use, a scan of every cell (screens and history) frees the
  /// unused ones; it is rate-limited while it keeps finding nothing.
  private mutating func unusedHyperlinkID() -> UInt32? {
    if let id = hyperlinks.freeIDs.popLast() { return id }
    let saved = (savedPrimary.pen.link, savedAlternate.pen.link)
    if !isAlternateScreen {
      let first = firstAbsoluteRow
      while hyperlinks.closedHead < hyperlinks.closed.count {
        let (id, row) = hyperlinks.closed[hyperlinks.closedHead]
        // Reopened or rebound since: a later entry covers it.
        let stale =
          !hyperlinks.isLive(id) || hyperlinks.lastRow[Int(id) - 1] != row
          || hyperlinks.pinned[Int(id) - 1]
        guard stale || row < first else { break }
        hyperlinks.closedHead += 1
        if stale || id == cursor.pen.link || id == saved.0 || id == saved.1 {
          continue
        }
        compactClosedHyperlinks()
        hyperlinks.release(id)
        return id
      }
      compactClosedHyperlinks()
    }
    if hyperlinks.live >= hyperlinks.scanThreshold
      || hyperlinks.target.count >= Int(CellAttributes.maxLink)
    {
      if hyperlinks.scanCooldown > 0 {
        hyperlinks.scanCooldown -= 1
      } else if let id = scanForUnusedHyperlinks() {
        return id
      }
    }
    guard hyperlinks.target.count < Int(CellAttributes.maxLink) else {
      return nil
    }
    return UInt32(hyperlinks.target.count + 1)
  }

  /// Drops the consumed front of the closed-link queue once it dominates.
  private mutating func compactClosedHyperlinks() {
    let head = hyperlinks.closedHead
    guard head >= 1024, head * 2 >= hyperlinks.closed.count else { return }
    hyperlinks.closed.removeFirst(head)
    hyperlinks.closedHead = 0
  }

  /// Frees every id no cell or cursor carries, and returns one of them.
  private mutating func scanForUnusedHyperlinks() -> UInt32? {
    let count = hyperlinks.target.count
    var used = [Bool](repeating: false, count: count + 1)
    for id in [cursor.pen.link, savedPrimary.pen.link, savedAlternate.pen.link]
    where Int(id) <= count { used[Int(id)] = true }
    func mark(
      _ cells: UnsafeBufferPointer<Cell>,
      _ extent: Int,
      _ used: inout [Bool]
    ) {
      for x in 0 ..< min(extent, cells.count) {
        let id = Int(cells[x].attributes.link)
        if id <= count { used[id] = true }
      }
    }
    for y in 0 ..< rows {
      mark(grid._unsafeCells(row: y), grid.extent(y), &used)
      mark(inactiveGrid._unsafeCells(row: y), inactiveGrid.extent(y), &used)
    }
    // Compressed history is scanned without promotion: an id still
    // referenced by cold cells is never recycled.
    for i in 0 ..< grid.historyCount {
      grid.withHistoryLine(i) { line, _ in mark(line, line.count, &used) }
    }
    for i in 0 ..< inactiveGrid.historyCount {
      inactiveGrid.withHistoryLine(i) { line, _ in mark(line, line.count, &used)
      }
    }
    var id = UInt32(count)
    while id >= 1 {
      if !used[Int(id)], hyperlinks.isLive(id) {
        hyperlinks.release(id)
        hyperlinks.freeIDs.append(id)
      }
      id -= 1
    }
    // Wait for as many links again, so scans stay amortized.
    hyperlinks.scanThreshold = max(
      HyperlinkTable.minimumScanThreshold,
      hyperlinks.live * 2
    )
    guard let free = hyperlinks.freeIDs.popLast() else {
      hyperlinks.scanCooldown = 255
      return nil
    }
    return free
  }

  /// Target of hyperlink `id` (from `CellAttributes.link`).
  public func hyperlink(_ id: UInt32) -> String? {
    guard hyperlinks.isLive(id) else { return nil }
    return String(
      decoding: hyperlinks.targets[Int(hyperlinks.target[Int(id) - 1])],
      as: UTF8.self
    )
  }
}
