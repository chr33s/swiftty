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
struct GatewaySupervisorTests {
  @Test
  func cancellationKeepsTransmittedSlotAndBoundsQueuedCommands() async throws {
    let fake = FakeGuardian()
    defer { fake.close() }
    let supervisor = try await GatewaySupervisor.connect(
      peerRequirement: nil,
      expectedGuardianPID: getpid(),
      channel: { .connect(endpoint: fake.endpoint, queue: $0) }
    )
    do {
      try await supervisor.ensureWriter(
        GuardianAuthority(
          incarnation: UUID(),
          workspace: WorkspaceID(),
          generation: 1
        )
      )
      Issue.record("old guardian received an unsupported writer request")
    } catch let error as MuxError {
      #expect(error.code == .incompatibleVersion)
    }
    do {
      _ = try await supervisor.admissionStatus()
      Issue.record("old guardian accepted admission status")
    } catch let error as MuxError {
      #expect(error.code == .incompatibleVersion)
    }
    do {
      _ = try await supervisor.setAdmissionPaused(true, expectedRevision: 0)
      Issue.record("old guardian accepted admission mutation")
    } catch let error as MuxError {
      #expect(error.code == .incompatibleVersion)
    }
    do {
      _ = try await supervisor.workerSelection()
      Issue.record("old guardian accepted selection query")
    } catch let error as MuxError {
      #expect(error.code == .incompatibleVersion)
    }
    do {
      _ = try await supervisor.selectWorkerBuild("one", expectedRevision: 0)
      Issue.record("old guardian accepted build selection")
    } catch let error as MuxError {
      #expect(error.code == .incompatibleVersion)
    }
    do {
      _ = try await supervisor.clearWorkerRollback(expectedRevision: 0)
      Issue.record("old guardian accepted rollback change")
    } catch let error as MuxError {
      #expect(error.code == .incompatibleVersion)
    }
    do {
      _ = try await supervisor.settledUpdateInventory(expectedRevision: 0)
      Issue.record("old guardian passed update barrier")
    } catch let error as MuxError {
      #expect(error.code == .incompatibleVersion)
    }
    #expect(fake.received.withLock { $0 } == 0)
    #expect(await supervisor.pendingCommandCount == 0)
    let active = Task { try await supervisor.inventory() }
    try await waitUntil { fake.received.withLock { $0 } == 1 }
    let waiting = (0 ..< 63)
      .map { _ in Task { try await supervisor.inventory() } }
    try await waitUntil { await supervisor.pendingCommandCount == 64 }
    do {
      _ = try await supervisor.inventory()
      Issue.record("unbounded supervisor admission")
    } catch let error as MuxError { #expect(error.code == .resourceLimit) }
    for task in waiting { task.cancel() }
    for task in waiting {
      await #expect(throws: CancellationError.self) { try await task.value }
    }
    active.cancel()
    await #expect(throws: CancellationError.self) { try await active.value }
    #expect(await supervisor.pendingCommandCount == 1)
    let next = Task { try await supervisor.inventory() }
    try await waitUntil { await supervisor.pendingCommandCount == 2 }
    #expect(fake.received.withLock { $0 } == 1)
    fake.reply(sequence: 1)
    try await waitUntil { fake.received.withLock { $0 } == 2 }
    fake.reply(sequence: 2)
    #expect(try await next.value.isEmpty)
    #expect(await supervisor.pendingCommandCount == 0)
    let lost = Task { try await supervisor.inventory() }
    try await waitUntil { fake.received.withLock { $0 } == 3 }
    let queued = Task { try await supervisor.inventory() }
    try await waitUntil { await supervisor.pendingCommandCount == 2 }
    await supervisor.close()
    await #expect(throws: MuxError.self) { try await lost.value }
    await #expect(throws: MuxError.self) { try await queued.value }
    #expect(fake.received.withLock { $0 } == 3)
    #expect(await supervisor.pendingCommandCount == 0)
  }

  @Test
  func discoversSurvivingWorkerWithoutCreatingOrTakingItsLease() async throws {
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
      host.close()
      control.close()
      guardian.shutdown {}
    }
    try await waitUntil { published.withLock { $0 } }
    let first = try await GatewaySupervisor.connect(
      peerRequirement: nil,
      expectedGuardianPID: getpid(),
      channel: { .connect(endpoint: controlEndpoint, queue: $0) }
    )
    let barrier = try await first.admissionStatus()
    #expect(!barrier.paused && barrier.pendingWorkers == 0)
    _ = try await first.setAdmissionPaused(
      true,
      expectedRevision: barrier.revision
    )
    let authority = try #require(try await first.inventory().first?.authority)
    let firstIdentity = try #require(await first.identity?.gateway)
    try await waitUntil {
      guardian.gatewayReady(workspace: workspace, gateway: firstIdentity)
    }
    let observation = try await GatewayWorkspaceObservation.open(
      authority: authority,
      supervisor: first,
      peerRequirement: nil
    )
    #expect(await observation.summary == nil)
    let graphObservation = try await GatewayGraphObservation.open(
      authority: authority,
      supervisor: first,
      peerRequirement: nil
    )
    #expect(await graphObservation.graph == nil)
    let client = try await first.connectWorker(
      authority,
      peerRequirement: nil,
      frontend: .native
    )
    _ = try await client.execute(
      .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
    )
    let initialGraph = try #require(
      try await graphObservation.next(timeout: .seconds(3))
    )
    #expect(initialGraph.id == workspace)
    #expect(initialGraph.panes.count == 1)
    #expect(initialGraph.tabs.count == 1)
    #expect(initialGraph.attachmentRole == nil)
    let initialSummary = try #require(
      try await observation.next(timeout: .seconds(3))
    )
    #expect(initialSummary.id == workspace)
    #expect(!initialSummary.isAttached)
    #expect(initialSummary.leaseGeneration == 0)
    _ = try await client.execute(
      .renameWorkspace(.id(workspace), name: "surviving workspace")
    )
    let renamed = try #require(try await observation.next(timeout: .seconds(3)))
    #expect(renamed.name == "surviving workspace")
    let renamedGraph = try #require(
      try await graphObservation.next(timeout: .seconds(3))
    )
    #expect(renamedGraph.name == renamed.name)
    #expect(renamedGraph.layoutRevision > initialGraph.layoutRevision)
    #expect(renamedGraph.panes.first?.pid == initialGraph.panes.first?.pid)
    await graphObservation.close()
    let cancelledWait = Task {
      try await observation.next(timeout: .seconds(3))
    }
    cancelledWait.cancel()
    await #expect(throws: CancellationError.self) {
      try await cancelledWait.value
    }
    #expect(await observation.summary?.name == "surviving workspace")
    let pid = try #require(try await first.inventory().first?.panes.first?.pid)
    #expect(kill(pid, 0) == 0)
    await first.close()
    await #expect(throws: MuxError.self) {
      try await observation.next(timeout: .seconds(3))
    }
    #expect(await observation.summary == nil)
    let second = try await GatewaySupervisor.connect(
      peerRequirement: nil,
      expectedGuardianPID: getpid(),
      channel: { .connect(endpoint: controlEndpoint, queue: $0) }
    )
    let rediscovered = try await second.inventory()
    #expect(rediscovered.count == 1)
    #expect(rediscovered.first?.authority == authority)
    #expect(rediscovered.first?.panes.first?.pid == pid)
    let secondIdentity = try #require(await second.identity?.gateway)
    try await waitUntil {
      guardian.gatewayReady(workspace: workspace, gateway: secondIdentity)
    }
    let rediscoveredObservation = try await GatewayWorkspaceObservation.open(
      authority: authority,
      supervisor: second,
      peerRequirement: nil
    )
    #expect(
      await rediscoveredObservation.summary?.name == "surviving workspace"
    )
    #expect(await rediscoveredObservation.summary?.isAttached == false)
    let survivingGraph = try await GatewayGraphObservation.open(
      authority: authority,
      supervisor: second,
      peerRequirement: nil
    )
    #expect(await survivingGraph.graph == renamedGraph)
    guard
      case let .endpoint(workerEndpoint) = try await second.request(
        .endpoint(workspace: workspace)
      )
    else { throw MuxError(.invalidRequest, "missing relay worker") }
    let nativeEndpoint = try GatewayNativeEndpoint(
      supervisor: second,
      authority: authority,
      peerRequirement: nil,
      capacity: 1
    )
    let reattached = try await MuxConnection.connect(
      endpoint: nativeEndpoint.endpoint,
      frontend: .native
    )
    await #expect(throws: MuxError.self) {
      try await MuxConnection.connect(
        endpoint: nativeEndpoint.endpoint,
        frontend: .native
      )
    }
    #expect(await reattached.welcome?.server == workerEndpoint.instance)
    #expect(await reattached.welcome?.forwardedTransport == nil)
    #expect(
      await reattached.welcome?.features.contains(.workspaceGraph) == false
    )
    await #expect(throws: MuxError.self) {
      try await reattached.execute(.observeWorkspaceGraph(true))
    }
    _ = try await reattached.execute(.status)
    let remote = try await second.connectWorker(
      authority,
      peerRequirement: nil,
      frontend: .native,
      forwardedTransport: .remote
    )
    #expect(await remote.welcome?.forwardedTransport == .remote)
    for command in [
      MuxCommand.subscribeAutomation(true), .observeWorkspaceGraph(true),
      .attach(AttachRequest(.id(workspace), role: .observer)),
    ] {
      do {
        _ = try await remote.execute(command)
        Issue.record("forwarded remote client acquired local-only access")
      } catch let error as MuxError { #expect(error.code == .unauthorized) }
    }
    _ = try await remote.execute(.attach(AttachRequest(.id(workspace))))
    guard
      case let .workspaces(summaries) = try await reattached.execute(
        .listWorkspaces
      )
    else { throw MuxError(.invalidRequest, "missing remote lease summary") }
    #expect(summaries.first?.leaseHolder?.transport == .remote)
    await remote.close()
    try await second.grantWriter(workspace)
    try await waitUntil {
      guardian.gatewayReady(workspace: workspace, gateway: secondIdentity)
    }
    let shown = try await reattached.attachAndShow(.id(workspace))
    let pane = shown.tabs[0].activePane
    try await reattached.send(.text("echo native-relay-ok\r"), to: pane)
    _ = try await reattached.frame(of: pane) {
      $0.lines.contains("native-relay-ok")
    }
    for report in ["relay-inbox-one", "relay-inbox-two"] {
      _ = try await reattached.execute(.subscribeInbox(true))
      try await reattached.send(
        .text("printf '\\033]7501;state=error:id=\(report)\\007'\r"),
        to: pane
      )
      while true {
        if case let .inbox(update) = try await reattached.nextEvent(
          timeout: .seconds(2)
        ) {
          #expect(update.acknowledgementToken != nil)
          break
        }
      }
      _ = try await reattached.execute(.subscribeInbox(false))
    }
    _ = try await reattached.execute(.detach)
    _ = try await reattached.attachAndShow(.id(workspace))
    await #expect(throws: MuxError.self) { try await client.execute(.status) }
    #expect(kill(pid, 0) == 0)
    // A stale route cannot silently follow a different ownership generation.
    let staleAdmission = try GatewayNativeAdmission(limit: 1)
    let staleEndpoint = try GatewayNativeEndpoint(
      supervisor: second,
      authority: GuardianAuthority(
        incarnation: authority.incarnation,
        workspace: authority.workspace,
        generation: authority.generation + 1
      ),
      peerRequirement: nil,
      admission: staleAdmission
    )
    await #expect(throws: MuxError.self) {
      try await MuxConnection.connect(
        endpoint: staleEndpoint.endpoint,
        frontend: .native
      )
    }
    try await waitUntil { staleAdmission.count == 0 }
    await staleEndpoint.close()
    #expect(kill(pid, 0) == 0)
    await reattached.close()
    try await waitUntil { await nativeEndpoint.connectionCount == 0 }
    let finalClient = try await MuxConnection.connect(
      endpoint: nativeEndpoint.endpoint,
      frontend: .native
    )
    _ = try await finalClient.execute(.status)
    #expect(await nativeEndpoint.connectionCount == 1)
    // Closing a listener cancels its connections, not the retained shell.
    await nativeEndpoint.close()
    #expect(await nativeEndpoint.connectionCount == 0)
    #expect(kill(pid, 0) == 0)
    await #expect(throws: MuxError.self) {
      try await finalClient.execute(.status)
    }
    await finalClient.close()
    let endingClient = try await second.connectWorker(
      authority,
      peerRequirement: nil,
      frontend: .native
    )
    _ = try await endingClient.execute(.endWorkspace(.id(workspace)))
    await endingClient.close()
    while try await survivingGraph.next(timeout: .seconds(3)) != nil {}
    #expect(await survivingGraph.graph == nil)
    await survivingGraph.close()
    try await second.endAndForget(authority)
    #expect(try await second.inventory().isEmpty)
    #expect(kill(pid, 0) == -1)
    await rediscoveredObservation.close()
    await nativeEndpoint.close()
    await #expect(throws: MuxError.self) {
      try await reattached.execute(.status)
    }
    await reattached.close()
    await client.close()
    await second.close()
  }

  private func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await condition()) {
      guard ContinuousClock.now < deadline else {
        throw MuxError(.connectionLost, "test wait timed out")
      }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  final class FakeGuardian: Sendable {
    let queue = DispatchQueue(label: "gateway-supervisor-fake")
    let listener: SMXListener
    let received = Mutex(0)
    let channel = Mutex<SMXChannel?>(nil)
    var endpoint: SMXEndpoint { listener.endpoint }

    init(supportsUpdateBarrier: Bool = false) {
      listener = SMXListener(anonymousOn: queue)
      listener.activate(connectionQueue: queue) { [weak self] channel in
        guard let self else { return }
        self.channel.withLock { $0 = channel }
        channel.activate { [weak self] event in
          guard let self, case let .message(data) = event,
            let request = try? JSONDecoder()
              .decode(GuardianGatewayRequest.self, from: data)
          else { return }
          switch request {
          case .hello:
            channel.send(
              try! JSONEncoder()
                .encode(
                  GuardianGatewayEvent.welcome(
                    incarnation: UUID(),
                    gateway: UUID(),
                    supportsAdmissionControl: supportsUpdateBarrier,
                    supportsWorkerSelection: supportsUpdateBarrier
                  )
                )
            )
          case .command: self.received.withLock { $0 += 1 }
          case .acknowledge: break
          }
        }
      }
    }

    func reply(sequence: UInt64) {
      queue.async { [self] in
        channel.withLock { $0 }?
          .send(
            try! JSONEncoder()
              .encode(
                GuardianGatewayEvent.result(
                  sequence: sequence,
                  value: .inventory([])
                )
              )
          )
      }
    }

    func close() {
      queue.sync {
        channel.withLock { $0 }?.cancel()
        listener.cancel()
      }
    }
  }
}
