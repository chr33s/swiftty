import Darwin
import Dispatch
import Foundation
import SwiftMuxProtocol
import SwiftMuxXPC

/// Authenticated local worker transport and process inventory. All mutable
/// state belongs to `queue`. PTYs outlive connections; only explicit End or
/// guardian shutdown terminates them. The supervisor provisions workers and
/// writer capabilities; neither is self-issued over the worker connection.
package final class GuardianServer: @unchecked Sendable {
  package let incarnation = UUID()
  let queue = DispatchQueue(label: "swiftmux.guardian", qos: .userInitiated)
  let limits: MuxLimits
  let launcher: PaneLauncher
  let peerRequirement: String?
  let progressTimeout: TimeInterval
  let buildSelectionQueue: DispatchQueue
  var workspaces: [WorkspaceID: Workspace] = [:]
  var peers: [UUID: Peer] = [:]
  var listener: SMXListener?
  var gateway: UUID?
  var gatewayPID: Int32?
  var outputBytes = 0
  var resultBytes = 0
  var admissionPaused = false
  var admissionRevision: UInt64 = 0
  /// Set while paused (spec.durability.md §5.2).
  var admissionPhase: GuardianAdmissionPhase?
  /// Bounds `settling`; the guardian resumes admission on expiry.
  let admissionSettlementTimeout: TimeInterval
  var admissionSettlementTimer: DispatchSourceTimer?
  var workerSelectionPending = false
  var pendingLaunches = 0
  struct PendingWorker {
    let authority: GuardianAuthority
    var ending = false
  }

  var pendingWorkers: [WorkspaceID: PendingWorker] = [:]
  private var lastGeneration: UInt64 = 0

  /// Never reuse authority, even when a retired workspace ID is submitted again.
  func allocateAuthority(
    _ workspace: WorkspaceID
  ) throws(MuxError) -> GuardianAuthority {
    dispatchPrecondition(condition: .onQueue(queue))
    guard lastGeneration < UInt64.max else {
      throw MuxError(.resourceLimit, "workspace generations exhausted")
    }
    lastGeneration += 1
    return GuardianAuthority(
      incarnation: incarnation,
      workspace: workspace,
      generation: lastGeneration
    )
  }
  var stopping = false
  var stopCallbacks: [@Sendable () -> Void] = []

  final class Peer {
    let channel: SMXChannel
    var workspace: WorkspaceID?
    init(_ channel: SMXChannel) { self.channel = channel }
  }

  final class Workspace {
    let authority: GuardianAuthority
    let expectedPID: Int32
    var token: UUID?
    var connection: UUID?
    var unavailable = false
    var ending = false
    var pendingLaunch: PendingLaunch?
    var writer: UUID?
    var observesGateway = false
    var gatewayRevision: UInt64 = 0
    var appliedGatewayRevision: UInt64 = 0
    var inFlightGatewayRevision: UInt64?
    var panes: [PaneID: Pane] = [:]
    var nextCommand: UInt64 = 1
    var retired: UInt64 = 0
    var results: [UInt64: (GuardianCommand, GuardianResult, Int)] = [:]
    var resultBytes = 0
    var outputBytes = 0
    var progressProbe: UUID?
    var progressDeadline: DispatchTime = .now()
    var progressTimer: DispatchSourceTimer?
    var worker: GuardianWorkerProcess?
    var buildPin: GuardianBuildPin?
    var launchError: MuxError?
    var serviceEndpoint: GuardianWorkerEndpoint?

    init(authority: GuardianAuthority, pid: Int32, token: UUID) {
      self.authority = authority
      expectedPID = pid
      self.token = token
    }
  }

  final class Pane {
    let process = UUID()
    let runtime: GuardianPTY
    var nextOutput: UInt64 = 1
    var acknowledged: UInt64 = 0
    var outstanding: [UInt64: Int] = [:]
    var outputBytes = 0
    init(_ runtime: GuardianPTY) { self.runtime = runtime }
  }

  struct PendingLaunch {
    let id: PaneID
    let pane: Pane
    let command: GuardianCommand
    let charge: Int
  }

  package init(
    launcherPath: String,
    limits: MuxLimits = .standard,
    peerRequirement: String?,
    progressTimeout: TimeInterval = 5,
    admissionSettlementTimeout: TimeInterval = 30,
    buildSelectionQueue: DispatchQueue = .global(qos: .utility)
  ) throws(MuxError) {
    try limits.validateForService()
    guard progressTimeout.isFinite, progressTimeout > 0, progressTimeout <= 5
    else { throw MuxError(.invalidRequest, "invalid worker progress timeout") }
    guard admissionSettlementTimeout.isFinite, admissionSettlementTimeout > 0,
      admissionSettlementTimeout <= 30
    else {
      throw MuxError(.invalidRequest, "invalid admission settlement deadline")
    }
    guard limits.readTurnBytes > 0,
      limits.readTurnBytes <= GuardianWire.outputChunkLimit
    else {
      throw MuxError(
        .invalidRequest,
        "guardian read chunk must be at most 64 KiB"
      )
    }
    self.limits = limits
    self.peerRequirement = peerRequirement
    self.progressTimeout = progressTimeout
    self.admissionSettlementTimeout = admissionSettlementTimeout
    self.buildSelectionQueue = buildSelectionQueue
    launcher = PaneLauncher(
      launcherPath: launcherPath,
      innerTerm: SMX.fallbackInnerTerm
    )
  }

  package func listenAnonymously() -> SMXEndpoint {
    queue.sync {
      precondition(listener == nil)
      let value = SMXListener(anonymousOn: queue)
      listener = value
      activate(value)
      return value.endpoint
    }
  }

  package func listen(machService: String) {
    queue.sync {
      precondition(listener == nil)
      let value = SMXListener(machService: machService, queue: queue)
      listener = value
      activate(value)
    }
  }

  private func activate(_ value: SMXListener) {
    value.activate(connectionQueue: queue) { [weak self] channel in
      self?.accept(channel)
    }
  }

  /// Supervisor-only admission: bind a one-use token to its spawned worker's
  /// PID. A disconnected workspace cannot be revived by presenting the token.
  package func provisionWorker(
    workspace: WorkspaceID,
    pid: Int32
  ) throws -> UUID {
    try queue.sync {
      try requireWorkerAdmission()
      guard !stopping, pid > 0, workspaces[workspace] == nil,
        pendingWorkers[workspace] == nil,
        workspaces.count + pendingWorkers.count < limits.maxPanes
      else { throw MuxError(.resourceLimit, "cannot provision workspace") }
      let token = UUID()
      let authority = try allocateAuthority(workspace)
      workspaces[workspace] = Workspace(
        authority: authority,
        pid: pid,
        token: token
      )
      return token
    }
  }

  package func replaceGateway(_ identity: UUID, pid: Int32 = getpid()) {
    queue.sync {
      precondition(pid > 0)
      guard gateway != identity || gatewayPID != pid else { return }
      gateway = identity
      gatewayPID = pid
      for workspace in workspaces.values {
        revokeWriter(workspace)
        publishGatewayBinding(workspace)
      }
      // A new gateway did not start a settling update and cannot finish it.
      resumeSettlingAdmission()
    }
  }

  package func grantWriter(
    workspace id: WorkspaceID,
    gateway identity: UUID
  ) throws -> UUID {
    try queue.sync {
      guard !stopping, gateway == identity, let workspace = workspaces[id],
        workspace.connection != nil, !workspace.unavailable, !workspace.ending
      else { throw MuxError(.notAttached, "gateway or worker is unavailable") }
      revokeWriter(workspace)
      let capability = UUID()
      workspace.writer = capability
      publishGatewayBinding(workspace)
      return capability
    }
  }

  /// Establish input authority once for the current gateway. Unlike explicit
  /// renewal, repeated calls do not cancel input or advance the binding revision.
  package func ensureWriter(
    authority: GuardianAuthority,
    gateway identity: UUID
  ) throws -> UUID {
    try queue.sync {
      guard !stopping, gateway == identity,
        let workspace = workspaces[authority.workspace],
        workspace.authority == authority
      else { throw MuxError(.staleAttachment, "stale writer authority") }
      guard workspace.connection != nil, !workspace.unavailable,
        !workspace.ending
      else { throw MuxError(.notAttached, "worker is unavailable") }
      if let writer = workspace.writer { return writer }
      let capability = UUID()
      workspace.writer = capability
      publishGatewayBinding(workspace)
      return capability
    }
  }

  package func revokeGateway(_ identity: UUID) {
    queue.sync {
      guard gateway == identity else { return }
      gateway = nil
      gatewayPID = nil
      for workspace in workspaces.values {
        revokeWriter(workspace)
        publishGatewayBinding(workspace)
      }
    }
  }

  package func gatewayReady(
    workspace id: WorkspaceID,
    gateway identity: UUID?
  ) -> Bool {
    queue.sync {
      guard !stopping, gateway == identity, let workspace = workspaces[id],
        !workspace.unavailable, !workspace.ending, workspace.observesGateway,
        workspace.gatewayRevision > 0
      else { return false }
      return workspace.appliedGatewayRevision == workspace.gatewayRevision
    }
  }

  func publishGatewayBinding(_ workspace: Workspace) {
    guard workspace.observesGateway, !workspace.unavailable else { return }
    guard workspace.gatewayRevision < UInt64.max else {
      loseWorker(workspace);
      return
    }
    workspace.gatewayRevision += 1
    sendCurrentGatewayBinding(workspace)
  }

  func sendCurrentGatewayBinding(_ workspace: Workspace) {
    guard workspace.inFlightGatewayRevision == nil,
      workspace.appliedGatewayRevision < workspace.gatewayRevision,
      !workspace.unavailable
    else { return }
    workspace.inFlightGatewayRevision = workspace.gatewayRevision
    send(
      .gatewayBinding(
        GuardianGatewayBinding(
          authority: workspace.authority,
          revision: workspace.gatewayRevision,
          gateway: gateway,
          pid: gatewayPID,
          writer: workspace.writer
        )
      ),
      to: workspace
    )
  }

  func revokeWriter(_ workspace: Workspace) {
    workspace.writer = nil
    for (id, pane) in workspace.panes {
      let released = pane.runtime.discardUnwrittenInput()
      if released > 0 {
        send(
          .inputReleased(
            pane: GuardianPaneHandle(pane: id, process: pane.process),
            bytes: released
          ),
          to: workspace
        )
      }
      pane.runtime.flush()
    }
  }

  /// Discovery returns only a live admitted worker. The caller must still
  /// authenticate the endpoint peer against this PID and signing policy.
  package func workerEndpoint(
    workspace id: WorkspaceID
  ) -> GuardianWorkerEndpoint? {
    queue.sync {
      guard !stopping, let workspace = workspaces[id], !workspace.unavailable,
        workspace.connection != nil
      else { return nil }
      return workspace.serviceEndpoint
    }
  }

  package func inventory() -> [GuardianWorkspaceInventory] {
    queue.sync {
      let settled = workspaces.values.map { workspace in
        GuardianWorkspaceInventory(
          authority: workspace.authority,
          available: workspace.connection != nil && !workspace.unavailable,
          worker: workspace.worker.map { workerInventory($0) },
          panes: workspace.panes.map { id, pane in
            GuardianPaneInventory(
              pane: id,
              process: pane.process,
              pid: pane.runtime.pid,
              finished: pane.runtime.finished
            )
          },
          // Adoption precedes the worker's authenticated hello. Keep that
          // interval distinct from a worker that has become unavailable.
          starting: workspace.token != nil && !workspace.unavailable
            && !workspace.ending,
          launchError: workspace.launchError,
          workerProtocol: workspace.buildPin?.manifest.workerProtocol
        )
      }
      return settled
        + pendingWorkers.values.map { pending in
          GuardianWorkspaceInventory(
            authority: pending.authority,
            available: false,
            worker: nil,
            panes: [],
            starting: true
          )
        }
    }
  }

  /// Supervisor End works even when the worker is dead. No PID supplied by
  /// the caller is used for signalling; the retained runtime owns the child.
  package func endWorkspace(_ id: WorkspaceID) {
    queue.async {
      self.pendingWorkers[id]?.ending = true
      guard let workspace = self.workspaces[id] else { return }
      workspace.ending = true
      self.loseWorker(workspace)
      for pane in workspace.panes.values { pane.runtime.terminate() }
    }
  }

  /// Validate supervisor authority and select the retained process owners in
  /// the same queue turn. A stale generation cannot terminate a replacement.
  package func endWorkspace(
    authority: GuardianAuthority,
    gateway identity: UUID
  ) throws {
    try queue.sync {
      guard !stopping, gateway == identity else {
        throw MuxError(
          .staleAttachment,
          "stale workspace termination authority"
        )
      }
      if pendingWorkers[authority.workspace]?.authority == authority {
        pendingWorkers[authority.workspace]?.ending = true
        return
      }
      guard let workspace = workspaces[authority.workspace],
        workspace.authority == authority
      else {
        throw MuxError(
          .staleAttachment,
          "stale workspace termination authority"
        )
      }
      workspace.ending = true
      loseWorker(workspace)
      for pane in workspace.panes.values { pane.runtime.terminate() }
    }
  }

  package func shutdown(completion: @escaping @Sendable () -> Void) {
    queue.async {
      self.stopCallbacks.append(completion)
      self.stopping = true
      self.listener?.cancel()
      self.listener = nil
      for workspace in self.workspaces.values {
        self.loseWorker(workspace)
        for pane in workspace.panes.values { pane.runtime.terminate() }
      }
      self.checkStopped()
    }
  }

  func checkStopped() {
    guard stopping, !workerSelectionPending, pendingLaunches == 0,
      pendingWorkers.isEmpty,
      workspaces.values.allSatisfy({
        ($0.worker?.finished ?? true)
          && $0.panes.values.allSatisfy { $0.runtime.finished }
      })
    else { return }
    let callbacks = stopCallbacks
    stopCallbacks.removeAll()
    for callback in callbacks { callback() }
  }
}
