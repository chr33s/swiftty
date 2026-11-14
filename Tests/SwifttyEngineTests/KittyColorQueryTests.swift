@testable import SwifttyEngine
import Testing
import TestSupport

struct KittyColorQueryTests {
  struct Unknown: Sendable {
    let key: String
    let encoded: String
  }

  @Test(
    arguments: [
      Unknown(key: "bogus", encoded: "Ym9ndXM"),
      Unknown(key: "nonsense", encoded: "bm9uc2Vuc2U"),
      Unknown(key: "a b", encoded: "YSBi"),
      Unknown(key: "\u{7F}", encoded: "fw"), Unknown(key: "é", encoded: "w6k"),
      Unknown(key: "visual_bell", encoded: "dmlzdWFsX2JlbGw"),
    ],
    [false, true]
  )
  func unknownFieldsAreEncodedAndOrdered(field: Unknown, fragmented: Bool) {
    for terminator in ["\u{07}", "\u{1B}\\"] {
      var vt = VT()
      vt.feed("\u{1B}]21;foreground=#102030\u{1B}\\")
      let request =
        "\u{1B}]21;\(field.key)=?;foreground=?;cursor_text=?;\(field.key)=?"
        + terminator
      if fragmented {
        for byte in request.utf8 { vt.feed(bytes: [byte]) }
      } else {
        vt.feed(request)
      }
      let expected =
        "\u{1B}]21;unknown=\(field.encoded);foreground=rgb:1010/2020/3030;cursor_text=;unknown=\(field.encoded)"
        + terminator
      #expect(TestFixture(vt.takeOutput()) == TestFixture(expected))
      // A known color with no fixed value is distinct from an unknown
      // field, and query replies must not mutate the palette.
      #expect(vt.state.palette.foreground == 0x102030)
      #expect(vt.state.palette.cursorText == nil)
    }
  }
}
