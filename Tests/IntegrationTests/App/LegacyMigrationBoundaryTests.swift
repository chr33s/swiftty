import Crypto
import Foundation
@testable import RoamingApp
import SSHIdentity
import Testing

extension MainActorIntegrationTests.IdentityAccountBoundaryTests {
  func migratedLegacyFixture() async throws -> (
    model: RoamingAppModel, secrets: InMemoryIdentitySecretStore,
    legacy: InMemoryLegacyKeySource, identity: SSHIdentityMetadata
  ) {
    let secrets = InMemoryIdentitySecretStore()
    let legacy = InMemoryLegacyKeySource(keys: [
      "phone": Curve25519.Signing.PrivateKey()
    ])
    let model = app(secrets: secrets, legacy: legacy)
    await select("account-a", in: model)
    #expect(try model.save(legacyHost("A")))
    await model.identityStore.migrateLegacyLabels()
    return (model, secrets, legacy, try #require(model.identities.first))
  }

  func legacyHost(_ name: String) -> HostProfile {
    HostProfile(
      nickname: name,
      host: name.lowercased() + ".local",
      username: "me",
      auth: .legacyKey(label: "phone")
    )
  }

  func suspendedLegacyFixture() async throws -> (
    RoamingAppModel, SuspendedIdentitySecrets, InMemoryLegacyKeySource,
    SSHIdentityMetadata
  ) {
    let secrets = SuspendedIdentitySecrets()
    let legacy = InMemoryLegacyKeySource(keys: [
      "phone": Curve25519.Signing.PrivateKey()
    ])
    let model = app(secrets: secrets, legacy: legacy)
    await select("account-a", in: model)
    #expect(try model.save(legacyHost("A")))
    await model.identityStore.migrateLegacyLabels()
    return (model, secrets, legacy, try #require(model.identities.first))
  }

  @Test
  func legacyReuseRechecksTheMappedIdentityAfterVerification() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let (model, secrets, legacy, identity) = try await suspendedLegacyFixture()
    let host = legacyHost("New")
    #expect(try model.save(host))
    await secrets.suspendNextRead()
    let migration = Task { await model.identityStore.migrateLegacyLabels() }
    await secrets.waitForRead()
    #expect(model.commitConnections { $0.tombstoneIdentity(identity.id) })
    await secrets.resumeRead()
    await migration.value
    #expect(
      model.hosts.first { $0.id == host.id }?.auth == .legacyKey(label: "phone")
    )
    #expect(!model.connections.migration.completed)
    #expect(await legacy.contains("phone"))
  }

  @Test
  func legacyCleanupRechecksReferencesAfterVerification() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let (model, secrets, legacy, _) = try await suspendedLegacyFixture()
    await secrets.suspendNextRead()
    let cleanup = Task { await model.identityStore.cleanUpLegacyItems() }
    await secrets.waitForRead()
    let host = legacyHost("Arriving")
    #expect(
      model.commitConnections {
        $0.scopes[ConnectionSnapshot.hostRecord(host.id)] = "account-b"
        $0.upsertHost(host)
      }
    )
    await secrets.resumeRead()
    await cleanup.value
    #expect(await legacy.contains("phone"))
    #expect(model.connections.migration.pendingCleanup == ["phone"])
  }

  @Test(arguments: [false, true])
  func legacyPublicationRejectsAnArrivingIncompatibleIdentity(
    deleted: Bool
  ) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = IdentitySecret(.init())
    let secrets = SuspendedIdentitySecrets()
    let legacy = InMemoryLegacyKeySource(keys: ["phone": key.ed25519PrivateKey!]
    )
    let model = app(secrets: secrets, legacy: legacy)
    await select("account-a", in: model)
    let host = legacyHost("A")
    #expect(try model.save(host))
    await secrets.suspendNextRead()
    let migration = Task { await model.identityStore.migrateLegacyLabels() }
    await secrets.waitForRead()
    let id = try #require(model.connections.migration.labelMap["phone"])
    #expect(
      model.commitConnections {
        $0.insertIdentity(
          SSHIdentityMetadata(
            id: id,
            name: "Deleted",
            publicKeyLine: deleted
              ? key.publicKeyLine : IdentitySecret(.init()).publicKeyLine,
            storage: .deviceOnly,
            revision: LogicalRevision(counter: 100, deviceID: UUID()),
            deletedAt: deleted ? .now : nil
          )
        )
      }
    )
    await secrets.resumeRead()
    await migration.value
    #expect(
      model.hosts.first { $0.id == host.id }?.auth == .legacyKey(label: "phone")
    )
    #expect(!model.connections.migration.completed)
    #expect(model.connections.identity(id)?.isDeleted == deleted)
    #expect(model.connections.migration.pendingCleanup.isEmpty)
    #expect(await legacy.contains("phone"))
  }

  @Test
  func legacyRepairRejectsDifferentMaterialBeforeWritingTheReplacement()
    async throws
  {
    defer { try? FileManager.default.removeItem(at: directory) }
    let (originalModel, secrets, _, identity) =
      try await migratedLegacyFixture()
    try await secrets.delete(id: identity.id, policy: .deviceOnly)
    let host = legacyHost("New")
    #expect(try originalModel.save(host))
    let changed = InMemoryLegacyKeySource(keys: [
      "phone": Curve25519.Signing.PrivateKey()
    ])
    let model = app(secrets: secrets, legacy: changed)
    await model.identityStore.recover()
    #expect(try await secrets.storedIdentities(policy: .deviceOnly).isEmpty)
    #expect(model.connections.intents.isEmpty)
    #expect(
      model.connections.identity(identity.id)?.fingerprint
        == identity.fingerprint
    )
    #expect(
      model.hosts.first { $0.id == host.id }?.auth == .legacyKey(label: "phone")
    )
    #expect(!model.connections.migration.completed)
    #expect(await changed.contains("phone"))
  }

  @Test(arguments: [false, true], [false, true])
  func legacyMigrationDoesNotAdoptAnotherAccountsMappedKey(
    cleanedUp: Bool,
    displaced: Bool
  ) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let (model, _, legacy, identity) = try await migratedLegacyFixture()
    if cleanedUp { await model.identityStore.cleanUpLegacyItems() }
    #expect(await legacy.contains("phone") == !cleanedUp)
    await select("account-b", in: model)
    if displaced {
      #expect(
        model.commitConnections {
          $0.activateRecord(
            ConnectionSnapshot.identityRecord(identity.id),
            for: "account-b"
          )
        }
      )
    }
    let host = legacyHost("B")
    #expect(try model.save(host))
    await model.identityStore.migrateLegacyLabels()
    #expect(
      model.hosts.first { $0.id == host.id }?.auth == .legacyKey(label: "phone")
    )
    #expect(!model.connections.migration.completed)
    #expect(model.connections.migration.labelMap["phone"] == identity.id)
    #expect(model.identities.isEmpty)
    #expect(await legacy.contains("phone") == !cleanedUp)
  }

  @Test
  func legacyMigrationDoesNotReassignADeletedMappedIdentity() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let (model, secrets, legacy, identity) = try await migratedLegacyFixture()
    try await model.identityStore.delete(identity.id)
    let host = legacyHost("New")
    #expect(try model.save(host))
    await model.identityStore.migrateLegacyLabels()
    #expect(
      model.hosts.first { $0.id == host.id }?.auth == .legacyKey(label: "phone")
    )
    #expect(!model.connections.migration.completed)
    #expect(try await secrets.storedIdentities(policy: .deviceOnly).isEmpty)
    #expect(await legacy.contains("phone"))
  }

  @Test(arguments: [false, true])
  func legacyMigrationRepairsAMissingReplacementFromTheOriginalKey(
    atLimit: Bool
  ) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let (model, secrets, _, identity) = try await migratedLegacyFixture()
    if atLimit {
      let key = try await secrets.read(id: identity.id, policy: .deviceOnly)
      #expect(
        model.commitConnections { snapshot in
          for index in 1 ..< ConnectionStore.maxIdentities {
            snapshot.insertIdentity(
              SSHIdentityMetadata(
                name: "Other \(index)",
                publicKeyLine: key.publicKeyLine,
                storage: .deviceOnly,
                revision: LogicalRevision(
                  counter: 0,
                  deviceID: snapshot.deviceID
                )
              )
            )
          }
        }
      )
    }
    try await secrets.delete(id: identity.id, policy: .deviceOnly)
    let host = legacyHost("New")
    #expect(try model.save(host))
    await model.identityStore.migrateLegacyLabels()
    #expect(
      model.hosts.first { $0.id == host.id }?.auth
        == .key(identityID: identity.id)
    )
    #expect(await model.identityStore.availability(identity.id) == .available)
    #expect(
      try await secrets.storedIdentities(policy: .deviceOnly) == [identity.id]
    )
    #expect(
      model.connections.identity(identity.id)?.fingerprint
        == identity.fingerprint
    )
    #expect(model.connections.migration.pendingCleanup == ["phone"])
  }

  @Test
  func legacyMappingResumesAfterItsMissingReplacementIsRepaired() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let (model, secrets, legacy, identity) = try await migratedLegacyFixture()
    let original = try await secrets.read(id: identity.id, policy: .deviceOnly)
    await model.identityStore.cleanUpLegacyItems()
    #expect(await !legacy.contains("phone"))
    try await secrets.delete(id: identity.id, policy: .deviceOnly)
    let host = legacyHost("Later")
    #expect(try model.save(host))
    await model.identityStore.migrateLegacyLabels()
    #expect(!model.connections.migration.completed)
    #expect(!model.connections.migration.unresolved.contains("phone"))
    #expect(
      model.hosts.first { $0.id == host.id }?.auth == .legacyKey(label: "phone")
    )
    // Explicit repair supplies the same key to its existing UUID.
    try await secrets.add(original, id: identity.id, policy: .deviceOnly)
    await model.identityStore.migrateLegacyLabels()
    #expect(
      model.hosts.first { $0.id == host.id }?.auth
        == .key(identityID: identity.id)
    )
    #expect(model.connections.migration.completed)
  }

  @Test
  func legacyCleanupRetainsKeysReferencedByDisplacedAccountCaches() async throws
  {
    defer { try? FileManager.default.removeItem(at: directory) }
    let (model, _, legacy, _) = try await migratedLegacyFixture()
    let old = legacyHost("Cached")
    let name = ConnectionSnapshot.hostRecord(old.id)
    #expect(
      model.commitConnections { snapshot in
        snapshot.scopes[name] = "account-b"
        snapshot.upsertHost(old)
        snapshot.activateRecord(name, for: "account-c")
        var replacement = old
        replacement.auth = .password
        snapshot.scopes[name] = "account-c"
        snapshot.upsertHost(replacement)
      }
    )
    #expect(
      model.connections.cachedHosts.contains {
        $0.auth == .legacyKey(label: "phone")
      }
    )
    await model.identityStore.cleanUpLegacyItems()
    #expect(await legacy.contains("phone"))
    #expect(model.connections.migration.pendingCleanup.contains("phone"))
  }

  @Test
  func legacyCleanupDoesNotDeleteChangedMaterialUnderTheOldLabel() async throws
  {
    defer { try? FileManager.default.removeItem(at: directory) }
    let (_, secrets, _, identity) = try await migratedLegacyFixture()
    let replacement = InMemoryLegacyKeySource(keys: [
      "phone": Curve25519.Signing.PrivateKey()
    ])
    let model = app(secrets: secrets, legacy: replacement)
    await model.identityStore.recover()
    #expect(await replacement.contains("phone"))
    #expect(model.connections.migration.pendingCleanup.contains("phone"))
    #expect(
      model.connections.identity(identity.id)?.fingerprint
        == identity.fingerprint
    )
  }
}
