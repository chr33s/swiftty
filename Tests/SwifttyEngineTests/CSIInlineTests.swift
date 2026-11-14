@testable import SwifttyEngine
import Testing

/// Byte-at-a-time feeding never completes a CSI in one buffer, so it is the
/// reference for the inline CSI parser.
struct CSIInlineTests {
  @Test(arguments: [1, 2, 3, 4])
  func `inline CSI matches byte-at-a-time parsing`(seed: UInt64) {
    var state = seed
    func next(_ bound: Int) -> Int {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int((state >> 33) % UInt64(bound))
    }
    let pieces = [
      "\(CSI)m\(CSI)?1h\(CSI)H", "\(CSI)1;2;3;4:3;31m",
      "\(CSI)38:5:24;48:2:125:136:147m", "\(CSI)58;5;44;2m",
      "\(CSI)m\(CSI)10A\(CSI)3E\(CSI)2K",
      "\(CSI)39m\(CSI)10`a\(CSI)100b\(CSI)?1l", "\(CSI):5m", "\(CSI)1?m",
      "\(CSI)2\u{7F}J", "\(CSI)3\nB", "\(CSI) q", "\(CSI)2 q", "\(CSI)!p",
      "\(CSI)1 !q", "\(CSI)>c", "\(CSI)6n", "\(CSI)?25$p", "\(CSI)99999999H",
      String(
        repeating: "\(CSI)" + String(repeating: "1;", count: 30) + "m",
        count: 1
      ), "\(CSI)\u{E9}m", "text ", "漢", "\r\n", "\(ESC)7", "\(ESC)8",
    ]
    var input = ""
    for _ in 0 ..< 2000 { input += pieces[next(pieces.count)] }
    let bytes = Array(input.utf8)
    var fast = VT(20, 6)
    var reference = VT(20, 6)
    fast.feed(bytes: bytes)
    for b in bytes { reference.feed(bytes: [b]) }
    #expect(fast.lines == reference.lines)
    #expect(fast.cursor == reference.cursor)
    #expect(fast.state.cursor == reference.state.cursor)
    #expect(fast.state.modes == reference.state.modes)
    #expect(fast.takeOutput() == reference.takeOutput())
    for y in 0 ..< 6 {
      for x in 0 ..< 20 { #expect(fast.cell(x, y) == reference.cell(x, y)) }
    }
  }
}
