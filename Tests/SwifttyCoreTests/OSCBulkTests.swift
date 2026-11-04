@testable import SwifttyEngine
import Testing

/// OSC bodies are appended in runs; every split must match one whole feed.
struct OSCBulkTests {
  @Test
  func `a title split at every byte matches one feed`() {
    let input = Array("\u{1B}]0002;tïtle-ü\u{07}x\u{1B}]2;second\u{1B}\\".utf8)
    var whole = VT(10, 2)
    whole.feed(bytes: input)
    #expect(whole.state.title == "second")
    for cut in 1 ..< input.count {
      var split = VT(10, 2)
      split.feed(bytes: Array(input[..<cut]))
      // ESC dispatches before its `\` arrives.
      let expected =
        cut < 17 ? "" : cut == input.count - 1 ? "second" : "tïtle-ü"
      #expect(split.state.title == expected)
      split.feed(bytes: Array(input[cut...]))
      #expect(split.state.title == "second")
      #expect(split.lines == whole.lines)
    }
  }

  @Test
  func `leading zeros do not hide the command`() {
    var vt = VT(10, 2)
    vt.feed("\u{1B}]000000002;zeros\u{07}")
    #expect(vt.state.title == "zeros")
    // Ten digits are rejected.
    vt.feed("\u{1B}]0000000002;long\u{07}")
    #expect(vt.state.title == "zeros")
  }

  @Test(arguments: [false, true])
  func `bodies past the generic limit are dropped`(fragmented: Bool) {
    for extra in [0, 1] {
      var vt = VT(10, 2)
      let body =
        "2;" + String(repeating: "t", count: Parser.maxOSCBytes - 2 + extra)
      let bytes = Array("\u{1B}]\(body)\u{07}".utf8)
      if fragmented {
        var i = 0
        while i < bytes.count {
          vt.feed(bytes: Array(bytes[i ..< min(i + 65_521, bytes.count)]))
          i += 65_521
        }
      } else {
        vt.feed(bytes: bytes)
      }
      #expect(
        vt.state.title.utf8.count == (extra == 0 ? Parser.maxOSCBytes - 2 : 0)
      )
    }
  }

  @Test
  func `a control inside a clipboard body still voids it`() {
    var vt = VT(10, 2)
    vt.feed("\u{1B}]52;c;aGVs\u{01}bG8=\u{07}")
    #expect(vt.state.takeEvents().isEmpty)
  }
}
