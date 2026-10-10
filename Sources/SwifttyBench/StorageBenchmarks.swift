import Foundation
import SwifttyCore

@inline(never)
private func consumeStorageResult(_ checksum: UInt64) {
  precondition(checksum != UInt64.max)
}

private func measureStorage(
  _ name: String,
  size: Int,
  layout: String,
  iterations: Int,
  warmupIterations: Int = 10,
  operation: () -> UInt64
) {
  var checksum: UInt64 = 0
  for _ in 0 ..< warmupIterations { checksum &+= operation() }
  let start = DispatchTime.now().uptimeNanoseconds
  for _ in 0 ..< iterations { checksum &+= operation() }
  let elapsed = DispatchTime.now().uptimeNanoseconds - start
  consumeStorageResult(checksum)
  row(
    name,
    [
      ("size", "\(size)"), ("layout", layout), ("iterations", "\(iterations)"),
      ("ns/op", fmt(Double(elapsed) / Double(iterations), 1)),
      ("checksum", "\(checksum)"),
    ]
  )
}

/// Operation curves isolate storage costs from parser and renderer setup.
func runStorageBenchmarks() {
  guard selected("storage") else { return }
  for size in [16, 63, 64, 65, 256] {
    var grid = Grid(columns: 80, rows: size, historyLimitBytes: size * 80 * 16)
    for y in 0 ..< size {
      grid[0, y] = Cell(glyph: 65, attributes: .default, width: 1)
    }
    measureStorage(
      "row-rotation",
      size: size,
      layout: "chunked",
      iterations: 10_000
    ) {
      grid.scrollUp(top: 0, bottom: size - 1, count: size / 2, fill: .blank)
      return UInt64(grid[0, 0].glyph)
    }
    for head in [0, size / 2, size - 1] {
      var history = Grid(
        columns: 80,
        rows: size,
        historyLimitBytes: size * 80 * 16
      )
      for _ in 0 ..< (size + head) {
        history.scrollUpIntoHistory(count: 1, fill: .blank)
      }
      measureStorage(
        "history-eviction",
        size: size,
        layout: "wrapped-\(head)",
        iterations: 10_000,
        warmupIterations: size
      ) {
        history.scrollUpIntoHistory(count: 1, fill: .blank)
        return UInt64(history.historyEvicted)
      }
    }
    var state = TerminalState(columns: size, rows: 4, scrollbackLimitBytes: 0)
    var parser = Parser()
    let text = Array(
      ("\u{1B}[?2027h" + String(repeating: "e\u{301}", count: size * 4)).utf8
    )
    parser.consume(text.span, into: &state)
    measureStorage(
      "grapheme-compaction",
      size: size * 4,
      layout: "live",
      iterations: 100
    ) {
      state.compactGraphemes()
      return UInt64(state.grid[size - 1, 3].glyph)
    }
    var builder = SnapshotBuilder()
    measureStorage(
      "snapshot-reuse",
      size: size * 4,
      layout: "pooled-unchanged",
      iterations: 1000
    ) {
      let snapshot = builder.build(from: &state)
      return snapshot.sequence &+ UInt64(snapshot.cells(row: 0)[0].glyph)
    }
    let manager = CoreTextFontManager()
    let font = manager.resolve(FontDescriptor())
    let shaper = Shaper()
    let input = Array(repeating: UInt32(65), count: size)
    _ = shaper.shape(input, style: [], font: font)
    measureStorage(
      "shaping-cache-hit",
      size: size,
      layout: "warm",
      iterations: 1000
    ) { UInt64(shaper.shape(input, style: [], font: font).count) }
    var miss = 0
    let inputs = (0 ..< 110)
      .map { offset in
        [UInt32(0x400 + offset)] + Array(repeating: UInt32(65), count: size - 1)
      }
    measureStorage(
      "shaping-cache-miss",
      size: size,
      layout: "unique",
      iterations: 100
    ) {
      let glyphs = shaper.shape(inputs[miss], style: [], font: font)
      miss += 1
      return UInt64(glyphs.count)
    }
  }
}
