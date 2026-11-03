import SwiftMuxGuardian
@testable import SwiftMuxService
import Testing

struct PaneWriterCompactionTests {
  @Test
  func continuousMixedWritesReleaseCompletedPayloadsAndPreserveCredits() {
    var writer = PaneWriter(replyReserve: 64 << 10)
    let initial = [UInt8](repeating: 0x41, count: 16 << 10)
    writer.appendInput(initial)
    var expected = initial
    var inputKinds = [Bool](repeating: true, count: initial.count)
    var actual: [UInt8] = []
    var releasedInput = 0
    var admittedInput = initial.count
    var completedPayloadsReleased = true
    for turn in 0 ..< 160 {
      let reply = [UInt8](repeating: UInt8(turn), count: 31)
      let input = [UInt8](repeating: UInt8(255 - turn), count: 8192)
      let accepted = writer.appendReply(reply)
      #expect(accepted)
      writer.appendInput(input)
      admittedInput += input.count
      expected.append(contentsOf: reply)
      expected.append(contentsOf: input)
      inputKinds.append(contentsOf: repeatElement(false, count: reply.count))
      inputKinds.append(contentsOf: repeatElement(true, count: input.count))
      let before = actual.count
      var quota = 8192
      let released = writer.flush { buffer in
        let count = min(quota, buffer.count)
        actual.append(
          contentsOf: buffer.prefix(count).bindMemory(to: UInt8.self)
        )
        quota -= count
        return count
      }
      let expectedRelease = inputKinds[before ..< actual.count].filter(\.self)
        .count
      #expect(released == expectedRelease)
      releasedInput += expectedRelease
      #expect(writer.pendingInputBytes == admittedInput - releasedInput)
      #expect(
        writer.pendingReplyBytes
          == inputKinds[actual.count...].filter { !$0 }.count
      )
      #expect(!writer.isEmpty)
      completedPayloadsReleased =
        completedPayloadsReleased
        && writer.queue.allSatisfy { $0.remaining > 0 || $0.bytes.isEmpty }
    }
    #expect(completedPayloadsReleased)
    let before = actual.count
    let finalRelease = writer.flush { buffer in
      actual.append(contentsOf: buffer.bindMemory(to: UInt8.self))
      return buffer.count
    }
    #expect(finalRelease == inputKinds[before...].filter(\.self).count)
    #expect(actual == expected)
    #expect(writer.pendingInputBytes == 0)
    #expect(writer.pendingReplyBytes == 0)
    #expect(writer.isEmpty)
    #expect(writer.queue.isEmpty)
  }
}
