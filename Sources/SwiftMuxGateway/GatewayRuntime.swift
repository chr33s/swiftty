import Foundation
import SwiftMuxClient
import SwiftMuxGuardian
import SwiftMuxProtocol
import SwiftMuxXPC

/// Owns a guardian connection, continuous discovery and bounded native routes.
/// Shutdown releases gateway resources; only explicit End terminates sessions.
package actor GatewayRuntime {
  private let supervisor: GatewaySupervisor
  private let directory: GatewayWorkspaceDirectory
  private let routes: GatewayNativeRoutes
  private let creator: GatewayWorkspaceCreator
  /// Saved layouts (spec.durability.md §12.2); nil disables them.
  private let saved: SavedLayoutService?
  private let peerRequirement: String?
  private var monitor: Task<Void, Never>?
  private var closed = false
  package private(set) var failure: MuxError?

  private init(
    supervisor: GatewaySupervisor,
    directory: GatewayWorkspaceDirectory,
    routes: GatewayNativeRoutes,
    creator: GatewayWorkspaceCreator,
    saved: SavedLayoutService?,
    peerRequirement: String?
  ) {
    self.supervisor = supervisor
    self.directory = directory
    self.routes = routes
    self.creator = creator
    self.saved = saved
    self.peerRequirement = peerRequirement
  }

  /// Takes ownership of the supervisor. Initial inventory must succeed; worker
  /// graphs may still be discovering when this returns. Never creates a shell.
  package static func start(
    supervisor: GatewaySupervisor,
    peerRequirement: String?,
    capacity: Int = 32,
    connectionLimit: Int = 64,
    pollInterval: Duration = .seconds(1),
    saved: SavedLayoutService? = nil
  ) async throws -> GatewayRuntime {
    var directory: GatewayWorkspaceDirectory?
    do {
      guard pollInterval > .zero, pollInterval <= .seconds(60) else {
        throw MuxError(.invalidRequest, "invalid gateway polling interval")
      }
      try Task.checkCancellation()
      let discovery = try GatewayWorkspaceDirectory(
        supervisor: supervisor,
        peerRequirement: peerRequirement,
        capacity: capacity
      )
      directory = discovery
      let routes = try GatewayNativeRoutes(
        supervisor: supervisor,
        directory: discovery,
        peerRequirement: peerRequirement,
        capacity: capacity,
        connectionLimit: connectionLimit
      )
      if let saved {
        await saved.start(incarnation: await supervisor.identity?.incarnation)
        await saved.setRetire { authority in
          // A definitively ended worker owns no process; retire it.
          try? await supervisor.endAndForget(authority)
        }
        await discovery.setSavedLayoutHooks(
          state: { authority, state in
            await saved.observe(authority, state: state)
          },
          lost: { id in await saved.workerLost(id) },
          output: { authority, source in
            await saved.setOutputSource(authority, source)
          }
        )
      }
      try await discovery.refresh()
      try Task.checkCancellation()
      let runtime = GatewayRuntime(
        supervisor: supervisor,
        directory: discovery,
        routes: routes,
        creator: GatewayWorkspaceCreator(
          supervisor: supervisor,
          peerRequirement: peerRequirement
        ),
        saved: saved,
        peerRequirement: peerRequirement
      )
      await runtime.startMonitor(interval: pollInterval)
      do { try Task.checkCancellation() } catch {
        await runtime.close()
        throw error
      }
      return runtime
    } catch {
      await directory?.close()
      await supervisor.close()
      throw error
    }
  }

  deinit { monitor?.cancel() }

  package var records: [GatewayWorkspaceDirectory.Record] {
    get async { await directory.records }
  }
  package var nativeRouteCount: Int { get async { await routes.routeCount } }
  package var nativeConnectionCount: Int {
    get async { await routes.connectionCount }
  }
  package var activeObservationCount: Int {
    get async { await directory.activeObservationCount }
  }

  package func preflightUpdate(_ artifact: GatewayUpdateArtifact) async throws {
    guard artifact.manifest.nativeControlProtocol == GatewayControl.version
    else {
      throw MuxError(
        .incompatibleVersion,
        "candidate gateway requires an unsupported native control protocol"
      )
    }
    try await preflightUpdate(
      guardianProtocol: artifact.manifest.guardianProtocol,
      workerProtocols: Set(artifact.manifest.workerProtocols)
    )
  }

  /// Rechecks both the candidate and retained rollback gateway against settled
  /// inventory and the pinned build proposed for future workspaces. The updater
  /// must retain this barrier revision through publication; this is no permit to
  /// change selection or resume admission concurrently.
  package func preflightPausedUpdate(
    candidate: GatewayUpdateArtifact,
    rollback: GatewayUpdateArtifact,
    nextWorker: GuardianBuildPin,
    expectedRevision: UInt64,
    timeout: Duration = .seconds(30)
  ) async throws {
    try checkOpen()
    for artifact in [candidate, rollback] {
      guard artifact.manifest.nativeControlProtocol == GatewayControl.version,
        artifact.manifest.guardianProtocol
          == nextWorker.manifest.guardianProtocol,
        artifact.manifest.workerProtocols.contains(
          nextWorker.manifest.workerProtocol
        )
      else {
        throw MuxError(
          .incompatibleVersion,
          "candidate or rollback gateway cannot support proposed worker selection"
        )
      }
    }
    let inventory = try await supervisor.settledUpdateInventory(
      expectedRevision: expectedRevision,
      timeout: timeout
    )
    try checkOpen()
    for artifact in [candidate, rollback] {
      try GatewayUpdateCompatibility.validate(
        guardianProtocol: artifact.manifest.guardianProtocol,
        workerProtocols: Set(artifact.manifest.workerProtocols),
        inventory: inventory
      )
    }
  }

  /// Fresh guardian inventory includes unavailable/retained workers. This
  /// read-only check cannot authorize installation from a later stale snapshot.
  package func preflightUpdate(
    guardianProtocol: Int,
    workerProtocols: Set<Int>
  ) async throws {
    try checkOpen()
    let inventory = try await supervisor.inventory()
    try checkOpen()
    try Task.checkCancellation()
    try GatewayUpdateCompatibility.validate(
      guardianProtocol: guardianProtocol,
      workerProtocols: workerProtocols,
      inventory: inventory
    )
  }

  /// Observer/status routing does not establish input authority. Controller
  /// routing prepares the gateway grant; worker attachment still enforces leases.
  package func nativeEndpoint(
    for selector: WorkspaceSelector,
    role: AttachmentRole = .observer
  ) async throws -> SMXEndpoint {
    try await nativeRoute(for: selector, role: role).endpoint
  }

  package func nativeRoute(
    for selector: WorkspaceSelector,
    role: AttachmentRole
  ) async throws -> (descriptor: GatewayRouteDescriptor, endpoint: SMXEndpoint)
  {
    try checkOpen()
    let authority = try await directory.nativeAuthority(for: selector)
    if role == .controller { try await supervisor.ensureWriter(authority) }
    let worker = try await supervisor.workerEndpoint(authority)
    try checkOpen()
    let endpoint = try await routes.endpoint(
      for: .id(authority.workspace),
      expectedAuthority: authority
    )
    return (
      GatewayRouteDescriptor(
        workspace: authority.workspace,
        server: worker.instance
      ), endpoint
    )
  }

  /// The guardian incarnation: stable across gateway restarts, new when
  /// the guardian (and with it every session) restarts.
  package var guardianIncarnation: UUID? {
    get async { await supervisor.guardianIncarnation }
  }

  /// A direct SMX connection to `workspace`'s worker for an in-process
  /// frontend of this gateway (the roaming host). `transport` is the
  /// ingress the gateway authenticated, so a `.remote` client gets the
  /// worker's remote restrictions. A controller first gets the gateway's
  /// writer grant; the worker still enforces leases.
  package func connectWorker(
    for workspace: WorkspaceID,
    role: AttachmentRole,
    frontend: FrontendKind,
    transport: LeaseHolder.Transport
  ) async throws -> MuxConnection {
    try checkOpen()
    let authority = try await directory.nativeAuthority(for: .id(workspace))
    if role == .controller { try await supervisor.ensureWriter(authority) }
    try checkOpen()
    return try await supervisor.connectWorker(
      authority,
      peerRequirement: peerRequirement,
      frontend: frontend,
      forwardedTransport: transport
    )
  }

  /// Workspaces with a known summary, most recently known first; a worker
  /// still discovering reports its last summary rather than disappearing.
  package var summaries: [WorkspaceSummary] {
    get async {
      await directory.records.compactMap { record in
        if case let .available(summary) = record.state { return summary }
        return record.lastKnownSummary
      }
    }
  }

  package func createWorkspace(
    _ id: WorkspaceID,
    request: NewWorkspaceRequest,
    timeout: Duration = .seconds(15)
  ) async throws -> GuardianAuthority {
    try checkOpen()
    try checkCreationOpen()
    return try await creator.create(id, request: request, timeout: timeout)
  }

  /// Installer maintenance: no new or reopened workspace may appear between
  /// its empty-state check and taking the agents down.
  package private(set) var maintenance = false

  package func setMaintenance(_ on: Bool) { maintenance = on }

  private func checkCreationOpen() throws {
    guard !maintenance else {
      throw MuxError(.quiescing, "SwiftMux maintenance is in progress")
    }
  }

  /// `disposition` tells the saved-layout store why (§12.2.6). The record
  /// learns it before End, so a crash after End still applies it.
  package func endWorkspace(
    _ selector: WorkspaceSelector,
    disposition: SavedLayoutDisposition = .ended
  ) async throws {
    try checkOpen()
    let record = try await directory.resolve(selector)
    try checkOpen()
    let id = record.inventory.authority.workspace
    await saved?.markEnding(id, disposition: disposition)
    try await supervisor.endAndForget(record.inventory.authority)
    await saved?.didEnd(id, disposition: disposition)
    // The monitor reconciles inventory and routes; no uncertain mutation replay.
  }

  // MARK: Planned replacement (spec.durability.md §7)

  /// Moves a workspace to a new worker of the selected build, preserving its
  /// processes. `started` runs once the transaction exists (a supervisor
  /// that launches candidates itself can ignore it).
  package func migrateWorkspace(
    _ selector: WorkspaceSelector,
    started: (@Sendable (GuardianMigrationStatus) async throws -> Void)? = nil
  ) async throws -> GuardianMigrationStatus {
    try checkOpen()
    let record = try await directory.resolve(selector)
    try checkOpen()
    let workspace = record.inventory.authority.workspace
    await routes.beginMigration(workspace)
    let status: GuardianMigrationStatus
    do {
      status = try await supervisor.migrate(
        record.inventory.authority,
        started: started
      )
    } catch {
      await routes.endMigration(workspace)
      throw error
    }
    // The owner generation changes on release and on an abort from frozen.
    let next = try? await supervisor.inventory()
      .first(where: { $0.authority.workspace == status.workspace })?
      .authority
    switch (status.outcome, next) {
    case let (.released?, next?):
      // Live frontends continue on the candidate instead of reconnecting.
      await routes.migrated(
        workspace,
        from: record.inventory.authority,
        to: next
      )
    case let (.resumed?, next?) where next != record.inventory.authority:
      // The same worker carries on under a fresh authority: re-pin the
      // route; its relays keep their connections.
      await routes.reauthorized(
        workspace,
        from: record.inventory.authority,
        to: next
      )
    default:
      // No owner to follow (unavailable, ended, or inventory unreadable):
      // ordinary pruning decides.
      await routes.endMigration(workspace)
    }
    // Release or abort changed the owner generation: refresh discovery so
    // routes ask for the current authority, not the fenced one.
    for _ in 0 ..< 100 {
      do {
        try await directory.refresh()
        break
      } catch let error as MuxError where error.code == .quiescing {
        try await Task.sleep(for: .milliseconds(10))
      }
    }
    return status
  }

  /// Fresh guardian inventory, so retained and unavailable workspaces count.
  package func installationStatus() async throws -> GatewayInstallationStatus {
    try checkOpen()
    let inventory = try await supervisor.inventory()
    guard let incarnation = await supervisor.guardianIncarnation else {
      throw MuxError(.notAttached, "guardian identity unknown")
    }
    let admission = try? await supervisor.admissionStatus()
    return GatewayInstallationStatus(
      guardianIncarnation: incarnation,
      workspaces: inventory.count,
      updatePending: admission.map { $0.paused && $0.phase == .replacing }
    )
  }

  package typealias UpdateHandler =
    @Sendable (GatewayUpdateRequest) async throws -> GatewayUpdateResult
  private var updateHandler: UpdateHandler?

  /// The daemon supplies how it validates candidates and owns update plans.
  package func setUpdateHandler(_ handler: UpdateHandler?) {
    updateHandler = handler
  }

  package func prepareUpdate(
    _ request: GatewayUpdateRequest
  ) async throws -> GatewayUpdateResult {
    try checkOpen()
    guard let updateHandler else {
      throw MuxError(
        .incompatibleVersion,
        "this gateway cannot prepare updates"
      )
    }
    return try await updateHandler(request)
  }

  /// After an update selects a new worker build (spec.durability.md §5.2):
  /// move live workspaces still on older builds, one at a time. A refusal
  /// or rollback is a deferred upgrade for that workspace, never a failed
  /// update; the rest continue.
  /// How long a post-update upgrade waits for discovery to finish.
  package var upgradeDiscoveryLimit: Duration = .seconds(120)

  package func upgradeWorkspaces(
    to build: String,
    started: (@Sendable (GuardianMigrationStatus) async throws -> Void)? = nil
  ) async -> [WorkspaceID: Result<GuardianMigrationOutcome, MuxError>] {
    var results: [WorkspaceID: Result<GuardianMigrationOutcome, MuxError>] = [:]
    // Discovery may still be opening workspaces at startup: keep scanning
    // until none is starting or discovering, each workspace tried once.
    let deadline = ContinuousClock.now + upgradeDiscoveryLimit
    while failure == nil {
      let records = await directory.records
      let candidates = records.filter { record in
        guard case .available = record.state,
          results[record.inventory.authority.workspace] == nil
        else { return false }
        return record.inventory.worker?.build != build
      }
      for record in candidates {
        let id = record.inventory.authority.workspace
        guard failure == nil else { break }
        do {
          let status = try await migrateWorkspace(.id(id), started: started)
          results[id] = .success(status.outcome ?? .unavailable)
        } catch {
          results[id] = .failure(
            error as? MuxError ?? MuxError(.invalidRequest, "\(error)")
          )
        }
      }
      let settling = records.contains { record in
        switch record.state {
        case .starting, .discovering: true
        default: false
        }
      }
      guard settling || !candidates.isEmpty, ContinuousClock.now < deadline
      else { break }
      try? await Task.sleep(for: .milliseconds(200))
    }
    return results
  }

  // MARK: Saved layouts

  private func savedService() throws -> SavedLayoutService {
    guard let saved else {
      throw MuxError(.notFound, "saved layouts are not configured")
    }
    return saved
  }

  private func savedInventory() async -> SavedLayoutInventory {
    await Self.savedInventory(directory: directory, supervisor: supervisor)
  }

  private static func savedInventory(
    directory: GatewayWorkspaceDirectory,
    supervisor: GatewaySupervisor
  ) async -> SavedLayoutInventory {
    var workspaces: [WorkspaceID: SavedLayoutInventoryState] = [:]
    for record in await directory.records {
      let state: SavedLayoutInventoryState =
        switch record.state {
        case .available: record.graph.map { .live(name: $0.name) } ?? .empty
        case .empty: .empty
        case .unavailable: .unavailable
        case .starting, .discovering: .pending
        }
      workspaces[record.inventory.authority.workspace] = state
    }
    return SavedLayoutInventory(
      incarnation: await supervisor.identity?.incarnation,
      workspaces: workspaces
    )
  }

  package func savedWorkspaces() async throws -> SavedWorkspaceList {
    try checkOpen()
    let saved = try savedService()
    return await saved.list(await savedInventory(), markOffered: true)
  }

  package func reopenSaved(
    _ request: SavedReopenRequest
  ) async throws -> (WorkspaceID, WorkspaceTemplateOutcome) {
    try checkOpen()
    try checkCreationOpen()
    let saved = try savedService()
    let creator = creator
    return try await saved.reopen(request, inventory: await savedInventory()) {
      id,
      template in
      let created = try await creator.create(id, payload: .template(template))
      guard let outcome = created.outcome else {
        throw MuxError(.invalidRequest, "missing template outcome")
      }
      return outcome
    }
  }

  package func setSavedPolicy(
    _ policy: SavedLayoutPolicy,
    expectedRevision: UInt64
  ) async throws -> SavedLayoutPolicy {
    try checkOpen()
    return try await savedService()
      .setPolicy(policy, expectedRevision: expectedRevision)
  }

  package func deleteSaved(_ id: WorkspaceID?) async throws {
    try checkOpen()
    try await savedService().deleteSaved(id)
  }

  package func previousOutput(
    _ id: WorkspaceID,
    pane: PaneID,
    offset: Int
  ) async throws -> SavedOutputPage {
    try checkOpen()
    return try await savedService()
      .previousOutput(id, pane: pane, offset: offset)
  }

  package func discardPreviousOutput(
    _ id: WorkspaceID,
    pane: PaneID?
  ) async throws {
    try checkOpen()
    try await savedService().discardPreviousOutput(id, pane: pane)
  }

  private static func reconcileSaved(
    _ saved: SavedLayoutService,
    directory: GatewayWorkspaceDirectory,
    supervisor: GatewaySupervisor
  ) async {
    let inventory = await savedInventory(
      directory: directory,
      supervisor: supervisor
    )
    await saved.reconcile(inventory) { id in
      let items = try await supervisor.inventory()
      guard let item = items.first(where: { $0.authority.workspace == id })
      else { return }
      try await supervisor.endAndForget(item.authority)
    }
  }

  package func close() async {
    closed = true
    await saved?.shutdown()
    monitor?.cancel()
    await routes.close()
    await creator.close()
    await monitor?.value
    await directory.close()
    await supervisor.close()
  }

  private func checkOpen() throws {
    try Task.checkCancellation()
    if let failure { throw failure }
    guard !closed else {
      throw MuxError(.connectionLost, "gateway runtime closed")
    }
  }

  private func startMonitor(interval: Duration) {
    let directory = directory
    let routes = routes
    let supervisor = supervisor
    let creator = creator
    let saved = saved
    monitor = Task.detached { [weak self] in
      let failure: MuxError
      do {
        try await directory.monitor(interval: interval) {
          do { try await routes.reconcile() } catch let error as MuxError
            where error.code == .quiescing
          {
            // A selection already reconciles routes. Retry this read-only work
            // at the next inventory poll rather than queueing another task.
          }
          if let saved {
            await Self.reconcileSaved(
              saved,
              directory: directory,
              supervisor: supervisor
            )
          }
        }
        failure = MuxError(.connectionLost, "gateway discovery stopped")
      } catch {
        failure =
          (error as? MuxError)
          ?? MuxError(.connectionLost, "gateway discovery cancelled")
      }
      await routes.close()
      await creator.close()
      await supervisor.close()
      await self?.monitorEnded(failure)
    }
  }

  private func monitorEnded(_ error: MuxError) async {
    guard !closed else { return }
    failure = error
    closed = true
    // Guardian or discovery loss: held exit changes are discarded (§12.2.5).
    await saved?.guardianLost()
  }
}
