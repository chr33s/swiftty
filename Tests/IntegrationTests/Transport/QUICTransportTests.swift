#if os(macOS)
@testable import AppleTransport
import Foundation
import Network
import ScreenProtocol
import SessionCore
import Synchronization
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct QUICTransportTests {
  @Test(arguments: [
    Duration.seconds(-1), .milliseconds(Int64(UInt32.max) + 1),
    .seconds(Int64.max), .seconds(Int64.min),
  ])
  func idleTimeoutRejectsValuesOutsideTheNativeRange(
    _ duration: Duration
  ) throws {
    #expect(throws: RSTTransportError.handshake("invalid idle timeout")) {
      try QUICOptions.idleMilliseconds(duration)
    }
  }

  @Test
  func idleTimeoutPreservesPositiveFractionsAndNativeBoundaries() throws {
    let options = NWProtocolQUIC.Options(alpn: [RSTLimits.alpn])
    let cases: [(Duration, Int)] = [
      (.zero, 0), (.microseconds(1), 1), (.milliseconds(1001), 1001),
      (.init(secondsComponent: 1, attosecondsComponent: -1), 1000),
      (.milliseconds(Int64(UInt32.max)), Int(UInt32.max)),
    ]
    for (duration, expected) in cases {
      let milliseconds = try QUICOptions.idleMilliseconds(duration)
      #expect(milliseconds == expected)
      options.idleTimeout = milliseconds
      #expect(options.idleTimeout == expected)
    }
  }

  private struct WeakConnection: Sendable { weak var value: QUICRSTConnection? }
  private struct WeakStream: Sendable { weak var value: NWConnection? }
  private struct WeakListener: Sendable { weak var value: QUICRSTListener? }
  private final class CallbackOwner: Sendable {}
  private struct WeakCallbackOwner: Sendable { weak var value: CallbackOwner? }
  private final class CallbackOwnerReference: Sendable {
    private let state: Mutex<WeakCallbackOwner>
    init(_ owner: CallbackOwner) {
      state = Mutex(WeakCallbackOwner(value: owner))
    }
    var isAlive: Bool { state.withLock { $0.value != nil } }
  }

  private func listenerWithCallbackOwner() async throws -> (
    QUICRSTListener, CallbackOwnerReference
  ) {
    let owner = CallbackOwner()
    let weakOwner = CallbackOwnerReference(owner)
    let listener = QUICRSTListener(
      identity: loopbackIdentity,
      configuration: .init(host: "127.0.0.1")
    )
    try await listener.start { [owner] _ in withExtendedLifetime(owner) {} }
    return (listener, weakOwner)
  }

  private func stoppedListenerCallbackOwner() async throws
    -> CallbackOwnerReference
  {
    let (listener, weakOwner) = try await listenerWithCallbackOwner()
    #expect(weakOwner.isAlive)
    listener.stop()
    return weakOwner
  }

  @Test
  func stoppedListenerReleasesTheAcceptedConnectionCallback() async throws {
    let weakOwner = try await stoppedListenerCallbackOwner()
    try await transportEventually(.seconds(2)) { !weakOwner.isAlive }
  }

  @Test(arguments: ["open", "stop", "cancel"])
  func listenerStartRejectsShutdownBeforeReturning(
    _ action: String
  ) async throws {
    let listener = QUICRSTListener(
      identity: loopbackIdentity,
      configuration: .init(host: "127.0.0.1")
    )
    let reached = Mutex(false)
    let (gate, release) = AsyncStream<Void>.makeStream()
    let accepted = Accepted()
    let task = Task {
      try await listener.start(
        onConnection: { accepted.add($0) },
        beforeReturnForTesting: {
          reached.withLock { $0 = true }
          for await _ in gate { break }
        }
      )
    }
    defer {
      task.cancel()
      release.finish()
      listener.stop()
    }
    try await transportEventually(.seconds(2)) { reached.withLock { $0 } }
    #expect(listener.port != 0)
    if action == "stop" { listener.stop() }
    if action == "cancel" { task.cancel() }
    release.yield(())
    release.finish()
    switch await task.result {
    case .success: #expect(action == "open")
    case let .failure(error):
      if action == "open" { throw error }
      #expect(
        error as? RSTTransportError == (action == "stop" ? .closed : .canceled)
      )
    }
    if action == "open" {
      let client = try await connector()
        .connectQUIC(
          host: "127.0.0.1",
          port: listener.port,
          pin: loopbackIdentity.pin,
        )
      defer { client.close() }
      try await transportEventually(.seconds(2)) { accepted.count == 1 }
    }
  }

  @Test(arguments: ["open", "close", "stop"])
  func listenerDoesNotReportAConnectionClosedBeforeHandoff(
    _ action: String
  ) async throws {
    let weakListener = Mutex(WeakListener())
    let boundary = Mutex((entered: false, closed: false, finished: false))
    let reports = Mutex(0)
    let listener = QUICRSTListener(
      identity: loopbackIdentity,
      configuration: .init(host: "127.0.0.1"),
      beforeReportForTesting: { connection in
        if action == "close" { connection.close() }
        if action == "stop" { weakListener.withLock { $0.value }?.stop() }
        boundary.withLock {
          $0.entered = true
          $0.closed = connection.isClosed
        }
        // Run after the current readiness handler, so zero reports is observed
        // only once that handler has completed its handoff decision.
        connection.queue.async { boundary.withLock { $0.finished = true } }
      }
    )
    weakListener.withLock { $0.value = listener }
    defer { listener.stop() }
    try await listener.start { _ in reports.withLock { $0 += 1 } }
    // Explicit server closure may fail the client handshake or close it after
    // setup. The assertion concerns the server's accepted-connection callback.
    let client = try? await connector()
      .connectQUIC(
        host: "127.0.0.1",
        port: listener.port,
        pin: loopbackIdentity.pin,
      )
    defer { client?.close() }
    try await transportEventually(.seconds(2)) {
      boundary.withLock { $0.finished }
    }
    #expect(boundary.withLock { $0.entered })
    #expect(boundary.withLock { $0.closed } == (action != "open"))
    #expect(reports.withLock { $0 } == (action == "open" ? 1 : 0))
    if action == "open" { #expect(client != nil) }
  }

  @Test
  func firstTerminationRetainsBoundedNativeErrorDetails() async throws {
    let (listener, _) = try await startListener()
    defer { listener.stop() }
    let client = try await connector()
      .connectQUIC(
        host: "127.0.0.1",
        port: listener.port,
        pin: loopbackIdentity.pin,
      )
    defer { client.close() }
    let metadata = try #require(
      client.group.metadata(definition: NWProtocolQUIC.definition)
        as? NWProtocolQUIC.Metadata
    )
    let reason = String(repeating: "r", count: 1024)
    metadata.applicationError = .init(code: 42, reason: reason)
    let nativeReason = String(
      (metadata.applicationError.reason ?? "none").prefix(256)
    )
    client.terminate(
      error: NWError.posix(.ECONNABORTED),
      source: "first native failure"
    )
    client.terminate(
      error: NWError.posix(.ENOTCONN),
      source: "later native failure"
    )
    let diagnostic = client.snapshotDiagnosticsForTesting
    #expect(diagnostic.contains("first native failure"))
    #expect(!diagnostic.contains("later native failure"))
    #expect(diagnostic.contains("nativeApplicationCode=Optional(42)"))
    #expect(diagnostic.contains("nativeReason=\(nativeReason),"))
    #expect(!diagnostic.contains(String(repeating: "r", count: 257)))
    #expect(diagnostic.contains("nativeControlStreamCode=Optional("))
  }

  @Test
  func peerClosureBeforeConnectionHandoffIsRejected() async throws {
    let (listener, accepted) = try await startListener()
    defer { listener.stop() }
    let observedClosure = Mutex(false)
    await #expect(throws: RSTTransportError.handshake("control stream closed"))
    {
      _ = try await connector()
        .connectQUIC(
          host: "127.0.0.1",
          port: listener.port,
          pin: loopbackIdentity.pin,
          beforeReturnForTesting: { connection in
            connection.start(Inbox().handler)
            do {
              try await connection.sendControl(
                ControlRecord.encode(.ping(epoch: 1, nonce: 1))
              )
              try await transportEventually(.seconds(2)) { accepted.count == 1 }
              let (server, _) = try #require(accepted.all.first)
              try await transportEventually(.seconds(2)) {
                server.hasControlStreamForTesting
              }
              server.close()
              try await transportEventually(.seconds(2)) { connection.isClosed }
              observedClosure.withLock { $0 = true }
            } catch { Issue.record("peer-close fixture failed: \(error)") }
          },
        )
    }
    #expect(observedClosure.withLock { $0 })
  }

  @Test(arguments: [false, true])
  func handshakeTimeoutCoversControlSetupAndConnectionHandoff(
    _ handoff: Bool
  ) async throws {
    let (listener, _) = try await startListener()
    defer { listener.stop() }
    let captured = Mutex<QUICRSTConnection?>(nil)
    defer { captured.withLock { $0 }?.close() }
    let budget = Duration.seconds(1)
    let hold: @Sendable (QUICRSTConnection) async -> Void = { connection in
      captured.withLock { $0 = connection }
      try? await Task.sleep(for: budget + .milliseconds(50))
    }
    await #expect(throws: RSTTransportError.handshake("timed out")) {
      _ = try await QUICRSTConnector(handshakeTimeout: budget)
        .connectQUIC(
          host: "127.0.0.1",
          port: listener.port,
          pin: loopbackIdentity.pin,
          beforeControlForTesting: handoff ? nil : hold,
          beforeReturnForTesting: handoff ? hold : nil,
        )
    }
    let connection = try #require(captured.withLock { $0 })
    #expect(connection.isClosed)
  }

  @Test
  func cancellationAtConnectionHandoffClosesTheConnection() async throws {
    let (listener, _) = try await startListener()
    defer { listener.stop() }
    let captured = Mutex<QUICRSTConnection?>(nil)
    defer { captured.withLock { $0 }?.close() }
    _ = await Task {
      await #expect(throws: RSTTransportError.canceled) {
        _ = try await connector()
          .connectQUIC(
            host: "127.0.0.1",
            port: listener.port,
            pin: loopbackIdentity.pin,
            beforeReturnForTesting: { connection in
              captured.withLock { $0 = connection }
              withUnsafeCurrentTask { $0?.cancel() }
            },
          )
      }
    }
    .value
    let connection = try #require(captured.withLock { $0 })
    #expect(connection.isClosed)
  }

  @Test
  func overlappingCreditReturnsCannotLowerTheNativeStreamLimit() async throws {
    let (listener, accepted) = try await startListener()
    defer { listener.stop() }
    let client = try await connector()
      .connectQUIC(
        host: "127.0.0.1",
        port: listener.port,
        pin: loopbackIdentity.pin,
      )
    defer { client.close() }
    client.start(Inbox().handler)
    try await client.sendControl(
      ControlRecord.encode(.ping(epoch: 1, nonce: 1))
    )
    try await transportEventually { accepted.count == 1 }
    let ready = Mutex(false)
    let released = DispatchSemaphore(value: 0)
    defer { released.signal() }
    let first = Task.detached {
      client.releaseSnapshotCredit(beforeUpdateForTesting: {
        ready.withLock { $0 = true }
        #expect(released.wait(timeout: .now() + 5) == .success)
      })
    }
    try await transportEventually { ready.withLock { $0 } }
    client.releaseSnapshotCredit()
    // The setter schedules native work; hold the stale writer until the
    // larger limit is observable rather than assuming synchronous publication.
    try await transportEventually(.seconds(1)) {
      client.snapshotDiagnosticsForTesting.contains(
        "localMaxStreams=Optional(6)"
      )
    }
    released.signal()
    await first.value
    #expect(
      client.snapshotDiagnosticsForTesting.contains(
        "localMaxStreams=Optional(6)"
      )
    )
  }

  @Test
  func rejectedSnapshotStreamIsReleased() async throws {
    var diagnosticClient: QUICRSTConnection?
    var diagnosticServer: QUICRSTConnection?
    var rejection = "not observed"
    func step<T>(
      _ stage: String,
      _ body: () async throws -> T
    ) async throws -> T {
      do { return try await body() } catch {
        Issue.record(
          Comment(
            rawValue: """
              rejected snapshot stage=\(stage), error=\(error), rejection=\(rejection)
              client: \(diagnosticClient?.snapshotDiagnosticsForTesting ?? "not created")
              server: \(diagnosticServer?.snapshotDiagnosticsForTesting ?? "not accepted")
              """
          )
        )
        throw error
      }
    }
    let (listener, accepted) = try await step("listener") {
      try await startListener()
    }
    defer { listener.stop() }
    let client = try await step("connect") {
      try await connector()
        .connectQUIC(
          host: "127.0.0.1",
          port: listener.port,
          pin: loopbackIdentity.pin,
        )
    }
    diagnosticClient = client
    client.enableSnapshotReadDiagnosticsForTesting()
    defer { client.close() }
    let inbox = Inbox()
    client.start(inbox.handler)
    try await step("control ping") {
      try await client.sendControl(
        ControlRecord.encode(.ping(epoch: 1, nonce: 1))
      )
    }
    try await step("accept") {
      try await transportEventually { accepted.count == 1 }
    }
    let (server, _) = try #require(accepted.all.first)
    diagnosticServer = server
    server.enableSnapshotReadDiagnosticsForTesting()
    let rejectedStream = Mutex(WeakStream())
    server.queue.suspend()
    var suspended = true
    defer { if suspended { server.queue.resume() } }
    let send = Task {
      // An invalid frame type makes the receiver reset before reading the
      // body. The body exceeds the receive window, keeping the send pending.
      try await server.sendSnapshot(
        [UInt8](repeating: 0xFF, count: RSTLimits.maxSnapshotEncodedBytes),
        stream: 1,
      )
    }
    defer { send.cancel() }
    try await step("register rejected send") {
      try await transportEventually {
        server.pendingSnapshotSendsForTesting == 1
      }
    }
    func captureStream() throws {
      let stream = try #require(server.snapshotStreamForTesting(1))
      rejectedStream.withLock { $0.value = stream }
    }
    try await step("capture rejected stream") { try captureStream() }
    server.queue.resume()
    suspended = false
    try await step("retire rejected send") {
      try await transportEventually {
        server.pendingSnapshotSendsForTesting == 0
      }
    }
    switch await send.result {
    case .success: Issue.record("rejected snapshot send completed successfully")
    case let .failure(error): rejection = String(describing: error)
    }
    #expect(
      server.snapshotStreamForTesting(1) == nil,
      Comment(rawValue: server.snapshotDiagnosticsForTesting),
    )
    try await step("release rejected stream") {
      try await transportEventually(.seconds(1)) {
        rejectedStream.withLock { $0.value == nil }
      }
    }
    let good = snapshotPayload(bodyLength: 100, fill: 2)
    try await step("send valid replacement") {
      try await server.sendSnapshot(good, stream: 2)
    }
    try await step("receive valid replacement") {
      try await transportEventually { inbox.snapshots == [good] }
    }
    #expect(!client.isClosed)
    #expect(!server.isClosed)
  }

  @Test(
    arguments: [false, true],
    [100, 300_000, RSTLimits.maxSnapshotEncodedBytes]
  )
  func retiredSnapshotStreamIsReleased(
    _ cancel: Bool,
    _ bodyLength: Int
  ) async throws {
    let (listener, accepted) = try await startListener()
    defer { listener.stop() }
    let client = try await connector()
      .connectQUIC(
        host: "127.0.0.1",
        port: listener.port,
        pin: loopbackIdentity.pin,
      )
    defer { client.close() }
    let inbox = Inbox()
    client.start(inbox.handler)
    try await client.sendControl(
      ControlRecord.encode(.ping(epoch: 1, nonce: 1)),
    )
    try await transportEventually { accepted.count == 1 }
    let (server, _) = try #require(accepted.all.first)
    let firstStream = Mutex(WeakStream())
    let payload = snapshotPayload(bodyLength: bodyLength, fill: 1)
    func sendAndCapture() async throws {
      try await server.sendSnapshot(payload, stream: 1)
      let stream = try #require(server.snapshotStreamForTesting(1))
      firstStream.withLock { $0.value = stream }
    }
    try await withConnectionDiagnostics(client: client, server: server) {
      try await sendAndCapture()
      if cancel {
        try await transportEventually { inbox.snapshots.count == 1 }
        server.cancelSnapshot(stream: 1)
      } else {
        for id in 2 ... (QUICRSTConnection.maxTrackedOutbound + 1) {
          try await server.sendSnapshot(payload, stream: UInt64(id))
        }
        try await transportEventually {
          inbox.snapshots.count == QUICRSTConnection.maxTrackedOutbound + 1
        }
      }
    }
    #expect(inbox.snapshots.allSatisfy { $0 == payload })
    #expect(server.snapshotStreamForTesting(1) == nil)
    try await transportEventually(.seconds(1)) {
      firstStream.withLock { $0.value == nil }
    }
    #expect(!client.isClosed)
    #expect(!server.isClosed)
  }

  @Test
  func closedConnectionReleasesAHandlerThatCapturesIt() async throws {
    let (listener, _) = try await startListener()
    defer { listener.stop() }
    let weakConnection = Mutex(WeakConnection())
    let closed = Mutex(false)
    func connectAndClose() async throws {
      let client = try await connector()
        .connectQUIC(
          host: "127.0.0.1",
          port: listener.port,
          pin: loopbackIdentity.pin,
        )
      weakConnection.withLock { $0.value = client }
      client.start(
        RSTConnectionHandler(
          onControl: { _ in _ = client.isClosed },
          onClosed: { _ in closed.withLock { $0 = true } },
        ),
      )
      client.close()
    }
    try await connectAndClose()
    try await transportEventually { closed.withLock { $0 } }
    try await transportEventually {
      weakConnection.withLock { $0.value == nil }
    }
  }

  @Test(arguments: [false, true], [false, true])
  func pendingSnapshotAdmissionIncludesStreamCreation(
    _ sameID: Bool,
    _ closeInstead: Bool,
  ) async throws {
    let (listener, accepted) = try await startListener()
    defer { listener.stop() }
    let client = try await connector()
      .connectQUIC(
        host: "127.0.0.1",
        port: listener.port,
        pin: loopbackIdentity.pin,
      )
    defer { client.close() }
    let inbox = Inbox()
    client.start(inbox.handler)
    try await client.sendControl(
      ControlRecord.encode(.ping(epoch: 1, nonce: 1)),
    )
    try await transportEventually { accepted.count == 1 }
    let (server, _) = try #require(accepted.all.first)
    let release = Mutex(false)
    let entered = Mutex(0)
    defer { release.withLock { $0 = true } }
    let payload = snapshotPayload(bodyLength: 32, fill: 1)
    let sends = (0 ..< QUICRSTConnection.maxPendingSnapshotSends)
      .map { id in
        Task {
          await #expect(
            throws: closeInstead ? RSTTransportError.closed : .canceled,
          ) {
            try await server.sendSnapshot(
              payload,
              stream: sameID ? 1 : UInt64(id),
              beforeRegistration: nil,
              beforeStreamCreation: {
                entered.withLock { $0 += 1 }
                while !release.withLock({ $0 }) {
                  try? await Task.sleep(for: .milliseconds(1))
                }
              },
            )
          }
        }
      }
    defer { sends.forEach { $0.cancel() } }
    try await transportEventually { entered.withLock { $0 } == sends.count }
    #expect(server.admittedSnapshotSendsForTesting == sends.count)
    let overflowEntered = Mutex(false)
    let overflowFinished = Mutex(false)
    let overflow = Task {
      defer { overflowFinished.withLock { $0 = true } }
      await #expect(throws: RSTTransportError.resourceLimit) {
        try await server.sendSnapshot(
          payload,
          stream: 100,
          beforeRegistration: nil,
          beforeStreamCreation: {
            overflowEntered.withLock { $0 = true }
            while !release.withLock({ $0 }) {
              try? await Task.sleep(for: .milliseconds(1))
            }
          },
        )
      }
    }
    defer { overflow.cancel() }
    let deadline = ContinuousClock.now + .seconds(1)
    while !overflowFinished.withLock({ $0 }), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    #expect(overflowFinished.withLock { $0 })
    #expect(!overflowEntered.withLock { $0 })
    #expect(server.admittedSnapshotSendsForTesting == sends.count)
    overflow.cancel()
    if closeInstead {
      server.close()
      // Reserved creators remain accounted for until they actually return.
      #expect(server.admittedSnapshotSendsForTesting == sends.count)
    } else {
      sends.forEach { $0.cancel() }
    }
    release.withLock { $0 = true }
    await overflow.value
    for send in sends { _ = await send.value }
    #expect(server.admittedSnapshotSendsForTesting == 0)
    if closeInstead {
      await #expect(throws: RSTTransportError.closed) {
        try await server.sendSnapshot(payload, stream: 200)
      }
    } else {
      try await server.sendSnapshot(payload, stream: 200)
      try await transportEventually { inbox.snapshots.contains(payload) }
    }
    #expect(server.admittedSnapshotSendsForTesting == 0)
    client.close()
    #expect(server.admittedSnapshotSendsForTesting == 0)
  }

  @Test(arguments: [false, true])
  func recentPreCanceledSnapshotsSurviveHistoryCapacity(
    _ repeatID: Bool,
  ) async throws {
    let (listener, accepted) = try await startListener()
    defer { listener.stop() }
    let client = try await connector()
      .connectQUIC(
        host: "127.0.0.1",
        port: listener.port,
        pin: loopbackIdentity.pin,
      )
    defer { client.close() }
    let inbox = Inbox()
    client.start(inbox.handler)
    try await client.sendControl(
      ControlRecord.encode(.ping(epoch: 1, nonce: 1)),
    )
    try await transportEventually { accepted.count == 1 }
    let (server, _) = try #require(accepted.all.first)
    for id in 1 ... 64 { server.cancelSnapshot(stream: UInt64(id)) }
    let last: UInt64 = repeatID ? 64 : 65
    server.cancelSnapshot(stream: last)
    let refused = snapshotPayload(bodyLength: 100, fill: 7)
    await #expect(throws: RSTTransportError.canceled) {
      try await server.sendSnapshot(refused, stream: 63)
    }
    await #expect(throws: RSTTransportError.canceled) {
      try await server.sendSnapshot(refused, stream: last)
    }
    let expired = snapshotPayload(bodyLength: 100, fill: 9)
    if repeatID {
      await #expect(throws: RSTTransportError.canceled) {
        try await server.sendSnapshot(refused, stream: 1)
      }
    } else {
      // Overflow evicts only the oldest unknown ID.
      try await server.sendSnapshot(expired, stream: 1)
    }
    let valid = snapshotPayload(bodyLength: 100, fill: 8)
    try await server.sendSnapshot(valid, stream: 66)
    try await transportEventually { inbox.snapshots.contains(valid) }
    let expected = repeatID ? [valid] : [expired, valid]
    try await transportEventually { inbox.snapshots.count >= expected.count }
    let onlyValidSnapshots =
      inbox.snapshots.count == expected.count
      && inbox.snapshots.allSatisfy { expected.contains($0) }
    #expect(onlyValidSnapshots)
    #expect(server.preCanceledSnapshotCount == (repeatID ? 61 : 62))
    #expect(!inbox.closed)
    server.close()
    server.cancelSnapshot(stream: 1000)
    #expect(server.preCanceledSnapshotCount == 0)
  }

  @Test(arguments: [false, true])
  func snapshotCancelledBeforeWriteAdmissionDoesNotWrite(
    _ close: Bool
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
    let writes = Mutex(0)
    let payload = snapshotPayload(
      bodyLength: RSTLimits.maxSnapshotEncodedBytes,
      fill: 1
    )
    await #expect(throws: close ? RSTTransportError.closed : .canceled) {
      try await server.sendSnapshot(
        payload,
        stream: 1,
        beforeRegistration: nil,
        beforeWrite: {
          if close { server.close() } else { server.cancelSnapshot(stream: 1) }
        },
        write: { _, _, completed in
          writes.withLock { $0 += 1 }
          completed(nil)
        }
      )
    }
    #expect(writes.withLock { $0 } == 0)
    #expect(server.pendingSnapshotSendsForTesting == 0)
    #expect(server.admittedSnapshotSendsForTesting == 0)
    if !close {
      let replacement = snapshotPayload(bodyLength: 100, fill: 2)
      try await server.sendSnapshot(replacement, stream: 2)
      try await transportEventually { inbox.snapshots == [replacement] }
      #expect(!client.isClosed)
      #expect(!server.isClosed)
    }
  }

  @Test
  func `cancellation during stream creation refuses the snapshot`() async throws
  {
    let (listener, accepted) = try await startListener()
    defer { listener.stop() }
    let client = try await connector()
      .connectQUIC(
        host: "127.0.0.1",
        port: listener.port,
        pin: loopbackIdentity.pin,
      )
    defer { client.close() }
    let inbox = Inbox()
    client.start(inbox.handler)
    try await client.sendControl(
      ControlRecord.encode(.ping(epoch: 1, nonce: 1)),
    )
    try await transportEventually { accepted.count == 1 }
    let (server, _) = try #require(accepted.all.first)
    let payload = snapshotPayload(bodyLength: 100, fill: 7)
    await #expect(throws: RSTTransportError.canceled) {
      try await server.sendSnapshot(
        payload,
        stream: 1,
        beforeRegistration: { server.cancelSnapshot(stream: 1) },
      )
    }
    try await server.sendSnapshot(payload, stream: 2)
    try await transportEventually { inbox.snapshots.contains(payload) }
    try await Task.sleep(for: .milliseconds(100))
    #expect(inbox.snapshots.count == 1)
    #expect(!inbox.closed)
  }

  /// Sequential cancellations must not exhaust the client's initial
  /// unidirectional stream credit.
  @Test
  func `repeated cancellation during stream creation preserves stream credit`()
    async throws
  {
    let (listener, accepted) = try await startListener()
    defer { listener.stop() }
    let client = try await connector()
      .connectQUIC(
        host: "127.0.0.1",
        port: listener.port,
        pin: loopbackIdentity.pin,
      )
    defer { client.close() }
    let inbox = Inbox()
    client.start(inbox.handler)
    try await client.sendControl(
      ControlRecord.encode(.ping(epoch: 1, nonce: 1)),
    )
    try await transportEventually { accepted.count == 1 }
    let (server, serverInbox) = try #require(accepted.all.first)
    let cancellations = UInt64(QUICOptions.concurrentSnapshotStreams) * 3
    for stream in 1 ... cancellations {
      await #expect(throws: RSTTransportError.canceled) {
        try await server.sendSnapshot(
          snapshotPayload(bodyLength: 100, fill: UInt8(stream)),
          stream: stream,
          beforeRegistration: { server.cancelSnapshot(stream: stream) },
        )
      }
    }
    #expect(server.admittedSnapshotSendsForTesting == 0)
    var delivered: [[UInt8]] = []
    for offset in 1 ... UInt64(QUICOptions.concurrentSnapshotStreams) * 2 {
      let replacement = snapshotPayload(
        bodyLength: 100,
        fill: 0x80 + UInt8(offset)
      )
      try await server.sendSnapshot(replacement, stream: cancellations + offset)
      delivered.append(replacement)
      try await transportEventually { inbox.snapshots == delivered }
    }
    try await client.sendControl(
      ControlRecord.encode(.ping(epoch: 1, nonce: 2)),
    )
    try await transportEventually { serverInbox.messages.count == 2 }
    try await server.sendControl(
      ControlRecord.encode(.ping(epoch: 1, nonce: 3)),
    )
    try await transportEventually { inbox.messages.count == 1 }
    #expect(!inbox.closed)
    #expect(!serverInbox.closed)
  }

  @Test
  func `replacing a pending snapshot settles both senders`() async throws {
    let (listener, accepted) = try await startListener()
    defer { listener.stop() }
    let client = try await connector()
      .connectQUIC(
        host: "127.0.0.1",
        port: listener.port,
        pin: loopbackIdentity.pin,
      )
    defer { client.close() }
    let inbox = Inbox()
    client.start(inbox.handler)
    try await client.sendControl(
      ControlRecord.encode(.ping(epoch: 1, nonce: 1)),
    )
    try await transportEventually { accepted.count == 1 }
    let (server, _) = try #require(accepted.all.first)
    let firstResult = Mutex<RSTTransportError?>(nil)
    let replacementRegistered = Mutex(false)
    server.queue.suspend()
    var suspended = true
    Task {
      do {
        try await server.sendSnapshot(
          snapshotPayload(bodyLength: 100, fill: 1),
          stream: 1,
        )
        Issue.record("superseded snapshot completed successfully")
      } catch { firstResult.withLock { $0 = error as? RSTTransportError } }
    }
    do {
      try await transportEventually(.seconds(2)) {
        server.pendingSnapshotSendsForTesting == 1
      }
      let replacement = Task {
        try await server.sendSnapshot(
          snapshotPayload(bodyLength: 100, fill: 2),
          stream: 1,
          beforeRegistration: { replacementRegistered.withLock { $0 = true } },
        )
      }
      try await transportEventually(.seconds(2)) {
        replacementRegistered.withLock { $0 }
      }
      do {
        try await transportEventually(.seconds(2)) {
          firstResult.withLock { $0 != nil }
        }
      } catch { Issue.record("superseded snapshot sender never settled") }
      server.queue.resume()
      suspended = false
      try await replacement.value
    } catch {
      if suspended { server.queue.resume() }
      throw error
    }
    #expect(firstResult.withLock { $0 } == .canceled)
    let newer = snapshotPayload(bodyLength: 100, fill: 2)
    try await transportEventually { inbox.snapshots.contains(newer) }
    #expect(inbox.snapshots.count(where: { $0 == newer }) == 1)
    #expect(
      inbox.snapshots.allSatisfy {
        $0 == newer || $0 == snapshotPayload(bodyLength: 100, fill: 1)
      },
    )
    #expect(!inbox.closed)
  }

  @Test
  func `control records round trip in both directions`() async throws {
    let (listener, accepted) = try await startListener()
    defer { listener.stop() }
    #expect(listener.port != 0)

    let client = try await connector()
      .connectQUIC(
        host: "127.0.0.1",
        port: listener.port,
        pin: loopbackIdentity.pin,
      )
    defer { client.close() }
    #expect(client.negotiatedALPN == RSTLimits.alpn)
    let clientInbox = Inbox()
    client.start(clientInbox.handler)

    for nonce in 1 ... 3 as ClosedRange<UInt64> {
      try await client.sendControl(
        ControlRecord.encode(.ping(epoch: 1, nonce: nonce)),
      )
    }
    try #require(await eventually { accepted.all.first?.1.messages.count == 3 })
    let (server, serverInbox) = try #require(accepted.all.first)
    #expect(
      serverInbox.messages
        == (1 ... 3).map { ControlMessage.ping(epoch: 1, nonce: $0) },
    )

    // Several records in one write still decode in order.
    var batch: [UInt8] = []
    for nonce in 1 ... 3 as ClosedRange<UInt64> {
      batch += try ControlRecord.encode(.pong(epoch: 1, nonce: nonce))
    }
    try await server.sendControl(batch)
    try #require(await eventually { clientInbox.messages.count == 3 })
    #expect(
      clientInbox.messages
        == (1 ... 3).map { ControlMessage.pong(epoch: 1, nonce: $0) },
    )

    client.close()
    try #require(await eventually { serverInbox.closed && clientInbox.closed })
    try #require(await eventually { listener.activeConnectionCount == 0 })
  }

  @Test
  func `slow onControl applies backpressure in order`() async throws {
    // A slow consumer: concurrent onControl calls would overlap.
    let tracker = OverlapTracker()
    let listener = QUICRSTListener(
      identity: loopbackIdentity,
      configuration: .init(host: "127.0.0.1"),
    )
    try await listener.start { connection in
      connection.start(
        RSTConnectionHandler(
          onControl: { bytes in
            tracker.enter(bytes.count)
            try? await Task.sleep(for: .milliseconds(20))
            tracker.leave()
            tracker.consumed(bytes.count)
          },
          onClosed: { _ in },
        ),
      )
    }
    defer { listener.stop() }
    let client = try await connector()
      .connectQUIC(
        host: "127.0.0.1",
        port: listener.port,
        pin: loopbackIdentity.pin,
      )
    defer { client.close() }
    var total = 0
    for nonce in 1 ... 10 as ClosedRange<UInt64> {
      let record = try ControlRecord.encode(.ping(epoch: 1, nonce: nonce))
      total += record.count
      try await client.sendControl(record)
    }
    try #require(await eventually { tracker.bytes == total })
    #expect(tracker.maxConcurrent == 1)
  }

  @Test
  func `one connection carries far more snapshots than the stream limit`()
    async throws
  {
    // QUIC stream credit is cumulative: the client must keep extending
    // it or the server stalls after its initial allowance.
    let (listener, accepted) = try await startListener()
    defer { listener.stop() }
    let client = try await connector()
      .connectQUIC(
        host: "127.0.0.1",
        port: listener.port,
        pin: loopbackIdentity.pin,
      )
    defer { client.close() }
    let inbox = Inbox()
    client.start(inbox.handler)
    try await client.sendControl(
      ControlRecord.encode(.ping(epoch: 1, nonce: 1)),
    )
    try await transportEventually { accepted.count == 1 }
    let (server, _) = try #require(accepted.all.first)
    for id in 1 ... 60 as ClosedRange<UInt64> {
      try await server.sendSnapshot(
        snapshotPayload(bodyLength: 200, fill: UInt8(id)),
        stream: id,
      )
      try await transportEventually { inbox.snapshots.count == Int(id) }
    }
  }

  @Test
  func `snapshot streams deliver complete payloads and drop a canceled one`()
    async throws
  {
    var stage = "listener"
    do {
      let (listener, accepted) = try await startListener()
      defer { listener.stop() }
      stage = "connect"
      let client = try await connector()
        .connectQUIC(
          host: "127.0.0.1",
          port: listener.port,
          pin: loopbackIdentity.pin,
        )
      defer { client.close() }
      let inbox = Inbox()
      client.start(inbox.handler)
      stage = "initial control"
      try await client.sendControl(
        ControlRecord.encode(.ping(epoch: 1, nonce: 1)),
      )
      stage = "accepted server"
      try #require(await eventually { accepted.count == 1 })
      let (server, _) = try #require(accepted.all.first)
      client.enableSnapshotReadDiagnosticsForTesting()
      server.enableSnapshotReadDiagnosticsForTesting()

      let small = snapshotPayload(bodyLength: 1000, fill: 0xA1)
      let medium = snapshotPayload(bodyLength: 300_000, fill: 0xB2)
      let huge = snapshotPayload(
        bodyLength: RSTLimits.maxSnapshotEncodedBytes,
        fill: 0xC3,
      )
      let last = snapshotPayload(bodyLength: 50000, fill: 0xD4)

      stage = "small snapshot"
      try await server.sendSnapshot(small, stream: 1)
      stage = "medium snapshot"
      try await server.sendSnapshot(medium, stream: 2)
      // Race cancellation with a queued 4 MiB send. It may finish before
      // the delay elapses; the partial-reset test guarantees an open stream.
      let hugeSend = Task { try await server.sendSnapshot(huge, stream: 3) }
      try await Task.sleep(for: .milliseconds(5))
      let beforeCancellation = """
        server: \(server.snapshotDiagnosticsForTesting)
        client: \(client.snapshotDiagnosticsForTesting)
        """
      server.cancelSnapshot(stream: 3)
      stage = "canceled huge snapshot completion"
      let hugeResult = await hugeSend.result
      let afterCancellation = """
        server: \(server.snapshotDiagnosticsForTesting)
        client: \(client.snapshotDiagnosticsForTesting)
        """
      stage = "final snapshot"
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await server.sendSnapshot(last, stream: 4) }
        group.addTask {
          try await Task.sleep(for: .seconds(5))
          Issue.record(
            """
            final snapshot send stalled before cancellation:
            server: \(server.snapshotDiagnosticsForTesting)
            client: \(client.snapshotDiagnosticsForTesting)
            before huge snapshot cancellation:
            \(beforeCancellation)
            after huge snapshot cancellation:
            \(afterCancellation)
            received payload sizes: \(inbox.snapshots.map(\.count))
            inbox closed: \(inbox.closed), error: \(String(describing: inbox.closeError))
            """
          )
          throw TimedOut(line: #line)
        }
        defer { group.cancelAll() }
        _ = try await group.next()
      }

      stage = "snapshot delivery"
      try #require(await eventually { inbox.snapshots.contains(last) })
      try await Task.sleep(for: .milliseconds(200))
      let received = inbox.snapshots
      #expect(received.contains(small))
      #expect(received.contains(medium))
      // Never a partial payload: anything delivered is one of the sends.
      for payload in received {
        #expect([small, medium, huge, last].contains(payload))
      }
      #expect(received.count(where: { $0 == huge }) <= 1)
      // Canceled before its send completed (bytes already queued in QUIC
      // may still arrive whole, which is allowed).
      if case let .failure(error) = hugeResult {
        #expect(error as? RSTTransportError == .canceled)
      }
      // A pre-canceled id never opens a stream.
      stage = "pre-canceled snapshot"
      server.cancelSnapshot(stream: 9)
      await #expect(throws: RSTTransportError.canceled) {
        try await server.sendSnapshot(small, stream: 9)
      }
    } catch {
      Issue.record("snapshot scenario failed during \(stage): \(error)")
      throw error
    }
  }

  /// On macOS 27.0.1 (the GitHub xcode-27 runner) cancelling a partially
  /// sent stream can abort the whole QUIC connection: the client sees a clean
  /// FIN, then both control streams fail (ENOTCONN / ECONNABORTED) with no
  /// application error. 27.2 resets only the stream, as this test requires.
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(
          majorVersion: 27,
          minorVersion: 2,
          patchVersion: 0
        )
      ),
      "Network framework before macOS 27.2 aborts the connection on stream reset"
    ),
    arguments: [
      5000, QUICOptions.snapshotStreamWindow + 5000,
      2 * QUICOptions.snapshotStreamWindow + 5000,
    ]
  )
  func `a reset partial stream is never delivered`(
    _ partialLength: Int
  ) async throws {
    let (listener, accepted) = try await startListener()
    defer { listener.stop() }
    let client = try await connector()
      .connectQUIC(
        host: "127.0.0.1",
        port: listener.port,
        pin: loopbackIdentity.pin,
      )
    defer { client.close() }
    let inbox = Inbox()
    client.start(inbox.handler)
    try await client.sendControl(
      ControlRecord.encode(.ping(epoch: 1, nonce: 1)),
    )
    try #require(await eventually { accepted.count == 1 })
    let (server, _) = try #require(accepted.all.first)

    client.enableSnapshotReadDiagnosticsForTesting()
    let full = snapshotPayload(
      bodyLength: RSTLimits.maxSnapshotEncodedBytes,
      fill: 0x11
    )
    // Name the failing step: CI (macOS 27.0.1, release) has reported a bare
    // ENOTCONN here that does not reproduce locally.
    var stage = "partial send"
    do {
      let partial = try await server.sendRawStreamForTesting(
        Array(full.prefix(partialLength)),
        finish: false,
      )
      stage = "partial read"
      try await transportEventually {
        client.snapshotReadBytesForTesting.contains(partialLength)
      }
      partial.cancel()
      // FIN after a truncated body is not a complete snapshot either.
      stage = "truncated send"
      _ = try await server.sendRawStreamForTesting(
        Array(full.prefix(7000)),
        finish: true,
      )
      stage = "good send"
      let good = snapshotPayload(bodyLength: 50000, fill: 0x22)
      try await server.sendSnapshot(good, stream: 1)
      stage = "good delivery"
      try #require(await eventually { !inbox.snapshots.isEmpty })
      try await Task.sleep(for: .milliseconds(200))
      #expect(inbox.snapshots == [good])
      stage = "read release"
      try await transportEventually {
        client.snapshotReadBytesForTesting.isEmpty
      }
    } catch {
      Issue.record(
        """
        reset scenario failed during \(stage): \(error); \
        clientClosed=\(client.isClosed) serverClosed=\(server.isClosed) \
        reads=\(client.snapshotReadBytesForTesting)
        client: \(client.snapshotDiagnosticsForTesting)
        server: \(server.snapshotDiagnosticsForTesting)
        """
      )
      throw error
    }
  }

  @Test
  func `an empty snapshot stream returns its credit without delivery`()
    async throws
  {
    let (listener, accepted) = try await startListener()
    defer { listener.stop() }
    let client = try await connector()
      .connectQUIC(
        host: "127.0.0.1",
        port: listener.port,
        pin: loopbackIdentity.pin,
      )
    defer { client.close() }
    let inbox = Inbox()
    client.start(inbox.handler)
    try await client.sendControl(
      ControlRecord.encode(.ping(epoch: 1, nonce: 1)),
    )
    try #require(await eventually { accepted.count == 1 })
    let (server, _) = try #require(accepted.all.first)

    // A snapshot abandoned before its write ends as an empty stream.
    _ = try await server.sendRawStreamForTesting([], finish: true)
    try await transportEventually {
      client.snapshotDiagnosticsForTesting.contains("released=1,")
    }
    let good = snapshotPayload(bodyLength: 32, fill: 0x44)
    try await server.sendSnapshot(good, stream: 1)
    try #require(await eventually { !inbox.snapshots.isEmpty })
    #expect(inbox.snapshots == [good])
    #expect(!client.isClosed)
    #expect(!server.isClosed)
  }

  @Test
  func `superseded snapshot streams retire once the client releases them`()
    async throws
  {
    let (listener, accepted) = try await startListener()
    defer { listener.stop() }
    let client = try await connector()
      .connectQUIC(
        host: "127.0.0.1",
        port: listener.port,
        pin: loopbackIdentity.pin,
      )
    defer { client.close() }
    let inbox = Inbox()
    client.start(inbox.handler)
    try await client.sendControl(
      ControlRecord.encode(.ping(epoch: 1, nonce: 1)),
    )
    try #require(await eventually { accepted.count == 1 })
    let (server, _) = try #require(accepted.all.first)
    server.enableSnapshotReadDiagnosticsForTesting()

    let limit = QUICRSTConnection.maxTrackedOutbound
    for id in 1 ... UInt64(limit + 2) {
      try await server.sendSnapshot(
        snapshotPayload(bodyLength: 32, fill: UInt8(id)),
        stream: id
      )
      server.cancelSnapshot(stream: id)
    }
    try await transportEventually {
      client.snapshotDiagnosticsForTesting.contains("released=\(limit + 2),")
    }
    try await transportEventually {
      server.snapshotDiagnosticsForTesting.contains("retiring=0,")
    }
    #expect(server.snapshotDiagnosticsForTesting.contains("outbound retire,"))
    let good = snapshotPayload(bodyLength: 32, fill: 0x55)
    try await server.sendSnapshot(good, stream: 100)
    try await transportEventually { inbox.snapshots.last == good }
    #expect(!client.isClosed)
    #expect(!server.isClosed)
  }

  @Test
  func `oversized and overlong snapshot streams are discarded`() async throws {
    let (listener, accepted) = try await startListener()
    defer { listener.stop() }
    let client = try await connector()
      .connectQUIC(
        host: "127.0.0.1",
        port: listener.port,
        pin: loopbackIdentity.pin,
      )
    defer { client.close() }
    let inbox = Inbox()
    client.start(inbox.handler)
    try await client.sendControl(
      ControlRecord.encode(.ping(epoch: 1, nonce: 1)),
    )
    try #require(await eventually { accepted.count == 1 })
    let (server, _) = try #require(accepted.all.first)

    // Header claims more than the 4 MiB bound.
    var oversized = snapshotPayload(bodyLength: 16, fill: 0)
    let tooBig = UInt32(RSTLimits.maxSnapshotEncodedBytes + 1)
    for offset in [1, 5] {
      oversized[offset] = UInt8(tooBig >> 24)
      oversized[offset + 1] = UInt8(tooBig >> 16 & 0xFF)
      oversized[offset + 2] = UInt8(tooBig >> 8 & 0xFF)
      oversized[offset + 3] = UInt8(tooBig & 0xFF)
    }
    _ = try await server.sendRawStreamForTesting(oversized, finish: true)
    // More bytes than the header announced.
    let overlong = snapshotPayload(bodyLength: 100, fill: 1) + [1, 2, 3]
    _ = try await server.sendRawStreamForTesting(overlong, finish: true)
    // The sender refuses to exceed the bound itself.
    await #expect(throws: RSTTransportError.snapshotTooLarge) {
      try await server.sendSnapshot(
        [UInt8](repeating: 0, count: SnapshotStreamAccumulator.hardLimit + 1),
        stream: 7,
      )
    }

    let good = snapshotPayload(bodyLength: 32, fill: 0x33)
    try await server.sendSnapshot(good, stream: 1)
    try #require(await eventually { !inbox.snapshots.isEmpty })
    try await Task.sleep(for: .milliseconds(200))
    #expect(inbox.snapshots == [good])
    #expect(!inbox.closed)
  }

  @Test
  func `wrong pin fails closed before application data`() async throws {
    let (listener, accepted) = try await startListener()
    defer { listener.stop() }
    let other = try HostIdentity.generate(hostnames: ["localhost"])

    await #expect(throws: RSTTransportError.pinMismatch) {
      _ = try await connector()
        .connect(host: "127.0.0.1", port: listener.port, pin: other.pin)
    }
    try await Task.sleep(for: .milliseconds(200))
    #expect(accepted.count == 0)
    #expect(listener.activeConnectionCount == 0)
  }

  @Test
  func `changed SPKI pin fails the handshake before application data`()
    async throws
  {
    let (listener, accepted) = try await startListener()
    defer { listener.stop() }
    // The grant names another key: the server's leaf fails the SPKI
    // check in the verify block, so no connection (and no Attach with
    // the token) ever reaches the server.
    let other = try HostIdentity.generate(hostnames: ["localhost"])
    let pin = try CertificatePin(
      certificateDER: other.certificateDER,
      sha256: other.certificateSHA256,
      spkiSHA256: other.spkiSHA256,
    )
    #expect(throws: CertificatePinError.spkiMismatch) {
      try pin.validate(leafDER: loopbackIdentity.certificateDER)
    }
    await #expect(throws: RSTTransportError.pinMismatch) {
      _ = try await connector()
        .connect(host: "127.0.0.1", port: listener.port, pin: pin)
    }
    try await Task.sleep(for: .milliseconds(200))
    #expect(accepted.count == 0)
    #expect(listener.activeConnectionCount == 0)
  }

  @Test
  func `pin with matching hash but different DER cannot be built`() throws {
    let other = try HostIdentity.generate()
    #expect(throws: CertificatePinError.inconsistentPin) {
      try CertificatePin(
        certificateDER: other.certificateDER,
        sha256: loopbackIdentity.certificateSHA256,
      )
    }
  }

  @Test
  func `ALPN mismatch fails the handshake`() async throws {
    let (listener, accepted) = try await startListener()
    defer { listener.stop() }
    await #expect(throws: RSTTransportError.self) {
      _ = try await connector("rst/0", timeout: .seconds(2))
        .connect(
          host: "127.0.0.1",
          port: listener.port,
          pin: loopbackIdentity.pin,
        )
    }
    try await Task.sleep(for: .milliseconds(200))
    #expect(accepted.count == 0)
  }

  @Test
  func `listener caps concurrent connections`() async throws {
    let (listener, accepted) = try await startListener(
      .init(host: "127.0.0.1", maxConnections: 2),
    )
    defer { listener.stop() }
    let pin = loopbackIdentity.pin
    let first = try await connector()
      .connectQUIC(host: "127.0.0.1", port: listener.port, pin: pin)
    defer { first.close() }
    let second = try await connector()
      .connectQUIC(host: "127.0.0.1", port: listener.port, pin: pin)
    defer { second.close() }
    try #require(await eventually { accepted.count == 2 })

    // The third group is refused; depending on when Network hands the
    // group to the listener the client either fails to connect or sees
    // the connection closed straight away.
    let inbox = Inbox()
    do {
      let third = try await connector(timeout: .seconds(2))
        .connectQUIC(host: "127.0.0.1", port: listener.port, pin: pin)
      defer { third.close() }
      third.start(inbox.handler)
      try #require(await eventually { inbox.closed })
    } catch {}
    #expect(listener.rejectedConnectionCount >= 1)
    #expect(listener.activeConnectionCount == 2)
    #expect(accepted.count == 2)

    first.close()
    try #require(await eventually { listener.activeConnectionCount == 1 })
    let fourth = try await connector()
      .connectQUIC(host: "127.0.0.1", port: listener.port, pin: pin)
    defer { fourth.close() }
    try #require(await eventually { accepted.count == 3 })
  }

  @Test
  func `listener rate-limits new handshakes`() async throws {
    let (listener, accepted) = try await startListener(
      .init(host: "127.0.0.1", handshakesPerSecond: 0.01, handshakeBurst: 1),
    )
    defer { listener.stop() }
    let first = try await connector()
      .connectQUIC(
        host: "127.0.0.1",
        port: listener.port,
        pin: loopbackIdentity.pin,
      )
    defer { first.close() }
    do {
      let second = try await connector(timeout: .seconds(2))
        .connectQUIC(
          host: "127.0.0.1",
          port: listener.port,
          pin: loopbackIdentity.pin,
        )
      defer { second.close() }
      let inbox = Inbox()
      second.start(inbox.handler)
      try #require(await eventually { inbox.closed })
    } catch {}
    #expect(listener.rejectedConnectionCount >= 1)
    try #require(await eventually { accepted.count == 1 })
  }

  @Test
  func `closing the listener closes its connections`() async throws {
    let (listener, accepted) = try await startListener()
    defer { listener.stop() }
    let client = try await connector()
      .connectQUIC(
        host: "127.0.0.1",
        port: listener.port,
        pin: loopbackIdentity.pin,
      )
    defer { client.close() }
    let inbox = Inbox()
    client.start(inbox.handler)
    try #require(await eventually { accepted.count == 1 })
    listener.stop()
    try #require(await eventually { inbox.closed })
    await #expect(throws: (any Error).self) {
      try await client.sendControl(
        ControlRecord.encode(.ping(epoch: 1, nonce: 1)),
      )
    }
  }
}

final class OverlapTracker: Sendable {
  private struct State {
    var current = 0
    var maxConcurrent = 0
    var bytes = 0
  }

  private let state = Mutex(State())

  func enter(_ count: Int) {
    state.withLock {
      $0.current += 1
      $0.maxConcurrent = max($0.maxConcurrent, $0.current)
    }
  }

  func leave(_ count: Int = 0) { state.withLock { $0.current -= 1 } }

  /// Bytes fully consumed (counted on exit so a test waits for the end).
  func consumed(_ count: Int) { state.withLock { $0.bytes += count } }

  var maxConcurrent: Int { state.withLock { $0.maxConcurrent } }

  var bytes: Int { state.withLock { $0.bytes } }
}
#endif
