@testable import SwifttyEngine
import Testing
import TestSupport

/// REP must match printing the character itself `n` times.
struct RepeatTests {
  @Test(
    arguments: [
      "", "\(CSI)?7l", "\(CSI)4h", "\(ESC)(0", "\(CSI)41;1m",
      "\(CSI)3;8r\(CSI)?69h\(CSI)2;9s",
    ]
    .map(TestFixture.init),
    [1, 5, 13, 300]
  )
  func `REP matches the repeated text`(setup: TestFixture<String>, count: Int) {
    let setup = setup.value
    for prefix in ["", "漢字\(CSI)1G", "\(CSI)2;11H"] {
      var rep = VT(12, 4)
      var literal = VT(12, 4)
      rep.feed(setup + prefix + "q\(CSI)\(count)b!")
      literal.feed(
        setup + prefix + String(repeating: "q", count: count + 1) + "!"
      )
      #expect(rep.lines == literal.lines)
      #expect(rep.cursor == literal.cursor)
      for y in 0 ..< 4 {
        #expect(rep.state.grid.extent(y) == literal.state.grid.extent(y))
        for x in 0 ..< 12 { #expect(rep.cell(x, y) == literal.cell(x, y)) }
      }
    }
  }
}
