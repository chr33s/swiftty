#if os(macOS)
import AppleTransport
import Foundation
import ScreenProtocol
import SessionCore
import Synchronization
import SwiftMuxProtocol
import SwifttyCore
import TerminalHost
import TerminalSurface
import Testing

/// Answers bootstrap requests the way `swifttyd bootstrap --stdio` does,
/// through the length-prefixed envelope, without an SSH hop.
struct EnvelopeBootstrapper: RemoteBootstrapper {
  let service: BootstrapService

  func bootstrap(_ request: BootstrapRequest) async throws -> BootstrapResponse
  {
    let reply = await service.respond(
      toEnvelope: try BootstrapEnvelope.encode(request)
    )
    return try BootstrapEnvelope.decode(BootstrapResponse.self, from: reply)
  }
}

/// The real stack over loopback QUIC: registry and authoritative terminal
/// on a real PTY, pinned QUIC transport, roaming client, and a
/// presentation-mode Swiftty session as the display.
final class ConnectionLog: Sendable {
  let list = Mutex<[any RSTConnection]>([])
}

@Suite(.serialized)
struct RoamingEndToEndTests {
  final class Harness: Sendable {
    let listener: QUICRSTListener
    let registry: SessionRegistry
    let service: BootstrapService
    let serverConnections: ConnectionLog
    private let shutdownTask = Mutex<Task<Void, Never>?>(nil)

    /// Set when clients reach the listener through an address-changing relay.
    let relay: RebindingUDPRelay?

    init(loginShell: Bool = false, throughRelay: Bool = false) async throws {
      let identity = try AppleTransport.HostIdentity.generate(ipAddresses: [
        "127.0.0.1"
      ])
      listener = QUICRSTListener(
        identity: identity,
        configuration: .init(host: "127.0.0.1", port: 0)
      )
      let pending = Mutex<SessionRegistry?>(nil)
      let connections = ConnectionLog()
      serverConnections = connections
      try await listener.start { connection in
        connections.list.withLock { $0.append(connection) }
        pending.withLock { $0 }?.accept(connection)
      }
      let relay =
        throughRelay ? try RebindingUDPRelay(serverPort: listener.port) : nil
      self.relay = relay
      let relayPort = relay?.port
      let home = NSTemporaryDirectory()
      let registry = SessionRegistry(
        service: try makeService(),
        identity: TerminalHost.HostIdentity(
          endpoint: BootstrapEndpoint(
            host: "127.0.0.1",
            port: relayPort ?? listener.port
          ),
          certificate: HostCertificate(der: identity.certificateDER)
        ),
        launch: {
          if loginShell { return RoamingHost.defaultLaunch() }
          return LaunchSpec(
            command: ["/bin/sh"],
            workingDirectory: home,
            environment: [
              "PATH": "/usr/bin:/bin", "HOME": home, "PS1": "$ ",
              "LANG": "en_US.UTF-8",
            ]
          )
        }
      )
      pending.withLock { $0 = registry }
      self.registry = registry
      service = BootstrapService(registry: registry)
    }

    func makeClient(display: TerminalSession) -> RoamingClient {
      RoamingClient(
        bootstrapper: EnvelopeBootstrapper(service: service),
        connector: QUICGrantConnector(),
        sink: display
      )
    }

    /// The shell PID of a session's pane in the SwiftMux service.
    func pid(_ id: SessionID) async -> pid_t? {
      guard let session = registry.session(id) else { return nil }
      return await shellPID(registry, session)
    }

    func shutdown() async {
      let shutdown = shutdownTask.withLock { task in
        if let task { return task }
        let shutdown = Task {
          relay?.stop()
          await withCheckedContinuation { continuation in
            registry.service.prepareToExit { continuation.resume() }
          }
          listener.stop()
        }
        task = shutdown
        return shutdown
      }
      await shutdown.value
    }
  }

  func waitFor(
    _ what: String,
    timeout: Duration = .seconds(15),
    _ condition: () async -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
      guard ContinuousClock.now < deadline else {
        Issue.record("timed out waiting for \(what)")
        throw CancellationError()
      }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  func screen(_ display: TerminalSession) -> String {
    display.snapshot().text.joined(separator: "\n")
  }

  @Test
  func `typed input reaches the host shell and its screen comes back`()
    async throws
  {
    let harness = try await Harness()
    let display = TerminalSession(presentationColumns: 80, rows: 24)
    let client = harness.makeClient(display: display)
    try await client.start(.create(GridSize(columns: 80, rows: 24)))
    try await waitFor("active") { await client.state == .active }

    #expect(
      await client.submit(.text("echo roam-$((6*7))")) != .refused(.closed)
    )
    _ = await client.submit(.key(SemanticKey(.enter)))
    try await waitFor("echo output") { screen(display).contains("roam-42") }
    try await waitFor("ack") { await client.status.pendingInputCount == 0 }

    await client.close(.terminate)
    await harness.shutdown()
  }

  @Test
  func `shared frames arrive as deltas and copy spans unfetched history`()
    async throws
  {
    let harness = try await Harness()
    let display = TerminalSession(presentationColumns: 40, rows: 8)
    let client = harness.makeClient(display: display)
    try await client.start(.create(GridSize(columns: 40, rows: 8)))
    try await waitFor("active") { await client.state == .active }
    _ = await client.submit(.text("seq 1 3000; echo done-mark"))
    _ = await client.submit(.key(SemanticKey(.enter)))
    try await waitFor("output") { screen(display).contains("done-mark") }
    for word in ["one", "two", "three"] {
      _ = await client.submit(.text("echo \(word)-x"))
      _ = await client.submit(.key(SemanticKey(.enter)))
      try await waitFor(word) { screen(display).contains("\(word)-x") }
    }
    // A pause longer than the base retention window: the newest base is
    // kept, so the next keystroke still arrives as a delta.
    try await Task.sleep(for: .milliseconds(2_500))
    _ = await client.submit(.text("echo after-pause"))
    _ = await client.submit(.key(SemanticKey(.enter)))
    try await waitFor("after pause") {
      screen(display).contains("after-pause\n")
    }
    let stats = await client.deltaStatistics
    #expect(stats.applied > 0)
    #expect(stats.requestedFull == 0)
    // Copy from the oldest retained row to the newest output: rows the
    // client never received come from the host's grid.
    let frame = try #require(await client.currentPaneFrame)
    let h = frame.history
    let last = try #require(frame.lines.lastIndex(of: "three-x"))
    let screenRows = (0 ... last).compactMap { frame.rowIdentity($0) }
      .filter { $0.address.row >= h.viewportTop + h.viewportOffset }
    func request(_ rows: [RowIdentity]) -> CopySelectionRequest {
      CopySelectionRequest(
        pane: PaneID(),
        start: SelectionPoint(
          address: HistoryAddress(
            generation: h.generation,
            alternateScreen: false,
            row: h.firstRow
          ),
          column: 0
        ),
        end: SelectionPoint(
          address: h.address(viewportRow: last, alternateScreen: false),
          column: 39
        ),
        unit: .character,
        screenRowVersions: rows
      )
    }
    let text = try await client.copySelection(request(screenRows))
    let lines = text.split(separator: "\n")
    #expect(lines.contains("1500"))
    #expect(lines.contains("done-mark"))
    #expect(lines.last == "three-x")
    var stale = screenRows
    stale[stale.count - 1].version &+= 1000
    await #expect(throws: RoamingClient.CopyError(.selectionChanged)) {
      try await client.copySelection(request(stale))
    }
    await client.close(.terminate)
    await harness.shutdown()
  }

  @Test
  func `a display selection scrolled out of view is copied from the host`()
    async throws
  {
    let harness = try await Harness()
    let display = TerminalSession(presentationColumns: 40, rows: 8)
    let client = harness.makeClient(display: display)
    display.remoteCopyHandler = { selection, done in
      Task { done(try? await client.copySelection(selection)) }
    }
    try await client.start(.create(GridSize(columns: 40, rows: 8)))
    try await waitFor("active") { await client.state == .active }
    _ = await client.submit(.text("seq 1 200; echo done-mark"))
    _ = await client.submit(.key(SemanticKey(.enter)))
    // The echoed command line also contains "done-mark"; wait for the
    // output line and the prompt after it, so no later output edits the
    // selected rows and ends the selection.
    try await waitFor("output") {
      let lines = display.withState { $0.screenLines }
        .map { $0.trimmingCharacters(in: .whitespaces) }
      guard let mark = lines.lastIndex(of: "done-mark") else { return false }
      return lines[(mark + 1)...].contains { $0.hasPrefix("$") }
    }
    // Select every shown row, then scroll this client's window back so
    // the selection's end lies below what is shown.
    let shown = display.withState { $0.screenLines }
    display.mutate { state in
      state.setSelection(
        Selection(
          anchor: state.viewportPoint(row: 0, column: 0),
          head: state.viewportPoint(row: state.rows - 1, column: 39)
        )
      )
    }
    await client.scrollViewport(by: 3)
    try await waitFor("window moved") {
      display.withState { $0.presentationSelectionBeyondView } != nil
    }
    let text: String? = await withCheckedContinuation { continuation in
      DispatchQueue.main.async {
        display.copySelectedText { continuation.resume(returning: $0) }
      }
    }
    let expected = shown.map { line in
      var line = line
      while line.last == " " { line.removeLast() }
      return line
    }
    #expect(
      text?.split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init) == expected
    )
    await client.close(.terminate)
    await harness.shutdown()
  }

  @Test(arguments: [false, true])
  func `per-key echo keeps screens flowing`(loginShell: Bool) async throws {
    let harness = try await Harness(loginShell: loginShell)
    let display = TerminalSession(presentationColumns: 80, rows: 24)
    let client = harness.makeClient(display: display)
    try await client.start(.create(GridSize(columns: 80, rows: 24)))
    try await waitFor("active") { await client.state == .active }
    try await Task.sleep(for: .seconds(2))
    for ch in "echo login-$((7*6))" {
      _ = await client.submit(.text(String(ch)))
    }
    _ = await client.submit(.key(SemanticKey(.enter)))
    do {
      try await waitFor("output") { screen(display).contains("login-42") }
    } catch {
      Issue.record("status \(await client.status)\n\(screen(display))")
    }
    await client.close(.terminate)
    await harness.shutdown()
  }

  @Test
  func
    `client address change mid-session recovers the same shell exactly once`()
    async throws
  {
    // The phone's address changes (Wi-Fi to cellular): the server's replies
    // go to the old address, so the client detects the stall after its
    // path-change probe and reattaches to the retained session (spec §9).
    let harness = try await Harness(throughRelay: true)
    let relay = try #require(harness.relay)
    let display = TerminalSession(presentationColumns: 80, rows: 24)
    let client = harness.makeClient(display: display)
    try await client.start(.create(GridSize(columns: 80, rows: 24)))
    try await waitFor("active") { await client.state == .active }
    let session = try #require(await client.status.sessionID)
    let pid = try #require((await harness.pid(session)))

    for hop in 1 ... 3 {
      try relay.rebind()
      await client.pathChanged()
      try await waitFor("recovery \(hop)", timeout: .seconds(30)) {
        await client.state == .active
      }
      _ = await client.submit(.text("echo hop-$((\(hop)*11))"))
      _ = await client.submit(.key(SemanticKey(.enter)))
      try await waitFor("hop \(hop) output", timeout: .seconds(30)) {
        screen(display).contains("hop-\(hop * 11)")
      }
    }
    let text = screen(display)
    for hop in 1 ... 3 {
      #expect(text.components(separatedBy: "hop-\(hop * 11)").count - 1 == 1)
    }
    #expect(await client.status.sessionID == session)
    #expect((await harness.pid(session)) == pid)
    await client.close(.terminate)
    await harness.shutdown()
  }

  @Test
  func `lost connection reattaches to the same shell without duplicate input`()
    async throws
  {
    let harness = try await Harness()
    let display = TerminalSession(presentationColumns: 80, rows: 24)
    let client = harness.makeClient(display: display)
    try await client.start(.create(GridSize(columns: 80, rows: 24)))
    try await waitFor("active") { await client.state == .active }
    let sessionID = try #require(await client.status.sessionID)
    let pid = try #require((await harness.pid(sessionID)))

    _ = await client.submit(.text("echo first-$((1+1))"))
    _ = await client.submit(.key(SemanticKey(.enter)))
    try await waitFor("first output") { screen(display).contains("first-2") }

    // Abrupt loss of the transport (A1/A2 analogue): the host keeps the
    // shell; the client reconnects with a new epoch on its own.
    for connection in harness.serverConnections.list.withLock({ $0 }) {
      connection.close()
    }
    try await waitFor("recovery", timeout: .seconds(30)) {
      await client.state == .active
        && harness.serverConnections.list.withLock { $0.count } >= 2
    }
    #expect((await harness.pid(sessionID)) == pid)

    _ = await client.submit(.text("echo second-$((2+2))"))
    _ = await client.submit(.key(SemanticKey(.enter)))
    try await waitFor("second output") { screen(display).contains("second-4") }
    let text = screen(display)
    #expect(text.components(separatedBy: "first-2").count - 1 == 1)
    #expect(text.components(separatedBy: "second-4").count - 1 == 1)

    await client.close(.terminate)
    await harness.shutdown()
  }

  @Test
  func `unreachable advertised host falls back to the SSH host`() async throws {
    let harness = try await Harness()
    let bootstrapper = EnvelopeBootstrapper(service: harness.service)
    guard
      case var .granted(grant) = try await bootstrapper.bootstrap(
        BootstrapRequest(
          operation: .create,
          initialGrid: GridSize(columns: 80, rows: 24)
        )
      )
    else {
      Issue.record("expected a grant")
      await harness.shutdown()
      return
    }
    // A LAN address the client cannot route to (TEST-NET-1), as when the
    // Mac advertises its Wi-Fi address and the phone is on cellular.
    grant.endpoint.host = "192.0.2.1"
    let connection = try await QUICGrantConnector(
      connector: QUICRSTConnector(handshakeTimeout: .seconds(3)),
      fallbackHost: "127.0.0.1",
      fallbackDelay: .milliseconds(50)
    )
    .connect(to: grant)
    connection.close()
    try await waitFor("server saw the fallback connection") {
      harness.serverConnections.list.withLock { $0.count } == 1
    }
    await harness.shutdown()
  }

  @Test
  func `changed QUIC pin fails closed before the token is sent`() async throws {
    let harness = try await Harness()
    let bootstrapper = EnvelopeBootstrapper(service: harness.service)
    guard
      case let .granted(grant) = try await bootstrapper.bootstrap(
        BootstrapRequest(
          operation: .create,
          initialGrid: GridSize(columns: 80, rows: 24)
        )
      )
    else {
      Issue.record("expected a grant")
      await harness.shutdown()
      return
    }
    #expect(grant.serverSPKISHA256 != nil)
    let other = try AppleTransport.HostIdentity.generate(ipAddresses: [
      "127.0.0.1"
    ])

    // The host's key changed since SSH delivered the pin (or the endpoint
    // is an impostor): the grant pins `other`, the listener presents its
    // own certificate. The SPKI check fails the handshake.
    var rotated = grant
    rotated.serverCertificateDER = other.certificateDER
    rotated.serverCertificateSHA256 = other.certificateSHA256
    rotated.serverSPKISHA256 = other.spkiSHA256
    await #expect(throws: RSTTransportError.pinMismatch) {
      _ = try await QUICGrantConnector().connect(to: rotated)
    }

    // Only the SPKI pin changed: the grant is inconsistent and is refused
    // before any packet is sent.
    var mismatched = grant
    mismatched.serverSPKISHA256 = other.spkiSHA256
    await #expect(throws: CertificatePinError.inconsistentPin) {
      _ = try await QUICGrantConnector().connect(to: mismatched)
    }

    // No connection reached the server, so no Attach carried the token
    // and the reservation was never claimed.
    try await Task.sleep(for: .milliseconds(200))
    #expect(harness.serverConnections.list.withLock { $0.count } == 0)
    #expect(harness.listener.activeConnectionCount == 0)
    #expect((try await harness.registry.list()).map(\.state) == [.reserved])

    // The genuine pin still attaches.
    let connection = try await QUICGrantConnector().connect(to: grant)
    connection.close()
    try await waitFor("server saw the pinned connection") {
      harness.serverConnections.list.withLock { $0.count } == 1
    }
    await harness.shutdown()
  }

  @Test
  func `cold relaunch resumes the retained session by id`() async throws {
    let harness = try await Harness()
    let first = TerminalSession(presentationColumns: 80, rows: 24)
    let client = harness.makeClient(display: first)
    try await client.start(.create(GridSize(columns: 80, rows: 24)))
    try await waitFor("active") { await client.state == .active }
    _ = await client.submit(.text("export MARK=kept-$((3*3))"))
    _ = await client.submit(.key(SemanticKey(.enter)))
    try await waitFor("ack") { await client.status.pendingInputCount == 0 }
    let sessionID = try #require(await client.status.sessionID)
    await client.close(.detach)

    // A new process: no input queue, fresh SSH authorization, new writer.
    let second = TerminalSession(presentationColumns: 80, rows: 24)
    let relaunched = harness.makeClient(display: second)
    try await relaunched.start(.resume(sessionID))
    try await waitFor("reattached") { await relaunched.state == .active }
    _ = await relaunched.submit(.text("echo $MARK"))
    _ = await relaunched.submit(.key(SemanticKey(.enter)))
    try await waitFor("retained env") { screen(second).contains("kept-9") }
    await relaunched.close(.terminate)
    await harness.shutdown()
  }
}
#endif

#if os(macOS)
import SSHClient

/// Full path: SSH host-key check and authentication, no-PTY exec of the
/// fixed helper path, the real registry's grant, pinned QUIC attachment.
@Suite(.serialized)
struct RoamingOverSSHTests {
  @Test
  func `bootstrap over SSH exec grants an attachable session`() async throws {
    let harness = try await RoamingEndToEndTests.Harness()
    let ssh = try await TestSSHServer.start()
    let service = harness.service
    ssh.state.bootstrapForwarder.withLock {
      $0 = { envelope in await service.respond(toEnvelope: envelope) }
    }
    let bootstrapper = SSHBootstrapper(
      endpoint: SSHEndpoint(
        configuration: ssh.configuration(),
        credential: .password(TestSSHServer.password),
        trustStore: ssh.trustingStore(),
        helperPath: TestSSHServer.forwardHelperPath
      )
    )
    let display = TerminalSession(presentationColumns: 80, rows: 24)
    let client = RoamingClient(
      bootstrapper: bootstrapper,
      connector: QUICGrantConnector(),
      sink: display
    )
    try await client.start(.create(GridSize(columns: 80, rows: 24)))
    let deadline = ContinuousClock.now + .seconds(15)
    while await client.state != .active, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await client.state == .active)
    _ = await client.submit(.text("echo via-ssh-$((5*5))"))
    _ = await client.submit(.key(SemanticKey(.enter)))
    while !display.snapshot().text.joined().contains("via-ssh-25"),
      ContinuousClock.now < deadline + .seconds(10)
    { try await Task.sleep(for: .milliseconds(20)) }
    #expect(display.snapshot().text.joined().contains("via-ssh-25"))
    #expect(ssh.state.authRequests.withLock { $0 } >= 1)

    // An unknown host key with no decision fails closed before any grant.
    let untrusted = SSHBootstrapper(
      endpoint: SSHEndpoint(
        configuration: ssh.configuration(),
        credential: .password(TestSSHServer.password),
        trustStore: InMemoryHostTrustStore(),
        helperPath: TestSSHServer.forwardHelperPath
      )
    )
    await #expect(throws: RemoteBootstrapError.hostKeyRejected) {
      _ = try await untrusted.bootstrap(BootstrapRequest(operation: .list))
    }

    await client.close(.terminate)
    await harness.shutdown()
    await ssh.shutdown()
  }
}
#endif
