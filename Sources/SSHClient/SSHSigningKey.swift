import Crypto
import Foundation
import NIOSSH

/// Public-key algorithms Swiftty can authenticate with
/// (spec.ssh-identity.md §13.1). RSA is absent because SwiftNIO SSH has no
/// RSA client keys; it is refused, never approximated.
public enum SSHKeyAlgorithm: String, Hashable, Sendable, Codable, CaseIterable
{
  case ed25519 = "ssh-ed25519"
  case ecdsaP256 = "ecdsa-sha2-nistp256"
  case ecdsaP384 = "ecdsa-sha2-nistp384"
  case ecdsaP521 = "ecdsa-sha2-nistp521"

  /// The OpenSSH curve identifier inside ECDSA key blobs.
  public var curveName: String? {
    switch self {
    case .ed25519: nil
    case .ecdsaP256: "nistp256"
    case .ecdsaP384: "nistp384"
    case .ecdsaP521: "nistp521"
    }
  }

  /// Short label such as `Ed25519` or `ECDSA P-256`.
  public var displayName: String {
    switch self {
    case .ed25519: "Ed25519"
    case .ecdsaP256: "ECDSA P-256"
    case .ecdsaP384: "ECDSA P-384"
    case .ecdsaP521: "ECDSA P-521"
    }
  }

  /// The algorithm of a canonical `"<type> <base64>"` line (no comment)
  /// whose blob is a well-formed key of that type, else `nil`.
  public init?(canonicalPublicKeyLine line: String) {
    let parts = line.split(separator: " ", omittingEmptySubsequences: false)
    guard parts.count == 2, let algorithm = Self(rawValue: String(parts[0])),
      let key = try? NIOSSHPublicKey(openSSHPublicKey: line),
      String(openSSHPublicKey: key) == line
    else { return nil }
    self = algorithm
  }
}

/// A private key held only for the authentication operation. Descriptions
/// are redacted; never log or persist the payload.
public enum SSHSigningKey: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  case ed25519(Curve25519.Signing.PrivateKey)
  case p256(P256.Signing.PrivateKey)
  case p384(P384.Signing.PrivateKey)
  case p521(P521.Signing.PrivateKey)
  #if canImport(Darwin)
  /// A device-bound key whose private half never leaves the Secure
  /// Enclave; signing may require Face ID, Touch ID or the passcode.
  case secureEnclaveP256(SecureEnclave.P256.Signing.PrivateKey)
  #endif

  public var algorithm: SSHKeyAlgorithm {
    switch self {
    case .ed25519: .ed25519
    case .p256: .ecdsaP256
    case .p384: .ecdsaP384
    case .p521: .ecdsaP521
    #if canImport(Darwin)
    case .secureEnclaveP256: .ecdsaP256
    #endif
    }
  }

  public var isSecureEnclave: Bool {
    #if canImport(Darwin)
    if case .secureEnclaveP256 = self { return true }
    #endif
    return false
  }

  /// A fresh software key from the system CSPRNG.
  public static func generate(_ algorithm: SSHKeyAlgorithm) -> SSHSigningKey {
    switch algorithm {
    case .ed25519: .ed25519(.init())
    case .ecdsaP256: .p256(.init())
    case .ecdsaP384: .p384(.init())
    case .ecdsaP521: .p521(.init())
    }
  }

  var nioPrivateKey: NIOSSHPrivateKey {
    switch self {
    case let .ed25519(key): NIOSSHPrivateKey(ed25519Key: key)
    case let .p256(key): NIOSSHPrivateKey(p256Key: key)
    case let .p384(key): NIOSSHPrivateKey(p384Key: key)
    case let .p521(key): NIOSSHPrivateKey(p521Key: key)
    #if canImport(Darwin)
    case let .secureEnclaveP256(key):
      NIOSSHPrivateKey(secureEnclaveP256Key: key)
    #endif
    }
  }

  /// Canonical `"<type> <base64>"` line, without a comment.
  public var publicKeyLine: String {
    String(openSSHPublicKey: nioPrivateKey.publicKey)
  }

  /// OpenSSH `SHA256:` fingerprint of the public key.
  public var fingerprint: String {
    SSHPublicKeyFormat.fingerprint(openSSHPublicKey: publicKeyLine) ?? ""
  }

  public var description: String { "SSHSigningKey(<redacted>)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: []) }
}

extension SSHPublicKeyFormat {
  /// `"<type> <base64> [comment]"` for `authorized_keys`. Control
  /// characters and newlines in the comment are removed so the line cannot
  /// inject extra entries or options.
  public static func authorizedKeysLine(
    _ line: String,
    comment: String?
  ) -> String {
    guard let comment else { return line }
    let cleaned = String(
      String.UnicodeScalarView(
        comment.unicodeScalars.filter {
          $0.value >= 0x20 && $0.value != 0x7F
            && !(0x80 ... 0x9F).contains($0.value)
        }
      )
    )
    .trimmingCharacters(in: .whitespaces)
    return cleaned.isEmpty ? line : line + " " + cleaned
  }
}
