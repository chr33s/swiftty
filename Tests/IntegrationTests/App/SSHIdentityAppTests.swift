import Crypto
import Foundation
import NIOSSH
@testable import RoamingApp
import SSHClient
@testable import SSHIdentity
import ScreenProtocol
import TerminalSurface
import Testing

/// spec.ssh-identity.md §11: KEY-01–03, KEY-06–07 and MIG-01–02 against
/// in-memory Keychain fakes and the in-process SSH server.
extension MainActorIntegrationTests {
  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(1)))
  struct SSHIdentityAppTests {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("identity-" + UUID().uuidString)

    func app(
      secrets: InMemoryIdentitySecretStore = InMemoryIdentitySecretStore(),
      legacy: InMemoryLegacyKeySource = InMemoryLegacyKeySource()
    ) -> RoamingAppModel {
      RoamingAppModel(
        store: ConnectionStore(
          fileURL: directory.appendingPathComponent("hosts.json")
        ),
        secrets: secrets,
        legacyKeys: legacy
      )
    }

    func trusted(_ server: TestSSHServer) async throws -> FileHostTrustStore {
      let trust = FileHostTrustStore(
        fileURL: directory.appendingPathComponent("trust.json")
      )
      try await trust.setTrustedKey(server.hostKeyLine, for: server.identity)
      return trust
    }

    func host(
      _ server: TestSSHServer,
      identity: UUID,
      name: String = "Mac"
    ) -> HostProfile {
      HostProfile(
        nickname: name,
        host: "127.0.0.1",
        port: server.port,
        username: TestSSHServer.username,
        auth: .key(identityID: identity)
      )
    }

    static func nioKey(
      _ identity: SSHIdentityMetadata
    ) throws -> NIOSSHPublicKey {
      try NIOSSHPublicKey(openSSHPublicKey: identity.publicKey)
    }

    // MARK: KEY-01, KEY-02

    @Test
    func generatedAndImportedKeysAuthenticateAfterRelaunch() async throws {
      defer { try? FileManager.default.removeItem(at: directory) }
      let secrets = InMemoryIdentitySecretStore()
      var model = app(secrets: secrets)
      model.load()
      let generated = try await model.identityStore.generate(
        name: "Generated",
        policy: .deviceOnly
      )
      let fixture = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "../../SSHIdentityTests/Fixtures/plain")
      let imported = try await model.identityStore.importKey(
        try Data(contentsOf: fixture),
        name: "Imported",
        policy: .deviceOnly
      )
      let server = try await TestSSHServer.start(authorizedKeys: [
        try Self.nioKey(generated), try Self.nioKey(imported),
      ])
      defer { Task { await server.shutdown() } }
      let trust = try await trusted(server)
      for identity in [generated, imported] {
        #expect(
          try model.save(
            host(server, identity: identity.id, name: identity.name)
          )
        )
      }

      // Relaunch: a fresh model over the same store and Keychain.
      model = app(secrets: secrets)
      model.load()
      #expect(
        model.identities.map(\.fingerprint).sorted()
          == [generated.fingerprint, imported.fingerprint].sorted()
      )
      let access = SSHAccess(app: model, trustStore: trust)
      for saved in model.hosts {
        let connection = try await access.connect(saved, interactive: false)
        await connection.close()
      }
      #expect(server.state.authRequests.withLock { $0 } >= 2)
    }

    @Test
    func renamingASharedIdentityKeepsReferencesAndFingerprint() async throws {
      defer { try? FileManager.default.removeItem(at: directory) }
      let model = app()
      model.load()
      let identity = try await model.identityStore.generate(
        name: "Shared",
        policy: .deviceOnly
      )
      let a = HostProfile(
        nickname: "A",
        host: "a.local",
        username: "me",
        auth: .key(identityID: identity.id)
      )
      let b = HostProfile(
        nickname: "B",
        host: "b.local",
        username: "me",
        auth: .key(identityID: identity.id)
      )
      #expect(try model.save(a))
      #expect(try model.save(b))
      try model.identityStore.rename(identity.id, to: "Renamed")
      #expect(model.identity(identity.id)?.name == "Renamed")
      #expect(model.identity(identity.id)?.fingerprint == identity.fingerprint)
      #expect(
        model.hosts.map(\.auth) == [
          .key(identityID: identity.id), .key(identityID: identity.id),
        ]
      )
      #expect(model.authSummary(for: a) == "Key \u{201C}Renamed\u{201D}")
    }

    // MARK: KEY-03

    @Test(arguments: [false, true])
    func missingOrLockedKeysFailClosed(locked: Bool) async throws {
      defer { try? FileManager.default.removeItem(at: directory) }
      let secrets = InMemoryIdentitySecretStore()
      let model = app(secrets: secrets)
      model.load()
      let server = try await TestSSHServer.start()
      defer { Task { await server.shutdown() } }
      let trust = try await trusted(server)
      let access = SSHAccess(app: model, trustStore: trust)
      let missing = host(server, identity: UUID())
      #expect(try model.save(missing))
      await #expect(throws: SSHAccessError.keyUnavailable(.unknownIdentity)) {
        _ = try await access.connect(missing, interactive: true)
      }
      if locked {
        let identity = try await model.identityStore.generate(
          name: "Locked",
          policy: .deviceOnly
        )
        await secrets.setLocked(true)
        let lockedHost = host(server, identity: identity.id)
        await #expect(
          throws: SSHAccessError.keyUnavailable(.protectedDataUnavailable)
        ) { _ = try await access.connect(lockedHost, interactive: false) }
      }
      // Display is metadata-only; nothing was generated, no password was
      // asked for and no credential reached the server.
      #expect(access.publicKeyLine(for: missing) == nil)
      #expect(model.pendingPassword == nil)
      #expect(server.state.authRequests.withLock { $0 } == 0)
      let stored = try await secrets.storedIdentities(policy: .deviceOnly)
      #expect(stored.count == (locked ? 1 : 0))
    }

    @Test
    func deletingAnIdentityLeavesHostsUnresolved() async throws {
      defer { try? FileManager.default.removeItem(at: directory) }
      let secrets = InMemoryIdentitySecretStore()
      let model = app(secrets: secrets)
      model.load()
      let identity = try await model.identityStore.generate(
        name: "Gone",
        policy: .deviceOnly
      )
      let saved = HostProfile(
        nickname: "A",
        host: "a.local",
        username: "me",
        auth: .key(identityID: identity.id)
      )
      #expect(try model.save(saved))
      try await model.identityStore.delete(identity.id)
      #expect(model.identities.isEmpty)
      #expect(model.hosts.first?.auth == .key(identityID: identity.id))
      #expect(model.connections.intents.isEmpty)
      #expect(try await secrets.storedIdentities(policy: .deviceOnly).isEmpty)
      await #expect(throws: IdentityResolutionError.deleted) {
        _ = try await model.identityStore.resolve(identity.id)
      }
    }

    @Test
    func iCloudCopyAndWithdrawalKeepAVerifiedCopy() async throws {
      defer { try? FileManager.default.removeItem(at: directory) }
      let secrets = InMemoryIdentitySecretStore()
      let model = app(secrets: secrets)
      model.load()
      model.identityStore.currentICloudAccount = { "test-account" }
      let local = try await model.identityStore.generate(
        name: "Laptop",
        policy: .deviceOnly
      )
      let saved = HostProfile(
        nickname: "A",
        host: "a.local",
        username: "me",
        auth: .key(identityID: local.id)
      )
      #expect(try model.save(saved))
      let copy = try await model.identityStore.createICloudCopy(
        of: local.id,
        name: "Laptop (iCloud)",
        reassign: [saved.id]
      )
      #expect(copy.id != local.id)
      #expect(copy.fingerprint == local.fingerprint)
      #expect(copy.storage == .iCloudKeychain)
      #expect(model.hosts.first?.auth == .key(identityID: copy.id))
      #expect(model.identity(local.id)?.isDeleted == false)

      let back = try await model.identityStore.withdrawFromICloud(
        copy.id,
        name: "Laptop again",
        reassign: [saved.id]
      )
      #expect(back.storage == .deviceOnly)
      #expect(model.hosts.first?.auth == .key(identityID: back.id))
      #expect(model.identity(copy.id)?.isDeleted == true)
      #expect(
        try await secrets.storedIdentities(policy: .iCloudKeychain).isEmpty
      )
      #expect(await model.identityStore.availability(back.id) == .available)
    }

    @Test
    func iCloudIdentitiesNeedAVerifiedAccount() async throws {
      defer { try? FileManager.default.removeItem(at: directory) }
      let model = app()
      model.load()
      model.identityStore.currentICloudAccount = { nil }
      await #expect(throws: IdentityOperationError.accountRequired) {
        _ = try await model.identityStore.generate(
          name: "Cloud",
          policy: .iCloudKeychain
        )
      }
      #expect(model.identities.isEmpty)
      model.identityStore.currentICloudAccount = nil
      await #expect(
        throws: IdentityOperationError.accountVerificationUnavailable
      ) {
        _ = try await model.identityStore.generate(
          name: "Unverified",
          policy: .iCloudKeychain
        )
      }
      _ = try await model.identityStore.generate(
        name: "Local",
        policy: .deviceOnly
      )
      #expect(model.identities.map(\.name) == ["Local"])
    }

    /// Without the right passphrase nothing is saved; with it the key is
    /// stored like any other import and the passphrase is not kept.
    @Test
    func encryptedImportsNeedTheirPassphrase() async throws {
      defer { try? FileManager.default.removeItem(at: directory) }
      let secrets = InMemoryIdentitySecretStore()
      let model = app(secrets: secrets)
      model.load()
      let fixture = try Data(
        contentsOf: URL(filePath: #filePath).deletingLastPathComponent()
          .appending(path: "../../SSHIdentityTests/Fixtures/aes256")
      )
      let inspection = try await model.identityStore.inspect(fixture)
      #expect(inspection.isEncrypted)
      for (passphrase, error) in [
        (nil, OpenSSHImportError.passphraseRequired),
        ("wrong", .wrongPassphrase),
      ] {
        await #expect(throws: IdentityOperationError.importFailed(error)) {
          _ = try await model.identityStore.importKey(
            fixture,
            passphrase: passphrase,
            name: "Encrypted",
            policy: .deviceOnly
          )
        }
      }
      #expect(model.identities.isEmpty)
      #expect(try await secrets.storedIdentities(policy: .deviceOnly).isEmpty)
      let identity = try await model.identityStore.importKey(
        fixture,
        passphrase: "correct horse",
        name: "Encrypted",
        policy: .deviceOnly
      )
      #expect(identity.fingerprint == inspection.fingerprint)
      #expect(model.identities.map(\.id) == [identity.id])
    }

    // MARK: MIG-01, MIG-02

    static let legacyFile = #"""
      {
        "hosts" : [
          { "auth" : { "keychainKey" : { "label" : "phone" } }, "host" : "a.local",
            "id" : "3F8A3108-AF67-4FA6-A94D-6F175876E934", "nickname" : "A",
            "port" : 22, "username" : "me" },
          { "auth" : { "keychainKey" : { "label" : "phone" } }, "host" : "b.local",
            "id" : "9C1B4E2A-0D55-4C7E-9E39-2B7C3B6A1F00", "nickname" : "B",
            "port" : 2222, "username" : "me" },
          { "auth" : { "keychainKey" : { "label" : "lost" } }, "host" : "c.local",
            "id" : "0B6C4D3E-1F2A-4B5C-8D9E-0F1A2B3C4D5E", "nickname" : "C",
            "port" : 22, "username" : "me" },
          { "auth" : { "password" : {} }, "host" : "d.local",
            "id" : "6A7B8C9D-0E1F-4A2B-9C3D-4E5F6A7B8C9D", "nickname" : "D",
            "port" : 22, "username" : "me" }
        ],
        "version" : 1
      }
      """#

    @Test
    func versionOneMigrationPreservesHostsAndFingerprints() async throws {
      defer { try? FileManager.default.removeItem(at: directory) }
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      let file = directory.appendingPathComponent("hosts.json")
      try Data(Self.legacyFile.utf8).write(to: file)
      let phone = Curve25519.Signing.PrivateKey()
      let legacy = InMemoryLegacyKeySource(keys: ["phone": phone])
      let secrets = InMemoryIdentitySecretStore()
      let model = app(secrets: secrets, legacy: legacy)
      model.load()
      await model.identityStore.recover()

      #expect(model.hosts.map(\.nickname) == ["A", "B", "C", "D"])
      #expect(model.hosts.map(\.port) == [22, 2222, 22, 22])
      let migrated = try #require(model.identities.first)
      #expect(model.identities.count == 1)
      #expect(migrated.name == "phone")
      #expect(migrated.storage == .deviceOnly)
      #expect(
        migrated.fingerprint == SSHEd25519Key.fingerprint(of: phone.publicKey)
      )
      // Shared labels stay shared; an absent key stays unresolved.
      #expect(model.hosts[0].auth == .key(identityID: migrated.id))
      #expect(model.hosts[1].auth == .key(identityID: migrated.id))
      #expect(model.hosts[2].auth == .legacyKey(label: "lost"))
      #expect(model.hosts[3].auth == .password)
      #expect(model.connections.migration.unresolved == ["lost"])
      #expect(model.connections.migration.completed)
      // The legacy item goes only after verified replacement; the original
      // file is retained.
      #expect(await legacy.deleted == ["phone"])
      #expect(model.connections.migration.pendingCleanup.isEmpty)
      let original = try Data(
        contentsOf: directory.appendingPathComponent("hosts.v1.json")
      )
      #expect(original == Data(Self.legacyFile.utf8))
      #expect(await model.identityStore.availability(migrated.id) == .available)
      await #expect(throws: SSHAccessError.keyNeedsRepair) {
        _ = try await model.ssh.connect(model.hosts[2], interactive: false)
      }
    }

    @Test
    func interruptedMigrationResumesWithTheSameMapping() async throws {
      defer { try? FileManager.default.removeItem(at: directory) }
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      try Data(Self.legacyFile.utf8)
        .write(to: directory.appendingPathComponent("hosts.json"))
      let phone = Curve25519.Signing.PrivateKey()
      let legacy = InMemoryLegacyKeySource(keys: ["phone": phone])
      let secrets = InMemoryIdentitySecretStore()
      var model = app(secrets: secrets, legacy: legacy)
      // Locked Keychain: defer, never treat a key as missing.
      await legacy.inject(.protectedDataUnavailable)
      await legacy.inject(.protectedDataUnavailable)
      model.load()
      await model.identityStore.recover()
      #expect(!model.connections.migration.completed)
      #expect(model.connections.migration.unresolved.isEmpty)
      #expect(model.hosts[0].auth == .legacyKey(label: "phone"))
      let mapped = try #require(model.connections.migration.labelMap["phone"])

      // A Keychain write failure, then a relaunch.
      await secrets.inject(.status(-1))
      await model.identityStore.migrateLegacyLabels()
      #expect(model.identities.isEmpty)
      #expect(model.connections.migration.unresolved == ["lost"])
      #expect(!model.connections.migration.completed)
      model = app(secrets: secrets, legacy: legacy)
      model.load()
      await model.identityStore.recover()
      #expect(model.connections.migration.labelMap["phone"] == mapped)
      #expect(model.identities.map(\.id) == [mapped])
      #expect(
        model.identities.first?.fingerprint
          == SSHEd25519Key.fingerprint(of: phone.publicKey)
      )
      #expect(model.hosts[0].auth == .key(identityID: mapped))
      #expect(!(await legacy.contains("phone")))
      // Re-running after completion changes nothing.
      let before = model.connections
      await model.identityStore.recover()
      #expect(model.connections == before)
    }

    @Test
    func aWrittenButUnpublishedIdentityIsRecoveredOnRelaunch() async throws {
      defer { try? FileManager.default.removeItem(at: directory) }
      let secrets = InMemoryIdentitySecretStore()
      var model = app(secrets: secrets)
      model.load()
      // Simulate a crash between the Keychain write and publication.
      let key = Curve25519.Signing.PrivateKey()
      let id = UUID()
      try await secrets.add(IdentitySecret(key), id: id, policy: .deviceOnly)
      let intent = IdentityIntent(
        id: UUID(),
        identityID: id,
        kind: .generate,
        policy: .deviceOnly,
        name: "Interrupted",
        publicKey: IdentitySecret(key).publicKeyLine,
        reassign: [],
        stage: .secretWritten,
        createdAt: .now
      )
      #expect(model.commitConnections { $0.intents.append(intent) })
      model = app(secrets: secrets)
      model.load()
      await model.identityStore.recover()
      #expect(model.identities.map(\.id) == [id])
      #expect(model.connections.intents.isEmpty)
      #expect(await model.identityStore.orphans().isEmpty)
    }

    @Test
    func orphansNeedExplicitApproval() async throws {
      defer { try? FileManager.default.removeItem(at: directory) }
      let secrets = InMemoryIdentitySecretStore()
      let model = app(secrets: secrets)
      model.load()
      let id = UUID()
      try await secrets.add(
        IdentitySecret(.init()),
        id: id,
        policy: .deviceOnly
      )
      await model.identityStore.recover()
      #expect(model.identities.isEmpty)
      let orphans = await model.identityStore.orphans()
      #expect(orphans.map(\.id) == [id])
      try await model.identityStore.adoptOrphan(
        id,
        policy: .deviceOnly,
        name: "Found"
      )
      #expect(model.identities.map(\.id) == [id])
    }

    @Test
    func snapshotWritesKeepAPreviousCopyAndNoSecrets() async throws {
      defer { try? FileManager.default.removeItem(at: directory) }
      let model = app()
      model.load()
      let identity = try await model.identityStore.generate(
        name: "Key",
        policy: .deviceOnly
      )
      #expect(
        try model.save(
          HostProfile(
            nickname: "A",
            host: "a.local",
            username: "me",
            auth: .key(identityID: identity.id)
          )
        )
      )
      let previous = try #require(try model.store.loadPrevious())
      #expect(previous.identities.map(\.id) == [identity.id])
      // SEC-01: the snapshot holds public material only.
      let text = try String(contentsOf: model.store.fileURL, encoding: .utf8)
      let secret = try await model.identityStore.resolve(identity.id)
      #expect(
        !text.contains(
          secret.ed25519PrivateKey!.rawRepresentation.base64EncodedString()
        )
      )
      #expect(text.contains(identity.fingerprint))
    }
  }
}

extension MainActorIntegrationTests.SSHIdentityAppTests {
  /// A connection right after the upgrade waits for the migration in
  /// flight instead of reporting the key as needing repair.
  @Test
  func connectingDuringMigrationUsesTheMigratedKey() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let phone = Curve25519.Signing.PrivateKey()
    let server = try await TestSSHServer.start(authorizedKeys: [
      NIOSSHPrivateKey(ed25519Key: phone).publicKey
    ])
    defer { Task { await server.shutdown() } }
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let file = #"""
      { "version" : 1, "hosts" : [ { "auth" : { "keychainKey" : { "label" : "phone" } },
        "host" : "127.0.0.1", "id" : "3F8A3108-AF67-4FA6-A94D-6F175876E934",
        "nickname" : "A", "port" : \#(server.port), "username" : "\#(TestSSHServer.username)" } ] }
      """#
    try Data(file.utf8)
      .write(to: directory.appendingPathComponent("hosts.json"))
    let model = app(legacy: InMemoryLegacyKeySource(keys: ["phone": phone]))
    let trust = try await trusted(server)
    model.load()
    let legacyHost = try #require(model.hosts.first)
    #expect(legacyHost.auth == .legacyKey(label: "phone"))
    let access = SSHAccess(app: model, trustStore: trust)
    let connection = try await access.connect(legacyHost, interactive: false)
    await connection.close()
    #expect(model.hosts.first?.auth.identityID != nil)
  }

  @Test
  func unrecognizedICloudItemsCanOnlyBeRestored() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = InMemoryIdentitySecretStore()
    let model = app(secrets: secrets)
    model.load()
    let id = UUID()
    try await secrets.add(
      IdentitySecret(.init()),
      id: id,
      policy: .iCloudKeychain
    )
    await #expect(throws: IdentityOperationError.syncedOrphan) {
      try await model.identityStore.deleteOrphan(id, policy: .iCloudKeychain)
    }
    #expect(try await secrets.storedIdentities(policy: .iCloudKeychain) == [id])
  }

  /// A Secure Enclave item never syncs, so an unrecognized one is this
  /// device's alone and can be deleted like a device-only item.
  @Test
  func unrecognizedSecureEnclaveItemsCanBeDeleted() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = InMemoryIdentitySecretStore()
    let model = app(secrets: secrets)
    model.load()
    let id = UUID()
    await secrets.overwrite(Data([3]), id: id, policy: .secureEnclave)
    #expect(await model.identityStore.orphans().map(\.id) == [id])
    try await model.identityStore.deleteOrphan(id, policy: .secureEnclave)
    #expect(try await secrets.storedIdentities(policy: .secureEnclave).isEmpty)
  }

  @Test
  func anUnverifiableWriteIsResumedNotOrphaned() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = InMemoryIdentitySecretStore()
    let model = app(secrets: secrets)
    model.load()
    // The write succeeds, then the read-back finds the device locked.
    await secrets.failNextRead(.protectedDataUnavailable)
    await #expect(throws: IdentityOperationError.pendingVerification) {
      _ = try await model.identityStore.generate(
        name: "Late",
        policy: .deviceOnly
      )
    }
    #expect(model.identities.isEmpty)
    #expect(model.connections.intents.count == 1)
    await model.identityStore.recover()
    #expect(model.identities.map(\.name) == ["Late"])
    #expect(await model.identityStore.orphans().isEmpty)
  }

  /// A roaming bootstrap whose key cannot be read fails closed and stops,
  /// rather than looking like an unreachable Mac.
  @Test
  func unreadableKeysStopBootstrapsAsCredentialFailures() async throws {
    let endpoint = SSHEndpoint(
      configuration: SSHClient.SSHClientConfiguration(
        host: "127.0.0.1",
        port: 1,
        username: "me"
      ),
      credentialSource: .resolved { @Sendable in
        throw SSHAccessError.keyUnavailable(.protectedDataUnavailable)
      },
      trustStore: InMemoryHostTrustStore()
    )
    await #expect(throws: RemoteBootstrapError.credentialUnavailable) {
      _ = try await SSHBootstrapper(endpoint: endpoint)
        .bootstrap(BootstrapRequest(operation: .list))
    }
  }
}
