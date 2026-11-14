import Foundation
import SSHIdentity

/// The entire local state of one record, including unsent edits and conflicts.
/// A record name is unique within an account, not across accounts.
package enum CachedConnectionRecord: Hashable, Sendable, Codable {
  case host(
    profile: HostProfile?,
    position: Int?,
    revision: LogicalRevision?,
    tombstone: HostTombstone?,
    conflict: HostConflict?
  )
  case identity(metadata: SSHIdentityMetadata?, conflict: SSHIdentityMetadata?)
  case knownHost(
    record: KnownHostRecord?,
    incoming: KnownHostRecord?,
    review: TrustReview?
  )

  package func matches(name: String) -> Bool {
    switch self {
    case let .host(profile, position, _, _, conflict):
      guard name.hasPrefix("host-"),
        let id = UUID(uuidString: String(name.dropFirst(5)))
      else { return false }
      return (profile == nil || profile?.id == id)
        && (conflict == nil || conflict?.remote.id == id)
        && (position ?? 0) >= 0
    case let .identity(metadata, conflict):
      guard name.hasPrefix("identity-"),
        let id = UUID(uuidString: String(name.dropFirst(9)))
      else { return false }
      return (metadata == nil || metadata?.id == id)
        && (conflict == nil || conflict?.id == id)
    case let .knownHost(record, incoming, review):
      return name.hasPrefix("knownhost-")
        && [record, incoming].compactMap { $0 }
          .allSatisfy {
            ConnectionSnapshot.knownHostRecord(host: $0.host, port: $0.port)
              == name
          }
        && (review == nil || review?.recordName == name)
    }
  }
}

extension ConnectionSnapshot {
  /// Keychain identities belong to their verified account even before the
  /// user opts into metadata sync. Restore only those identities here;
  /// host/trust cache selection still follows metadata-account consent.
  package mutating func selectKeychainAccount(_ account: String?) {
    verifiedKeychainAccount = account
    guard let account else { return }
    let records = accounts[account]?.cachedRecords ?? [:]
    for name in records.keys.sorted() {
      if case .identity(let metadata, _)? = records[name],
        metadata?.storage == .iCloudKeychain
      {
        activateRecord(name, for: account)
      }
    }
  }

  /// Selects a verified account and restores records displaced while it was
  /// inactive. Noncolliding records stay in the working set, hidden by scope.
  package mutating func selectAccount(_ account: String?) {
    if let previous = boundAccount, previous != account {
      accounts[previous, default: AccountPartition()].hostOrder =
        hosts.filter { scopes[Self.hostRecord($0.id)] == previous }.map(\.id)
    }
    boundAccount = account
    guard let account else { return }
    let names = accounts[account]?.cachedRecords?.keys.sorted() ?? []
    for name in names { activateRecord(name, for: account) }
    if let order = accounts[account]?.hostOrder {
      let ranks = Dictionary(
        order.enumerated().map { ($0.element, $0.offset) },
        uniquingKeysWith: { first, _ in first }
      )
      hosts = hosts.enumerated()
        .sorted { a, b in
          let ar =
            scopes[Self.hostRecord(a.element.id)] == account
            ? ranks[a.element.id] : nil
          let br =
            scopes[Self.hostRecord(b.element.id)] == account
            ? ranks[b.element.id] : nil
          return (ar ?? (order.count + a.offset))
            < (br ?? (order.count + b.offset))
        }
        .map(\.element)
    }
  }

  /// Call before applying an account's record. Never compare its revision,
  /// tombstone or conflict against a different account's same-name record.
  package mutating func activateRecord(_ name: String, for account: String) {
    if name.hasPrefix("identity-"),
      let id = UUID(uuidString: String(name.dropFirst(9))),
      unverifiedKeychainIdentities?.contains(id) == true
    {
      return
    }
    if let previous = scopes[name], previous != account {
      if let record = takeRecord(name) {
        var partition = accounts[previous] ?? AccountPartition()
        if partition.cachedRecords == nil { partition.cachedRecords = [:] }
        partition.cachedRecords?[name] = record
        accounts[previous] = partition
      }
      scopes[name] = nil
    }
    if let cached = accounts[account]?.cachedRecords?.removeValue(forKey: name)
    {
      restore(cached, named: name)
      scopes[name] = account
    }
  }

  private mutating func takeRecord(_ name: String) -> CachedConnectionRecord? {
    if name.hasPrefix("host-"),
      let id = UUID(uuidString: String(name.dropFirst(5)))
    {
      let position = hosts.firstIndex { $0.id == id }
      return .host(
        profile: position.map { hosts.remove(at: $0) },
        position: position,
        revision: hostRevisions.removeValue(forKey: id),
        tombstone: hostTombstones.removeValue(forKey: id),
        conflict: hostConflicts.removeValue(forKey: id)
      )
    }
    if name.hasPrefix("identity-"),
      let id = UUID(uuidString: String(name.dropFirst(9)))
    {
      return .identity(
        metadata: identities.firstIndex { $0.id == id }
          .map { identities.remove(at: $0) },
        conflict: identityConflicts.removeValue(forKey: id)
      )
    }
    if name.hasPrefix("knownhost-") {
      return .knownHost(
        record: knownHosts.removeValue(forKey: name),
        incoming: trustInbox.removeValue(forKey: name),
        review: trustReviews.removeValue(forKey: name)
      )
    }
    return nil
  }

  private mutating func restore(
    _ record: CachedConnectionRecord,
    named name: String
  ) {
    switch record {
    case let .host(profile, position, revision, tombstone, conflict):
      guard let id = UUID(uuidString: String(name.dropFirst(5))) else { return }
      if let profile {
        hosts.insert(
          profile,
          at: min(max(0, position ?? hosts.count), hosts.count)
        )
      }
      hostRevisions[id] = revision
      hostTombstones[id] = tombstone
      hostConflicts[id] = conflict
    case let .identity(metadata, conflict):
      guard let id = UUID(uuidString: String(name.dropFirst(9))) else { return }
      if let metadata { identities.append(metadata) }
      identityConflicts[id] = conflict
    case let .knownHost(record, incoming, review):
      knownHosts[name] = record
      trustInbox[name] = incoming
      trustReviews[name] = review
    }
  }

  private var cachedRecords: [CachedConnectionRecord] {
    accounts.values.flatMap { $0.cachedRecords.map { Array($0.values) } ?? [] }
  }

  package var cachedHosts: [HostProfile] {
    cachedRecords.compactMap { record in
      if case .host(let host, _, _, _, _) = record { return host }
      return nil
    }
  }

  package var cachedIdentities: [SSHIdentityMetadata] {
    cachedRecords.compactMap { record in
      if case .identity(let metadata, _) = record { return metadata }
      return nil
    }
  }

  package var cachedKnownHosts: [KnownHostRecord] {
    cachedRecords.compactMap { record in
      if case .knownHost(let record, _, _) = record { return record }
      return nil
    }
  }
}
