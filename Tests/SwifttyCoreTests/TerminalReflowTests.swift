@testable import SwifttyCore
import Testing
import TestSupport

struct TerminalReflowTests {
  @Test(arguments: [(4, 2), (4, 5), (8, 2), (8, 5)], ["A", "A;k=s", "B", "C"])
  func `resize retains blank semantic rows below both cursors`(
    _ size: (Int, Int),
    _ command: String
  ) {
    var vt = VT(4, 4, scrollback: 4096)
    vt.feed("\u{1B}[4;1H\u{1B}]133;\(command)\u{7}\u{1B}[H")
    vt.state.resize(columns: size.0, rows: size.1)
    let expected: RowMark =
      switch command {
      case "A": .prompt
      case "A;k=s": .promptContinuation
      case "C": .output
      default: .none
      }
    let mark = vt.state.mark(absoluteRow: 3)
    #expect(mark == expected)
    let row = vt.state.line(absoluteRow: 3)
    #expect(row?.cells.allSatisfy(\.isBlank) == true)
    if command == "B" {
      let y = 3 - vt.state.screenAbsoluteRow(0)
      vt.feed("\u{1B}[\(y + 1);1H")
      let start = vt.state.inputStart
      #expect(start == TerminalPoint(row: 3, column: 0))
    }
  }

  @Test(arguments: [2, 3, 5, 6], [1, 5])
  func `semantic boundaries follow wide leads across reflow padding`(
    _ columns: Int,
    _ rows: Int
  ) {
    var vt = VT(4, rows, scrollback: 4096)
    vt.feed("ABC漢\u{1B}]133;C\u{7}X")
    vt.state.resize(columns: columns, rows: rows)
    let row = columns == 2 ? 2 : (columns == 3 ? 1 : 0)
    let mark = vt.state.mark(absoluteRow: row)
    #expect(mark == .output)
    let cell = vt.state.line(absoluteRow: row)?
      .cells[columns == 2 || columns == 3 ? 0 : 3]
    #expect(cell?.glyph == 0x6F22)
  }

  @Test(arguments: [5, 6], ["A;k=s", "C"])
  func `merged semantic rows keep the first role and input line flag`(
    _ columns: Int,
    _ command: String
  ) {
    var vt = VT(4, 5, scrollback: 4096)
    vt.feed(
      "\u{1B}]133;A\u{7}ABCDE\u{1B}]133;\(command)\u{7}F\u{1B}]133;B\u{7}gh"
    )
    vt.state.resize(columns: columns, rows: 5)
    let first = vt.state.mark(absoluteRow: 0)
    #expect(first == .prompt)
    let start = vt.state.inputStart
    #expect(start == TerminalPoint(row: 6 / columns, column: 6 % columns))
    let moves = vt.state.promptCursorMoves(
      to: TerminalPoint(row: 6 / columns, column: 6 % columns)
    )
    #expect(moves == -2)
  }

  @Test(
    arguments: [2, 3, 5, 6],
    [("A;k=s", 1), ("A;k=s", 5), ("C", 1), ("C", 5)]
  )
  func `width reflow follows semantic marks within wrapped lines`(
    _ columns: Int,
    _ fixture: (String, Int)
  ) {
    let (command, rows) = fixture
    var vt = VT(4, rows, scrollback: 4096)
    vt.feed("ABCDE\u{1B}]133;\(command)\u{7}F")
    vt.state.resize(columns: columns, rows: rows)
    let expected: RowMark = command == "C" ? .output : .promptContinuation
    let mark = vt.state.mark(absoluteRow: 4 / columns)
    #expect(mark == expected)
  }

  @Test(arguments: [1, 5], ["ABC漢", "AB漢"])
  func `height resize preserves wide padding attributes and pending wrap`(
    _ rows: Int,
    _ text: String
  ) {
    var vt = VT(4, 3, scrollback: 4096)
    vt.feed("\u{1B}[1;31;44;4m" + text)
    let cursor = vt.cursor
    let pending = vt.state.cursor.pendingWrap
    let cells = (0 ... cursor.y)
      .map { Array(vt.state.grid._unsafeCells(row: $0)) }
    let wrapped = (0 ... cursor.y).map { vt.state.grid.isWrapped($0) }
    vt.state.resize(columns: 4, rows: rows)
    for y in cells.indices {
      let actual = vt.state.line(absoluteRow: y)
      #expect(actual.map { Array($0.cells) } == cells[y])
      #expect(actual?.wrapped == wrapped[y])
    }
    #expect(vt.cursor.x == cursor.x)
    #expect(vt.state.cursor.pendingWrap == pending)
    let cursorRow = vt.state.screenAbsoluteRow(vt.cursor.y)
    #expect(cursorRow == cursor.y)
    let validExtents = vt.state.checkExtentInvariant()
    #expect(validExtents)
  }

  @Test(arguments: [1, 3, 6], ["A;k=s", "C"])
  func `height resize retains semantic marks on soft wrapped rows`(
    _ rows: Int,
    _ command: String
  ) {
    var vt = VT(4, 3, scrollback: 4096)
    vt.feed("\u{1B}]133;A\u{7}ABCDE\u{1B}]133;\(command)\u{7}F")
    let expected: RowMark = command == "C" ? .output : .promptContinuation
    let before = vt.state.mark(absoluteRow: 1)
    #expect(before == expected)
    vt.state.resize(columns: 4, rows: rows)
    let first = vt.state.mark(absoluteRow: 0)
    let second = vt.state.mark(absoluteRow: 1)
    #expect(first == .prompt)
    #expect(second == expected)
    let wrapped = vt.state.line(absoluteRow: 0)?.wrapped
    #expect(wrapped == true)
    let text = vt.state.text(
      from: TerminalPoint(row: 0, column: 0),
      to: TerminalPoint(row: 1, column: 4)
    )
    #expect(text == "ABCDEF")
  }

  @Test(arguments: [4, 8], [1, 5])
  func
    `inactive primary input origin follows reflow while alternate screen is active`(
      _ initialColumns: Int,
      _ rows: Int
    )
  {
    var vt = VT(initialColumns, rows, scrollback: 4096)
    vt.feed("\u{1B}]133;A\u{7}ABC漢\u{1B}]133;B\u{7}xyz\u{1B}[?1049h\u{1B}[Halt")
    let columns = initialColumns == 4 ? 8 : 4
    vt.state.resize(columns: columns, rows: rows)
    vt.feed("\u{1B}[?1049l")
    let expected = TerminalPoint(
      row: columns == 4 ? 1 : 0,
      column: columns == 4 ? 2 : 5
    )
    let start = vt.state.inputStart
    #expect(start == expected)
    let moves = vt.state.promptCursorMoves(to: expected)
    #expect(moves == -3)
  }

  @Test(arguments: [4, 8], [(false, 1), (false, 5), (true, 1), (true, 5)])
  func `input origin follows wide character padding through reflow`(
    _ initialColumns: Int,
    _ fixture: (Bool, Int)
  ) {
    let (pending, rows) = fixture
    var vt = VT(initialColumns, rows, scrollback: 4096)
    let prompt = pending ? "AB漢" : "ABC漢"
    vt.feed("\u{1B}]133;A\u{7}" + prompt + "\u{1B}]133;B\u{7}xyz")
    let columns = initialColumns == 4 ? 8 : 4
    vt.state.resize(columns: columns, rows: rows)
    let start = vt.state.inputStart
    let expected = TerminalPoint(
      row: columns == 4 ? 1 : 0,
      column: columns == 4 ? (pending ? 0 : 2) : (pending ? 4 : 5)
    )
    #expect(start == expected)
    let moves = vt.state.promptCursorMoves(to: expected)
    #expect(moves == -3)
    vt.state.resize(columns: initialColumns, rows: rows)
    let restored = vt.state.inputStart
    let original = TerminalPoint(
      row: initialColumns == 4 ? 1 : 0,
      column: initialColumns == 4 ? (pending ? 0 : 2) : (pending ? 4 : 5)
    )
    #expect(restored == original)
    let restoredMoves = vt.state.promptCursorMoves(to: original)
    #expect(restoredMoves == -3)
  }

  @Test(arguments: [2, 3, 4, 5, 7, 9], Array(0 ..< 16))
  func `reflow keeps live and saved cursors on the same wide or narrow cell`(
    _ columns: Int,
    _ scenario: Int
  ) {
    let x = scenario % 8
    let restore = scenario >= 8
    var vt = VT(8, 8, scrollback: 4096)
    vt.feed("A漢B😀CD\u{1B}[1;\(x + 1)H")
    let original = vt.cell(x, 0)
    if restore { vt.feed("\u{1B}7\u{1B}[H") }
    vt.state.resize(columns: columns, rows: 8)
    if restore { vt.feed("\u{1B}8") }
    #expect(vt.cell(vt.cursor.x, vt.cursor.y) == original)
    #expect(!vt.state.cursor.pendingWrap)
    vt.state.resize(columns: 8, rows: 8)
    #expect(vt.cursor.x == x)
    #expect(vt.cursor.y == 0)
    #expect(vt.cell(x, 0) == original)
    let validExtents = vt.state.checkExtentInvariant()
    #expect(validExtents)
  }

  @Test(arguments: [12, 24], [false, true])
  func `width changes restore default tab stops on either screen`(
    _ columns: Int,
    _ alternate: Bool
  ) {
    var vt = VT(20, 3)
    if alternate { vt.feed("\u{1B}[?47h") }
    // Remove all defaults and install a stop in column four.
    vt.feed("\u{1B}[3g\u{1B}[4G\u{1B}H\r\t")
    #expect(vt.cursor.x == 3)
    vt.state.resize(columns: columns, rows: 3)
    vt.feed("\r\t")
    #expect(vt.cursor.x == 8)
    vt.feed("\u{1B}[Z")
    #expect(vt.cursor.x == 0)
    vt.feed("\u{1B}[3G\t")
    #expect(vt.cursor.x == 8)  // The custom stop was removed.
  }

  @Test(arguments: [1, 5], [false, true])
  func `height changes preserve custom and cleared tab stops`(
    _ rows: Int,
    _ alternate: Bool
  ) {
    var vt = VT(20, 3)
    if alternate { vt.feed("\u{1B}[?47h") }
    vt.feed("\u{1B}[3g\u{1B}[4G\u{1B}H\r")
    vt.state.resize(columns: 20, rows: rows)
    vt.feed("\t")
    #expect(vt.cursor.x == 3)
    vt.feed("\t")
    #expect(vt.cursor.x == 19)  // Cleared defaults remain absent.
    vt.feed("\u{1B}[Z")
    #expect(vt.cursor.x == 3)
    vt.feed("\u{1B}[Z")
    #expect(vt.cursor.x == 0)
  }

  @Test(arguments: [1, 2, 3, 4, 6])
  func `grid resize removes cut wide characters from history and screen alike`(
    _ columns: Int
  ) {
    var grid = Grid(columns: 4, rows: 1, historyLimitBytes: 4096)
    let attributes = CellAttributes(
      foreground: .palette(1),
      background: .palette(4)
    )
    var tail = attributes
    tail.flags.insert(.spacerTail)
    let cells = [
      Cell(glyph: 0x41, attributes: .default, width: 1),
      Cell(glyph: 0x6F22, attributes: attributes, width: 2),
      Cell(glyph: 0, attributes: tail, width: 0),
      Cell(glyph: 0x42, attributes: .default, width: 1),
    ]
    cells.withUnsafeBufferPointer { source in
      grid.appendHistory(source, wrapped: false)
      grid.setRow(0, source, wrapped: false)
    }
    grid.resize(columns: columns, rows: 1)
    var expected = Array(cells.prefix(columns))
    if columns == 2 { expected[1] = .blank }
    expected.append(
      contentsOf: repeatElement(.blank, count: max(0, columns - cells.count))
    )
    #expect(Array(grid._unsafeCells(row: 0)) == expected)
    #expect(Array(grid.historyLine(0).cells) == expected)
  }

  @Test(arguments: [3, 4, 6], [0, 1, 2])
  func
    `alternate screen resize preserves the insertion position after pending wrap`(
      _ columns: Int,
      _ restoration: Int
    )
  {
    var vt = VT(4, 3)
    vt.feed("\u{1B}[?47hABCD\u{1B}7")
    if restoration == 2 { vt.feed("\u{1B}[?47l") }
    vt.state.resize(columns: columns, rows: 3)
    if restoration == 2 { vt.feed("\u{1B}[?47h") }
    if restoration != 0 { vt.feed("\u{1B}8") }
    #expect(vt.cursor.x == (columns > 4 ? 4 : columns - 1))
    #expect(vt.state.cursor.pendingWrap == (columns <= 4))
    vt.feed("X")
    let expected =
      columns == 6
      ? ["ABCDX", "", ""] : [columns == 3 ? "ABC" : "ABCD", "X", ""]
    #expect(TestFixture(vt.lines) == TestFixture(expected))
  }

  @Test(arguments: [1, 3], ["漢", "❤\u{FE0F}"])
  func `reflowed wide character padding preserves its attributes`(
    _ rows: Int,
    _ text: String
  ) throws {
    var vt = VT(8, rows, scrollback: 4096)
    vt.feed(
      "\u{1B}[?2027hABC\u{1B}[1;31;44;4m\u{1B}]8;;https://example.com\u{07}"
        + text
    )
    let lead = vt.cell(3, 0)
    let tail = vt.cell(4, 0)
    #expect(lead.width == 2)
    vt.state.resize(columns: 4, rows: rows)
    let head: Cell
    if rows == 1 {
      try #require(vt.state.grid.historyCount == 1)
      head = vt.state.grid.historyLine(0).0[3]
    } else {
      head = vt.cell(3, 0)
    }
    var expected = lead.attributes
    expected.flags.subtract(.structural)
    expected.flags.insert(.spacerHead)
    #expect(head == Cell(glyph: 0, attributes: expected, width: 1))
    let y = rows == 1 ? 0 : 1
    #expect(vt.cell(0, y) == lead)
    #expect(vt.cell(1, y) == tail)
    vt.state.resize(columns: 8, rows: rows)
    #expect(vt.state.grid.historyCount == 0)
    #expect(vt.cell(3, 0) == lead)
    #expect(vt.cell(4, 0) == tail)
    let validExtents = vt.state.checkExtentInvariant()
    #expect(validExtents)
  }
}

extension TerminalReflowTests {
  @Test
  func widthResizeClearsInactiveWrapPadding() {
    var vt = VT(6, 3)
    vt.feed("\u{1B}[?1049habcde漢\u{1B}[?1049l")
    #expect(vt.state.inactiveGrid[5, 0].flags.contains(.spacerHead))
    vt.state.resize(columns: 8, rows: 3)
    #expect(!vt.state.inactiveGrid[5, 0].flags.contains(.spacerHead))
    #expect(vt.state.inactiveGrid[0, 1].width == 2)
    #expect(vt.state.inactiveGrid[1, 1].flags.contains(.spacerTail))
  }
}
