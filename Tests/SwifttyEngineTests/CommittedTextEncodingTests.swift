@testable import SwifttyEngine
import Testing

struct CommittedTextEncodingTests {
  @Test(arguments: [
    UInt8(0), 1, 2, 4, 16, 17, 23, 8, 9, 10, 12, 24, 25, 26, 28, 31,
  ])
  func commitsRespectKeyboardFlags(_ flags: UInt8) {
    let cases = [
      ("漢", "28450"), ("å", "229"), ("a", "97"), ("e\u{301}", "101:769"),
      ("👩‍💻", "128105:8205:128187"), ("漢字", "28450:23383"),
      (" \u{10FFFF}", "32:1114111"),
    ]
    for (text, codePoints) in cases {
      var output: [UInt8] = [0xFF]
      #expect(
        InputEncoder.encode(
          .text(text),
          modes: .initial,
          keyboardFlags: flags,
          into: &output
        )
      )
      let expected =
        flags & 8 == 0
        ? text : flags & 16 == 0 ? "\u{1B}[0u" : "\u{1B}[0;1;\(codePoints)u"
      #expect(output == [0xFF] + Array(expected.utf8))
    }
  }

  @Test
  func emptyCommitsAndNonTextInputsKeepTheirContracts() {
    for flags: UInt8 in [0, 8, 24, 31] {
      var output: [UInt8] = [0xFF]
      #expect(
        InputEncoder.encode(
          .text(""),
          modes: .initial,
          keyboardFlags: flags,
          into: &output
        )
      )
      #expect(output == [0xFF])
      #expect(
        InputEncoder.encode(
          .bytes([0, 0x1B, 0xFF]),
          modes: .initial,
          keyboardFlags: flags,
          into: &output
        )
      )
      #expect(output == [0xFF, 0, 0x1B, 0xFF])
      output.removeAll()
      #expect(
        InputEncoder.encode(
          .paste("漢\n"),
          modes: [.bracketedPaste],
          keyboardFlags: flags,
          into: &output
        )
      )
      #expect(output == Array("\u{1B}[200~漢\n\u{1B}[201~".utf8))
    }
  }

  @Test
  func controlTextIsRefusedAtomicallyInKeyReportMode() {
    for value: UInt32 in Array(0 ... 31) + Array(127 ... 159) {
      let text = "a" + String(Unicode.Scalar(value)!) + "漢"
      for flags: UInt8 in [8, 24, 31] {
        var output: [UInt8] = [0xFF]
        #expect(
          !InputEncoder.encode(
            .text(text),
            modes: .initial,
            keyboardFlags: flags,
            into: &output
          )
        )
        #expect(output == [0xFF])
      }
      var output: [UInt8] = []
      #expect(InputEncoder.encode(.text(text), modes: .initial, into: &output))
      #expect(output == Array(text.utf8))
    }
  }
}
