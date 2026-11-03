import Darwin
import Foundation
import SwiftMuxClient
import SwiftMuxGateway
@testable import SwiftMuxGuardian
import SwiftMuxProtocol
import SwiftMuxService
import Synchronization
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct GatewayRuntimeTests {
  @Test
  func shutdownRetainsShellAndReconnectAutomaticallyRetiresRoutes() async throws
  {
    let workspace = WorkspaceID()
    let guardian = try GuardianServer(
      launcherPath: launcherPath(),
      peerRequirement: nil
    )
    let token = try guardian.provisionWorker(
      workspace: workspace,
      pid: getpid()
    )
    let endpoint = guardian.listenAnonymously()
    let published = Mutex(false)
    let host = try WorkspaceWorkerHost(
      workspace: workspace,
      launcherPath: launcherPath(),
      peerRequirement: nil,
      connect: { queue, handlers in
        try GuardianWorkerConnection(
          channel: .connect(endpoint: endpoint, queue: queue),
          workspace: workspace,
          token: token,
          peerRequirement: nil,
          expectedGuardianPID: getpid(),
          handlers: handlers
        )
      },
      ready: { _ in published.withLock { $0 = true } },
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
    try await waitUntil { published.withLock { $0 } }
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
    do {
      try await runtime.preflightUpdate(
        guardianProtocol: GuardianWire.version,
        workerProtocols: Set(SMX.compatibleVersions)
      )
      Issue.record("unpinned fixture worker was assumed update-compatible")
    } catch let error as MuxError { #expect(error.code == .quiescing) }

    #expect(guardian.inventory().allSatisfy { $0.panes.isEmpty })
    let authority = try #require(guardian.inventory().first?.authority)
    let bootstrap = try await supervisor.connectWorker(
      authority,
      peerRequirement: nil,
      frontend: .native
    )
    _ = try await bootstrap.execute(
      .newWorkspace(
        NewWorkspaceRequest(name: "retained", launch: shellLaunch())
      )
    )
    await bootstrap.close()
    try await waitUntil {
      await runtime.records.contains {
        if case .available = $0.state { true } else { false }
      }
    }
    let routed = try await runtime.nativeEndpoint(for: .id(workspace))
    let client = try await MuxConnection.connect(
      endpoint: routed,
      frontend: .native
    )
    _ = try await client.execute(.status)
    #expect(
      guardian.queue.sync { guardian.workspaces[workspace]?.writer == nil }
    )
    let controllerRoute = try await runtime.nativeEndpoint(
      for: .id(workspace),
      role: .controller
    )
    let firstGrant = try #require(
      guardian.queue.sync { guardian.workspaces[workspace]?.writer }
    )
    let revision = guardian.queue.sync {
      guardian.workspaces[workspace]?.gatewayRevision
    }
    let shown = try await client.attachAndShow(.id(workspace))
    let pane = shown.tabs[0].activePane
    try await client.send(.text("echo runtime-writer-one\r"), to: pane)
    _ = try await client.frame(of: pane) {
      $0.lines.contains("runtime-writer-one")
    }
    _ = try await runtime.nativeEndpoint(for: .id(workspace), role: .controller)
    _ = try await runtime.nativeEndpoint(for: .id(workspace), role: .observer)
    #expect(
      guardian.queue.sync { guardian.workspaces[workspace]?.writer }
        == firstGrant
    )
    #expect(
      guardian.queue.sync { guardian.workspaces[workspace]?.gatewayRevision }
        == revision
    )
    var stale = authority
    stale.generation += 1
    do {
      try await supervisor.ensureWriter(stale)
      Issue.record("stale authority acquired writer access")
    } catch let error as MuxError { #expect(error.code == .staleAttachment) }
    #expect(
      guardian.queue.sync { guardian.workspaces[workspace]?.writer }
        == firstGrant
    )
    let rival = try await MuxConnection.connect(
      endpoint: controllerRoute,
      frontend: .native
    )
    do {
      _ = try await rival.execute(.attach(AttachRequest(.id(workspace))))
      Issue.record("ensuring writer displaced the current controller")
    } catch let error as MuxError { #expect(error.code == .leaseHeld) }
    await rival.close()
    try await client.send(.text("echo runtime-writer-still-held\r"), to: pane)
    _ = try await client.frame(of: pane) {
      $0.lines.contains("runtime-writer-still-held")
    }
    try await waitUntil { await runtime.nativeConnectionCount == 1 }

    let server = await client.welcome?.server
    let shell = try #require(guardian.inventory().first?.panes.first?.pid)
    #expect(await runtime.nativeRouteCount == 1)
    #expect(await runtime.nativeConnectionCount == 1)
    await runtime.close()
    #expect(await runtime.nativeRouteCount == 0)
    #expect(await runtime.nativeConnectionCount == 0)
    #expect(await runtime.activeObservationCount == 0)
    #expect(await runtime.failure == nil)
    #expect(kill(shell, 0) == 0)
    await #expect(throws: MuxError.self) { try await client.execute(.status) }
    await client.close()
    await #expect(throws: MuxError.self) {
      try await runtime.nativeEndpoint(for: .id(workspace))
    }

    let replacementControl = try await GatewaySupervisor.connect(
      peerRequirement: nil,
      expectedGuardianPID: getpid(),
      channel: { .connect(endpoint: controlEndpoint, queue: $0) }
    )
    let replacement = try await GatewayRuntime.start(
      supervisor: replacementControl,
      peerRequirement: nil,
      pollInterval: .milliseconds(20)
    )
    try await waitUntil {
      await replacement.records.contains {
        if case .available = $0.state { true } else { false }
      }
    }
    let freshRoute = try await replacement.nativeEndpoint(
      for: .name("retained"),
      role: .controller
    )
    let freshClient = try await MuxConnection.connect(
      endpoint: freshRoute,
      frontend: .native
    )
    #expect(await freshClient.welcome?.server == server)
    #expect(
      guardian.queue.sync { guardian.workspaces[workspace]?.writer }
        != firstGrant
    )
    let freshGraph = try await freshClient.attachAndShow(.id(workspace))
    let freshPane = freshGraph.tabs[0].activePane
    try await freshClient.send(
      .text("echo runtime-writer-two\r"),
      to: freshPane
    )
    _ = try await freshClient.frame(of: freshPane) {
      $0.lines.contains("runtime-writer-two")
    }

    #expect(kill(shell, 0) == 0)
    try await replacement.endWorkspace(.id(workspace))
    try await waitUntil {
      let empty = await replacement.records.isEmpty
      let routeCount = await replacement.nativeRouteCount
      let connectionCount = await replacement.nativeConnectionCount
      return empty && routeCount == 0 && connectionCount == 0
    }
    #expect(kill(shell, 0) == -1)
    await freshClient.close()
    // Losing the guardian control connection terminates the runtime monitor,
    // preserves its diagnostic, and drains all gateway resources.
    await replacementControl.close()
    try await waitUntil { await replacement.failure != nil }
    #expect(await replacement.failure?.code == .connectionLost)
    #expect(await replacement.activeObservationCount == 0)
    await replacement.close()
  }

  @Test(arguments: [false, true])
  func failedStartupReleasesOwnedGuardianConnection(
    cancelled: Bool
  ) async throws {
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
    let startup = Task {
      if cancelled { withUnsafeCurrentTask { $0?.cancel() } }
      return try await GatewayRuntime.start(
        supervisor: supervisor,
        peerRequirement: nil,
        capacity: cancelled ? 32 : 0
      )
    }
    do {
      let runtime = try await startup.value
      await runtime.close()
      Issue.record("invalid or cancelled startup succeeded")
    } catch is CancellationError { #expect(cancelled) } catch let error
      as MuxError
    { #expect(!cancelled && error.code == .invalidRequest) }
    await #expect(throws: MuxError.self) { try await supervisor.checkOpen() }
    #expect(guardian.inventory().isEmpty)
  }

  private func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await condition()) {
      guard ContinuousClock.now < deadline else {
        throw MuxError(.connectionLost, "runtime test timed out")
      }
      try await Task.sleep(for: .milliseconds(5))
    }
  }
}
