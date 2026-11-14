@testable import SwifttyEngine
import Testing
import TestSupport

struct ColorOSCReplyLimitTests {
  @Test(arguments: [4, 21], [false, true])
  func colorBodiesHaveAnAtomicByteLimit(command: Int, fragmented: Bool) {
    for prefixZeros in ["", "000"] {
      for terminator in ["\u{07}", "\u{1B}\\"] {
        for size in [8191, 8192, 8193] {
          var vt = VT()
          let initial =
            command == 4
            ? vt.state.palette.colors[1] : vt.state.palette.foreground
          let prefix =
            prefixZeros
            + (command == 4 ? "4;1;#010203;" : "21;foreground=#010203;")
          let body =
            prefix + String(repeating: ";", count: size - prefix.utf8.count, )
          let request = "\u{1B}]" + body + terminator
          if fragmented {
            for byte in request.utf8 { vt.feed(bytes: [byte]) }
          } else {
            vt.feed(request)
          }
          let color =
            command == 4
            ? vt.state.palette.colors[1] : vt.state.palette.foreground
          #expect(color == (size <= 8192 ? 0x010203 : initial))
          #expect(vt.state.output.isEmpty)
          vt.feed("ok\u{1B}[5n")
          #expect(vt.lines[0] == "ok")
          #expect(vt.takeOutput() == "\u{1B}[0n")
        }
      }
    }
  }

  @Test(arguments: [4, 21])
  func oversizedQueryBatchesProduceNoReply(command: Int) {
    var vt = VT()
    let body =
      command == 4
      ? "4;1;?" + String(repeating: ";1;?", count: 32768)
      : "21;1=?" + String(repeating: ";1=?", count: 32768)
    vt.feed("\u{1B}]" + body)
    #expect(vt.state.output.isEmpty)
    vt.feed("\u{1B}\\")
    let replied = !vt.state.output.isEmpty
    #expect(!replied)
    vt.state.output.removeAll()
    vt.feed("\u{1B}]10;?\u{07}")
    #expect(vt.takeOutput().hasPrefix("\u{1B}]10;rgb:"))
  }

  @Test(arguments: [4, 21])
  func longZeroPrefixesCannotBypassTheColorLimit(command: Int) {
    var vt = VT()
    let zeros = String(repeating: "0", count: 256 << 10)
    vt.feed("\u{1B}]" + zeros)
    // Restoring a partial sequence must retain prefix recognition.
    let continuation = vt.parser.continuation
    vt.parser.restore(continuation)
    vt.feed(command == 4 ? "4;1;?\u{07}" : "21;1=?\u{07}")
    #expect(vt.state.output.isEmpty)
    // A later OSC starts with fresh prefix state.
    vt.feed("\u{1B}]4;1;?\u{07}")
    #expect(vt.takeOutput().hasPrefix("\u{1B}]4;1;rgb:"))
  }

  @Test
  func fullPaletteCommandsFitTheLimit() {
    var vt = VT()
    let setting =
      "4;"
      + (0 ..< 256).map { "\($0);rgb:0101/0202/0303" }.joined(separator: ";")
    #expect(setting.utf8.count < 8192)
    vt.feed("\u{1B}]" + setting + "\u{1B}\\")
    #expect((0 ..< 256).allSatisfy { vt.state.palette.colors[$0] == 0x010203 })
    let query = "4;" + (0 ..< 256).map { "\($0);?" }.joined(separator: ";")
    vt.feed("\u{1B}]" + query + "\u{1B}\\")
    let expected = (0 ..< 256)
      .map { "\u{1B}]4;\($0);rgb:0101/0202/0303\u{1B}\\" }.joined()
    #expect(TestFixture(vt.takeOutput()) == TestFixture(expected))
  }

  @Test(arguments: [4, 21])
  func exactLimitQueryBatchesPreserveAllReplies(command: Int) {
    var vt = VT()
    vt.feed("\u{1B}]4;1;#010203\u{1B}\\")
    let prefix = command == 4 ? "4;" : "21;"
    let pair = command == 4 ? "1;?;" : "1=?;"
    let count = (8192 - prefix.utf8.count) / pair.utf8.count
    var body = prefix + String(repeating: pair, count: count)
    body += String(repeating: ";", count: 8192 - body.utf8.count)
    vt.feed("\u{1B}]" + body + "\u{1B}\\")
    #expect(vt.state.output.count < 64 << 10)
    let expected =
      command == 4
      ? String(repeating: "\u{1B}]4;1;rgb:0101/0202/0303\u{1B}\\", count: count)
      : "\u{1B}]21;"
        + Array(repeating: "1=rgb:0101/0202/0303", count: count)
        .joined(separator: ";") + "\u{1B}\\"
    #expect(TestFixture(vt.takeOutput()) == TestFixture(expected))
  }
}
