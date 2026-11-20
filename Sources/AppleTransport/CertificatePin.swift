import Crypto
import Foundation
import SessionCore
import X509

public enum CertificatePinError: Error, Equatable, Sendable {
  /// The fingerprint is not 64 hexadecimal digits.
  case malformedFingerprint
  /// The pinned DER does not hash to the pinned fingerprint.
  case inconsistentPin
  case missingCertificate
  /// The peer's leaf hashes to a different fingerprint.
  case fingerprintMismatch
  /// The peer's leaf DER differs from the pinned DER.
  case certificateMismatch
  /// The peer's leaf SubjectPublicKeyInfo hashes to a different SPKI pin.
  case spkiMismatch
  /// The pinned DER is not a parseable X.509 certificate.
  case malformedCertificate
  case notYetValid
  case expired
}

/// Server certificate delivered through the SSH-authenticated bootstrap
/// (spec §5.2; spec.inbox.md §1.8): a connection-scoped trust anchor with
/// no system trust, no other self-signed certificate, no chain building.
///
/// The QUIC pin is the SHA-256 of the leaf's DER SubjectPublicKeyInfo
/// (`spkiSHA256`). When a grant carries it, the leaf must match it and, as
/// defence in depth, be byte-identical to the delivered certificate, so a
/// certificate rotated under the same key still needs a fresh grant. Grants
/// from older hosts omit the SPKI pin and are checked by exact certificate
/// only. The check runs in the TLS verify block, so a changed pin fails the
/// handshake before the resume capability (`Attach` token) can be sent.
public struct CertificatePin: Hashable, Sendable {
  public let certificateDER: Data
  /// Lowercase hex SHA-256 of `certificateDER`.
  public let sha256: String
  /// Lowercase hex SHA-256 of the certificate's DER SubjectPublicKeyInfo,
  /// when the grant carried one.
  public let spkiSHA256: String?

  /// The SPKI pin is computed only when the DER parses as X.509.
  public init(certificateDER: Data) {
    self.certificateDER = certificateDER
    self.sha256 = Self.fingerprint(certificateDER)
    self.spkiSHA256 = try? Self.spkiFingerprint(certificateDER)
  }

  /// Fails when the DER does not hash to `sha256` or does not contain the key
  /// `spkiSHA256` names, so an inconsistent grant is never trusted.
  /// `spkiSHA256`, when present, must be exactly 64 lowercase hex digits.
  public init(
    certificateDER: Data,
    sha256: String,
    spkiSHA256: String? = nil
  ) throws(CertificatePinError) {
    guard bytes(fromHex: sha256, count: SHA256.byteCount) != nil else {
      throw .malformedFingerprint
    }
    if let spkiSHA256, !Self.isLowercaseFingerprint(spkiSHA256) {
      throw .malformedFingerprint
    }
    let actual = Self.fingerprint(certificateDER)
    guard actual == sha256.lowercased() else { throw .inconsistentPin }
    if let spkiSHA256 {
      guard try Self.spkiFingerprint(certificateDER) == spkiSHA256 else {
        throw .inconsistentPin
      }
    }
    self.certificateDER = certificateDER
    self.sha256 = actual
    self.spkiSHA256 = spkiSHA256
  }

  /// Lowercase hex SHA-256 of `der`.
  public static func fingerprint(_ der: Data) -> String {
    hexString(SHA256.hash(data: der))
  }

  /// The QUIC pin (RFC 7469 style): lowercase hex SHA-256 of the certificate's
  /// SubjectPublicKeyInfo, hashed as it appears in the DER, never re-encoded.
  public static func spkiFingerprint(
    _ der: Data
  ) throws(CertificatePinError) -> String {
    // Parse fully first so only a well-formed certificate is ever pinned.
    guard (try? Certificate(derEncoded: Array(der))) != nil,
      let spki = subjectPublicKeyInfo(Array(der))
    else { throw .malformedCertificate }
    return hexString(SHA256.hash(data: spki))
  }

  static func isLowercaseFingerprint(_ text: String) -> Bool {
    text.utf8.count == SHA256.byteCount * 2
      && text.utf8.allSatisfy {
        (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains($0)
          || (UInt8(ascii: "a") ... UInt8(ascii: "f")).contains($0)
      }
  }

  /// The encoded SubjectPublicKeyInfo element of a DER certificate:
  /// `Certificate ::= SEQUENCE { tbsCertificate SEQUENCE { [0] version
  /// OPTIONAL, serialNumber, signature, issuer, validity, subject,
  /// subjectPublicKeyInfo, ... }, ... }`.
  static func subjectPublicKeyInfo(_ der: [UInt8]) -> ArraySlice<UInt8>? {
    guard let certificate = DERElement(der[...]), certificate.tag == 0x30,
      let tbs = DERElement(certificate.content), tbs.tag == 0x30
    else { return nil }
    var rest = tbs.content
    var element = DERElement(rest)
    // Explicit [0] version.
    if let version = element, version.tag == 0xA0 {
      rest = rest[version.encoded.endIndex...]
      element = DERElement(rest)
    }
    // serialNumber, signature, issuer, validity, subject.
    for _ in 0 ..< 5 {
      guard let skipped = element else { return nil }
      rest = rest[skipped.encoded.endIndex...]
      element = DERElement(rest)
    }
    guard let spki = element, spki.tag == 0x30 else { return nil }
    return spki.encoded
  }

  /// Checks the SPKI pin (when pinned), fingerprint, DER, and validity window
  /// at `now`. Pure; the TLS verify block fails closed on any error.
  public func validate(
    leafDER: Data?,
    now: Date = Date()
  ) throws(CertificatePinError) {
    guard let leafDER, !leafDER.isEmpty else { throw .missingCertificate }
    if let spkiSHA256 {
      guard try Self.spkiFingerprint(leafDER) == spkiSHA256 else {
        throw .spkiMismatch
      }
    }
    guard Self.fingerprint(leafDER) == sha256 else {
      throw .fingerprintMismatch
    }
    guard leafDER == certificateDER else { throw .certificateMismatch }
    let certificate: Certificate
    do { certificate = try Certificate(derEncoded: Array(leafDER)) } catch {
      throw .malformedCertificate
    }
    guard now >= certificate.notValidBefore else { throw .notYetValid }
    guard now <= certificate.notValidAfter else { throw .expired }
  }
}

/// One DER TLV with a single-byte tag and a definite length.
private struct DERElement {
  let tag: UInt8
  /// The whole element: tag, length and content.
  let encoded: ArraySlice<UInt8>
  let content: ArraySlice<UInt8>

  init?(_ bytes: ArraySlice<UInt8>) {
    var i = bytes.startIndex
    guard i < bytes.endIndex else { return nil }
    let tag = bytes[i]
    // High-tag-number form never appears in the fields walked here.
    guard tag & 0x1F != 0x1F else { return nil }
    i += 1
    guard i < bytes.endIndex else { return nil }
    let first = bytes[i]
    i += 1
    var length = 0
    if first < 0x80 {
      length = Int(first)
    } else {
      let count = Int(first & 0x7F)
      // Indefinite length (0x80) is not DER; cap at 4 length octets.
      guard (1 ... 4).contains(count), bytes.endIndex - i >= count else {
        return nil
      }
      for _ in 0 ..< count {
        length = length << 8 | Int(bytes[i])
        i += 1
      }
    }
    guard length <= bytes.endIndex - i else { return nil }
    self.tag = tag
    self.content = bytes[i ..< i + length]
    self.encoded = bytes[bytes.startIndex ..< i + length]
  }
}
