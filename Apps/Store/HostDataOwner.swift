import Foundation
import SSHClient

/// Durable ownership of saved workspaces and local transfer data. Credentials
/// can rotate without changing the remote user's data; names and revisions are
/// not owners.
package struct HostDataOwner: Codable, Hashable, Sendable {
  package let hostID: UUID
  package let account: String?
  package let hostname: String
  package let port: Int
  package let username: String

  package init(host: HostProfile, account: String?) {
    hostID = host.id
    self.account = account
    hostname = HostIdentity(host: host.host, port: host.port)?.host ?? host.host
    port = host.port
    username = host.username
  }

  package func hasSameEndpoint(as other: Self) -> Bool {
    hostID == other.hostID && hostname == other.hostname && port == other.port
      && username == other.username
  }
}
