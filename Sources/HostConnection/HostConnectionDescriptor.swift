import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The SSH connection details a Mac shows as a pairing code
/// (spec.connection-setup.md §4): where to reach its SSH server, which
/// account to sign in as, and the SHA-256 fingerprints of the SSH host
/// public keys that server presents.
///
/// A descriptor is not an authorization. It carries no passwords, private
/// keys, RST tokens, session or workspace identifiers, commands, helper
/// paths or automatic actions, and decoding it performs no network
/// request. The fingerprints are expectations the client enforces before
/// it sends any credential; they never become trusted keys by themselves.
public struct HostConnectionDescriptor: Hashable, Sendable {
  public static let kind = "swiftty-host"
  public static let version = 1
  /// Total encoded size accepted by the decoder.
  public static let maxBytes = 2048
  public static let maxHostKeys = 4
  public static let maxNameLength = 64
  public static let maxHostLength = 253
  public static let maxUsernameLength = 64

  /// One SSH host public key, by the OpenSSH `SHA256:` fingerprint of its
  /// wire-format blob (the format the client's trust store displays).
  /// Never a QUIC certificate or SPKI fingerprint.
  public struct HostKey: Hashable, Sendable {
    /// SSH algorithm name, such as `ssh-ed25519`.
    public var algorithm: String
    /// `SHA256:` followed by the unpadded base64 of a 32-byte digest.
    public var sha256: String

    public init(algorithm: String, sha256: String) {
      self.algorithm = algorithm
      self.sha256 = sha256
    }
  }

  /// SSH host-key algorithms the direct clients can verify.
  public static let supportedAlgorithms: Set<String> = [
    "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384",
    "ecdsa-sha2-nistp521",
  ]

  /// Display name; optional, never used as a host name.
  public var name: String?
  public var host: String
  public var port: Int
  public var username: String
  public var hostKeys: [HostKey]

  public init(
    name: String?,
    host: String,
    port: Int = 22,
    username: String,
    hostKeys: [HostKey]
  ) {
    self.name = name
    self.host = host
    self.port = port
    self.username = username
    self.hostKeys = hostKeys
  }

  public var expectedFingerprints: Set<String> { Set(hostKeys.map(\.sha256)) }

  public enum DecodingError: Error, Hashable, Sendable {
    case tooLarge
    case malformed
    case unsupportedKind
    case unsupportedVersion
    case unknownField(String)
    case invalidName
    case invalidHost
    case invalidPort
    case invalidUsername
    case invalidHostKeys
  }

  public enum EncodingError: Error, Hashable, Sendable {
    case invalid(DecodingError)
    case tooLarge
  }

  // MARK: Encoding

  /// Compact, key-sorted UTF-8 JSON that `decode` accepts.
  public func encoded() throws(EncodingError) -> Data {
    do { try validate() } catch { throw .invalid(error) }
    struct Wire: Encodable {
      struct SSH: Encodable {
        var host: String
        var port: Int
        var username: String
      }
      struct Key: Encodable {
        var algorithm: String
        var sha256: String
      }
      var kind: String
      var version: Int
      var name: String?
      var ssh: SSH
      var hostKeys: [Key]
    }
    let wire = Wire(
      kind: Self.kind,
      version: Self.version,
      name: name,
      ssh: .init(host: host, port: port, username: username),
      hostKeys: hostKeys.map {
        .init(algorithm: $0.algorithm, sha256: $0.sha256)
      }
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(wire) else { throw .tooLarge }
    guard data.count <= Self.maxBytes else { throw .tooLarge }
    return data
  }

  /// The encoded descriptor as text, for a QR code or the pasteboard.
  public func encodedString() throws(EncodingError) -> String {
    String(decoding: try encoded(), as: UTF8.self)
  }

  // MARK: Decoding

  /// Decodes a pairing code. Bounded and strict: unknown fields, other
  /// kinds or versions, oversize input and out-of-bounds values are
  /// rejected rather than normalized.
  public static func decode(
    _ data: Data
  ) throws(DecodingError) -> HostConnectionDescriptor {
    guard data.count <= maxBytes else { throw .tooLarge }
    guard String(data: data, encoding: .utf8) != nil,
      let object = try? JSONSerialization.jsonObject(with: data),
      let root = object as? [String: Any]
    else { throw .malformed }
    guard let kind = root["kind"] as? String, kind == Self.kind else {
      throw .unsupportedKind
    }
    guard let version = integer(root["version"]), version == Self.version else {
      throw .unsupportedVersion
    }
    try requireOnly(root, ["kind", "version", "name", "ssh", "hostKeys"])

    var name: String?
    if let value = root["name"] {
      guard let text = value as? String else { throw .invalidName }
      name = text
    }
    guard let ssh = root["ssh"] as? [String: Any] else { throw .malformed }
    try requireOnly(ssh, ["host", "port", "username"])
    guard let host = ssh["host"] as? String else { throw .invalidHost }
    guard let port = integer(ssh["port"]) else { throw .invalidPort }
    guard let username = ssh["username"] as? String else {
      throw .invalidUsername
    }
    guard let keys = root["hostKeys"] as? [Any],
      (1 ... maxHostKeys).contains(keys.count)
    else { throw .invalidHostKeys }
    var hostKeys: [HostKey] = []
    for value in keys {
      guard let key = value as? [String: Any] else { throw .invalidHostKeys }
      try requireOnly(key, ["algorithm", "sha256"])
      guard let algorithm = key["algorithm"] as? String,
        let sha256 = key["sha256"] as? String
      else { throw .invalidHostKeys }
      hostKeys.append(HostKey(algorithm: algorithm, sha256: sha256))
    }
    let descriptor = HostConnectionDescriptor(
      name: name,
      host: host,
      port: port,
      username: username,
      hostKeys: hostKeys
    )
    try descriptor.validate()
    return descriptor
  }

  public static func decode(
    _ text: String
  ) throws(DecodingError) -> HostConnectionDescriptor {
    guard text.utf8.count <= maxBytes else { throw .tooLarge }
    return try decode(Data(text.utf8))
  }

  /// Checks every field against the version 1 bounds.
  public func validate() throws(DecodingError) {
    if let name { guard Self.isValidName(name) else { throw .invalidName } }
    guard Self.isValidHost(host) else { throw .invalidHost }
    guard (1 ... 65_535).contains(port) else { throw .invalidPort }
    guard Self.isValidUsername(username) else { throw .invalidUsername }
    guard (1 ... Self.maxHostKeys).contains(hostKeys.count),
      Set(hostKeys.map(\.sha256)).count == hostKeys.count,
      hostKeys.allSatisfy({
        Self.supportedAlgorithms.contains($0.algorithm)
          && Self.isValidFingerprint($0.sha256)
      })
    else { throw .invalidHostKeys }
  }

  private static func requireOnly(
    _ object: [String: Any],
    _ allowed: Set<String>
  ) throws(DecodingError) {
    if let unknown = object.keys.sorted()
      .first(where: { !allowed.contains($0) })
    {
      throw .unknownField(String(unknown.prefix(32)))
    }
  }

  /// An integral JSON number; booleans and fractions are not integers.
  private static func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID()
    else { return nil }
    let double = number.doubleValue
    guard double.rounded() == double, abs(double) <= 1_000_000 else {
      return nil
    }
    return number.intValue
  }

  // MARK: Field rules

  /// `SHA256:` plus 43 unpadded base64 characters encoding 32 bytes.
  public static func isValidFingerprint(_ text: String) -> Bool {
    guard text.hasPrefix("SHA256:") else { return false }
    let body = text.dropFirst("SHA256:".count)
    guard body.count == 43,
      body.unicodeScalars.allSatisfy({
        ("A" ... "Z").contains($0) || ("a" ... "z").contains($0)
          || ("0" ... "9").contains($0) || $0 == "+" || $0 == "/"
      }), let data = Data(base64Encoded: body + "=")
    else { return false }
    return data.count == 32
  }

  /// A DNS host name or an unscoped IPv4/IPv6 literal. URLs, ports,
  /// scopes, user info and anything needing normalization are refused.
  public static func isValidHost(_ host: String) -> Bool {
    guard !host.isEmpty, host.utf8.count <= maxHostLength else { return false }
    if isIPLiteral(host) { return true }
    return isDNSName(host)
  }

  static func isIPLiteral(_ host: String) -> Bool {
    var v4 = in_addr()
    var v6 = in6_addr()
    if host.contains(".") && !host.contains(":") {
      return inet_pton(AF_INET, host, &v4) == 1
    }
    return host.contains(":") && !host.contains("%")
      && inet_pton(AF_INET6, host, &v6) == 1
  }

  /// LDH labels of 1–63 ASCII characters, no leading or trailing hyphen,
  /// and no trailing dot. A name made only of digits and dots is not one.
  static func isDNSName(_ host: String) -> Bool {
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    guard !labels.isEmpty else { return false }
    for label in labels {
      guard (1 ... 63).contains(label.utf8.count), label.first != "-",
        label.last != "-",
        label.unicodeScalars.allSatisfy({
          ("a" ... "z").contains($0) || ("A" ... "Z").contains($0)
            || ("0" ... "9").contains($0) || $0 == "-"
        })
      else { return false }
    }
    return !host.unicodeScalars.allSatisfy {
      ("0" ... "9").contains($0) || $0 == "."
    }
  }

  /// A POSIX-style account short name.
  public static func isValidUsername(_ name: String) -> Bool {
    guard !name.isEmpty, name.utf8.count <= maxUsernameLength,
      name.first != "-", name.first != "."
    else { return false }
    return name.unicodeScalars.allSatisfy {
      ("a" ... "z").contains($0) || ("A" ... "Z").contains($0)
        || ("0" ... "9").contains($0) || $0 == "_" || $0 == "-" || $0 == "."
    }
  }

  /// Printable display text with no controls, URLs or shell syntax.
  public static func isValidName(_ name: String) -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed == name, name.count <= maxNameLength,
      name.utf8.count <= 4 * maxNameLength, !name.contains("://")
    else { return false }
    let forbidden: Set<Unicode.Scalar> = ["`", "$", ";", "|", "<", ">", "\\"]
    return name.unicodeScalars.allSatisfy { scalar in
      if scalar == " " { return true }
      return !forbidden.contains(scalar) && !scalar.properties.isWhitespace
        && scalar.properties.generalCategory != .control
        && scalar.properties.generalCategory != .format
        && scalar.properties.generalCategory != .lineSeparator
        && scalar.properties.generalCategory != .paragraphSeparator
        && scalar.properties.generalCategory != .unassigned
        && scalar.properties.generalCategory != .privateUse
        && scalar.properties.generalCategory != .surrogate
    }
  }
}
