import Foundation
import SwiftMuxProtocol

/// Local supervisor protocol, on a separately authenticated gateway listener.
/// Endpoints are carried out of band and are valid only with `.endpoint` results.
package enum GuardianGatewayRequest: Codable, Equatable, Sendable {
  case hello(version: Int)
  case command(
    incarnation: UUID,
    gateway: UUID,
    sequence: UInt64,
    body: GuardianGatewayCommand
  )
  case acknowledge(sequence: UInt64)
}

package enum GuardianGatewayCommand: Codable, Equatable, Sendable {
  case inventory
  case workerSelection
  case selectWorkerBuild(String, expectedRevision: UInt64)
  case clearWorkerRollback(expectedRevision: UInt64)
  case admissionStatus
  case setAdmissionPaused(Bool, expectedRevision: UInt64)
  /// Settling → replacing (spec.durability.md §5.2).
  case advanceAdmissionPhase(expectedRevision: UInt64)
  case create(workspace: WorkspaceID)
  case endpoint(workspace: WorkspaceID)
  case grantWriter(workspace: WorkspaceID)
  case ensureWriter(authority: GuardianAuthority)
  case end(authority: GuardianAuthority)
  case forget(authority: GuardianAuthority)
}

package enum GuardianGatewayEvent: Codable, Sendable {
  case welcome(
    incarnation: UUID,
    gateway: UUID,
    supportsEnsureWriter: Bool? = nil,
    supportsAdmissionControl: Bool? = nil,
    supportsWorkerSelection: Bool? = nil,
    supportsAdmissionPhase: Bool? = nil
  )
  case result(sequence: UInt64, value: GuardianGatewayResult)
  case refused(MuxError)
}

package enum GuardianGatewayResult: Codable, Sendable {
  case inventory([GuardianWorkspaceInventory])
  case admission(GuardianAdmissionStatus)
  case workerSelection(GuardianWorkerSelection)
  /// Admission only; inventory and endpoint discovery establish readiness.
  case creating(GuardianAuthority)
  case endpoint(
    authority: GuardianAuthority,
    instance: ServerInstanceID,
    pid: Int32
  )
  case writer(UUID)
  /// End was accepted. Inventory establishes when process teardown finishes.
  case ending
  /// All owned processes finished and the workspace's resources were released.
  case forgotten
  case rejected(MuxError)
}

package struct GuardianWorkerSelection: Codable, Sendable, Equatable {
  package let selected: String?
  package let rollback: String?
}
