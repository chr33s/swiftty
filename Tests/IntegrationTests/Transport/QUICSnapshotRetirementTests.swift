#if os(macOS)
@testable import AppleTransport
import Foundation
import Network
import ScreenProtocol
import SessionCore
import Synchronization
import Testing

extension QUICTransportTests {
  @Test(arguments: [0, 1 << 20, 3 << 20], [false, true])
  func newerSnapshotRetirementsPreserveASlowPeersConnection(
    pauseAfterBytes: Int,
    cancelAfterSend: Bool
  ) async throws {
    try await exerciseRetirement(
      pauseAfterBytes: pauseAfterBytes,
      cancelAfterSend: cancelAfterSend
    )
  }

  @Test(arguments: [8 << 20, 16 << 20])
  func snapshotCreditRecoversAfterReaderResumes(initialCredit: Int) async throws
  {
    try await exerciseRetirement(
      pauseAfterBytes: 0,
      initialCredit: initialCredit
    )
  }

  private func exerciseRetirement(
    pauseAfterBytes: Int,
    initialCredit: Int? = nil,
    cancelAfterSend: Bool = true
  ) async throws {
    let (listener, accepted) = try await startListener()
    defer { listener.stop() }
    let client = try await connector()
      .connectQUIC(
        host: "127.0.0.1",
        port: listener.port,
        pin: loopbackIdentity.pin,
        initialMaxDataForTesting: initialCredit,
        beforeReturnForTesting: nil
      )
    defer { client.close() }
    let inbox = Inbox()
    client.start(inbox.handler)
    try await client.sendControl(
      ControlRecord.encode(.ping(epoch: 1, nonce: 1))
    )
    try await transportEventually { accepted.count == 1 }
    let (server, serverInbox) = try #require(accepted.all.first)
    server.enableSnapshotReadDiagnosticsForTesting()
    let gate = HeldFirstSnapshotRead(afterBytes: pauseAfterBytes)
    client.setBeforeSnapshotReadForTesting(gate.hold)
    defer {
      client.setBeforeSnapshotReadForTesting(nil)
      gate.release()
    }
    let payload = snapshotPayload(
      bodyLength: RSTLimits.maxSnapshotEncodedBytes,
      fill: 1
    )
    let result = Mutex<Result<Void, any Error>?>(nil)
    let first = Task {
      do {
        try await server.sendSnapshot(payload, stream: 1)
        result.withLock { $0 = .success(()) }
      } catch { result.withLock { $0 = .failure(error) } }
    }
    defer { first.cancel() }
    var stage = "first native write with peer read deferred"
    var resumedForCredit = false
    let scenario =
      "cancelAfterSend=\(cancelAfterSend), pauseAfter=\(pauseAfterBytes), "
      + "initialCredit=\(String(describing: initialCredit))"

    func awaitSnapshot(_ expected: [UInt8]) async throws -> Bool {
      do {
        try await transportEventually(.seconds(2)) {
          inbox.snapshots.contains(expected)
        }
        return false
      } catch let timeout as TimedOut {
        // RFC 9000 §4: all streams in this direction share connection credit.
        // A deliberately held reader can exhaust it before retirement overflow.
        // This branch is allowed only while that reader is held. Once it resumes,
        // every remaining snapshot must meet the ordinary two-second deadline.
        guard gate.isHolding, !client.isClosed, !server.isClosed else {
          throw timeout
        }
        let control = await diagnoseControlProgress(
          client: client,
          server: server,
          inbox: inbox,
          serverInbox: serverInbox
        )
        try #require(serverInbox.messages.contains(.ping(epoch: 1, nonce: 999)))
        gate.release()
        try await transportEventually(.seconds(2)) {
          inbox.snapshots.contains(expected)
            && inbox.messages.contains(.pong(epoch: 1, nonce: 999))
        }
        print(
          "QUIC read pressure recovered: \(stage), initialCredit=\(String(describing: initialCredit)), \(control)"
        )
        return true
      }
    }

    do {
      // Setup only: a loaded runner can take seconds to write the first 4 MiB.
      try await transportEventually(.seconds(10)) {
        gate.isHolding && result.withLock { $0 != nil }
      }
      try result.withLock { try $0?.get() }
      let oldStream = try #require(server.snapshotStreamForTesting(1))
      if cancelAfterSend { server.cancelSnapshot(stream: 1) }
      for id in 2 ... QUICRSTConnection.maxTrackedOutbound + 2 {
        stage = "newer snapshot \(id)"
        let newer = snapshotPayload(
          bodyLength: RSTLimits.maxSnapshotEncodedBytes,
          fill: UInt8(id)
        )
        // The native send can wait for connection credit that only the held
        // reader returns, so delivery is awaited alongside it: awaitSnapshot
        // releases that reader when credit runs out.
        let sending = Task {
          try await server.sendSnapshot(newer, stream: UInt64(id))
        }
        defer { sending.cancel() }
        if try await awaitSnapshot(newer) { resumedForCredit = true }
        try await sending.value
        if cancelAfterSend { server.cancelSnapshot(stream: UInt64(id)) }
      }
      // With credit available, confirm actual overflow retirement while the old
      // reader is still held. With backpressure, confirm retirement after that
      // reader resumed. Both paths must preserve the connection and replacement.
      stage = "old native stream retirement"
      try await transportEventually(.seconds(2)) {
        if case .cancelled = oldStream.state { return true }
        return false
      }
      #expect(gate.isHolding == !resumedForCredit)
      stage = "control with old stream \(oldStream.state)"
      try await client.sendControl(
        ControlRecord.encode(.ping(epoch: 1, nonce: 2))
      )
      try await transportEventually(.seconds(2)) {
        serverInbox.messages.contains(.ping(epoch: 1, nonce: 2))
      }
      gate.release()
      stage = "replacement after delayed peer resumes"
      try await verifyReplacement(client: client, server: server, inbox: inbox)
      print(
        "QUIC retirement evidence: \(scenario), resumedForCredit=\(resumedForCredit)"
      )
    } catch {
      Issue.record(
        Comment(
          rawValue: """
            retirement stage=\(stage), held=\(gate.isHolding), resumedForCredit=\(resumedForCredit)
            \(scenario)
            client: \(client.snapshotDiagnosticsForTesting)
            server: \(server.snapshotDiagnosticsForTesting)
            """
        )
      )
      throw error
    }
  }

  private func verifyReplacement(
    client: QUICRSTConnection,
    server: QUICRSTConnection,
    inbox: Inbox
  ) async throws {
    let replacement = snapshotPayload(
      bodyLength: RSTLimits.maxSnapshotEncodedBytes,
      fill: 100
    )
    try await server.sendSnapshot(replacement, stream: 100)
    try await transportEventually(.seconds(2)) {
      inbox.snapshots.contains(replacement)
    }
    try await server.sendControl(
      ControlRecord.encode(.pong(epoch: 1, nonce: 2))
    )
    try await transportEventually(.seconds(2)) {
      inbox.messages.contains(.pong(epoch: 1, nonce: 2))
    }
    #expect(!client.isClosed)
    #expect(!server.isClosed)
  }
}

/// Observes both control directions without letting a stalled native send extend
/// the diagnostic deadline. Cancelled callers are joined before returning; their
/// already-submitted bytes can still arrive when native credit becomes available.
private func diagnoseControlProgress(
  client: QUICRSTConnection,
  server: QUICRSTConnection,
  inbox: Inbox,
  serverInbox: Inbox
) async -> String {
  let sent = Mutex<[String: String]>([:])
  let ping = ControlMessage.ping(epoch: 1, nonce: 999)
  let pong = ControlMessage.pong(epoch: 1, nonce: 999)
  let upstream = Task {
    do {
      try await client.sendControl(ControlRecord.encode(ping))
      sent.withLock { $0["upstream"] = "completed" }
    } catch { sent.withLock { $0["upstream"] = String(describing: error) } }
  }
  let downstream = Task {
    do {
      try await server.sendControl(ControlRecord.encode(pong))
      sent.withLock { $0["downstream"] = "completed" }
    } catch { sent.withLock { $0["downstream"] = String(describing: error) } }
  }
  try? await transportEventually(.seconds(2)) {
    serverInbox.messages.contains(ping) && inbox.messages.contains(pong)
  }
  let result = """
    upstreamDelivered=\(serverInbox.messages.contains(ping)), \
    downstreamDelivered=\(inbox.messages.contains(pong)), nativeSends=\(sent.withLock { $0 })
    """
  upstream.cancel()
  downstream.cancel()
  await upstream.value
  await downstream.value
  return result
}

private final class HeldFirstSnapshotRead: Sendable {
  private struct State {
    var used = false
    var resume: (@Sendable () -> Void)?
  }
  private let state = Mutex(State())
  private let afterBytes: Int
  init(afterBytes: Int) { self.afterBytes = afterBytes }
  var isHolding: Bool { state.withLock { $0.resume != nil } }
  func hold(_ bytes: Int, resume: @escaping @Sendable () -> Void) -> Bool {
    state.withLock { s in
      guard !s.used, bytes >= afterBytes else { return false }
      s.used = true
      s.resume = resume
      return true
    }
  }
  func release() {
    let resume = state.withLock { s in
      s.used = true
      defer { s.resume = nil }
      return s.resume
    }
    resume?()
  }
}
#endif
