/// Converts primary-screen cells and scrollback into resized rows without
/// mutating the source grid. TerminalState commits the result and chooses
/// which rows remain on screen.
enum TerminalReflow {
  private struct RowBoundary {
    var line: Int
    var offset: Int
    var bits: UInt8
  }

  struct Result {
    var cells: [Cell]
    var wrapped: [Bool]
    var marks: [UInt8]
    var cursors: [(row: Int, column: Int, pending: Bool)]
  }

  private struct LogicalLines {
    var cells: [Cell]
    var starts: [Int]
    var wrapped: [Bool]
    var marks: [UInt8]
    var boundaries: [RowBoundary]
    var cursors: [(line: Int, offset: Int, pending: Bool)]
  }

  private static func collect(
    from grid: borrowing Grid,
    columns newColumns: Int,
    cursors: [Cursor],
    contentCursorCount: Int,
    rewrap: Bool,
  ) -> LogicalLines {
    var lastRow = min(
      cursors.prefix(contentCursorCount).map(\.y).max() ?? 0,
      grid.rows - 1
    )
    // A blank prompt or input origin is retained content too, even
    // when neither live nor saved cursor remains on its row.
    for y in stride(from: grid.rows - 1, to: lastRow, by: -1)
    where grid.markBits(y) != 0
      || grid._unsafeCells(row: y).contains(where: { !$0.isBlank })
    {
      lastRow = y
      break
    }
    var cells: [Cell] = []
    var lineStarts: [Int] = []
    var lineWrapped: [Bool] = []
    var lineMarks: [UInt8] = []
    var boundaries: [RowBoundary] = []
    var lineOpen = false
    // Per cursor: logical line, offset in it, and pending wrap.
    var marks = cursors.map { _ in (line: -1, offset: 0, pending: false) }
    let history = grid.historyCount
    for p in 0 ..< history + lastRow + 1 {
      let (row, wrapped) =
        p < history
        ? grid.historyLine(p)
        : (grid._unsafeCells(row: p - history), grid.isWrapped(p - history))
      let bits =
        p < history ? grid.historyMarkBits(p) : grid.markBits(p - history)
      if !lineOpen {
        lineStarts.append(cells.count)
        lineWrapped.append(wrapped)
        lineMarks.append(bits)
        lineOpen = true
      } else if bits != 0 {
        let line = lineStarts.count - 1
        boundaries.append(
          RowBoundary(
            line: line,
            offset: cells.count - lineStarts[line],
            bits: bits
          )
        )
      }
      for (i, c) in cursors.enumerated() where p == history + c.y {
        let line = lineStarts.count - 1
        let x = rewrap ? c.x : min(c.x, newColumns - 1)
        let pending = c.pendingWrap && x == c.x
        marks[i] = (
          line, cells.count - lineStarts[line] + x + (pending ? 1 : 0), pending
        )
      }
      var length = row.count
      if !wrapped || !rewrap {
        while length > 0, row[length - 1].isBlank { length -= 1 }
      }
      for k in 0 ..< length
      where rewrap ? !row[k].flags.contains(.spacerHead) : true {
        cells.append(row[k])
      }
      if !wrapped || !rewrap { lineOpen = false }
    }
    lineStarts.append(cells.count)

    return LogicalLines(
      cells: cells,
      starts: lineStarts,
      wrapped: lineWrapped,
      marks: lineMarks,
      boundaries: boundaries,
      cursors: marks,
    )
  }

  static func resize(
    _ grid: borrowing Grid,
    columns newColumns: Int,
    cursors: [Cursor],
    contentCursorCount: Int,
    rewrap: Bool,
  ) -> Result {
    // Auxiliary search and viewport markers follow retained content;
    // they must not preserve otherwise unused blank rows.
    let lines = collect(
      from: grid,
      columns: newColumns,
      cursors: cursors,
      contentCursorCount: contentCursorCount,
      rewrap: rewrap
    )
    let cells = lines.cells
    let lineStarts = lines.starts
    let lineWrapped = lines.wrapped
    let lineMarks = lines.marks
    let marks = lines.cursors
    var out: [Cell] = []
    var outWrapped: [Bool] = []
    var outMarks: [UInt8] = []
    var boundaryIndex = 0
    var placed = cursors.map { _ in (row: -1, column: 0, pending: false) }
    // Boundaries are ordered with the cells, so retaining many semantic
    // marks does not add a per-cell scan through all marked rows.
    func placeBoundaries(line: Int, offset: Int) {
      while boundaryIndex < lines.boundaries.count {
        let boundary = lines.boundaries[boundaryIndex]
        guard boundary.line == line, boundary.offset <= offset else { break }
        let row = outMarks.count - 1
        outMarks[row] = Grid.mergingMarkBits(outMarks[row], boundary.bits)
        boundaryIndex += 1
      }
    }
    func newRow() {
      out.append(contentsOf: repeatElement(Cell.blank, count: newColumns))
      outWrapped.append(false)
      outMarks.append(0)
    }
    for line in 0 ..< lineStarts.count - 1 {
      let lo = lineStarts[line]
      let hi = lineStarts[line + 1]
      newRow()
      outMarks[outMarks.count - 1] = lineMarks[line]
      var col = 0
      for k in lo ..< hi {
        let cell = cells[k]
        // A wide lead has already advanced col past both cells.
        // Its tail still names the second cell, not the next one.
        let markedColumn = cell.width == 0 ? max(0, col - 1) : col
        for i in marks.indices
        where marks[i].line == line && k - lo == marks[i].offset
          && placed[i].row < 0
        {
          placed[i] = (
            outWrapped.count - 1, min(markedColumn, newColumns - 1), false
          )
        }
        if cell.width == 0 {
          placeBoundaries(line: line, offset: k - lo)
          continue
        }  // tails are re-created with their lead
        let w = Int(cell.width)
        if col + w > newColumns {
          // truncated; a cut wide character is dropped
          guard rewrap else { break }
          if w == 2, col < newColumns {
            var attributes = cell.attributes
            attributes.flags.subtract(.structural)
            attributes.flags.insert(.spacerHead)
            out[out.count - newColumns + col] = Cell(
              glyph: 0,
              attributes: attributes,
              width: 1
            )
          }
          outWrapped[outWrapped.count - 1] = true
          newRow()
          col = 0
          for i in marks.indices
          where marks[i].line == line && k - lo == marks[i].offset {
            placed[i] = (outWrapped.count - 1, 0, false)
          }
        }
        placeBoundaries(line: line, offset: k - lo)
        guard w <= newColumns else { continue }
        let base = out.count - newColumns
        out[base + col] = cell
        if w == 2 {
          var tail = cell.attributes
          tail.flags.subtract(.grapheme)
          tail.flags.insert(.spacerTail)
          out[base + col + 1] = Cell(glyph: 0, attributes: tail, width: 0)
        }
        col += w
      }
      placeBoundaries(line: line, offset: hi - lo)
      if !rewrap { outWrapped[outWrapped.count - 1] = lineWrapped[line] }
      for i in marks.indices where marks[i].line == line && placed[i].row < 0 {
        // The cursor sits past the end of the line's content.
        // Blank cells after it are not kept. An insertion position
        // at the right edge stays pending instead of moving back
        // onto the last character.
        let position = col + (marks[i].offset - (hi - lo))
        let pending = position == newColumns && (rewrap || marks[i].pending)
        placed[i] = (
          outWrapped.count - 1, min(position, newColumns - 1), pending
        )
      }
    }
    for i in 0 ..< contentCursorCount where placed[i].row < 0 {
      newRow()
      placed[i] = (outWrapped.count - 1, 0, false)
    }

    return Result(
      cells: out,
      wrapped: outWrapped,
      marks: outMarks,
      cursors: placed
    )
  }
}

/// Commits reflowed rows and maps their cursors back to the primary screen.
extension TerminalState {
  /// Re-wraps primary screen + scrollback to a new width, keeping each
  /// cursor on the same logical position (a pending wrap is the position
  /// after its cell). Without `rewrap` (autowrap off) rows are truncated
  /// instead. Allocates temporaries; resize is not a hot path.
  mutating func reflowPrimary(
    columns newColumns: Int,
    rows newRows: Int,
    cursors: inout [Cursor],
    rewrap: Bool
  ) {
    // A height change keeps the old top row in place, as Ghostty does:
    // shrinking drops blank rows below the content before pushing rows
    // into history, and growing pulls history back down only when the
    // live cursor sits on the bottom row. The old top row is tracked as
    // one more mark. A width change re-wraps and keeps the bottom.
    let pullsHistory =
      newColumns != grid.columns
      || (newRows > grid.rows && cursors[0].y >= grid.rows - 1)
    let originalCursorCount = cursors.count
    let searchMark =
      !isAlternateScreen && newColumns != grid.columns
      ? selectedSearchReflowMark() : nil
    if let searchMark {
      cursors.append(searchMark.start)
      cursors.append(searchMark.end)
    }
    let inputMark = inputReflowMark()
    let inputMarkIndex = cursors.count
    if let inputMark { cursors.append(inputMark) }
    let screenTopMark = cursors.count
    cursors.append(Cursor())
    defer { cursors.removeLast(cursors.count - originalCursorCount) }
    // A height change moves physical rows without changing their
    // contents, padding, or semantic boundaries on wrapped rows.
    let reflow = TerminalReflow.resize(
      grid,
      columns: newColumns,
      cursors: cursors,
      contentCursorCount: originalCursorCount,
      rewrap: rewrap && newColumns != grid.columns,
    )
    let out = reflow.cells
    let outWrapped = reflow.wrapped
    let outMarks = reflow.marks
    let placed = reflow.cursors

    let total = outWrapped.count
    var top = max(0, total - newRows)
    if !pullsHistory { top = max(top, placed[screenTopMark].row) }
    // Keep the live cursor visible, but never at the cost of rows below
    // the screen: those would be neither on screen nor in history.
    if placed[0].row < top { top = max(placed[0].row, total - newRows) }
    grid.reset(columns: newColumns, rows: newRows)
    out.withUnsafeBufferPointer { buf in
      for r in 0 ..< top {
        grid.appendHistory(
          UnsafeBufferPointer(
            rebasing: buf[r * newColumns ..< (r + 1) * newColumns]
          ),
          wrapped: outWrapped[r],
          marks: outMarks[r],
        )
      }
      for r in top ..< min(total, top + newRows) {
        grid.setRow(
          r - top,
          UnsafeBufferPointer(
            rebasing: buf[r * newColumns ..< (r + 1) * newColumns]
          ),
          wrapped: outWrapped[r],
          marks: outMarks[r],
        )
      }
    }
    if inputMark != nil {
      let origin = placed[inputMarkIndex]
      updateInputOffsetAfterReflow(
        row: origin.row,
        column: origin.column,
        pending: origin.pending,
        columns: newColumns
      )
    }
    if let searchMark {
      let start = placed[originalCursorCount]
      let end = placed[originalCursorCount + 1]
      if start.row >= 0, end.row >= 0 {
        searchMatches[searchMark.matchIndex] = TerminalRange(
          start: TerminalPoint(row: start.row, column: start.column),
          end: TerminalPoint(
            row: end.row,
            column: min(end.column + searchMark.endWidth - 1, newColumns - 1)
          ),
        )
      }
    }
    for i in 0 ..< originalCursorCount {
      cursors[i].x = placed[i].column
      cursors[i].y = min(max(placed[i].row - top, 0), newRows - 1)
      cursors[i].pendingWrap = placed[i].pending
    }
  }
}
