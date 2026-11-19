import Checksum
@testable import SwifttyCore
@testable import SwifttyEngine
import Testing

/// Encodes every eligible unit, as idle maintenance eventually would.
@discardableResult
func compressAll(_ state: inout TerminalState) -> Int {
  var budget = ScrollbackMaintenanceBudget()
  budget.maximumCandidates = 1 << 20
  budget.maximumUnits = 1 << 20
  var steps = 0
  while state.maintainScrollback(budget: budget) == .pending {
    steps += 1
    precondition(steps < 10_000, "maintenance did not settle")
  }
  return state.scrollbackStatistics.compressedUnits
}

@discardableResult
func compressAll(_ grid: inout Grid, protecting: Range<Int> = 0 ..< 0) -> Int {
  var budget = ScrollbackMaintenanceBudget()
  budget.maximumCandidates = 1 << 20
  budget.maximumUnits = 1 << 20
  while grid.maintainScrollback(protecting: protecting, budget: budget)
    == .pending
  {}
  return grid.scrollbackStatistics().compressedUnits
}

/// Styled, linked, wide, clustered and soft-wrapped output.
func scrollbackCorpus(lines: Int, columns: Int) -> String {
  var s = ""
  for i in 0 ..< lines {
    switch i % 6 {
    case 0:
      s += "\(CSI)3\(i % 8)mline \(i) compiling module_\(i % 97).swift\(CSI)0m"
    case 1: s += "warning: unused 'x\(i)' 漢字テスト 👩‍👩‍👧 e\u{301}"
    case 2:
      s +=
        "\(ESC)]8;;https://example.com/\(i % 40)\(ESC)\\link\(i)"
        + "\(ESC)]8;;\(ESC)\\ tail"
    case 3: s += String(repeating: "abcdefghij", count: columns * 3 / 10 + 1)
    case 4: s += "\(CSI)1;4;48;5;\(i % 256)mbold \(i)\(CSI)0m\(CSI)K"
    default: s += "\(CSI)58;2;1;2;3m\(CSI)4:3mcurly \(i)\(CSI)0m"
    }
    s += "\r\n"
  }
  return s
}

/// Everything observable about primary history, read without promotion.
func historyFingerprint(_ state: borrowing TerminalState) -> [String] {
  var out = (0 ..< state.scrollbackCount).map { state.scrollbackText($0) }
  out.append(String(decoding: state.dumpPrimaryANSI(), as: UTF8.self))
  let first = state.firstAbsoluteRow
  let last = first + state.addressableRows - 1
  out.append(
    state.text(
      from: TerminalPoint(row: first, column: 0),
      to: TerminalPoint(row: last, column: state.columns - 1)
    )
  )
  out.append(
    state.text(
      from: TerminalPoint(row: first, column: 1),
      to: TerminalPoint(row: last, column: 3),
      rectangle: true
    )
  )
  return out
}

struct ScrollbackCompressionTests {
  @Test
  func `cell layout is dense and CRC-32C matches the reference vector`() {
    #expect(ScrollbackCodec.cellLayoutIsDense)
    #expect(MemoryLayout<Cell>.size == 16 && MemoryLayout<Cell>.stride == 16)
    let bytes = Array("123456789".utf8)
    #expect(CRC32C.checksum(bytes, bytes.count) == 0xE306_9283)
    #expect(CRC32C.checksum(bytes, 0) == 0)
    #expect(CRC32C.software(bytes, bytes.count) == 0xE306_9283)
    var long = [UInt8](repeating: 0, count: 4_099)
    for i in long.indices { long[i] = UInt8(truncatingIfNeeded: i &* 31) }
    #expect(
      CRC32C.checksum(long, long.count) == CRC32C.software(long, long.count)
    )
  }

  @Test
  func `codec rejects corrupt and truncated payloads`() {
    let count = 64 * 1024
    var source = [UInt8](repeating: 0, count: count)
    for i in source.indices { source[i] = UInt8(truncatingIfNeeded: i / 64) }
    let checksum = CRC32C.checksum(source, count)
    var encoded = [UInt8](repeating: 0, count: count)
    let scratch = UnsafeMutableRawPointer.allocate(
      byteCount: max(1, ScrollbackCodec.encodeScratchBytes),
      alignment: 16
    )
    defer { scratch.deallocate() }
    let n = encoded.withUnsafeMutableBytes {
      ScrollbackCodec.encode(
        source,
        count,
        into: $0.baseAddress!,
        capacity: count,
        scratch: scratch
      )
    }
    #expect(n > 0 && n < count)
    var decoded = [UInt8](repeating: 0, count: count)
    func decode(
      _ payload: [UInt8],
      _ length: Int
    ) -> ScrollbackCodec.DecodeResult {
      decoded.withUnsafeMutableBytes {
        ScrollbackCodec.decode(
          payload,
          length,
          into: $0.baseAddress!,
          count: count,
          checksum: checksum,
          scratch: nil
        )
      }
    }
    #expect(decode(encoded, n) == .ok)
    #expect(decoded == source)
    var corrupt = encoded
    corrupt[n / 2] ^= 0x5A
    #expect(decode(corrupt, n) != .ok)
    if case .lengthMismatch = decode(encoded, n / 2) {
    } else {
      Issue.record("truncated payload was not rejected by length")
    }
    // An empty encode result is a failure, not an empty stream.
    let zero = encoded.withUnsafeMutableBytes {
      ScrollbackCodec.encode(
        source,
        count,
        into: $0.baseAddress!,
        capacity: 8,
        scratch: scratch
      )
    }
    #expect(zero == 0)
  }

  @Test(arguments: [1, 80, 120, 256, 257, 512, 1000])
  func `compression is transparent at every width`(_ columns: Int) {
    var vt = VT(columns, 8, scrollback: 40_000_000)
    vt.feed(scrollbackCorpus(lines: 300, columns: columns))
    vt.state.search("line 1")
    let matches = vt.state.searchMatches
    let before = historyFingerprint(vt.state)
    let rows = (0 ..< vt.state.scrollbackCount)
      .map { index in
        vt.state.grid.withHistoryLine(index) { cells, wrapped in
          (Array(cells), wrapped, vt.state.grid.historyMark(index))
        }
      }
    #expect(vt.state.scrollbackCompression.effective)
    let compressed = compressAll(&vt.state)
    #expect(compressed > 0)
    let restoresBefore = vt.state.scrollbackStatistics.restores
    #expect(historyFingerprint(vt.state) == before)
    vt.state.refreshSearch()
    vt.state.search("line 1")
    #expect(vt.state.searchMatches == matches)
    for index in rows.indices {
      vt.state.grid.withHistoryLine(index) { cells, wrapped in
        #expect(Array(cells) == rows[index].0, "row \(index)")
        #expect(wrapped == rows[index].1)
      }
      #expect(vt.state.grid.historyMark(index) == rows[index].2)
    }
    // Read-only scans and searches left every unit compressed.
    let stats = vt.state.scrollbackStatistics
    #expect(stats.restores == restoresBefore)
    #expect(stats.compressedUnits == compressed)
    #expect(stats.scanDecodes > 0)
    #expect(vt.state.grid.checkInvariants() == true)
    // Promoting reads return the same cells and restore in place.
    for index in rows.indices {
      let cells = vt.state.scrollbackCells(at: index)
        .withUnsafeBufferPointer { Array($0) }
      #expect(cells == rows[index].0)
    }
    #expect(vt.state.scrollbackStatistics.compressedUnits == 0)
    #expect(vt.state.grid.checkInvariants() == true)
  }

  @Test
  func `two borrowed cold rows stay valid while a third is read`() {
    var grid = Grid(columns: 40, rows: 4, historyLimitBytes: 40 * 16 * 1000)
    for i in 0 ..< 600 {
      for (x, scalar) in "row \(i)".unicodeScalars.enumerated() {
        grid[x, 0] = Cell(glyph: scalar.value, attributes: .default, width: 1)
      }
      grid.scrollUpIntoHistory(count: 1, fill: .blank)
    }
    #expect(compressAll(&grid) > 3)
    let first = grid.historyCells(at: 3)
    let second = grid.historyCells(at: 400)
    let third = grid.historyCells(at: 200)
    func text(_ span: Span<Cell>) -> String {
      span.withUnsafeBufferPointer { cells in
        String(
          String.UnicodeScalarView(
            cells.compactMap { $0.glyph == 0 ? nil : Unicode.Scalar($0.glyph) }
          )
        )
      }
    }
    #expect(text(first) == "row 3")
    #expect(text(second) == "row 400")
    #expect(text(third) == "row 200")
    #expect(text(first) == "row 3")
  }

  @Test
  func `resumed output recycles compressed rows like an uncompressed ring`() {
    let columns = 30
    let budget = columns * 16 * 700
    var vt = VT(columns, 6, scrollback: budget)
    var reference = VT(columns, 6, scrollback: budget)
    reference.state.setScrollbackCompression(false)
    let corpus = scrollbackCorpus(lines: 900, columns: columns)
    vt.feed(corpus)
    reference.feed(corpus)
    #expect(vt.state.grid.historyCount == vt.state.grid.historyCapacity)
    #expect(compressAll(&vt.state) > 0)
    #expect(compressAll(&reference.state) == 0)
    let more = scrollbackCorpus(lines: 800, columns: columns)
    vt.feed(more)
    reference.feed(more)
    #expect(vt.state.scrollbackStatistics.recycleRestores > 0)
    #expect(historyFingerprint(vt.state) == historyFingerprint(reference.state))
    #expect(vt.state.grid.historyEvicted == reference.state.grid.historyEvicted)
    #expect(vt.lines == reference.lines)
    #expect(vt.state.grid.checkInvariants() == true)
  }

  @Test
  func `reflow and compaction read compressed history faithfully`() {
    var vt = VT(50, 6)
    var reference = VT(50, 6)
    reference.state.setScrollbackCompression(false)
    let corpus = scrollbackCorpus(lines: 400, columns: 50)
    vt.feed(corpus)
    reference.feed(corpus)
    #expect(compressAll(&vt.state) > 0)
    vt.state.compactGraphemes()
    reference.state.compactGraphemes()
    #expect(vt.state.scrollbackStatistics.compactionRestores > 0)
    #expect(historyFingerprint(vt.state) == historyFingerprint(reference.state))
    #expect(compressAll(&vt.state) > 0)
    for (columns, rows) in [(37, 6), (81, 9), (50, 6)] {
      vt.state.resize(columns: columns, rows: rows)
      reference.state.resize(columns: columns, rows: rows)
      #expect(
        historyFingerprint(vt.state) == historyFingerprint(reference.state),
        "\(columns)x\(rows)"
      )
      #expect(vt.lines == reference.lines)
      #expect(compressAll(&vt.state) > 0)
    }
    #expect(vt.state.grid.checkInvariants() == true)
  }

  @Test
  func `alternate screen keeps primary history compressible`() {
    var vt = VT(40, 5)
    vt.feed(scrollbackCorpus(lines: 300, columns: 40))
    let before = historyFingerprint(vt.state)
    vt.feed("\(CSI)?1049h")
    #expect(compressAll(&vt.state) > 0)
    // Selection text addresses the alternate screen; history and the
    // primary dump do not.
    #expect(
      historyFingerprint(vt.state).prefix(before.count - 2)
        == before.dropLast(2)
    )
    vt.feed("alternate\r\n\(CSI)?1049l")
    #expect(historyFingerprint(vt.state) == before)
    #expect(vt.state.scrollbackStatistics.restores == 0)
  }

  @Test
  func `links in compressed history keep their targets and slots`() {
    var vt = VT(30, 4)
    var reference = VT(30, 4)
    reference.state.setScrollbackCompression(false)
    var corpus = ""
    for i in 0 ..< 300 {
      corpus += "\(ESC)]8;;https://h/\(i)\(ESC)\\L\(i)\(ESC)]8;;\(ESC)\\\r\n"
    }
    vt.feed(String(corpus.prefix(corpus.count / 2)))
    reference.feed(String(corpus.prefix(corpus.count / 2)))
    #expect(compressAll(&vt.state) > 0)
    // Slot reclamation scans cold history without promoting it.
    vt.feed(String(corpus.dropFirst(corpus.count / 2)))
    reference.feed(String(corpus.dropFirst(corpus.count / 2)))
    let first = vt.state.firstAbsoluteRow
    for row in first ..< first + vt.state.addressableRows {
      let point = TerminalPoint(row: row, column: 0)
      #expect(
        vt.state.link(at: point)?.url == reference.state.link(at: point)?.url,
        "row \(row)"
      )
    }
  }

  @Test
  func `failures keep a valid resident source`() {
    for fault in 0 ..< 3 {
      var vt = VT(40, 4)
      vt.feed(scrollbackCorpus(lines: 300, columns: 40))
      let before = historyFingerprint(vt.state)
      var faults = ScrollbackFaults()
      switch fault {
      case 0: faults.failEncode = true
      case 1: faults.failPayloadAllocation = true
      default: faults.failReclaim = true
      }
      vt.state.grid.scrollbackFaults = faults
      compressAll(&vt.state)
      let stats = vt.state.scrollbackStatistics
      #expect(stats.compressedUnits == 0, "fault \(fault)")
      #expect(stats.unprofitableAttempts + stats.failedAttempts > 0)
      #expect(historyFingerprint(vt.state) == before)
      #expect(vt.state.grid.checkInvariants() == true)
      vt.state.grid.scrollbackFaults = ScrollbackFaults()
      if fault == 0 {
        // Unprofitable units are not retried until their content changes.
        #expect(compressAll(&vt.state) == 0)
      } else {
        #expect(compressAll(&vt.state) > 0)
        #expect(historyFingerprint(vt.state) == before)
      }
    }
  }

  @Test
  func `incompressible history settles without repeated attempts`() {
    var grid = Grid(columns: 64, rows: 2, historyLimitBytes: 64 * 16 * 500)
    var random = SystemRandomNumberGenerator()
    for _ in 0 ..< 400 {
      for x in 0 ..< 64 {
        grid[x, 1] = Cell(
          glyph: UInt32.random(in: 0x4E00 ... 0x9FFF, using: &random),
          attributes: CellAttributes(
            foreground: .rgb(.random(in: 0 ... 255), .random(in: 0 ... 255), 1),
            background: .rgb(.random(in: 0 ... 255), 2, .random(in: 0 ... 255)),
            flags: CellFlags(rawValue: .random(in: 0 ... 0x3FF)),
            link: .random(in: 0 ... 255)
          ),
          width: 1
        )
      }
      grid.scrollUpIntoHistory(count: 1, bottom: 1, fill: .blank)
    }
    #expect(compressAll(&grid) == 0)
    let attempts = grid.scrollbackStatistics().unprofitableAttempts
    #expect(attempts > 0)
    var budget = ScrollbackMaintenanceBudget()
    budget.maximumCandidates = 1 << 20
    #expect(
      grid.maintainScrollback(protecting: 0 ..< 0, budget: budget) == .idle
    )
    #expect(grid.scrollbackStatistics().unprofitableAttempts == attempts)
  }

  @Test
  func `viewport, recent captures and the eviction horizon stay warm`() {
    var vt = VT(40, 10, scrollback: 40 * 16 * 2_000)
    vt.feed(scrollbackCorpus(lines: 1_000, columns: 40))
    vt.state.scrollViewport(by: 500)
    let top = vt.state.grid.historyCount - 500
    compressAll(&vt.state)
    for index in top ..< top + 10 {
      #expect(vt.state.grid.historyUnitStates(index).allSatisfy { $0 == 0 })
    }
    #expect(vt.state.scrollbackStatistics.protectedUnitBytes > 0)
    // Captures never restore beyond what they display.
    let screen = vt.state.captureOwnedScreen()
    #expect(screen.rows == 10)
    #expect(vt.state.scrollbackStatistics.restores == 0)
    // A full ring keeps its next eviction rows warm.
    var full = VT(40, 4, scrollback: 40 * 16 * 300)
    full.feed(scrollbackCorpus(lines: 600, columns: 40))
    #expect(full.state.grid.historyCount == full.state.grid.historyCapacity)
    #expect(compressAll(&full.state) > 0)
    #expect(full.state.grid.historyUnitStates(0) == [0])
  }

  @Test
  func `compression changes no generations, damage or search state`() {
    var vt = VT(40, 5)
    vt.feed(scrollbackCorpus(lines: 300, columns: 40))
    vt.state.search("compiling")
    _ = vt.state.takeDamage()
    let addressing = vt.state.addressingGeneration
    let matches = vt.state.searchMatches
    let selected = vt.state.searchSelected
    #expect(compressAll(&vt.state) > 0)
    #expect(vt.state.takeDamage().isEmpty)
    #expect(vt.state.addressingGeneration == addressing)
    #expect(vt.state.searchMatches == matches)
    #expect(vt.state.searchSelected == selected)
    _ = vt.state.scrollbackCells(at: 3)
    #expect(vt.state.takeDamage().isEmpty)
    #expect(vt.state.addressingGeneration == addressing)
  }

  @Test
  func `turning compression off keeps cold history readable`() {
    var vt = VT(40, 5)
    vt.feed(scrollbackCorpus(lines: 300, columns: 40))
    let before = historyFingerprint(vt.state)
    let compressed = compressAll(&vt.state)
    #expect(compressed > 0)
    vt.state.setScrollbackCompression(false)
    #expect(!vt.state.scrollbackCompression.effective)
    #expect(vt.state.scrollbackCompression.fallbackReason != nil)
    #expect(vt.state.maintainScrollback() == .disabled)
    #expect(vt.state.scrollbackStatistics.compressedUnits == compressed)
    #expect(historyFingerprint(vt.state) == before)
  }
}

struct ScrollbackIntegrityTests {
  /// Committed cold state has no resident fallback: corruption traps
  /// before any cell is exposed rather than fabricating content.
  @Test
  func `a corrupted compressed unit fails fast on a promoting read`() async {
    await #expect(processExitsWith: .failure) {
      var vt = VT(40, 4)
      vt.feed(scrollbackCorpus(lines: 300, columns: 40))
      _ = compressAll(&vt.state)
      precondition(vt.state.grid.corruptFirstScrollbackPayloadForTesting())
      for index in 0 ..< vt.state.scrollbackCount {
        _ = vt.state.scrollbackCells(at: index).count
      }
    }
  }

  @Test
  func `a corrupted compressed unit fails fast on a preserved scan`() async {
    await #expect(processExitsWith: .failure) {
      var vt = VT(40, 4)
      vt.feed(scrollbackCorpus(lines: 300, columns: 40))
      _ = compressAll(&vt.state)
      precondition(vt.state.grid.corruptFirstScrollbackPayloadForTesting())
      vt.state.search("compiling")
    }
  }

  @Test
  func `intact compressed units all verify during scans`() {
    var vt = VT(40, 4)
    vt.feed(scrollbackCorpus(lines: 300, columns: 40))
    #expect(compressAll(&vt.state) > 1)
    // Without corruption every unit decodes and verifies.
    vt.state.search("compiling")
    #expect(!vt.state.searchMatches.isEmpty)
    #expect(vt.state.scrollbackStatistics.restores == 0)
  }
}
