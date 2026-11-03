import Dispatch
import Foundation
import SwiftMuxProtocol

package struct GuardianAdmissionStatus: Codable, Equatable, Sendable {
  package let paused: Bool
  package let revision: UInt64
  package let pendingWorkers: Int
  /// Absent on guardians predating serialized worker selection.
  package var selectionPending: Bool? = nil
}

extension GuardianServer {
  package func admissionStatus(
    gateway identity: UUID
  ) throws -> GuardianAdmissionStatus {
    try queue.sync {
      try requireAdmissionGateway(identity)
      return currentAdmissionStatus()
    }
  }

  /// Every accepted set advances the revision, including reasserting a pause.
  /// Gateway loss never clears this barrier or implies installation success.
  package func setAdmissionPaused(
    _ paused: Bool,
    expectedRevision: UInt64,
    gateway identity: UUID
  ) throws -> GuardianAdmissionStatus {
    try queue.sync {
      try requireAdmissionGateway(identity)
      guard !workerSelectionPending else {
        throw MuxError(.quiescing, "worker selection is still pending")
      }
      guard admissionRevision == expectedRevision else {
        throw MuxError(.staleRevision, "admission barrier changed")
      }
      guard admissionRevision < UInt64.max else {
        throw MuxError(.resourceLimit, "admission revisions exhausted")
      }
      admissionRevision += 1
      admissionPaused = paused
      return currentAdmissionStatus()
    }
  }

  /// Reserve the barrier before filesystem work, then publish off the I/O queue.
  /// Once admitted, caller/gateway loss does not cancel an uncertain disk commit.
  package func selectWorkerBuild(
    _ build: String,
    registry: GuardianBuildRegistry,
    expectedRevision: UInt64,
    gateway identity: UUID,
    completion:
      @escaping @Sendable (Result<GuardianAdmissionStatus, MuxError>) -> Void
  ) {
    updateWorkerSelection(
      expectedRevision: expectedRevision,
      gateway: identity,
      completion: completion
    ) { try registry.select(build, guardian: self.incarnation) }
  }

  package func clearWorkerRollback(
    registry: GuardianBuildRegistry,
    expectedRevision: UInt64,
    gateway identity: UUID,
    completion:
      @escaping @Sendable (Result<GuardianAdmissionStatus, MuxError>) -> Void
  ) {
    updateWorkerSelection(
      expectedRevision: expectedRevision,
      gateway: identity,
      completion: completion
    ) { try registry.clearRollback(guardian: self.incarnation) }
  }

  private func updateWorkerSelection(
    expectedRevision: UInt64,
    gateway identity: UUID,
    completion:
      @escaping @Sendable (Result<GuardianAdmissionStatus, MuxError>) -> Void,
    publish: @escaping @Sendable () throws -> Void
  ) {
    queue.async { [self] in
      do {
        try requireAdmissionGateway(identity)
        guard admissionRevision == expectedRevision else {
          throw MuxError(.staleRevision, "admission barrier changed")
        }
        guard admissionPaused, !workerSelectionPending,
          currentAdmissionStatus().pendingWorkers == 0
        else {
          throw MuxError(
            .quiescing,
            "worker selection requires settled paused admission"
          )
        }
        guard admissionRevision < UInt64.max else {
          throw MuxError(.resourceLimit, "admission revisions exhausted")
        }
        admissionRevision += 1
        workerSelectionPending = true
      } catch {
        completion(.failure(error as? MuxError ?? MuxError(.invalidRequest)))
        return
      }
      buildSelectionQueue.async { [self] in
        let result: Result<Void, MuxError>
        do {
          try publish()
          result = .success(())
        } catch {
          result = .failure(
            error as? MuxError
              ?? MuxError(.launchFailed, "worker selection failed")
          )
        }
        queue.async { [self] in
          workerSelectionPending = false
          completion(result.map { currentAdmissionStatus() })
          checkStopped()
        }
      }
    }
  }

  func requireWorkerAdmission() throws(MuxError) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard !admissionPaused else {
      throw MuxError(.quiescing, "worker admission is paused")
    }
  }

  private func requireAdmissionGateway(_ identity: UUID) throws(MuxError) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard !stopping, gateway == identity else {
      throw MuxError(.staleAttachment, "gateway is no longer current")
    }
  }

  private func currentAdmissionStatus() -> GuardianAdmissionStatus {
    dispatchPrecondition(condition: .onQueue(queue))
    return GuardianAdmissionStatus(
      paused: admissionPaused,
      revision: admissionRevision,
      pendingWorkers: pendingWorkers.count
        + workspaces.values
        .filter { $0.token != nil && !$0.unavailable && !$0.ending }.count,
      selectionPending: workerSelectionPending
    )
  }
}
