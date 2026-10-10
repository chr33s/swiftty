@testable import SwifttyCore
import Testing
import TestSupport

struct StorageLayoutTests {
  @Test(arguments: RingLayout.small())
  func historyLayouts(_ layout: RingLayout) {
    var ring = Scrollback(capacity: layout.capacity)
    var model: [Int32] = []
    var evicted = 0
    if layout.capacity > 0 {
      for value in 0 ..< layout.appended {
        let expected: Int32?
        if model.count == layout.capacity {
          expected = model.removeFirst()
          evicted += 1
        } else {
          expected = nil
        }
        model.append(Int32(value))
        #expect(ring.push(Int32(value)) == expected)
        #expect(ring.checkInvariants() == true)
        #expect((0 ..< ring.count).map { ring.id($0) } == model)
        #expect(ring.evicted == evicted)
      }
    }
    var released: [Int32] = []
    ring.removeAll { released.append($0) }
    #expect(released == model)
    #expect(ring.count == 0 && ring.evicted == 0 && ring.checkInvariants())
    if layout.capacity > 0 {
      #expect(ring.push(42) == nil)
      #expect(ring.id(0) == 42)
    }
  }

  @Test(arguments: [1, 2, 63, 64, 65], [0, 1, 2, 63, 64, 65])
  func gridMatchesModel(rows: Int, historyCapacity: Int) {
    let columns = 4
    var grid = Grid(
      columns: columns,
      rows: rows,
      historyLimitBytes: columns * 16 * historyCapacity,
      maxHistoryRows: historyCapacity
    )
    var screen = Array(
      repeating: Array(repeating: Cell.blank, count: columns),
      count: rows
    )
    var history: [[Cell]] = []
    var evicted = 0
    var random = SeededGenerator(seed: UInt64(rows * 1000 + historyCapacity))
    var trace: [String] = []
    for step in 0 ..< 150 {
      let operation = random.next(upperBound: 5)
      let y = random.next(upperBound: rows)
      let n = random.next(upperBound: rows + 2)
      switch operation {
      case 0:
        let x = random.next(upperBound: columns)
        let cell = Cell(
          glyph: UInt32(65 + step % 26),
          attributes: .default,
          width: 1
        )
        grid[x, y] = cell
        screen[y][x] = cell
        trace.append("write(\(x),\(y))")
      case 1:
        grid.scrollUpIntoHistory(count: n, fill: .blank)
        for _ in 0 ..< min(n, rows) {
          let old = screen.removeFirst()
          screen.append(Array(repeating: .blank, count: columns))
          if historyCapacity > 0 {
            if history.count == historyCapacity {
              history.removeFirst();
              evicted += 1
            }
            history.append(old)
          } else {
            evicted += 1
          }
        }
        trace.append("history(\(n))")
      case 2:
        grid.scrollUp(top: y, bottom: rows - 1, count: n, fill: .blank)
        let count = min(n, rows - y)
        screen.removeSubrange(y ..< y + count)
        screen.append(
          contentsOf: Array(
            repeating: Array(repeating: .blank, count: columns),
            count: count
          )
        )
        trace.append("up(\(y),\(n))")
      case 3:
        grid.scrollDown(top: y, bottom: rows - 1, count: n, fill: .blank)
        let count = min(n, rows - y)
        screen.removeLast(count)
        screen.insert(
          contentsOf: Array(
            repeating: Array(repeating: .blank, count: columns),
            count: count
          ),
          at: y
        )
        trace.append("down(\(y),\(n))")
      default:
        grid.clearHistory()
        history.removeAll()
        evicted = 0
        trace.append("clearHistory")
      }
      let context =
        "seed=\(random.seed), step=\(step), trace=\(trace.suffix(12))"
      #expect(grid.checkInvariants() == true, "\(context)")
      #expect(grid.historyCount == history.count, "\(context)")
      #expect(grid.historyEvicted == evicted, "\(context)")
      for row in 0 ..< rows {
        let actual = grid.cells(row: row).withUnsafeBufferPointer { Array($0) }
        #expect(actual == screen[row], "\(context), row=\(row)")
      }
      for index in history.indices {
        let actual = grid.historyCells(at: index)
          .withUnsafeBufferPointer { Array($0) }
        #expect(actual == history[index], "\(context), history=\(index)")
      }
    }
  }

  @Test
  func mutableViewTracksExtentOnThrow() {
    enum Failure: Error { case expected }
    var grid = Grid(columns: 8, rows: 1)
    #expect(throws: Failure.self) {
      try grid.withMutableCells(row: 0) { cells in
        cells[7] = Cell(glyph: 65, attributes: .default, width: 1)
        throw Failure.expected
      }
    }
    #expect(grid.extent(0) == 8 && grid[7, 0].glyph == 65)
    grid.withMutableCells(row: 0) { cells in cells[7] = .blank }
    #expect(grid.extent(0) == 0 && grid.checkInvariants())
  }
}
