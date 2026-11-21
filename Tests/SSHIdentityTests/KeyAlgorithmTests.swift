import Crypto
import Foundation
import SSHClient
import Testing

@testable import SSHIdentity

/// spec.ssh-identity.md §13: ECDSA identities, Secure Enclave storage and
/// saved passwords.
@Suite
struct KeyAlgorithmTests {
  let device = UUID()

  static func fixture(_ name: String) throws -> Data {
    let url = try #require(
      Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
    )
    return try Data(contentsOf: url)
  }

  /// The `"<type> <base64>"` part of a `.pub` fixture.
  static func publicLine(_ name: String) throws -> String {
    let text = String(decoding: try fixture("\(name).pub"), as: UTF8.self)
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: " ").prefix(2).joined(separator: " ")
  }

  @Test(arguments: [
    ("ecdsa256", SSHKeyAlgorithm.ecdsaP256), ("ecdsa384", .ecdsaP384),
    ("ecdsa521", .ecdsaP521),
  ])
  func importsOpenSSHECDSAKeys(name: String, algorithm: SSHKeyAlgorithm) throws
  {
    let data = try Self.fixture(name)
    let key = try OpenSSHKeyImporter.decode(data)
    #expect(key.secret.key.algorithm == algorithm)
    #expect(key.secret.publicKeyLine == (try Self.publicLine(name)))
    #expect(key.comment == "\(name)@fixture")
    let inspection = try OpenSSHKeyImporter.inspect(data)
    #expect(inspection.algorithm == algorithm.rawValue)
    #expect(inspection.fingerprint == key.fingerprint)
  }

  @Test
  func importsPassphraseProtectedECDSA() throws {
    let data = try Self.fixture("ecdsa256-aes")
    let inspection = try OpenSSHKeyImporter.inspect(data)
    #expect(inspection.isEncrypted)
    #expect(throws: OpenSSHImportError.passphraseRequired) {
      try OpenSSHKeyImporter.decode(data)
    }
    #expect(throws: OpenSSHImportError.wrongPassphrase) {
      try OpenSSHKeyImporter.decode(data, passphrase: "wrong")
    }
    let key = try OpenSSHKeyImporter.decode(data, passphrase: "correct horse")
    #expect(key.secret.key.algorithm == .ecdsaP256)
    #expect(key.fingerprint == inspection.fingerprint)
  }

  @Test
  func importsPEMECDSA() throws {
    let key = try OpenSSHKeyImporter.decode(try Self.fixture("ecdsa-pem-named"))
    #expect(
      key.secret.publicKeyLine == (try Self.publicLine("ecdsa-pem-named"))
    )
    #expect(key.comment == nil)
    // Explicit curve parameters are refused rather than interpreted.
    #expect(throws: OpenSSHImportError.unsupportedFormat("PEM EC")) {
      try OpenSSHKeyImporter.decode(try Self.fixture("ecdsa-pem"))
    }
  }

  @Test
  func refusesEncryptedPEM() {
    let pem = """
      -----BEGIN EC PRIVATE KEY-----
      Proc-Type: 4,ENCRYPTED
      DEK-Info: AES-128-CBC,00000000000000000000000000000000

      AAAA
      -----END EC PRIVATE KEY-----
      """
    #expect(throws: OpenSSHImportError.unsupportedFormat("Encrypted PEM EC")) {
      try OpenSSHKeyImporter.decode(Data(pem.utf8))
    }
  }

  @Test
  func everyAlgorithmRoundTripsThroughTheKeychainPayload() throws {
    for algorithm in SSHKeyAlgorithm.allCases {
      let secret = IdentitySecret(key: .generate(algorithm))
      let restored = try #require(IdentitySecret(payload: secret.payload))
      #expect(restored.publicKeyLine == secret.publicKeyLine)
      #expect(restored.key.algorithm == algorithm)
      #expect(
        SSHKeyAlgorithm(canonicalPublicKeyLine: secret.publicKeyLine)
          == algorithm
      )
    }
    // Unknown formats and curves are refused, not guessed.
    #expect(IdentitySecret(payload: Data([9, 1, 2])) == nil)
    #expect(IdentitySecret(payload: Data([2, 7]) + Data(count: 32)) == nil)
    #expect(IdentitySecret(payload: Data([1]) + Data(count: 31)) == nil)
  }

  @Test
  func ecdsaMetadataValidates() throws {
    let secret = IdentitySecret(key: .generate(.ecdsaP384))
    let metadata = SSHIdentityMetadata(
      name: "Server",
      publicKeyLine: secret.publicKeyLine,
      storage: .iCloudKeychain,
      revision: LogicalRevision(counter: 1, deviceID: device)
    )
    try metadata.validate()
    #expect(metadata.algorithm == "ecdsa-sha2-nistp384")
    #expect(metadata.keyTypeLabel == "ECDSA P-384")
    #expect(metadata.fingerprint == secret.fingerprint)
    #expect(metadata.authorizedKeysLine == secret.publicKeyLine + " Server")
  }

  @Test
  func secureEnclaveStorageIsP256Only() throws {
    let ed = IdentitySecret(Curve25519.Signing.PrivateKey())
    let invalid = SSHIdentityMetadata(
      name: "Phone",
      publicKeyLine: ed.publicKeyLine,
      storage: .secureEnclave,
      revision: LogicalRevision(counter: 1, deviceID: device)
    )
    #expect(throws: SSHIdentityMetadata.ValidationError.unsupportedAlgorithm) {
      try invalid.validate()
    }
    let p256 = IdentitySecret(key: .generate(.ecdsaP256))
    let valid = SSHIdentityMetadata(
      name: "Phone",
      publicKeyLine: p256.publicKeyLine,
      storage: .secureEnclave,
      revision: LogicalRevision(counter: 1, deviceID: device)
    )
    try valid.validate()
    #expect(valid.keyTypeLabel == "P-256 · Secure Enclave")
    #expect(IdentityStoragePolicy.secureEnclave.isDeviceBound)
    #expect(!IdentityStoragePolicy.softwareCases.contains(.secureEnclave))
  }

  @Test
  func tamperedMetadataIsRejected() {
    let secret = IdentitySecret(key: .generate(.ecdsaP256))
    let other = IdentitySecret(key: .generate(.ecdsaP256))
    let mismatched = SSHIdentityMetadata(
      id: UUID(),
      name: "Server",
      algorithm: SSHKeyAlgorithm.ecdsaP256.rawValue,
      publicKey: secret.publicKeyLine,
      fingerprint: other.fingerprint,
      storage: .deviceOnly,
      createdAt: .now,
      revision: LogicalRevision(counter: 1, deviceID: device),
      deletedAt: nil
    )
    #expect(throws: SSHIdentityMetadata.ValidationError.fingerprintMismatch) {
      try mismatched.validate()
    }
    let wrongType = SSHIdentityMetadata(
      id: UUID(),
      name: "Server",
      algorithm: SSHKeyAlgorithm.ecdsaP384.rawValue,
      publicKey: secret.publicKeyLine,
      fingerprint: secret.fingerprint,
      storage: .deviceOnly,
      createdAt: .now,
      revision: LogicalRevision(counter: 1, deviceID: device),
      deletedAt: nil
    )
    #expect(throws: SSHIdentityMetadata.ValidationError.invalidPublicKey) {
      try wrongType.validate()
    }
  }

  @Test
  func resolvesECDSAAndRefusesTheWrongNamespace() async throws {
    let store = InMemoryIdentitySecretStore()
    let secret = IdentitySecret(key: .generate(.ecdsaP521))
    let metadata = SSHIdentityMetadata(
      name: "Server",
      publicKeyLine: secret.publicKeyLine,
      storage: .deviceOnly,
      revision: LogicalRevision(counter: 1, deviceID: device)
    )
    try await store.add(secret, id: metadata.id, policy: .deviceOnly)
    let resolved = try await IdentityResolver(secrets: store).resolve(metadata)
    #expect(resolved.publicKeyLine == secret.publicKeyLine)
    guard case .publicKey = resolved.credential else {
      Issue.record("Expected a public-key credential")
      return
    }
    // A software key is never accepted into the Secure Enclave namespace.
    await #expect(throws: IdentitySecretError.malformed) {
      try await store.add(secret, id: UUID(), policy: .secureEnclave)
    }
  }

  @Test
  func secureEnclaveMetadataFromAnotherDeviceIsUnavailable() async {
    let p256 = IdentitySecret(key: .generate(.ecdsaP256))
    let metadata = SSHIdentityMetadata(
      name: "Other phone",
      publicKeyLine: p256.publicKeyLine,
      storage: .secureEnclave,
      revision: LogicalRevision(counter: 1, deviceID: device)
    )
    let resolver = IdentityResolver(secrets: InMemoryIdentitySecretStore())
    #expect(
      await resolver.availability(of: metadata) == .unavailableOnThisDevice
    )
  }

  @Test
  func secureEnclaveKeysWhenAvailable() async throws {
    guard SecureEnclaveKeys.isAvailable else {
      #expect(throws: SecureEnclaveKeyError.unavailable) {
        try SecureEnclaveKeys.generate(requireUserPresence: false)
      }
      return
    }
    let secret: IdentitySecret
    do {
      secret = try SecureEnclaveKeys.generate(requireUserPresence: false)
    } catch .generationFailed {
      // Unsigned test runners lack the entitlement the Secure Enclave
      // requires; signed device builds exercise this path (spec §13.5).
      return
    }
    #expect(secret.key.isSecureEnclave)
    #expect(secret.key.algorithm == .ecdsaP256)
    let restored = try #require(IdentitySecret(payload: secret.payload))
    #expect(restored.publicKeyLine == secret.publicKeyLine)
    #expect(restored.matches(.secureEnclave))
    #expect(!restored.matches(.deviceOnly))
  }

  @Test
  func savedPasswordsAreBoundToTheirEndpoint() async throws {
    let saved = SavedPassword(
      host: "Mac.local",
      port: 22,
      username: "me",
      password: "secret"
    )
    #expect(saved.matches(host: "mac.local", port: 22, username: "me"))
    #expect(!saved.matches(host: "other.local", port: 22, username: "me"))
    #expect(!saved.matches(host: "mac.local", port: 2222, username: "me"))
    #expect(!saved.matches(host: "mac.local", port: 22, username: "root"))
    #expect(!String(describing: saved).contains("secret"))
    let payload = try #require(saved.payload)
    let restored = try #require(SavedPassword(payload: payload))
    #expect(restored == saved)

    let store = InMemorySavedPasswordStore()
    let host = UUID()
    await #expect(throws: IdentitySecretError.notFound) {
      try await store.read(host: host)
    }
    await store.save(saved, host: host)
    #expect(try await store.read(host: host) == saved)
    await store.delete(host: host)
    #expect(await store.count == 0)
  }
}
