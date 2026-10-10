@testable import SwifttyCore
import Testing

struct ScrollbackTests {
  @Test(arguments: [0, -1])
  func `session honors disabled history row limits`(_ limit: Int) {
    var configuration = SessionConfiguration()
    configuration.scrollbackLimitRows = limit
    let session = TerminalSession(
      columns: 4,
      rows: 2,
      configuration: configuration
    )
    for columns in [4, 8, 2] {
      session.resize(columns: columns, rows: 2)
      session.feed(Array("a\r\nb\r\nc\r\n".utf8))
      #expect(session.withState { $0.grid.historyCount } == 0)
      session.reset()
    }
  }

  @Test(arguments: [0, -1])
  func `nonpositive history row limits disable history`(_ limit: Int) {
    var grid = Grid(
      columns: 4,
      rows: 2,
      historyLimitBytes: 1024,
      maxHistoryRows: limit
    )
    for columns in [4, 8, 2] {
      grid.resize(columns: columns, rows: 2)
      fill(&grid, row: 0, "x")
      grid.scrollUpIntoHistory(count: 1, fill: .blank)
      #expect(grid.historyCapacity == 0)
      #expect(grid.historyCount == 0)
      #expect(text(grid._unsafeCells(row: 0)) == "")
    }
  }

  func fill(_ grid: inout Grid, row y: Int, _ s: String) {
    for (x, scalar) in s.unicodeScalars.enumerated() {
      grid[x, y] = Cell(glyph: scalar.value, attributes: .default, width: 1)
    }
  }

  func text(_ cells: UnsafeBufferPointer<Cell>) -> String {
    String(
      String.UnicodeScalarView(
        cells.compactMap { $0.glyph == 0 ? nil : Unicode.Scalar($0.glyph) }
      )
    )
  }

  @Test
  func `scrolling moves rows into history without copying`() {
    var grid = Grid(columns: 8, rows: 2, historyLimitBytes: 8 * 16 * 10)
    fill(&grid, row: 0, "abc")
    let top = grid._unsafeRow(0)
    grid.setWrapped(0, true)
    grid.scrollUpIntoHistory(count: 1, fill: .blank)
    #expect(grid.historyCount == 1)
    let (cells, wrapped) = grid.historyLine(0)
    #expect(cells.baseAddress == UnsafePointer(top))
    #expect(text(cells) == "abc" && wrapped)
    #expect(grid.extent(1) == 0 && !grid.isWrapped(1))
  }

  @Test
  func `history is capped and recycles the oldest row`() {
    var grid = Grid(columns: 4, rows: 2, historyLimitBytes: 4 * 16 * 3)
    #expect(grid.historyCapacity == 3)
    for i in 0 ..< 10 {
      fill(&grid, row: 1, "\(i)")
      grid.scrollUpIntoHistory(count: 1, fill: .blank)
    }
    #expect(grid.historyCount == 3)
    #expect(text(grid._unsafeCells(row: 1)) == "")
    // Each scroll pushes the previous bottom row (now row 0): "6", "7", "8".
    #expect(
      (0 ..< 3).map { text(grid.historyLine($0).cells) } == ["6", "7", "8"]
    )
  }

  @Test
  func `history order and contents`() {
    var grid = Grid(columns: 4, rows: 1, historyLimitBytes: 4 * 16 * 3)
    for i in 0 ..< 5 {
      fill(&grid, row: 0, "\(i)")
      grid.scrollUpIntoHistory(count: 1, fill: .blank)
    }
    #expect(
      (0 ..< 3).map { text(grid.historyLine($0).cells) } == ["2", "3", "4"]
    )
  }

  @Test
  func `max history rows and disabled history`() {
    let capped = Grid(
      columns: 4,
      rows: 2,
      historyLimitBytes: 1 << 30,
      maxHistoryRows: 10
    )
    #expect(capped.historyCapacity == 10)
    var none = Grid(columns: 4, rows: 2)
    fill(&none, row: 0, "x")
    none.scrollUpIntoHistory(count: 1, fill: .blank)
    #expect(none.historyCount == 0 && text(none._unsafeCells(row: 0)) == "")
  }

  @Test
  func `append and clear history`() {
    var grid = Grid(columns: 4, rows: 1, historyLimitBytes: 4 * 16 * 2)
    let row = [Cell](
      repeating: Cell(glyph: 0x41, attributes: .default, width: 1),
      count: 4
    )
    for _ in 0 ..< 5 {
      row.withUnsafeBufferPointer { grid.appendHistory($0, wrapped: false) }
    }
    #expect(grid.historyCount == 2)
    grid.clearHistory()
    #expect(grid.historyCount == 0)
    fill(&grid, row: 0, "z")
    grid.scrollUpIntoHistory(count: 1, fill: .blank)
    #expect(text(grid.historyLine(0).cells) == "z")
  }
}
