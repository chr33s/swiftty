import Foundation

/// Where the shell is in its prompt/command cycle (OSC 133).
public enum SemanticState: Sendable, Equatable {
  case none, prompt, input, output
}

/// How the shell handles clicks in its prompt, from the `cl` and kitty
/// `click_events` options of OSC 133 ; A.
public enum PromptClick: Sendable, Equatable {
  /// Cursor-key sequences the shell accepts for click-to-move (`cl`).
  public enum CursorKeys: Sendable, Equatable {
    case line  // line
    case multiple  // m
    case conservativeVertical  // v
    case smartVertical  // w
  }

  /// No option seen: clicks move the cursor within the command line.
  case none
  case cursorKeys(CursorKeys)
  /// `click_events=1` reports viewport rows, `=2` rows relative to the
  /// prompt; the shell moves its own cursor.
  case events(relative: Bool)
}

/// What a click in the prompt sends the shell.
public enum PromptClickAction: Sendable, Equatable {
  /// Left (negative) or right arrow presses.
  case moves(Int)
  /// A synthetic SGR left-button press for `click_events`.
  case report([UInt8])
}

/// Light or dark appearance, reported to applications (DEC mode 2031).
public enum ColorScheme: Sendable, Equatable { case dark, light }

/// Shell integration (OSC 133 semantic prompts) and the smaller
/// host-facing protocols: title and SGR stacks, color-scheme and in-band
/// size reports, pointer shapes, the kitty color protocol, underline colors.
extension TerminalState {
  // MARK: Semantic prompts

  enum PromptRedraw { case none, all, lastRow }

  /// `OSC 133 ; A|B|C|D [; options]` (FinalTerm, as extended by kitty and
  /// Ghostty). Parsed in place: shells send several per prompt.
  mutating func semanticPrompt(_ rest: UnsafeBufferPointer<UInt8>) {
    guard let kind = rest.first, rest.count == 1 || rest[1] == 0x3B else {
      return
    }
    // Value of `key=` among the `;`-separated options.
    func option(_ key: StaticString) -> UnsafeBufferPointer<UInt8>? {
      let k = UnsafeBufferPointer(
        start: key.utf8Start,
        count: key.utf8CodeUnitCount
      )
      var i = 2
      while i < rest.count {
        var end = i
        while end < rest.count, rest[end] != 0x3B { end += 1 }
        if end - i > k.count, rest[i + k.count] == 0x3D,
          (0 ..< k.count).allSatisfy({ rest[i + $0] == k[$0] })
        {
          return UnsafeBufferPointer(rebasing: rest[(i + k.count + 1) ..< end])
        }
        i = end + 1
      }
      return nil
    }
    switch kind {
    case 0x41:  // A
      let continuation =
        option("k").map { $0.count == 1 && ($0[0] == 0x63 || $0[0] == 0x73) }
        ?? false  // c, s
      // A new command boundary, not a continuation line or a redraw
      // of the prompt already showing.
      if !continuation, semanticState != .prompt, semanticState != .input {
        programStatusPromptStarted()
      }
      if let redraw = option("redraw") {
        if redraw.count == 1, redraw[0] == 0x30 || redraw[0] == 0x31 {
          promptRedraw = redraw[0] == 0x31 ? .all : .none
        } else if redraw.elementsEqual("last".utf8) {
          promptRedraw = .lastRow
        }
      }
      // `click_events` takes precedence over `cl`; `click_events=0` falls
      // back to it. A prompt without either keeps the previous setting.
      if let events = option("click_events"), events.count == 1,
        events[0] == 0x31 || events[0] == 0x32
      {
        promptClick = .events(relative: events[0] == 0x32)
      } else if let cl = option("cl").flatMap(Self.promptCursorKeys) {
        promptClick = .cursorKeys(cl)
      }
      if grid.mark(cursor.y) != .prompt {
        grid.setMark(cursor.y, continuation ? .promptContinuation : .prompt)
      }
      semanticState = .prompt
      hasSemanticPrompts = true
      clearInputLine()
    case 0x42:  // B
      semanticState = .input
      markInputLine()
    case 0x43:  // C
      if onShellCommandFinished != nil { shellCommand = captureShellCommand() }
      semanticState = .output
      clearInputLine()
      // At column zero the output replaces this row's prompt; after
      // a prompt prefix, keep its mark because both share the row.
      if cursor.x == 0 || grid.mark(cursor.y) == .none {
        grid.setMark(cursor.y, .output)
      }
    case 0x44:  // D [; exit status]
      semanticState = .none
      clearInputLine()
      lastExitCode = Self.semanticExitCode(rest)
      commandFinished = true
      onShellCommandFinished?(shellCommand, lastExitCode)
      shellCommand = ""
    default: break
    }
  }

  private func captureShellCommand() -> String {
    guard !isAlternateScreen, let offset = inputOffset,
      let row = primaryInputLineRow()
    else { return "" }
    let start = TerminalPoint(
      row: screenAbsoluteRow(row) + offset / columns,
      column: offset % columns
    )
    var end = TerminalPoint(
      row: screenAbsoluteRow(cursor.y),
      column: cursor.x - 1
    )
    if cursor.pendingWrap { end.column = cursor.x }
    if end.column < 0 {
      end.row -= 1
      end.column = columns - 1
    }
    guard end >= start, end.row - start.row <= 1024 else { return "" }
    return String(text(from: start, to: end).prefix(16_384))
  }

  private static func promptCursorKeys(
    _ value: UnsafeBufferPointer<UInt8>
  ) -> PromptClick.CursorKeys? {
    if value.elementsEqual("line".utf8) { return .line }
    guard value.count == 1 else { return nil }
    return switch value[0] {
    case 0x6D: .multiple  // m
    case 0x76: .conservativeVertical  // v
    case 0x77: .smartVertical  // w
    default: nil
    }
  }

  /// The first option of D is a complete signed 32-bit decimal field.
  private static func semanticExitCode(
    _ rest: UnsafeBufferPointer<UInt8>
  ) -> Int? {
    guard rest.count > 2 else { return nil }
    var i = 2
    let negative = rest[i] == 0x2D
    if negative || rest[i] == 0x2B { i += 1 }
    let digitsStart = i
    let limit = negative ? -Int64(Int32.min) : Int64(Int32.max)
    var value: Int64 = 0
    while i < rest.count, rest[i] != 0x3B {
      guard (0x30 ... 0x39).contains(rest[i]) else { return nil }
      let digit = Int64(rest[i] - 0x30)
      guard value <= (limit - digit) / 10 else { return nil }
      value = value * 10 + digit
      i += 1
    }
    guard i > digitsStart else { return nil }
    return Int(negative ? -value : value)
  }

  /// Flags the first row of the cursor's logical line and records the
  /// cursor's offset in that line: the command line starts there.
  private mutating func markInputLine() {
    clearInputLine()
    let top = cursorLogicalLineStart
    let index = top - firstAbsoluteRow
    if index < grid.historyCount {
      grid.setHistoryInputLine(index, true)
    } else {
      grid.setInputLine(index - grid.historyCount, true)
    }
    inputOffset =
      (screenAbsoluteRow(cursor.y) - top) * columns + cursor.x
      + (cursor.pendingWrap ? 1 : 0)
  }

  private mutating func clearInputLine() {
    // Only `markInputLine` sets the flag, and it sets the offset too.
    guard inputOffset != nil else { return }
    inputOffset = nil
    for y in 0 ..< rows where grid.isInputLine(y) {
      grid.setInputLine(y, false)
      return
    }
    for i in (0 ..< grid.historyCount).reversed()
    where grid.isHistoryInputLine(i) {
      grid.setHistoryInputLine(i, false)
      return
    }
  }

  /// Where the command line being edited starts (OSC 133 ; B), absolute;
  /// nil unless the cursor is still on that logical line.
  public var inputStart: TerminalPoint? {
    guard semanticState == .input, !isAlternateScreen, let offset = inputOffset
    else { return nil }
    // The first row of the cursor's logical line must carry the flag.
    let top = cursorLogicalLineStart
    let index = top - firstAbsoluteRow
    let marked =
      index < grid.historyCount
      ? grid.isHistoryInputLine(index)
      : grid.isInputLine(index - grid.historyCount)
    guard marked else { return nil }
    return TerminalPoint(row: top + offset / columns, column: offset % columns)
  }

  private var cursorLogicalLineStart: Int {
    var top = screenAbsoluteRow(cursor.y)
    while top > firstAbsoluteRow, isWrapped(absoluteRow: top - 1) == true {
      top -= 1
    }
    return top
  }

  /// Track the input boundary as an insertion position, including one
  /// just past a row's right edge that has not wrapped yet. During
  /// reflow, `grid` is primary even when the alternate screen is active.
  func inputReflowMark() -> Cursor? {
    guard semanticState == .input, let offset = inputOffset,
      let top = primaryInputLineRow()
    else { return nil }
    var mark = Cursor()
    mark.x = offset % columns
    mark.y = top + offset / columns
    if mark.x == 0, offset > 0 {
      mark.x = columns - 1
      mark.y -= 1
      mark.pendingWrap = true
    }
    return mark
  }

  /// The rebuilt grid's absolute rows match the reflow output's row
  /// indices, including rows evicted while appending its history.
  mutating func updateInputOffsetAfterReflow(
    row: Int,
    column: Int,
    pending: Bool,
    columns: Int
  ) {
    guard let relativeTop = primaryInputLineRow() else {
      inputOffset = nil
      return
    }
    let top = grid.historyEvicted + grid.historyCount + relativeTop
    guard row >= top else {
      inputOffset = nil
      return
    }
    inputOffset = (row - top) * columns + column + (pending ? 1 : 0)
  }

  /// Finds the primary grid's input-line flag without consulting the
  /// active screen or cursor. History rows have negative screen indices.
  private func primaryInputLineRow() -> Int? {
    for i in 0 ..< grid.historyCount where grid.isHistoryInputLine(i) {
      return i - grid.historyCount
    }
    for y in 0 ..< grid.rows where grid.isInputLine(y) { return y }
    return nil
  }

  /// Absolute row of screen row `y`, whatever the viewport shows.
  /// Out-of-range coordinates saturate at the integer limits.
  public func screenAbsoluteRow(_ y: Int) -> Int {
    guard !isAlternateScreen else { return y }
    let top = grid.historyEvicted + grid.historyCount
    let (row, overflow) = top.addingReportingOverflow(y)
    return overflow ? (y < 0 ? .min : .max) : row
  }

  /// Semantic mark of absolute row `row`, or nil once it has left history.
  public func mark(absoluteRow row: Int) -> RowMark? {
    guard row >= firstAbsoluteRow else { return nil }
    let index = row - firstAbsoluteRow
    guard index >= 0, index < addressableRows else { return nil }
    let history = isAlternateScreen ? 0 : grid.historyCount
    return index < history
      ? grid.historyMark(index) : grid.mark(index - history)
  }

  /// Absolute rows where prompts start (not continuations), oldest first.
  public func promptRows() -> [Int] {
    (firstAbsoluteRow ..< firstAbsoluteRow + addressableRows)
      .filter { mark(absoluteRow: $0) == .prompt }
  }

  /// Scrolls so the `delta`-th prompt above (negative) or below (positive)
  /// the top visible row becomes the top row. Returns false when there is
  /// no such prompt that can move the viewport.
  @discardableResult
  public mutating func jumpToPrompt(_ delta: Int) -> Bool {
    guard !isAlternateScreen, delta != 0 else { return false }
    let top = absoluteRow(viewportRow: 0)
    let prompts = promptRows()
    let candidates =
      delta < 0
      ? prompts.filter { $0 < top }.reversed() : prompts.filter { $0 > top }
    let steps = delta.magnitude
    guard UInt(candidates.count) >= steps else { return false }
    let target = Array(candidates)[Int(steps) - 1]
    let before = viewportOffset
    scrollViewport(toTopRow: target - firstAbsoluteRow)
    guard viewportOffset != before else { return false }
    damage.setFull()
    return true
  }

  /// Output of the command around `p` (in its prompt, command line or
  /// output): from the output mark to the last non-blank row before the
  /// next prompt. Nil when that command has no marked output.
  public func commandOutputRange(
    at p: TerminalPoint
  ) -> (start: TerminalPoint, end: TerminalPoint)? {
    let p = clamp(p)
    let first = firstAbsoluteRow
    let last = firstAbsoluteRow + addressableRows - 1
    var start: Int?
    var row = p.row
    while row >= first {
      let m = mark(absoluteRow: row)
      if m == .output {
        start = row
        break
      }
      if m == .prompt {
        // On the prompt: the output follows, before the next prompt.
        var next = row + 1
        while next <= last, mark(absoluteRow: next) != .prompt {
          if mark(absoluteRow: next) == .output {
            start = next
            break
          }
          next += 1
        }
        break
      }
      row -= 1
    }
    guard let start else { return nil }
    var end = start
    while end + 1 <= last {
      let m = mark(absoluteRow: end + 1)
      if m == .prompt || m == .promptContinuation { break }
      end += 1
    }
    while end > start,
      withLine(
        absoluteRow: end,
        { cells, _ in !cells.contains(where: { !$0.isBlank }) }
      ) == true
    { end -= 1 }
    return (
      TerminalPoint(row: start, column: 0),
      TerminalPoint(row: end, column: columns - 1)
    )
  }

  /// What a click at `p` sends the shell, or nil when it sends nothing.
  /// Every `cl` value moves along the command line like Ghostty does;
  /// `click_events` reports clicks at or below the current prompt and
  /// leaves validation to the shell, as kitty does.
  public func promptClickAction(at p: TerminalPoint) -> PromptClickAction? {
    guard case let .events(relative) = promptClick else {
      return promptCursorMoves(to: p).map(PromptClickAction.moves)
    }
    guard p.column >= 0, !isAlternateScreen,
      semanticState == .prompt || semanticState == .input
    else { return nil }
    var promptRow = screenAbsoluteRow(cursor.y)
    while promptRow > firstAbsoluteRow, mark(absoluteRow: promptRow) != .prompt
    { promptRow -= 1 }
    guard mark(absoluteRow: promptRow) == .prompt, p.row >= promptRow else {
      return nil
    }
    let row = relative ? p.row - promptRow : viewportRow(absoluteRow: p.row)
    guard row >= 0, row < rows else { return nil }
    let column = min(p.column, columns - 1)
    return .report(Array("\u{1B}[<0;\(column + 1);\(row + 1)M".utf8))
  }

  /// Left (negative) or right arrow presses that move the shell's cursor
  /// to `p` while a command line is being edited (OSC 133 ; B), or nil
  /// when `p` is outside it. Arrows move by character, so wide characters
  /// and clusters count once; a point past the text goes to its end.
  /// Negative columns are outside the command; columns beyond a row's
  /// right edge target that row's end.
  public func promptCursorMoves(to p: TerminalPoint) -> Int? {
    guard p.column >= 0, semanticState == .input, !isAlternateScreen,
      let start = inputStart
    else { return nil }
    let p = TerminalPoint(row: p.row, column: min(p.column, columns))
    let cursorRow = screenAbsoluteRow(cursor.y)
    let cursorPoint = TerminalPoint(
      row: cursorRow,
      column: cursor.x + (cursor.pendingWrap ? 1 : 0)
    )
    // The edited line runs from the input start through the cursor's
    // row and any rows it wraps into.
    var lastRow = cursorRow
    while isWrapped(absoluteRow: lastRow) == true,
      isWrapped(absoluteRow: lastRow + 1) != nil
    { lastRow += 1 }
    guard p.row >= start.row, p.row <= lastRow, start.row <= cursorRow else {
      return nil
    }
    guard p.row > start.row || p.column >= start.column else { return nil }
    func linear(_ q: TerminalPoint) -> Int {
      (q.row - start.row) * columns + q.column
    }
    // End of the typed text: just past the last non-blank cell.
    var end = linear(cursorPoint)
    for row in start.row ... lastRow {
      let last = withLine(absoluteRow: row) { cells, _ in
        cells.lastIndex(where: { !$0.isBlank })
      }
      if let x = last ?? nil {
        end = max(end, linear(TerminalPoint(row: row, column: x + 1)))
      }
    }
    let target = min(linear(p), end)
    let from = linear(cursorPoint)
    guard target != from else { return 0 }
    // Count characters between the two positions.
    var moves = 0
    for i in min(target, from) ..< max(target, from) {
      let row = start.row + i / columns
      let column = i % columns
      let spacer = withLine(absoluteRow: row) { cells, _ in
        column < cells.count ? cells[column].isSpacer : nil
      }
      guard let isSpacer = spacer ?? nil else {
        moves += 1  // blank space past the text
        continue
      }
      if !isSpacer { moves += 1 }
    }
    return target < from ? -moves : moves
  }

  /// Before a resize: when the shell redraws its prompt on SIGWINCH,
  /// clear the prompt being shown so the old copy is not reflowed into
  /// garbage (Ghostty's behavior with `redraw=1`).
  mutating func clearPromptForResize() {
    guard !isAlternateScreen, promptRedraw == .all,
      semanticState == .prompt || semanticState == .input
    else { return }
    var y = cursor.y
    while y >= 0, grid.mark(y) != .prompt { y -= 1 }
    guard y >= 0 else { return }
    invalidateSelection(rows: y ..< rows, from: 0, to: columns)
    grid.clear(rows: y ..< rows, with: .blank)
    grid.setMark(y, .prompt)
    cursor.x = 0
    cursor.y = y
    cursor.pendingWrap = false
    inputOffset = nil
    damage.setFull()
  }

  /// `redraw=last` clears only the cursor's row at the new width, leaving
  /// earlier prompt lines and the reflowed cursor position intact.
  mutating func clearLastPromptRowAfterResize() {
    guard !isAlternateScreen, promptRedraw == .lastRow,
      semanticState == .prompt || semanticState == .input
    else { return }
    clearInputLine()
    invalidateSelection(rows: cursor.y ..< cursor.y + 1, from: 0, to: columns)
    let mark = grid.mark(cursor.y)
    grid.clear(rows: cursor.y ..< cursor.y + 1, with: .blank)
    grid.setMark(cursor.y, mark)
  }

  // MARK: Title and SGR stacks

  /// XTWINOPS 22: saves the title (icon and window titles are one here).
  mutating func pushTitle() {
    if titleStack.count >= Self.stackLimit { titleStack.removeFirst() }
    titleStack.append(titleBytes)
  }

  /// XTWINOPS 23: restores the last saved title.
  mutating func popTitle() {
    guard let saved = titleStack.popLast(), saved != titleBytes else { return }
    titleBytes = saved
    titleChanged = true
  }

  /// XTPUSHSGR: saves the pen's graphic attributes.
  mutating func pushPen() {
    if penStack.count >= Self.stackLimit { penStack.removeFirst() }
    penStack.append(cursor.pen)
  }

  /// XTPOPSGR: restores them; the hyperlink and protection are not SGR
  /// state and stay as they are.
  mutating func popPen() {
    guard var saved = penStack.popLast() else { return }
    saved.link = cursor.pen.link
    saved.flags.subtract(.protected)
    saved.flags.formUnion(cursor.pen.flags.intersection(.protected))
    cursor.pen = saved
  }

  /// xterm's depth for the title and SGR stacks.
  static let stackLimit = 10

  // MARK: Reports

  /// Sets the appearance the host is showing; with mode 2031 the
  /// application is told about the change.
  public mutating func setColorScheme(_ scheme: ColorScheme) {
    guard scheme != colorScheme else { return }
    colorScheme = scheme
    if modes.contains(.colorSchemeUpdates) { reportColorScheme() }
  }

  /// `CSI ? 997 ; 1 n` (dark) or `; 2 n` (light).
  mutating func reportColorScheme() {
    reply("\u{1B}[?997;\(colorScheme == .dark ? 1 : 2)n")
  }

  /// In-band resize notification (mode 2048):
  /// `CSI 48 ; rows ; columns ; height px ; width px t`.
  mutating func reportSize() {
    reply(
      "\u{1B}[48;\(rows);\(columns);\(textAreaPixelSize.height);\(textAreaPixelSize.width)t"
    )
  }

  // MARK: OSC 22 / OSC 21

  /// OSC 22: pointer shape; empty means the default.
  mutating func setPointerShape(_ rest: UnsafeBufferPointer<UInt8>) {
    let name = rest.isEmpty ? "default" : String(decoding: rest, as: UTF8.self)
    guard name != pointerShape else { return }
    pointerShape = name
    events.append(.pointerShape(name))
  }

  /// OSC 21, the kitty color protocol: `key=value` pairs where the value
  /// is a color, `?` to query, or empty for a supported dynamic color.
  /// A bare key resets to its configured default. Keys are `foreground`,
  /// `background`, `cursor`, `cursor_text`, `selection_foreground`,
  /// `selection_background` and palette indices.
  mutating func kittyColors(
    _ rest: UnsafeBufferPointer<UInt8>,
    terminator st: String
  ) {
    var answers: [String] = []
    var changed = false
    for item in String(decoding: rest, as: UTF8.self).split(separator: ";") {
      guard let eq = item.firstIndex(of: "=") else {
        changed = setKittyColor(item, nil) || changed
        continue
      }
      let key = item[..<eq]
      let value = item[item.index(after: eq)...]
      if value == "?" {
        switch kittyColor(key) {
        case let .known(rgb):
          answers.append("\(key)=\(rgb.map(Self.formatColor) ?? "")")
        case .unknown:
          // Unknown names are opaque: never reflect them as PTY input.
          // The protocol uses Base64 without padding to delimit fields.
          var encoded = Data(key.utf8).base64EncodedString()
          while encoded.last == "=" { encoded.removeLast() }
          answers.append("unknown=\(encoded)")
        }
        continue
      }
      if value.isEmpty {
        changed = setDynamicKittyColor(key) || changed
      } else if let rgb = Self.parseColor(value) {
        changed = setKittyColor(key, rgb) || changed
      }
    }
    if !answers.isEmpty {
      reply("\u{1B}]21;" + answers.joined(separator: ";") + st)
    }
    if changed { damage.setFull() }
  }

  private enum KittyColor {
    case unknown
    case known(UInt32?)
  }

  private func kittyColor(_ key: Substring) -> KittyColor {
    switch key {
    case "foreground": .known(palette.foreground)
    case "background": .known(palette.background)
    case "cursor": .known(palette.cursor)
    case "cursor_text": .known(palette.cursorText)
    case "selection_foreground": .known(palette.selectionForeground)
    case "selection_background": .known(palette.selectionBackground)
    default:
      if let index = Int(key), (0 ..< 256).contains(index) {
        .known(palette.colors[index])
      } else {
        .unknown
      }
    }
  }

  /// Only these overrides have a dynamic representation in the renderer.
  /// Palette entries cannot be dynamic; unsupported requests do nothing.
  private mutating func setDynamicKittyColor(_ key: Substring) -> Bool {
    switch key {
    case "cursor_text": palette.cursorText = nil
    case "selection_foreground": palette.selectionForeground = nil
    case "selection_background": palette.selectionBackground = nil
    default: return false
    }
    return true
  }

  /// Sets (or with nil resets) one color; returns whether `key` is known.
  private mutating func setKittyColor(_ key: Substring, _ rgb: UInt32?) -> Bool
  {
    switch key {
    case "foreground": palette.foreground = rgb ?? defaultPalette.foreground
    case "background": palette.background = rgb ?? defaultPalette.background
    case "cursor": palette.cursor = rgb ?? defaultPalette.cursor
    case "cursor_text": palette.cursorText = rgb ?? defaultPalette.cursorText
    case "selection_foreground":
      palette.selectionForeground = rgb ?? defaultPalette.selectionForeground
    case "selection_background":
      palette.selectionBackground = rgb ?? defaultPalette.selectionBackground
    default:
      guard let i = Int(key), (0 ..< 256).contains(i) else { return false }
      palette.colors[i] = rgb ?? defaultPalette.colors[i]
    }
    return true
  }

  // MARK: Underline colors

  /// Id for underline color `color` (SGR 58). Up to 63 distinct colors
  /// are kept per terminal; past that, underlines use the text color.
  mutating func internUnderlineColor(_ color: TerminalColor) -> UInt8 {
    if let i = underlineColors.firstIndex(of: color) { return UInt8(i + 1) }
    guard underlineColors.count < 63 else { return 0 }
    underlineColors.append(color)
    return UInt8(underlineColors.count)
  }

  /// Color for `CellAttributes.underlineColor` id `id`.
  public func underlineColor(_ id: UInt8) -> TerminalColor? {
    id > 0 && Int(id) <= underlineColors.count
      ? underlineColors[Int(id) - 1] : nil
  }

  /// RIS: shell-integration and stack state.
  mutating func resetShellState() {
    semanticState = .none
    promptRedraw = .none
    promptClick = .none
    inputOffset = nil
    hasSemanticPrompts = false
    lastExitCode = nil
    shellCommand = ""
    titleStack = []
    penStack = []
    underlineColors = []
    if !pointerShape.isEmpty {
      pointerShape = ""
      events.append(.pointerShape(""))
    }
  }
}
