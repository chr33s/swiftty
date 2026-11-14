@testable import SwifttyEngine
import Testing
import TestSupport

struct HexColorSpecificationTests {
  @Test(
    arguments: [
      ("#3a7", UInt32(0x30A070)), ("#3A7F90", UInt32(0x3A7F90)),
      ("#3a17f2903", UInt32(0x3A7F90)), ("#3a127f349056", UInt32(0x3A7F90)),
      ("#000", UInt32(0)), ("#fff", UInt32(0xF0F0F0)),
      ("#fffffffff", UInt32(0xFFFFFF)), ("#ffffffffffff", UInt32(0xFFFFFF)),
    ],
    [false, true]
  )
  func hexColorsUseTheMostSignificantComponentBits(
    sample: (String, UInt32),
    fragmented: Bool,
  ) {
    let (color, expected) = sample
    for terminator in ["\u{07}", "\u{1B}\\"] {
      var vt = VT()
      let request =
        "\u{1B}]11;\(color)" + terminator + "\u{1B}]4;1;\(color)" + terminator
        + "\u{1B}]21;cursor_text=\(color)" + terminator
      if fragmented {
        for byte in request.utf8 { vt.feed(bytes: [byte]) }
      } else {
        vt.feed(request)
      }
      #expect(vt.state.palette.background == expected)
      #expect(vt.state.palette.colors[1] == expected)
      #expect(vt.state.palette.cursorText == expected)
      #expect(vt.state.output.isEmpty)
    }
  }

  @Test(arguments: [
    "#", "#1", "#12", "#1234", "#12345", "#1234567", "#12345678", "#1234567890",
    "#12345678901", "#1234567890123", "#ggg", "#+12", "#-12", "#１２３", "#abc ",
    " #abc",
  ])
  func malformedHexColorsLeaveAllThreeTargetsUnchanged(color: String) {
    var vt = VT()
    vt.feed("\u{1B}]21;cursor_text=#102030\u{07}")
    let initial = vt.state.palette
    vt.feed(
      "\u{1B}]11;\(color)\u{07}\u{1B}]4;1;\(color)\u{07}\u{1B}]21;cursor_text=\(color)\u{07}",
    )
    #expect(vt.state.palette == initial)
    #expect(vt.state.output.isEmpty)
  }

  @Test
  func hashAndRGBFormsUseTheirDistinctBitRules() {
    var vt = VT()
    vt.feed("\u{1B}]4;1;#3a7;2;rgb:3/a/7\u{07}")
    #expect(vt.state.palette.colors[1] == 0x30A070)
    #expect(vt.state.palette.colors[2] == 0x33AA77)
  }
}
