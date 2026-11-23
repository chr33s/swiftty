#if os(macOS)
@testable import AppleTransport
import ScreenProtocol
import SessionCore
import Synchronization
import Testing

extension QUICTransportTests {
  @Test
  func slowControlCannotDiscardTheNewestCompletedSnapshot() async throws {
    let (listener, accepted) = try await startListener()
    defer { listener.stop() }
    let client = try await connector()
      .connectQUIC(
        host: "127.0.0.1",
        port: listener.port,
        pin: loopbackIdentity.pin
      )
    defer { client.close() }
    let session = SessionID.random()
    let store = Mutex(RemoteScreenStore(sessionID: session))
    let received = Mutex<[UInt64]>([])
    let entered = Mutex(false)
    let (gate, release) = AsyncStream<Void>.makeStream()
    defer { release.finish() }
    client.start(
      RSTConnectionHandler(
        onControl: { _ in
          entered.withLock { $0 = true }
          for await _ in gate { break }
        },
        onSnapshot: { bytes in
          do {
            let snapshot = try decodeScreen(bytes)
            store.withLock { _ = $0.install(snapshot) }
            received.withLock { $0.append(snapshot.screenRevision) }
          } catch { Issue.record(error) }
        },
        onClosed: { _ in }
      )
    )
    try await client.sendControl(
      ControlRecord.encode(.ping(epoch: 1, nonce: 1))
    )
    try await transportEventually { accepted.count == 1 }
    let (server, inbox) = try #require(accepted.all.first)
    try await server.sendControl(
      ControlRecord.encode(.pong(epoch: 1, nonce: 1))
    )
    try await transportEventually { entered.withLock { $0 } }

    func payload(_ revision: UInt64) throws -> [UInt8] {
      var screen = ScreenSnapshot.blank(
        sessionID: session,
        columns: 80,
        rows: 24
      )
      screen.attachmentEpoch = 1
      screen.screenRevision = revision
      return try rstFrameRecord(screen)
    }

    // Independent streams may complete in any revision order. The first
    // arrival is newest; later completions must not evict it before decode.
    for (index, revision) in [UInt64(4), 1, 2, 3].enumerated() {
      try await server.sendSnapshot(
        payload(revision),
        stream: UInt64(index + 1)
      )
      try await transportEventually(.seconds(2)) {
        let counts = client.snapshotDeliveryCountsForTesting
        return counts.queued + counts.released == index + 1
      }
    }
    #expect(received.withLock { $0.isEmpty })
    let held = client.snapshotDeliveryCountsForTesting
    #expect(held.queued == 4)
    #expect(held.released == 0)

    // A fifth stream cannot add another queued payload while all four
    // credits belong to undelivered snapshots. Observe actual native work,
    // then leave time for an incorrectly admitted stream to arrive.
    let extraPayload = try payload(1)
    let extraResult = Mutex<Result<Void, any Error>?>(nil)
    let extra = Task {
      do {
        try await server.sendSnapshot(extraPayload, stream: 5)
        extraResult.withLock { $0 = .success(()) }
      } catch { extraResult.withLock { $0 = .failure(error) } }
    }
    defer { extra.cancel() }
    try await transportEventually(.seconds(2)) {
      server.snapshotStreamForTesting(5) != nil
    }
    try await Task.sleep(for: .milliseconds(100))
    #expect(client.snapshotDeliveryCountsForTesting.queued == 4)
    #expect(client.snapshotDeliveryCountsForTesting.released == 0)
    release.finish()
    try await transportEventually(.seconds(2)) {
      client.snapshotDeliveryCountsForTesting.released == 5
        && extraResult.withLock { $0 != nil }
    }
    await extra.value
    try extraResult.withLock { try $0?.get() }
    #expect(received.withLock { $0 } == [4, 1, 2, 3, 1])
    #expect(store.withLock { $0.current?.screenRevision } == 4)

    // Consuming the held events must return native stream credit and leave
    // both directions usable without reconnecting.
    try await server.sendSnapshot(payload(5), stream: 6)
    try await client.sendControl(
      ControlRecord.encode(.ping(epoch: 1, nonce: 2))
    )
    try await transportEventually(.seconds(2)) {
      store.withLock { $0.current?.screenRevision } == 5
        && inbox.messages.contains(.ping(epoch: 1, nonce: 2))
        && client.snapshotDeliveryCountsForTesting.released == 6
    }
    #expect(!client.isClosed && !server.isClosed)
  }
}
#endif
