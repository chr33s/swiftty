@testable import SwifttyEngine
import Testing
import TestSupport

struct ParserReplyPrefixTests {
  @Test(
    arguments: [
      "\u{1B}[5n", "\u{1B}[6n", "\u{1B}[>q", "\u{1B}]4;1;?\u{07}",
      "\u{1B}]4;1;?\u{1B}\\", "\u{1B}P+q544E\u{1B}\\", "\u{1B}P$qm\u{1B}\\",
    ]
    .map(TestFixture.init)
  )
  func resumedPrefixesMatchWholeInput(query: TestFixture<String>) {
    let input = "Aé漢🙂" + query.value + "X" + query.value + "\r\nEND"
    var reference = VT(20, 3)
    reference.feed(input)
    var actual = VT(20, 3)
    let bytes = Array(input.utf8)
    var offset = 0
    var replies: [UInt8] = []
    while offset < bytes.count {
      let consumed = bytes.withUnsafeBufferPointer {
        actual.parser.consumePrefix(
          UnsafeBufferPointer(rebasing: $0[offset...]),
          into: &actual.state,
          replyLimit: 1,
        )
      }
      #expect(consumed > 0)
      guard consumed > 0 else { break }
      offset += consumed
      replies.append(contentsOf: actual.state.output)
      actual.state.output.removeAll()
    }
    #expect(TestFixture(actual.lines) == TestFixture(reference.lines))
    #expect(
      TestFixture(String(decoding: replies, as: UTF8.self))
        == TestFixture(reference.takeOutput())
    )
    #expect(
      actual.parser.continuation.state == reference.parser.continuation.state
    )
  }

  @Test
  func OSCReplyCanPauseBeforeTheSTFinalByte() {
    var vt = VT()
    let bytes = Array("\u{1B}]4;1;?\u{1B}\\Z".utf8)
    let consumed = bytes.withUnsafeBufferPointer {
      vt.parser.consumePrefix($0, into: &vt.state, replyLimit: 1)
    }
    #expect(consumed == bytes.count - 2)
    #expect(vt.parser.continuation.state == .escape)
    vt.state.output.removeAll()
    let remaining = bytes.withUnsafeBufferPointer {
      vt.parser.consumePrefix(
        UnsafeBufferPointer(rebasing: $0[consumed...]),
        into: &vt.state,
        replyLimit: 1,
      )
    }
    #expect(remaining == 2)
    #expect(vt.lines[0] == "Z")
    #expect(vt.state.output.isEmpty)
  }

  @Test
  func existingRepliesLeaveInputUntouchedUntilDrained() {
    var vt = VT()
    vt.state.output = [1, 2, 3]
    let bytes = Array("X".utf8)
    let consumed = bytes.withUnsafeBufferPointer {
      vt.parser.consumePrefix($0, into: &vt.state, replyLimit: 3)
    }
    #expect(consumed == 0)
    #expect(vt.lines[0].isEmpty)
    vt.state.output.removeAll()
    let resumed = bytes.withUnsafeBufferPointer {
      vt.parser.consumePrefix($0, into: &vt.state, replyLimit: 3)
    }
    #expect(resumed == 1)
    #expect(vt.lines[0] == "X")
  }

  @Test
  func oneCompleteReplyCanCrossTheThreshold() {
    var vt = VT()
    vt.state.terminalVersion = String(
      repeating: "a",
      count: TerminalState.maxQueryReplyBytes - 6,
    )
    let bytes = Array("\u{1B}[>qZ".utf8)
    let consumed = bytes.withUnsafeBufferPointer {
      vt.parser.consumePrefix($0, into: &vt.state, replyLimit: 1)
    }
    #expect(consumed == 4)
    #expect(vt.state.output.count == TerminalState.maxQueryReplyBytes)
    #expect(vt.lines[0].isEmpty)
  }
}
