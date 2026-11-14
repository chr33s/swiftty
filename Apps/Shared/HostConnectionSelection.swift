import Foundation

/// Non-secret selection retained between presentation and fresh SSH sign-ins.
/// An unsaved target also captures its absence, so a later same-UUID record
/// cannot become its owner implicitly.
struct HostConnectionSelection: Identifiable, Hashable, Sendable {
  let host: HostProfile
  let context: HostMutationContext
  let identity: SSHIdentityStore.AuthenticationReference?
  var id: UUID { host.id }

  /// A renamed key remains the same target; account and credential changes do not.
  func hasSameTarget(as other: Self) -> Bool {
    guard host == other.host, context == other.context else { return false }
    switch (identity, other.identity) {
    case (nil, nil): return true
    case let (first?, second?): return first.hasSameIdentity(as: second)
    default: return false
    }
  }
}

extension RoamingAppModel {
  func connectionSelection(for host: HostProfile) -> HostConnectionSelection {
    let exists = connections.hosts.contains { $0.id == host.id }
    return HostConnectionSelection(
      host: host,
      context: hostMutationContext(for: exists ? host : nil, id: host.id),
      identity: host.auth.identityID.map {
        identityStore.authenticationReference($0)
      }
    )
  }
}

extension HostDataOwner {
  init(_ selection: HostConnectionSelection) {
    self.init(host: selection.host, account: selection.context.scope)
  }
}
