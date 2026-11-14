import Foundation

/// How a saved host authenticates. A *reference* only: secrets live in
/// the Keychain or are prompted for, never in a `HostProfile`.
///
/// Version 2 encodes `{"type": …}` explicitly (spec.ssh-identity.md §5).
/// The version-1 synthesized shape is read for migration only, and an
/// unknown variant written by a newer build is preserved verbatim.
public enum AuthMethodReference: Hashable, Sendable, Codable {
  /// Prompt for a password at connect time; nothing is stored here.
  case password
  /// A reusable SSH identity, by stable UUID. Renaming the identity never
  /// changes this reference.
  case key(identityID: UUID)
  /// A version-1 label awaiting migration or explicit repair. Never
  /// resolves to a credential and never creates a key.
  case legacyKey(label: String)
  /// A variant this build does not understand, kept for round-tripping.
  case unsupported(JSONValue)

  public var identityID: UUID? {
    if case .key(let id) = self { return id }
    return nil
  }

  private enum CodingKeys: String, CodingKey {
    case type, identity, label
    // Version-1 synthesized enum keys.
    case password, keychainKey
  }

  public init(from decoder: any Decoder) throws {
    let raw = try JSONValue(from: decoder)
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let type = try? container.decode(String.self, forKey: .type) {
      switch type {
      case "password": self = .password
      case "key":
        self = .key(
          identityID: try container.decode(UUID.self, forKey: .identity)
        )
      case "legacyKey":
        self = .legacyKey(
          label: try container.decode(String.self, forKey: .label)
        )
      default: self = .unsupported(raw)
      }
      return
    }
    if container.contains(.password) {
      self = .password
    } else if let legacy = try? container.nestedContainer(
      keyedBy: CodingKeys.self,
      forKey: .keychainKey
    ), let label = try? legacy.decode(String.self, forKey: .label) {
      self = .legacyKey(label: label)
    } else {
      self = .unsupported(raw)
    }
  }

  public func encode(to encoder: any Encoder) throws {
    if case .unsupported(let raw) = self {
      try raw.encode(to: encoder)
      return
    }
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .password: try container.encode("password", forKey: .type)
    case .key(let id):
      try container.encode("key", forKey: .type)
      try container.encode(id, forKey: .identity)
    case .legacyKey(let label):
      try container.encode("legacyKey", forKey: .type)
      try container.encode(label, forKey: .label)
    case .unsupported: break
    }
  }
}

/// Lossless JSON for preserving data a newer build wrote.
public indirect enum JSONValue: Hashable, Sendable, Codable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}

/// A saved SSH host: explicit host, port and username (spec §2), plus a
/// user-chosen nickname. Contains no passwords, private keys, tokens,
/// certificates or session identifiers.
public struct HostProfile: Hashable, Sendable, Codable, Identifiable {
  public enum ValidationError: Error, Hashable, Sendable {
    case emptyNickname
    case invalidHost
    case invalidPort
    case invalidUsername
    case invalidKeyLabel
  }

  public static let maxNicknameLength = 64
  public static let maxHostLength = 253
  public static let maxUsernameLength = 64
  public static let maxKeyLabelLength = 64

  public var id: UUID
  public var nickname: String
  public var host: String
  public var port: Int
  public var username: String
  public var auth: AuthMethodReference

  public init(
    id: UUID = UUID(),
    nickname: String,
    host: String,
    port: Int = 22,
    username: String,
    auth: AuthMethodReference = .password
  ) {
    self.id = id
    self.nickname = nickname
    self.host = host
    self.port = port
    self.username = username
    self.auth = auth
  }

  /// Checks every field. The host and username are passed to SSH as
  /// structured values, never interpolated into a shell command, but are
  /// still restricted to printable, whitespace-free text.
  public func validate() throws(ValidationError) {
    let name = nickname.trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty, name.count <= Self.maxNicknameLength,
      Self.isPrintable(name, allowSpaces: true)
    else { throw .emptyNickname }
    guard !host.isEmpty, host.utf8.count <= Self.maxHostLength,
      Self.isPrintable(host, allowSpaces: false), !host.hasPrefix("-")
    else { throw .invalidHost }
    guard (1...65_535).contains(port) else { throw .invalidPort }
    guard !username.isEmpty, username.utf8.count <= Self.maxUsernameLength,
      Self.isPrintable(username, allowSpaces: false), !username.hasPrefix("-")
    else { throw .invalidUsername }
    if case .legacyKey(let label) = auth {
      guard !label.isEmpty, label.count <= Self.maxKeyLabelLength,
        Self.isPrintable(label, allowSpaces: true)
      else { throw .invalidKeyLabel }
    }
  }

  public var isValid: Bool { (try? validate()) != nil }

  /// `user@host:port` for display.
  public var endpointSummary: String {
    let hostPart = host.contains(":") ? "[\(host)]" : host
    return port == 22 ? "\(username)@\(hostPart)" : "\(username)@\(hostPart):\(port)"
  }

  package static func isPrintable(_ text: String, allowSpaces: Bool) -> Bool {
    text.unicodeScalars.allSatisfy { scalar in
      if scalar == " " { return allowSpaces }
      return !scalar.properties.isWhitespace
        && scalar.properties.generalCategory != .control
        && scalar.properties.generalCategory != .format
    }
  }
}
