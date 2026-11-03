import AppKit
import Darwin
import Foundation
import MuxNavigation
import SwiftMuxClient
import SwiftMuxGateway
import SwiftMuxGuardian
import SwiftMuxProtocol
import SwiftMuxService
@testable import Swiftty
import SwifttyCore
import Synchronization
import Testing
import TestSupport

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct MuxGatewayWindowTests {
  enum RecoveryOutcome: CaseIterable { case reattached, busy, closed }

  @Test(
    .enabled(if: MuxNativeTests.hasMetal),
    arguments: RecoveryOutcome.allCases
  )
  func routedWindowsRenderAndReplaceWithoutFallingBackToLegacyService(
    outcome: RecoveryOutcome
  ) async throws {
    let competingController = outcome == .busy
    _ = NSApplication.shared
    let launcher = try NativeTestProducts.launcherPath()
    let guardian = try GuardianServer(
      launcherPath: launcher,
      peerRequirement: nil
    )
    let workers = guardian.listenAnonymously()
    let supervisorServer = GuardianGatewayServer(
      guardian: guardian,
      peerRequirement: nil
    )
    let supervisorEndpoint = supervisorServer.listenAnonymously()
    let ids = [WorkspaceID(), WorkspaceID()]
    let ready = Mutex(0)
    var hosts: [WorkspaceWorkerHost] = []
    var windows: [MuxWorkspaceController] = []
    defer {
      for window in windows { window.close() }
      for host in hosts { host.close() }
      supervisorServer.close()
      guardian.shutdown {}
    }
    for id in ids {
      let token = try guardian.provisionWorker(workspace: id, pid: getpid())
      hosts.append(
        try WorkspaceWorkerHost(
          workspace: id,
          launcherPath: launcher,
          peerRequirement: nil,
          connect: { queue, handlers in
            try GuardianWorkerConnection(
              channel: .connect(endpoint: workers, queue: queue),
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
      channel: { .connect(endpoint: supervisorEndpoint, queue: $0) }
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
            launch: LaunchSpec(
              command: ["/bin/sh"],
              workingDirectory: "/tmp",
              environment: ["PATH": "/usr/bin:/bin", "PS1": "$ "]
            )
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
    var availableGateway: MuxGatewayConnection? = gateway
    var unavailableAttempts = 0
    var connections = 0
    let application = MuxGatewayApplication(connect: {
      guard let availableGateway else {
        unavailableAttempts += 1
        throw MuxError(.connectionLost, "gateway restarting")
      }
      connections += 1
      return availableGateway
    })
    let listing = try await application.listing()
    #expect(listing.server == nil)
    #expect(Set(listing.gatewayRecords?.map(\.workspace) ?? []) == Set(ids))
    #expect(listing.workspaces.count == 2)
    let configuration = Configuration()
    let defaultsName = "gateway-window-test-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let delegate = AppDelegate(
      gatewayApplication: application,
      workspaceDefaults: defaults,
      listMuxWorkspaces: {
        Issue.record("legacy listing used in gateway mode");
        throw MuxError(.invalidRequest)
      },
      reportMuxAttachError: { Issue.record("unexpected list error: \($0)") },
      openMuxWorkspace: { _, _, _ in
        Issue.record("legacy open used in gateway mode");
        throw MuxError(.invalidRequest)
      },
      reportMuxOpenError: { Issue.record("unexpected open error: \($0)") }
    )
    delegate.workspaces.open(ids[0])
    let openingDeadline = ContinuousClock.now + .seconds(5)
    while delegate.workspaces.controllers.isEmpty {
      guard ContinuousClock.now < openingDeadline else {
        throw MuxError(.connectionLost, "delegate did not open routed window")
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    let first = try #require(delegate.workspaces.controllers.first)
    windows.append(first)
    show(first)
    try await prove(first, marker: "native-gateway-first")
    let firstServer = first.server
    let firstPane = try #require(first.activePane)
    let firstTab = first.workspace?.activeTab
    let rival = try await gateway.openWorkspace(.id(ids[1]), role: .controller)
    _ = try await rival.connection.execute(.attach(AttachRequest(.id(ids[1]))))
    do {
      _ = try await MuxWorkspaceController.replace(
        first,
        with: .id(ids[1]),
        configuration: configuration,
        gateway: gateway
      )
      Issue.record("replacement displaced an unconsenting controller")
    } catch let error as MuxError { #expect(error.code == .leaseHeld) }
    #expect(first.holdsLease && !first.isClosed)
    try await prove(first, marker: "native-gateway-retained")
    await rival.connection.detach()
    await rival.connection.close()
    let second = try await MuxWorkspaceController.replace(
      first,
      with: .id(ids[1]),
      configuration: configuration,
      gateway: gateway
    )
    windows.append(second)
    show(second)
    #expect(first.isClosed && second.server != firstServer)
    #expect(second.gateway === gateway)
    try await prove(second, marker: "native-gateway-second")
    // Attention navigation must select the target worker, not invoke the default
    // legacy connection factory or reuse the current worker's route.
    let returned = try await MuxWorkspaceController.reveal(
      PaneTarget(workspace: ids[0], tab: firstTab, pane: firstPane),
      in: second,
      configuration: configuration,
      connect: {
        Issue.record("gateway navigation fell back to legacy service");
        throw MuxError(.invalidRequest)
      }
    )
    windows.append(returned)
    show(returned)
    #expect(second.isClosed && returned.server == firstServer)
    #expect(returned.gateway === gateway)
    try await prove(returned, marker: "native-gateway-returned")
    let pids = guardian.inventory().flatMap { $0.panes.map(\.pid) }
    await returned.detach()
    returned.close()
    #expect(pids.count == 2 && pids.allSatisfy { kill($0, 0) == 0 })
    // Reopening an attention target with no current window uses the injected
    // gateway open callback, not the coordinator's default legacy connector.
    try await delegate.workspaces.reveal(
      PaneTarget(workspace: ids[0], tab: firstTab, pane: firstPane),
      takeover: nil,
      connect: {
        Issue.record("missing-window reveal fell back to legacy");
        throw MuxError(.invalidRequest)
      }
    )
    let revealed = try #require(delegate.workspaces.controller(holding: ids[0]))
    windows.append(revealed)
    try await prove(revealed, marker: "native-gateway-delegate-reveal")
    let oldAttachment = try #require(
      MuxNativeTests().activeView(revealed)?.presented?.frame.identity
        .attachment
    )
    // Keep the window and both shell processes while replacing all gateway state.
    availableGateway = nil
    await server.close()
    await runtime.close()
    try await waitUntil { !revealed.holdsLease && unavailableAttempts > 0 }
    if outcome == .closed {
      revealed.close()
      #expect(revealed.gatewayRecovery == nil)
    }
    let replacementSupervisor = try await GatewaySupervisor.connect(
      peerRequirement: nil,
      expectedGuardianPID: getpid(),
      channel: { .connect(endpoint: supervisorEndpoint, queue: $0) }
    )
    let replacementRuntime = try await GatewayRuntime.start(
      supervisor: replacementSupervisor,
      peerRequirement: nil,
      pollInterval: .milliseconds(20)
    )
    try await waitUntil {
      await replacementRuntime.records
        .filter { if case .available = $0.state { true } else { false } }.count
        == 2
    }
    let replacementServer = GatewayControlServer(
      runtime: replacementRuntime,
      peerRequirement: nil
    )
    let replacementEndpoint = replacementServer.listenAnonymously()
    let newGateway = try await MuxGatewayConnection.connect(
      peerRequirement: nil,
      expectedPID: getpid(),
      channel: { .connect(endpoint: replacementEndpoint, queue: $0) }
    )
    var competitor: MuxConnection?
    if competingController {
      let route = try await newGateway.openWorkspace(
        .id(ids[0]),
        role: .controller
      )
      _ = try await route.connection.execute(
        .attach(AttachRequest(.id(ids[0])))
      )
      competitor = route.connection
      try await waitUntil {
        let records = await replacementRuntime.records
        return records.contains {
          guard $0.inventory.authority.workspace == ids[0],
            case let .available(summary) = $0.state
          else { return false }
          return summary.isAttached
        }
      }
    }
    availableGateway = newGateway
    if outcome == .closed {
      // A restored gateway must not reopen a window closed during backoff.
      try await Task.sleep(for: .milliseconds(300))
      #expect(delegate.workspaces.controller(holding: ids[0]) == nil)
      #expect(connections == 1)
    } else if competingController {
      try await waitUntil { revealed.gatewayRecovery == nil }
      #expect(!revealed.isClosed && !revealed.holdsLease)
      #expect(revealed.window?.subtitle.contains("Reconnect failed") == true)
      #expect(delegate.workspaces.controller(holding: ids[0]) == nil)
      // Recovery must not ask for takeover or displace the new controller.
      try await competitor?.checkOpen()
    } else {
      // No attention action or explicit reconnect: transport loss recovers itself.
      try await waitUntil {
        delegate.workspaces.controller(holding: ids[0]) != nil
      }
      let reattached = try #require(
        delegate.workspaces.controller(holding: ids[0])
      )
      windows.append(reattached)
      #expect(revealed.isClosed && reattached !== revealed)
      #expect(reattached.server == firstServer)
      #expect(reattached.gateway === availableGateway)
      let retainedView = try #require(MuxNativeTests().activeView(reattached))
      #expect(
        await MuxNativeTests()
          .waitPresented(retainedView) {
            $0.lines.contains("native-gateway-delegate-reveal")
          } != nil
      )
      #expect(
        retainedView.presented?.frame.identity.attachment != oldAttachment
      )
      try await prove(reattached, marker: "native-gateway-restarted")
    }
    await competitor?.detach()
    await competitor?.close()
    #expect(pids.allSatisfy { kill($0, 0) == 0 })
    await delegate.workspaces.terminate()
    #expect(try await application.listing().gatewayRecords?.count == 2)
    #expect(connections == 2)
    do {
      _ = try await application.open(
        nil,
        configuration: configuration,
        takeover: nil
      )
      Issue.record("unconfigured worker creation unexpectedly succeeded")
    } catch let error as MuxError {
      let id = try #require(application.lastCreationID)
      #expect(error.message.contains(id.description))
    }
    #expect(guardian.inventory().count == 2)
    let finalGateway = try #require(availableGateway)
    for id in ids { try await finalGateway.endWorkspace(.id(id)) }
    await application.close()
    await replacementServer.close()
    await replacementRuntime.close()
    await server.close()
    await runtime.close()
  }

  private func show(_ controller: MuxWorkspaceController) {
    controller.window?.isReleasedWhenClosed = false
    controller.showWindow(nil)
  }

  private func prove(
    _ controller: MuxWorkspaceController,
    marker: String
  ) async throws {
    let helper = MuxNativeTests()
    let view = try #require(helper.activeView(controller))
    controller.send(.text("echo \(marker)\r"), to: view.pane)
    #expect(
      await helper.waitPresented(view) { $0.lines.contains(marker) } != nil
    )
  }

  private func waitUntil(_ condition: @MainActor () async -> Bool) async throws
  {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await condition()) {
      guard ContinuousClock.now < deadline else {
        throw MuxError(.connectionLost, "gateway window test timed out")
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}
