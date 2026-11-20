#if os(macOS)
import Crypto
import Foundation
import Security
import SessionCore
import X509

public enum HostIdentityError: Error, Equatable, Sendable {
  case invalidValidity
  case certificateEncoding
  case keyImport(Int32)
  case certificateImport
  case identityCreation
  case storage(String)
  case insecureStorage(String)
}

/// The `swifttyd` QUIC/TLS server identity (spec §5.2, §14 Gate 0).
///
/// A fresh P-256 key owned by the helper, independent of the SSH host key.
/// The self-issued certificate is trusted only because its exact DER and
/// SHA-256 travel inside the SSH-authenticated bootstrap grant
/// (`CertificatePin`).
///
/// ## Why `SecIdentityCreate`
///
/// Network framework needs a `SecIdentity`. Alternatives on macOS 27:
///
/// - `SecPKCS12Import` with `kSecImportToMemoryOnly` needs a
///   password-protected PKCS #12 blob that swift-certificates cannot
///   produce; hand-rolling PKCS #12 is needless crypto surface.
/// - A private file keychain relies on the deprecated `SecKeychain` APIs.
/// - The data-protection keychain needs a keychain-access-group entitlement
///   that an unsigned/ad-hoc helper and the test runner lack
///   (`errSecMissingEntitlement`).
/// - **Chosen:** `SecIdentityCreate(_:_:_:)` (public in the OS 27 SDKs)
///   pairs an in-memory `SecCertificate` with a `SecKeyCreateWithData` key.
///   Nothing touches the keychain, so the helper runs as a plain per-user
///   launchd agent.
///
/// Persisted as `host-key.raw` (32-byte P-256 scalar) and `host-cert.der`,
/// each written 0600 atomically in an owner-only (0700) directory.
/// Ownership and permissions are verified on load; a group/other-accessible
/// file is refused. The certificate is replaced near expiry or when its
/// SANs change; clients then get the new pin through fresh SSH auth.
///
/// Sendable: immutable after init; the retained `SecIdentity` is an
/// immutable, thread-safe CF object.
public struct HostIdentity: @unchecked Sendable {
  public let certificateDER: Data
  /// Lowercase hex SHA-256 of `certificateDER` for the bootstrap grant.
  public let certificateSHA256: String
  /// Lowercase hex SHA-256 of the certificate's DER SubjectPublicKeyInfo:
  /// the QUIC pin every bootstrap grant carries.
  public let spkiSHA256: String
  public let notValidBefore: Date
  public let notValidAfter: Date
  public let secIdentity: SecIdentity

  public static let defaultValidity: TimeInterval = 30 * 24 * 3600
  /// Regenerate when less than this remains.
  public static let renewalMargin: TimeInterval = 3 * 24 * 3600
  static let backdate: TimeInterval = 5 * 60
  static let keyFile = "host-key.raw"
  static let certificateFile = "host-cert.der"
  /// Local persistence and generated-certificate bound, in DER bytes.
  public static let maxCertificateBytes = 64 * 1024

  public var pin: CertificatePin {
    CertificatePin(certificateDER: certificateDER)
  }

  public var protocolIdentity: sec_identity_t? {
    sec_identity_create(secIdentity)
  }

  /// - Parameters:
  ///   - hostnames: SAN DNS names. Descriptive only: clients pin the exact DER.
  ///   - ipAddresses: Textual IPv4/IPv6 addresses for IP SANs.
  ///   - validity: Lifetime in seconds, greater than zero, at most 397 days.
  ///   - now: Reference time for expiry and the backdated validity start.
  /// - Returns: A fresh key and certificate paired as an in-memory identity.
  /// - Throws: If the lifetime is invalid, construction fails, or Security
  ///   cannot pair the key and certificate.
  public static func generate(
    hostnames: [String] = [],
    ipAddresses: [String] = [],
    validity: TimeInterval = defaultValidity,
    now: Date = Date()
  ) throws -> HostIdentity {
    let key = P256.Signing.PrivateKey()
    let der = try makeCertificate(
      key: key,
      hostnames: hostnames,
      ipAddresses: ipAddresses,
      validity: validity,
      now: now
    )
    return try HostIdentity(key: key, certificateDER: der)
  }

  /// Loads the persisted identity from `directory`, generating and
  /// storing a new one when absent, unreadable, near expiry, or issued
  /// for different names.
  public static func loadOrCreate(
    directory: URL,
    hostnames: [String] = [],
    ipAddresses: [String] = [],
    validity: TimeInterval = defaultValidity,
    now: Date = Date()
  ) throws -> HostIdentity {
    let storage = try HostIdentityStorage(directory: directory, create: true)
    if let existing = try? load(storage: storage),
      existing.notValidBefore <= now,
      existing.notValidAfter.timeIntervalSince(now) > renewalMargin,
      existing.matches(hostnames: hostnames, ipAddresses: ipAddresses)
    {
      return existing
    }
    let key = P256.Signing.PrivateKey()
    let der = try makeCertificate(
      key: key,
      hostnames: hostnames,
      ipAddresses: ipAddresses,
      validity: validity,
      now: now
    )
    let identity = try HostIdentity(key: key, certificateDER: der)
    try storage.write(key.rawRepresentation, to: .key)
    try storage.write(der, to: .certificate)
    return identity
  }

  /// Loads a persisted identity, verifying owner-only permissions.
  public static func load(directory: URL) throws -> HostIdentity {
    try load(storage: HostIdentityStorage(directory: directory))
  }

  private static func load(storage: HostIdentityStorage) throws -> HostIdentity
  {
    do {
      let key = try P256.Signing.PrivateKey(
        rawRepresentation: try storage.read(.key)
      )
      return try HostIdentity(
        key: key,
        certificateDER: try storage.read(.certificate)
      )
    } catch let error as HostIdentityError { throw error } catch {
      throw HostIdentityError.storage("unreadable identity")
    }
  }

  init(key: P256.Signing.PrivateKey, certificateDER: Data) throws {
    guard !certificateDER.isEmpty,
      certificateDER.count <= Self.maxCertificateBytes
    else { throw HostIdentityError.certificateEncoding }
    let certificate: Certificate
    do {
      certificate = try Certificate(derEncoded: Array(certificateDER))
    } catch { throw HostIdentityError.certificateEncoding }
    // The certificate must certify this key.
    guard certificate.publicKey == Certificate.PublicKey(key.publicKey) else {
      throw HostIdentityError.identityCreation
    }

    let attributes: [CFString: Any] = [
      kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
      kSecAttrKeyClass: kSecAttrKeyClassPrivate, kSecAttrKeySizeInBits: 256,
    ]
    var error: Unmanaged<CFError>?
    // SecKey's external private-key format is 04 || X || Y || D.
    guard
      let secKey = SecKeyCreateWithData(
        key.x963Representation as CFData,
        attributes as CFDictionary,
        &error
      )
    else {
      let code = error.map { CFErrorGetCode($0.takeRetainedValue()) } ?? 0
      throw HostIdentityError.keyImport(Int32(truncatingIfNeeded: code))
    }
    guard
      let secCertificate = SecCertificateCreateWithData(
        nil,
        certificateDER as CFData
      )
    else { throw HostIdentityError.certificateImport }
    guard let identity = SecIdentityCreate(nil, secCertificate, secKey) else {
      throw HostIdentityError.identityCreation
    }

    self.certificateDER = certificateDER
    self.certificateSHA256 = CertificatePin.fingerprint(certificateDER)
    guard let spkiSHA256 = try? CertificatePin.spkiFingerprint(certificateDER)
    else { throw HostIdentityError.certificateEncoding }
    self.spkiSHA256 = spkiSHA256
    self.notValidBefore = certificate.notValidBefore
    self.notValidAfter = certificate.notValidAfter
    self.secIdentity = identity
  }

  func matches(hostnames: [String], ipAddresses: [String]) -> Bool {
    guard let certificate = try? Certificate(derEncoded: Array(certificateDER)),
      let expected = try? Self.subjectAlternativeNames(
        hostnames: hostnames,
        ipAddresses: ipAddresses
      )
    else { return false }
    let actual = (try? certificate.extensions.subjectAlternativeNames) ?? nil
    return Set(actual.map(Array.init) ?? []) == Set(expected)
  }

  // MARK: Certificate construction

  static func subjectAlternativeNames(
    hostnames: [String],
    ipAddresses: [String]
  ) throws -> [GeneralName] {
    var names = hostnames.map { GeneralName.dnsName($0) }
    for text in ipAddresses {
      guard let bytes = ipBytes(text) else {
        throw HostIdentityError.certificateEncoding
      }
      names.append(.ipAddress(.init(contentBytes: ArraySlice(bytes))))
    }
    return names
  }

  static func makeCertificate(
    key: P256.Signing.PrivateKey,
    hostnames: [String],
    ipAddresses: [String],
    validity: TimeInterval,
    now: Date
  ) throws -> Data {
    guard validity > 0, validity <= 397 * 24 * 3600 else {
      throw HostIdentityError.invalidValidity
    }
    let names = try subjectAlternativeNames(
      hostnames: hostnames,
      ipAddresses: ipAddresses
    )
    let subject = try DistinguishedName {
      CommonName("swifttyd")
      OrganizationName("swiftty RST/1")
    }
    var serial = secureRandomBytes(20)
    serial[0] &= 0x7F  // Positive, at most 20 octets (RFC 5280 §4.1.2.2).
    if serial[0] == 0 { serial[0] = 1 }
    let extensions = try Certificate.Extensions {
      Critical(BasicConstraints.notCertificateAuthority)
      Critical(KeyUsage(digitalSignature: true))
      try ExtendedKeyUsage([.serverAuth])
      SubjectKeyIdentifier(hash: Certificate.PublicKey(key.publicKey))
      if !names.isEmpty { SubjectAlternativeNames(names) }
    }
    let certificate = try Certificate(
      version: .v3,
      serialNumber: Certificate.SerialNumber(bytes: ArraySlice(serial)),
      publicKey: Certificate.PublicKey(key.publicKey),
      notValidBefore: now.addingTimeInterval(-backdate),
      notValidAfter: now.addingTimeInterval(validity),
      issuer: subject,
      subject: subject,
      signatureAlgorithm: .ecdsaWithSHA256,
      extensions: extensions,
      issuerPrivateKey: Certificate.PrivateKey(key)
    )
    do { return Data(try certificate.serializeAsPEM().derBytes) } catch {
      throw HostIdentityError.certificateEncoding
    }
  }

  static func ipBytes(_ text: String) -> [UInt8]? {
    var v4 = in_addr()
    if inet_pton(AF_INET, text, &v4) == 1 {
      return withUnsafeBytes(of: v4) { Array($0) }
    }
    var v6 = in6_addr()
    if inet_pton(AF_INET6, text, &v6) == 1 {
      return withUnsafeBytes(of: v6) { Array($0) }
    }
    return nil
  }

}
#endif
