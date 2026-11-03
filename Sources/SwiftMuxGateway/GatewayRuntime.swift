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
  private var monitor: Task<Void, Never>?
  private var closed = false
  package private(set) var failure: MuxError?

  private init(
    supervisor: GatewaySupervisor,
    directory: GatewayWorkspaceDirectory,
    routes: GatewayNativeRoutes,
    creator: GatewayWorkspaceCreator
  ) {
    self.supervisor = supervisor
    self.directory = directory
    self.routes = routes
    self.creator = creator
  }

  /// Takes ownership of the supervisor. Initial inventory must succeed; worker
  /// graphs may still be discovering when this returns. Never creates a shell.
  package static func start(
    supervisor: GatewaySupervisor,
    peerRequirement: String?,
    capacity: Int = 32,
    connectionLimit: Int = 64,
    pollInterval: Duration = .seconds(1)
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
      try await discovery.refresh()
      try Task.checkCancellation()
      let runtime = GatewayRuntime(
        supervisor: supervisor,
        directory: discovery,
        routes: routes,
        creator: GatewayWorkspaceCreator(
          supervisor: supervisor,
          peerRequirement: peerRequirement
        )
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

  package func createWorkspace(
    _ id: WorkspaceID,
    request: NewWorkspaceRequest,
    timeout: Duration = .seconds(15)
  ) async throws -> GuardianAuthority {
    try checkOpen()
    return try await creator.create(id, request: request, timeout: timeout)
  }

  package func endWorkspace(_ selector: WorkspaceSelector) async throws {
    try checkOpen()
    let record = try await directory.resolve(selector)
    try checkOpen()
    try await supervisor.endAndForget(record.inventory.authority)
    // The monitor reconciles inventory and routes; no uncertain mutation replay.
  }

  package func close() async {
    closed = true
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

  private func monitorEnded(_ error: MuxError) {
    guard !closed else { return }
    failure = error
    closed = true
  }
}
