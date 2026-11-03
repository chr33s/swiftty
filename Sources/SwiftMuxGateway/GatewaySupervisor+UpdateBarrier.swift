import SwiftMuxGuardian
import SwiftMuxProtocol

extension GatewaySupervisor {
  /// Read-only reconciliation under an already-owned pause. Cancellation or
  /// expiry leaves the pause intact; the updater decides whether it can resume.
  package func settledUpdateInventory(
    expectedRevision: UInt64,
    timeout: Duration = .seconds(30)
  ) async throws -> [GuardianWorkspaceInventory] {
    guard timeout > .zero, timeout <= .seconds(30) else {
      throw MuxError(.invalidRequest, "invalid update settlement timeout")
    }
    try checkOpen()
    guard identity?.supportsWorkerSelection == true else {
      throw MuxError(
        .incompatibleVersion,
        "guardian lacks serialized worker selection"
      )
    }
    let deadline = ContinuousClock.now + timeout
    let inventory = try await withThrowingTaskGroup(
      of: [GuardianWorkspaceInventory].self
    ) { group in
      group.addTask {
        try await self.waitForSettledInventory(
          expectedRevision: expectedRevision,
          deadline: deadline
        )
      }
      group.addTask {
        try await Task.sleep(until: deadline, clock: .continuous)
        throw MuxError(
          .quiescing,
          "worker admission did not settle before update deadline"
        )
      }
      defer { group.cancelAll() }
      return try await group.next()!
    }
    try checkUpdateDeadline(deadline)
    return inventory
  }

  private func waitForSettledInventory(
    expectedRevision: UInt64,
    deadline: ContinuousClock.Instant
  ) async throws -> [GuardianWorkspaceInventory] {
    while true {
      try checkUpdateDeadline(deadline)
      let before = try await admissionStatus()
      try checkUpdateDeadline(deadline)
      try validateUpdateBarrier(before, expectedRevision: expectedRevision)
      if before.pendingWorkers == 0 && before.selectionPending == false {
        let records = try await inventory()
        try checkUpdateDeadline(deadline)
        let after = try await admissionStatus()
        try checkUpdateDeadline(deadline)
        try validateUpdateBarrier(after, expectedRevision: expectedRevision)
        guard after.pendingWorkers == 0, after.selectionPending == false,
          !records.contains(where: { $0.starting })
        else {
          throw MuxError(
            .quiescing,
            "worker admission changed during inventory"
          )
        }
        return records
      }
      try await Task.sleep(
        until: min(deadline, .now + .milliseconds(25)),
        clock: .continuous
      )
    }
  }

  private func validateUpdateBarrier(
    _ status: GuardianAdmissionStatus,
    expectedRevision: UInt64
  ) throws {
    guard status.paused, status.revision == expectedRevision else {
      throw MuxError(.staleRevision, "update admission barrier changed")
    }
    guard status.selectionPending != nil else {
      throw MuxError(.incompatibleVersion, "guardian omits selection progress")
    }
  }

  private func checkUpdateDeadline(_ deadline: ContinuousClock.Instant) throws {
    try Task.checkCancellation()
    try checkOpen()
    guard ContinuousClock.now < deadline else {
      throw MuxError(
        .quiescing,
        "worker admission did not settle before update deadline"
      )
    }
  }
}
