import Crypto
import CryptoExtras
import Foundation
import SSHClient

/// Why an imported private key was refused (spec.ssh-identity.md §6.2).
/// Messages name the problem only; they never echo file contents.
public enum OpenSSHImportError: Error, Hashable, Sendable {
  case inputTooLarge
  /// Not an armored `openssh-key-v1` private key.
  case unrecognizedFormat
  /// Another private-key format, such as PEM RSA or PKCS #8.
  case unsupportedFormat(String)
  /// A passphrase-protected key, opened without a passphrase.
  case passphraseRequired
  case wrongPassphrase
  /// An encryption cipher other than the AES modes in §6.4.
  case unsupportedCipher(String)
  /// A key derivation other than `bcrypt`.
  case unsupportedKDF(String)
  /// More KDF rounds than `OpenSSHKeyImporter.maxRounds`.
  case workFactorTooHigh(Int)
  case publicKeyOnly
  case certificate
  case malformed
  case unsupportedKeyCount(Int)
  case unsupportedAlgorithm(String)
  case commentTooLarge
  case invalidPadding
  /// Public and private halves disagree.
  case keyMismatch
  case cancelled

  public var message: String {
    switch self {
    case .inputTooLarge: "The file is larger than 64 KB."
    case .unrecognizedFormat: "This is not an OpenSSH private key."
    case .unsupportedFormat(let name):
      "\(name) keys are not supported. Import an OpenSSH Ed25519 or ECDSA "
        + "key, or generate one here."
    case .passphraseRequired: "Enter the key's passphrase."
    case .wrongPassphrase: "The passphrase is incorrect."
    case .unsupportedCipher(let name):
      "Keys encrypted with \(name) are not supported. Re-encrypt a copy with "
        + "ssh-keygen -p -Z aes256-ctr, import that copy, then delete it."
    case .unsupportedKDF(let name):
      "Keys protected with the \(name) key derivation are not supported."
    case .workFactorTooHigh(let rounds):
      "The key's passphrase uses \(rounds) rounds; at most "
        + "\(OpenSSHKeyImporter.maxRounds) are supported. Re-encrypt a copy "
        + "with ssh-keygen -p -a 100."
    case .publicKeyOnly:
      "This is a public key. Import the matching private key file."
    case .certificate: "SSH certificates are not supported."
    case .malformed: "The key file is damaged or incomplete."
    case .unsupportedKeyCount(let count):
      "The file holds \(count) keys; import one key at a time."
    case .unsupportedAlgorithm(let name):
      "\(name) keys are not supported; import an Ed25519 or ECDSA "
        + "(P-256, P-384, P-521) key."
    case .commentTooLarge: "The key's comment is larger than 1 KB."
    case .invalidPadding: "The key file's padding is invalid."
    case .keyMismatch: "The key's public and private halves do not match."
    case .cancelled: "Import cancelled."
    }
  }
}

/// What a key file holds, shown so the user can confirm the algorithm and
/// fingerprint before anything is saved.
public struct OpenSSHKeyInspection: Hashable, Sendable {
  public let algorithm: String
  public let fingerprint: String
  /// Nil for an encrypted key: the comment is inside the encrypted part.
  public let comment: String?
  /// Saving needs the passphrase.
  public let isEncrypted: Bool
}

/// A decoded key, normalized for Keychain storage.
public struct ImportedOpenSSHKey: Sendable {
  public let secret: IdentitySecret
  /// The file's comment, a suggested display name.
  public let comment: String?

  public var fingerprint: String { secret.fingerprint }

  public var inspection: OpenSSHKeyInspection {
    OpenSSHKeyInspection(
      algorithm: secret.key.algorithm.rawValue,
      fingerprint: fingerprint,
      comment: comment,
      isEncrypted: false
    )
  }
}

/// The ciphers of passphrase-protected `openssh-key-v1` files that import
/// supports (§6.4), with OpenSSH's key, IV, block and tag sizes.
enum OpenSSHCipher: Sendable {
  case ctr(keySize: Int)
  case cbc(keySize: Int)
  case gcm(keySize: Int)

  init?(name: String) {
    switch name {
    case "aes128-ctr": self = .ctr(keySize: 16)
    case "aes192-ctr": self = .ctr(keySize: 24)
    case "aes256-ctr": self = .ctr(keySize: 32)
    case "aes128-cbc": self = .cbc(keySize: 16)
    case "aes192-cbc": self = .cbc(keySize: 24)
    case "aes256-cbc": self = .cbc(keySize: 32)
    case "aes128-gcm@openssh.com": self = .gcm(keySize: 16)
    case "aes256-gcm@openssh.com": self = .gcm(keySize: 32)
    default: return nil
    }
  }

  var keySize: Int {
    switch self {
    case let .ctr(n), let .cbc(n), let .gcm(n): n
    }
  }

  var ivSize: Int { if case .gcm = self { 12 } else { 16 } }

  var blockSize: Int { 16 }

  /// Bytes of authentication tag following the encrypted section.
  var tagSize: Int { if case .gcm = self { 16 } else { 0 } }

  /// Decrypts the private section; nil when GCM authentication fails.
  func decrypt(_ section: [UInt8], tag: [UInt8], keyAndIV: [UInt8]) -> [UInt8]?
  {
    let key = SymmetricKey(data: keyAndIV[..<keySize])
    let iv = keyAndIV[keySize...]
    do {
      switch self {
      case .ctr:
        return Array(
          try AES._CTR.decrypt(
            section,
            using: key,
            nonce: AES._CTR.Nonce(nonceBytes: iv)
          )
        )
      case .cbc:
        return Array(
          try AES._CBC.decrypt(
            section,
            using: key,
            iv: AES._CBC.IV(ivBytes: iv),
            noPadding: true
          )
        )
      case .gcm:
        let box = try AES.GCM.SealedBox(
          nonce: AES.GCM.Nonce(data: iv),
          ciphertext: section,
          tag: tag
        )
        return Array(try AES.GCM.open(box, using: key))
      }
    } catch { return nil }
  }
}

/// Bounded import of one `openssh-key-v1` Ed25519 key (§6.2), unencrypted
/// or passphrase-protected (§6.4). Every length is checked before
/// allocation and the input must be consumed exactly.
public enum OpenSSHKeyImporter {
  public static let maxInputBytes = 64 * 1024
  public static let maxCommentBytes = 1024
  /// `bcrypt_pbkdf` rounds accepted: ssh-keygen's default is 16 and common
  /// hardening advice is 100. Each round costs the same, so the bound caps
  /// the work an imported file can demand.
  public static let maxRounds = 1024
  static let maxSaltBytes = 64

  static let magic = Array("openssh-key-v1".utf8) + [0]
  static let beginArmor = "-----BEGIN OPENSSH PRIVATE KEY-----"
  static let endArmor = "-----END OPENSSH PRIVATE KEY-----"
  /// The unencrypted private section is padded to this block size.
  static let blockSize = 8

  /// The file's structure, validated, before any decryption.
  struct Envelope {
    /// Canonical `"<type> <base64>"` line of the file's public key.
    var publicKey: String
    /// Nil when unencrypted.
    var encryption: (cipher: OpenSSHCipher, salt: [UInt8], rounds: Int)?
    var section: [UInt8]
    var tag: [UInt8]

    mutating func reset() {
      section.resetBytes()
      tag.resetBytes()
    }
  }

  /// What the file holds, for confirmation. An encrypted key needs no
  /// passphrase here: its public key is stored in the clear.
  public static func inspect(
    _ input: Data
  ) throws(OpenSSHImportError) -> OpenSSHKeyInspection {
    if let pem = try pemKey(input) { return pem.inspection }
    var envelope = try parse(input)
    defer { envelope.reset() }
    guard envelope.encryption != nil else {
      return try parsePrivateSection(
        envelope.section,
        publicKey: envelope.publicKey,
        padding: blockSize,
        encrypted: false
      )
      .inspection
    }
    return OpenSSHKeyInspection(
      algorithm: SSHPublicKeyFormat.keyType(openSSHPublicKey: envelope.publicKey),
      fingerprint: SSHPublicKeyFormat.fingerprint(
        openSSHPublicKey: envelope.publicKey
      ) ?? "",
      comment: nil,
      isEncrypted: true
    )
  }

  /// Decodes synchronously on the caller's thread. Prefer
  /// `OpenSSHImportGate`, which runs off the main actor with bounded
  /// concurrency. `passphrase` is used only for an encrypted key and is
  /// never stored; `isCancelled` is polled during key derivation.
  public static func decode(
    _ input: Data,
    passphrase: String? = nil,
    isCancelled: () -> Bool = { false }
  ) throws(OpenSSHImportError) -> ImportedOpenSSHKey {
    if let pem = try pemKey(input) { return pem }
    var envelope = try parse(input)
    defer { envelope.reset() }
    guard let (cipher, salt, rounds) = envelope.encryption else {
      return try parsePrivateSection(
        envelope.section,
        publicKey: envelope.publicKey,
        padding: blockSize,
        encrypted: false
      )
    }
    guard let passphrase, !passphrase.isEmpty else { throw .passphraseRequired }
    var secret = Array(passphrase.utf8)
    defer { secret.resetBytes() }
    var keyAndIV: [UInt8]
    do {
      keyAndIV = try BcryptPBKDF.derive(
        passphrase: secret,
        salt: salt,
        rounds: rounds,
        length: cipher.keySize + cipher.ivSize,
        isCancelled: isCancelled
      )
    } catch .cancelled { throw .cancelled } catch { throw .malformed }
    defer { keyAndIV.resetBytes() }
    guard
      var plain = cipher.decrypt(
        envelope.section,
        tag: envelope.tag,
        keyAndIV: keyAndIV
      )
    else { throw .wrongPassphrase }
    defer { plain.resetBytes() }
    return try parsePrivateSection(
      plain,
      publicKey: envelope.publicKey,
      padding: cipher.blockSize,
      encrypted: true
    )
  }

  static func parse(_ input: Data) throws(OpenSSHImportError) -> Envelope {
    var bytes = try unarmor(input)
    defer { bytes.resetBytes() }
    guard bytes.count > magic.count, Array(bytes[..<magic.count]) == magic
    else { throw .malformed }
    var reader = SSHWireReader(Array(bytes[magic.count...]))
    defer { reader.reset() }
    guard let cipherName = reader.readText(maxLength: 64),
      let kdf = reader.readText(maxLength: 64),
      let kdfOptions = reader.readString(maxLength: 4096)
    else { throw .malformed }
    let encryption = try encryption(
      cipher: cipherName,
      kdf: kdf,
      options: kdfOptions
    )
    guard let count = reader.readUInt32() else { throw .malformed }
    guard count == 1 else {
      throw count == 0 ? .malformed : .unsupportedKeyCount(Int(count))
    }
    guard let blob = reader.readString(maxLength: 1024) else {
      throw .malformed
    }
    let publicKey = try canonicalPublicKey(blob: blob)
    guard let section = reader.readString(maxLength: maxInputBytes) else {
      throw .malformed
    }
    let tagSize = encryption?.cipher.tagSize ?? 0
    let tag = reader.readRest()
    guard tag.count == tagSize else { throw .malformed }
    let block = encryption?.cipher.blockSize ?? blockSize
    guard !section.isEmpty, section.count % block == 0 else {
      throw .invalidPadding
    }
    return Envelope(
      publicKey: publicKey,
      encryption: encryption,
      section: section,
      tag: tag
    )
  }

  /// The cipher and `bcrypt` parameters, bounded before any work is done.
  private static func encryption(
    cipher name: String,
    kdf: String,
    options: [UInt8]
  ) throws(OpenSSHImportError) -> (
    cipher: OpenSSHCipher, salt: [UInt8], rounds: Int
  )? {
    if name == "none" {
      guard kdf == "none", options.isEmpty else { throw .malformed }
      return nil
    }
    guard kdf != "none" else { throw .malformed }
    guard let cipher = OpenSSHCipher(name: name) else {
      throw .unsupportedCipher(name)
    }
    guard kdf == "bcrypt" else { throw .unsupportedKDF(kdf) }
    var reader = SSHWireReader(options)
    guard let salt = reader.readString(maxLength: maxSaltBytes), !salt.isEmpty,
      let rounds = reader.readUInt32(), reader.isAtEnd, rounds >= 1
    else { throw .malformed }
    guard rounds <= maxRounds else { throw .workFactorTooHigh(Int(rounds)) }
    return (cipher, salt, Int(rounds))
  }

  // MARK: Armor

  static func unarmor(_ input: Data) throws(OpenSSHImportError) -> [UInt8] {
    guard input.count <= maxInputBytes else { throw .inputTooLarge }
    guard let text = String(data: input, encoding: .utf8) else {
      throw .unrecognizedFormat
    }
    let lines = text.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard let first = lines.first else { throw .unrecognizedFormat }
    if first != beginArmor {
      throw classifyForeign(first: first, lineCount: lines.count)
    }
    guard lines.count >= 3, lines.last == endArmor,
      lines.dropFirst().dropLast().allSatisfy({ !$0.hasPrefix("-----") })
    else { throw .malformed }
    let body = lines.dropFirst().dropLast().joined()
    guard let data = Data(base64Encoded: body) else { throw .malformed }
    return Array(data)
  }

  private static func classifyForeign(
    first: String,
    lineCount: Int
  ) -> OpenSSHImportError {
    switch first {
    case "-----BEGIN RSA PRIVATE KEY-----": return .unsupportedFormat("PEM RSA")
    case "-----BEGIN DSA PRIVATE KEY-----": return .unsupportedFormat("PEM DSA")
    case "-----BEGIN PRIVATE KEY-----", "-----BEGIN ENCRYPTED PRIVATE KEY-----":
      return .unsupportedFormat("PKCS #8")
    case "---- BEGIN SSH2 PUBLIC KEY ----": return .publicKeyOnly
    default: break
    }
    let type = first.split(separator: " ").first.map(String.init) ?? ""
    if lineCount == 1, type.hasSuffix("-cert-v01@openssh.com") {
      return .certificate
    }
    if lineCount == 1,
      type.hasPrefix("ssh-") || type.hasPrefix("ecdsa-")
        || type.hasPrefix("sk-")
    {
      return .publicKeyOnly
    }
    return .unrecognizedFormat
  }

  /// The canonical line of a supported public-key blob.
  private static func canonicalPublicKey(
    blob: [UInt8]
  ) throws(OpenSSHImportError) -> String {
    var reader = SSHWireReader(blob)
    guard let type = reader.readText(maxLength: 128) else { throw .malformed }
    guard SSHKeyAlgorithm(rawValue: type) != nil else {
      throw type.contains("-cert-") ? .certificate : .unsupportedAlgorithm(type)
    }
    let line = type + " " + Data(blob).base64EncodedString()
    guard SSHKeyAlgorithm(canonicalPublicKeyLine: line) != nil else {
      throw .malformed
    }
    return line
  }

  // MARK: PEM ECDSA

  /// An unencrypted SEC 1 (`EC PRIVATE KEY`) or PKCS #8 (`PRIVATE KEY`)
  /// ECDSA key on P-256, P-384 or P-521; `nil` for any other armor.
  static func pemKey(
    _ input: Data
  ) throws(OpenSSHImportError) -> ImportedOpenSSHKey? {
    guard input.count <= maxInputBytes else { throw .inputTooLarge }
    guard let text = String(data: input, encoding: .utf8) else { return nil }
    let first = text.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .first { !$0.isEmpty }
    let label: String
    switch first {
    case "-----BEGIN EC PRIVATE KEY-----": label = "PEM EC"
    case "-----BEGIN PRIVATE KEY-----": label = "PKCS #8"
    default: return nil
    }
    if text.contains("Proc-Type: 4,ENCRYPTED") {
      throw .unsupportedFormat("Encrypted \(label)")
    }
    let key: SSHSigningKey
    if let p256 = try? P256.Signing.PrivateKey(pemRepresentation: text) {
      key = .p256(p256)
    } else if let p384 = try? P384.Signing.PrivateKey(pemRepresentation: text) {
      key = .p384(p384)
    } else if let p521 = try? P521.Signing.PrivateKey(pemRepresentation: text) {
      key = .p521(p521)
    } else {
      throw .unsupportedFormat(label)
    }
    return ImportedOpenSSHKey(secret: IdentitySecret(key: key), comment: nil)
  }

  // MARK: Private section

  /// `padding` is the cipher's block size. For a decrypted section,
  /// mismatched check integers mean the passphrase was wrong.
  static func parsePrivateSection(
    _ plain: [UInt8],
    publicKey: String,
    padding blockSize: Int,
    encrypted: Bool
  ) throws(OpenSSHImportError) -> ImportedOpenSSHKey {
    var reader = SSHWireReader(plain)
    defer { reader.reset() }
    guard let check1 = reader.readUInt32(), let check2 = reader.readUInt32()
    else { throw .malformed }
    guard check1 == check2 else {
      throw encrypted ? .wrongPassphrase : .malformed
    }
    guard let type = reader.readText(maxLength: 128) else { throw .malformed }
    guard let algorithm = SSHKeyAlgorithm(rawValue: type) else {
      throw .unsupportedAlgorithm(type)
    }
    guard algorithm == .ed25519 else {
      return try parseECDSASection(
        &reader,
        algorithm: algorithm,
        publicKey: publicKey,
        padding: blockSize
      )
    }
    guard let publicBytes = reader.readString(maxLength: 32),
      publicBytes.count == 32,
      var privateBytes = reader.readString(maxLength: 64),
      privateBytes.count == 64
    else { throw .malformed }
    defer { privateBytes.resetBytes() }
    guard let commentLength = reader.peekLength() else { throw .malformed }
    guard commentLength <= maxCommentBytes else { throw .commentTooLarge }
    guard let commentBytes = reader.readString(maxLength: maxCommentBytes)
    else { throw .malformed }
    let padding = reader.readRest()
    guard padding.count < blockSize,
      padding.enumerated().allSatisfy({ $0.element == UInt8($0.offset + 1) })
    else { throw .invalidPadding }
    let key: Curve25519.Signing.PrivateKey
    do {
      key = try Curve25519.Signing.PrivateKey(
        rawRepresentation: privateBytes[..<32]
      )
    } catch { throw .malformed }
    let derived = Array(key.publicKey.rawRepresentation)
    guard publicBytes == derived, Array(privateBytes[32...]) == derived,
      IdentitySecret(key).publicKeyLine == publicKey
    else { throw .keyMismatch }
    let comment = String(bytes: commentBytes, encoding: .utf8)
    return ImportedOpenSSHKey(
      secret: IdentitySecret(key),
      comment: comment?.isEmpty == false ? comment : nil
    )
  }
}

extension OpenSSHKeyImporter {
  /// `string curve, string Q, mpint d, string comment, padding` after the
  /// key type (PROTOCOL.key; RFC 5656 §3.1).
  static func parseECDSASection(
    _ reader: inout SSHWireReader,
    algorithm: SSHKeyAlgorithm,
    publicKey: String,
    padding blockSize: Int
  ) throws(OpenSSHImportError) -> ImportedOpenSSHKey {
    guard let curve = reader.readText(maxLength: 16),
      curve == algorithm.curveName,
      let point = reader.readString(maxLength: 133),
      var scalar = reader.readString(maxLength: 67)
    else { throw .malformed }
    defer { scalar.resetBytes() }
    guard let commentLength = reader.peekLength() else { throw .malformed }
    guard commentLength <= maxCommentBytes else { throw .commentTooLarge }
    guard let commentBytes = reader.readString(maxLength: maxCommentBytes)
    else { throw .malformed }
    let padding = reader.readRest()
    guard padding.count < blockSize,
      padding.enumerated().allSatisfy({ $0.element == UInt8($0.offset + 1) })
    else { throw .invalidPadding }
    // An mpint is big-endian two's complement: drop a sign byte, then
    // left-pad to the curve's scalar size.
    let size =
      switch algorithm {
      case .ecdsaP256: 32
      case .ecdsaP384: 48
      default: 66
      }
    var raw = Array(scalar.drop { $0 == 0 })
    defer { raw.resetBytes() }
    guard raw.count <= size else { throw .malformed }
    raw = [UInt8](repeating: 0, count: size - raw.count) + raw
    let key: SSHSigningKey
    let derivedPoint: [UInt8]
    do {
      switch algorithm {
      case .ecdsaP256:
        let k = try P256.Signing.PrivateKey(rawRepresentation: raw)
        key = .p256(k)
        derivedPoint = Array(k.publicKey.x963Representation)
      case .ecdsaP384:
        let k = try P384.Signing.PrivateKey(rawRepresentation: raw)
        key = .p384(k)
        derivedPoint = Array(k.publicKey.x963Representation)
      case .ecdsaP521:
        let k = try P521.Signing.PrivateKey(rawRepresentation: raw)
        key = .p521(k)
        derivedPoint = Array(k.publicKey.x963Representation)
      case .ed25519: throw OpenSSHImportError.malformed
      }
    } catch { throw .malformed }
    let secret = IdentitySecret(key: key)
    guard derivedPoint == point, secret.publicKeyLine == publicKey else {
      throw .keyMismatch
    }
    let comment = String(bytes: commentBytes, encoding: .utf8)
    return ImportedOpenSSHKey(
      secret: secret,
      comment: comment?.isEmpty == false ? comment : nil
    )
  }
}

/// Runs imports off the main actor, one at a time (§6.2, §6.4). A cancelled
/// import reports `.cancelled` and its result is discarded, so nothing is
/// persisted from it.
public actor OpenSSHImportGate {
  public static let shared = OpenSSHImportGate()

  public init() {}

  public func decode(
    _ input: Data,
    passphrase: String? = nil
  ) throws(OpenSSHImportError) -> ImportedOpenSSHKey {
    guard !Task.isCancelled else { throw .cancelled }
    let key = try OpenSSHKeyImporter.decode(
      input,
      passphrase: passphrase,
      isCancelled: { Task.isCancelled }
    )
    guard !Task.isCancelled else { throw .cancelled }
    return key
  }

  public func inspect(
    _ input: Data
  ) throws(OpenSSHImportError) -> OpenSSHKeyInspection {
    guard !Task.isCancelled else { throw .cancelled }
    return try OpenSSHKeyImporter.inspect(input)
  }
}

extension SSHWireReader {
  /// A UTF-8 string field.
  mutating func readText(maxLength: Int) -> String? {
    let start = offset
    guard let bytes = readString(maxLength: maxLength),
      let text = String(bytes: bytes, encoding: .utf8)
    else {
      rewind(to: start)
      return nil
    }
    return text
  }

  /// The next string's declared length, without consuming it.
  func peekLength() -> Int? {
    var copy = self
    return copy.readUInt32().map(Int.init)
  }
}

extension Array where Element == UInt8 {
  /// Best-effort clearing of an owned buffer; not a guarantee that no other
  /// copy exists (§7.2).
  mutating func resetBytes() {
    withUnsafeMutableBytes {
      _ = memset_s($0.baseAddress, $0.count, 0, $0.count)
    }
  }
}
