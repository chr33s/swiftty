import Darwin
import Dispatch
import Foundation
import SwiftMuxGateway
import SwiftMuxGuardian
import SwiftMuxProtocol
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct GatewayUpdateBarrierTests {
  private func waitFor(_ semaphore: DispatchSemaphore, seconds: Double) -> Bool
  { semaphore.wait(timeout: .now() + seconds) == .success }

  @Test
  func deadlineIncludesStalledGuardianRequest() async throws {
    let fake = GatewaySupervisorTests.FakeGuardian(supportsUpdateBarrier: true)
    defer { fake.close() }
    let supervisor = try await GatewaySupervisor.connect(
      peerRequirement: nil,
      channel: { .connect(endpoint: fake.endpoint, queue: $0) }
    )
    let start = ContinuousClock.now
    do {
      _ = try await supervisor.settledUpdateInventory(
        expectedRevision: 1,
        timeout: .milliseconds(50)
      )
      Issue.record("stalled guardian passed update barrier")
    } catch let error as MuxError { #expect(error.code == .quiescing) }
    #expect(start.duration(to: .now) < .seconds(2))
    #expect(fake.received.withLock { $0 } == 1)
    // Cancellation abandons the caller, not the uncertain transmitted wire slot.
    #expect(await supervisor.pendingCommandCount == 1)
    await supervisor.close()
  }

  @Test(arguments: ["settle", "timeout", "cancel", "changed", "gateway"])
  func pendingAdmissionsHaveOneDeadlineAndStableRevision(
    mode: String
  ) async throws {
    let fixture = try GuardianBuildRegistryTests.Fixture()
    defer { fixture.remove() }
    let guardian = try GuardianServer(
      launcherPath: launcherPath(),
      peerRequirement: nil
    )
    let workspace = WorkspaceID()
    _ = try guardian.provisionWorker(workspace: workspace, pid: getpid())
    let control = GuardianGatewayServer(
      guardian: guardian,
      peerRequirement: nil,
      buildRegistry: try fixture.registry(),
      workerMachService: "qualification.unused"
    )
    let endpoint = control.listenAnonymously()
    defer {
      control.close()
      let stopped = DispatchSemaphore(value: 0)
      guardian.shutdown { stopped.signal() }
      #expect(waitFor(stopped, seconds: 5))
    }
    let supervisor = try await GatewaySupervisor.connect(
      peerRequirement: nil,
      channel: { .connect(endpoint: endpoint, queue: $0) }
    )
    let pause = try await supervisor.setAdmissionPaused(
      true,
      expectedRevision: 0
    )
    let task = Task {
      try await supervisor.settledUpdateInventory(
        expectedRevision: pause.revision,
        timeout: mode == "timeout" ? .milliseconds(75) : .seconds(2)
      )
    }
    try await Task.sleep(for: .milliseconds(20))
    var inspection = supervisor
    switch mode {
    case "settle":
      let authority = try #require(guardian.inventory().first?.authority)
      try guardian.endWorkspace(
        authority: authority,
        gateway: try #require(await supervisor.identity?.gateway)
      )
      let inventory = try await task.value
      #expect(inventory.count == 1 && inventory.first?.starting == false)
    case "cancel":
      task.cancel()
      await #expect(throws: CancellationError.self) { try await task.value }
    case "gateway":
      inspection = try await GatewaySupervisor.connect(
        peerRequirement: nil,
        channel: { .connect(endpoint: endpoint, queue: $0) }
      )
      do {
        _ = try await task.value
        Issue.record("old gateway completed update barrier")
      } catch let error as MuxError { #expect(error.code == .connectionLost) }
    case "changed":
      _ = try await supervisor.setAdmissionPaused(
        true,
        expectedRevision: pause.revision
      )
      do {
        _ = try await task.value
        Issue.record("newer pause accepted as original barrier")
      } catch let error as MuxError { #expect(error.code == .staleRevision) }
    default:
      do {
        _ = try await task.value
        Issue.record("starting worker passed deadline")
      } catch let error as MuxError { #expect(error.code == .quiescing) }
    }
    // A replacement gateway did not start a settling update: it resumes.
    #expect(
      try await inspection.admissionStatus().paused == (mode != "gateway")
    )
    #expect(guardian.inventory().count == 1)
    await inspection.close()
    await supervisor.close()
  }

  @Test(arguments: ["deadline", "gateway", "replacing"])
  func settlingPauseResumesWithoutItsUpdater(mode: String) async throws {
    let guardian = try GuardianServer(
      launcherPath: launcherPath(),
      peerRequirement: nil,
      admissionSettlementTimeout: mode == "deadline" ? 0.1 : 30
    )
    let control = GuardianGatewayServer(
      guardian: guardian,
      peerRequirement: nil
    )
    let endpoint = control.listenAnonymously()
    defer {
      control.close()
      let stopped = DispatchSemaphore(value: 0)
      guardian.shutdown { stopped.signal() }
      #expect(waitFor(stopped, seconds: 5))
    }
    let updater = try await GatewaySupervisor.connect(
      peerRequirement: nil,
      channel: { .connect(endpoint: endpoint, queue: $0) }
    )
    var status = try await updater.setAdmissionPaused(true, expectedRevision: 0)
    #expect(status.phase == .settling)
    if mode == "replacing" {
      status = try await updater.beginGatewayReplacement(
        expectedRevision: status.revision
      )
      #expect(status.phase == .replacing && status.paused)
      do {
        _ = try await updater.beginGatewayReplacement(
          expectedRevision: status.revision
        )
        Issue.record("replacing barrier advanced twice")
      } catch let error as MuxError { #expect(error.code == .invalidRequest) }
    }
    let paused = status.revision
    switch mode {
    case "deadline":
      try await Task.sleep(for: .milliseconds(400))
      let after = try await updater.admissionStatus()
      #expect(!after.paused && after.phase == nil)
      #expect(after.revision == paused + 1)
      await updater.close()
    default:
      // The updater disappears; its successor binds.
      await updater.close()
      let successor = try await GatewaySupervisor.connect(
        peerRequirement: nil,
        channel: { .connect(endpoint: endpoint, queue: $0) }
      )
      let after = try await successor.admissionStatus()
      if mode == "replacing" {
        // Only an explicit, verified resume ends a replacing barrier.
        #expect(after.paused && after.phase == .replacing)
        #expect(after.revision == paused)
        let resumed = try await successor.setAdmissionPaused(
          false,
          expectedRevision: after.revision
        )
        #expect(!resumed.paused && resumed.phase == nil)
      } else {
        #expect(!after.paused && after.revision == paused + 1)
      }
      await successor.close()
    }
  }

  @Test
  func guardedPreflightRequiresCompatibleRollbackAndFutureWorker() async throws
  {
    let worker = try GuardianBuildRegistryTests.Fixture()
    let candidate = try GatewayUpdateArtifactTests.Fixture()
    let rollback = try GatewayUpdateArtifactTests.Fixture()
    defer {
      worker.remove();
      candidate.remove();
      rollback.remove()
    }
    let registry = try worker.registry()
    let pin = try registry.pin("one")
    let guardian = try GuardianServer(
      launcherPath: launcherPath(),
      peerRequirement: nil
    )
    let control = GuardianGatewayServer(
      guardian: guardian,
      peerRequirement: nil,
      buildRegistry: registry,
      workerMachService: "qualification.unused"
    )
    let endpoint = control.listenAnonymously()
    defer {
      control.close();
      guardian.shutdown {}
    }
    let supervisor = try await GatewaySupervisor.connect(
      peerRequirement: nil,
      channel: { .connect(endpoint: endpoint, queue: $0) }
    )
    let runtime = try await GatewayRuntime.start(
      supervisor: supervisor,
      peerRequirement: nil
    )
    let pause = try await supervisor.setAdmissionPaused(
      true,
      expectedRevision: 0
    )
    try await runtime.preflightPausedUpdate(
      candidate: candidate.validate(),
      rollback: rollback.validate(),
      nextWorker: pin,
      expectedRevision: pause.revision
    )
    var declaration = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: rollback.metadata))
        as? [String: Any]
    )
    declaration["workerProtocols"] = [SMX.protocolVersion + 1]
    try JSONSerialization.data(withJSONObject: declaration)
      .write(to: rollback.metadata)
    try rollback.sign()
    do {
      try await runtime.preflightPausedUpdate(
        candidate: candidate.validate(),
        rollback: rollback.validate(),
        nextWorker: pin,
        expectedRevision: pause.revision
      )
      Issue.record("rollback cannot serve proposed worker")
    } catch let error as MuxError {
      #expect(error.code == .incompatibleVersion)
    }
    #expect(try await supervisor.admissionStatus().paused)
    _ = try await supervisor.setAdmissionPaused(
      false,
      expectedRevision: pause.revision
    )
    do {
      _ = try await supervisor.settledUpdateInventory(
        expectedRevision: pause.revision
      )
      Issue.record("released barrier passed validation")
    } catch let error as MuxError { #expect(error.code == .staleRevision) }
    await runtime.close()
  }
}
