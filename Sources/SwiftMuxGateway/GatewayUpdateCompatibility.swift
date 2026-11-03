import SwiftMuxGuardian
import SwiftMuxProtocol

/// Read-only preflight, not an update permit. Installation must also prevent
/// admission/build-selection races and revalidate before replacing the gateway.
package enum GatewayUpdateCompatibility {
  package static func validate(
    guardianProtocol: Int,
    workerProtocols: Set<Int>,
    inventory: [GuardianWorkspaceInventory]
  ) throws {
    guard !workerProtocols.isEmpty, workerProtocols.count <= 64,
      workerProtocols.allSatisfy({ $0 > 0 })
    else {
      throw MuxError(.invalidRequest, "invalid gateway worker protocol set")
    }
    guard guardianProtocol == GuardianWire.version else {
      throw MuxError(
        .incompatibleVersion,
        "candidate gateway cannot use the running guardian"
      )
    }
    for record in inventory {
      guard let version = record.workerProtocol else {
        throw MuxError(
          .quiescing,
          "workspace \(record.authority.workspace) has unknown worker compatibility"
        )
      }
      guard workerProtocols.contains(version) else {
        throw MuxError(
          .incompatibleVersion,
          "workspace \(record.authority.workspace) requires worker protocol \(version)"
        )
      }
    }
  }
}
