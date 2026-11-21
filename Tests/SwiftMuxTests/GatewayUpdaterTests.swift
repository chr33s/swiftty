import Darwin
import Foundation
import SwiftMuxGateway
@testable import SwiftMuxGuardian
import SwiftMuxProtocol
import SwiftMuxXPC
import Synchronization
import Testing

/// The ordinary update across two gateways (spec.durability.md §5.2, UA4):
/// final compatibility under the barrier, a `replacing` pause that survives
/// gateway loss, verified completion, rollback and stale-resume rejection.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct GatewayUpdaterTests {
  typealias Builds = GuardianBuildRegistryTests.Fixture
  typealias Artifact = GatewayUpdateArtifactTests.Fixture

  final class Installer: GatewayReplacement, @unchecked Sendable {
    let installed = Mutex<[String]>([])
    func install(_ build: String) async throws {
      installed.withLock { $0.append(build) }
    }
  }

  final class Rig: @unchecked Sendable {
    let builds: Builds
    let artifact: Artifact
    let registry: GuardianBuildRegistry
    let guardian: GuardianServer
    let control: GuardianGatewayServer
    let endpoint: SMXEndpoint
    let plans: GatewayUpdatePlanStore
    let installer = Installer()
    let workspace = WorkspaceID()

    init(settlement: TimeInterval = 30) throws {
      builds = try Builds()
      artifact = try Artifact()
      registry = try builds.registry()
      try registry.select("one")
      guardian = try GuardianServer(
        launcherPath: launcherPath(),
        peerRequirement: nil,
        admissionSettlementTimeout: settlement
      )
      control = GuardianGatewayServer(
        guardian: guardian,
        peerRequirement: nil,
        buildRegistry: registry,
        workerMachService: "qualification.unused"
      )
      endpoint = control.listenAnonymously()
      plans = GatewayUpdatePlanStore(
        root: builds.root.appendingPathComponent("gateway")
      )
    }

    /// A gateway: a fresh guardian connection, which replaces the previous
    /// gateway's identity.
    func gateway() async throws -> (GatewaySupervisor, GatewayUpdater) {
      let endpoint = endpoint
      let supervisor = try await GatewaySupervisor.connect(
        peerRequirement: nil,
        expectedGuardianPID: getpid(),
        channel: { .connect(endpoint: endpoint, queue: $0) }
      )
      return (
        supervisor,
        GatewayUpdater(
          supervisor: supervisor,
          plans: plans,
          replacement: installer,
          settlement: .seconds(5)
        )
      )
    }

    /// A live workspace pinned to build one; its worker exits at once, so
    /// the guardian retains it with the build's protocol metadata.
    func liveWorkspace(_ supervisor: GatewaySupervisor) async throws {
      _ = try await supervisor.create(workspace)
      let deadline = ContinuousClock.now + .seconds(5)
      while guardian.inventory().contains(where: { $0.starting }) {
        guard ContinuousClock.now < deadline else {
          throw MuxError(.connectionLost, "creation did not settle")
        }
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(guardian.inventory().first?.workerProtocol == SMX.protocolVersion)
    }

    func close() {
      control.close()
      let stopped = DispatchSemaphore(value: 0)
      guardian.shutdown { stopped.signal() }
      _ = stopped.wait(timeout: .now() + 5)
      artifact.remove()
      builds.remove()
    }
  }

  private static let protocols = Set(SMX.compatibleVersions)

  @Test
  func theSuccessorVerifiesSelectsTheNewWorkerAndResumes() async throws {
    let rig = try Rig()
    defer { rig.close() }
    let (old, updater) = try await rig.gateway()
    try await rig.liveWorkspace(old)
    let outcome = try await updater.install(
      candidate: rig.artifact.validate(),
      currentBuild: "current-1",
      currentProtocols: Self.protocols,
      worker: (build: "two", protocol: SMX.protocolVersion)
    )
    guard case let .handedOver(plan) = outcome else {
      Issue.record("not handed over: \(outcome)")
      return
    }
    #expect(rig.installer.installed.withLock { $0 } == ["candidate-1"])
    #expect(try rig.plans.load() == plan)
    // The old gateway is gone; `replacing` survives without it.
    await old.close()
    let (next, successor) = try await rig.gateway()
    let paused = try await next.admissionStatus()
    #expect(paused.paused && paused.phase == .replacing)
    let finished = try await successor.complete(
      ownBuild: "candidate-1",
      ownProtocols: Self.protocols
    )
    #expect(finished == .completed(plan))
    let status = try await next.admissionStatus()
    #expect(!status.paused)
    // Stale resume from before completion has no effect.
    await #expect(throws: MuxError.self) {
      _ = try await next.setAdmissionPaused(
        false,
        expectedRevision: paused.revision
      )
    }
    let selection = try await next.workerSelection()
    #expect(selection.selected == "two" && selection.rollback == "one")
    #expect(try rig.plans.load() == nil)
    // The live workspace keeps build one pinned.
    #expect(throws: MuxError.self) { try rig.registry.remove("one") }
    #expect(rig.guardian.inventory().first?.worker?.build == "one")
    await next.close()
  }

  @Test
  func anIncompatibleUpdateIsDeferredWithSelectionsUnchanged() async throws {
    let rig = try Rig()
    defer { rig.close() }
    let (gateway, updater) = try await rig.gateway()
    try await rig.liveWorkspace(gateway)
    let before = try await gateway.admissionStatus()
    let outcome = try await updater.install(
      candidate: rig.artifact.validate(),
      currentBuild: "current-1",
      currentProtocols: Self.protocols,
      // A worker protocol neither gateway serves.
      worker: (build: "two", protocol: 99)
    )
    guard case let .deferred(error) = outcome else {
      Issue.record("incompatible update was not deferred: \(outcome)")
      return
    }
    #expect(error.code == .incompatibleVersion)
    let after = try await gateway.admissionStatus()
    #expect(!after.paused && after.revision > before.revision)
    #expect(try await gateway.workerSelection().selected == "one")
    #expect(rig.installer.installed.withLock { $0 }.isEmpty)
    #expect(try rig.plans.load() == nil)
    await gateway.close()
  }

  @Test
  func liveWorkspacesTheCandidateCannotServeDeferTheUpdate() async throws {
    let rig = try Rig()
    defer { rig.close() }
    let (gateway, updater) = try await rig.gateway()
    try await rig.liveWorkspace(gateway)
    // The candidate drops the live workspace's worker protocol.
    var declaration = try #require(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: rig.artifact.metadata)
      ) as? [String: Any]
    )
    declaration["workerProtocols"] = [SMX.protocolVersion + 50]
    try JSONSerialization.data(withJSONObject: declaration)
      .write(to: rig.artifact.metadata)
    try rig.artifact.sign()
    let outcome = try await updater.install(
      candidate: rig.artifact.validate(),
      currentBuild: "current-1",
      currentProtocols: Self.protocols,
      worker: nil
    )
    guard case let .deferred(error) = outcome else {
      Issue.record("unservable live workspace did not defer: \(outcome)")
      return
    }
    #expect(error.code == .incompatibleVersion)
    #expect(!(try await gateway.admissionStatus().paused))
    await gateway.close()
  }

  @Test
  func aSuccessorThatFailsVerificationRestoresTheRollbackGateway() async throws
  {
    let rig = try Rig()
    defer { rig.close() }
    let (old, updater) = try await rig.gateway()
    try await rig.liveWorkspace(old)
    _ = try await updater.install(
      candidate: rig.artifact.validate(),
      currentBuild: "current-1",
      currentProtocols: Self.protocols,
      worker: (build: "two", protocol: SMX.protocolVersion)
    )
    await old.close()
    // The installed candidate cannot serve the live workspace after all.
    let (bad, candidate) = try await rig.gateway()
    await #expect(throws: MuxError.self) {
      _ = try await candidate.complete(
        ownBuild: "candidate-1",
        ownProtocols: [SMX.protocolVersion + 50]
      )
    }
    #expect(
      rig.installer.installed.withLock { $0 } == ["candidate-1", "current-1"]
    )
    #expect(try rig.plans.load()?.state == .rollingBack)
    #expect(try await bad.admissionStatus().paused)
    await bad.close()
    // The restored gateway resumes with the prior selection.
    let (restored, rollback) = try await rig.gateway()
    let outcome = try await rollback.complete(
      ownBuild: "current-1",
      ownProtocols: Self.protocols
    )
    guard case .rolledBack = outcome else {
      Issue.record("rollback gateway did not finish: \(outcome)")
      return
    }
    #expect(!(try await restored.admissionStatus().paused))
    #expect(try await restored.workerSelection().selected == "one")
    #expect(try rig.plans.load() == nil)
    await restored.close()
  }

  @Test
  func anUnrelatedGatewayLeavesTheReplacingBarrierAlone() async throws {
    let rig = try Rig()
    defer { rig.close() }
    let (old, updater) = try await rig.gateway()
    try await rig.liveWorkspace(old)
    _ = try await updater.install(
      candidate: rig.artifact.validate(),
      currentBuild: "current-1",
      currentProtocols: Self.protocols,
      worker: nil
    )
    await old.close()
    let (other, stranger) = try await rig.gateway()
    await #expect(throws: MuxError.self) {
      _ = try await stranger.complete(
        ownBuild: "something-else",
        ownProtocols: Self.protocols
      )
    }
    #expect(try await other.admissionStatus().paused)
    await other.close()
  }

  @Test
  func aSettlingPauseResumesWhenItsUpdaterIsLost() async throws {
    let rig = try Rig(settlement: 0.3)
    defer { rig.close() }
    let (old, _) = try await rig.gateway()
    let status = try await old.admissionStatus()
    let paused = try await old.setAdmissionPaused(
      true,
      expectedRevision: status.revision
    )
    #expect(paused.phase == .settling)
    await old.close()
    let (next, successor) = try await rig.gateway()
    // A gateway binding during `settling` did not start that update.
    let deadline = ContinuousClock.now + .seconds(5)
    while try await next.admissionStatus().paused {
      guard ContinuousClock.now < deadline else {
        Issue.record("settling pause was never resumed")
        break
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(
      try await successor.complete(
        ownBuild: "candidate-1",
        ownProtocols: Self.protocols
      ) == .idle
    )
    await next.close()
  }
}
