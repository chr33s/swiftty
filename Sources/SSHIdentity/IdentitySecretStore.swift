import Crypto
import Foundation
import SSHClient

#if canImport(Security)
import Security
#endif

/// An identity's private key, held only by the Keychain adapter and short
/// authentication or import operations (§5). Deliberately not `Codable`,
/// and its descriptions are redacted so it cannot reach persistence or
/// diagnostics by accident.
public struct IdentitySecret: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  public let key: SSHSigningKey

  public init(_ privateKey: Curve25519.Signing.PrivateKey) {
    self.key = .ed25519(privateKey)
  }

  public init(key: SSHSigningKey) { self.key = key }

  /// The Ed25519 key, or `nil` for another algorithm.
  public var ed25519PrivateKey: Curve25519.Signing.PrivateKey? {
    if case let .ed25519(key) = key { return key }
    return nil
  }

  /// Canonical `"<type> <base64>"` public-key line, without a comment.
  public var publicKeyLine: String { key.publicKeyLine }
  public var fingerprint: String { key.fingerprint }
  public var credential: SSHCredential { .publicKey(key) }

  public var description: String { "IdentitySecret(<redacted>)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: []) }

  /// Keychain payload, by leading format byte:
  ///
  /// | Byte | Contents |
  /// |---|---|
  /// | 1 | 32-byte Ed25519 seed |
  /// | 2 | curve tag (2 P-256, 3 P-384, 4 P-521), raw ECDSA scalar |
  /// | 3 | Secure Enclave key handle, usable only on this device |
  static let payloadVersion: UInt8 = 1
  static let ecdsaPayloadVersion: UInt8 = 2
  static let secureEnclavePayloadVersion: UInt8 = 3

  var payload: Data {
    switch key {
    case let .ed25519(key):
      var data = Data([Self.payloadVersion])
      data.append(key.rawRepresentation)
      return data
    case let .p256(key):
      return Data([Self.ecdsaPayloadVersion, 2]) + key.rawRepresentation
    case let .p384(key):
      return Data([Self.ecdsaPayloadVersion, 3]) + key.rawRepresentation
    case let .p521(key):
      return Data([Self.ecdsaPayloadVersion, 4]) + key.rawRepresentation
    #if canImport(Darwin)
    case let .secureEnclaveP256(key):
      return Data([Self.secureEnclavePayloadVersion]) + key.dataRepresentation
    #endif
    }
  }

  init?(payload: Data) {
    guard let version = payload.first else { return nil }
    let body = payload.dropFirst()
    switch version {
    case Self.payloadVersion:
      guard body.count == 32,
        let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: body)
      else { return nil }
      self.key = .ed25519(key)
    case Self.ecdsaPayloadVersion:
      guard let curve = body.first else { return nil }
      let raw = body.dropFirst()
      switch curve {
      case 2:
        guard let key = try? P256.Signing.PrivateKey(rawRepresentation: raw)
        else { return nil }
        self.key = .p256(key)
      case 3:
        guard let key = try? P384.Signing.PrivateKey(rawRepresentation: raw)
        else { return nil }
        self.key = .p384(key)
      case 4:
        guard let key = try? P521.Signing.PrivateKey(rawRepresentation: raw)
        else { return nil }
        self.key = .p521(key)
      default: return nil
      }
    #if canImport(Darwin)
    case Self.secureEnclavePayloadVersion:
      // Fails on any other device: the handle is sealed to this one.
      guard SecureEnclave.isAvailable,
        let key = try? SecureEnclave.P256.Signing.PrivateKey(
          dataRepresentation: body
        )
      else { return nil }
      self.key = .secureEnclaveP256(key)
    #endif
    default: return nil
    }
  }

  /// Whether this payload belongs in `policy`'s namespace.
  func matches(_ policy: IdentityStoragePolicy) -> Bool {
    key.isSecureEnclave == (policy == .secureEnclave)
  }
}

/// Keychain outcomes kept distinct (§7.2): only `notFound` means absence.
public enum IdentitySecretError: Error, Hashable, Sendable {
  case notFound
  /// Create-without-overwrite found an existing item.
  case duplicate
  /// Locked device or protected data not yet available.
  case protectedDataUnavailable
  case authenticationCancelled
  case missingEntitlement
  /// The stored item is not a valid payload.
  case malformed
  /// A broad query matched more than one item.
  case ambiguous
  case status(Int32)
}

/// Exact-namespace storage for identity private keys. Every operation names
/// the identity UUID and its storage policy; there is no load-or-create.
public protocol IdentitySecretStore: Sendable {
  /// Creates the item; never overwrites. A present item is `.duplicate`.
  func add(
    _ secret: IdentitySecret,
    id: UUID,
    policy: IdentityStoragePolicy
  ) async throws(IdentitySecretError)
  func read(
    id: UUID,
    policy: IdentityStoragePolicy
  ) async throws(IdentitySecretError) -> IdentitySecret
  /// Deleting an absent item succeeds.
  func delete(
    id: UUID,
    policy: IdentityStoragePolicy
  ) async throws(IdentitySecretError)
  /// Identity UUIDs present in this app's exact namespace, for orphan
  /// recovery only. Never used to choose a login credential.
  func storedIdentities(
    policy: IdentityStoragePolicy
  ) async throws(IdentitySecretError) -> Set<UUID>
}

/// Volatile secret store for tests and previews. Policies are separate
/// namespaces, as Keychain synchronization flags are.
public actor InMemoryIdentitySecretStore: IdentitySecretStore {
  private var items: [IdentityStoragePolicy: [UUID: Data]] = [:]
  /// Errors to return from the next operations, for failure injection.
  public var failures: [IdentitySecretError] = []
  /// Whether reads behave as if the device were locked.
  public var locked = false

  public init() {}

  /// An error for the next read only, for failure injection.
  public var readFailure: IdentitySecretError?

  public func setLocked(_ value: Bool) { locked = value }
  public func failNextRead(_ error: IdentitySecretError) { readFailure = error }
  public func inject(_ error: IdentitySecretError) { failures.append(error) }

  /// Raw replacement, for integrity-conflict tests only.
  public func overwrite(
    _ payload: Data,
    id: UUID,
    policy: IdentityStoragePolicy
  ) { items[policy, default: [:]][id] = payload }

  private func nextFailure() throws(IdentitySecretError) {
    if !failures.isEmpty { throw failures.removeFirst() }
  }

  public func add(
    _ secret: IdentitySecret,
    id: UUID,
    policy: IdentityStoragePolicy
  ) throws(IdentitySecretError) {
    try nextFailure()
    guard secret.matches(policy) else { throw .malformed }
    guard items[policy]?[id] == nil else { throw .duplicate }
    items[policy, default: [:]][id] = secret.payload
  }

  public func read(
    id: UUID,
    policy: IdentityStoragePolicy
  ) throws(IdentitySecretError) -> IdentitySecret {
    try nextFailure()
    if let readFailure {
      self.readFailure = nil
      throw readFailure
    }
    if locked { throw .protectedDataUnavailable }
    guard let payload = items[policy]?[id] else { throw .notFound }
    guard let secret = IdentitySecret(payload: payload), secret.matches(policy)
    else { throw .malformed }
    return secret
  }

  public func delete(
    id: UUID,
    policy: IdentityStoragePolicy
  ) throws(IdentitySecretError) {
    try nextFailure()
    items[policy]?[id] = nil
  }

  public func storedIdentities(
    policy: IdentityStoragePolicy
  ) throws(IdentitySecretError) -> Set<UUID> {
    try nextFailure()
    return Set(items[policy]?.keys ?? [:].keys)
  }
}

#if canImport(Security)
/// Generic-password items in the data-protection Keychain (§7.1):
///
/// | Policy | Synchronizable | Accessibility |
/// |---|---|---|
/// | device only | false | `WhenUnlockedThisDeviceOnly` |
/// | iCloud Keychain | true | `WhenUnlocked` |
///
/// Service `dev.chr33s.swiftty.ssh-identity.v1`, account the lowercase
/// identity UUID, and the configured access group on every operation.
public actor KeychainIdentitySecretStore: IdentitySecretStore {
  public static let defaultService = "dev.chr33s.swiftty.ssh-identity.v1"

  public let service: String
  /// `nil` uses the app's default access group (unsigned test hosts).
  public let accessGroup: String?

  public init(
    service: String = KeychainIdentitySecretStore.defaultService,
    accessGroup: String?
  ) {
    self.service = service
    self.accessGroup = accessGroup
  }

  private func query(
    policy: IdentityStoragePolicy,
    account: String?
  ) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service(for: policy),
      kSecAttrSynchronizable as String: policy == .iCloudKeychain,
    ]
    if let account { query[kSecAttrAccount as String] = account }
    if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
    #if os(macOS)
    query[kSecUseDataProtectionKeychain as String] = true
    #endif
    return query
  }

  /// Secure Enclave handles use their own namespace, so recovery of
  /// software keys never lists them and vice versa (§13.2).
  private func service(for policy: IdentityStoragePolicy) -> String {
    policy == .secureEnclave ? service + ".secure-enclave" : service
  }

  private static func account(_ id: UUID) -> String {
    id.uuidString.lowercased()
  }

  public func add(
    _ secret: IdentitySecret,
    id: UUID,
    policy: IdentityStoragePolicy
  ) throws(IdentitySecretError) {
    guard secret.matches(policy) else { throw .malformed }
    var add = query(policy: policy, account: Self.account(id))
    add[kSecValueData as String] = secret.payload
    add[kSecAttrLabel as String] = "Swiftty SSH identity"
    add[kSecAttrAccessible as String] =
      switch policy {
      case .deviceOnly, .secureEnclave:
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      case .iCloudKeychain: kSecAttrAccessibleWhenUnlocked
      }
    let status = SecItemAdd(add as CFDictionary, nil)
    guard status == errSecSuccess else { throw Self.error(status) }
  }

  public func read(
    id: UUID,
    policy: IdentityStoragePolicy
  ) throws(IdentitySecretError) -> IdentitySecret {
    var read = query(policy: policy, account: Self.account(id))
    read[kSecReturnData as String] = true
    read[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(read as CFDictionary, &result)
    guard status == errSecSuccess else { throw Self.error(status) }
    guard let data = result as? Data,
      let secret = IdentitySecret(payload: data), secret.matches(policy)
    else { throw .malformed }
    return secret
  }

  public func delete(
    id: UUID,
    policy: IdentityStoragePolicy
  ) throws(IdentitySecretError) {
    let status = SecItemDelete(
      query(policy: policy, account: Self.account(id)) as CFDictionary
    )
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw Self.error(status)
    }
  }

  public func storedIdentities(
    policy: IdentityStoragePolicy
  ) throws(IdentitySecretError) -> Set<UUID> {
    var list = query(policy: policy, account: nil)
    list[kSecReturnAttributes as String] = true
    list[kSecMatchLimit as String] = kSecMatchLimitAll
    var result: CFTypeRef?
    let status = SecItemCopyMatching(list as CFDictionary, &result)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess else { throw Self.error(status) }
    guard let items = result as? [[String: Any]] else { throw .malformed }
    var ids: Set<UUID> = []
    for item in items {
      // Only canonical lowercase UUID accounts belong to this namespace.
      guard let account = item[kSecAttrAccount as String] as? String,
        let id = UUID(uuidString: account), Self.account(id) == account
      else { continue }
      guard ids.insert(id).inserted else { throw .ambiguous }
    }
    return ids
  }

  static func error(_ status: OSStatus) -> IdentitySecretError {
    switch status {
    case errSecItemNotFound: .notFound
    case errSecDuplicateItem: .duplicate
    case errSecInteractionNotAllowed: .protectedDataUnavailable
    case errSecUserCanceled: .authenticationCancelled
    case errSecMissingEntitlement: .missingEntitlement
    case errSecDecode: .malformed
    default: .status(status)
    }
  }
}
#endif
