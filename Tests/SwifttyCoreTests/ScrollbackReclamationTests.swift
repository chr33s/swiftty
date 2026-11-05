@testable import SwifttyCore
@testable import SwifttyEngine
import Testing
import TestSupport

struct ScrollbackReclamationTests {
  func fill(_ grid: inout Grid, row y: Int, _ s: String) {
    for (x, scalar) in s.unicodeScalars.enumerated() where x < grid.columns {
      grid[x, y] = Cell(glyph: scalar.value, attributes: .default, width: 1)
    }
  }

  @Test
  func `clearing compressed history discards payloads without decoding`() {
    var vt = VT(60, 6)
    vt.feed(scrollbackCorpus(lines: 800, columns: 60))
    let screen = vt.lines
    let compressed = compressAll(&vt.state)
    #expect(compressed > 0)
    vt.feed("\(CSI)3J")
    let stats = vt.state.scrollbackStatistics
    #expect(stats.restores == 0)
    #expect(stats.scanDecodes == 0)
    #expect(stats.discardedPayloads == compressed)
    #expect(stats.compressedUnits == 0)
    #expect(stats.compressedPayloadBytes == 0)
    #expect(stats.discardedUnits > 0)
    #expect(stats.reclaimedFreeBytes > 0)
    #expect(stats.logicalHistoryCellBytes == 0)
    #expect(vt.lines == screen)
    #expect(vt.state.grid.checkInvariants() == true)
    // Reused rows start blank.
    vt.feed("\(CSI)H\(CSI)2J")
    vt.feed(scrollbackCorpus(lines: 200, columns: 60))
    var reference = VT(60, 6)
    reference.feed(scrollbackCorpus(lines: 200, columns: 60))
    #expect(historyFingerprint(vt.state) == historyFingerprint(reference.state))
    #expect(vt.state.grid.checkInvariants() == true)
  }

  @Test
  func `clearing resident history reclaims fully free units only`() {
    var grid = Grid(columns: 80, rows: 24, historyLimitBytes: 80 * 16 * 5_000)
    for i in 0 ..< 2_000 {
      fill(&grid, row: 23, "line \(i)")
      grid.scrollUpIntoHistory(count: 1, fill: .blank)
    }
    grid.clear(rows: 0 ..< 24, with: .blank)
    for y in 0 ..< 24 { fill(&grid, row: y, "screen \(y)") }
    grid.clearHistory()
    let stats = grid.scrollbackStatistics()
    #expect(stats.reclaimedUnits > 0)
    #expect(stats.reclaimedFreeBytes > 0)
    // Units mixing screen rows stay resident with their live rows.
    for y in 0 ..< 24 {
      let text = grid.cells(row: y)
        .withUnsafeBufferPointer { cells in
          String(
            String.UnicodeScalarView(
              cells.compactMap {
                $0.glyph == 0 ? nil : Unicode.Scalar($0.glyph)
              }
            )
          )
        }
      #expect(text == "screen \(y)")
    }
    #expect(grid.checkInvariants() == true)
    for i in 0 ..< 3_000 {
      fill(&grid, row: 23, "again \(i)")
      grid.scrollUpIntoHistory(count: 1, fill: .blank)
    }
    #expect(grid.checkInvariants() == true)
    #expect(grid.historyCount == 3_000)
  }

  /// Seeded replay through compress, promote, scan, clear and reuse,
  /// against an array model, across unit-straddling widths.
  @Test(arguments: [1, 4, 257, 1000], [0, 1, 63, 64, 65, 300])
  func `seeded replay matches the model through storage transitions`(
    columns: Int,
    historyCapacity: Int
  ) {
    let rows = 3
    var grid = Grid(
      columns: columns,
      rows: rows,
      historyLimitBytes: columns * 16 * max(1, historyCapacity),
      maxHistoryRows: historyCapacity
    )
    var screen = Array(
      repeating: Array(repeating: Cell.blank, count: columns),
      count: rows
    )
    var history: [[Cell]] = []
    var random = SeededGenerator(
      seed: UInt64(columns * 10_000 + historyCapacity)
    )
    var trace: [String] = []
    for step in 0 ..< 400 {
      let operation = random.next(upperBound: 8)
      switch operation {
      case 0, 1, 2:
        let y = random.next(upperBound: rows)
        let x = random.next(upperBound: columns)
        let cell = Cell(
          glyph: UInt32(65 + step % 26),
          attributes: CellAttributes(link: UInt32(step % 7)),
          width: 1
        )
        grid[x, y] = cell
        screen[y][x] = cell
        trace.append("write")
      case 3:
        let n = 1 + random.next(upperBound: 20)
        grid.scrollUpIntoHistory(count: n, fill: .blank)
        for _ in 0 ..< min(n, rows) {
          let old = screen.removeFirst()
          screen.append(Array(repeating: .blank, count: columns))
          if historyCapacity > 0 {
            if history.count == historyCapacity { history.removeFirst() }
            history.append(old)
          }
        }
        trace.append("history(\(n))")
      case 4:
        compressAll(&grid)
        trace.append("compress")
      case 5 where !history.isEmpty:
        // Promote one row; others stay as they are.
        let index = random.next(upperBound: history.count)
        let actual = grid.historyCells(at: index)
          .withUnsafeBufferPointer { Array($0) }
        #expect(actual == history[index], "promote \(index)")
        trace.append("promote(\(index))")
      case 6 where random.next(upperBound: 6) == 0:
        grid.clearHistory()
        history.removeAll()
        trace.append("clear")
      default:
        var budget = ScrollbackMaintenanceBudget()
        budget.maximumCandidates = 1 + random.next(upperBound: 8)
        _ = grid.maintainScrollback(protecting: 0 ..< 0, budget: budget)
        trace.append("step")
      }
      let context = "step=\(step), trace=\(trace.suffix(10))"
      #expect(grid.checkInvariants() == true, "\(context)")
      #expect(grid.historyCount == history.count, "\(context)")
      for row in 0 ..< rows {
        let actual = grid.cells(row: row).withUnsafeBufferPointer { Array($0) }
        #expect(actual == screen[row], "\(context), row=\(row)")
      }
      let restores = grid.scrollbackStatistics().restores
      for index in history.indices {
        grid.withHistoryLine(index) { cells, _ in
          #expect(Array(cells) == history[index], "\(context), h=\(index)")
        }
      }
      #expect(grid.scrollbackStatistics().restores == restores)
    }
  }

  @Test
  func `heap fallback stays uncompressed and equivalent`() {
    var mapped = Grid(columns: 40, rows: 3, historyLimitBytes: 40 * 16 * 300)
    var heap = Grid(
      columns: 40,
      rows: 3,
      historyLimitBytes: 40 * 16 * 300,
      maxHistoryRows: 100_000,
      reclaimable: false
    )
    for i in 0 ..< 500 {
      fill(&mapped, row: 2, "line \(i)")
      fill(&heap, row: 2, "line \(i)")
      mapped.scrollUpIntoHistory(count: 1, fill: .blank)
      heap.scrollUpIntoHistory(count: 1, fill: .blank)
    }
    #expect(mapped.isCompressible == true)
    #expect(heap.isCompressible == false)
    #expect(heap.scrollbackFallbackReason != nil)
    #expect(compressAll(&mapped) > 0)
    var budget = ScrollbackMaintenanceBudget()
    budget.maximumCandidates = 1 << 20
    #expect(
      heap.maintainScrollback(protecting: 0 ..< 0, budget: budget) == .disabled
    )
    for index in 0 ..< mapped.historyCount {
      let a = mapped.withHistoryLine(index) { cells, _ in Array(cells) }
      let b = heap.withHistoryLine(index) { cells, _ in Array(cells) }
      #expect(a == b)
    }
    heap.clearHistory()
    #expect(heap.scrollbackStatistics().reclaimedUnits == 0)
    #expect(heap.checkInvariants() == true)
  }

  @Test
  func `presentation sessions allocate no history and never compress`() {
    let session = TerminalSession(
      presentationColumns: 20,
      rows: 4,
      configuration: SessionConfiguration()
    )
    let policy = session.scrollbackCompression
    #expect(!policy.effective)
    #expect(session.withState { $0.grid.historyCapacity } == 0)
    #expect(session.scrollbackStatistics.reservedMappingBytes > 0)
    #expect(session.scrollbackStatistics.logicalHistoryCellBytes == 0)
  }

  @Test
  func `statistics are metadata only`() {
    var vt = VT(40, 4)
    vt.feed(scrollbackCorpus(lines: 300, columns: 40))
    let compressed = compressAll(&vt.state)
    let before = vt.state.scrollbackStatistics
    for _ in 0 ..< 3 { _ = vt.state.scrollbackStatistics }
    let after = vt.state.scrollbackStatistics
    #expect(after.scanDecodes == before.scanDecodes)
    #expect(after.restores == before.restores)
    #expect(after.compressedUnits == compressed)
    #expect(after.compressedPayloadBytes > 0)
    #expect(after.compressedPayloadBytes < after.logicalHistoryCellBytes)
    #expect(after.metadataBytes > 0)
    #expect(after.reservedMappingBytes >= after.residentUnitBytes)
  }

  @Test
  func `reset and resize release storage with their pools`() {
    var vt = VT(40, 4)
    vt.feed(scrollbackCorpus(lines: 400, columns: 40))
    compressAll(&vt.state)
    let generation = vt.state.scrollbackGeneration
    vt.state.resize(columns: 41, rows: 4)
    #expect(vt.state.scrollbackGeneration != generation)
    #expect(
      vt.state.maintainScrollback(expectedGeneration: generation) == .stale
    )
    #expect(compressAll(&vt.state) > 0)
    vt.feed("\(ESC)c")
    #expect(vt.state.scrollbackStatistics.compressedUnits == 0)
    #expect(vt.state.grid.checkInvariants() == true)
  }
}
