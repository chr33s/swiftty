import Foundation
import SwiftMuxClient
import SwiftMuxGuardian
import SwiftMuxProtocol

extension GatewaySupervisor {
  package func workerSelection() async throws -> GuardianWorkerSelection {
    guard case let .workerSelection(value) = try await request(.workerSelection)
    else { throw MuxError(.invalidRequest, "missing worker selection") }
    return value
  }

  package func selectWorkerBuild(
    _ build: String,
    expectedRevision: UInt64
  ) async throws -> GuardianAdmissionStatus {
    guard
      case let .admission(value) = try await request(
        .selectWorkerBuild(build, expectedRevision: expectedRevision)
      )
    else {
      throw MuxError(.invalidRequest, "missing selection acknowledgement")
    }
    return value
  }

  package func clearWorkerRollback(
    expectedRevision: UInt64
  ) async throws -> GuardianAdmissionStatus {
    guard
      case let .admission(value) = try await request(
        .clearWorkerRollback(expectedRevision: expectedRevision)
      )
    else { throw MuxError(.invalidRequest, "missing rollback acknowledgement") }
    return value
  }

  package func admissionStatus() async throws -> GuardianAdmissionStatus {
    guard case let .admission(status) = try await request(.admissionStatus)
    else { throw MuxError(.invalidRequest, "missing admission status") }
    return status
  }

  package func setAdmissionPaused(
    _ paused: Bool,
    expectedRevision: UInt64
  ) async throws -> GuardianAdmissionStatus {
    guard
      case let .admission(status) = try await request(
        .setAdmissionPaused(paused, expectedRevision: expectedRevision)
      )
    else {
      throw MuxError(.invalidRequest, "missing admission acknowledgement")
    }
    return status
  }

  package func inventory() async throws -> [GuardianWorkspaceInventory] {
    guard case let .inventory(items) = try await request(.inventory) else {
      throw MuxError(.invalidRequest, "missing guardian inventory")
    }
    return items
  }

  /// Explicit creation only. Discovery never calls this to repair missing state.
  package func create(
    _ workspace: WorkspaceID
  ) async throws -> GuardianAuthority {
    guard
      case let .creating(authority) = try await request(
        .create(workspace: workspace)
      )
    else { throw MuxError(.invalidRequest, "missing worker admission") }
    return authority
  }

  /// Called only when writer access is needed, never by status/discovery.
  package func grantWriter(_ workspace: WorkspaceID) async throws {
    guard case .writer = try await request(.grantWriter(workspace: workspace))
    else { throw MuxError(.invalidRequest, "missing writer capability") }
  }

  /// Reuses the current grant; a new grant must be applied by the worker before
  /// this returns. Endpoint polling is read-only and never repeats the mutation.
  package func ensureWriter(_ authority: GuardianAuthority) async throws {
    guard case .writer = try await request(.ensureWriter(authority: authority))
    else { throw MuxError(.invalidRequest, "missing stable writer grant") }
    let deadline = ContinuousClock.now + .seconds(5)
    while true {
      try Task.checkCancellation()
      do {
        _ = try await workerEndpoint(authority)
        return
      } catch let error as MuxError where error.code == .notAttached {
        guard ContinuousClock.now < deadline else {
          throw MuxError(
            .notAttached,
            "worker has not applied writer authority"
          )
        }
        try await Task.sleep(for: .milliseconds(25))
      }
    }
  }

  /// Resolves routing information without granting input authority or a lease.
  package func workerEndpoint(
    _ authority: GuardianAuthority
  ) async throws -> GuardianWorkerEndpoint {
    guard
      case let .endpoint(worker) = try await request(
        .endpoint(workspace: authority.workspace)
      ), worker.authority == authority
    else { throw MuxError(.staleAttachment, "workspace owner changed") }
    try checkOpen()
    try Task.checkCancellation()
    return worker
  }

  /// Returns a verified transport, not display readiness or a controller lease.
  /// The caller must obtain the graph/subscription and attach using normal rules.
  package func connectWorker(
    _ authority: GuardianAuthority,
    peerRequirement: String?,
    frontend: FrontendKind,
    terminalProfile: String? = nil,
    forwardedTransport: LeaseHolder.Transport? = nil,
    relaysAcknowledgements: Bool = false
  ) async throws -> MuxConnection {
    let worker = try await workerEndpoint(authority)
    let client = try await MuxConnection.connectWorker(
      endpoint: worker.endpoint,
      expectedPID: worker.pid,
      expectedServer: worker.instance,
      peerRequirement: peerRequirement,
      frontend: frontend,
      terminalProfile: terminalProfile,
      forwardedTransport: forwardedTransport,
      relaysAcknowledgements: relaysAcknowledgements
    )
    do {
      try checkOpen()
      try Task.checkCancellation()
      return client
    } catch {
      await client.close()
      throw error
    }
  }

  /// End is submitted once. Only a definitive quiescing Forget is retried.
  /// Timeout/cancellation leaves teardown discoverable; connection loss is an
  /// unknown outcome and must be reconciled from a fresh inventory by the caller.
  package func endAndForget(
    _ authority: GuardianAuthority,
    timeout: Duration = .seconds(10)
  ) async throws {
    guard timeout > .zero, timeout <= .seconds(30) else {
      throw MuxError(.invalidRequest, "invalid workspace teardown timeout")
    }
    let deadline = ContinuousClock.now + timeout
    guard case .ending = try await request(.end(authority: authority)) else {
      throw MuxError(.invalidRequest, "missing End acknowledgement")
    }
    while true {
      try Task.checkCancellation()
      guard ContinuousClock.now < deadline else {
        throw MuxError(.quiescing, "workspace teardown is still pending")
      }
      do {
        guard case .forgotten = try await request(.forget(authority: authority))
        else {
          throw MuxError(.invalidRequest, "missing retirement acknowledgement")
        }
        return
      } catch let error as MuxError where error.code == .quiescing {
        try await Task.sleep(
          until: min(deadline, .now + .milliseconds(25)),
          clock: .continuous
        )
      }
    }
  }
}
