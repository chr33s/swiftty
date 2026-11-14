import Foundation
import SSHClient

/// What the persistence layer needs from the object that owns the connection
/// snapshot. The stores hold this weakly, never the app model itself, so they
/// build and test without the app's UI and terminal dependencies.
@MainActor
package protocol ConnectionOwner: AnyObject, Sendable {
  /// The committed connection state.
  var connections: ConnectionSnapshot { get }
  /// Bumped whenever the signed-in account may have changed.
  var accountGeneration: Int { get }
  func invalidateAccountContext()
  /// Writes the mutated snapshot durably, then publishes it. False when the
  /// store is unreadable or the write fails; memory is then unchanged.
  @discardableResult
  func commitConnections(
    notifySync: Bool,
    _ mutate: (inout ConnectionSnapshot) throws(ConnectionStore.StoreError) ->
      Void
  ) -> Bool
  /// The CloudKit database when metadata sync is configured.
  var cloudDatabase: (any ConnectionCloudDatabase)? { get }
  /// The local file of trusted SSH host keys.
  var trustFile: FileHostTrustStore { get }
}

extension ConnectionOwner {
  @discardableResult
  package func commitConnections(
    _ mutate: (inout ConnectionSnapshot) throws(ConnectionStore.StoreError) ->
      Void
  ) -> Bool { commitConnections(notifySync: true, mutate) }
}
