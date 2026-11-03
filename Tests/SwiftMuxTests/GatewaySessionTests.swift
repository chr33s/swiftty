import Darwin
import Dispatch
import Foundation
import SwiftMuxClient
import SwiftMuxGateway
import SwiftMuxGuardian
import SwiftMuxProtocol
import SwiftMuxService
import SwiftMuxTerminal
import SwiftMuxXPC
import Synchronization
import TTYKit
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct GatewaySessionTests {
  @Test(arguments: [false, true])
  @MainActor
  func switchPreservesOldSelectionOnRefusalAndRequiresExplicitTakeover(
    detachDuringRecovery: Bool
  ) async throws {
    let guardian = try GuardianServer(
      launcherPath: launcherPath(),
      peerRequirement: nil
    )
    let workerEndpoint = guardian.listenAnonymously()
    let control = GuardianGatewayServer(
      guardian: guardian,
      peerRequirement: nil
    )
    let controlEndpoint = control.listenAnonymously()
    let ids = [WorkspaceID(), WorkspaceID()]
    let ready = Mutex(0)
    var hosts: [WorkspaceWorkerHost] = []
    defer {
      for host in hosts { host.close() }
      control.close()
      guardian.shutdown {}
    }
    for id in ids {
      let token = try guardian.provisionWorker(workspace: id, pid: getpid())
      hosts.append(
        try WorkspaceWorkerHost(
          workspace: id,
          launcherPath: launcherPath(),
          peerRequirement: nil,
          connect: { queue, handlers in
            try GuardianWorkerConnection(
              channel: .connect(endpoint: workerEndpoint, queue: queue),
              workspace: id,
              token: token,
              peerRequirement: nil,
              expectedGuardianPID: getpid(),
              handlers: handlers
            )
          },
          ready: { _ in ready.withLock { $0 += 1 } },
          unavailable: { _ in }
        )
      )
    }
    try await waitUntil { ready.withLock { $0 } == 2 }
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
    try await waitUntil {
      await runtime.records.filter { $0.state == .empty }.count == 2
    }
    for id in ids {
      let authority = try #require(
        guardian.inventory().first { $0.authority.workspace == id }?.authority
      )
      let bootstrap = try await supervisor.connectWorker(
        authority,
        peerRequirement: nil,
        frontend: .native
      )
      _ = try await bootstrap.execute(
        .newWorkspace(
          NewWorkspaceRequest(
            name: "session-\(ids.firstIndex(of: id)!)",
            launch: shellLaunch()
          )
        )
      )
      await bootstrap.close()
    }
    try await waitUntil {
      await runtime.records
        .filter { if case .available = $0.state { true } else { false } }.count
        == 2
    }
    let server = GatewayControlServer(runtime: runtime, peerRequirement: nil)
    let endpoint = server.listenAnonymously()
    let gateway = try await MuxGatewayConnection.connect(
      peerRequirement: nil,
      expectedPID: getpid(),
      channel: { .connect(endpoint: endpoint, queue: $0) }
    )
    let session = MuxGatewaySession(gateway: gateway, frontend: .terminal)
    let first = try await session.select(.id(ids[0]))
    #expect(first.workspace.id == ids[0])
    try await proveInput(first, marker: "first-route-live")
    let rival = try await gateway.openWorkspace(.id(ids[1]), role: .controller)
    _ = try await rival.connection.attachAndShow(.id(ids[1]))
    do {
      _ = try await session.select(.id(ids[1]))
      Issue.record("switch displaced another controller without consent")
    } catch let error as MuxError { #expect(error.code == .leaseHeld) }
    #expect(await session.isCurrent(first.id))
    try await proveInput(
      first,
      marker: "first-route-retained",
      configure: false
    )
    guard
      case let .workspaces(records) = try await rival.connection.execute(
        .listWorkspaces
      ), let lease = records.first?.leaseGeneration
    else { throw MuxError(.invalidRequest, "missing rival lease") }
    do {
      _ = try await session.select(.id(ids[1]), expectedLease: lease + 1)
      Issue.record("stale takeover succeeded")
    } catch let error as MuxError { #expect(error.code == .staleRevision) }
    #expect(await session.isCurrent(first.id))
    let second = try await session.select(.id(ids[1]), expectedLease: lease)
    #expect(second.workspace.id == ids[1])
    #expect(!((await session.isCurrent(first.id))))
    #expect(await session.isCurrent(second.id))
    await #expect(throws: MuxError.self) {
      _ = try await first.connection.execute(.status)
    }
    try await proveInput(second, marker: "second-route-live")
    // Switching to the released workspace acquires a new attachment/selection.
    let returned = try await session.select(.id(ids[0]))
    #expect(returned.id != first.id && returned.attachment != first.attachment)
    #expect(!((await session.isCurrent(second.id))))
    do {
      _ = try await session.select(.id(ids[0]))
      Issue.record("same-workspace switch replaced its own controller")
    } catch let error as MuxError { #expect(error.code == .alreadyAttached) }
    do {
      _ = try await session.reconnect(using: gateway, selection: returned.id)
      Issue.record("recovery displaced a live attachment")
    } catch let error as MuxError { #expect(error.code == .alreadyAttached) }
    let retainedPIDs = guardian.inventory().flatMap { $0.panes.map(\.pid) }
      .sorted()
    await server.close()
    await runtime.close()
    let nextSupervisor = try await GatewaySupervisor.connect(
      peerRequirement: nil,
      expectedGuardianPID: getpid(),
      channel: { .connect(endpoint: controlEndpoint, queue: $0) }
    )
    let nextRuntime = try await GatewayRuntime.start(
      supervisor: nextSupervisor,
      peerRequirement: nil,
      pollInterval: .milliseconds(20)
    )
    try await waitUntil {
      await nextRuntime.records
        .filter { if case .available = $0.state { true } else { false } }.count
        == 2
    }
    let nextServer = GatewayControlServer(
      runtime: nextRuntime,
      peerRequirement: nil
    )
    let nextEndpoint = nextServer.listenAnonymously()
    let nextGateway = try await MuxGatewayConnection.connect(
      peerRequirement: nil,
      expectedPID: getpid(),
      channel: { .connect(endpoint: nextEndpoint, queue: $0) }
    )
    let competitor = try await nextGateway.openWorkspace(
      .id(ids[0]),
      role: .controller
    )
    _ = try await competitor.connection.attachAndShow(.id(ids[0]))
    do {
      _ = try await session.reconnect(
        using: nextGateway,
        selection: returned.id
      )
      Issue.record("recovery displaced a competing controller")
    } catch let error as MuxError { #expect(error.code == .leaseHeld) }
    #expect(await session.isCurrent(returned.id))
    await competitor.connection.detach()
    await competitor.connection.close()
    let recovered = try await session.reconnect(
      using: nextGateway,
      selection: returned.id
    )
    #expect(recovered.workspace.id == returned.workspace.id)
    #expect(recovered.welcome.server == returned.welcome.server)
    #expect(
      recovered.attachment != returned.attachment && recovered.id != returned.id
    )
    #expect(recovered.role == .controller)
    do {
      _ = try await session.reconnect(
        using: nextGateway,
        selection: returned.id
      )
      Issue.record("stale recovery replaced the new selection")
    } catch let error as MuxError { #expect(error.code == .staleAttachment) }
    try await proveInput(
      recovered,
      marker: "recovered-route-live",
      retaining: "first-route-retained"
    )
    #expect(
      guardian.inventory().flatMap { $0.panes.map(\.pid) }.sorted()
        == retainedPIDs
    )
    let recoveryControl = Mutex<MuxGatewayConnection?>(nextGateway)
    let outer = try TerminalClientTests.Outer()
    let terminal = TerminalClient(
      gateway: nextGateway,
      session: session,
      selection: recovered,
      reconnect: {
        guard let control = recoveryControl.withLock({ $0 }) else {
          throw MuxError(.connectionLost)
        }
        return control
      },
      tty: RawTTY(input: outer.slave, output: outer.slave)
    )
    let run = Task { await terminal.run() }
    defer { run.cancel() }
    try #require(await outer.wait { $0.last?.contains("session-0") == true })
    outer.type("echo terminal-route-one\r")
    try #require(await outer.wait { $0.contains("terminal-route-one") })
    do {
      try await terminal.selectGatewayWorkspace(.id(ids[0]))
      Issue.record("terminal replaced its live selection")
    } catch let error as MuxError { #expect(error.code == .alreadyAttached) }
    recoveryControl.withLock { $0 = nil }
    await nextServer.close()
    await nextRuntime.close()
    try #require(await outer.wait { $0.last?.contains("reconnecting") == true })
    // Bytes read during outage must not become delayed shell commands.
    outer.type("export should_not_run=bad\r")
    try await Task.sleep(for: .milliseconds(100))
    if detachDuringRecovery {
      outer.type("\u{02}d")
      #expect(await run.value == .detached("detached during reconnect"))
      #expect(await session.selection == nil)
    }
    let finalSupervisor = try await GatewaySupervisor.connect(
      peerRequirement: nil,
      expectedGuardianPID: getpid(),
      channel: { .connect(endpoint: controlEndpoint, queue: $0) }
    )
    let finalRuntime = try await GatewayRuntime.start(
      supervisor: finalSupervisor,
      peerRequirement: nil,
      pollInterval: .milliseconds(20)
    )
    try await waitUntil {
      await finalRuntime.records
        .filter { if case .available = $0.state { true } else { false } }.count
        == 2
    }
    let finalServer = GatewayControlServer(
      runtime: finalRuntime,
      peerRequirement: nil
    )
    let finalEndpoint = finalServer.listenAnonymously()
    let finalGateway = try await MuxGatewayConnection.connect(
      peerRequirement: nil,
      expectedPID: getpid(),
      channel: { .connect(endpoint: finalEndpoint, queue: $0) }
    )
    if !detachDuringRecovery {
      recoveryControl.withLock { $0 = finalGateway }
      try await waitUntil { !(await session.isCurrent(recovered.id)) }
      try #require(
        await outer.wait { $0.last?.hasPrefix("[session-0]") == true }
      )
      outer.type("printf 'recovery-%s\\n' \"${should_not_run:-clean}\"\r")
      try #require(await outer.wait { $0.contains("recovery-clean") })
      outer.type("\u{02}w")
      try #require(await outer.wait { $0.last?.contains("session-1") == true })
      outer.type("session-1\r")
      try #require(
        await outer.wait { $0.last?.hasPrefix("[session-1]") == true }
      )
      outer.type("echo terminal-route-two\r")
      try #require(await outer.wait { $0.contains("terminal-route-two") })
      #expect(terminal.workspace.id == ids[1])
      #expect(!((await session.isCurrent(returned.id))))
      outer.type("\u{02}d")
      #expect(await run.value == .detached("detached from session-1"))
    }
    // Recovery preserves read-only observers even when no controller is present.
    let observerSession = MuxGatewaySession(gateway: finalGateway)
    let observer = try await observerSession.select(
      .id(ids[0]),
      role: .observer
    )
    await observer.connection.close()
    let observerRecovered = try await observerSession.reconnect(
      using: finalGateway,
      selection: observer.id
    )
    #expect(observerRecovered.role == .observer)
    do {
      _ = try await observerRecovered.connection.execute(
        .renameWorkspace(.id(ids[0]), name: "must-not-rename")
      )
      Issue.record("recovered observer gained mutation authority")
    } catch let error as MuxError { #expect(error.code == .unauthorized) }
    await observerSession.close()
    let pids = guardian.inventory().flatMap { $0.panes.map(\.pid) }
    await session.close()
    #expect(await session.selection == nil)
    #expect(!((await session.isCurrent(returned.id))))
    await #expect(throws: MuxError.self) {
      _ = try await session.select(.id(ids[1]))
    }
    #expect(try await finalGateway.listWorkspaces().count == 2)
    #expect(pids.count == 2 && pids.allSatisfy { kill($0, 0) == 0 })
    await rival.connection.close()
    for id in ids { try await finalGateway.endWorkspace(.id(id)) }
    await finalGateway.close()
    await finalServer.close()
    await finalRuntime.close()
    await nextGateway.close()
    await nextServer.close()
    await nextRuntime.close()
    await gateway.close()
    await server.close()
    await runtime.close()
  }

  @Test
  func closingDuringRoutePreparationCancelsSelectionWithoutReplaying()
    async throws
  {
    let queue = DispatchQueue(label: "session-blocked-route")
    let listener = SMXListener(anonymousOn: queue)
    let channel = Mutex<SMXChannel?>(nil)
    let requests = Mutex(0)
    listener.activate(connectionQueue: queue) { peer in
      channel.withLock { $0 = peer }
      peer.activate { event in
        guard case let .message(data) = event,
          let request = try? JSONDecoder()
            .decode(GatewayControlRequest.self, from: data)
        else { return }
        switch request {
        case .hello:
          peer.send(
            try! JSONEncoder()
              .encode(
                GatewayControlEvent.welcome(
                  version: GatewayControl.version,
                  gateway: ServerInstanceID()
                )
              )
          )
        case .command: requests.withLock { $0 += 1 }
        case .acknowledge:
          Issue.record("pending route was acknowledged without a result")
        }
      }
    }
    defer {
      channel.withLock { $0 }?.cancel();
      listener.cancel()
    }
    let endpoint = listener.endpoint
    let gateway = try await MuxGatewayConnection.connect(
      peerRequirement: nil,
      expectedPID: getpid(),
      channel: { .connect(endpoint: endpoint, queue: $0) }
    )
    let session = MuxGatewaySession(gateway: gateway)
    let selection = Task { try await session.select(.id(WorkspaceID())) }
    try await waitUntil { requests.withLock { $0 } == 1 }
    do {
      _ = try await session.select(.id(WorkspaceID()))
      Issue.record("overlapping selection was admitted")
    } catch let error as MuxError { #expect(error.code == .quiescing) }
    await session.close()
    await #expect(throws: CancellationError.self) { try await selection.value }
    #expect(await session.selection == nil)
    #expect(requests.withLock { $0 } == 1)
    // Abandoning this session does not release the shared control wire slot.
    #expect(await gateway.pendingCommandCount == 1)
    await gateway.close()
    #expect(await gateway.pendingCommandCount == 0)
  }

  private func proveInput(
    _ selection: MuxGatewaySession.Selection,
    marker: String,
    configure: Bool = true,
    retaining prior: String? = nil
  ) async throws {
    let pane = try #require(selection.workspace.activeTabSnapshot?.activePane)
    if configure {
      _ = try await selection.connection.execute(
        .setGeometry(
          GeometryBatch(
            layoutRevision: selection.workspace.layoutRevision,
            generation: 1,
            entries: [.init(pane: pane, columns: 80, rows: 24)]
          )
        )
      )
      _ = try await selection.connection.execute(.setSubscriptions([pane]))
    }
    try await selection.connection.send(.text("echo \(marker)\r"), to: pane)
    _ = try await selection.connection.frame(of: pane) {
      $0.lines.contains(marker) && (prior == nil || $0.lines.contains(prior!))
    }
  }

  private func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await condition()) {
      guard ContinuousClock.now < deadline else {
        throw MuxError(.connectionLost, "session test timed out")
      }
      try await Task.sleep(for: .milliseconds(5))
    }
  }
}
