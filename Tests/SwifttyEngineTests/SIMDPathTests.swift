@testable import SwifttyEngine
import Testing

/// The NEON paths in `CTerminalSIMD`: the parser's payload scanners and the
/// narrow block store in `printFresh`.
struct SIMDPathTests {
  private static func bytes(seed: UInt64, count: Int) -> [UInt8] {
    var state = seed
    return (0 ..< count)
      .map { _ in
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        // Mostly printable, with a few controls and high bytes.
        switch (state >> 33) % 64 {
        case 0: return UInt8((state >> 40) % 0x20)
        case 1: return 0x80 | UInt8((state >> 40) % 0x80)
        default: return 0x20 + UInt8((state >> 40) % 0x5F)
        }
      }
  }

  @Test(arguments: [1, 7, 4096] as [UInt64])
  func `scanners find the first stop byte exactly`(seed: UInt64) {
    let data = Self.bytes(seed: seed, count: 400)
    data.withUnsafeBufferPointer { buffer in
      let p = buffer.baseAddress!
      for start in 0 ..< 80 {
        for end in [
          start, start + 1, start + 15, start + 16, start + 63, start + 64,
          start + 65, start + 200, 400,
        ] where end >= start && end <= 400 {
          var control = start
          while control < end, p[control] >= 0x20 { control += 1 }
          var payload = start
          while payload < end, p[payload] >= 0x20, p[payload] < 0x80 {
            payload += 1
          }
          let foundControl = Parser.scanNonControl(p, from: start, to: end)
          #expect(foundControl == control, "start \(start) end \(end)")
          let foundPayload = Parser.scanPayload(p, from: start, to: end)
          #expect(foundPayload == payload, "start \(start) end \(end)")
        }
      }
    }
  }

  /// Narrow text below U+0300, in runs that reach the block store, with
  /// the pictographs it must leave to the scalar path at every position
  /// of an eight-scalar block, followed by scalars that join them.
  private static let narrowLines: [String] = {
    var lines: [String] = []
    for mark in ["\u{A9}", "\u{AE}"] {
      for position in 0 ..< 10 {
        let before = String(repeating: "é", count: position)
        for join in ["\u{FE0F}", "\u{200D}\u{2764}\u{FE0F}", "\u{301}", "x"] {
          lines.append(before + mark + join + "àbçdéfghïjklmñöp")
        }
      }
    }
    // Runs that end at the last columns, and long runs across a wrap.
    lines.append(String(repeating: "àéîõü", count: 9))
    lines.append(String(repeating: "ß", count: 31) + "\u{301}")
    return lines
  }()

  @Test(arguments: [20, 31, 32])
  func `narrow blocks match byte-at-a-time output`(columns: Int) {
    var whole = VT(columns, 4, scrollback: 4096)
    var reference = VT(columns, 4, scrollback: 4096)
    for line in Self.narrowLines {
      let bytes = Array((line + "\r\n").utf8)
      whole.feed(bytes: bytes)
      for b in bytes { reference.feed(bytes: [b]) }
      for y in 0 ..< 4 {
        for x in 0 ..< columns {
          let a = whole.cell(x, y)
          let r = reference.cell(x, y)
          let scalars = whole.state.scalars(of: a)
          let expected = reference.state.scalars(of: r)
          #expect(scalars == expected, "\(line) at \(x), \(y)")
          #expect(a.width == r.width, "\(line) at \(x), \(y)")
          #expect(a.attributes == r.attributes, "\(line) at \(x), \(y)")
        }
      }
      let lines = (whole.lines, whole.state.scrollbackCount)
      #expect(lines.0 == reference.lines)
      #expect(lines.1 == reference.state.scrollbackCount)
    }
  }
}
