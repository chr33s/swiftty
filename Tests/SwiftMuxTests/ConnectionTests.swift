import Dispatch
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
import Synchronization
import Testing
import TestSupport

/// `MuxConnection` request, detach, record-size and paste rules.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ConnectionTests {
  @Test(arguments: [false, true])
  func channelCannotReconnectAfterReportingPeerClosure(
    _ reentrant: Bool
  ) async throws {
    let queue = DispatchQueue(label: "closed-channel-send-test")
    let listener = SMXListener(anonymousOn: queue)
    let channels = Mutex<[SMXChannel]>([])
    let received = Mutex<[UInt8]>([])
    let reasons = Mutex<[String]>([])
    listener.activate(connectionQueue: queue) { channel in
      channels.withLock { $0.append(channel) }
      channel.activate { event in
        if case let .message(data) = event {
          if let byte = data.first { received.withLock { $0.append(byte) } }
          channel.cancel()
        }
      }
    }
    let client = SMXChannel.connect(endpoint: listener.endpoint, queue: queue)
    client.activate { [weak client] event in
      if case let .closed(reason) = event {
        reasons.withLock { $0.append(reason) }
        if reentrant { client?.send(Data(repeating: 3, count: 8)) }
      }
    }
    defer {
      client.cancel()
      channels.withLock { $0 }.forEach { $0.cancel() }
      listener.cancel()
    }
    client.send(Data(repeating: 1, count: 8))
    for _ in 0 ..< 200 where reasons.withLock({ $0.isEmpty }) {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(reasons.withLock { $0.count } == 1)
    try #require(received.withLock { $0 } == [1])
    if !reentrant { client.send(Data(repeating: 3, count: 8)) }
    for _ in 0 ..< 50 where channels.withLock({ $0.count }) == 1 {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(
      channels.withLock { $0.count } == 1,
      "closure reasons: \(reasons.withLock { $0 })"
    )
    #expect(received.withLock { $0 } == [1])
  }

  @Test(arguments: [false, true])
  func channelRejectsOversizedRecords(holdClientCallbacks: Bool) async throws {
    let queue = DispatchQueue(label: "record-limit-test")
    let listener = SMXListener(anonymousOn: queue)
    let channels = Mutex<[SMXChannel]>([])
    let received = Mutex<[Int]>([])
    let closed = Mutex(0)
    let closedReasons = Mutex<[String]>([])
    let events = Mutex<[String]>([])
    let clientClosed = Mutex(false)
    listener.activate(connectionQueue: queue) { channel in
      let index = channels.withLock { channels in
        channels.append(channel)
        return channels.count
      }
      events.withLock {
        if $0.count < 32 { $0.append("accepted channel \(index)") }
      }
      channel.activate { event in
        switch event {
        case let .message(data):
          received.withLock { $0.append(data.count) }
          events.withLock {
            if $0.count < 32 {
              $0.append(
                "channel \(index) message bytes=\(data.count) first=\(data.first.map(String.init) ?? "nil")"
              )
            }
          }
        case let .closed(reason):
          events.withLock {
            if $0.count < 32 { $0.append("channel \(index) closed: \(reason)") }
          }
          closedReasons.withLock { $0.append(reason) }
          closed.withLock { $0 += 1 }
        }
      }
    }
    let clientQueue =
      holdClientCallbacks
      ? DispatchQueue(label: "record-limit-client-held") : queue
    let client = SMXChannel.connect(
      endpoint: listener.endpoint,
      queue: clientQueue
    )
    client.activate { event in
      if case let .closed(reason) = event {
        events.withLock {
          if $0.count < 32 { $0.append("client closed: \(reason)") }
        }
        clientClosed.withLock { $0 = true }
      }
    }
    var callbacksHeld = holdClientCallbacks
    if callbacksHeld { clientQueue.suspend() }
    defer {
      if callbacksHeld { clientQueue.resume() }
      client.cancel()
      channels.withLock { $0 }.forEach { $0.cancel() }
      listener.cancel()
    }
    client.send(Data(repeating: 1, count: 8))
    client.send(
      Data(repeating: 2, count: SMXCodec.serverRecordLimit(.standard) + 1)
    )
    client.send(Data(repeating: 3, count: 8))
    for _ in 0 ..< 200 {
      if closed.withLock({ $0 }) > 0 {
        if callbacksHeld {
          callbacksHeld = false
          clientQueue.resume()
        }
        if clientClosed.withLock({ $0 }) { break }
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    if callbacksHeld {
      callbacksHeld = false
      clientQueue.resume()
    }
    #expect(
      received.withLock { $0 } == [8],
      """
      accepted channels: \(channels.withLock { $0.count })
      closed reasons: \(closedReasons.withLock { $0 })
      channel events: \(events.withLock { $0 })
      """,
    )
    #expect(closed.withLock { $0 } == 1)
    #expect(clientClosed.withLock { $0 })
  }

  @Test(arguments: [false, true])
  func channelUsesCurrentReceiveLimit(_ clientReceives: Bool) async throws {
    let queue = DispatchQueue(label: "changing-record-limit-test")
    let listener = SMXListener(anonymousOn: queue)
    let channels = Mutex<[SMXChannel]>([])
    let limit = Mutex(8)
    let received = Mutex<[Int]>([])
    let closed = Mutex(0)
    let receive: @Sendable (SMXChannel.Event) -> Void = { event in
      switch event {
      case let .message(data):
        received.withLock { $0.append(data.count) }
        limit.withLock { $0 = 4 }
      case .closed: closed.withLock { $0 += 1 }
      }
    }
    let send: @Sendable (SMXChannel) -> Void = { channel in
      channel.send(Data(repeating: 1, count: 8))
      channel.send(Data(repeating: 2, count: 5))
      channel.send(Data(repeating: 3, count: 3))
    }
    listener.activate(connectionQueue: queue) { channel in
      channels.withLock { $0.append(channel) }
      if clientReceives {
        channel.activate { _ in }
        send(channel)
      } else {
        channel.activate(recordLimit: { limit.withLock { $0 } }, receive)
      }
    }
    let client = SMXChannel.connect(endpoint: listener.endpoint, queue: queue)
    defer {
      client.cancel()
      channels.withLock { $0 }.forEach { $0.cancel() }
      listener.cancel()
    }
    if clientReceives {
      client.activate(recordLimit: { limit.withLock { $0 } }, receive)
      // Anonymous XPC connections reach the listener on their first send.
      client.send(Data([0]))
    } else {
      client.activate { _ in }
      send(client)
    }
    for _ in 0 ..< 200 where closed.withLock({ $0 }) == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(received.withLock { $0 } == [8])
    #expect(closed.withLock { $0 } == 1)
  }

  /// A service stand-in that answers the handshake and `attach` but never
  /// `detach`, and records whether the client's channel ended.
  final class SilentService: @unchecked Sendable {
    let listener: SMXListener
    let queue = DispatchQueue(label: "silent-service")
    let closed = Mutex(false)
    let requests = Mutex(0)
    private let channels = Mutex<[SMXChannel]>([])

    init() {
      listener = SMXListener(anonymousOn: queue)
      listener.activate(connectionQueue: queue) { [weak self] channel in
        guard let self else {
          channel.cancel()
          return
        }
        channels.withLock { $0.append(channel) }
        channel.activate { [weak self, weak channel] event in
          guard let self, let channel else {
            channel?.cancel()
            return
          }
          switch event {
          case .closed: closed.withLock { $0 = true }
          case let .message(data): answer(data, on: channel)
          }
        }
      }
    }

    private func answer(_ data: Data, on channel: SMXChannel) {
      guard
        let message = try? SMXCodec.decode(
          ClientMessage.self,
          from: data,
          limit: 1 << 20
        )
      else { return }
      if case .request = message { requests.withLock { $0 += 1 } }
      let reply: ServerMessage
      switch message {
      case .hello:
        reply = .welcome(
          Welcome(
            protocolVersion: SMX.protocolVersion,
            build: SMX.build,
            server: ServerInstanceID(),
            acceptedProfile: nil,
            limits: .standard,
            innerTerm: "xterm-256color"
          )
        )
      case let .request(id, .attach):
        reply = .reply(
          id: id,
          result: .success(
            .attached(
              attachment: AttachmentID(),
              workspace: WorkspaceSnapshot(
                id: WorkspaceID(),
                name: "silent",
                tabs: [],
                activeTab: TabID(),
                panes: [],
                layoutRevision: 1
              )
            )
          )
        )
      default: return
      }
      if let data = try? SMXCodec.encode(reply, limit: 1 << 20) {
        channel.send(data)
      }
    }

    func stop() {
      listener.cancel()
      channels.withLock { $0 }.forEach { $0.cancel() }
    }

    deinit { stop() }
  }

  @Test
  func releasingSilentServiceClosesItsAcceptedConnections() async throws {
    var service: SilentService? = SilentService()
    weak let weakService = service
    defer { weakService?.stop() }
    let connection = try await MuxConnection.connect(
      endpoint: #require(service).listener.endpoint,
      frontend: .native,
    )
    try await RuntimeFixture.withCleanup {
      service = nil
      for _ in 0 ..< 100 where weakService != nil {
        try await Task.sleep(for: .milliseconds(10))
      }
      try #require(weakService == nil)
      let event = try await withTimeout(.seconds(2)) {
        try? await connection.nextEvent()
      }
      #expect(event == nil)
    } cleanup: {
      await connection.close()
    }
  }

  /// Quit, window replacement and `swmux` detach wait on this: a service
  /// that never answers must not hang them, and the lease it holds is
  /// released by closing the connection.
  @Test
  func detachIsBoundedWhenTheServiceDoesNotAnswer() async throws {
    let service = SilentService()
    let c = try await MuxConnection.connect(
      endpoint: service.listener.endpoint,
      frontend: .native
    )
    _ = try await c.execute(.attach(AttachRequest(.name("silent"))))
    await c.setDetachTimeout(.milliseconds(200))
    let start = ContinuousClock.now
    try await withTimeout(.seconds(10)) { await c.detach() }
    #expect(ContinuousClock.now - start < .seconds(5))
    #expect(await c.attachment == nil)
    // The connection was closed, which releases the lease.
    #expect(await (try? c.nextEvent()) == nil)
    for _ in 0 ..< 200 where !service.closed.withLock({ $0 }) {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(service.closed.withLock { $0 })
  }

  /// Closing rejects new commands while the event consumer sees EOF.
  @Test
  func requestsAfterDeliberateCloseFailImmediately() async throws {
    let h = try Harness()
    let c = try await h.connect()
    await c.close()
    await #expect {
      try await c.execute(.listWorkspaces, timeout: .milliseconds(100))
    } throws: { ($0 as? MuxError) == MuxError(.connectionLost, "closed") }
    #expect(try await c.nextEvent() == nil)
  }

  /// A task cancelled before dispatch must not acquire a lease.
  @Test
  func anAlreadyCancelledTaskSendsNoRequest() async throws {
    let service = SilentService()
    let c = try await MuxConnection.connect(
      endpoint: service.listener.endpoint,
      frontend: .native,
    )
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await c.execute(.attach(AttachRequest(.name("silent"))))
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    // A following request is answered after any earlier message on the
    // same channel, so this count needs no timing-based sleep.
    _ = try await c.execute(.attach(AttachRequest(.name("silent"))))
    #expect(service.requests.withLock { $0 } == 1)
    await c.close()
  }

  /// Cancelling the waiting task resumes `execute` once; late replies
  /// are dropped.
  @Test
  func cancellingAnUnansweredRequestStopsWaiting() async throws {
    let service = SilentService()
    let c = try await MuxConnection.connect(
      endpoint: service.listener.endpoint,
      frontend: .native
    )
    let task = Task { try await c.execute(.listWorkspaces) }
    try await Task.sleep(for: .milliseconds(50))
    task.cancel()
    await #expect(throws: CancellationError.self) {
      try await withTimeout(.seconds(5)) { try await task.value }
    }
    await #expect {
      try await c.execute(.listWorkspaces, timeout: .milliseconds(50))
    } throws: { ($0 as? MuxError)?.code == .connectionLost }
    await c.close()
  }

  /// A record too large to send is refused on its own: the connection
  /// (and the lease it holds) stays usable.
  @Test
  func anOversizedRequestIsRefusedAlone() async throws {
    let h = try Harness()
    let c = try await h.connect()
    defer { Task { await c.close() } }
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      )
    else {
      throw MuxError(.invalidRequest, "unexpected workspace creation reply")
    }
    let pane = ws.tabs[0].activePane
    try await c.attachAndShow(.id(ws.id))
    let name = String(repeating: "n", count: 300 << 10)
    await #expect {
      try await c.execute(.renameWorkspace(.id(ws.id), name: name))
    } throws: { ($0 as? MuxError)?.code == .resourceLimit }
    // Text longer than one record is split, not fatal.
    try await c.send(.text("cat > /dev/null\r"), to: pane)
    let line = String(repeating: "t", count: 63) + "\n"
    await c.post(
      .text(String(repeating: line, count: (160 << 10) / 64)),
      to: pane
    )
    await c.post(.key(.character(0x64), .control), to: pane)
    try await c.send(.text("echo alive-$((1+1))\r"), to: pane)
    _ = try await c.frame(of: pane, timeout: .seconds(20)) {
      $0.lines.contains("alive-2")
    }
    #expect(await c.attachment != nil)
  }

  /// A record that cannot be encoded fails the connection and cancels
  /// its channel, so the service releases the lease (no zombie lease
  /// refusing the next attach with `leaseHeld`); `close` after that is
  /// harmless.
  @Test
  func aFailedConnectionReleasesItsLease() async throws {
    var phase = "initial connection"
    defer {
      if phase != "completed" {
        Issue.record("Lease-release test stopped during \(phase)")
      }
    }
    let h = try Harness()
    let c = try await h.connect()
    defer { Task { await c.close() } }
    phase = "workspace creation"
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      )
    else {
      throw MuxError(.invalidRequest, "unexpected workspace creation reply")
    }
    phase = "initial attachment"
    guard
      case let .attached(attachment, _) = try await c.execute(
        .attach(AttachRequest(.id(ws.id)))
      )
    else { throw MuxError(.invalidRequest, "unexpected attachment reply") }
    let huge = String(repeating: "x", count: 300 << 10)
    phase = "oversized input rejection"
    await #expect(throws: MuxError.self) {
      try await c.submit(
        raw: InputRecord(
          sequence: 1,
          attachment: attachment,
          pane: ws.tabs[0].activePane,
          payload: .input(.text(huge))
        )
      )
    }
    phase = "initial connection close"
    await c.close()
    phase = "replacement connection"
    let other = try await h.connect()
    defer { Task { await other.close() } }
    var attached = false
    for attempt in 0 ..< 200 {
      phase = "replacement attachment attempt \(attempt)"
      if case .attached? = try? await other.execute(
        .attach(AttachRequest(.id(ws.id)))
      ) {
        attached = true
        break
      }
      phase = "replacement attachment retry delay \(attempt)"
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(attached)
    phase = "replacement connection close"
    await other.close()
    phase = "completed"
  }

  /// Two pastes to one pane in a row: the second waits for the first's
  /// envelope (the service refuses a second open paste), and input sent
  /// after it stays after it.
  @Test
  func consecutivePastesToOnePaneBothComplete() async throws {
    let h = try Harness()
    let c = try await h.connect()
    defer { Task { await c.close() } }
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      )
    else {
      throw MuxError(.invalidRequest, "unexpected workspace creation reply")
    }
    let pane = ws.tabs[0].activePane
    try await c.attachAndShow(.id(ws.id))
    // `cat` copies what the pane receives into a file, in order.
    let path = NSTemporaryDirectory() + "paste-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: path) }
    try await c.send(.text("cat > '\(path)'\r"), to: pane)
    // Redirection proves the shell has processed the command. Share the
    // original 300ms setup + 10s observation budget with the output wait.
    let deadline = ContinuousClock.now + .milliseconds(10300)
    while !FileManager.default.fileExists(atPath: path),
      ContinuousClock.now < deadline
    { try await Task.sleep(for: .milliseconds(10)) }
    try #require(
      FileManager.default.fileExists(atPath: path),
      "the shell must create the output file before pastes are submitted"
    )
    let results = Mutex<[Int: Result<PasteState, MuxError>]>([:])
    let filler = String(repeating: "filler\n", count: 8000)
    c.enqueuePaste(filler + "one\n", to: pane) { r in
      results.withLock { $0[1] = r }
    }
    c.enqueuePaste("two\n", to: pane) { r in results.withLock { $0[2] = r } }
    c.enqueue(.text("three\n"), to: pane)
    c.enqueue(.key(.character(0x64), .control), to: pane)
    var written = ""
    while ContinuousClock.now < deadline {
      written = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
      if written.hasSuffix("three\n"), results.withLock({ $0.count }) == 2 {
        break
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(try results.withLock { try $0[1]?.get() } == .completed)
    #expect(try results.withLock { try $0[2]?.get() } == .completed)
    #expect(written == filler + "one\ntwo\nthree\n")
  }
}
