import Darwin
import Foundation
import SwiftMuxClient
import SwiftMuxGateway
import SwiftMuxGuardian
import SwiftMuxProtocol
import SwiftMuxService
import Synchronization
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct GatewayDirectoryTests {
  @Test
  func independentWorkersRetainUnavailableProcessesUntilExplicitEnd()
    async throws
  {
    let guardian = try GuardianServer(
      launcherPath: launcherPath(),
      peerRequirement: nil
    )
    let endpoint = guardian.listenAnonymously()
    let control = GuardianGatewayServer(
      guardian: guardian,
      peerRequirement: nil
    )
    let controlEndpoint = control.listenAnonymously()
    let ids = [WorkspaceID(), WorkspaceID(), WorkspaceID()]
    let published = Mutex(0)
    var hosts: [WorkspaceWorkerHost] = []
    defer {
      for host in hosts { host.close() }
      control.close()
      guardian.shutdown {}
    }
    for id in ids.prefix(2) {
      let token = try guardian.provisionWorker(workspace: id, pid: getpid())
      hosts.append(
        try WorkspaceWorkerHost(
          workspace: id,
          launcherPath: launcherPath(),
          peerRequirement: nil,
          connect: { queue, handlers in
            try GuardianWorkerConnection(
              channel: .connect(endpoint: endpoint, queue: queue),
              workspace: id,
              token: token,
              peerRequirement: nil,
              expectedGuardianPID: getpid(),
              handlers: handlers
            )
          },
          ready: { _ in published.withLock { $0 += 1 } },
          unavailable: { _ in }
        )
      )
    }
    // An admitted worker that never connects remains in inventory.
    _ = try guardian.provisionWorker(workspace: ids[2], pid: getpid())
    try await waitUntil { published.withLock { $0 } == 2 }
    let supervisor = try await GatewaySupervisor.connect(
      peerRequirement: nil,
      expectedGuardianPID: getpid(),
      channel: { .connect(endpoint: controlEndpoint, queue: $0) }
    )
    let identity = try #require(await supervisor.identity?.gateway)
    try await waitUntil {
      ids.prefix(2)
        .allSatisfy { guardian.gatewayReady(workspace: $0, gateway: identity) }
    }
    let directory = try GatewayWorkspaceDirectory(
      supervisor: supervisor,
      peerRequirement: nil
    )
    do {
      _ = try await directory.resolve(.id(ids[0]))
      Issue.record("undiscovered inventory was treated as empty")
    } catch let error as MuxError { #expect(error.code == .quiescing) }
    let undersized = try GatewayWorkspaceDirectory(
      supervisor: supervisor,
      peerRequirement: nil,
      capacity: 2
    )
    do {
      try await undersized.refresh()
      Issue.record("oversized inventory was silently truncated")
    } catch let error as MuxError { #expect(error.code == .resourceLimit) }
    #expect(await undersized.failure?.code == .resourceLimit)
    #expect(await undersized.activeObservationCount == 0)
    await undersized.close()
    #expect(await undersized.failure?.code == .resourceLimit)
    let monitor = Task {
      try await directory.monitor(interval: .milliseconds(20))
    }
    defer { monitor.cancel() }
    try await waitUntil {
      await directory.records.filter { $0.state == .empty }.count == 2
    }
    #expect(await directory.records.count == 3)
    #expect(guardian.inventory().allSatisfy { $0.panes.isEmpty })
    // Membership changes must be discovered without an explicit refresh.
    let added = WorkspaceID()
    _ = try guardian.provisionWorker(workspace: added, pid: getpid())
    try await waitUntil { await directory.records.count == 4 }
    let addedAuthority = try #require(
      guardian.inventory().first { $0.authority.workspace == added }?.authority
    )
    try await supervisor.endAndForget(addedAuthority)
    try await waitUntil { await directory.records.count == 3 }
    do {
      try await directory.monitor()
      Issue.record("duplicate directory monitor admitted")
    } catch let error as MuxError { #expect(error.code == .quiescing) }

    let authority = guardian.inventory().map(\.authority)
    for id in ids.prefix(2) {
      let owner = try #require(authority.first { $0.workspace == id })
      let client = try await supervisor.connectWorker(
        owner,
        peerRequirement: nil,
        frontend: .native
      )
      _ = try await client.execute(
        .newWorkspace(
          NewWorkspaceRequest(name: id.description, launch: shellLaunch())
        )
      )
      await client.close()
    }
    try await waitUntil {
      await directory.records
        .filter { if case .available = $0.state { true } else { false } }.count
        == 2
    }
    #expect(
      await directory.records.allSatisfy {
        if case let .available(summary) = $0.state {
          !summary.isAttached && summary.leaseGeneration == 0
            && $0.graph?.id == summary.id && $0.graph?.panes.count == 1
        } else {
          true
        }
      }
    )
    let selectedAuthority = try await directory.nativeAuthority(
      for: .id(ids[0])
    )
    #expect(selectedAuthority.workspace == ids[0])
    let routes = try GatewayNativeRoutes(
      supervisor: supervisor,
      directory: directory,
      peerRequirement: nil,
      capacity: 2,
      connectionLimit: 1
    )
    let selectedEndpoint = try await routes.endpoint(for: .id(ids[0]))
    _ = try await routes.endpoint(for: .id(ids[0]))
    #expect(await routes.routeCount == 1)
    let selectedClient = try await MuxConnection.connect(
      endpoint: selectedEndpoint,
      frontend: .native
    )
    let otherEndpoint = try await routes.endpoint(for: .id(ids[1]))
    #expect(await routes.routeCount == 2)
    #expect(await routes.connectionCount == 1)
    await #expect(throws: MuxError.self) {
      try await MuxConnection.connect(
        endpoint: otherEndpoint,
        frontend: .native
      )
    }
    #expect(await routes.connectionCount == 1)
    let limitedRoutes = try GatewayNativeRoutes(
      supervisor: supervisor,
      directory: directory,
      peerRequirement: nil,
      capacity: 1
    )
    _ = try await limitedRoutes.endpoint(for: .id(ids[0]))
    do {
      _ = try await limitedRoutes.endpoint(for: .id(ids[1]))
      Issue.record("unbounded native route admission")
    } catch let error as MuxError { #expect(error.code == .resourceLimit) }
    await limitedRoutes.close()
    guard
      case let .workspaces(selected) = try await selectedClient.execute(
        .listWorkspaces
      )
    else {
      throw MuxError(.invalidRequest, "selected route omitted its workspace")
    }
    #expect(selected.map(\.id) == [ids[0]])
    #expect(selected.first?.isAttached == false)
    await selectedClient.close()
    try await waitUntil { await routes.connectionCount == 0 }
    let otherClient = try await MuxConnection.connect(
      endpoint: otherEndpoint,
      frontend: .native
    )
    guard
      case let .workspaces(other) = try await otherClient.execute(
        .listWorkspaces
      )
    else {
      throw MuxError(.invalidRequest, "second route omitted its workspace")
    }
    #expect(other.map(\.id) == [ids[1]])
    let retainedPID = try #require(
      guardian.inventory().first { $0.authority.workspace == ids[0] }?.panes
        .first?
        .pid
    )
    let transient = try GatewayWorkspaceDirectory(
      supervisor: supervisor,
      peerRequirement: nil
    )
    let transientMonitor = Task {
      try await transient.monitor(interval: .seconds(60))
    }
    try await waitUntil {
      await transient.records
        .filter { if case .available = $0.state { true } else { false } }.count
        == 2
    }
    transientMonitor.cancel()
    do {
      try await transientMonitor.value
      Issue.record("cancelled live monitor completed normally")
    } catch is CancellationError {}

    #expect(await transient.activeObservationCount == 0)
    #expect(kill(retainedPID, 0) == 0)
    hosts[0].close()
    try await waitUntil {
      await directory.records.contains {
        guard $0.inventory.authority.workspace == ids[0] else { return false }
        if case .unavailable = $0.state { return true }
        return false
      }
    }
    #expect(kill(retainedPID, 0) == 0)
    try await waitUntil {
      await directory.records.contains {
        $0.inventory.authority.workspace == ids[0] && !$0.inventory.available
      }
    }
    try await routes.reconcile()
    #expect(await routes.routeCount == 1)
    _ = try await otherClient.execute(.status)
    await #expect(throws: MuxError.self) {
      try await MuxConnection.connect(
        endpoint: selectedEndpoint,
        frontend: .native
      )
    }
    let unavailable = try await directory.resolve(.id(ids[0]))
    #expect(unavailable.lastKnownSummary?.name == ids[0].description)
    #expect(unavailable.graph == nil)
    await #expect(throws: MuxError.self) {
      try await directory.nativeAuthority(for: .id(ids[0]))
    }
    let healthy = try #require(authority.first { $0.workspace == ids[1] })
    let client = try await supervisor.connectWorker(
      healthy,
      peerRequirement: nil,
      frontend: .native
    )
    _ = try await client.execute(
      .renameWorkspace(.id(ids[1]), name: "still healthy")
    )
    try await waitUntil {
      await directory.records.contains {
        if case let .available(summary) = $0.state {
          summary.name == "still healthy" && $0.graph?.name == "still healthy"
        } else {
          false
        }
      }
    }
    #expect(
      await directory.records.first {
        $0.inventory.authority.workspace == ids[0]
      }?
      .graph == nil
    )
    _ = try await client.execute(.attach(AttachRequest(.id(ids[1]))))
    _ = try await client.execute(.newTab(name: "added", launch: shellLaunch()))
    try await waitUntil {
      await directory.records.contains {
        guard $0.inventory.authority.workspace == ids[1],
          case let .available(summary) = $0.state
        else { return false }
        return summary.tabCount == 2 && $0.graph?.tabs.count == 2
          && $0.graph?.panes.count == 2
      }
    }
    #expect(await directory.records.count == 3)
    for owner in authority { try await supervisor.endAndForget(owner) }
    try await waitUntil { await directory.records.isEmpty }
    #expect(kill(retainedPID, 0) == -1)
    try await routes.reconcile()
    #expect(await routes.routeCount == 0)
    #expect(await routes.connectionCount == 0)
    await otherClient.close()
    await routes.close()
    await #expect(throws: MuxError.self) {
      try await routes.endpoint(for: .id(ids[1]))
    }
    // Reusing an ID under new authority must not inherit cached presentation.
    _ = try guardian.provisionWorker(workspace: ids[0], pid: getpid())
    try await waitUntil { await directory.records.count == 1 }
    let replacement = try await directory.resolve(.id(ids[0]))
    #expect(replacement.lastKnownSummary == nil)
    #expect(replacement.inventory.authority != selectedAuthority)
    try await supervisor.endAndForget(replacement.inventory.authority)
    try await waitUntil { await directory.records.isEmpty }
    // Retired observations cannot repopulate membership, even if they finish late.
    monitor.cancel()
    do {
      try await monitor.value
      Issue.record("cancelled monitor completed normally")
    } catch is CancellationError {}
    #expect(await directory.activeObservationCount == 0)
    #expect(await directory.records.isEmpty)
    await client.close()
    await supervisor.close()
  }

  private func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await condition()) {
      guard ContinuousClock.now < deadline else {
        throw MuxError(.connectionLost, "directory test wait timed out")
      }
      try await Task.sleep(for: .milliseconds(5))
    }
  }
}
