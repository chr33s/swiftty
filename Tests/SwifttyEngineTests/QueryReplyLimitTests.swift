@testable import SwifttyEngine
import Testing
import TestSupport

struct QueryReplyLimitTests {
  private static let limit = 64 << 10

  @Test(arguments: [-1, 0, 1])
  func versionReplyLimitsCountUTF8Bytes(delta: Int) {
    var vt = VT()
    let base = String(repeating: "é", count: (Self.limit - 6) / 2)
    vt.state.terminalVersion =
      delta < 0
      ? String(base.dropLast()) + "a"
      : base + String(repeating: "a", count: delta, )
    let prior = Array("prior".utf8)
    vt.state.output = prior
    vt.feed("\u{1B}[>q")
    let expected =
      delta <= 0
      ? prior
        + Array(("\u{1B}P>|" + vt.state.terminalVersion + "\u{1B}\\").utf8)
      : prior
    let matches = vt.state.output == expected
    #expect(matches)
    vt.state.output.removeAll()
    vt.feed("\u{1B}[5n")
    #expect(vt.takeOutput() == "\u{1B}[0n")
  }

  @Test(arguments: [-1, 0, 1], [false, true])
  func terminfoReplyLimitsIncludeEncodingAndFraming(
    delta: Int,
    fragmented: Bool,
  ) {
    var vt = VT()
    let size = (Self.limit - 12) / 2 + delta
    vt.state.terminfoName = "é" + String(repeating: "a", count: size - 2)
    let request = "\u{1B}P+q544E\u{1B}\\"
    if fragmented {
      for byte in request.utf8 { vt.feed(bytes: [byte]) }
    } else {
      vt.feed(request)
    }
    if delta <= 0 {
      #expect(vt.state.output.count == 12 + size * 2)
      let matches =
        vt.takeOutput() == "\u{1B}P1+r544E="
        + TerminalState.hex(vt.state.terminfoName) + "\u{1B}\\"
      #expect(matches)
    } else {
      let replied = !vt.state.output.isEmpty
      #expect(!replied)
    }
  }

  @Test(arguments: [false, true])
  func amplifiedTermcapBatchesAreDroppedAtomically(fragmented: Bool) {
    var vt = VT()
    vt.state.terminfoName = String(repeating: "a", count: 1024)
    vt.state.output = Array("prior".utf8)
    // Even a small request can expand beyond the reply reserve. A valid
    // first capability must not produce a partial response on overflow.
    let request =
      "\u{1B}P+q436f;"
      + Array(repeating: "544E", count: 64).joined(separator: ";") + "\u{1B}\\"
    if fragmented {
      for byte in request.utf8 { vt.feed(bytes: [byte]) }
    } else {
      vt.feed(request)
    }
    let unchanged = vt.state.output == Array("prior".utf8)
    #expect(unchanged)
    vt.state.output.removeAll()
    vt.feed("\u{1B}P+q436f\u{1B}\\")
    #expect(vt.takeOutput() == "\u{1B}P1+r436f=323536\u{1B}\\")
  }

  @Test(arguments: [false, true])
  func exactLimitBatchesPreserveEveryReplyAndExistingOutput(overflow: Bool) {
    var vt = VT()
    vt.state.terminfoName = String(
      repeating: "a",
      count: (Self.limit / 2 - 12) / 2,
    )
    let reply =
      "\u{1B}P1+r544E="
      + String(repeating: "61", count: vt.state.terminfoName.utf8.count, )
      + "\u{1B}\\"
    #expect(reply.utf8.count * 2 == Self.limit)
    vt.state.output = Array("prior".utf8)
    vt.feed("\u{1B}P+q544E;544E" + (overflow ? ";436f" : "") + "\u{1B}\\")
    let expected = "prior" + (overflow ? "" : reply + reply)
    let matches = vt.state.output == Array(expected.utf8)
    #expect(matches)
  }

  @Test
  func maximumDefaultCapabilityBatchFitsTheReserve() {
    var vt = VT()
    let count = 819
    let body =
      Array(repeating: "4d73", count: count).joined(separator: ";") + ";;"
    #expect(body.utf8.count == 4096)
    vt.feed("\u{1B}P+q" + body + "\u{1B}\\")
    let reply =
      "\u{1B}P1+r4d73=5C455D35323B25703125733B25703225735C303037\u{1B}\\"
    #expect(reply.utf8.count * count < Self.limit)
    let matches = vt.takeOutput() == String(repeating: reply, count: count)
    #expect(matches)
  }
}
