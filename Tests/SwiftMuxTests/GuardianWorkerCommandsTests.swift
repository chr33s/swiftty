import Dispatch
import Foundation
import SwiftMuxGuardian
import SwiftMuxProtocol
import Testing

@Suite
struct GuardianWorkerCommandsTests {
  @Test
  func reservedReplyAndControlAdmissionSurvivesFullInputWindow() throws {
    let fixture = Fixture()
    try fixture.queue.sync { () throws -> Void in
      let input = fixture.input
      for _ in 0 ..< GuardianWire.commandWindow {
        #expect(
          try fixture.commands.submit(input, completion: fixture.completed)
        )
      }
      #expect(
        try !fixture.commands.submit(input, completion: fixture.completed)
      )
      #expect(fixture.sent == [input])
      let reply = GuardianCommand.reply(pane: fixture.pane, bytes: Data([7]))
      let end = GuardianCommand.end(pane: fixture.pane)
      #expect(try fixture.commands.submit(reply, completion: fixture.completed))
      #expect(try fixture.commands.submit(end, completion: fixture.completed))
      fixture.drain()
      #expect(
        fixture.sent == Array(
          repeating: input,
          count: GuardianWire.commandWindow
        ) + [reply, end]
      )
      #expect(fixture.results.count == GuardianWire.commandWindow + 2)
      #expect(try fixture.commands.submit(input, completion: fixture.completed))
      fixture.drain()
    }
  }

  @Test
  func revocationCancelsOnlyUnsentMatchingInputAndRefundsItsCapacity() throws {
    let fixture = Fixture()
    try fixture.queue.sync { () throws -> Void in
      #expect(
        try fixture.commands.submit(
          fixture.input,
          completion: fixture.completed
        )
      )
      for _ in 1 ..< GuardianWire.commandWindow {
        #expect(
          try fixture.commands.submit(
            fixture.input,
            completion: fixture.completed
          )
        )
      }
      let resize = GuardianCommand.resize(
        pane: fixture.pane,
        columns: 100,
        rows: 30
      )
      #expect(
        try fixture.commands.submit(resize, completion: fixture.completed)
      )
      fixture.commands.cancelUnsentInput(pane: fixture.pane)
      #expect(fixture.results.count == GuardianWire.commandWindow - 1)
      for result in fixture.results {
        guard case let .success(.rejected(error)) = result else {
          Issue.record("unsent input did not receive a definitive rejection");
          continue
        }
        #expect(error.code == .staleAttachment)
      }
      #expect(fixture.sent == [fixture.input])
      #expect(
        try fixture.commands.submit(
          fixture.input,
          completion: fixture.completed
        )
      )
      fixture.drain()
      #expect(fixture.sent == [fixture.input, resize, fixture.input])
    }
  }

  @Test
  func lossDistinguishesUnsentWorkAndCompletesEachOperationOnce() throws {
    let fixture = Fixture()
    try fixture.queue.sync { () throws -> Void in
      for _ in 0 ..< 3 {
        #expect(
          try fixture.commands.submit(
            fixture.input,
            completion: fixture.completed
          )
        )
      }
      fixture.commands.close(MuxError(.connectionLost, "test disconnect"))
      #expect(fixture.results.count == 3)
      if case .failure = fixture.results[0] {
      } else {
        Issue.record("lost in-flight outcome must be unknown")
      }
      for result in fixture.results.dropFirst() {
        if case .success(.rejected) = result {
        } else {
          Issue.record("unsent outcome must be definitive")
        }
      }
      // A late connection completion cannot complete the operation twice.
      fixture.drain()
      fixture.commands.close(MuxError(.connectionLost, "again"))
      #expect(fixture.results.count == 3)
      #expect(fixture.sent.count == 1)
      #expect(
        try !fixture.commands.submit(
          fixture.input,
          completion: fixture.completed
        )
      )
    }
  }

  @Test
  func encodedByteBudgetIsBoundedAndOversizedRequestsNeverConsumeSlots() throws
  {
    let fixture = Fixture()
    try fixture.queue.sync { () throws -> Void in
      let large = GuardianCommand.reply(
        pane: fixture.pane,
        bytes: Data(repeating: 1, count: 128 << 10)
      )
      var count = 0
      while try fixture.commands.submit(large, completion: fixture.completed) {
        count += 1
      }
      #expect(count > 1 && count < GuardianWire.commandWindow)
      let huge = GuardianCommand.reply(
        pane: fixture.pane,
        bytes: Data(repeating: 1, count: 1 << 20)
      )
      #expect(throws: MuxError.self) {
        try fixture.commands.submit(huge, completion: fixture.completed)
      }
      #expect(
        try fixture.commands.submit(
          .end(pane: fixture.pane),
          completion: fixture.completed
        )
      )
      fixture.drain()
      #expect(fixture.results.count == count + 1)
    }
  }

  @Test
  func pasteCancellationPreservesOtherPastesOrdinaryInputAndInFlightWork()
    throws
  {
    let fixture = Fixture()
    try fixture.queue.sync { () throws -> Void in
      let begin = GuardianCommand.beginPaste(
        pane: fixture.pane,
        writer: fixture.writer,
        id: 1,
        bracketed: true
      )
      let chunk = GuardianCommand.appendPaste(
        pane: fixture.pane,
        writer: fixture.writer,
        id: 1,
        text: "abc"
      )
      let end = GuardianCommand.endPaste(
        pane: fixture.pane,
        writer: fixture.writer,
        id: 1
      )
      let other = GuardianCommand.beginPaste(
        pane: fixture.pane,
        writer: fixture.writer,
        id: 2,
        bracketed: false
      )
      for command in [begin, chunk, end, fixture.input, other] {
        #expect(
          try fixture.commands.submit(command, completion: fixture.completed)
        )
      }
      fixture.commands.cancelUnsentInput(
        pane: fixture.pane,
        paste: 1,
        includingOrdinaryInput: false
      )
      #expect(fixture.results.count == 2)
      fixture.drain()
      #expect(fixture.sent == [begin, fixture.input, other])
      #expect(fixture.results.count == 5)
    }
  }

  @Test
  func immediateResultsAndExplicitLocalRefusalDoNotInventUnknownExecution()
    throws
  {
    let fixture = Fixture()
    try fixture.queue.sync { () throws -> Void in
      fixture.commands = GuardianWorkerCommands(queue: fixture.queue) {
        _,
        completion in
        completion(.success(.ok))
        return true
      }
      for _ in 0 ..< GuardianWire.commandWindow * 2 {
        #expect(
          try fixture.commands.submit(
            fixture.input,
            completion: fixture.completed
          )
        )
      }
      #expect(fixture.results.count == GuardianWire.commandWindow * 2)
      fixture.results.removeAll()
      fixture.commands = GuardianWorkerCommands(queue: fixture.queue) { _, _ in
        false
      }
      #expect(
        try fixture.commands.submit(
          fixture.input,
          completion: fixture.completed
        )
      )
      #expect(fixture.results.count == 1)
      if case .success(.rejected) = fixture.results[0] {
      } else {
        Issue.record(
          "explicit non-admission cannot have an unknown execution outcome"
        )
      }
      #expect(
        try !fixture.commands.submit(
          fixture.input,
          completion: fixture.completed
        )
      )
    }
  }

  private final class Fixture: @unchecked Sendable {
    let queue = DispatchQueue(label: "guardian-command-admission-test")
    let pane = GuardianPaneHandle(pane: PaneID(), process: UUID())
    let writer = UUID()
    var sent: [GuardianCommand] = []
    var callbacks: [GuardianWorkerCommands.Completion] = []
    var results: [Result<GuardianResult, MuxError>] = []
    lazy var commands = GuardianWorkerCommands(queue: queue) {
      [unowned self] command, completion in
      sent.append(command)
      callbacks.append(completion)
      return true
    }
    var input: GuardianCommand {
      .input(pane: pane, writer: writer, bytes: Data([120]))
    }
    var completed: GuardianWorkerCommands.Completion {
      { [self] in results.append($0) }
    }
    func drain() {
      while !callbacks.isEmpty { callbacks.removeFirst()(.success(.ok)) }
    }
  }
}
