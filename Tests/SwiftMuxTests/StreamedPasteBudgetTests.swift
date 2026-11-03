import SwiftMuxGuardian
import Dispatch
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
@testable import SwiftMuxService
import Testing
import TestSupport

@Suite(.serialized, .timeLimit(.minutes(1)))
struct StreamedPasteBudgetTests {
  @Test
  func leaseEndFinishesAStartedKeyButDropsUnstartedInput() {
    var writer = PaneWriter(replyReserve: 16)
    writer.appendInput(Array("\u{1B}[A".utf8))
    writer.appendInput(Array("make\r".utf8))
    var bytes: [UInt8] = []
    // The descriptor takes only the escape's first two bytes.
    _ = writer.flush { buffer in
      let n = min(2, buffer.count)
      bytes.append(contentsOf: buffer.bindMemory(to: UInt8.self).prefix(n))
      return n
    }
    #expect(writer.discardUnwrittenInput() == 5)
    _ = writer.flush { buffer in
      bytes.append(contentsOf: buffer.bindMemory(to: UInt8.self))
      return buffer.count
    }
    #expect(bytes == Array("\u{1B}[A".utf8))
    #expect(writer.isEmpty)
    #expect(writer.pendingInputBytes == 0)
  }

  @Test
  func leaseEndFinishesAStartedPasteScalar() {
    var writer = PaneWriter(replyReserve: 16)
    writer.beginPaste(id: 1, bracketed: false)
    writer.appendPaste(id: 1, text: "aé b")
    var bytes: [UInt8] = []
    // The descriptor takes "a" and the first byte of "é".
    _ = writer.flush { buffer in
      let n = min(2, buffer.count)
      bytes.append(contentsOf: buffer.bindMemory(to: UInt8.self).prefix(n))
      return n
    }
    #expect(writer.discardUnwrittenInput() == 2)
    _ = writer.flush { buffer in
      bytes.append(contentsOf: buffer.bindMemory(to: UInt8.self))
      return buffer.count
    }
    #expect(bytes == Array("aé".utf8))
    #expect(writer.isEmpty)
    #expect(writer.pendingInputBytes == 0)
  }

  @Test(arguments: [false, true], [false, true])
  func markersRetainClosingCreditAndPreserveDeferredOrder(
    bracketed: Bool,
    cancel: Bool,
  ) {
    var writer = PaneWriter(replyReserve: 16)
    writer.beginPaste(id: 1, bracketed: bracketed)
    #expect(writer.pendingInputBytes == (bracketed ? 12 : 0))
    writer.appendPaste(id: 1, text: "a\nb")
    writer.appendInput([0x78])
    let accepted = writer.appendReply([0x79])
    #expect(accepted)
    var bytes: [UInt8] = []
    let first = writer.flush { buffer in
      bytes.append(contentsOf: buffer.bindMemory(to: UInt8.self))
      return buffer.count
    }
    #expect(first == (bracketed ? 9 : 3))
    #expect(writer.isEmpty)
    #expect(writer.pendingInputBytes == (bracketed ? 7 : 1))
    if cancel {
      let result = writer.cancelPaste(id: 1)
      #expect(result.discarded == 0 && result.wrote)
    } else {
      writer.endPaste(id: 1)
    }
    // Closing the envelope consumes its existing reservation.
    #expect(writer.pendingInputBytes == (bracketed ? 7 : 1))
    let last = writer.flush { buffer in
      bytes.append(contentsOf: buffer.bindMemory(to: UInt8.self))
      return buffer.count
    }
    let expected = bracketed ? "\u{1B}[200~a\nb\u{1B}[201~xy" : "a\rbxy"
    #expect(bytes == Array(expected.utf8))
    #expect(last == (bracketed ? 7 : 1))
    #expect(writer.pendingInputBytes == 0)
    #expect(writer.pendingReplyBytes == 0 && writer.deferredReplyBytes == 0)
  }

  @Test(arguments: [0, 6, 7, 9, 10, 12])
  func cancellationRefundsPayloadWithoutLosingClosingCredit(written: Int) {
    var writer = PaneWriter(replyReserve: 16)
    writer.beginPaste(id: 1, bracketed: true)
    writer.appendPaste(id: 1, text: "abc")
    writer.appendPaste(id: 1, text: "def")
    var remaining = written
    var bytes: [UInt8] = []
    let released = writer.flush { buffer in
      let n = min(remaining, buffer.count)
      bytes.append(contentsOf: buffer.prefix(n).bindMemory(to: UInt8.self))
      remaining -= n
      return n
    }
    #expect(released == written)
    let cancelled = writer.cancelPaste(id: 1)
    let discarded = written <= 6 ? 6 : (written <= 9 ? 3 : 0)
    #expect(cancelled.discarded == discarded)
    #expect(cancelled.wrote == (written > 6))
    #expect(writer.pendingInputBytes == 18 - written - discarded)
    let tail = writer.flush { buffer in
      bytes.append(contentsOf: buffer.bindMemory(to: UInt8.self))
      return buffer.count
    }
    #expect(tail == 18 - written - discarded)
    let payload = written <= 6 ? "" : (written <= 9 ? "abc" : "abcdef")
    #expect(bytes == Array("\u{1B}[200~\(payload)\u{1B}[201~".utf8))
    #expect(writer.pendingInputBytes == 0)
  }

  @Test(arguments: [0, 2, 6], [false, true])
  func droppingAnEnvelopeReturnsTheUnqueuedClosingReservation(
    written: Int,
    ended: Bool,
  ) {
    var writer = PaneWriter(replyReserve: 16)
    writer.beginPaste(id: 1, bracketed: true)
    var remaining = written
    let released = writer.flush { buffer in
      let n = min(remaining, buffer.count)
      remaining -= n
      return n
    }
    #expect(released == written)
    if ended { writer.endPaste(id: 1) }
    let dropped = writer.discardAll()
    let secondDrop = writer.discardAll()
    #expect(dropped == 12 - written)
    #expect(secondDrop == 0)
    #expect(writer.pendingInputBytes == 0 && writer.isEmpty)
    #expect(!writer.hasOpenPaste)
  }

  @Test
  func repeatedEmptyEnvelopesAreChargedWhileWritesAreBlocked() {
    var writer = PaneWriter(replyReserve: 16)
    for id in UInt64(1) ... 128 {
      writer.beginPaste(id: id, bracketed: true)
      writer.endPaste(id: id)
      let released = writer.flush { _ in 0 }
      #expect(released == 0)
      #expect(writer.pendingInputBytes == Int(id) * 12)
    }
    let dropped = writer.discardAll()
    #expect(dropped == 128 * 12)
  }

  @Test
  func unavailableRuntimeReturnsTheBeginReservation() async {
    var limits = MuxLimits.standard
    limits.inputBytesPerPane = 12
    let runtime = PaneRuntime(
      id: PaneID(),
      workspace: WorkspaceID(),
      columns: 10,
      rows: 2,
      historyBytes: limits.minHistoryBytesPerPane,
      limits: limits,
    )
    #expect(runtime.reserve(12))
    runtime.pasteBegin(id: 1, estimate: 12)
    await barrier(runtime)
    #expect(runtime.outstandingInput.withLock { $0 } == 0)
  }

  enum Admission: CaseIterable, Sendable { case empty, end, cancel }

  @Test(arguments: Admission.allCases)
  func serviceChargesBeginsAndGuaranteesClosingAtCapacity(
    admission: Admission,
  ) async throws {
    try await withPane { connection, runtime, attachment in
      let pane = runtime.id
      func record(_ sequence: UInt64, _ payload: InputPayload) -> InputRecord {
        InputRecord(
          sequence: sequence,
          attachment: attachment,
          pane: pane,
          payload: payload,
        )
      }
      let started = DispatchSemaphore(value: 0)
      let proceed = DispatchSemaphore(value: 0)
      runtime.queue.async {
        started.signal()
        _ = proceed.wait(timeout: .now() + 10)
      }
      defer { proceed.signal() }
      let held = await withCheckedContinuation { continuation in
        DispatchQueue.global()
          .async {
            continuation.resume(
              returning: started.wait(timeout: .now() + 2) == .success
            )
          }
      }
      try #require(held)
      try await connection.submit(raw: record(1, .pasteBegin(id: 1)))
      if admission == .empty {
        try await connection.submit(raw: record(2, .pasteEnd(id: 1)))
        try await connection.submit(raw: record(3, .pasteBegin(id: 2)))
        try await connection.submit(raw: record(4, .pasteEnd(id: 2)))
        await #expect {
          try await connection.submit(raw: record(5, .pasteBegin(id: 3), ))
        } throws: { ($0 as? MuxError)?.code == .resourceLimit }
        await #expect {
          try await connection.submit(raw: record(6, .pasteEnd(id: 3), ))
        } throws: { ($0 as? MuxError)?.code == .invalidRequest }
      } else {
        try await connection.submit(
          raw: record(2, .pasteChunk(id: 1, text: "abcdefghijkl"), )
        )
        await #expect {
          try await connection.submit(
            raw: record(3, .pasteChunk(id: 1, text: "x"), )
          )
        } throws: { ($0 as? MuxError)?.code == .resourceLimit }
        let close: InputPayload =
          admission == .end ? .pasteEnd(id: 1) : .pasteCancel(id: 1)
        try await connection.submit(raw: record(4, close))
      }
      #expect(runtime.outstandingInput.withLock { $0 } == 24)
      proceed.signal()
      await barrier(runtime)
      #expect(runtime.outstandingInput.withLock { $0 } == 0)
      let next: UInt64 = admission == .empty ? 7 : 5
      try await connection.submit(raw: record(next, .pasteBegin(id: 3)))
      try await connection.submit(raw: record(next + 1, .pasteEnd(id: 3)))
      await barrier(runtime)
      #expect(runtime.outstandingInput.withLock { $0 } == 0)
    }
  }

  @Test(arguments: [false, true])
  func runtimeRefundsUnbracketedAndDuplicateBeginReservations(
    bracketed: Bool,
  ) async throws {
    try await withPane(bracketed: bracketed) {
      connection,
      runtime,
      attachment in
      let begin = InputRecord(
        sequence: 1,
        attachment: attachment,
        pane: runtime.id,
        payload: .pasteBegin(id: 1),
      )
      try await connection.submit(raw: begin)
      await barrier(runtime)
      let retained = bracketed ? 6 : 0
      #expect(runtime.outstandingInput.withLock { $0 } == retained)
      // A queued begin rejected by the runtime must return its entire credit.
      #expect(runtime.reserve(12))
      runtime.pasteBegin(id: 2, estimate: 12)
      await barrier(runtime)
      #expect(runtime.outstandingInput.withLock { $0 } == retained)
      try await connection.submit(
        raw: InputRecord(
          sequence: 2,
          attachment: attachment,
          pane: runtime.id,
          payload: .pasteEnd(id: 1),
        )
      )
      await barrier(runtime)
      #expect(runtime.outstandingInput.withLock { $0 } == 0)
    }
  }

  private func withPane(
    bracketed: Bool = true,
    _ work: (MuxConnection, PaneRuntime, AttachmentID) async throws -> Void,
  ) async throws {
    var limits = MuxLimits.standard
    limits.inputBytesPerPane = 24
    let harness = try Harness(limits: limits)
    let connection = try await harness.connect()
    try await RuntimeFixture.withCleanup {
      var launch = shellLaunch()
      let mode = bracketed ? "h" : "l"
      launch.command = [
        "/bin/sh", "-c",
        "stty -echo -icanon; printf '\\033[?2004\(mode)READY\\n'; exec /bin/sleep 30",
      ]
      guard
        case let .created(workspace) = try await connection.execute(
          .newWorkspace(NewWorkspaceRequest(launch: launch)),
        )
      else { throw MuxError(.invalidRequest, "creation reply") }
      let pane = workspace.tabs[0].activePane
      try await connection.attachAndShow(.id(workspace.id))
      try await RuntimeFixture.wait("pane mode", timeout: .seconds(2)) {
        await harness.service.screenLines(pane)?
          .contains { $0.contains("READY") } == true
      }
      let runtime = try #require(await harness.service.runtime(pane))
      let attachment = try #require(await connection.attachment)
      try await work(connection, runtime, attachment)
    } cleanup: {
      await connection.close()
      await withCheckedContinuation { continuation in
        harness.service.prepareToExit { continuation.resume() }
      }
    }
  }

  private func barrier(_ runtime: PaneRuntime) async {
    await withCheckedContinuation { continuation in
      runtime.queue.async { continuation.resume() }
    }
  }
}
