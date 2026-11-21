import Dispatch
import Foundation
import SwiftMuxProtocol

/// Update barrier phase (spec.durability.md §5.2). `settling` lasts until
/// the updater begins replacing the gateway; only `replacing` survives the
/// settlement deadline and gateway replacement.
package enum GuardianAdmissionPhase: String, Codable, Equatable, Sendable {
  case settling
  case replacing
}

package struct GuardianAdmissionStatus: Codable, Equatable, Sendable {
  package let paused: Bool
  package let revision: UInt64
  package let pendingWorkers: Int
  /// Absent on guardians predating serialized worker selection.
  package var selectionPending: Bool? = nil
  /// Present while paused, on guardians that record the barrier phase.
  package var phase: GuardianAdmissionPhase? = nil
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
  /// Pausing starts `settling`, which the guardian resumes itself when the
  /// settlement deadline expires or a new gateway binds; a reasserted pause
  /// keeps its phase and deadline. Gateway loss never clears `replacing` or
  /// implies installation success.
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
      if paused, !admissionPaused {
        admissionPhase = .settling
        armAdmissionSettlement()
      } else if !paused {
        admissionPhase = nil
        admissionSettlementTimer?.cancel()
        admissionSettlementTimer = nil
      }
      admissionPaused = paused
      return currentAdmissionStatus()
    }
  }

  /// The updater begins gateway replacement: the barrier no longer expires.
  package func advanceAdmissionPhase(
    expectedRevision: UInt64,
    gateway identity: UUID
  ) throws -> GuardianAdmissionStatus {
    try queue.sync {
      try requireAdmissionGateway(identity)
      guard admissionRevision == expectedRevision else {
        throw MuxError(.staleRevision, "admission barrier changed")
      }
      guard admissionPaused, admissionPhase == .settling else {
        throw MuxError(.invalidRequest, "admission is not settling")
      }
      guard admissionRevision < UInt64.max else {
        throw MuxError(.resourceLimit, "admission revisions exhausted")
      }
      admissionRevision += 1
      admissionPhase = .replacing
      admissionSettlementTimer?.cancel()
      admissionSettlementTimer = nil
      return currentAdmissionStatus()
    }
  }

  private func armAdmissionSettlement(after delay: TimeInterval? = nil) {
    dispatchPrecondition(condition: .onQueue(queue))
    admissionSettlementTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + (delay ?? admissionSettlementTimeout))
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      admissionSettlementTimer = nil
      guard admissionPaused, admissionPhase == .settling else { return }
      // Never resume under a selection publication; retry shortly after.
      guard !workerSelectionPending else {
        armAdmissionSettlement(after: 1)
        return
      }
      resumeSettlingAdmission()
    }
    admissionSettlementTimer = timer
    timer.resume()
  }

  /// Defers a settling update with the unchanged selections.
  func resumeSettlingAdmission() {
    dispatchPrecondition(condition: .onQueue(queue))
    guard admissionPaused, admissionPhase == .settling, !workerSelectionPending,
      admissionRevision < UInt64.max
    else { return }
    admissionRevision += 1
    admissionPaused = false
    admissionPhase = nil
    admissionSettlementTimer?.cancel()
    admissionSettlementTimer = nil
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
      selectionPending: workerSelectionPending,
      phase: admissionPaused ? admissionPhase : nil
    )
  }
}
