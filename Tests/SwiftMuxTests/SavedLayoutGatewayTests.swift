import Darwin
import Foundation
import SwiftMuxClient
@testable import SwiftMuxGateway
@testable import SwiftMuxGuardian
import SwiftMuxProtocol
import SwiftMuxService
import SwiftMuxXPC
import Synchronization
import Testing

/// Saved layouts through a real guardian, worker and gateway runtime
/// (spec.durability.md §12.2; RS1, RS2, RS4 and RS11 end to end).
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SavedLayoutGatewayTests {
  /// The listing once discovery has completed (it refuses until then).
  private func listing(
    _ runtime: GatewayRuntime
  ) async throws -> SavedWorkspaceList {
    let deadline = ContinuousClock.now + .seconds(10)
    while true {
      do { return try await runtime.savedWorkspaces() } catch let error
        as MuxError
        where error.code == .quiescing && ContinuousClock.now < deadline
      { try await Task.sleep(for: .milliseconds(20)) }
    }
  }

  private func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !(await condition()) {
      guard ContinuousClock.now < deadline else {
        throw MuxError(.connectionLost, "saved layout test timed out")
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  /// One guardian incarnation with one provisioned worker.
  final class Topology: @unchecked Sendable {
    let guardian: GuardianServer
    let host: WorkspaceWorkerHost
    let control: GuardianGatewayServer
    let controlEndpoint: SMXEndpoint
    let workspace: WorkspaceID

    init(workspace: WorkspaceID) async throws {
      self.workspace = workspace
      guardian = try GuardianServer(
        launcherPath: launcherPath(),
        peerRequirement: nil
      )
      let token = try guardian.provisionWorker(
        workspace: workspace,
        pid: getpid()
      )
      let endpoint = guardian.listenAnonymously()
      let published = Mutex(false)
      host = try WorkspaceWorkerHost(
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
      control = GuardianGatewayServer(guardian: guardian, peerRequirement: nil)
      controlEndpoint = control.listenAnonymously()
      let deadline = ContinuousClock.now + .seconds(5)
      while !published.withLock({ $0 }) {
        guard ContinuousClock.now < deadline else {
          throw MuxError(.connectionLost, "worker did not publish")
        }
        try await Task.sleep(for: .milliseconds(10))
      }
    }

    func runtime(
      saved: SavedLayoutService
    ) async throws -> (GatewayRuntime, GatewaySupervisor) {
      let endpoint = controlEndpoint
      let supervisor = try await GatewaySupervisor.connect(
        peerRequirement: nil,
        expectedGuardianPID: getpid(),
        channel: { .connect(endpoint: endpoint, queue: $0) }
      )
      let runtime = try await GatewayRuntime.start(
        supervisor: supervisor,
        peerRequirement: nil,
        pollInterval: .milliseconds(20),
        saved: saved
      )
      return (runtime, supervisor)
    }

    /// Guardian loss, as at logout or reboot: shells end with it.
    func lose() {
      host.close()
      control.close()
      let stopped = DispatchSemaphore(value: 0)
      guardian.shutdown { stopped.signal() }
      _ = stopped.wait(timeout: .now() + 8)
    }
  }

  private func service(root: URL, keys: MemoryKeyStore) -> SavedLayoutService {
    var timing = SavedLayoutService.Timing()
    timing.exitHold = .milliseconds(200)
    timing.writeInterval = .milliseconds(20)
    return SavedLayoutService(
      files: SavedLayoutFiles(root: root),
      keys: keys,
      build: "test",
      timing: timing
    )
  }

  @Test
  func layoutSurvivesGuardianLossAndListsAsSaved() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "saved-gateway-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let keys = MemoryKeyStore()
    let workspace = WorkspaceID()
    let first = try await Topology(workspace: workspace)
    let saved = service(root: root, keys: keys)
    let (runtime, supervisor) = try await first.runtime(saved: saved)
    let authority = try #require(first.guardian.inventory().first?.authority)
    let bootstrap = try await supervisor.connectWorker(
      authority,
      peerRequirement: nil,
      frontend: .native
    )
    var launch = shellLaunch()
    launch.workingDirectory = "/tmp"
    _ = try await bootstrap.execute(
      .newWorkspace(NewWorkspaceRequest(name: "kept", launch: launch))
    )
    await bootstrap.close()
    try await waitUntil { await saved.record(workspace) != nil }
    try await waitUntil {
      await runtime.records.contains {
        if case .available = $0.state { true } else { false }
      }
    }
    let routed = try await runtime.nativeEndpoint(
      for: .id(workspace),
      role: .controller
    )
    let client = try await MuxConnection.connect(
      endpoint: routed,
      frontend: .native
    )
    let shown = try await client.attachAndShow(.id(workspace))
    let pane = shown.tabs[0].activePane
    _ = try await client.execute(
      .split(pane: pane, axis: .leftRight, launch: nil)
    )
    _ = try await client.execute(.renameTab(shown.tabs[0].id, name: "edit"))
    try await waitUntil {
      let record = await saved.record(workspace)
      return record?.content.paneCount == 2
        && record?.content.tabs.first?.name == "edit"
    }
    let content = try #require(await saved.record(workspace)?.content)
    // The split inherited the first pane's local directory.
    #expect(content.panes.map(\.localDirectory) == ["/tmp", "/tmp"])
    #expect(content.panes[0].launch == .command(["/bin/sh"]))
    #expect(content.panes[1].launch == .loginShell)
    // Live while its guardian runs; nothing to reopen.
    let live = try await listing(runtime)
    #expect(live.workspaces.map(\.state) == [.live])
    await #expect(throws: MuxError.self) {
      try await runtime.reopenSaved(
        SavedReopenRequest(record: workspace, launch: shellLaunch())
      )
    }
    await client.close()
    await runtime.close()
    first.lose()

    // After the loss, a new guardian incarnation and gateway.
    let second = try await Topology(workspace: WorkspaceID())
    defer { second.lose() }
    let reread = service(root: root, keys: keys)
    let (next, _) = try await second.runtime(saved: reread)
    let list = try await listing(next)
    #expect(list.store == .available)
    let entry = try #require(list.workspaces.first { $0.id == workspace })
    #expect(entry.state == .saved && entry.name == "kept")
    #expect(entry.paneCount == 2 && entry.tabCount == 1)
    #expect(entry.commands == [.init(slot: 0, command: ["/bin/sh"])])
    #expect(await reread.record(workspace)?.firstOfferedAt != nil)
    // The shell exits did not shrink the saved layout.
    #expect(await reread.record(workspace)?.content == content)
    await next.close()
  }

  @Test
  func workerEndDispositionsReachTheStore() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "saved-gateway-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let keys = MemoryKeyStore()
    let workspace = WorkspaceID()
    let topology = try await Topology(workspace: workspace)
    defer { topology.lose() }
    let saved = service(root: root, keys: keys)
    let (runtime, supervisor) = try await topology.runtime(saved: saved)
    let authority = try #require(topology.guardian.inventory().first?.authority)
    let bootstrap = try await supervisor.connectWorker(
      authority,
      peerRequirement: nil,
      frontend: .native
    )
    _ = try await bootstrap.execute(
      .newWorkspace(NewWorkspaceRequest(name: "kept", launch: shellLaunch()))
    )
    try await waitUntil { await saved.record(workspace) != nil }
    // An update-style End keeps the record for reopening.
    _ = try await bootstrap.execute(
      .endWorkspace(.id(workspace), disposition: .retained)
    )
    try await waitUntil {
      await saved.record(workspace)?.disposition == .retained
    }
    await bootstrap.close()
    // Listed as saved once the gateway has observed the End.
    try await waitUntil {
      (try? await runtime.savedWorkspaces())?.workspaces
        .first { $0.id == workspace }?
        .state == .saved
    }
    try await runtime.deleteSaved(workspace)
    #expect(await saved.record(workspace) == nil)
    await runtime.close()
  }
}
