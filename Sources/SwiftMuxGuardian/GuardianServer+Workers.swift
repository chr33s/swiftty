import Darwin
import Dispatch
import Foundation
import SwiftMuxProtocol

extension GuardianServer {
  /// Reserve identity before validating/loading the selected build. Admission
  /// survives gateway loss and is discoverable while the asynchronous work runs.
  /// Retrying a retained identity never launches another worker.
  package func createWorker(
    workspace id: WorkspaceID,
    registry: GuardianBuildRegistry,
    machService: String,
    gateway identity: UUID
  ) throws -> GuardianAuthority {
    try queue.sync {
      guard !stopping, gateway == identity else {
        throw MuxError(.staleAttachment, "gateway is no longer current")
      }
      if let workspace = workspaces[id] { return workspace.authority }
      if let pending = pendingWorkers[id] { return pending.authority }
      try requireWorkerAdmission()
      guard workspaces.count + pendingWorkers.count < limits.maxPanes else {
        throw MuxError(.resourceLimit, "workspace capacity exhausted")
      }
      let authority = try allocateAuthority(id)
      pendingWorkers[id] = PendingWorker(authority: authority)
      DispatchQueue.global(qos: .userInitiated)
        .async { [self] in
          do {
            let build = try registry.pinSelected()
            let bootstrap = GuardianWorkerBootstrap(
              version: GuardianWire.version,
              workspace: id,
              token: UUID(),
              guardianPID: getpid(),
              machService: machService,
              build: build.build,
              peerRequirement: peerRequirement
            )
            let worker = try GuardianWorkerProcess.spawn(
              executable: build.workerPath,
              arguments: [],
              bootstrap: bootstrap,
              queue: queue
            )
            queue.async { [self] in
              adoptWorker(
                .success(worker),
                bootstrap: bootstrap,
                buildPin: build
              ) { _ in }
            }
          } catch {
            let failure =
              (error as? MuxError)
              ?? MuxError(
                .launchFailed,
                "worker build validation or launch failed"
              )
            queue.async { [self] in
              let pending = pendingWorkers.removeValue(forKey: id)!
              let workspace = Workspace(
                authority: authority,
                pid: 0,
                token: UUID()
              )
              workspace.token = nil
              workspace.unavailable = true
              workspace.ending = pending.ending || stopping
              workspace.launchError = failure
              workspaces[id] = workspace
              checkStopped()
            }
          }
        }
      return authority
    }
  }

  package func launchWorker(
    workspace id: WorkspaceID,
    build: GuardianBuildPin,
    machService: String,
    completion:
      @escaping @Sendable (Result<GuardianWorkerInventory, MuxError>) -> Void
  ) {
    launchWorker(
      workspace: id,
      executable: build.workerPath,
      arguments: [],
      build: build.build,
      machService: machService,
      buildPin: build,
      completion: completion
    )
  }

  /// Supervisor-only launch from a locally selected immutable build. Remote
  /// clients never supply executable paths or bootstrap service names. The
  /// installer must retain this build and its resources while inventory pins it.
  package func launchWorker(
    workspace id: WorkspaceID,
    executable: String,
    arguments: [String] = [],
    build: String,
    machService: String,
    completion:
      @escaping @Sendable (Result<GuardianWorkerInventory, MuxError>) -> Void
  ) {
    launchWorker(
      workspace: id,
      executable: executable,
      arguments: arguments,
      build: build,
      machService: machService,
      buildPin: nil,
      completion: completion
    )
  }

  private func launchWorker(
    workspace id: WorkspaceID,
    executable: String,
    arguments: [String],
    build: String,
    machService: String,
    buildPin: GuardianBuildPin?,
    completion:
      @escaping @Sendable (Result<GuardianWorkerInventory, MuxError>) -> Void
  ) {
    queue.async {
      guard !self.stopping, self.workspaces[id] == nil,
        self.pendingWorkers[id] == nil,
        self.workspaces.count + self.pendingWorkers.count < self.limits.maxPanes
      else {
        completion(
          .failure(MuxError(.resourceLimit, "cannot launch workspace worker"))
        )
        return
      }
      do throws(MuxError) {
        try self.requireWorkerAdmission()
        self.pendingWorkers[id] = PendingWorker(
          authority: try self.allocateAuthority(id)
        )
      } catch {
        completion(.failure(error))
        return
      }
      let bootstrap = GuardianWorkerBootstrap(
        version: GuardianWire.version,
        workspace: id,
        token: UUID(),
        guardianPID: getpid(),
        machService: machService,
        build: build,
        peerRequirement: self.peerRequirement
      )
      // Signature validation and executable loading must not stall PTY I/O.
      // Retain self until adoption so shutdown cannot abandon a late child.
      DispatchQueue.global(qos: .userInitiated)
        .async { [self] in
          let result: Result<GuardianWorkerProcess, MuxError>
          do {
            result = .success(
              try GuardianWorkerProcess.spawn(
                executable: executable,
                arguments: arguments,
                bootstrap: bootstrap,
                queue: queue
              )
            )
          } catch let error as MuxError { result = .failure(error) } catch {
            result = .failure(
              MuxError(.launchFailed, "worker launch failed: \(error)")
            )
          }
          queue.async {
            self.adoptWorker(
              result,
              bootstrap: bootstrap,
              buildPin: buildPin,
              completion: completion
            )
          }
        }
    }
  }

  private func adoptWorker(
    _ result: Result<GuardianWorkerProcess, MuxError>,
    bootstrap: GuardianWorkerBootstrap,
    buildPin: GuardianBuildPin?,
    completion:
      @escaping @Sendable (Result<GuardianWorkerInventory, MuxError>) -> Void
  ) {
    let id = bootstrap.workspace
    let pending = pendingWorkers.removeValue(forKey: id)!
    defer { checkStopped() }
    switch result {
    case let .failure(error): completion(.failure(error))
    case let .success(worker):
      let workspace = Workspace(
        authority: pending.authority,
        pid: worker.pid,
        token: bootstrap.token
      )
      workspace.worker = worker
      workspace.buildPin = buildPin
      workspace.ending = pending.ending || stopping
      workspaces[id] = workspace
      worker.onFinished = { [weak self, weak worker] in
        guard let self, let worker, let workspace = self.workspaces[id],
          workspace.worker === worker
        else { return }
        self.loseWorker(workspace, MuxError(.connectionLost, "worker exited"))
        self.checkStopped()
      }
      do { try worker.activate() } catch {
        loseWorker(workspace)
        completion(
          .failure(MuxError(.launchFailed, "worker bootstrap delivery failed"))
        )
        return
      }
      guard !workspace.ending, !workspace.unavailable else {
        loseWorker(workspace)
        completion(
          .failure(MuxError(.quiescing, "worker launch ended before admission"))
        )
        return
      }
      // Success means an owned, bootstrapped child, not a ready workspace.
      // Only its authenticated welcome and graph subscription establish ready.
      completion(.success(workerInventory(worker)))
      queue.asyncAfter(deadline: .now() + 5) { [weak self, weak worker] in
        guard let self, let worker, let workspace = self.workspaces[id],
          workspace.worker === worker, workspace.connection == nil,
          !workspace.unavailable
        else { return }
        self.loseWorker(
          workspace,
          MuxError(.connectionLost, "worker did not connect")
        )
      }
    }
  }

  func workerInventory(
    _ worker: GuardianWorkerProcess
  ) -> GuardianWorkerInventory {
    GuardianWorkerInventory(
      pid: worker.pid,
      build: worker.build,
      finished: worker.finished,
      status: worker.status
    )
  }

  /// Reclaim an explicitly ended workspace only after all owned children and
  /// launches settled. Never erase retained unavailable live processes.
  package func forgetWorkspace(_ id: WorkspaceID) throws {
    try queue.sync { try forgetEndedWorkspace(id) }
  }

  package func forgetWorkspace(
    authority: GuardianAuthority,
    gateway identity: UUID
  ) throws {
    try queue.sync {
      guard !stopping, gateway == identity,
        workspaces[authority.workspace]?.authority == authority
      else {
        throw MuxError(.staleAttachment, "stale workspace retirement authority")
      }
      try forgetEndedWorkspace(authority.workspace)
    }
  }

  private func forgetEndedWorkspace(_ id: WorkspaceID) throws {
    dispatchPrecondition(condition: .onQueue(queue))
    guard pendingWorkers[id] == nil, let workspace = workspaces[id],
      workspace.ending, workspace.pendingLaunch == nil,
      workspace.worker?.finished ?? true,
      workspace.panes.values.allSatisfy({ $0.runtime.finished })
    else { throw MuxError(.quiescing, "workspace has not ended") }
    workspaces.removeValue(forKey: id)
  }
}
