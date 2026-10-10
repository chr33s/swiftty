import AppKit
import SwifttyCore

/// VoiceOver: the view is a read-only text area holding the visible
/// screen, with the insertion point at the terminal cursor.
extension TerminalView {
  override func isAccessibilityElement() -> Bool { true }

  override func accessibilityRole() -> NSAccessibility.Role? { .textArea }

  override func accessibilityRoleDescription() -> String? { "terminal" }

  override func accessibilityLabel() -> String? { window?.title ?? "Terminal" }

  override func accessibilityValue() -> Any? { accessibilityText?.string ?? "" }

  override func accessibilityNumberOfCharacters() -> Int {
    accessibilityText?.string.utf16.count ?? 0
  }

  override func accessibilityVisibleCharacterRange() -> NSRange {
    NSRange(location: 0, length: accessibilityNumberOfCharacters())
  }

  override func accessibilitySelectedTextRange() -> NSRange {
    selectedAccessibilityRanges.first
      ?? NSRange(location: accessibilityText?.cursorOffset ?? 0, length: 0)
  }

  override func accessibilitySelectedTextRanges() -> [NSValue]? {
    let ranges = selectedAccessibilityRanges
    return (ranges.isEmpty ? [accessibilitySelectedTextRange()] : ranges)
      .map { NSValue(range: $0) }
  }

  override func accessibilitySelectedText() -> String? {
    guard let text = accessibilityText else { return "" }
    let string = text.string as NSString
    return selectedAccessibilityRanges.map { string.substring(with: $0) }
      .joined(separator: "\n")
  }

  /// Selection offsets refer to the visible value, including its row separators.
  /// A rectangle has one range per row; an ordinary selection is contiguous.
  private var selectedAccessibilityRanges: [NSRange] {
    guard let text = accessibilityText, let snapshot = lastSnapshot,
      let selection = snapshot.selection
    else { return [] }
    let first = max(0, selection.startRow)
    let last = min(text.lineRanges.count - 1, selection.endRow)
    guard first <= last else { return [] }
    func offset(column: Int, row: Int) -> Int {
      let cells = snapshot.cells(row: row)
      var length = 0
      for x in 0 ..< min(column, cells.count) where !cells[x].isSpacer {
        length += accessibilityUTF16Length(of: cells[x], in: snapshot)
      }
      let line = text.lineRanges[row]
      return line.location + min(length, line.length)
    }
    var ranges: [NSRange] = []
    for row in first ... last {
      var lo = max(
        0,
        selection.rectangle || row == selection.startRow
          ? selection.startColumn : 0
      )
      let hi = min(
        snapshot.columns - 1,
        selection.rectangle || row == selection.endRow
          ? selection.endColumn : snapshot.columns - 1
      )
      guard lo <= hi else { continue }
      let cells = snapshot.cells(row: row)
      if lo > 0, cells[lo].flags.contains(.spacerTail), cells[lo - 1].width == 2
      {
        lo -= 1
      }
      let start = offset(column: lo, row: row)
      let end = offset(column: hi + 1, row: row)
      ranges.append(NSRange(location: start, length: end - start))
    }
    if selection.rectangle { return ranges.filter { $0.length > 0 } }
    guard let start = ranges.first?.location,
      let end = ranges.last.map(NSMaxRange), end > start
    else { return [] }
    return [NSRange(location: start, length: end - start)]
  }

  override func accessibilityInsertionPointLineNumber() -> Int {
    accessibilityText?.cursorLine ?? 0
  }

  override func accessibilityLine(for index: Int) -> Int {
    accessibilityText?.line(forOffset: index) ?? 0
  }

  override func accessibilityRange(forLine line: Int) -> NSRange {
    guard let text = accessibilityText, line >= 0, line < text.lineRanges.count
    else { return NSRange(location: 0, length: 0) }
    return text.lineRanges[line]
  }

  override func accessibilityRange(for index: Int) -> NSRange {
    guard let text = accessibilityText, let snapshot = lastSnapshot, index >= 0,
      index < text.string.utf16.count
    else { return NSRange(location: NSNotFound, length: 0) }
    let row = text.line(forOffset: index)
    let line = text.lineRanges[row]
    // The exposed row separator is a character with no terminal cell.
    if index == NSMaxRange(line) { return NSRange(location: index, length: 1) }
    let column = accessibilityColumn(
      at: index - line.location,
      row: row,
      in: snapshot,
      roundUp: false
    )
    return accessibilityGlyphRange(
      column: column,
      row: row,
      text: text,
      snapshot: snapshot
    )
  }

  override func accessibilityRange(for point: NSPoint) -> NSRange {
    guard point.x.isFinite, point.y.isFinite, let window,
      let text = accessibilityText, let snapshot = lastSnapshot
    else { return NSRange(location: NSNotFound, length: 0) }
    let local = convert(window.convertPoint(fromScreen: point), from: nil)
    guard containsTerminalPoint(local) else {
      return NSRange(location: NSNotFound, length: 0)
    }
    let cell = unclampedCell(at: local)
    guard cell.row >= 0, cell.row < text.lineRanges.count, cell.column >= 0,
      cell.column < snapshot.columns
    else { return NSRange(location: NSNotFound, length: 0) }
    return accessibilityGlyphRange(
      column: cell.column,
      row: cell.row,
      text: text,
      snapshot: snapshot
    )
  }

  /// A wide glyph's two cells share one UTF-16 range.
  private func accessibilityGlyphRange(
    column: Int,
    row: Int,
    text: AccessibilityText,
    snapshot: RenderSnapshot
  ) -> NSRange {
    let cells = snapshot.cells(row: row)
    let line = text.lineRanges[row]
    var offset = 0
    for x in 0 ..< cells.count where !cells[x].isSpacer {
      let cell = cells[x]
      let length = min(
        accessibilityUTF16Length(of: cell, in: snapshot),
        max(0, line.length - offset)
      )
      if column >= x, column < x + max(1, Int(cell.width)), length > 0 {
        return NSRange(location: line.location + offset, length: length)
      }
      offset += length
    }
    return NSRange(location: NSNotFound, length: 0)
  }

  override func accessibilityString(for range: NSRange) -> String? {
    guard let string = accessibilityText?.string else { return nil }
    let ns = string as NSString
    guard range.location >= 0, range.length >= 0, range.location <= ns.length,
      range.length <= ns.length - range.location
    else { return nil }
    return ns.substring(with: range)
  }

  /// Screen rectangle enclosing the cells `range` touches.
  override func accessibilityFrame(for range: NSRange) -> NSRect {
    guard let text = accessibilityText, let snapshot = lastSnapshot, let window
    else { return .zero }
    let length = text.string.utf16.count
    guard range.location >= 0, range.length >= 0, range.location <= length,
      range.length <= length - range.location
    else { return .zero }
    let first = text.line(forOffset: range.location)
    let last = text.line(forOffset: max(range.location, NSMaxRange(range) - 1))
    var left = snapshot.columns
    var right = 0
    for row in first ... last {
      let line = text.lineRanges[row]
      let start = min(line.length, max(0, range.location - line.location))
      let end = min(line.length, max(0, NSMaxRange(range) - line.location))
      left = min(
        left,
        accessibilityColumn(at: start, row: row, in: snapshot, roundUp: false)
      )
      right = max(
        right,
        accessibilityColumn(
          at: end,
          row: row,
          in: snapshot,
          roundUp: range.length > 0
        )
      )
    }
    let scale = window.backingScaleFactor
    let cell = renderer.cellSize
    let top = (renderer.options.paddingY + CGFloat(first) * cell.height) / scale
    let height = CGFloat(last - first + 1) * cell.height / scale
    let rect = NSRect(
      x: (renderer.options.paddingX + CGFloat(left) * cell.width) / scale,
      y: bounds.height - top - height,
      width: CGFloat(right - left) * cell.width / scale,
      height: height,
    )
    return window.convertToScreen(convert(rect, to: nil))
  }

  /// An offset inside a glyph uses its leading or trailing cell boundary.
  private func accessibilityColumn(
    at target: Int,
    row: Int,
    in snapshot: RenderSnapshot,
    roundUp: Bool
  ) -> Int {
    guard target > 0 else { return 0 }
    let cells = snapshot.cells(row: row)
    var offset = 0
    for x in 0 ..< cells.count where !cells[x].isSpacer {
      let cell = cells[x]
      let end = offset + accessibilityUTF16Length(of: cell, in: snapshot)
      let next = min(cells.count, x + max(1, Int(cell.width)))
      if target < end { return roundUp ? next : x }
      if target == end { return next }
      offset = end
    }
    return cells.count
  }

  private func accessibilityUTF16Length(
    of cell: Cell,
    in snapshot: RenderSnapshot
  ) -> Int {
    if cell.isGrapheme {
      let scalars = snapshot.graphemeScalars(cell)
      var length = 0
      for i in 0 ..< scalars.count {
        length +=
          Unicode.Scalar(scalars[i]).map { $0.value > 0xFFFF ? 2 : 1 } ?? 1
      }
      return length
    }
    return Unicode.Scalar(cell.glyph).map { $0.value > 0xFFFF ? 2 : 1 } ?? 1
  }
}
