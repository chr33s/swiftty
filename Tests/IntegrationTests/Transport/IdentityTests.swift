#if os(macOS)
@testable import AppleTransport
import Crypto
import Foundation
import ScreenProtocol
import SessionCore
import Testing
import TestSupport
import X509

struct IdentityTests {
  @Test
  func `generated certificate matches its fingerprint and validity`() throws {
    let now = Date()
    let identity = try HostIdentity.generate(
      hostnames: ["mac.example"],
      ipAddresses: ["127.0.0.1", "::1"],
      now: now
    )
    #expect(
      identity.certificateSHA256
        == hexString(SHA256.hash(data: identity.certificateDER))
    )
    #expect(identity.certificateSHA256.count == 64)
    #expect(
      identity.certificateSHA256 == identity.certificateSHA256.lowercased()
    )

    let certificate = try Certificate(
      derEncoded: Array(identity.certificateDER)
    )
    #expect(certificate.notValidBefore <= now)
    #expect(certificate.notValidAfter > now)
    #expect(
      certificate.notValidAfter.timeIntervalSince(now) <= HostIdentity
        .defaultValidity + 1
    )
    #expect(certificate.issuer == certificate.subject)
    let names = try #require(try certificate.extensions.subjectAlternativeNames)
    #expect(names.contains(.dnsName("mac.example")))
    #expect(names.contains(.ipAddress(.init(contentBytes: [127, 0, 0, 1]))))
    #expect(
      try certificate.extensions.basicConstraints == .notCertificateAuthority
    )
    #expect(identity.protocolIdentity != nil)
    try identity.pin.validate(leafDER: identity.certificateDER, now: now)
  }

  @Test
  func `pin validation is exact and date bounded`() throws {
    let now = Date()
    let identity = try HostIdentity.generate(validity: 3600, now: now)
    let other = try HostIdentity.generate(now: now)
    let pin = try CertificatePin(
      certificateDER: identity.certificateDER,
      sha256: identity.certificateSHA256.uppercased()
    )
    #expect(pin.sha256 == identity.certificateSHA256)
    try pin.validate(leafDER: identity.certificateDER, now: now)

    #expect(throws: CertificatePinError.fingerprintMismatch) {
      try pin.validate(leafDER: other.certificateDER, now: now)
    }
    #expect(throws: CertificatePinError.missingCertificate) {
      try pin.validate(leafDER: nil, now: now)
    }
    #expect(throws: CertificatePinError.expired) {
      try pin.validate(leafDER: identity.certificateDER, now: now + 7200)
    }
    #expect(throws: CertificatePinError.notYetValid) {
      try pin.validate(leafDER: identity.certificateDER, now: now - 3600)
    }
    #expect(throws: CertificatePinError.malformedFingerprint) {
      try CertificatePin(certificateDER: identity.certificateDER, sha256: "zz")
    }
    // Not a certificate at all, even if pinned exactly.
    let junk = Data([1, 2, 3])
    #expect(throws: CertificatePinError.malformedCertificate) {
      try CertificatePin(certificateDER: junk).validate(leafDER: junk)
    }
  }

  @Test
  func `SPKI pin is the hash of the certificate's SubjectPublicKeyInfo`() throws
  {
    let identity = try HostIdentity.generate(ipAddresses: ["127.0.0.1"])
    // Independent derivation: the fixed P-256 SPKI header followed by the
    // uncompressed point the Security framework reports for the key.
    let certificate = try #require(
      SecCertificateCreateWithData(nil, identity.certificateDER as CFData)
    )
    let key = try #require(SecCertificateCopyKey(certificate))
    let point = try #require(
      SecKeyCopyExternalRepresentation(key, nil) as Data?
    )
    let header = try #require(
      bytes(
        fromHex: "3059301306072a8648ce3d020106082a8648ce3d030107034200",
        count: 26
      )
    )
    let expected = hexString(SHA256.hash(data: header + Array(point)))
    #expect(identity.spkiSHA256 == expected)
    #expect(
      try CertificatePin.spkiFingerprint(identity.certificateDER) == expected
    )
    #expect(identity.pin.spkiSHA256 == expected)
    #expect(identity.spkiSHA256 != identity.certificateSHA256)
    #expect(throws: CertificatePinError.malformedCertificate) {
      try CertificatePin.spkiFingerprint(Data([0x30, 0x03, 0x02, 0x01, 0x01]))
    }
  }

  @Test
  func `SPKI pin is verified before the exact certificate`() throws {
    let now = Date()
    let identity = try HostIdentity.generate(now: now)
    let other = try HostIdentity.generate(now: now)
    let pin = try CertificatePin(
      certificateDER: identity.certificateDER,
      sha256: identity.certificateSHA256,
      spkiSHA256: identity.spkiSHA256
    )
    try pin.validate(leafDER: identity.certificateDER, now: now)
    // A different key fails on the SPKI pin first.
    #expect(throws: CertificatePinError.spkiMismatch) {
      try pin.validate(leafDER: other.certificateDER, now: now)
    }
    // A grant whose SPKI pin names another key is inconsistent.
    #expect(throws: CertificatePinError.inconsistentPin) {
      try CertificatePin(
        certificateDER: identity.certificateDER,
        sha256: identity.certificateSHA256,
        spkiSHA256: other.spkiSHA256
      )
    }
    // The SPKI pin must be exactly 64 lowercase hex digits.
    for malformed in [
      identity.spkiSHA256.uppercased(), "zz",
      String(identity.spkiSHA256.dropLast()),
    ] {
      #expect(throws: CertificatePinError.malformedFingerprint) {
        try CertificatePin(
          certificateDER: identity.certificateDER,
          sha256: identity.certificateSHA256,
          spkiSHA256: malformed
        )
      }
    }
    // Grants from older hosts carry no SPKI pin: exact DER still applies.
    let legacy = try CertificatePin(
      certificateDER: identity.certificateDER,
      sha256: identity.certificateSHA256
    )
    #expect(legacy.spkiSHA256 == nil)
    try legacy.validate(leafDER: identity.certificateDER, now: now)
    #expect(throws: CertificatePinError.fingerprintMismatch) {
      try legacy.validate(leafDER: other.certificateDER, now: now)
    }
  }

  @Test
  func `identity persists owner-only and renews on name change`() throws {
    let base = FileManager.default.temporaryDirectory.appending(
      path: "rst-identity-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: base) }
    let directory = base.appending(path: "tls")
    try FileManager.default.createDirectory(
      at: base,
      withIntermediateDirectories: true
    )

    let first = try HostIdentity.loadOrCreate(
      directory: directory,
      hostnames: ["a.example"]
    )
    for (name, mode) in [
      (".", 0o700), (HostIdentity.keyFile, 0o600),
      (HostIdentity.certificateFile, 0o600),
    ] {
      let attributes = try FileManager.default.attributesOfItem(
        atPath: directory.appending(path: name).path(percentEncoded: false)
      )
      #expect((attributes[.posixPermissions] as? Int) == mode)
    }

    let again = try HostIdentity.loadOrCreate(
      directory: directory,
      hostnames: ["a.example"]
    )
    #expect(again.certificateDER == first.certificateDER)

    let renamed = try HostIdentity.loadOrCreate(
      directory: directory,
      hostnames: ["b.example"]
    )
    #expect(renamed.certificateDER != first.certificateDER)

    // A widened key file is refused, never silently used.
    let keyPath = directory.appending(path: HostIdentity.keyFile)
      .path(percentEncoded: false)
    chmod(keyPath, 0o644)
    #expect(throws: HostIdentityError.insecureStorage(HostIdentity.keyFile)) {
      try HostIdentity.load(directory: directory)
    }
  }

  @Test
  func oversizedChunkCountDoesNotOverflow() throws {
    var accumulator = SnapshotStreamAccumulator()
    try accumulator.append([0, 0, 0, 0])
    let input = ReadCountingBytes(prefix: [], count: Int.max)
    #expect(throws: FramingError.snapshotTooLarge) {
      try accumulator.append(input)
    }
    #expect(input.elementReads == 0)
    #expect(accumulator.bytes.count == 4)
  }

  @Test
  func snapshotAccumulatorRejectsExcessBeforeReadingBody() {
    let input = ReadCountingBytes(
      prefix: [2, 0, 0, 0, 1, 0, 0, 0, 1],
      count: 1024 * 1024
    )
    var accumulator = SnapshotStreamAccumulator()
    #expect(throws: FramingError.trailingData) { try accumulator.append(input) }
    #expect(input.elementReads == SnapshotFrame.headerLength)
    #expect(accumulator.bytes.count == SnapshotFrame.headerLength)
  }

  @Test
  func `snapshot accumulator enforces header bounds`() throws {
    let payload = snapshotPayload(bodyLength: 100, fill: 7)
    var accumulator = SnapshotStreamAccumulator()
    try accumulator.append(payload.prefix(4))
    #expect(accumulator.expectedLength == nil)
    try accumulator.append(payload.dropFirst(4))
    #expect(try accumulator.finish() == payload)

    var overlong = SnapshotStreamAccumulator()
    #expect(throws: FramingError.trailingData) {
      try overlong.append(payload + [0])
    }
    var truncated = SnapshotStreamAccumulator()
    try truncated.append(payload.prefix(50))
    #expect(throws: FramingError.truncated) { try truncated.finish() }
    #expect(truncated.nextReadLimit == payload.count - 50 + 1)

    var oversized = snapshotPayload(bodyLength: 0, fill: 0)
    oversized[5] = 0xFF
    var big = SnapshotStreamAccumulator()
    #expect(throws: FramingError.snapshotTooLarge) { try big.append(oversized) }
  }

  @Test
  func `token bucket admits a burst then refills`() {
    var bucket = TokenBucket(capacity: 2, refillPerSecond: 1)
    let t0 = ContinuousClock.now
    let results = [
      bucket.take(now: t0), bucket.take(now: t0), bucket.take(now: t0),
      bucket.take(now: t0 + .milliseconds(500)),
      bucket.take(now: t0 + .milliseconds(1100)),
    ]
    #expect(results == [true, true, false, false, true])
  }
}
#endif
