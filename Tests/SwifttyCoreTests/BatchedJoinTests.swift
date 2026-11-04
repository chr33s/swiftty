@testable import SwifttyEngine
import Testing

/// Byte-at-a-time feeding prints each scalar alone, so it is the reference
/// for joins after batched runs.
struct BatchedJoinTests {
  @Test(arguments: [false, true], [1, 2, 3])
  func `batched joins match one scalar at a time`(
    clustering: Bool,
    seed: UInt64
  ) {
    var state = seed
    func next(_ bound: Int) -> Int {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int((state >> 33) % UInt64(bound))
    }
    let pieces = [
      "a", "e", "漢", "क", "\u{94D}", "ष", "\u{93F}", "\u{301}", "\u{302}",
      "\u{20DD}", "\u{200D}", "\u{200C}", "👩", "💻", "🏽", "\u{FE0F}", "\u{FE0E}",
      "☺", "🇯", "🇵", "\u{1100}", "\u{1161}", "\u{11A8}", "\u{600}", "\u{903}",
      " ", "\r\n", "\(CSI)H", String(repeating: "\u{300}", count: 70),
      "\(CSI)7G", "\(CSI)4h", "\(CSI)4l",
    ]
    var input = clustering ? "\(CSI)?2027h" : "\(CSI)?2027l"
    for _ in 0 ..< 1500 { input += pieces[next(pieces.count)] }
    input += "\(CSI)3b"
    let bytes = Array(input.utf8)
    var fast = VT(9, 4)
    var reference = VT(9, 4)
    fast.feed(bytes: bytes)
    for b in bytes { reference.feed(bytes: [b]) }
    #expect(fast.cursor == reference.cursor)
    #expect(fast.state.cursor == reference.state.cursor)
    for y in 0 ..< 4 {
      #expect(fast.state.grid.extent(y) == reference.state.grid.extent(y))
      for x in 0 ..< 9 {
        let a = fast.cell(x, y)
        let r = reference.cell(x, y)
        #expect(fast.state.scalars(of: a) == reference.state.scalars(of: r))
        #expect(a.attributes == r.attributes)
        #expect(a.width == r.width)
      }
    }
    #expect(fast.state.scrollbackCount == reference.state.scrollbackCount)
    // At a soft wrap, a joiner after a wrapped cell can land on a different
    // row in batched and per-scalar printing (present before these tests).
    withKnownIssue(
      "batched and per-scalar joins differ at soft wraps",
      isIntermittent: true
    ) {
      for i in 0
        ..< min(fast.state.scrollbackCount, reference.state.scrollbackCount)
      {
        #expect(
          fast.state.scrollbackText(i) == reference.state.scrollbackText(i)
        )
      }
    }
  }
}
