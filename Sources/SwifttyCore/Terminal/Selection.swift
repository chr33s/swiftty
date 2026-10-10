import Foundation

/// A cell position addressed independently of scrolling.
///
/// `row` is an absolute line number: on the primary screen line 0 is the
/// first line ever written to history, so a point keeps naming the same line
/// as output scrolls (`TerminalState.absoluteRow(viewportRow:)`). On the
/// alternate screen rows are screen rows.
public struct TerminalPoint: Hashable, Sendable, Comparable {
  public var row: Int
  public var column: Int

  public init(row: Int, column: Int) {
    self.row = row
    self.column = column
  }

  public static func < (lhs: TerminalPoint, rhs: TerminalPoint) -> Bool {
    lhs.row != rhs.row ? lhs.row < rhs.row : lhs.column < rhs.column
  }
}

/// A selected span: from `anchor` (where it began) to `head` (where it is
/// being extended to), inclusive. `rectangle` selects a column block.
public struct Selection: Equatable, Sendable {
  public var anchor: TerminalPoint
  public var head: TerminalPoint
  public var rectangle: Bool

  public init(
    anchor: TerminalPoint,
    head: TerminalPoint,
    rectangle: Bool = false
  ) {
    self.anchor = anchor
    self.head = head
    self.rectangle = rectangle
  }

  public var start: TerminalPoint {
    rectangle
      ? TerminalPoint(
        row: min(anchor.row, head.row),
        column: min(anchor.column, head.column)
      ) : min(anchor, head)
  }

  public var end: TerminalPoint {
    rectangle
      ? TerminalPoint(
        row: max(anchor.row, head.row),
        column: max(anchor.column, head.column)
      ) : max(anchor, head)
  }

  public func contains(_ p: TerminalPoint) -> Bool {
    let s = start
    let e = end
    if rectangle {
      return p.row >= s.row && p.row <= e.row && p.column >= s.column
        && p.column <= e.column
    }
    return p >= s && p <= e
  }
}

/// An inclusive span of cells, used for search matches.
public struct TerminalRange: Hashable, Sendable {
  public var start: TerminalPoint
  public var end: TerminalPoint

  public init(start: TerminalPoint, end: TerminalPoint) {
    self.start = start
    self.end = end
  }
}

extension TerminalState {
  // MARK: Addressing

  /// Absolute row of the first line still available.
  public var firstAbsoluteRow: Int {
    isAlternateScreen ? 0 : grid.historyEvicted
  }

  /// Lines available for addressing: history plus the screen.
  public var addressableRows: Int {
    (isAlternateScreen ? 0 : grid.historyCount) + rows
  }

  /// Absolute row shown at visible row `y`.
  /// Out-of-range coordinates saturate at the integer limits.
  public func absoluteRow(viewportRow y: Int) -> Int {
    guard !isAlternateScreen else { return y }
    let top = grid.historyEvicted + grid.historyCount - viewportOffset
    let (row, overflow) = top.addingReportingOverflow(y)
    return overflow ? (y < 0 ? .min : .max) : row
  }

  /// Visible row showing absolute row `row` (may be outside `0..<rows`).
  /// Out-of-range coordinates saturate at the integer limits.
  public func viewportRow(absoluteRow row: Int) -> Int {
    guard !isAlternateScreen else { return row }
    let top = grid.historyEvicted + grid.historyCount - viewportOffset
    let (y, overflow) = row.subtractingReportingOverflow(top)
    return overflow ? (row < 0 ? .min : .max) : y
  }

  /// Whether an absolute row remains in the active screen or history. O(1).
  public func contains(absoluteRow row: Int) -> Bool {
    row >= firstAbsoluteRow && row - firstAbsoluteRow < addressableRows
  }

  /// Cells of absolute row `row`, or nil once it has left history.
  internal func line(
    absoluteRow row: Int
  ) -> (cells: UnsafeBufferPointer<Cell>, wrapped: Bool)? {
    guard row >= firstAbsoluteRow else { return nil }
    let index = row - firstAbsoluteRow
    guard index >= 0, index < addressableRows else { return nil }
    let history = isAlternateScreen ? 0 : grid.historyCount
    if index < history { return grid.historyLine(index) }
    return (
      grid._unsafeCells(row: index - history), grid.isWrapped(index - history)
    )
  }

  /// Point clamped to the addressable area.
  public func clamp(_ p: TerminalPoint) -> TerminalPoint {
    TerminalPoint(
      row: min(
        max(p.row, firstAbsoluteRow),
        firstAbsoluteRow + addressableRows - 1
      ),
      column: min(max(p.column, 0), columns - 1),
    )
  }

  /// Absolute point at viewport coordinates, clamped to the visible grid.
  /// Padding and out-of-view gestures cannot address invisible history.
  public func viewportPoint(row: Int, column: Int) -> TerminalPoint {
    TerminalPoint(
      row: absoluteRow(viewportRow: min(max(row, 0), rows - 1)),
      column: min(max(column, 0), columns - 1),
    )
  }

  // MARK: Text

  /// Text between two points (inclusive). Soft-wrapped lines join without
  /// a newline; trailing blanks of each hard line are trimmed.
  public func text(
    from a: TerminalPoint,
    to b: TerminalPoint,
    rectangle: Bool = false
  ) -> String {
    let start = clamp(min(a, b))
    let end = clamp(max(a, b))
    let left = min(max(min(a.column, b.column), 0), columns - 1)
    let right = min(max(max(a.column, b.column), 0), columns - 1)
    var out = String.UnicodeScalarView()
    var pendingNewline = false
    for row in start.row ... end.row {
      guard let (cells, wrapped) = line(absoluteRow: row) else { continue }
      var lo = rectangle ? left : row == start.row ? start.column : 0
      let hi = rectangle ? right : row == end.row ? end.column : columns - 1
      // A selection touching either half includes the whole glyph.
      if lo > 0, lo < cells.count, cells[lo].flags.contains(.spacerTail),
        cells[lo - 1].width == 2
      {
        lo -= 1
      }
      var lineScalars = String.UnicodeScalarView()
      if lo <= hi {
        for x in lo ... min(hi, cells.count - 1) where !cells[x].isSpacer {
          appendText(of: cells[x], to: &lineScalars)
        }
      }
      let joinsNext = !rectangle && wrapped && row != end.row
      var line = String(lineScalars)
      if !joinsNext {
        // Trim whole blank characters, not a space belonging to
        // a grapheme (for example, after a Unicode prepend scalar).
        while line.last == " " { line.removeLast() }
      }
      if pendingNewline { out.append("\n") }
      out.append(contentsOf: line.unicodeScalars)
      pendingNewline = !joinsNext
    }
    return String(out)
  }

  public var selectionText: String? {
    guard let selection else { return nil }
    return text(
      from: selection.start,
      to: selection.end,
      rectangle: selection.rectangle
    )
  }

  // MARK: Selection

  public mutating func setSelection(_ newValue: Selection?) {
    let clamped = newValue.map { s in
      Selection(
        anchor: clamp(s.anchor),
        head: clamp(s.head),
        rectangle: s.rectangle
      )
    }
    guard clamped != selection else { return }
    selection = clamped
    damage.setFull()
  }

  /// Preserve the surviving part of a selection after rows disappear.
  /// Linear selections include complete intervening rows; rectangles
  /// keep their original column boundaries.
  internal mutating func clipSelectionToAvailableRows(_ value: Selection) {
    let first = firstAbsoluteRow
    let last = first + addressableRows - 1
    guard value.end.row >= first, value.start.row <= last else {
      setSelection(nil)
      return
    }
    func clipped(_ point: TerminalPoint) -> TerminalPoint {
      if point.row < first {
        return TerminalPoint(
          row: first,
          column: value.rectangle ? point.column : 0
        )
      }
      if point.row > last {
        return TerminalPoint(
          row: last,
          column: value.rectangle ? point.column : columns - 1
        )
      }
      return point
    }
    setSelection(
      Selection(
        anchor: clipped(value.anchor),
        head: clipped(value.head),
        rectangle: value.rectangle
      )
    )
  }

  /// Selects everything addressable: history and the screen.
  public mutating func selectAll() {
    setSelection(
      Selection(
        anchor: TerminalPoint(row: firstAbsoluteRow, column: 0),
        head: TerminalPoint(
          row: firstAbsoluteRow + addressableRows - 1,
          column: columns - 1
        ),
      )
    )
  }

  /// Selection was made on content that is gone (screen switch, resize,
  /// clear): drop it.
  internal mutating func invalidateSelection() {
    if selection != nil {
      selection = nil
      damage.setFull()
    }
    markSearchDirty()
  }

  /// Moving cells in place replaces their selected content. Selections
  /// elsewhere, including scrollback and cells outside margins, survive.
  internal mutating func invalidateSelection(
    rows range: Range<Int>,
    from left: Int,
    to right: Int
  ) {
    guard left < right, !range.isEmpty else { return }
    markSearchDirty()
    guard selection != nil else { return }
    for y in range {
      if let selected = selectedColumns(inScreenRow: y),
        selected.overlaps(left ..< right)
      {
        setSelection(nil)
        return
      }
    }
  }

  /// Selected cells in a screen row, including both halves of wide glyphs.
  /// Capture before writing so splitting a wide glyph cannot hide a selected half.
  @inline(__always)
  internal func selectedColumns(inScreenRow y: Int) -> Range<Int>? {
    guard let selection else { return nil }
    let row = screenAbsoluteRow(y)
    let start = selection.start
    let end = selection.end
    guard row >= start.row, row <= end.row else { return nil }
    var lo = max(0, selection.rectangle || row == start.row ? start.column : 0)
    var hi =
      min(
        columns - 1,
        selection.rectangle || row == end.row ? end.column : columns - 1
      ) + 1
    guard lo < hi else { return nil }
    let cells = grid._unsafeCells(row: y)
    if lo > 0, cells[lo].flags.contains(.spacerTail) { lo -= 1 }
    if hi < columns, cells[hi].flags.contains(.spacerTail) { hi += 1 }
    return lo ..< hi
  }

  /// Word around `p`: a run of cells of the same class (word characters,
  /// blanks, or other punctuation) following soft wraps.
  public func wordRange(
    at p: TerminalPoint
  ) -> (start: TerminalPoint, end: TerminalPoint) {
    let p = clamp(p)
    func cls(_ q: TerminalPoint) -> Int? {
      guard let (cells, _) = line(absoluteRow: q.row) else { return nil }
      var column = q.column
      var cell = cells[column]
      // Wrap padding can follow a wide glyph's tail. Walk through
      // both spacer cells to classify its visible character.
      while cell.isSpacer || cell.width == 0, column > 0 {
        column -= 1
        cell = cells[column]
      }
      var scalar: Unicode.Scalar?
      if cell.isGrapheme {
        let scalars = graphemeScalars(cell.glyph)
        for value in scalars {
          if let first = Unicode.Scalar(value) {
            scalar = first
            break
          }
        }
      } else {
        scalar =
          cell.glyph == 0 || cell.isSpacer ? nil : Unicode.Scalar(cell.glyph)
      }
      guard let scalar, scalar != " " else { return 0 }
      return Self.isWordScalar(scalar) ? 1 : 2
    }
    guard let target = cls(p) else { return (p, p) }
    var start = p
    while let prev = step(start, by: -1), cls(prev) == target { start = prev }
    var end = p
    while let next = step(end, by: 1), cls(next) == target { end = next }
    return (start, end)
  }

  /// Whole logical line (across soft wraps) containing `p`.
  public func lineRange(
    at p: TerminalPoint
  ) -> (start: TerminalPoint, end: TerminalPoint) {
    let p = clamp(p)
    var top = p.row
    while top > firstAbsoluteRow, let (_, wrapped) = line(absoluteRow: top - 1),
      wrapped
    { top -= 1 }
    var bottom = p.row
    while let (_, wrapped) = line(absoluteRow: bottom), wrapped,
      bottom < firstAbsoluteRow + addressableRows - 1
    { bottom += 1 }
    return (
      TerminalPoint(row: top, column: 0),
      TerminalPoint(row: bottom, column: columns - 1)
    )
  }

  /// Neighbouring cell across soft wraps only.
  private func step(_ p: TerminalPoint, by delta: Int) -> TerminalPoint? {
    if delta < 0 {
      if p.column > 0 { return TerminalPoint(row: p.row, column: p.column - 1) }
      guard let (_, wrapped) = line(absoluteRow: p.row - 1), wrapped else {
        return nil
      }
      return TerminalPoint(row: p.row - 1, column: columns - 1)
    }
    if p.column < columns - 1 {
      return TerminalPoint(row: p.row, column: p.column + 1)
    }
    guard let (_, wrapped) = line(absoluteRow: p.row), wrapped,
      line(absoluteRow: p.row + 1) != nil
    else { return nil }
    return TerminalPoint(row: p.row + 1, column: 0)
  }

  internal static func isWordScalar(_ s: Unicode.Scalar) -> Bool {
    if s.properties.isAlphabetic || s.properties.numericType != nil {
      return true
    }
    switch s {
    case "_", "-", ".", "/", "~", ":", "@", "+", "%", "#", "=", "?", "&":
      return true
    default: return false
    }
  }

  // MARK: Search

  /// Finds every occurrence of `needle` (case-insensitive unless it has
  /// an uppercase letter), oldest first; matches may span soft wraps.
  public mutating func search(_ needle: String) {
    searchQuery = needle.isEmpty ? nil : needle
    searchNeedsRefresh = false
    searchMatches = findSearchMatches(needle)
    searchSelected = nil
    damage.setFull()
  }

  internal mutating func markSearchDirty() {
    searchNeedsRefresh = searchQuery != nil
  }

  /// Moves existing ranges with retained rows before refreshing their
  /// contents, so the selected occurrence keeps its identity.
  internal mutating func shiftSearchRows(by delta: Int) {
    guard delta != 0 else { return }
    for i in searchMatches.indices {
      searchMatches[i].start.row += delta
      searchMatches[i].end.row += delta
    }
  }

  internal struct SearchReflowMark {
    var matchIndex: Int
    var start: Cursor
    var end: Cursor
    var endWidth: Int
  }

  /// Reflow tracks insertion positions. For an inclusive match ending
  /// on a wide tail, track its lead and restore the tail afterward.
  internal func selectedSearchReflowMark() -> SearchReflowMark? {
    guard let index = searchSelected, searchMatches.indices.contains(index)
    else { return nil }
    let range = searchMatches[index]
    guard range.start.row >= firstAbsoluteRow,
      range.end.row >= firstAbsoluteRow,
      line(absoluteRow: range.start.row) != nil,
      let (cells, _) = line(absoluteRow: range.end.row),
      cells.indices.contains(range.end.column)
    else { return nil }
    var start = Cursor()
    var end = Cursor()
    start.x = range.start.column
    start.y = range.start.row - firstAbsoluteRow - grid.historyCount
    end.x = range.end.column
    if cells[end.x].flags.contains(.spacerTail), end.x > 0 { end.x -= 1 }
    end.y = range.end.row - firstAbsoluteRow - grid.historyCount
    return SearchReflowMark(
      matchIndex: index,
      start: start,
      end: end,
      endWidth: max(1, Int(cells[end.x].width))
    )
  }

  /// Updates an active search after direct state changes. Parsing and
  /// session mutations do this once per batch automatically.
  public mutating func refreshSearch() {
    searchNeedsRefresh = false
    guard let query = searchQuery else { return }
    let matches = findSearchMatches(query)
    guard matches != searchMatches else { return }
    let selected = searchSelected.flatMap {
      searchMatches.indices.contains($0) ? searchMatches[$0] : nil
    }
    searchMatches = matches
    if let selected {
      searchSelected =
        matches.firstIndex(of: selected) ?? matches.firstIndex(where: {
          $0.start >= selected.start
        }) ?? matches.indices.last
    } else {
      searchSelected = matches.indices.last
    }
    damage.setFull()
  }

  internal mutating func refreshSearchIfNeeded() {
    if searchNeedsRefresh { refreshSearch() }
  }

  private func findSearchMatches(_ needle: String) -> [TerminalRange] {
    var matches: [TerminalRange] = []
    let target = Array(needle.unicodeScalars)
    guard !target.isEmpty else { return [] }
    let caseSensitive = needle.contains { $0.isUppercase }
    let locale = Locale(identifier: "en_US_POSIX")
    let folded =
      caseSensitive
      ? target
      : Array(
        needle.folding(options: .caseInsensitive, locale: locale).unicodeScalars
      )
    // Reuse matching prefixes so repeated text stays linear in line length.
    var prefixes = [Int](repeating: 0, count: folded.count)
    var matched = 0
    for i in folded.indices.dropFirst() {
      while matched > 0, folded[i] != folded[matched] {
        matched = prefixes[matched - 1]
      }
      if folded[i] == folded[matched] { matched += 1 }
      prefixes[i] = matched
    }

    // Stream logical lines through KMP. Only the last query-length
    // positions are needed to locate a match, even for a huge wrapped line.
    var points = [TerminalPoint](
      repeating: TerminalPoint(row: 0, column: 0),
      count: folded.count
    )
    var nextPoint = 0
    var lastMatch: TerminalRange?
    matched = 0
    func consume(
      _ scalar: Unicode.Scalar,
      at point: TerminalPoint,
      width: UInt8
    ) {
      points[nextPoint] = point
      nextPoint += 1
      if nextPoint == points.count { nextPoint = 0 }
      while matched > 0, scalar != folded[matched] {
        matched = prefixes[matched - 1]
      }
      if scalar == folded[matched] { matched += 1 }
      if matched == folded.count {
        let end = TerminalPoint(
          row: point.row,
          column: point.column + (width == 2 ? 1 : 0)
        )
        let range = TerminalRange(start: points[nextPoint], end: end)
        // Folding can produce several matches in the same cell,
        // such as searching for "s" in a single sharp S.
        if lastMatch != range {
          matches.append(range)
          lastMatch = range
        }
        matched = prefixes[matched - 1]
      }
    }
    func append(_ scalar: Unicode.Scalar, at point: TerminalPoint, width: UInt8)
    {
      if caseSensitive {
        consume(scalar, at: point, width: width)
      } else if scalar.value < 0x80 {
        // ASCII lowercasing needs no intermediate String or array.
        let value =
          (0x41 ... 0x5A).contains(scalar.value)
          ? scalar.value + 0x20 : scalar.value
        consume(Unicode.Scalar(value)!, at: point, width: width)
      } else {
        for folded in String(scalar)
          .folding(options: .caseInsensitive, locale: locale).unicodeScalars
        { consume(folded, at: point, width: width) }
      }
    }
    var row = firstAbsoluteRow
    let last = firstAbsoluteRow + addressableRows
    while row < last, let (cells, wrapped) = line(absoluteRow: row) {
      for x in 0 ..< cells.count where !cells[x].isSpacer {
        let cell = cells[x]
        let point = TerminalPoint(row: row, column: x)
        if cell.isGrapheme {
          var hasContent = false
          let scalars = graphemeScalars(cell.glyph)
          for value in scalars {
            if let scalar = Unicode.Scalar(value) {
              append(scalar, at: point, width: cell.width)
              hasContent = true
            }
          }
          if !hasContent { append(" ", at: point, width: cell.width) }
        } else if cell.glyph != 0, let scalar = Unicode.Scalar(cell.glyph) {
          append(scalar, at: point, width: cell.width)
        } else {
          append(" ", at: point, width: cell.width)
        }
      }
      row += 1
      if !wrapped { matched = 0 }
    }
    return matches
  }

  /// Moves the selected match (wrapping) and scrolls it into view.
  /// `forward` goes towards newer output. Returns the selected index.
  @discardableResult
  public mutating func selectSearchMatch(forward: Bool) -> Int? {
    guard !searchMatches.isEmpty else { return nil }
    let n = searchMatches.count
    let next =
      switch searchSelected {
      case let i?: forward ? (i + 1) % n : (i - 1 + n) % n
      case nil: forward ? 0 : n - 1
      }
    searchSelected = next
    scrollToShow(row: searchMatches[next].start.row)
    damage.setFull()
    return next
  }

  public mutating func endSearch() {
    searchQuery = nil
    searchNeedsRefresh = false
    searchMatches = []
    searchSelected = nil
    damage.setFull()
  }

  /// Scrolls the viewport so absolute `row` is visible, clamping to the
  /// available lines when the requested row is outside them.
  public mutating func scrollToShow(row: Int) {
    guard !isAlternateScreen else { return }
    let target = clamp(TerminalPoint(row: row, column: 0)).row
    let y = viewportRow(absoluteRow: target)
    if y < 0 {
      scrollViewport(by: -y)
    } else if y >= rows {
      scrollViewport(by: rows - 1 - y)
    }
  }

  /// Scrolls so that history line `top` (0 = oldest available) is the first
  /// visible row.
  public mutating func scrollViewport(toTopRow top: Int) {
    guard !isAlternateScreen else { return }
    let target = grid.historyCount - min(max(top, 0), grid.historyCount)
    scrollViewport(by: target - viewportOffset)
  }
}
