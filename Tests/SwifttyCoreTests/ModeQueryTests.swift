@testable import SwifttyCore
import Testing
import TestSupport

struct ModeQueryTests {
  @Test(arguments: ["", "4;20", "4:20", ";4", "4;", "4;;20"], [false, true])
  func
    `mode queries use the first semicolon parameter and ignore colon parameters`(
      _ parameters: String,
      _ fragmented: Bool
    )
  {
    for marker in ["", "?"] {
      var vt = VT(8, 3)
      vt.feed("content\(CSI)4h\(CSI)2;3H\(CSI)1;31m")
      let cursor = vt.state.cursor
      let modes = vt.state.modes
      _ = vt.state.takeDamage()
      let query = "\(CSI)\(marker)\(parameters)$p"
      if fragmented {
        for byte in query.utf8 { vt.feed(bytes: [byte]) }
      } else {
        vt.feed(query)
      }
      let first =
        Int(
          parameters.split(separator: ";", omittingEmptySubsequences: false)
            .first ?? ""
        ) ?? 0
      let status = marker.isEmpty && first == 4 ? 1 : 0
      let expected =
        parameters.contains(":") ? "" : "\(CSI)\(marker)\(first);\(status)$y"
      #expect(TestFixture(vt.takeOutput()) == TestFixture(expected))
      #expect(vt.state.cursor == cursor)
      #expect(vt.state.modes == modes)
      let damage = vt.state.takeDamage()
      #expect(damage.isEmpty)
      let mode = marker.isEmpty ? 4 : 7
      vt.feed("\(CSI)\(marker)\(mode)$p")
      #expect(
        TestFixture(vt.takeOutput())
          == TestFixture("\(CSI)\(marker)\(mode);1$y")
      )
      vt.feed("X")
      #expect(vt.cell(2, 1).glyph == 0x58)
      #expect(vt.cell(2, 1).attributes == cursor.pen)
    }
  }

  @Test(
    arguments: [
      ("", 4), ("", 20), ("", 0), ("", 9999), ("?", 7), ("?", 25), ("?", 69),
      ("?", 9999),
    ],
    [(false, false), (false, true), (true, false), (true, true)],
  )
  func `single mode queries report set reset and unknown modes`(
    _ request: (String, Int),
    _ options: (Bool, Bool)
  ) {
    let (marker, mode) = request
    let (enabled, fragmented) = options
    var vt = VT(8, 3)
    vt.feed("\(CSI)\(marker)\(mode)\(enabled ? "h" : "l")")
    let modes = vt.state.modes
    let cursor = vt.state.cursor
    _ = vt.state.takeDamage()
    let query = "\(CSI)\(marker)\(mode)$p"
    if fragmented {
      for byte in query.utf8 { vt.feed(bytes: [byte]) }
    } else {
      vt.feed(query)
    }
    let status = mode == 0 || mode == 9999 ? 0 : enabled ? 1 : 2
    #expect(
      TestFixture(vt.takeOutput())
        == TestFixture("\(CSI)\(marker)\(mode);\(status)$y")
    )
    #expect(vt.state.cursor == cursor)
    #expect(vt.state.modes == modes)
    let damage = vt.state.takeDamage()
    #expect(damage.isEmpty)
  }
}
