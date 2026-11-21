import CryptoKit
import Dispatch
import Foundation
import SwiftMuxProtocol

/// One planned replacement (spec.durability.md §7). The guardian owns its
/// phase, deadlines and the release decision; the gateway and the workers
/// only acknowledge transitions.
final class Migration {
  let id = UUID()
  let workspace: WorkspaceID
  let gateway: UUID
  var phase = GuardianMigrationPhase.preparing
  /// The old worker's authority when the transaction began.
  let oldAuthority: GuardianAuthority
  /// Allocated at preparation; it owns the workspace only after release.
  let candidateAuthority: GuardianAuthority
  var candidateToken: UUID?
  var candidatePID: Int32 = 0
  var candidateConnection: UUID?
  var candidateWorker: GuardianWorkerProcess?
  var candidateBuild: GuardianBuildPin?
  var deadline: DispatchTime
  var frozenAt: DispatchTime?
  var timer: DispatchSourceTimer?
  var oldFrozen = false
  var exporting = false
  var checkpoint = Data()
  var checkpointTotal: Int?
  var digest: Data?
  var imported = false
  var assigned = false
  var outcome: GuardianMigrationOutcome?
  var failure: MuxError?
  var frozenMilliseconds: Int?
  /// Child exits observed while frozen, for whichever owner is selected.
  var held: [GuardianEvent] = []

  init(
    workspace: WorkspaceID,
    gateway: UUID,
    old: GuardianAuthority,
    candidate: GuardianAuthority,
    deadline: DispatchTime
  ) {
    self.workspace = workspace
    self.gateway = gateway
    oldAuthority = old
    candidateAuthority = candidate
    self.deadline = deadline
  }
}

extension GuardianServer {
  // MARK: Gateway commands

  /// Starts a candidate from the selected build. The old worker keeps
  /// running unchanged; preparation has its own deadline.
  package func beginMigration(
    authority: GuardianAuthority,
    gateway identity: UUID,
    registry: GuardianBuildRegistry?,
    machService: String?
  ) throws -> GuardianMigrationStatus {
    try queue.sync {
      let migration = try prepareMigration(authority, gateway: identity)
      if let registry, let machService {
        launchCandidate(migration, registry: registry, machService: machService)
      }
      return status(migration)
    }
  }

  /// Test and supervisor admission for an already started candidate.
  package func provisionMigrationCandidate(
    transaction: UUID,
    pid: Int32
  ) throws -> UUID {
    try queue.sync {
      guard let migration, migration.id == transaction,
        migration.phase == .preparing, migration.candidateConnection == nil,
        pid > 0
      else { throw MuxError(.invalidRequest, "no candidate slot") }
      let token = UUID()
      migration.candidateToken = token
      migration.candidatePID = pid
      return token
    }
  }

  /// Status without gateway authority (tests).
  package func migrationStatusForTesting(
    _ transaction: UUID
  ) throws -> GuardianMigrationStatus {
    try queue.sync { try migrationStatusLocked(transaction) }
  }

  /// Accepted input the guardian has not yet written to the workspace's
  /// terminals (tests).
  package func pendingInputBytesForTesting(_ id: WorkspaceID) -> Int {
    queue.sync {
      workspaces[id]?.panes.values
        .reduce(0) { $0 + $1.runtime.pendingInputBytes } ?? 0
    }
  }

  /// Replies the guardian holds for the workspace's terminals (tests).
  package func pendingReplyBytesForTesting(_ id: WorkspaceID) -> Int {
    queue.sync {
      workspaces[id]?.panes.values
        .reduce(0) { $0 + $1.runtime.pendingReplyBytes } ?? 0
    }
  }

  /// Test-only convenience: begin without launching a process.
  package func beginMigrationForTesting(
    authority: GuardianAuthority,
    gateway identity: UUID
  ) throws -> GuardianMigrationStatus {
    try queue.sync {
      status(try prepareMigration(authority, gateway: identity))
    }
  }

  private func prepareMigration(
    _ authority: GuardianAuthority,
    gateway identity: UUID
  ) throws -> Migration {
    dispatchPrecondition(condition: .onQueue(queue))
    guard !stopping, gateway == identity else {
      throw MuxError(.staleAttachment, "gateway is no longer current")
    }
    guard migration == nil else {
      throw MuxError(.quiescing, "another migration is in progress")
    }
    guard let workspace = workspaces[authority.workspace],
      workspace.authority == authority, workspace.connection != nil,
      !workspace.unavailable, !workspace.ending
    else { throw MuxError(.staleAttachment, "workspace is not migratable") }
    guard finishedMigrations.count < 64 else {
      throw MuxError(.resourceLimit, "acknowledge finished migrations first")
    }
    // Peak-memory admission before anything starts (§7.2 step 1, MR7).
    let required = migrationMemory.required(for: workspace.expectedPID)
    let available = migrationMemory.available()
    guard available >= required else {
      throw MuxError(
        .resourceLimit,
        "insufficient memory for planned replacement: need \(required >> 20) MiB, \(available >> 20) MiB available"
      )
    }
    let candidate = try allocateAuthority(authority.workspace)
    let value = Migration(
      workspace: authority.workspace,
      gateway: identity,
      old: authority,
      candidate: candidate,
      deadline: .now() + migrationPreparationTimeout
    )
    migration = value
    armMigrationDeadline(value)
    return value
  }

  private func launchCandidate(
    _ migration: Migration,
    registry: GuardianBuildRegistry,
    machService: String
  ) {
    dispatchPrecondition(condition: .onQueue(queue))
    let token = UUID()
    migration.candidateToken = token
    let transaction = migration.id
    let workspaceID = migration.workspace
    DispatchQueue.global(qos: .userInitiated)
      .async { [self] in
        do {
          let build = try registry.pinSelected()
          let bootstrap = GuardianWorkerBootstrap(
            version: GuardianWire.version,
            workspace: workspaceID,
            token: token,
            guardianPID: getpid(),
            machService: machService,
            build: build.build,
            peerRequirement: peerRequirement,
            migration: transaction
          )
          let worker = try GuardianWorkerProcess.spawn(
            executable: build.workerPath,
            arguments: [],
            bootstrap: bootstrap,
            queue: queue
          )
          queue.async { [self] in
            guard let current = self.migration, current.id == transaction,
              current.phase == .preparing
            else {
              worker.terminate()
              return
            }
            current.candidateWorker = worker
            current.candidateBuild = build
            current.candidatePID = worker.pid
            worker.onFinished = { [weak self] in
              self?.candidateLost(transaction, connection: nil)
            }
            do { try worker.activate() } catch {
              abortMigration(
                MuxError(.launchFailed, "candidate bootstrap delivery failed")
              )
            }
          }
        } catch {
          queue.async { [self] in
            guard self.migration?.id == transaction else { return }
            abortMigration(
              (error as? MuxError)
                ?? MuxError(.launchFailed, "candidate launch failed")
            )
          }
        }
      }
  }

  /// Closes admission. From here the guardian runs the frozen phase to a
  /// release or an abort, whether or not the gateway stays connected.
  package func freezeMigration(
    transaction: UUID,
    gateway identity: UUID
  ) throws -> GuardianMigrationStatus {
    try queue.sync {
      guard gateway == identity else {
        throw MuxError(.staleAttachment, "gateway is no longer current")
      }
      // A replayed freeze reports the retained outcome unchanged (MR5).
      if let finished = finishedMigrations[transaction] { return finished }
      guard let migration, migration.id == transaction else {
        throw MuxError(.notFound, "no such migration")
      }
      guard migration.phase == .preparing else { return status(migration) }
      guard migration.candidateConnection != nil else {
        throw MuxError(.quiescing, "candidate is not connected yet")
      }
      guard let workspace = workspaces[migration.workspace],
        workspace.pendingLaunch == nil
      else {
        // A launch in flight prevents a cut (§3.1); stay in preparation.
        throw MuxError(.quiescing, "a pane launch is still settling")
      }
      migration.phase = .frozen
      migration.frozenAt = .now()
      migration.deadline = .now() + migrationFrozenTimeout
      armMigrationDeadline(migration)
      workspace.migrationFrozen = true
      send(.migrationFreeze(transaction: transaction), to: workspace)
      return status(migration)
    }
  }

  package func migrationStatus(
    transaction: UUID,
    gateway identity: UUID
  ) throws -> GuardianMigrationStatus {
    try queue.sync {
      guard gateway == identity else {
        throw MuxError(.staleAttachment, "gateway is no longer current")
      }
      if let migration, migration.id == transaction { return status(migration) }
      guard let finished = finishedMigrations[transaction] else {
        throw MuxError(.notFound, "no such migration")
      }
      return finished
    }
  }

  /// Abandons before release. A released transaction is reported unchanged.
  package func cancelMigration(
    transaction: UUID,
    gateway identity: UUID
  ) throws -> GuardianMigrationStatus {
    try queue.sync {
      guard gateway == identity else {
        throw MuxError(.staleAttachment, "gateway is no longer current")
      }
      if let migration, migration.id == transaction {
        if migration.phase == .preparing || migration.phase == .frozen {
          abortMigration(MuxError(.quiescing, "migration cancelled"))
        }
      }
      return try migrationStatusLocked(transaction)
    }
  }

  package func acknowledgeMigration(
    transaction: UUID,
    gateway identity: UUID
  ) throws -> GuardianMigrationStatus {
    try queue.sync {
      guard gateway == identity else {
        throw MuxError(.staleAttachment, "gateway is no longer current")
      }
      guard let finished = finishedMigrations.removeValue(forKey: transaction)
      else {
        if migration?.id == transaction {
          throw MuxError(.quiescing, "migration has not finished")
        }
        throw MuxError(.notFound, "no such migration")
      }
      return finished
    }
  }

  /// The gateway that began a transaction is gone. Before release that
  /// invalidates the cut (§7.2); after release the candidate continues.
  func gatewayLost(_ identity: UUID) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard let migration, migration.gateway == identity,
      migration.phase == .preparing || migration.phase == .frozen
    else { return }
    abortMigration(MuxError(.connectionLost, "gateway disconnected"))
  }

  private func migrationStatusLocked(
    _ transaction: UUID
  ) throws -> GuardianMigrationStatus {
    if let migration, migration.id == transaction { return status(migration) }
    guard let finished = finishedMigrations[transaction] else {
      throw MuxError(.notFound, "no such migration")
    }
    return finished
  }

  func status(_ migration: Migration) -> GuardianMigrationStatus {
    GuardianMigrationStatus(
      transaction: migration.id,
      workspace: migration.workspace,
      phase: migration.phase,
      outcome: migration.outcome,
      candidateConnected: migration.candidateConnection != nil,
      failure: migration.failure,
      frozenMilliseconds: migration.frozenMilliseconds
    )
  }

  // MARK: Deadlines

  private func armMigrationDeadline(_ migration: Migration) {
    dispatchPrecondition(condition: .onQueue(queue))
    migration.timer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: migration.deadline)
    let transaction = migration.id
    timer.setEventHandler { [weak self] in
      guard let self, let current = self.migration, current.id == transaction,
        current.phase == .preparing || current.phase == .frozen
      else { return }
      self.abortMigration(
        MuxError(
          .quiescing,
          current.phase == .frozen
            ? "frozen interval deadline expired" : "preparation timed out"
        )
      )
    }
    migration.timer = timer
    timer.resume()
  }

  // MARK: Candidate

  func admitCandidate(
    _ id: UUID,
    peer: Peer,
    version: Int,
    workspace: WorkspaceID,
    transaction: UUID,
    token: UUID
  ) {
    guard version == GuardianWire.version, peer.workspace == nil,
      peer.migration == nil, let migration, migration.id == transaction,
      migration.workspace == workspace, migration.phase == .preparing,
      migration.candidateToken == token, migration.candidateConnection == nil,
      migration.candidatePID == peer.channel.peerPID
    else {
      reject(id, MuxError(.unauthorized, "invalid candidate admission"))
      return
    }
    migration.candidateToken = nil
    migration.candidateConnection = id
    peer.migration = transaction
    sendCandidate(
      .migrationWelcome(
        transaction: transaction,
        authority: migration.candidateAuthority
      ),
      migration
    )
  }

  func receiveCandidate(
    _ request: GuardianRequest,
    transaction: UUID,
    from id: UUID
  ) {
    guard let migration, migration.id == transaction,
      migration.candidateConnection == id, migration.phase == .frozen
    else {
      reject(id, MuxError(.unauthorized, "candidate has no authority"))
      return
    }
    switch request {
    case let .migrationImported(value, digest) where value == transaction:
      guard migration.digest == digest, !migration.imported else {
        abortMigration(MuxError(.invalidRequest, "candidate import mismatch"))
        return
      }
      migration.imported = true
      // The candidate generation is assigned; gates stay closed (§7.2).
      migration.assigned = true
      sendCandidate(.migrationActivate(transaction: transaction), migration)
    case let .migrationActivated(value)
    where value == transaction && migration.imported:
      releaseMigration(migration)
    default:
      abortMigration(MuxError(.invalidRequest, "unexpected candidate request"))
    }
  }

  func candidateLost(_ transaction: UUID, connection: UUID?) {
    guard let migration, migration.id == transaction else { return }
    if migration.phase == .preparing || migration.phase == .frozen {
      abortMigration(MuxError(.connectionLost, "candidate lost"))
    }
  }

  private func sendCandidate(_ event: GuardianEvent, _ migration: Migration) {
    guard let id = migration.candidateConnection, let peer = peers[id],
      let bytes = try? JSONEncoder().encode(event),
      bytes.count <= GuardianWire.recordLimit
    else { return }
    peer.channel.send(bytes)
  }

  // MARK: Cut and transfer

  func oldWorkerFrozen(_ transaction: UUID, workspace: Workspace) {
    guard let migration, migration.id == transaction,
      migration.phase == .frozen, !migration.oldFrozen
    else { return }
    migration.oldFrozen = true
    checkMigrationCut(workspace)
  }

  /// The cut exists once the old worker has frozen and applied every
  /// output record the guardian sent (reads are already stopped).
  func checkMigrationCut(_ workspace: Workspace) {
    guard let migration, migration.workspace == workspace.authority.workspace,
      migration.phase == .frozen, migration.oldFrozen, !migration.exporting,
      workspace.panes.values.allSatisfy({ $0.outstanding.isEmpty })
    else { return }
    migration.exporting = true
    send(.migrationExport(transaction: migration.id), to: workspace)
  }

  func receiveCheckpointChunk(
    _ transaction: UUID,
    offset: Int,
    total: Int,
    bytes: Data,
    workspace: Workspace
  ) {
    guard let migration, migration.id == transaction,
      migration.phase == .frozen, migration.exporting
    else { return }
    guard total > 0, total <= GuardianMigrationWire.checkpointLimit,
      migration.checkpointTotal.map({ $0 == total }) ?? true,
      offset == migration.checkpoint.count,
      bytes.count <= GuardianMigrationWire.chunkBytes,
      offset + bytes.count <= total
    else {
      abortMigration(MuxError(.invalidRequest, "invalid checkpoint transfer"))
      return
    }
    migration.checkpointTotal = total
    migration.checkpoint.append(bytes)
    guard migration.checkpoint.count == total else { return }
    migration.digest = Data(SHA256.hash(data: migration.checkpoint))
    // Forward to the candidate in the same bounded chunks.
    var start = 0
    while start < total {
      let end = min(total, start + GuardianMigrationWire.chunkBytes)
      sendCandidate(
        .migrationImport(
          transaction: transaction,
          offset: start,
          total: total,
          bytes: migration.checkpoint.subdata(in: start ..< end)
        ),
        migration
      )
      start = end
    }
  }

  // MARK: Release and abort

  /// The one irreversible decision (§7.1). Rechecks the absolute deadline
  /// and the old worker before opening the candidate's gates.
  private func releaseMigration(_ migration: Migration) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard migration.phase == .frozen, migration.assigned,
      DispatchTime.now() < migration.deadline,
      let workspace = workspaces[migration.workspace], !workspace.unavailable,
      !workspace.ending, let candidate = migration.candidateConnection,
      peers[candidate] != nil
    else {
      abortMigration(MuxError(.quiescing, "release prerequisites not met"))
      return
    }
    migration.phase = .released
    migration.timer?.cancel()
    migration.timer = nil
    let old = workspace.connection
    let oldWorker = workspace.worker
    // The old worker leaves with no authority over any process.
    if let old, let peer = peers[old] {
      if let bytes = try? JSONEncoder()
        .encode(GuardianEvent.migrationRetire(transaction: migration.id))
      {
        peer.channel.send(bytes)
      }
      peer.workspace = nil
    }
    workspace.progressTimer?.cancel()
    workspace.progressTimer = nil
    workspace.progressProbe = nil
    // The candidate owns the workspace: new authority, its own command
    // sequence, its own endpoint once it publishes one.
    workspace.previousAuthority = nil
    replaceAuthority(workspace, with: migration.candidateAuthority)
    workspace.connection = candidate
    workspace.expectedPID = migration.candidatePID
    peers[candidate]?.workspace = migration.workspace
    peers[candidate]?.migration = nil
    workspace.worker = migration.candidateWorker
    if let build = migration.candidateBuild { workspace.buildPin = build }
    workspace.serviceEndpoint = nil
    workspace.observesGateway = false
    workspace.inFlightGatewayRevision = nil
    resultBytes -= workspace.resultBytes
    workspace.resultBytes = 0
    workspace.results.removeAll()
    workspace.nextCommand = 1
    workspace.retired = 0
    if let worker = migration.candidateWorker {
      let id = migration.workspace
      worker.onFinished = { [weak self, weak worker] in
        guard let self, let worker, let workspace = self.workspaces[id],
          workspace.worker === worker
        else { return }
        self.loseWorker(
          workspace,
          MuxError(.connectionLost, "replacement worker exited")
        )
        self.checkStopped()
      }
    }
    sendCandidate(.migrationReleased(transaction: migration.id), migration)
    workspace.migrationFrozen = false
    for event in migration.held { send(event, to: workspace) }
    migration.held.removeAll()
    startProgressWatchdog(workspace)
    for pane in workspace.panes.values { pane.runtime.flush() }
    finishMigration(migration, outcome: .released)
    // The old process exits on retire; never signal its shells.
    // Retained for the grace period: dropping the last reference would kill
    // it at once instead of letting it exit on retire and be reaped.
    if let oldWorker {
      queue.asyncAfter(deadline: .now() + 5) { oldWorker.terminate() }
    }
  }

  /// Before release: fence the candidate and resume the old worker under a
  /// fresh generation. An old worker that is gone leaves the workspace
  /// unavailable; nothing is promoted (§7.3).
  func abortMigration(_ error: MuxError, oldWorkerLost: Bool = false) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard let migration else { return }
    if migration.phase == .aborting {
      // Waiting for resumption: End or old-worker loss settles it now.
      if let workspace = workspaces[migration.workspace], workspace.ending {
        finishMigration(migration, outcome: .ended)
      } else if oldWorkerLost {
        finishMigration(migration, outcome: .unavailable)
      }
      return
    }
    guard migration.phase == .preparing || migration.phase == .frozen else {
      return
    }
    migration.failure = error
    migration.timer?.cancel()
    migration.timer = nil
    if let candidate = migration.candidateConnection,
      let peer = peers.removeValue(forKey: candidate)
    {
      if let bytes = try? JSONEncoder().encode(GuardianEvent.refused(error)) {
        peer.channel.send(bytes)
      }
      peer.channel.cancel()
    }
    migration.candidateWorker?.terminate()
    migration.candidateConnection = nil
    guard let workspace = workspaces[migration.workspace] else {
      finishMigration(migration, outcome: .unavailable)
      return
    }
    let wasFrozen = workspace.migrationFrozen
    workspace.migrationFrozen = false
    if workspace.ending {
      // End is the one disposition; held exits are moot.
      migration.held.removeAll()
      finishMigration(migration, outcome: .ended)
      return
    }
    if oldWorkerLost || workspace.unavailable {
      migration.held.removeAll()
      finishMigration(migration, outcome: .unavailable)
      return
    }
    if wasFrozen {
      // Fresh authority fences gateway grants and routes taken before the
      // cut; the old worker's own in-flight records remain acceptable.
      if let fresh = try? allocateAuthority(migration.workspace) {
        workspace.previousAuthority = workspace.authority
        replaceAuthority(workspace, with: fresh)
      }
      send(
        .migrationAborted(
          transaction: migration.id,
          authority: workspace.authority
        ),
        to: workspace
      )
      for event in migration.held { send(event, to: workspace) }
      migration.held.removeAll()
      for pane in workspace.panes.values { pane.runtime.flush() }
      // Resumption is acknowledged, never assumed (§7.3).
      migration.phase = .aborting
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now() + migrationResumeTimeout)
      let transaction = migration.id
      timer.setEventHandler { [weak self] in
        guard let self, let current = self.migration, current.id == transaction,
          current.phase == .aborting
        else { return }
        self.finishMigration(current, outcome: .unavailable)
        if let workspace = self.workspaces[current.workspace] {
          self.loseWorker(
            workspace,
            MuxError(.connectionLost, "old worker did not resume")
          )
        }
      }
      migration.timer = timer
      timer.resume()
      return
    }
    finishMigration(migration, outcome: .resumed)
  }

  func oldWorkerResumed(_ transaction: UUID) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard let migration, migration.id == transaction,
      migration.phase == .aborting
    else { return }
    finishMigration(migration, outcome: .resumed)
  }

  /// Release or abort: the workspace's owner generation changes.
  private func replaceAuthority(
    _ workspace: Workspace,
    with authority: GuardianAuthority
  ) {
    workspace.authority = authority
    // A resumed worker keeps its endpoint under the fresh authority; a
    // released candidate publishes its own.
    if let endpoint = workspace.serviceEndpoint {
      workspace.serviceEndpoint = GuardianWorkerEndpoint(
        authority: authority,
        instance: endpoint.instance,
        pid: endpoint.pid,
        endpoint: endpoint.endpoint
      )
    }
    // Later gateway bindings carry this authority; the worker learns it from
    // `migrationAborted` or its release before any arrives.
  }

  private func finishMigration(
    _ migration: Migration,
    outcome: GuardianMigrationOutcome
  ) {
    if let frozenAt = migration.frozenAt {
      let elapsed =
        DispatchTime.now().uptimeNanoseconds - frozenAt.uptimeNanoseconds
      migration.frozenMilliseconds = Int(elapsed / 1_000_000)
    }
    migration.timer?.cancel()
    migration.timer = nil
    migration.outcome = outcome
    migration.phase = .finished
    migration.checkpoint = Data()
    finishedMigrations[migration.id] = status(migration)
    if self.migration === migration { self.migration = nil }
  }
}
