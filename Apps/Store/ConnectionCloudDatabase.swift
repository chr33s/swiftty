import Foundation
import SSHClient
import SSHIdentity

/// A CloudKit field value, independent of CloudKit for testability.
public enum CloudValue: Hashable, Sendable, Codable {
  case string(String)
  case int(Int64)
  case date(Date)
  case bytes(Data)

  package var string: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  package var int: Int64? {
    if case .int(let value) = self { return value }
    return nil
  }

  package var date: Date? {
    if case .date(let value) = self { return value }
    return nil
  }
}

/// One record in the private `SwifttyConnectionsV1` zone.
public struct CloudRecord: Hashable, Sendable, Codable {
  public var name: String
  public var type: String
  public var fields: [String: CloudValue]
  /// Opaque server system fields, carrying the change tag. `nil` only for
  /// a record this device has never seen on the server.
  public var systemFields: Data?

  public init(
    name: String,
    type: String,
    fields: [String: CloudValue],
    systemFields: Data? = nil
  ) {
    self.name = name
    self.type = type
    self.fields = fields
    self.systemFields = systemFields
  }
}

/// Sync outcomes the coordinator distinguishes (§8.2).
public enum CloudSyncError: Error, Hashable, Sendable {
  case accountRequired
  case accountTemporarilyUnavailable
  case networkUnavailable
  /// Transient: retry after the server's hint, or with backoff.
  case retryAfter(TimeInterval?)
  /// The server holds a newer version of the record.
  case conflict(CloudRecord)
  case quotaExceeded
  case zoneNotFound
  /// The record was deleted on the server; resend it as new.
  case recordMissing
  case changeTokenExpired
  /// Missing entitlement, bad container or permission failure.
  case permissionFailure
  /// The local consent preference could not be persisted.
  case settingsNotSaved
  /// Schema or validation rejection.
  case invalidRecord(String)
  case other(Int)

  /// Errors that leave work queued and are retried automatically.
  package var isTransient: Bool {
    switch self {
    case .networkUnavailable, .retryAfter, .accountTemporarilyUnavailable: true
    default: false
    }
  }

  package var message: String {
    switch self {
    case .accountRequired: "Sign in to iCloud to sync."
    case .accountTemporarilyUnavailable: "iCloud is temporarily unavailable."
    case .networkUnavailable: "Offline."
    case .retryAfter: "iCloud is busy; retrying."
    case .conflict: "A newer change is on iCloud."
    case .quotaExceeded: "iCloud storage is full."
    case .zoneNotFound: "Synced data was removed from iCloud."
    case .recordMissing: "A synced record was removed from iCloud."
    case .changeTokenExpired: "Refetching from iCloud."
    case .permissionFailure: "This build is not configured for iCloud sync."
    case .settingsNotSaved:
      "Sync settings could not be saved. Check storage and try again before closing the app."
    case .invalidRecord(let reason): "iCloud rejected a record (\(reason))."
    case .other(let code): "iCloud error \(code)."
    }
  }
}

/// One page of zone changes and the checkpoint after it.
public struct CloudChangePage: Sendable {
  public var changed: [CloudRecord]
  public var deleted: [String]
  public var token: Data?
  public var moreComing: Bool

  public init(
    changed: [CloudRecord],
    deleted: [String],
    token: Data?,
    moreComing: Bool
  ) {
    self.changed = changed
    self.deleted = deleted
    self.token = token
    self.moreComing = moreComing
  }
}

/// The private-database operations sync needs. `CloudKitConnectionDatabase`
/// is the CloudKit implementation; tests substitute an in-memory server.
/// None of these calls can read Keychain secrets.
public protocol ConnectionCloudDatabase: Sendable {
  /// A stable, opaque identifier for the signed-in account.
  func accountID() async throws(CloudSyncError) -> String
  /// Creates the zone. Called only for a zone never seen, or after the
  /// user explicitly chose to recover a lost zone.
  func createZone() async throws(CloudSyncError)
  func fetchChanges(
    since token: Data?
  ) async throws(CloudSyncError) -> CloudChangePage
  /// Saves only if each record's change tag still matches the server.
  /// Results are per record; a conflict carries the server's record.
  func save(
    _ records: [CloudRecord]
  ) async throws(CloudSyncError) -> [String: Result<
    CloudRecord, CloudSyncError
  >]
}

/// Record encoding for the three v1 record types (§8.1).
package enum ConnectionRecords {
  package static let host = "SwifttyHostProfileV1"
  package static let identity = "SwifttySSHIdentityV1"
  package static let knownHost = "SwifttyKnownHostV1"
  package static let schema: Int64 = 1
  /// Bounds on kept-but-unreadable records.
  package static let maxOpaqueRecords = 1024
  package static let maxOpaqueBytes = 64 * 1024

  package enum DecodeResult<Value> {
    case value(Value)
    /// Valid, but from a newer schema: kept verbatim.
    case unsupported
    case malformed(String)
  }

  /// Every field a v1 record type may carry.
  package static func fieldNames(_ type: String) -> Set<String> {
    let common: Set = [
      "schema", "revCounter", "revDevice", "deleted", "deletedAt",
    ]
    switch type {
    case host:
      return common.union([
        "id", "nickname", "host", "port", "username", "authType", "identity",
        "authRaw",
      ])
    case identity:
      return common.union([
        "id", "name", "algorithm", "publicKey", "fingerprint", "storage",
        "createdAt",
      ])
    case knownHost:
      return common.union([
        "host", "port", "algorithm", "publicKey", "fingerprint",
        "provenanceDevice",
      ])
    default: return common
    }
  }

  // MARK: Revision and tombstone fields

  package static func revisionFields(
    _ revision: LogicalRevision,
    deletedAt: Date?
  ) -> [String: CloudValue] {
    var fields: [String: CloudValue] = [
      "schema": .int(schema),
      "revCounter": .int(Int64(clamping: revision.counter)),
      "revDevice": .string(revision.deviceID.uuidString),
      "deleted": .int(deletedAt == nil ? 0 : 1),
    ]
    if let deletedAt { fields["deletedAt"] = .date(deletedAt) }
    return fields
  }

  package static func revision(_ fields: [String: CloudValue]) -> LogicalRevision? {
    guard let counter = fields["revCounter"]?.int, counter >= 0,
      let device = fields["revDevice"]?.string.flatMap(UUID.init(uuidString:))
    else { return nil }
    return LogicalRevision(counter: UInt64(counter), deviceID: device)
  }

  package static func deletedAt(_ fields: [String: CloudValue]) -> Date?? {
    switch fields["deleted"]?.int {
    case 0: .some(nil)
    case 1: .some(fields["deletedAt"]?.date ?? Date(timeIntervalSince1970: 0))
    default: nil
    }
  }

  package static func schemaCheck<T>(_ fields: [String: CloudValue]) -> DecodeResult<T>?
  {
    guard let version = fields["schema"]?.int else {
      return .malformed("schema")
    }
    return version > schema ? .unsupported : nil
  }

  // MARK: Hosts

  package struct RemoteHost {
    package var profile: HostProfile
    package var revision: LogicalRevision
    package var deletedAt: Date?

    package init(
      profile: HostProfile,
      revision: LogicalRevision,
      deletedAt: Date? = nil
    ) {
      self.profile = profile
      self.revision = revision
      self.deletedAt = deletedAt
    }
  }

  package static func encode(
    host: HostProfile?,
    id: UUID,
    revision: LogicalRevision,
    tombstone: HostTombstone?
  ) -> [String: CloudValue]? {
    var fields = revisionFields(revision, deletedAt: tombstone?.deletedAt)
    fields["id"] = .string(id.uuidString)
    guard let host else { return tombstone == nil ? nil : fields }
    fields["nickname"] = .string(host.nickname)
    fields["host"] = .string(host.host)
    fields["port"] = .int(Int64(host.port))
    fields["username"] = .string(host.username)
    switch host.auth {
    case .password: fields["authType"] = .string("password")
    case .key(let identity):
      fields["authType"] = .string("key")
      fields["identity"] = .string(identity.uuidString)
    case .unsupported(let raw):
      guard let data = try? JSONEncoder().encode(raw) else { return nil }
      fields["authType"] = .string("other")
      fields["authRaw"] = .bytes(data)
    // An unresolved version-1 label is never published (§9 step 5).
    case .legacyKey: return nil
    }
    return fields
  }

  package static func decodeHost(_ record: CloudRecord) -> DecodeResult<RemoteHost> {
    let f = record.fields
    if let check: DecodeResult<RemoteHost> = schemaCheck(f) { return check }
    guard let id = f["id"]?.string.flatMap(UUID.init(uuidString:)),
      record.name == ConnectionSnapshot.hostRecord(id)
    else { return .malformed("id") }
    guard let revision = revision(f) else { return .malformed("revision") }
    guard let deleted = deletedAt(f) else { return .malformed("deleted") }
    if let deletedAt = deleted {
      // Tombstones keep only identity and revision.
      let placeholder = HostProfile(
        id: id,
        nickname: "-",
        host: "-",
        username: "-"
      )
      return .value(
        RemoteHost(
          profile: placeholder,
          revision: revision,
          deletedAt: deletedAt
        )
      )
    }
    let auth: AuthMethodReference
    switch f["authType"]?.string {
    case "password": auth = .password
    case "key":
      guard let identity = f["identity"]?.string.flatMap(UUID.init(uuidString:))
      else { return .malformed("identity") }
      auth = .key(identityID: identity)
    case "other":
      guard case .bytes(let data)? = f["authRaw"],
        let raw = try? JSONDecoder().decode(JSONValue.self, from: data)
      else { return .malformed("authRaw") }
      auth = .unsupported(raw)
    default: return .malformed("authType")
    }
    guard let nickname = f["nickname"]?.string, let host = f["host"]?.string,
      let port = f["port"]?.int, let username = f["username"]?.string
    else { return .malformed("fields") }
    let profile = HostProfile(
      id: id,
      nickname: nickname,
      host: host,
      port: Int(clamping: port),
      username: username,
      auth: auth
    )
    guard profile.isValid else { return .malformed("validation") }
    return .value(
      RemoteHost(profile: profile, revision: revision, deletedAt: nil)
    )
  }

  // MARK: Identities

  package static func encode(identity: SSHIdentityMetadata) -> [String: CloudValue] {
    var fields = revisionFields(
      identity.revision,
      deletedAt: identity.deletedAt
    )
    fields["id"] = .string(identity.id.uuidString)
    fields["name"] = .string(identity.name)
    fields["algorithm"] = .string(identity.algorithm)
    fields["publicKey"] = .string(identity.publicKey)
    fields["fingerprint"] = .string(identity.fingerprint)
    fields["storage"] = .string(identity.storage.rawValue)
    fields["createdAt"] = .date(identity.createdAt)
    return fields
  }

  package static func decodeIdentity(
    _ record: CloudRecord
  ) -> DecodeResult<SSHIdentityMetadata> {
    let f = record.fields
    if let check: DecodeResult<SSHIdentityMetadata> = schemaCheck(f) {
      return check
    }
    guard let id = f["id"]?.string.flatMap(UUID.init(uuidString:)),
      record.name == ConnectionSnapshot.identityRecord(id)
    else { return .malformed("id") }
    guard let revision = revision(f), let deleted = deletedAt(f),
      let name = f["name"]?.string, let algorithm = f["algorithm"]?.string,
      let publicKey = f["publicKey"]?.string,
      let fingerprint = f["fingerprint"]?.string,
      let storage = f["storage"]?.string.flatMap(IdentityStoragePolicy.init),
      let createdAt = f["createdAt"]?.date
    else { return .malformed("fields") }
    if algorithm != SSHIdentityMetadata.algorithm { return .unsupported }
    let metadata = SSHIdentityMetadata(
      id: id,
      name: name,
      algorithm: algorithm,
      publicKey: publicKey,
      fingerprint: fingerprint,
      storage: storage,
      createdAt: createdAt,
      revision: revision,
      deletedAt: deleted
    )
    guard metadata.isValid else { return .malformed("validation") }
    return .value(metadata)
  }

  // MARK: Known hosts

  package static func encode(knownHost: KnownHostRecord) -> [String: CloudValue] {
    var fields = revisionFields(
      knownHost.revision,
      deletedAt: knownHost.deletedAt
    )
    fields["host"] = .string(knownHost.host)
    fields["port"] = .int(Int64(knownHost.port))
    fields["algorithm"] = .string(
      SSHPublicKeyFormat.keyType(openSSHPublicKey: knownHost.publicKey)
    )
    fields["publicKey"] = .string(knownHost.publicKey)
    fields["fingerprint"] = .string(knownHost.fingerprint)
    if case .synced(let device) = knownHost.provenance {
      fields["provenanceDevice"] = .string(device.uuidString)
    } else {
      fields["provenanceDevice"] = .string(
        knownHost.revision.deviceID.uuidString
      )
    }
    return fields
  }

  package static func decodeKnownHost(
    _ record: CloudRecord
  ) -> DecodeResult<KnownHostRecord> {
    let f = record.fields
    if let check: DecodeResult<KnownHostRecord> = schemaCheck(f) {
      return check
    }
    guard let revision = revision(f), let deleted = deletedAt(f),
      let host = f["host"]?.string, let port = f["port"]?.int,
      let publicKey = f["publicKey"]?.string,
      let fingerprint = f["fingerprint"]?.string,
      let device = f["provenanceDevice"]?.string.flatMap(UUID.init(uuidString:))
    else { return .malformed("fields") }
    guard (1 ... 65_535).contains(port),
      record.name
        == ConnectionSnapshot.knownHostRecord(host: host, port: Int(port)),
      SSHPublicKeyFormat.fingerprint(openSSHPublicKey: publicKey) == fingerprint
    else { return .malformed("validation") }
    return .value(
      KnownHostRecord(
        host: host,
        port: Int(port),
        publicKey: publicKey,
        fingerprint: fingerprint,
        provenance: .synced(deviceID: device),
        revision: revision,
        deletedAt: deleted
      )
    )
  }
}
