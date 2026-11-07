#if os(macOS)
@testable import AppleTransport
import Foundation
import Network
import ScreenProtocol
import SessionCore
import Synchronization
import Testing

extension QUICTransportTests {
  @Test
  func repeatedUnregisteredCancellationPreservesNativeStreamCredit()
    async throws
  {
    let (listener, accepted) = try await startListener()
    defer { listener.stop() }
    let client = try await connector()
      .connectQUIC(
        host: "127.0.0.1",
        port: listener.port,
        pin: loopbackIdentity.pin
      )
    defer { client.close() }
    let inbox = Inbox()
    client.start(inbox.handler)
    try await client.sendControl(
      ControlRecord.encode(.ping(epoch: 1, nonce: 1))
    )
    try await transportEventually { accepted.count == 1 }
    let (server, serverInbox) = try #require(accepted.all.first)
    client.enableSnapshotReadDiagnosticsForTesting()
    server.enableSnapshotReadDiagnosticsForTesting()
    let canceled = snapshotPayload(
      bodyLength: RSTLimits.maxSnapshotEncodedBytes,
      fill: 1
    )
    let count = 4 * QUICOptions.concurrentSnapshotStreams
    do {
      for id in 1 ... count {
        await #expect(throws: RSTTransportError.canceled) {
          try await server.sendSnapshot(
            canceled,
            stream: UInt64(id),
            beforeRegistration: { server.cancelSnapshot(stream: UInt64(id)) }
          )
        }
        #expect(server.admittedSnapshotSendsForTesting == 0)
        #expect(server.snapshotStreamForTesting(UInt64(id)) == nil)
      }
      #expect(inbox.snapshots.isEmpty)
      // More successful writes than the initial allowance also prove that
      // credit keeps returning after the repeated creation cancellations.
      for index in 1 ... QUICOptions.concurrentSnapshotStreams + 1 {
        let payload = snapshotPayload(
          bodyLength: RSTLimits.maxSnapshotEncodedBytes,
          fill: UInt8(index + 1)
        )
        let result = Mutex<Result<Void, any Error>?>(nil)
        let send = Task {
          do {
            try await server.sendSnapshot(
              payload,
              stream: UInt64(count + index)
            )
            result.withLock { $0 = .success(()) }
          } catch { result.withLock { $0 = .failure(error) } }
        }
        do {
          try await transportEventually(.seconds(2)) {
            result.withLock { $0 != nil }
          }
          await send.value
          try #require(result.withLock { $0 }).get()
        } catch {
          send.cancel()
          await send.value
          throw error
        }
        try await transportEventually(.seconds(2)) {
          inbox.snapshots.count == index
        }
        #expect(inbox.snapshots.last == payload)
      }
      try await client.sendControl(
        ControlRecord.encode(.ping(epoch: 1, nonce: 2))
      )
      try await server.sendControl(
        ControlRecord.encode(.pong(epoch: 1, nonce: 2))
      )
      try await transportEventually(.seconds(2)) {
        serverInbox.messages.contains(.ping(epoch: 1, nonce: 2))
          && inbox.messages.contains(.pong(epoch: 1, nonce: 2))
      }
      #expect(!client.isClosed)
      #expect(!server.isClosed)
      #expect(server.admittedSnapshotSendsForTesting == 0)
    } catch {
      Issue.record(
        Comment(
          rawValue: """
            repeated creation cancellation client: \(client.snapshotDiagnosticsForTesting)
            server: \(server.snapshotDiagnosticsForTesting)
            """
        )
      )
      throw error
    }
  }

  @Test
  func supersededNativeCompletionCannotBeLostBeforeParking() async throws {
    let (listener, accepted) = try await startListener()
    defer { listener.stop() }
    let client = try await connector()
      .connectQUIC(
        host: "127.0.0.1",
        port: listener.port,
        pin: loopbackIdentity.pin
      )
    defer { client.close() }
    let inbox = Inbox()
    client.start(inbox.handler)
    try await client.sendControl(
      ControlRecord.encode(.ping(epoch: 1, nonce: 1))
    )
    try await transportEventually { accepted.count == 1 }
    let (server, _) = try #require(accepted.all.first)
    let pending = HeldSnapshotCompletion()
    let first = Task {
      try await server.sendSnapshot(
        snapshotPayload(bodyLength: RSTLimits.maxSnapshotEncodedBytes, fill: 1),
        stream: 1,
        beforeRegistration: nil,
        write: pending.write
      )
    }
    defer {
      first.cancel()
      pending.release()
    }
    try await transportEventually(.seconds(2)) { pending.isReady }
    let replacement = snapshotPayload(bodyLength: 100, fill: 2)
    try await server.sendSnapshot(
      replacement,
      stream: 1,
      beforeRegistration: nil,
      afterRegistration: { pending.release() }
    )
    if case let .failure(error) = await first.result {
      #expect(error as? RSTTransportError == .canceled)
    } else {
      Issue.record("superseded sender completed successfully")
    }
    try await transportEventually(.seconds(2)) {
      inbox.snapshots.contains(replacement)
    }
    #expect(server.parkedSnapshotFinishesForTesting == 0)
    try await transportEventually(.seconds(2)) { !pending.hasStream }
    #expect(!client.isClosed)
    #expect(!server.isClosed)
  }

  @Test(arguments: [false, true], [false, true])
  func cancelledNativeSnapshotWritesKeepTheirAdmissionUntilCompletion(
    reuseID: Bool,
    close: Bool
  ) async throws {
    let (listener, accepted) = try await startListener()
    defer { listener.stop() }
    let client = try await connector()
      .connectQUIC(
        host: "127.0.0.1",
        port: listener.port,
        pin: loopbackIdentity.pin
      )
    defer { client.close() }
    let inbox = Inbox()
    client.start(inbox.handler)
    try await client.sendControl(
      ControlRecord.encode(.ping(epoch: 1, nonce: 1))
    )
    try await transportEventually { accepted.count == 1 }
    let (server, _) = try #require(accepted.all.first)
    server.enableSnapshotReadDiagnosticsForTesting()
    // Submit real full-sized Network writes, but prevent their completion
    // callbacks from running until admission and cancellation are checked.
    server.queue.suspend()
    var suspended = true
    defer { if suspended { server.queue.resume() } }
    let payload = snapshotPayload(
      bodyLength: RSTLimits.maxSnapshotEncodedBytes,
      fill: 1
    )
    for id in 1 ... QUICRSTConnection.maxPendingSnapshotSends {
      let send = Task {
        try await server.sendSnapshot(payload, stream: reuseID ? 1 : UInt64(id))
      }
      defer { send.cancel() }
      try await transportEventually(.seconds(2)) {
        let event =
          "outbound write,snapshot=\(reuseID ? 1 : id),bytes=\(payload.count)"
        return server.snapshotDiagnosticsForTesting
          .components(separatedBy: event).count - 1 == (reuseID ? id : 1)
      }
      send.cancel()
      let result = await send.result
      guard case let .failure(error) = result else {
        Issue.record("cancelled snapshot sender completed successfully")
        return
      }
      #expect(error as? RSTTransportError == .canceled)
      #expect(server.admittedSnapshotSendsForTesting == id)
      if reuseID { #expect(server.parkedSnapshotFinishesForTesting == id - 1) }
    }
    let overflowResult = Mutex<Result<Void, any Error>?>(nil)
    let overflow = Task {
      let result: Result<Void, any Error>
      do {
        try await server.sendSnapshot(payload, stream: 100)
        result = .success(())
      } catch { result = .failure(error) }
      overflowResult.withLock { $0 = result }
    }
    defer { overflow.cancel() }
    try await transportEventually(.seconds(2)) {
      overflowResult.withLock { $0 != nil }
        || server.pendingSnapshotSendsForTesting != 0
    }
    if case let .failure(error) = overflowResult.withLock({ $0 }) {
      #expect(error as? RSTTransportError == .resourceLimit)
    } else {
      Issue.record("cancelled native writes allowed an extra snapshot send")
    }
    overflow.cancel()
    await overflow.value
    if close { server.close() }
    server.queue.resume()
    suspended = false
    // Every held write completes only now, and after a close only once the
    // group is canceled (up to `closeGrace` later): a loaded runner needs
    // more than the two seconds the other waits get.
    do {
      try await transportEventually {
        server.admittedSnapshotSendsForTesting == 0
      }
    } catch {
      Issue.record(
        "admissions not released: \(server.snapshotDiagnosticsForTesting)"
      )
      throw error
    }
    if close {
      #expect(server.isClosed)
      #expect(server.parkedSnapshotFinishesForTesting == 0)
      return
    }
    let replacement = snapshotPayload(bodyLength: 100, fill: 2)
    try await server.sendSnapshot(replacement, stream: 101)
    try await transportEventually(.seconds(2)) {
      inbox.snapshots.contains(replacement)
    }
    #expect(!client.isClosed)
    #expect(!server.isClosed)
  }
}

private final class HeldSnapshotCompletion: Sendable {
  private struct State {
    weak var stream: NWConnection?
    var completion: (@Sendable () -> Void)?
    var released = false
  }
  private let state = Mutex(State())

  var isReady: Bool { state.withLock { $0.completion != nil } }
  var hasStream: Bool { state.withLock { $0.stream != nil } }

  var write: QUICRSTConnection.ControlWrite {
    { stream, bytes, completed in
      self.state.withLock { $0.stream = stream }
      stream.send(
        content: bytes,
        contentContext: .finalMessage,
        isComplete: false,
        completion: .contentProcessed { error in
          let deliver: @Sendable () -> Void = { completed(error) }
          let released = self.state.withLock { state in
            guard !state.released else { return true }
            state.completion = deliver
            return false
          }
          if released { deliver() }
        }
      )
    }
  }

  func release() {
    let completion = state.withLock { state in
      state.released = true
      defer { state.completion = nil }
      return state.completion
    }
    completion?()
  }
}
#endif
