import Crypto
import Foundation
import Testing

@testable import SSHIdentity

/// KEY-03 and KEY-06: read-only resolution that fails closed.
@Suite
struct IdentityResolverTests {
  let device = UUID()

  func metadata(
    for key: Curve25519.Signing.PrivateKey,
    storage: IdentityStoragePolicy = .deviceOnly,
    deleted: Bool = false
  ) -> SSHIdentityMetadata {
    SSHIdentityMetadata(
      name: "Laptop",
      publicKey: key.publicKey,
      storage: storage,
      revision: LogicalRevision(counter: 1, deviceID: device),
      deletedAt: deleted ? .now : nil
    )
  }

  @Test
  func resolvesTheSelectedIdentityOnly() async throws {
    let store = InMemoryIdentitySecretStore()
    let key = Curve25519.Signing.PrivateKey()
    let identity = metadata(for: key)
    try await store.add(
      IdentitySecret(key),
      id: identity.id,
      policy: .deviceOnly
    )
    // Another stored key is never a substitute.
    let other = Curve25519.Signing.PrivateKey()
    try await store.add(IdentitySecret(other), id: UUID(), policy: .deviceOnly)
    let resolved = try await IdentityResolver(secrets: store).resolve(identity)
    #expect(resolved.publicKeyLine == IdentitySecret(key).publicKeyLine)
  }

  @Test
  func missingDeletedLockedAndCorruptItemsFailClosed() async throws {
    let store = InMemoryIdentitySecretStore()
    let resolver = IdentityResolver(secrets: store)
    let key = Curve25519.Signing.PrivateKey()
    let deviceOnly = metadata(for: key)
    let synced = metadata(for: key, storage: .iCloudKeychain)

    await #expect(throws: IdentityResolutionError.unknownIdentity) {
      try await resolver.resolve(nil)
    }
    await #expect(throws: IdentityResolutionError.unavailableOnThisDevice) {
      try await resolver.resolve(deviceOnly)
    }
    await #expect(throws: IdentityResolutionError.awaitingKeyMaterial) {
      try await resolver.resolve(synced)
    }
    await #expect(throws: IdentityResolutionError.deleted) {
      try await resolver.resolve(metadata(for: key, deleted: true))
    }
    try await store.add(
      IdentitySecret(key),
      id: deviceOnly.id,
      policy: .deviceOnly
    )
    await store.setLocked(true)
    await #expect(throws: IdentityResolutionError.protectedDataUnavailable) {
      try await resolver.resolve(deviceOnly)
    }
    await store.setLocked(false)
    await store.overwrite(
      Data([1, 2, 3]),
      id: deviceOnly.id,
      policy: .deviceOnly
    )
    await #expect(throws: IdentityResolutionError.integrityConflict) {
      try await resolver.resolve(deviceOnly)
    }
    await store.inject(.missingEntitlement)
    await #expect(throws: IdentityResolutionError.unsupported) {
      try await resolver.resolve(deviceOnly)
    }
    // Nothing above created a key.
    #expect(try await store.storedIdentities(policy: .iCloudKeychain).isEmpty)
    #expect(
      try await store.storedIdentities(policy: .deviceOnly) == [deviceOnly.id]
    )
  }

  @Test
  func sameUUIDWithDifferentKeyIsAnIntegrityConflict() async throws {
    let store = InMemoryIdentitySecretStore()
    let identity = metadata(for: Curve25519.Signing.PrivateKey())
    try await store.add(
      IdentitySecret(Curve25519.Signing.PrivateKey()),
      id: identity.id,
      policy: .deviceOnly
    )
    await #expect(throws: IdentityResolutionError.integrityConflict) {
      try await IdentityResolver(secrets: store).resolve(identity)
    }
  }

  @Test
  func duplicateWritesNeverOverwrite() async throws {
    let store = InMemoryIdentitySecretStore()
    let id = UUID()
    let first = Curve25519.Signing.PrivateKey()
    try await store.add(IdentitySecret(first), id: id, policy: .deviceOnly)
    await #expect(throws: IdentitySecretError.duplicate) {
      try await store.add(
        IdentitySecret(Curve25519.Signing.PrivateKey()),
        id: id,
        policy: .deviceOnly
      )
    }
    let kept = try await store.read(id: id, policy: .deviceOnly)
    #expect(kept.publicKeyLine == IdentitySecret(first).publicKeyLine)
    // Policies are separate namespaces.
    await #expect(throws: IdentitySecretError.notFound) {
      try await store.read(id: id, policy: .iCloudKeychain)
    }
  }

  @Test
  func metadataValidatesItsPublicMaterial() {
    let key = Curve25519.Signing.PrivateKey()
    let good = metadata(for: key)
    #expect(good.isValid)
    #expect(good.authorizedKeysLine.hasSuffix(" Laptop"))
    let forged = SSHIdentityMetadata(
      id: good.id,
      name: good.name,
      algorithm: good.algorithm,
      publicKey: good.publicKey,
      fingerprint: "SHA256:forged",
      storage: good.storage,
      createdAt: good.createdAt,
      revision: good.revision,
      deletedAt: nil
    )
    #expect(throws: SSHIdentityMetadata.ValidationError.fingerprintMismatch) {
      try forged.validate()
    }
    #expect(!SSHIdentityMetadata.isValidName(""))
    #expect(!SSHIdentityMetadata.isValidName(" padded"))
    #expect(!SSHIdentityMetadata.isValidName("tab\there"))
    #expect(SSHIdentityMetadata.isValidName("Work laptop"))
  }

  @Test
  func secretsAreRedacted() {
    let secret = IdentitySecret(Curve25519.Signing.PrivateKey())
    #expect(String(describing: secret) == "IdentitySecret(<redacted>)")
    #expect(String(reflecting: secret) == "IdentitySecret(<redacted>)")
    #expect(Mirror(reflecting: secret).children.isEmpty)
  }

  @Test
  func revisionsOrderByCounterThenDevice() {
    let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    #expect(
      LogicalRevision(counter: 1, deviceID: b)
        < LogicalRevision(counter: 2, deviceID: a)
    )
    #expect(
      LogicalRevision(counter: 2, deviceID: a)
        < LogicalRevision(counter: 2, deviceID: b)
    )
  }
}
