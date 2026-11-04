@testable import SwifttyEngine
import Testing

/// Byte-at-a-time feeding never takes the CR LF fast path, so it is the
/// reference for deferred clears.
struct DeferredClearTests {
  private static func input(seed: UInt64, lines: Int) -> [UInt8] {
    var state = seed
    func next(_ bound: Int) -> Int {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int((state >> 33) % UInt64(bound))
    }
    let pieces = [
      "x", "word ", "漢字", "e\u{301}", "👩\u{200D}💻", "\(CSI)41m", "\(CSI)0m",
      "\(CSI)1;32m", "\t", "\(CSI)K",
    ]
    var s = ""
    for _ in 0 ..< lines {
      for _ in 0 ..< next(14) {
        s +=
          next(3) == 0
          ? pieces[next(pieces.count)] : String(repeating: "a", count: next(9))
      }
      // Bare LF, and a coloured CR LF whose fill is not blank.
      switch next(6) {
      case 0: s += "\n"
      case 1: s += "\(CSI)44m\r\n\(CSI)0m"
      default: s += "\r\n"
      }
    }
    return Array(s.utf8)
  }

  private static func expectSame(
    _ actual: borrowing VT,
    _ reference: borrowing VT,
    columns: Int,
    rows: Int
  ) {
    for y in 0 ..< rows {
      #expect(actual.state.grid.extent(y) == reference.state.grid.extent(y))
      for x in 0 ..< columns {
        let a = actual.cell(x, y)
        let r = reference.cell(x, y)
        #expect(actual.state.scalars(of: a) == reference.state.scalars(of: r))
        #expect(a.attributes == r.attributes)
        #expect(a.width == r.width)
      }
    }
    #expect(actual.state.scrollbackCount == reference.state.scrollbackCount)
    for index in 0 ..< actual.state.scrollbackCount {
      #expect(
        actual.state.scrollbackText(index)
          == reference.state.scrollbackText(index)
      )
      let a = actual.state.scrollbackCells(at: index)
      let r = reference.state.scrollbackCells(at: index)
      #expect(a.count == r.count)
      for x in 0 ..< min(a.count, r.count) {
        #expect(a[x].attributes == r[x].attributes)
        #expect(a[x].width == r[x].width)
      }
    }
    #expect(actual.cursor == reference.cursor)
  }

  @Test(arguments: [0, 1, 2, 3, 5, 64], [1, 7, 4096])
  func `chunked output matches byte-at-a-time output`(chunk: Int, seed: UInt64)
  {
    let columns = 12
    let rows = 4
    let bytes = Self.input(seed: seed, lines: 300)
    // ~20 history rows, so recycled rows hold old content.
    var actual = VT(columns, rows, scrollback: 4096)
    var reference = VT(columns, rows, scrollback: 4096)
    if chunk == 0 {
      actual.feed(bytes: bytes)
    } else {
      var i = 0
      while i < bytes.count {
        actual.feed(bytes: Array(bytes[i ..< min(i + chunk, bytes.count)]))
        i += chunk
      }
    }
    for b in bytes { reference.feed(bytes: [b]) }
    Self.expectSame(actual, reference, columns: columns, rows: rows)
  }

  @Test
  func `a shorter line over a recycled row leaves the rest blank`() {
    var vt = VT(10, 2, scrollback: 4096)
    for _ in 0 ..< 40 { vt.feed("\(CSI)41m0123456789\(CSI)0m\r\n") }
    vt.feed("ab\r\ncd\r\n\nxy")
    #expect(vt.lines == ["", "xy"])
    #expect(vt.state.scrollbackText(vt.state.scrollbackCount - 1) == "cd")
    for x in 2 ..< 10 { #expect(vt.cell(x, 1).isBlank) }
    for x in 0 ..< 10 { #expect(vt.cell(x, 0).isBlank) }
  }
}
