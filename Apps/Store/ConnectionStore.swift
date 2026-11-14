import Crypto
import Foundation
import SSHIdentity

/// A deleted host's revision. Tombstones are never garbage-collected in
/// v1 (spec.ssh-identity.md §8.3): a stale device cannot resurrect them.
public struct HostTombstone: Hashable, Sendable, Codable {
  public var revision: LogicalRevision
  public var deletedAt: Date

  package init(
    revision: LogicalRevision,
    deletedAt: Date
  ) {
    self.revision = revision
    self.deletedAt = deletedAt
  }
}

/// Host, port, username and sign-in method: merged as one value, never
/// field by field (§8.3).
public struct ConnectionTuple: Hashable, Sendable, Codable {
  public var host: String
  public var port: Int
  public var username: String
  public var auth: AuthMethodReference

  public init(_ profile: HostProfile) {
    host = profile.host
    port = profile.port
    username = profile.username
    auth = profile.auth
  }
}

/// A concurrent remote edit to a host's connection tuple, held for review.
public struct HostConflict: Hashable, Sendable, Codable {
  public var remote: HostProfile
  public var remoteRevision: LogicalRevision

  package init(
    remote: HostProfile,
    remoteRevision: LogicalRevision
  ) {
    self.remote = remote
    self.remoteRevision = remoteRevision
  }
}

/// A host conflict with the host it belongs to.
public struct HostConflictItem: Hashable, Sendable, Identifiable {
  public var id: UUID
  public var conflict: HostConflict

  package init(
    id: UUID,
    conflict: HostConflict
  ) {
    self.id = id
    self.conflict = conflict
  }
}

/// Trust metadata for one known host, for opt-in trust sync (§8.1).
public struct KnownHostRecord: Hashable, Sendable, Codable {
  public enum Provenance: Hashable, Sendable, Codable {
    /// Approved on this device.
    case local
    /// Received from another of the user's devices.
    case synced(deviceID: UUID)
  }

  public var host: String
  public var port: Int
  public var publicKey: String
  public var fingerprint: String
  public var provenance: Provenance
  public var revision: LogicalRevision
  public var deletedAt: Date?

  package init(
    host: String,
    port: Int,
    publicKey: String,
    fingerprint: String,
    provenance: Provenance,
    revision: LogicalRevision,
    deletedAt: Date? = nil
  ) {
    self.host = host
    self.port = port
    self.publicKey = publicKey
    self.fingerprint = fingerprint
    self.provenance = provenance
    self.revision = revision
    self.deletedAt = deletedAt
  }
}

/// A trust change from another device that this device will not apply on
/// its own (§8.3). The local pin stays until the user decides.
public struct TrustReview: Hashable, Sendable, Codable, Identifiable {
  public enum Kind: Hashable, Sendable, Codable {
    /// Another device trusts a different key for this endpoint.
    case conflictingKey(remoteKey: String, remoteFingerprint: String)
    /// Another device removed its trust for this endpoint.
    case removedElsewhere
  }

  public var id: String { recordName }
  public var recordName: String
  public var host: String
  public var port: Int
  public var kind: Kind
  public var localFingerprint: String?

  package init(
    recordName: String,
    host: String,
    port: Int,
    kind: Kind,
    localFingerprint: String? = nil
  ) {
    self.recordName = recordName
    self.host = host
    self.port = port
    self.kind = kind
    self.localFingerprint = localFingerprint
  }
}

/// A durable, non-secret description of an in-progress identity change
/// (§7.2): record intent, write the item, verify, publish metadata, then
/// complete. Retried after relaunch from whichever step it reached.
public struct IdentityIntent: Hashable, Sendable, Codable, Identifiable {
  public enum Kind: Hashable, Sendable, Codable {
    case generate
    case importKey
    /// A new UUID for the same key material, in iCloud Keychain.
    case iCloudCopy(source: UUID)
    /// A new device-only copy that replaces `source`, then retires it.
    case withdraw(source: UUID)
    /// A version-1 label key moving to a new UUID.
    case migrateLegacy(label: String)
    /// Delete the identity's own Keychain item, after its tombstone.
    case deleteSecret
  }

  public enum Stage: Int, Hashable, Sendable, Codable, Comparable {
    case recorded, secretWritten, verified, published

    public static func < (lhs: Self, rhs: Self) -> Bool {
      lhs.rawValue < rhs.rawValue
    }
  }

  public let id: UUID
  public let identityID: UUID
  public let kind: Kind
  public let policy: IdentityStoragePolicy
  public let name: String
  /// The canonical public key the stored secret must match.
  public let publicKey: String
  /// Hosts to move to `identityID` once it is published.
  public let reassign: [UUID]
  public var stage: Stage
  public let createdAt: Date
  /// Account that authorized this operation; nil denotes local-only work.
  /// Recovery never publishes an old account's intent into a new account.
  public var account: String? = nil
  /// The verified account authorizing synchronizable Keychain access,
  /// independent of whether CloudKit metadata sync has ever been enabled.
  public var keychainAccount: String? = nil

  package init(
    id: UUID,
    identityID: UUID,
    kind: Kind,
    policy: IdentityStoragePolicy,
    name: String,
    publicKey: String,
    reassign: [UUID],
    stage: Stage,
    createdAt: Date,
    account: String? = nil,
    keychainAccount: String? = nil
  ) {
    self.id = id
    self.identityID = identityID
    self.kind = kind
    self.policy = policy
    self.name = name
    self.publicKey = publicKey
    self.reassign = reassign
    self.stage = stage
    self.createdAt = createdAt
    self.account = account
    self.keychainAccount = keychainAccount
  }

  package var requiresKeychainAccount: Bool {
    if policy == .iCloudKeychain { return true }
    if case .withdraw = kind { return true }
    return false
  }

  package var hasUnverifiedAccount: Bool {
    requiresKeychainAccount && account == nil && keychainAccount == nil
  }

  /// Old creations with no account provenance may only be restored after
  /// explicit review. Their host reassignment/deletion steps are not replayed.
  package var canRestoreAfterAccountReview: Bool {
    hasUnverifiedAccount && kind != .deleteSecret
  }

  package var requiresDeletionReview: Bool {
    hasUnverifiedAccount && kind == .deleteSecret
  }
}

/// Resumable version-1 label migration state (§9).
public struct LegacyMigrationState: Hashable, Sendable, Codable {
  /// One stable UUID per distinct label, persisted before any Keychain
  /// write so a rerun reuses it.
  public var labelMap: [String: UUID] = [:]
  /// Legacy items to delete after their replacements are committed.
  public var pendingCleanup: [String] = []
  /// Labels whose legacy item was absent: hosts keep `.legacyKey`.
  public var unresolved: [String] = []
  /// Every referenced label has been processed (or recorded unresolved).
  public var completed = true

  package init() {}
}

/// Opt-in synchronization choices (§4.3). Both off by default.
public struct SyncSettings: Hashable, Sendable, Codable {
  public var metadataSync = false
  public var trustSync = false

  package init() {}
}

/// One queued record, coalesced per entity (§8.2).
public struct OutboxEntry: Hashable, Sendable, Codable {
  public var recordName: String
  /// The local revision this entry asks the server to reach. An
  /// acknowledgment removes the entry only for exactly this revision.
  public var revision: LogicalRevision

  package init(
    recordName: String,
    revision: LogicalRevision
  ) {
    self.recordName = recordName
    self.revision = revision
  }
}

/// Cached server state for one CloudKit account (§8.4). Never published to
/// another account.
public struct AccountPartition: Hashable, Sendable, Codable {
  /// The user confirmed publishing local data to this account.
  public var consented = false
  public var changeToken: Data?
  /// Encoded CKRecord system fields (change tags) by record name.
  public var systemFields: [String: Data] = [:]
  public var outbox: [String: OutboxEntry] = [:]
  /// The last revision the server acknowledged or delivered, per record.
  public var synced: [String: LogicalRevision] = [:]
  /// Each host's tuple as last agreed with the server, for detecting
  /// concurrent tuple edits.
  public var hostBases: [UUID: ConnectionTuple] = [:]
  /// Valid records this build cannot interpret, kept verbatim (bounded).
  public var opaque: [String: Data] = [:]
  /// Malformed records by name, with a reason. Never applied.
  public var quarantine: [String: String] = [:]
  public var zoneReady = false
  /// The zone vanished; recovery needs explicit user action.
  public var zoneLost = false
  public var lastError: String?
  public var retryAt: Date?
  public var attempts = 0
  /// Records displaced from the working set by another account's same-name
  /// record. Optional for migration from the version-2 snapshot.
  package var cachedRecords: [String: CachedConnectionRecord]?
  /// Account-local profile order, retained while records are displaced.
  package var hostOrder: [UUID]?

  package init() {}
}

/// Every non-secret piece of connection state, committed atomically as one
/// file (§5). Private keys, passwords and passphrases never appear here.
public struct ConnectionSnapshot: Hashable, Sendable, Codable {
  public static let version = 4

  public var version = Self.version
  /// Random per installation; the tie-breaker in logical revisions.
  public var deviceID = UUID()
  public var clock: UInt64 = 0
  /// Live hosts in list order, including ones hidden by account scope.
  public var hosts: [HostProfile] = []
  public var hostRevisions: [UUID: LogicalRevision] = [:]
  public var hostTombstones: [UUID: HostTombstone] = [:]
  public var hostConflicts: [UUID: HostConflict] = [:]
  /// Live and tombstoned identities.
  public var identities: [SSHIdentityMetadata] = []
  /// Same-UUID records with different key material, quarantined.
  public var identityConflicts: [UUID: SSHIdentityMetadata] = [:]
  public var knownHosts: [String: KnownHostRecord] = [:]
  public var trustReviews: [String: TrustReview] = [:]
  /// Fetched trust records committed with their page, applied to the
  /// local trust store afterwards so a failed write is retried, not lost.
  public var trustInbox: [String: KnownHostRecord] = [:]
  public var intents: [IdentityIntent] = []
  public var migration = LegacyMigrationState()
  public var settings = SyncSettings()
  public var accounts: [String: AccountPartition] = [:]
  /// The CloudKit account local data is currently bound to, if any.
  public var boundAccount: String?
  /// Last verified Keychain account, independent of metadata upload consent.
  /// Cleared on an account-change notification and refreshed before recovery.
  public var verifiedKeychainAccount: String?
  /// Older local iCloud metadata whose owning account was never saved.
  /// Explicit fingerprint/account review is required before use or upload.
  package var unverifiedKeychainIdentities: Set<UUID>?
  /// Record name → owning account. iCloud identities acquire ownership when
  /// created, independently of metadata sync; other records acquire it when
  /// published or received. Absent means local-only or awaiting account review.
  public var scopes: [String: String] = [:]

  public init() {}

  // MARK: Record names

  public static func hostRecord(_ id: UUID) -> String {
    "host-" + id.uuidString.lowercased()
  }

  public static func identityRecord(_ id: UUID) -> String {
    "identity-" + id.uuidString.lowercased()
  }

  /// Versioned canonical endpoint: lowercase DNS name or address literal
  /// without brackets, then the port. Aliases are never resolved.
  public static func knownHostRecord(host: String, port: Int) -> String {
    var name = host.lowercased()
    if name.hasPrefix("["), name.hasSuffix("]") {
      name = String(name.dropFirst().dropLast())
    }
    let canonical = "v1|\(name)|\(port)"
    let digest = SHA256.hash(data: Data(canonical.utf8))
    return "knownhost-v1-" + digest.map { String(format: "%02x", $0) }.joined()
  }

  // MARK: Scope

  /// Whether `recordName` belongs to local-only data or the bound account.
  public func isVisible(_ recordName: String) -> Bool {
    if recordName.hasPrefix("identity-"),
      let id = UUID(uuidString: String(recordName.dropFirst(9)))
    {
      if unverifiedKeychainIdentities?.contains(id) == true { return false }
      if identity(id)?.storage == .iCloudKeychain,
        let scope = scopes[recordName]
      {
        return scope == (verifiedKeychainAccount ?? boundAccount)
      }
    }
    guard let scope = scopes[recordName] else { return true }
    return scope == boundAccount
  }

  public var visibleHosts: [HostProfile] {
    hosts.filter { isVisible(Self.hostRecord($0.id)) }
  }

  public var visibleIdentities: [SSHIdentityMetadata] {
    identities.filter { !$0.isDeleted && isVisible(Self.identityRecord($0.id)) }
  }

  /// Entities hidden because they belong to another iCloud account.
  public var hiddenCount: Int {
    hosts.count(where: { !isVisible(Self.hostRecord($0.id)) })
      + identities.count(where: {
        !$0.isDeleted && !isVisible(Self.identityRecord($0.id))
      }) + cachedHosts.count + cachedIdentities.count(where: { !$0.isDeleted })
  }

  public func identity(_ id: UUID) -> SSHIdentityMetadata? {
    identities.first { $0.id == id }
  }

  // MARK: Revisions

  /// The next local revision, past every revision observed so far.
  public mutating func tick() -> LogicalRevision {
    clock += 1
    return LogicalRevision(counter: clock, deviceID: deviceID)
  }

  public mutating func observe(_ revision: LogicalRevision) {
    clock = max(clock, revision.counter)
  }

  /// Queues `recordName` for the account it belongs to. Local-only data is
  /// bound to the current account only while metadata sync is on and that
  /// account has consented.
  public mutating func enqueue(_ recordName: String, revision: LogicalRevision)
  {
    let account: String
    if let scope = scopes[recordName] {
      account = scope
    } else if settings.metadataSync, let bound = boundAccount,
      accounts[bound]?.consented == true
    {
      account = bound
      scopes[recordName] = bound
    } else {
      return
    }
    accounts[account, default: AccountPartition()].outbox[recordName] =
      OutboxEntry(recordName: recordName, revision: revision)
  }

  // MARK: Hosts

  /// Adds or replaces a host (matched by id), keeping list order.
  public mutating func upsertHost(_ host: HostProfile) {
    guard hostTombstones[host.id] == nil else { return }
    if let index = hosts.firstIndex(where: { $0.id == host.id }) {
      guard hosts[index] != host else { return }
      hosts[index] = host
    } else {
      hosts.append(host)
    }
    let revision = tick()
    hostRevisions[host.id] = revision
    hostConflicts[host.id] = nil
    enqueue(Self.hostRecord(host.id), revision: revision)
  }

  public mutating func deleteHost(_ id: UUID) {
    guard hosts.contains(where: { $0.id == id }) else { return }
    hosts.removeAll { $0.id == id }
    let revision = tick()
    hostRevisions[id] = revision
    hostTombstones[id] = HostTombstone(revision: revision, deletedAt: .now)
    hostConflicts[id] = nil
    enqueue(Self.hostRecord(id), revision: revision)
  }

  /// Replaces the visible host list, as a version-1 style save does.
  public mutating func replaceVisibleHosts(_ next: [HostProfile]) {
    let keep = Set(next.map(\.id))
    for host in visibleHosts where !keep.contains(host.id) {
      deleteHost(host.id)
    }
    for host in next { upsertHost(host) }
    // Keep the caller's order for visible hosts; hidden ones stay after.
    let hidden = hosts.filter { !isVisible(Self.hostRecord($0.id)) }
    let byID = Dictionary(hosts.map { ($0.id, $0) }) { first, _ in first }
    hosts = next.compactMap { byID[$0.id] } + hidden
  }

  // MARK: Identities

  public mutating func insertIdentity(_ metadata: SSHIdentityMetadata) {
    guard identity(metadata.id) == nil else { return }
    var metadata = metadata
    let revision = tick()
    metadata.revision = revision
    identities.append(metadata)
    enqueue(Self.identityRecord(metadata.id), revision: revision)
  }

  public mutating func renameIdentity(_ id: UUID, to name: String) {
    guard let index = identities.firstIndex(where: { $0.id == id }),
      !identities[index].isDeleted, identities[index].name != name
    else { return }
    let revision = tick()
    identities[index].name = name
    identities[index].revision = revision
    enqueue(Self.identityRecord(id), revision: revision)
  }

  public mutating func tombstoneIdentity(_ id: UUID) {
    guard let index = identities.firstIndex(where: { $0.id == id }),
      !identities[index].isDeleted
    else { return }
    let revision = tick()
    identities[index].deletedAt = .now
    identities[index].revision = revision
    enqueue(Self.identityRecord(id), revision: revision)
  }

  /// Hosts whose sign-in names `id`.
  public func hosts(using id: UUID) -> [HostProfile] {
    hosts.filter { $0.auth.identityID == id }
  }

  // MARK: Known hosts

  public mutating func recordLocalTrust(
    host: String,
    port: Int,
    publicKey: String,
    fingerprint: String
  ) {
    let name = Self.knownHostRecord(host: host, port: port)
    if let existing = knownHosts[name], existing.deletedAt == nil,
      existing.publicKey == publicKey
    {
      return
    }
    if let account = boundAccount { activateRecord(name, for: account) }
    let revision = tick()
    knownHosts[name] = KnownHostRecord(
      host: host.lowercased(),
      port: port,
      publicKey: publicKey,
      fingerprint: fingerprint,
      provenance: .local,
      revision: revision,
      deletedAt: nil
    )
    trustReviews[name] = nil
    if settings.trustSync { enqueue(name, revision: revision) }
  }

  public mutating func recordLocalTrustRemoval(host: String, port: Int) {
    let name = Self.knownHostRecord(host: host, port: port)
    guard var record = knownHosts[name], record.deletedAt == nil else { return }
    let revision = tick()
    record.deletedAt = .now
    record.revision = revision
    knownHosts[name] = record
    if settings.trustSync { enqueue(name, revision: revision) }
  }
}

/// Atomic file storage for `ConnectionSnapshot` (§5): one file, written
/// with a retained previous copy. Holds no secrets; still written with
/// complete file protection where the platform provides it.
///
/// Version 1 (`{"version":1,"hosts":[…]}`) is read for migration only and
/// its original bytes are kept as `hosts.v1.json` before the first upgraded
/// write. Version 2 upgrades without changing its records. Version 3 keeps
/// colliding account records; older builds reject it when loading.
public struct ConnectionStore: Sendable {
  public enum StoreError: Error, Hashable, Sendable {
    case tooLarge
    case unsupportedVersion(Int)
    case malformed
    case tooManyHosts
    case tooManyIdentities
    case tooManyTrustEntries
    case invalidHost(UUID)
    case duplicateHost(UUID)
    case invalidIdentity(UUID)
    case io(String)
  }

  public static let maxHosts = 256
  public static let maxIdentities = 256
  public static let maxTrustEntries = 1024
  public static let maxFileBytes = 16 << 20

  public let fileURL: URL

  public init(fileURL: URL) { self.fileURL = fileURL }

  /// `Application Support/Swiftty/hosts.json`. tvOS offers no durable
  /// local storage to apps, so there the list lives in Caches and may be
  /// purged by the system (spec §2.3: no durable local file workflow).
  public static func defaultURL() -> URL {
    RoamingStorage.directory.appending(
      path: "hosts.json",
      directoryHint: .notDirectory
    )
  }

  /// The previous committed snapshot, kept for recovery.
  public var previousURL: URL {
    fileURL.deletingPathExtension().appendingPathExtension("previous.json")
  }

  /// The original version-1 file, kept after migration.
  public var legacyURL: URL {
    fileURL.deletingPathExtension().appendingPathExtension("v1.json")
  }

  /// The committed snapshot. A missing file is an empty store; an
  /// unreadable one is an error, never defaults.
  public func loadSnapshot() throws(StoreError) -> ConnectionSnapshot {
    guard let data = try read(fileURL) else { return ConnectionSnapshot() }
    return try Self.decode(data)
  }

  /// Visible hosts, for callers that only need the list.
  public func load() throws(StoreError) -> [HostProfile] {
    try loadSnapshot().visibleHosts
  }

  /// Replaces the visible hosts, keeping every other part of the snapshot.
  public func save(_ hosts: [HostProfile]) throws(StoreError) {
    var snapshot = try loadSnapshot()
    try Self.validateHosts(hosts)
    snapshot.replaceVisibleHosts(hosts)
    try commit(snapshot)
  }

  /// Validates and atomically writes `snapshot`, keeping the replaced file
  /// as the previous copy and, once, the original version-1 bytes.
  public func commit(_ snapshot: ConnectionSnapshot) throws(StoreError) {
    let data = try Self.encode(snapshot)
    do {
      let manager = FileManager.default
      try manager.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      if let existing = try read(fileURL) {
        _ = try Self.decode(existing)
        if Self.version(of: existing) == 1,
          !manager.fileExists(atPath: legacyURL.path)
        {
          try write(existing, to: legacyURL)
        }
        try write(existing, to: previousURL)
      }
      try write(data, to: fileURL)
    } catch let error as StoreError { throw error } catch {
      throw .io(String(describing: type(of: error)))
    }
  }

  /// The previous committed snapshot, when the current file is damaged.
  public func loadPrevious() throws(StoreError) -> ConnectionSnapshot? {
    guard let data = try read(previousURL) else { return nil }
    return try Self.decode(data)
  }

  private func read(_ url: URL) throws(StoreError) -> Data? {
    do {
      return try BoundedFile.readIfPresent(url, limit: Self.maxFileBytes)
    } catch BoundedFile.ReadError.tooLarge { throw .tooLarge } catch {
      throw .io(String(describing: type(of: error)))
    }
  }

  private func write(_ data: Data, to url: URL) throws {
    #if os(iOS) || os(visionOS)
    try data.write(to: url, options: [.atomic, .completeFileProtection])
    #else
    try data.write(to: url, options: [.atomic])
    #endif
  }

  // MARK: Coding

  package struct VersionProbe: Decodable { var version: Int }

  package static func version(of data: Data) -> Int? {
    (try? JSONDecoder().decode(VersionProbe.self, from: data))?.version
  }

  package static func validateHosts(_ hosts: [HostProfile]) throws(StoreError) {
    guard hosts.count <= maxHosts else { throw .tooManyHosts }
    var ids: Set<UUID> = []
    for host in hosts {
      guard host.isValid else { throw .invalidHost(host.id) }
      guard ids.insert(host.id).inserted else { throw .duplicateHost(host.id) }
    }
  }

  package static func encode(_ snapshot: ConnectionSnapshot) throws(StoreError) -> Data
  {
    try validateHosts(snapshot.hosts)
    try validateCounts(snapshot)
    for host in snapshot.cachedHosts where !host.isValid {
      throw .invalidHost(host.id)
    }
    let identities = snapshot.identities + snapshot.cachedIdentities
    for identity in identities where !identity.isValid {
      throw .invalidIdentity(identity.id)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [
      .prettyPrinted, .sortedKeys, .withoutEscapingSlashes,
    ]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(snapshot) else { throw .malformed }
    guard data.count <= maxFileBytes else { throw .tooLarge }
    return data
  }

  /// The read and write limits include hidden account caches. Tombstones
  /// remain bounded by file size, not by the live-entity allowance.
  private static func validateCounts(
    _ snapshot: ConnectionSnapshot
  ) throws(StoreError) {
    guard snapshot.hosts.count + snapshot.cachedHosts.count <= maxHosts else {
      throw .tooManyHosts
    }
    guard
      snapshot.identities.count(where: { !$0.isDeleted })
        + snapshot.cachedIdentities.count(where: { !$0.isDeleted })
        <= maxIdentities
    else { throw .tooManyIdentities }
    guard
      snapshot.knownHosts.count(where: { $0.value.deletedAt == nil })
        + snapshot.cachedKnownHosts.count(where: { $0.deletedAt == nil })
        <= maxTrustEntries
    else { throw .tooManyTrustEntries }
  }

  package static func decode(_ data: Data) throws(StoreError) -> ConnectionSnapshot {
    guard data.count <= maxFileBytes else { throw .tooLarge }
    guard let version = version(of: data) else { throw .malformed }
    switch version {
    case 1: return migrated(try HostProfileStore.decode(data))
    case 2, 3, ConnectionSnapshot.version:
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      guard
        let snapshot = try? decoder.decode(ConnectionSnapshot.self, from: data)
      else { throw .malformed }
      try validateCounts(snapshot)
      // Hand-edited duplicates or invalid entries are skipped, as in v1;
      // everything else must be valid.
      var ids: Set<UUID> = []
      var clean = snapshot
      clean.version = ConnectionSnapshot.version
      if version < 4 {
        let unverified = snapshot.identities
          .filter {
            $0.storage == .iCloudKeychain && !$0.isDeleted
              && snapshot.scopes[ConnectionSnapshot.identityRecord($0.id)]
                == nil
          }
          .map(\.id)
        if !unverified.isEmpty {
          clean.unverifiedKeychainIdentities = Set(unverified)
        }
      }
      if version == 2 {
        for index in clean.intents.indices {
          clean.intents[index].account =
            snapshot.scopes[
              ConnectionSnapshot.identityRecord(clean.intents[index].identityID)
            ] ?? snapshot.boundAccount
        }
      }
      clean.hosts = snapshot.hosts.filter {
        $0.isValid && ids.insert($0.id).inserted
      }
      guard
        (snapshot.identities + snapshot.cachedIdentities).allSatisfy(\.isValid),
        snapshot.cachedHosts.allSatisfy(\.isValid),
        snapshot.accounts.values.allSatisfy({ partition in
          partition.cachedRecords?.allSatisfy { $0.value.matches(name: $0.key) }
            ?? true
        })
      else { throw .malformed }
      return clean
    default: throw .unsupportedVersion(version)
    }
  }

  /// A version-1 host list as a snapshot awaiting label migration. Host
  /// UUIDs, endpoints, names and password selection are preserved.
  package static func migrated(_ hosts: [HostProfile]) -> ConnectionSnapshot {
    var snapshot = ConnectionSnapshot()
    snapshot.hosts = hosts
    for host in hosts { snapshot.hostRevisions[host.id] = snapshot.tick() }
    let labels = hosts.compactMap {
      if case .legacyKey(let label) = $0.auth { return label }
      return nil
    }
    snapshot.migration.completed = labels.isEmpty
    return snapshot
  }
}
