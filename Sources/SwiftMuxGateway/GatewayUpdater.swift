import Darwin
import Foundation
import SwiftMuxGuardian
import SwiftMuxProtocol

/// What the updater replaces and what it selects once the new gateway runs
/// (spec.durability.md §5.2). Persisted owner-only between the two gateway
/// processes; it is installation state, never session authority.
package struct GatewayUpdatePlan: Codable, Sendable, Equatable {
  package enum State: String, Codable, Sendable {
    /// The candidate gateway is being installed; it finishes the update.
    case replacing
    /// The candidate failed verification; the rollback gateway finishes.
    case rollingBack
  }

  package static let schema = 1

  package var schema: Int
  package var id: UUID
  package var state: State
  /// The gateway being installed and the one it replaces.
  package var gatewayBuild: String
  package var rollbackGatewayBuild: String
  /// The worker build to select for future workspaces, if any.
  package var workerBuild: String?
  /// The selection before the update, restored on rollback.
  package var priorWorkerBuild: String?

  package init(
    gatewayBuild: String,
    rollbackGatewayBuild: String,
    workerBuild: String?,
    priorWorkerBuild: String?
  ) {
    schema = Self.schema
    id = UUID()
    state = .replacing
    self.gatewayBuild = gatewayBuild
    self.rollbackGatewayBuild = rollbackGatewayBuild
    self.workerBuild = workerBuild
    self.priorWorkerBuild = priorWorkerBuild
  }
}

/// One owner-private plan file, written atomically.
package struct GatewayUpdatePlanStore: Sendable {
  package let file: URL

  package init(root: URL) {
    file = root.appendingPathComponent("gateway-update.json")
  }

  package func load() throws -> GatewayUpdatePlan? {
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      (attributes[.posixPermissions] as? Int).map({ $0 & 0o077 == 0 }) == true,
      (attributes[.size] as? Int).map({ $0 <= 16 << 10 }) == true
    else { throw MuxError(.invalidRequest, "unsafe update plan") }
    let plan = try JSONDecoder()
      .decode(GatewayUpdatePlan.self, from: Data(contentsOf: file))
    guard plan.schema == GatewayUpdatePlan.schema,
      GatewayUpdateArtifact.isBuildIdentifier(plan.gatewayBuild),
      GatewayUpdateArtifact.isBuildIdentifier(plan.rollbackGatewayBuild)
    else { throw MuxError(.invalidRequest, "unsupported update plan") }
    return plan
  }

  package func save(_ plan: GatewayUpdatePlan) throws {
    let directory = file.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try AtomicFile.write(try JSONEncoder().encode(plan), to: file)
  }

  package func remove() { unlink(file.path) }

  /// The plan, or nil when there is none or it cannot be read; an
  /// unreadable plan is renamed aside for diagnosis.
  package func loadOrSetAside() -> GatewayUpdatePlan? {
    do { return try load() } catch {
      let aside = file.deletingLastPathComponent()
        .appendingPathComponent("gateway-update.unreadable.json")
      unlink(aside.path)
      rename(file.path, aside.path)
      return nil
    }
  }
}

/// The build this gateway runs, from its sealed declaration
/// (`Contents/Resources/gateway-build.json`); nil outside a staged bundle.
package func runningGatewayBuild(
  bundle: Bundle = .main
) -> GatewayUpdateArtifact.Manifest? {
  guard
    let url = bundle.url(forResource: "gateway-build", withExtension: "json"),
    let data = try? Data(contentsOf: url), data.count <= 64 << 10
  else { return nil }
  return try? JSONDecoder()
    .decode(GatewayUpdateArtifact.Manifest.self, from: data)
}

/// Rollback needs the installer that registered this agent. Until it is
/// present, a failed verification leaves admission paused for it.
package struct InstallerRequiredReplacement: GatewayReplacement {
  package init() {}
  package func install(_ build: String) async throws {
    throw MuxError(
      .incompatibleVersion,
      "gateway \(build) must be restored by the installer"
    )
  }
}

/// Installs the gateway build an update names. Production unregisters the
/// running agent and registers the staged bundle, which ends this process;
/// the successor finishes with `GatewayUpdater.complete`.
package protocol GatewayReplacement: Sendable {
  func install(_ build: String) async throws
}

/// The ordinary update (spec.durability.md §5.2) over the guardian's one
/// admission barrier. It spans two gateways: this one pauses, settles,
/// checks compatibility under the barrier and hands over; the next one
/// verifies itself and resumes, or restores the rollback gateway.
package actor GatewayUpdater {
  package enum Outcome: Sendable, Equatable {
    /// Replacement handed to the installer; the successor finishes.
    case handedOver(GatewayUpdatePlan)
    /// Incompatible or unsettled: selections unchanged, admission resumed.
    case deferred(MuxError)
    /// The successor verified itself, selected the worker build, resumed.
    case completed(GatewayUpdatePlan)
    /// The rollback gateway restored the prior selection and resumed.
    case rolledBack(GatewayUpdatePlan)
    /// Admission was paused for replacement with no plan; this compatible
    /// gateway resumed with unchanged selections.
    case resumedWithoutPlan
    /// Nothing to finish.
    case idle
  }

  private let supervisor: GatewaySupervisor
  private let plans: GatewayUpdatePlanStore
  private let replacement: any GatewayReplacement
  private let settlement: Duration

  package init(
    supervisor: GatewaySupervisor,
    plans: GatewayUpdatePlanStore,
    replacement: any GatewayReplacement,
    settlement: Duration = .seconds(30)
  ) {
    self.supervisor = supervisor
    self.plans = plans
    self.replacement = replacement
    self.settlement = settlement
  }

  // MARK: Old gateway (steps 2–4)

  /// `currentBuild` is this gateway and the rollback; `currentProtocols`
  /// the worker protocols it serves. `worker` names the build to select
  /// afterwards and its protocol.
  package func install(
    candidate: GatewayUpdateArtifact,
    currentBuild: String,
    currentProtocols: Set<Int>,
    worker: (build: String, protocol: Int)?
  ) async throws -> Outcome {
    guard try plans.load() == nil else {
      throw MuxError(.quiescing, "another update is in progress")
    }
    let before = try await supervisor.admissionStatus()
    guard !before.paused else {
      throw MuxError(.quiescing, "worker admission is already paused")
    }
    let paused = try await supervisor.setAdmissionPaused(
      true,
      expectedRevision: before.revision
    )
    // From here every failure resumes the barrier this updater owns.
    do {
      return try await installPaused(
        candidate: candidate,
        currentBuild: currentBuild,
        currentProtocols: currentProtocols,
        worker: worker,
        paused: paused
      )
    } catch {
      let failure =
        error as? MuxError
        ?? MuxError(.invalidRequest, "update failed: \(error)")
      return try await deferUpdate(failure, revision: paused.revision)
    }
  }

  private func installPaused(
    candidate: GatewayUpdateArtifact,
    currentBuild: String,
    currentProtocols: Set<Int>,
    worker: (build: String, protocol: Int)?,
    paused: GuardianAdmissionStatus
  ) async throws -> Outcome {
    let priorWorker = try await retrying {
      try await supervisor.workerSelection()
    }
    .selected
    // Step 2–3: settle, then the final compatibility check under the
    // barrier, against fresh inventory including unavailable workers.
    let inventory: [GuardianWorkspaceInventory]
    do {
      inventory = try await supervisor.settledUpdateInventory(
        expectedRevision: paused.revision,
        timeout: settlement
      )
      try GatewayUpdateCompatibility.validate(
        guardianProtocol: candidate.manifest.guardianProtocol,
        workerProtocols: Set(candidate.manifest.workerProtocols),
        inventory: inventory
      )
      if let worker {
        // Both the candidate and the retained rollback gateway must serve
        // workspaces the new selection will create.
        guard candidate.manifest.workerProtocols.contains(worker.protocol),
          currentProtocols.contains(worker.protocol)
        else {
          throw MuxError(
            .incompatibleVersion,
            "worker build \(worker.build) needs protocol \(worker.protocol)"
          )
        }
      }
    } catch let error as MuxError {
      return try await deferUpdate(error, revision: paused.revision)
    }
    // Step 4: record the plan, enter `replacing`, hand over.
    let plan = GatewayUpdatePlan(
      gatewayBuild: candidate.manifest.build,
      rollbackGatewayBuild: currentBuild,
      workerBuild: worker?.build,
      priorWorkerBuild: priorWorker
    )
    try plans.save(plan)
    do {
      _ = try await supervisor.beginGatewayReplacement(
        expectedRevision: paused.revision
      )
    } catch {
      plans.remove()
      throw error
    }
    // `replacing` now: the successor or the rollback gateway finishes, so a
    // failed hand-over leaves the barrier for them rather than resuming.
    try await replacement.install(plan.gatewayBuild)
    return .handedOver(plan)
  }

  /// The registry answers `quiescing` while it validates a build; retry
  /// such reads briefly instead of failing the update.
  private func retrying<T: Sendable>(
    _ body: () async throws -> T
  ) async throws -> T {
    for _ in 0 ..< 20 {
      do { return try await body() } catch let error as MuxError
        where error.code == .quiescing
      { try await Task.sleep(for: .milliseconds(100)) }
    }
    return try await body()
  }

  private func deferUpdate(
    _ error: MuxError,
    revision: UInt64
  ) async throws -> Outcome {
    // Resume only the barrier this updater owns; a newer change wins.
    let status = try await supervisor.admissionStatus()
    if status.paused, status.revision == revision {
      _ = try await supervisor.setAdmissionPaused(
        false,
        expectedRevision: revision
      )
    }
    return .deferred(error)
  }

  // MARK: Successor (steps 5–6)

  /// Run by every gateway at startup, before it serves frontends. Only a
  /// `replacing` barrier is finished here; `settling` is the guardian's.
  package func complete(
    ownBuild: String,
    ownProtocols: Set<Int>
  ) async throws -> Outcome {
    let status = try await supervisor.admissionStatus()
    // An unreadable plan (damaged, or from a newer release) is set aside:
    // it must never keep a gateway from serving.
    let stored = plans.loadOrSetAside()
    guard status.paused, status.phase == .replacing else {
      // A plan without a replacing barrier is stale: the update was
      // deferred or the guardian restarted.
      if stored != nil { plans.remove() }
      return .idle
    }
    let inventory = try await supervisor.inventory()
    guard var plan = stored else {
      try GatewayUpdateCompatibility.validate(
        guardianProtocol: GuardianWire.version,
        workerProtocols: ownProtocols,
        inventory: inventory
      )
      _ = try await supervisor.setAdmissionPaused(
        false,
        expectedRevision: status.revision
      )
      return .resumedWithoutPlan
    }
    switch (plan.state, ownBuild) {
    case (.replacing, plan.gatewayBuild):
      do {
        try GatewayUpdateCompatibility.validate(
          guardianProtocol: GuardianWire.version,
          workerProtocols: ownProtocols,
          inventory: inventory
        )
        var revision = status.revision
        if let worker = plan.workerBuild {
          revision =
            try await supervisor.selectWorkerBuild(
              worker,
              expectedRevision: revision
            )
            .revision
        }
        _ = try await supervisor.setAdmissionPaused(
          false,
          expectedRevision: revision
        )
        plans.remove()
        return .completed(plan)
      } catch let error as MuxError where error.code != .staleRevision {
        // Verification failed: restore the gateway the plan retained. The
        // barrier stays paused for it.
        plan.state = .rollingBack
        try plans.save(plan)
        try await replacement.install(plan.rollbackGatewayBuild)
        throw error
      }
    case (_, plan.rollbackGatewayBuild):
      // The candidate never verified (or never started): restore the prior
      // worker selection, then resume.
      var revision = status.revision
      let current = try await retrying {
        try await supervisor.workerSelection()
      }
      .selected
      if let prior = plan.priorWorkerBuild, current != prior {
        revision =
          try await supervisor.selectWorkerBuild(
            prior,
            expectedRevision: revision
          )
          .revision
      }
      _ = try await supervisor.setAdmissionPaused(
        false,
        expectedRevision: revision
      )
      plans.remove()
      return .rolledBack(plan)
    default:
      throw MuxError(
        .incompatibleVersion,
        "gateway \(ownBuild) is not part of update \(plan.id)"
      )
    }
  }
}
