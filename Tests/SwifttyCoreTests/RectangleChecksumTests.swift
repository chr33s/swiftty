import TestSupport
@testable import SwifttyCore
@testable import SwifttyEngine
import Testing

/// DECRQCRA and XTCHECKSUM, checked against Ghostty's `xt_checksum` and
/// stream tests.
struct RectangleChecksumTests {
  typealias Flags = TerminalState.ChecksumFlags

  private func terminal(_ text: String = "") -> VT {
    var vt = VT(10, 5)
    vt.state.rectangleChecksumsEnabled = true
    vt.feed(text)
    return vt
  }

  private func sum(
    _ vt: inout VT,
    _ flags: Flags = .positive,
    top: Int = 0,
    left: Int = 0,
    bottom: Int = 0,
    right: Int = 0
  ) -> UInt16 {
    vt.state.checksumFlags = flags
    return vt.state.rectangleChecksum(
      top: top,
      left: left,
      bottom: bottom,
      right: right
    )
  }

  // MARK: Gating and replies

  @Test
  func `DECRQCRA is silent unless enabled`() {
    var vt = VT(80, 24)
    vt.feed("hello\u{1B}[1;1;1;1;1;5*y\u{1B}[1#y")
    #expect(vt.takeOutput() == "")
    #expect(vt.state.checksumFlags == [])
  }

  @Test
  func `DECRQCRA replies and XTCHECKSUM selects until reset`() {
    var vt = VT(80, 24)
    vt.state.rectangleChecksumsEnabled = true
    // "hello" sums to 0x214, which the DEC checksum negates.
    vt.feed("hello\u{1B}[3;1;1;1;1;5*y")
    #expect(vt.takeOutput() == "\u{1B}P3!~FDEC\u{1B}\\")
    vt.feed("\u{1B}[1#y\u{1B}[4;1;1;1;1;5*y")
    #expect(vt.takeOutput() == "\u{1B}P4!~0214\u{1B}\\")
    vt.feed("\u{1B}chello\u{1B}[5;1;1;1;1;5*y")
    #expect(vt.takeOutput() == "\u{1B}P5!~FDEC\u{1B}\\")
  }

  // Arguments omit ESC so test output stays free of terminal controls.
  @Test(arguments: [
    ("[7;1;2;3;4;5*y", true), ("[7*y", true), ("[*y", true),
    ("[1;1;2;3*y", true), ("[1;1;1;1;1;1;1*y", false), ("[1;1;1;1;1;1y", false),
    ("[1;1;1;1;1;1\"y", false),
  ])
  func `DECRQCRA accepts at most six parameters`(
    _ request: String,
    _ replies: Bool
  ) {
    var vt = terminal()
    vt.feed("\u{1B}" + request)
    #expect(vt.takeOutput().hasPrefix("\u{1B}P") == replies)
  }

  @Test(
    arguments: [
      ("[#y", Flags()), ("[0#y", Flags()),
      ("[5#y", Flags([.positive, .noTrim])), ("[48#y", Flags.full),
      ("[1;2#y", Flags.undrawn),
    ] as [(String, Flags)]
  )
  func `XTCHECKSUM keeps known bits and ignores extra parameters`(
    _ request: String,
    _ expected: Flags
  ) {
    var vt = terminal()
    vt.feed("\u{1B}[8#y")
    vt.feed("\u{1B}" + request)
    #expect(vt.state.checksumFlags == expected)
  }

  @Test
  func `rectangle-checksum-report enables replies for sessions`() {
    #expect(!Configuration().sessionConfiguration().rectangleChecksumsEnabled)
    let on = Configuration.configured([("rectangle-checksum-report", "true")])
    #expect(on.sessionConfiguration().rectangleChecksumsEnabled)
    let reset = Configuration.configured([
      ("rectangle-checksum-report", "true"), ("rectangle-checksum-report", ""),
    ])
    #expect(!reset.rectangleChecksumReport)
  }

  @Test
  func `configured checksum defaults survive reset`() {
    var vt = terminal()
    vt.state.defaultChecksumFlags = [.positive, .full]
    #expect(vt.state.checksumFlags == [.positive, .full])
    vt.feed("\u{1B}[0#y\u{1B}c")
    #expect(vt.state.checksumFlags == [.positive, .full])
  }

  @Test
  func `reply ids are clamped to sixteen bits`() {
    var vt = terminal("a")
    vt.feed("\u{1B}[99999;1;1;1;1;1*y")
    #expect(vt.takeOutput() == "\u{1B}P65535!~FF9F\u{1B}\\")
  }

  // MARK: Rectangles

  @Test
  func `defaults bounds and clamping`() {
    var vt = terminal("abc\r\ndef\r\nghi")
    let abc = UInt16(0x61 + 0x62 + 0x63)
    let all = abc + 0x64 + 0x65 + 0x66 + 0x67 + 0x68 + 0x69
    #expect(sum(&vt) == all)
    #expect(
      sum(&vt, top: 2, left: 2, bottom: 3, right: 3) == 0x65 + 0x66 + 0x68
        + 0x69
    )
    #expect(sum(&vt, top: 2, left: 3, bottom: 99, right: 99) == 0x66 + 0x69)
    #expect(sum(&vt, top: 3, bottom: 2) == 0)
    #expect(sum(&vt, left: 3, right: 2) == 0)
    #expect(sum(&vt, [], left: 3, right: 2) == 0)
  }

  @Test
  func `origin mode makes rectangles relative to the margins`() {
    var vt = terminal("abc\r\ndef\r\nghi")
    vt.feed("\u{1B}[?69h\u{1B}[2;4r\u{1B}[3;9s\u{1B}[?6h")
    // The default rectangle starts at the margins but runs to the screen edge.
    #expect(sum(&vt) == 0x66 + 0x69)
    #expect(sum(&vt, top: 1, left: 1, bottom: 1, right: 1) == 0x66)
  }

  // MARK: Cells

  @Test
  func `DEC sums trim blanks and skip undrawn cells`() {
    var vt = terminal("a b")
    let ab = UInt16(0x61 + 0x62)
    #expect(sum(&vt, [], top: 1, bottom: 1) == 0 &- ab)
    #expect(sum(&vt, top: 1, bottom: 1) == ab)
    #expect(sum(&vt, [.positive, .noTrim], top: 1, bottom: 1) == ab + 0x20 * 8)
    #expect(sum(&vt, [.positive, .undrawn], top: 1, bottom: 1) == ab)
  }

  @Test
  func `DEC sums keep only the rectangle's first space`() {
    var vt = terminal(" a\r\n b")
    #expect(sum(&vt) == 0x20 + 0x61 + 0x62)
  }

  @Test
  func `video attributes add to each cell`() {
    var vt = terminal("\u{1B}[1;4ma\u{1B}[0;7;5m \u{1B}[0;8m\u{1B}[1\"qb")
    #expect(
      sum(&vt, top: 1, bottom: 1) == 0x61 + 0x80 + 0x10 + 0x20 + 0x20 + 0x40
        + 0x62 + 0x08 + 0x04
    )
    #expect(
      sum(&vt, [.positive, .noAttributes], top: 1, bottom: 1) == 0x61 + 0x62
    )
  }

  @Test(arguments: ["3", "9", "2", "21"])
  func `extended attributes keep a space`(_ sgr: String) {
    var vt = terminal("a\u{1B}[\(sgr)m ")
    let attributes: UInt16 = sgr == "21" ? 0x10 : 0
    #expect(sum(&vt, top: 1, bottom: 1) == 0x61 + 0x20 + attributes)
  }

  @Test
  func `DEC sums use 8-bit values`() {
    var vt = terminal("é€")
    #expect(sum(&vt, top: 1, bottom: 1) == 0x69 + 0x1B)
    #expect(sum(&vt, [.positive, .full], top: 1, bottom: 1) == 0xE9 + 0x20AC)
  }

  @Test
  func `wide characters count their spacer`() {
    var vt = terminal("橋")
    #expect(sum(&vt, top: 1, bottom: 1) == 0x1B + 0x1B)
    #expect(sum(&vt, [.positive, .full], top: 1, bottom: 1) == 0x6A4B)
  }

  @Test
  func `combining marks count only in untrimmed DEC sums`() {
    var vt = terminal("e\u{301}")
    #expect(sum(&vt, top: 1, bottom: 1, right: 1) == 0x65)
    #expect(
      sum(&vt, [.positive, .noTrim], top: 1, bottom: 1, right: 1) == 0x65
        + 0x301
    )
    #expect(
      sum(&vt, [.positive, .noTrim, .full], top: 1, bottom: 1, right: 1) == 0x65
    )
  }
}
