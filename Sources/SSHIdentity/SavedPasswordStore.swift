import Foundation

#if canImport(Security)
import Security
#endif

/// A password the user chose to keep for one saved host
/// (spec.ssh-identity.md §13.3). It is bound to the endpoint it was
/// entered for: a host whose address, port or username later changes never
/// receives it. Descriptions are redacted.
public struct SavedPassword: Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  public let host: String
  public let port: Int
  public let username: String
  public let password: String

  public init(host: String, port: Int, username: String, password: String) {
    self.host = host
    self.port = port
    self.username = username
    self.password = password
  }

  /// Whether this password was saved for exactly this endpoint. Host names
  /// compare case-insensitively, as DNS does.
  public func matches(host: String, port: Int, username: String) -> Bool {
    self.host.lowercased() == host.lowercased() && self.port == port
      && self.username == username
  }

  public var description: String { "SavedPassword(<redacted>)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: []) }

  private struct Payload: Codable {
    var version = 1
    var host: String
    var port: Int
    var username: String
    var password: String
  }

  var payload: Data? {
    try? JSONEncoder().encode(
      Payload(host: host, port: port, username: username, password: password)
    )
  }

  init?(payload: Data) {
    guard let decoded = try? JSONDecoder().decode(Payload.self, from: payload),
      decoded.version == 1
    else { return nil }
    self.init(
      host: decoded.host,
      port: decoded.port,
      username: decoded.username,
      password: decoded.password
    )
  }
}

/// Keychain storage for saved host passwords, keyed by host UUID. Saved
/// passwords are device-only and never synchronized or written to
/// snapshots, CloudKit or logs.
public protocol SavedPasswordStore: Sendable {
  func read(host id: UUID) async throws(IdentitySecretError) -> SavedPassword
  /// Replaces any password saved for this host.
  func save(
    _ password: SavedPassword,
    host id: UUID
  ) async throws(IdentitySecretError)
  /// Deleting an absent item succeeds.
  func delete(host id: UUID) async throws(IdentitySecretError)
}

/// Volatile store for tests and previews.
public actor InMemorySavedPasswordStore: SavedPasswordStore {
  private var items: [UUID: SavedPassword] = [:]

  public init() {}

  public func read(
    host id: UUID
  ) throws(IdentitySecretError) -> SavedPassword {
    guard let item = items[id] else { throw .notFound }
    return item
  }

  public func save(_ password: SavedPassword, host id: UUID) {
    items[id] = password
  }

  public func delete(host id: UUID) { items[id] = nil }

  public var count: Int { items.count }
}

#if canImport(Security)
/// Generic-password items in the data-protection Keychain: service
/// `dev.chr33s.swiftty.ssh-password.v1`, account the lowercase host UUID,
/// not synchronizable, `WhenUnlockedThisDeviceOnly`.
public actor KeychainSavedPasswordStore: SavedPasswordStore {
  public static let defaultService = "dev.chr33s.swiftty.ssh-password.v1"

  public let service: String
  public let accessGroup: String?

  public init(
    service: String = KeychainSavedPasswordStore.defaultService,
    accessGroup: String?
  ) {
    self.service = service
    self.accessGroup = accessGroup
  }

  private func query(_ id: UUID) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: id.uuidString.lowercased(),
      kSecAttrSynchronizable as String: false,
    ]
    if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
    #if os(macOS)
    query[kSecUseDataProtectionKeychain as String] = true
    #endif
    return query
  }

  public func read(
    host id: UUID
  ) throws(IdentitySecretError) -> SavedPassword {
    var read = query(id)
    read[kSecReturnData as String] = true
    read[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(read as CFDictionary, &result)
    guard status == errSecSuccess else {
      throw KeychainIdentitySecretStore.error(status)
    }
    guard let data = result as? Data, let saved = SavedPassword(payload: data)
    else { throw .malformed }
    return saved
  }

  public func save(
    _ password: SavedPassword,
    host id: UUID
  ) throws(IdentitySecretError) {
    guard let payload = password.payload else { throw .malformed }
    let update: [String: Any] = [kSecValueData as String: payload]
    var status = SecItemUpdate(query(id) as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      var add = query(id)
      add[kSecValueData as String] = payload
      add[kSecAttrLabel as String] = "Swiftty SSH password"
      add[kSecAttrAccessible as String] =
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      status = SecItemAdd(add as CFDictionary, nil)
    }
    guard status == errSecSuccess else {
      throw KeychainIdentitySecretStore.error(status)
    }
  }

  public func delete(host id: UUID) throws(IdentitySecretError) {
    let status = SecItemDelete(query(id) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainIdentitySecretStore.error(status)
    }
  }
}
#endif
