import Darwin
import Dispatch
import Foundation
import SwiftMuxClient
import SwiftMuxGateway
import SwiftMuxGuardian
import SwiftMuxProtocol
import SwiftMuxService
import SwiftMuxXPC
import Synchronization
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct GatewayControlTests {
  @Test
  func discoveryRoutesAndAcknowledgedEndUseTheNativeControlBoundary()
    async throws
  {
    let guardian = try GuardianServer(
      launcherPath: launcherPath(),
      peerRequirement: nil
    )
    let workspace = WorkspaceID()
    let token = try guardian.provisionWorker(
      workspace: workspace,
      pid: getpid()
    )
    let workerEndpoint = guardian.listenAnonymously()
    let ready = Mutex(false)
    let host = try WorkspaceWorkerHost(
      workspace: workspace,
      launcherPath: launcherPath(),
      peerRequirement: nil,
      connect: { queue, handlers in
        try GuardianWorkerConnection(
          channel: .connect(endpoint: workerEndpoint, queue: queue),
          workspace: workspace,
          token: token,
          peerRequirement: nil,
          expectedGuardianPID: getpid(),
          handlers: handlers
        )
      },
      ready: { _ in ready.withLock { $0 = true } },
      unavailable: { _ in }
    )
    let control = GuardianGatewayServer(
      guardian: guardian,
      peerRequirement: nil
    )
    let controlEndpoint = control.listenAnonymously()
    defer {
      host.close();
      control.close();
      guardian.shutdown {}
    }
    try await waitUntil { ready.withLock { $0 } }
    let supervisor = try await GatewaySupervisor.connect(
      peerRequirement: nil,
      expectedGuardianPID: getpid(),
      channel: { .connect(endpoint: controlEndpoint, queue: $0) }
    )
    let runtime = try await GatewayRuntime.start(
      supervisor: supervisor,
      peerRequirement: nil,
      pollInterval: .milliseconds(20)
    )
    try await waitUntil { await runtime.records.first?.state == .empty }
    let authority = try #require(guardian.inventory().first?.authority)
    let bootstrap = try await supervisor.connectWorker(
      authority,
      peerRequirement: nil,
      frontend: .native
    )
    _ = try await bootstrap.execute(
      .newWorkspace(
        NewWorkspaceRequest(name: "control route", launch: shellLaunch())
      )
    )
    await bootstrap.close()
    try await waitUntil {
      await runtime.records.contains {
        if case .available = $0.state { true } else { false }
      }
    }
    let server = GatewayControlServer(runtime: runtime, peerRequirement: nil)
    let publicEndpoint = server.listenAnonymously()
    let clientQueue = DispatchQueue(label: "typed-gateway-control-client")
    let clientReady = Mutex(false)
    let typed = try clientQueue.sync {
      try GatewayControlConnection(
        channel: .connect(endpoint: publicEndpoint, queue: clientQueue),
        peerRequirement: nil,
        expectedPID: getpid(),
        ready: { _ in clientReady.withLock { $0 = true } },
        closed: { _ in }
      )
    }
    defer { clientQueue.sync { typed.close() } }
    try await waitUntil { clientReady.withLock { $0 } }
    do {
      _ = try await typedCommand(
        .create(
          WorkspaceID(),
          NewWorkspaceRequest(name: String(repeating: "x", count: 5 << 20))
        ),
        on: typed,
        queue: clientQueue
      )
      Issue.record("oversized creation was admitted")
    } catch let error as MuxError { #expect(error.code == .resourceLimit) }
    // Consecutive commands prove that the client acknowledges the previous
    // result before reusing the server's single outstanding-command slot.
    for _ in 0 ..< 2 {
      let reply = try await typedCommand(
        .listWorkspaces,
        on: typed,
        queue: clientQueue
      )
      guard case let .workspaces(items) = reply else {
        throw MuxError(.invalidRequest, "typed client did not return inventory")
      }
      #expect(items.count == 1 && items[0].workspace == workspace)
    }
    let routeReply = try await typedCommand(
      .route(.id(workspace), role: .observer),
      on: typed,
      queue: clientQueue
    )
    guard case let .route(route) = routeReply else {
      throw MuxError(.invalidRequest, "typed client did not return route")
    }
    #expect(route.gatewayPID == getpid())
    let routedClient = try await MuxConnection.connectWorker(
      endpoint: route.endpoint,
      expectedPID: route.gatewayPID,
      expectedServer: route.descriptor.server,
      peerRequirement: nil,
      frontend: .native
    )
    _ = try await routedClient.execute(.status)
    await routedClient.close()
    let asyncClient = try await MuxGatewayConnection.connect(
      peerRequirement: nil,
      expectedPID: getpid(),
      channel: { .connect(endpoint: publicEndpoint, queue: $0) }
    )
    #expect(
      try await asyncClient.listWorkspaces().first?.workspace == workspace
    )
    let opened = try await asyncClient.openWorkspace(.id(workspace))
    #expect(opened.workspace == workspace)
    await asyncClient.close()
    // Control lifetime and an already returned terminal transport are separate.
    _ = try await opened.connection.execute(.status)
    await opened.connection.close()
    let probe = Probe(publicEndpoint)
    let identity = try await probe.handshake()
    let listing = GatewayControlRequest.command(
      gateway: identity,
      sequence: 1,
      body: .listWorkspaces
    )
    try probe.send(listing)
    guard
      case let .result(1, .success(.workspaces(records))) =
        try await probe.next().0
    else { throw MuxError(.invalidRequest, "missing aggregate inventory") }
    #expect(
      records.count == 1 && records[0].workspace == workspace
        && records[0].state == .available
    )
    try probe.send(listing)
    guard case .result(1, .success(.workspaces)) = try await probe.next().0
    else { throw MuxError(.invalidRequest, "cached result was not replayed") }
    // Further duplicates do not create an unbounded output queue.
    try probe.send(listing)
    try probe.send(.acknowledge(sequence: 1))
    try probe.send(
      .command(
        gateway: identity,
        sequence: 2,
        body: .route(.id(workspace), role: .controller)
      )
    )
    let routed = try await probe.next()
    guard case let .result(2, .success(.route(descriptor))) = routed.0 else {
      throw MuxError(.invalidRequest, "missing native route")
    }
    #expect(descriptor.workspace == workspace)
    let endpoint = try #require(routed.1)
    try probe.send(.acknowledge(sequence: 2))
    let client = try await MuxConnection.connectWorker(
      endpoint: endpoint,
      expectedPID: getpid(),
      expectedServer: descriptor.server,
      peerRequirement: nil,
      frontend: .native
    )
    let shown = try await client.attachAndShow(.id(workspace))
    let pane = shown.tabs[0].activePane
    try await client.send(.text("echo control-route-input\r"), to: pane)
    _ = try await client.frame(of: pane) {
      $0.lines.contains("control-route-input")
    }
    let shell = try #require(guardian.inventory().first?.panes.first?.pid)
    await server.close()
    #expect(kill(shell, 0) == 0)
    _ = try await client.execute(.status)
    probe.close()

    let replacement = GatewayControlServer(
      runtime: runtime,
      peerRequirement: nil
    )
    let replacementEndpoint = replacement.listenAnonymously()
    let second = Probe(replacementEndpoint)
    let newIdentity = try await second.handshake()
    #expect(newIdentity != identity)
    let end = GatewayControlRequest.command(
      gateway: newIdentity,
      sequence: 1,
      body: .end(.id(workspace))
    )
    try second.send(end)
    guard case .result(1, .success(.ended)) = try await second.next().0 else {
      throw MuxError(.invalidRequest, "missing End result")
    }
    try second.send(end)
    guard case .result(1, .success(.ended)) = try await second.next().0 else {
      throw MuxError(
        .invalidRequest,
        "End was executed again instead of replaying its result"
      )
    }
    try second.send(.acknowledge(sequence: 1))
    try await waitUntil { await runtime.records.isEmpty }
    #expect(kill(shell, 0) == -1)
    try second.send(
      .command(gateway: newIdentity, sequence: 2, body: .listWorkspaces)
    )
    guard
      case let .result(2, .success(.workspaces(empty))) =
        try await second.next().0
    else { throw MuxError(.invalidRequest, "missing retired inventory") }
    #expect(empty.isEmpty)
    try second.send(
      .command(gateway: newIdentity, sequence: 2, body: .end(.id(workspace)))
    )
    try await waitUntil { second.isClosed }
    let stale = Probe(replacementEndpoint)
    _ = try await stale.handshake()
    try stale.send(
      .command(gateway: identity, sequence: 1, body: .listWorkspaces)
    )
    try await waitUntil { stale.isClosed }
    stale.close();
    second.close()
    await replacement.close()
    await client.close()
    await runtime.close()
  }

  @Test
  func unacknowledgedResultsShareABoundedByteBudget() async throws {
    let guardian = try GuardianServer(
      launcherPath: launcherPath(),
      peerRequirement: nil
    )
    let control = GuardianGatewayServer(
      guardian: guardian,
      peerRequirement: nil
    )
    let endpoint = control.listenAnonymously()
    defer {
      control.close();
      guardian.shutdown {}
    }
    let supervisor = try await GatewaySupervisor.connect(
      peerRequirement: nil,
      expectedGuardianPID: getpid(),
      channel: { .connect(endpoint: endpoint, queue: $0) }
    )
    let runtime = try await GatewayRuntime.start(
      supervisor: supervisor,
      peerRequirement: nil
    )
    let server = GatewayControlServer(runtime: runtime, peerRequirement: nil)
    let controlEndpoint = server.listenAnonymously()
    let peers = (0 ..< 3).map { _ in Probe(controlEndpoint) }
    let launch = NewWorkspaceRequest(
      launch: LaunchSpec(environment: [
        "payload": String(repeating: "x", count: 3 << 20)
      ])
    )
    var identities: [ServerInstanceID] = []
    for peer in peers.prefix(2) {
      let identity = try await peer.handshake()
      identities.append(identity)
      try peer.send(
        .command(
          gateway: identity,
          sequence: 1,
          body: .create(WorkspaceID(), launch)
        )
      )
      guard case let .result(1, .failure(error)) = try await peer.next().0
      else {
        throw MuxError(
          .invalidRequest,
          "unconfigured creation unexpectedly succeeded"
        )
      }
      #expect(error.code == .notAttached)
    }
    let identity = try await peers[2].handshake()
    try peers[2]
      .send(
        .command(
          gateway: identity,
          sequence: 1,
          body: .create(WorkspaceID(), launch)
        )
      )
    try await waitUntil { peers[2].isClosed }
    try peers[0].send(.acknowledge(sequence: 1))
    // The same peer's next result proves ACK processing precedes re-admission.
    try peers[0]
      .send(
        .command(gateway: identities[0], sequence: 2, body: .listWorkspaces)
      )
    guard case .result(2, .success(.workspaces)) = try await peers[0].next().0
    else {
      throw MuxError(
        .invalidRequest,
        "acknowledgement did not retire the pending window"
      )
    }
    try peers[0].send(.acknowledge(sequence: 2))
    let alive = Probe(controlEndpoint)
    let nextIdentity = try await alive.handshake()
    try alive.send(
      .command(
        gateway: nextIdentity,
        sequence: 1,
        body: .create(WorkspaceID(), launch)
      )
    )
    guard case let .result(1, .failure(error)) = try await alive.next().0 else {
      throw MuxError(
        .invalidRequest,
        "returned result capacity was not reusable"
      )
    }
    #expect(error.code == .notAttached)
    #expect(guardian.inventory().isEmpty)
    for peer in peers { peer.close() }
    alive.close()
    await server.close()
    await runtime.close()
  }

  private func typedCommand(
    _ command: GatewayControlCommand,
    on connection: GatewayControlConnection,
    queue: DispatchQueue
  ) async throws -> GatewayControlConnection.Reply {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        if !connection.submit(
          command,
          completion: { continuation.resume(with: $0) }
        ) {
          continuation.resume(
            throwing: MuxError(.quiescing, "control client busy")
          )
        }
      }
    }
  }

  private func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await condition()) {
      guard ContinuousClock.now < deadline else {
        throw MuxError(.connectionLost, "control test timed out")
      }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  private final class Probe: Sendable {
    private let channel: SMXChannel
    private let received = Mutex<[(GatewayControlEvent, SMXEndpoint?)]>([])
    private let closed = Mutex(false)
    var isClosed: Bool { closed.withLock { $0 } }
    init(_ endpoint: SMXEndpoint) {
      channel = .connect(
        endpoint: endpoint,
        queue: DispatchQueue(label: "gateway-control-test-client")
      )
      channel.activate(
        recordLimit: { GatewayControl.recordLimit },
        endpointHandler: { [weak self] data, endpoint in
          self?.receive(data, endpoint: endpoint)
        }
      ) { [weak self] event in
        switch event {
        case let .message(data): self?.receive(data, endpoint: nil)
        case .closed: self?.closed.withLock { $0 = true }
        }
      }
    }
    deinit { channel.cancel() }
    func close() { channel.cancel() }
    func send(_ request: GatewayControlRequest) throws {
      channel.send(
        try SMXCodec.encode(request, limit: GatewayControl.recordLimit)
      )
    }
    func handshake() async throws -> ServerInstanceID {
      try send(.hello(version: GatewayControl.version))
      guard case let .welcome(version, identity) = try await next().0,
        version == GatewayControl.version
      else { throw MuxError(.incompatibleVersion) }
      return identity
    }
    func next() async throws -> (GatewayControlEvent, SMXEndpoint?) {
      let deadline = ContinuousClock.now + .seconds(5)
      while true {
        if let value = received.withLock({ $0.isEmpty ? nil : $0.removeFirst() }
        ) {
          return value
        }
        guard !isClosed, ContinuousClock.now < deadline else {
          throw MuxError(.connectionLost, "control reply missing")
        }
        try await Task.sleep(for: .milliseconds(5))
      }
    }
    private func receive(_ data: Data, endpoint: SMXEndpoint?) {
      if let event = try? SMXCodec.decode(
        GatewayControlEvent.self,
        from: data,
        limit: GatewayControl.recordLimit
      ) {
        received.withLock { $0.append((event, endpoint)) }
      } else {
        channel.cancel()
      }
    }
  }
}
