@testable import SwifttyEngine
import Testing

/// Byte-at-a-time feeding never takes the CR LF fast path, so it is the
/// reference for deferred clears.
struct DeferredClearTests {
  private static let mixedPieces = [
    "x", "word ", "漢字", "e\u{301}", "👩\u{200D}💻", "\(CSI)41m", "\(CSI)0m",
    "\(CSI)1;32m", "\t", "\(CSI)K",
  ]

  /// UTF-8 runs that write over recycled rows: long narrow and wide runs,
  /// wide characters at the last column, Extend runs, and joins.
  private static let utf8Pieces = [
    "éèê", "漢字東京", "日", "a\u{300}\u{301}\u{302}", "e\u{301}", "ö ", "👍🏽",
    "\u{200D}", "\u{FE0F}", "\u{301}", "\(CSI)41m", "\(CSI)0m",
    String(repeating: "\u{300}", count: 70), "→│",
  ]

  private static func input(
    seed: UInt64,
    lines: Int,
    pieces: [String] = mixedPieces
  ) -> [UInt8] {
    var state = seed
    func next(_ bound: Int) -> Int {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int((state >> 33) % UInt64(bound))
    }
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

  @Test(arguments: [0, 1, 2, 3, 5, 7, 64], [1, 7, 4096])
  func `UTF-8 runs over recycled rows match byte-at-a-time output`(
    chunk: Int,
    seed: UInt64
  ) {
    let columns = 11
    let rows = 4
    let bytes = Self.input(seed: seed, lines: 300, pieces: Self.utf8Pieces)
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
  func `a shorter UTF-8 line over a recycled row leaves the rest blank`() {
    var vt = VT(10, 2, scrollback: 4096)
    for _ in 0 ..< 40 { vt.feed("漢字漢字漢字漢字漢字\r\n") }
    vt.feed("éa\u{301}\r\n漢\r\n\n日x")
    #expect(vt.lines == ["", "日x"])
    #expect(vt.state.scrollbackText(vt.state.scrollbackCount - 1) == "漢")
    #expect(
      vt.state.scrollbackText(vt.state.scrollbackCount - 2) == "éa\u{301}"
    )
    for x in 3 ..< 10 { #expect(vt.cell(x, 1).isBlank) }
    for x in 0 ..< 10 { #expect(vt.cell(x, 0).isBlank) }
  }

  /// Printable ASCII that soft-wraps across recycled rows, so most scrolls
  /// come from `printASCII`'s wrap; the rest are bare line feeds. Pieces end
  /// mid-row, change the pen, erase and print wide characters.
  private static func wrappingInput(seed: UInt64, runs: Int) -> [UInt8] {
    var state = seed
    func next(_ bound: Int) -> Int {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int((state >> 33) % UInt64(bound))
    }
    // Bare LF and tab take the parser's deferring fast path.
    let pieces = [
      "\(CSI)41m", "\(CSI)0m", "\(CSI)K", "漢", "\t", "\(CSI)3D", "\n", "\n\t",
    ]
    var s = ""
    for _ in 0 ..< runs {
      s += String(repeating: "abcdefghij", count: 4).prefix(1 + next(40))
      if next(3) == 0 { s += pieces[next(pieces.count)] }
    }
    return Array(s.utf8)
  }

  @Test(arguments: [false, true], [1, 7, 4096])
  func `wrapped ASCII over recycled rows matches byte-at-a-time output`(
    alternate: Bool,
    seed: UInt64
  ) {
    let columns = 12
    let rows = 4
    // Fill history and the screen with long lines first.
    var prefix = alternate ? "\(CSI)?1049h" : ""
    for _ in 0 ..< 30 { prefix += "\(CSI)44m0123456789AB\(CSI)0m\r\n" }
    let input = Self.wrappingInput(seed: seed, runs: 200)
    // ~20 history rows, so wraps recycle rows that hold old content.
    var actual = VT(columns, rows, scrollback: 4096)
    var reference = VT(columns, rows, scrollback: 4096)
    actual.feed(prefix)
    reference.feed(prefix)
    // Byte-at-a-time feeding wraps through the same deferring path, so
    // also check that no cell past a row's extent keeps old content.
    var i = 0
    while i < input.count {
      actual.feed(bytes: Array(input[i ..< min(i + 37, input.count)]))
      i += 37
      for y in 0 ..< rows {
        for x in actual.state.grid.extent(y) ..< columns {
          #expect(actual.cell(x, y).isBlank, "row \(y) column \(x)")
        }
      }
    }
    for b in input { reference.feed(bytes: [b]) }
    Self.expectSame(actual, reference, columns: columns, rows: rows)
  }

  @Test(arguments: [false, true])
  func `a line wrapping onto a recycled row leaves the rest blank`(
    alternate: Bool
  ) {
    var vt = VT(10, 2, scrollback: 4096)
    if alternate { vt.feed("\(CSI)?1049h") }
    for _ in 0 ..< 40 { vt.feed("\(CSI)41m0123456789\(CSI)0m\r\n") }
    // The wrap recycles a row; "xy" writes two cells of it.
    vt.feed("abcdefghijxy")
    #expect(vt.lines == ["abcdefghij", "xy"])
    for x in 2 ..< 10 { #expect(vt.cell(x, 1).isBlank) }
    let wrapped = (vt.state.grid.isWrapped(0), vt.state.grid.isWrapped(1))
    #expect(wrapped == (true, false))
  }

  @Test
  func `a coloured line wrapping onto a recycled row fills its background`() {
    var vt = VT(10, 2, scrollback: 4096)
    for _ in 0 ..< 40 { vt.feed("0123456789\r\n") }
    vt.feed("\(CSI)42mabcdefghijxy")
    #expect(vt.lines == ["abcdefghij", "xy"])
    let erased = vt.state.eraseCell
    for x in 2 ..< 10 { #expect(vt.cell(x, 1) == erased) }
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
