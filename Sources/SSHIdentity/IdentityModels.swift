import Crypto
import Foundation
import SSHClient

/// Where an identity's private key lives (spec.ssh-identity.md §7.1).
/// Chosen at generation or import and immutable for that UUID in v1: a
/// different policy is a different identity.
public enum IdentityStoragePolicy: String, Hashable, Sendable, Codable,
  CaseIterable
{
  /// Not synchronized; `WhenUnlockedThisDeviceOnly`. The default.
  case deviceOnly
  /// Synchronizable through iCloud Keychain; `WhenUnlocked`.
  case iCloudKeychain
  /// A P-256 key generated inside this device's Secure Enclave (§13.2).
  /// Its private half never leaves the device; only an encrypted handle is
  /// stored, device-only, in the Keychain.
  case secureEnclave

  /// Policies a software (generated or imported) key may choose.
  public static let softwareCases: [Self] = [.deviceOnly, .iCloudKeychain]

  /// Whether the private key can exist only on the device that made it.
  public var isDeviceBound: Bool { self != .iCloudKeychain }

  public var displayName: LocalizedStringResource {
    switch self {
    case .deviceOnly:
      LocalizedStringResource("This device only", bundle: #bundle)
    case .iCloudKeychain:
      LocalizedStringResource("iCloud Keychain", bundle: #bundle)
    case .secureEnclave:
      LocalizedStringResource("Secure Enclave", bundle: #bundle)
    }
  }
}

/// A deterministic logical clock for non-security metadata conflicts
/// (§8.3): ordered by counter, then by device. Counters advance past every
/// observed revision, so wall-clock skew never decides a merge.
public struct LogicalRevision: Hashable, Sendable, Codable, Comparable {
  public var counter: UInt64
  public var deviceID: UUID

  public init(counter: UInt64, deviceID: UUID) {
    self.counter = counter
    self.deviceID = deviceID
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
    return lhs.deviceID.uuidString < rhs.deviceID.uuidString
  }
}

/// Public, non-secret description of one SSH identity (§5). Never holds
/// private bytes or Keychain persistent references, so it may be written to
/// local snapshots and, when the user opts in, CloudKit.
public struct SSHIdentityMetadata: Hashable, Sendable, Codable, Identifiable {
  public enum ValidationError: Error, Hashable, Sendable {
    case invalidName
    case unsupportedAlgorithm
    case invalidPublicKey
    case fingerprintMismatch
  }

  /// The Ed25519 algorithm name, the default for new identities.
  public static let algorithm = SSHKeyAlgorithm.ed25519.rawValue
  public static let maxNameLength = 64

  public let id: UUID
  public var name: String
  /// An `SSHKeyAlgorithm` raw value, such as `ssh-ed25519`.
  public let algorithm: String
  /// Canonical `"<type> <base64>"` line, without a comment.
  public let publicKey: String
  /// OpenSSH `SHA256:` fingerprint of `publicKey`.
  public let fingerprint: String
  public let storage: IdentityStoragePolicy
  public let createdAt: Date
  public var revision: LogicalRevision
  /// Set once deleted; a tombstone is never revived (§8.3).
  public var deletedAt: Date?

  public init(
    id: UUID = UUID(),
    name: String,
    publicKey: Curve25519.Signing.PublicKey,
    storage: IdentityStoragePolicy,
    createdAt: Date = .now,
    revision: LogicalRevision,
    deletedAt: Date? = nil
  ) {
    self.init(
      id: id,
      name: name,
      algorithm: Self.algorithm,
      publicKey: SSHEd25519Key.authorizedKeysLine(for: publicKey),
      fingerprint: SSHEd25519Key.fingerprint(of: publicKey),
      storage: storage,
      createdAt: createdAt,
      revision: revision,
      deletedAt: deletedAt
    )
  }

  /// Metadata for any supported key, from its canonical public-key line
  /// (`IdentitySecret.publicKeyLine`). Callers must `validate()`.
  public init(
    id: UUID = UUID(),
    name: String,
    publicKeyLine: String,
    storage: IdentityStoragePolicy,
    createdAt: Date = .now,
    revision: LogicalRevision,
    deletedAt: Date? = nil
  ) {
    self.init(
      id: id,
      name: name,
      algorithm: SSHPublicKeyFormat.keyType(openSSHPublicKey: publicKeyLine),
      publicKey: publicKeyLine,
      fingerprint: SSHPublicKeyFormat.fingerprint(
        openSSHPublicKey: publicKeyLine
      ) ?? "",
      storage: storage,
      createdAt: createdAt,
      revision: revision,
      deletedAt: deletedAt
    )
  }

  /// Decoding entry point for records read from disk or CloudKit; callers
  /// must `validate()` before use.
  public init(
    id: UUID,
    name: String,
    algorithm: String,
    publicKey: String,
    fingerprint: String,
    storage: IdentityStoragePolicy,
    createdAt: Date,
    revision: LogicalRevision,
    deletedAt: Date?
  ) {
    self.id = id
    self.name = name
    self.algorithm = algorithm
    self.publicKey = publicKey
    self.fingerprint = fingerprint
    self.storage = storage
    self.createdAt = createdAt
    self.revision = revision
    self.deletedAt = deletedAt
  }

  public var isDeleted: Bool { deletedAt != nil }

  /// The Ed25519 public key named by `publicKey`, if well formed.
  public var ed25519PublicKey: Curve25519.Signing.PublicKey? {
    guard let blob = SSHPublicKeyFormat.keyBlob(openSSHPublicKey: publicKey)
    else { return nil }
    return Self.ed25519Key(blob: blob)
  }

  /// The key in a canonical `ssh-ed25519 <base64>` line (no comment).
  public static func ed25519PublicKey(
    line: String
  ) -> Curve25519.Signing.PublicKey? {
    guard line.split(separator: " ").count == 2,
      let blob = SSHPublicKeyFormat.keyBlob(openSSHPublicKey: line),
      let key = ed25519Key(blob: blob),
      SSHEd25519Key.authorizedKeysLine(for: key) == line
    else { return nil }
    return key
  }

  /// The parsed algorithm, if supported.
  public var keyAlgorithm: SSHKeyAlgorithm? {
    SSHKeyAlgorithm(rawValue: algorithm)
  }

  /// Picker and list label: `Ed25519`, `ECDSA P-256`, or
  /// `P-256 · Secure Enclave`.
  public var keyTypeLabel: String {
    if storage == .secureEnclave { return "P-256 · Secure Enclave" }
    return keyAlgorithm?.displayName ?? algorithm
  }

  /// `"<type> <base64> <name>"` for `authorized_keys`.
  public var authorizedKeysLine: String {
    guard SSHKeyAlgorithm(canonicalPublicKeyLine: publicKey) != nil else {
      return publicKey
    }
    return SSHPublicKeyFormat.authorizedKeysLine(publicKey, comment: name)
  }

  public func validate() throws(ValidationError) {
    guard Self.isValidName(name) else { throw .invalidName }
    guard let algorithm = keyAlgorithm else { throw .unsupportedAlgorithm }
    // Only P-256 keys can live in the Secure Enclave (§13.2).
    guard storage != .secureEnclave || algorithm == .ecdsaP256 else {
      throw .unsupportedAlgorithm
    }
    guard SSHKeyAlgorithm(canonicalPublicKeyLine: publicKey) == algorithm else {
      throw .invalidPublicKey
    }
    guard
      SSHPublicKeyFormat.fingerprint(openSSHPublicKey: publicKey) == fingerprint
    else { throw .fingerprintMismatch }
  }

  public var isValid: Bool { (try? validate()) != nil }

  /// Display names need not be unique; they are never a resolution rule.
  public static func isValidName(_ name: String) -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    return !trimmed.isEmpty && trimmed == name && name.count <= maxNameLength
      && name.unicodeScalars.allSatisfy {
        $0 == " "
          || (!$0.properties.isWhitespace
            && $0.properties.generalCategory != .control
            && $0.properties.generalCategory != .format)
      }
  }

  /// `string "ssh-ed25519", string key[32]`, exactly.
  static func ed25519Key(blob: [UInt8]) -> Curve25519.Signing.PublicKey? {
    var reader = SSHWireReader(blob)
    guard let type = reader.readString(maxLength: 64),
      type == Array(algorithm.utf8)
    else { return nil }
    guard let raw = reader.readString(maxLength: 32), raw.count == 32,
      reader.isAtEnd
    else { return nil }
    return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
  }
}

/// Whether this device can authenticate with an identity right now.
/// Computed locally from the Keychain; never synchronized (§5).
public enum IdentityAvailability: Hashable, Sendable {
  case available
  /// A device-only key whose private half is not on this device.
  case unavailableOnThisDevice
  /// An iCloud Keychain identity whose key has not reached this device.
  /// Absence does not prove delivery is still pending (§8.4).
  case awaitingKeyMaterial
  /// The device is locked or protected data is not yet available.
  case protectedDataUnavailable
  /// The Keychain rejected access (for example a missing entitlement).
  case unsupported
  case deleted
  /// The stored key does not match this identity's public key.
  case integrityConflict

  public var summary: String {
    switch self {
    case .available: "Available"
    case .unavailableOnThisDevice: "Not on this device"
    case .awaitingKeyMaterial: "Key not available on this device"
    case .protectedDataUnavailable: "Unlock this device to use this key"
    case .unsupported: "Keychain unavailable"
    case .deleted: "Deleted"
    case .integrityConflict: "Key doesn't match its fingerprint"
    }
  }
}

/// Bounds-checked SSH wire-format reader (RFC 4251 §5). Every length is
/// validated against the remaining input before any allocation.
struct SSHWireReader {
  private var bytes: [UInt8]
  private(set) var offset = 0

  init(_ bytes: [UInt8]) { self.bytes = bytes }

  var isAtEnd: Bool { offset == bytes.count }
  var remaining: Int { bytes.count - offset }

  mutating func readUInt32() -> UInt32? {
    guard remaining >= 4 else { return nil }
    defer { offset += 4 }
    return bytes[offset ..< offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
  }

  mutating func readString(maxLength: Int) -> [UInt8]? {
    let start = offset
    guard let length = readUInt32(), Int(length) <= maxLength,
      Int(length) <= remaining
    else {
      offset = start
      return nil
    }
    defer { offset += Int(length) }
    return Array(bytes[offset ..< offset + Int(length)])
  }

  mutating func rewind(to position: Int) { offset = position }

  /// Clears this reader's copy of the input (best effort, §7.2).
  mutating func reset() {
    bytes.resetBytes()
    bytes = []
    offset = 0
  }

  mutating func readRest() -> [UInt8] {
    defer { offset = bytes.count }
    return Array(bytes[offset...])
  }
}
