/// A complete, independently owned copy of the visible terminal state.
///
/// Captured in one operation on the terminal's owner, so cells and metadata
/// describe the same state. Grapheme cells refer to `graphemes` by
/// index rather than to the terminal's pooled table; `links` are dropped.
/// Used by SwiftMux to export pane frames and, in the other direction, to
/// build renderer snapshots from validated frames.
package struct OwnedScreen: Sendable, Equatable {
  package var columns: Int
  package var rows: Int
  /// Row-major, `columns * rows` cells.
  package var cells: [Cell]
  package var wrapped: [Bool]
  package var graphemes: [[UInt32]]
  package var cursor: CursorState
  package var palette: Palette
  package var underlineColors: [TerminalColor]
  package var modes: Modes
  package var title: String
  package var isAlternateScreen: Bool
  /// History addressing: rows change meaning when this changes.
  package var addressingGeneration: UInt64
  /// Absolute row of the oldest available line.
  package var firstAbsoluteRow: Int
  /// Absolute row shown at viewport row 0.
  package var viewportTopRow: Int
  package var viewportOffset: Int
  package var scrollbackCount: Int
  package var searchMatches: [HighlightSpan]
  package var selectedSearchMatch: Int?
  package var searchMatchCount: Int
  /// Types a kitty drag-and-drop client accepts (nil: none registered)
  /// and its answer for the current drag.
  package var dropTypes: [String]?
  package var dropAccepted: KittyDragAndDrop.Operation?

  package init(
    columns: Int,
    rows: Int,
    cells: [Cell],
    wrapped: [Bool],
    graphemes: [[UInt32]],
    cursor: CursorState,
    palette: Palette,
    underlineColors: [TerminalColor] = [],
    modes: Modes,
    title: String = "",
    isAlternateScreen: Bool = false,
    addressingGeneration: UInt64 = 0,
    firstAbsoluteRow: Int = 0,
    viewportTopRow: Int = 0,
    viewportOffset: Int = 0,
    scrollbackCount: Int = 0,
    searchMatches: [HighlightSpan] = [],
    selectedSearchMatch: Int? = nil,
    searchMatchCount: Int = 0,
    dropTypes: [String]? = nil,
    dropAccepted: KittyDragAndDrop.Operation? = nil,
  ) {
    self.columns = columns
    self.rows = rows
    self.cells = cells
    self.wrapped = wrapped
    self.graphemes = graphemes
    self.cursor = cursor
    self.palette = palette
    self.underlineColors = underlineColors
    self.modes = modes
    self.title = title
    self.isAlternateScreen = isAlternateScreen
    self.addressingGeneration = addressingGeneration
    self.firstAbsoluteRow = firstAbsoluteRow
    self.viewportTopRow = viewportTopRow
    self.viewportOffset = viewportOffset
    self.scrollbackCount = scrollbackCount
    self.searchMatches = searchMatches
    self.selectedSearchMatch = selectedSearchMatch
    self.searchMatchCount = searchMatchCount
    self.dropTypes = dropTypes
    self.dropAccepted = dropAccepted
  }

  /// The top-left `columns` × `rows` cells, padded with blanks; row
  /// addressing is unchanged (viewer windows, protocol size limits).
  package func cropped(columns: Int, rows: Int) -> OwnedScreen {
    guard columns > 0, rows > 0, columns != self.columns || rows != self.rows
    else { return self }
    var out = self
    var cells: [Cell] = []
    cells.reserveCapacity(columns * rows)
    var wrapped: [Bool] = []
    wrapped.reserveCapacity(rows)
    for y in 0 ..< rows {
      let source = y < self.rows
      wrapped.append(source && y < self.wrapped.count ? self.wrapped[y] : false)
      for x in 0 ..< columns {
        cells.append(
          source && x < self.columns ? self.cells[y * self.columns + x] : .blank
        )
      }
    }
    out.cells = cells
    out.wrapped = wrapped
    out.columns = columns
    out.rows = rows
    out.cursor.x = min(max(0, cursor.x), columns - 1)
    out.cursor.y = min(max(0, cursor.y), rows - 1)
    return out
  }

  /// Text of row `y` with trailing blanks trimmed.
  package func text(row y: Int) -> String {
    var s = String.UnicodeScalarView()
    for x in 0 ..< columns {
      let cell = cells[y * columns + x]
      if cell.isSpacer { continue }
      if cell.isGrapheme {
        for v in graphemes[Int(cell.glyph)] {
          s.append(Unicode.Scalar(v) ?? "\u{FFFD}")
        }
      } else {
        s.append(cell.glyph == 0 ? " " : Unicode.Scalar(cell.glyph) ?? " ")
      }
    }
    var line = String(s)
    while line.last == " " { line.removeLast() }
    return line
  }
}

extension TerminalState {
  /// Copies a window of `rows` lines starting at absolute row `top` (the
  /// live screen when nil or on the alternate screen) without moving the
  /// terminal's own viewport. Search state is not included; the cursor
  /// shows only on the live screen.
  package func captureOwnedWindow(top requested: Int?) -> OwnedScreen {
    let live = firstAbsoluteRow + scrollbackCount
    let top =
      isAlternateScreen
      ? firstAbsoluteRow : min(max(requested ?? live, firstAbsoluteRow), live)
    var cells: [Cell] = []
    cells.reserveCapacity(columns * rows)
    var wrapped: [Bool] = []
    wrapped.reserveCapacity(rows)
    var graphemes: [[UInt32]] = []
    for y in 0 ..< rows {
      let copied: Bool? = withLine(absoluteRow: top + y) { row, isWrapped in
        wrapped.append(isWrapped)
        for x in 0 ..< columns {
          guard x < row.count else {
            cells.append(.blank)
            continue
          }
          var cell = row[x]
          if cell.isGrapheme {
            var copy: [UInt32] = []
            appendScalars(of: cell, to: &copy)
            cell.glyph = UInt32(graphemes.count)
            graphemes.append(copy)
          }
          cell.attributes.link = 0
          cells.append(cell)
        }
        return true
      }
      if copied == nil {
        wrapped.append(false)
        cells.append(contentsOf: repeatElement(.blank, count: columns))
      }
    }
    let atLive = top >= live
    return OwnedScreen(
      columns: columns,
      rows: rows,
      cells: cells,
      wrapped: wrapped,
      graphemes: graphemes,
      cursor: CursorState(
        x: min(cursor.x, columns - 1),
        y: min(cursor.y, rows - 1),
        isVisible: modes.contains(.cursorVisible) && atLive,
        style: cursorStyle,
        isBlinking: modes.contains(.cursorBlink),
      ),
      palette: palette,
      underlineColors: underlineColors,
      modes: modes,
      title: title,
      isAlternateScreen: isAlternateScreen,
      addressingGeneration: addressingGeneration,
      firstAbsoluteRow: firstAbsoluteRow,
      viewportTopRow: top,
      viewportOffset: isAlternateScreen ? 0 : live - top,
      scrollbackCount: scrollbackCount,
    )
  }

  /// Copies the visible viewport and its metadata into owned values.
  /// - Complexity: O(columns * rows) plus visible grapheme scalars.
  package func captureOwnedScreen() -> OwnedScreen {
    var cells: [Cell] = []
    cells.reserveCapacity(columns * rows)
    var wrapped: [Bool] = []
    wrapped.reserveCapacity(rows)
    var graphemes: [[UInt32]] = []
    for y in 0 ..< rows {
      let (row, isWrapped) = viewportRow(y)
      wrapped.append(isWrapped)
      for x in 0 ..< columns {
        guard x < row.count else {
          cells.append(.blank)
          continue
        }
        var cell = row[x]
        if cell.isGrapheme {
          let scalars = graphemeScalars(cell.glyph)
          var copy: [UInt32] = []
          copy.reserveCapacity(scalars.count)
          for i in 0 ..< scalars.count { copy.append(scalars[i]) }
          cell.glyph = UInt32(graphemes.count)
          graphemes.append(copy)
        }
        cell.attributes.link = 0
        cells.append(cell)
      }
    }
    let top = absoluteRow(viewportRow: 0)
    var matches: [HighlightSpan] = []
    var selected: Int?
    for (i, m) in searchMatches.enumerated() {
      let start = viewportRow(absoluteRow: m.start.row)
      let end = viewportRow(absoluteRow: m.end.row)
      guard end >= 0, start < rows else { continue }
      if i == searchSelected { selected = matches.count }
      matches.append(
        HighlightSpan(
          startRow: start,
          startColumn: m.start.column,
          endRow: end,
          endColumn: m.end.column
        )
      )
    }
    return OwnedScreen(
      columns: columns,
      rows: rows,
      cells: cells,
      wrapped: wrapped,
      graphemes: graphemes,
      cursor: CursorState(
        x: min(cursor.x, columns - 1),
        y: min(cursor.y, rows - 1),
        isVisible: modes.contains(.cursorVisible) && viewportOffset == 0,
        style: cursorStyle,
        isBlinking: modes.contains(.cursorBlink),
      ),
      palette: palette,
      underlineColors: underlineColors,
      modes: modes,
      title: title,
      isAlternateScreen: isAlternateScreen,
      addressingGeneration: addressingGeneration,
      firstAbsoluteRow: firstAbsoluteRow,
      viewportTopRow: top,
      viewportOffset: viewportOffset,
      scrollbackCount: scrollbackCount,
      searchMatches: matches,
      selectedSearchMatch: selected,
      searchMatchCount: searchMatches.count,
      dropTypes: dragAndDrop?.registeredMimes,
      dropAccepted: dragAndDrop?.clientAccepted,
    )
  }
}
