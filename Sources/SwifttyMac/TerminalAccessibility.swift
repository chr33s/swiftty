import AppKit
import SwifttyCore

/// Unicode-aware queries over the immutable presentation admitted for display.
/// Both native surfaces use this value; history and shell ownership are absent.
@MainActor
package struct TerminalAccessibility {
  let snapshot: RenderSnapshot?
  let text: AccessibilityText?
  let selection: HighlightSpan?

  package init(
    snapshot: RenderSnapshot?,
    text: AccessibilityText?,
    selection: HighlightSpan?
  ) {
    self.snapshot = snapshot
    self.text = text
    self.selection = selection
  }

  package func accessibilityNumberOfCharacters() -> Int {
    text?.string.utf16.count ?? 0
  }

  package func accessibilityVisibleCharacterRange() -> NSRange {
    NSRange(location: 0, length: accessibilityNumberOfCharacters())
  }

  package func accessibilitySelectedTextRange() -> NSRange {
    selectedAccessibilityRanges.first
      ?? NSRange(location: text?.cursorOffset ?? 0, length: 0)
  }

  package func accessibilitySelectedTextRanges() -> [NSValue]? {
    let ranges = selectedAccessibilityRanges
    return (ranges.isEmpty ? [accessibilitySelectedTextRange()] : ranges)
      .map { NSValue(range: $0) }
  }

  package func accessibilitySelectedText() -> String? {
    guard let text = text else { return "" }
    let string = text.string as NSString
    return selectedAccessibilityRanges.map { string.substring(with: $0) }
      .joined(separator: "\n")
  }

  /// Selection offsets refer to the visible value, including its row separators.
  /// A rectangle has one range per row; an ordinary selection is contiguous.
  private var selectedAccessibilityRanges: [NSRange] {
    guard let text = text, let snapshot = snapshot, let selection else {
      return []
    }
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

  package func accessibilityInsertionPointLineNumber() -> Int {
    text?.cursorLine ?? 0
  }

  package func accessibilityLine(for index: Int) -> Int {
    text?.line(forOffset: index) ?? 0
  }

  package func accessibilityRange(forLine line: Int) -> NSRange {
    guard let text = text, line >= 0, line < text.lineRanges.count else {
      return NSRange(location: 0, length: 0)
    }
    return text.lineRanges[line]
  }

  package func accessibilityRange(for index: Int) -> NSRange {
    guard let text = text, let snapshot = snapshot, index >= 0,
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

  package func accessibilityRange(
    for point: NSPoint,
    view: NSView,
    renderer: MetalRenderer,
    contains: (NSPoint) -> Bool
  ) -> NSRange {
    guard point.x.isFinite, point.y.isFinite, let window = view.window,
      let text = text, let snapshot = snapshot
    else { return NSRange(location: NSNotFound, length: 0) }
    let local = view.convert(window.convertPoint(fromScreen: point), from: nil)
    guard contains(local) else {
      return NSRange(location: NSNotFound, length: 0)
    }
    let cell = TerminalPointer.cell(at: local, in: view, renderer: renderer)
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

  package func accessibilityString(for range: NSRange) -> String? {
    guard let string = text?.string else { return nil }
    let ns = string as NSString
    guard range.location >= 0, range.length >= 0, range.location <= ns.length,
      range.length <= ns.length - range.location
    else { return nil }
    return ns.substring(with: range)
  }

  /// Screen rectangle enclosing the cells `range` touches.
  package func accessibilityFrame(
    for range: NSRange,
    view: NSView,
    renderer: MetalRenderer
  ) -> NSRect {
    guard let text = text, let snapshot = snapshot, let window = view.window
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
      y: view.bounds.height - top - height,
      width: CGFloat(right - left) * cell.width / scale,
      height: height,
    )
    return window.convertToScreen(view.convert(rect, to: nil))
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

/// `AccessibilityText` for the latest snapshot, built once per snapshot
/// however many accessibility queries read it.
package struct AccessibilityTextCache {
  private var cached:
    (source: AnyObject, sequence: UInt64, text: AccessibilityText)?

  package init() {}
  private(set) var builds = 0

  package mutating func text(for snapshot: RenderSnapshot) -> AccessibilityText
  {
    if let cached, cached.source === snapshot.sourceIdentity,
      cached.sequence == snapshot.sequence
    {
      return cached.text
    }
    let text = AccessibilityText(snapshot)
    builds += 1
    cached = (snapshot.sourceIdentity, snapshot.sequence, text)
    return text
  }
}
