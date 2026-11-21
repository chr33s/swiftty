import Foundation
@testable import RoamingApp
import SSHIdentity
import Testing

/// Storage policies whose keys these tests can generate: a Secure Enclave
/// identity is P-256 only and needs the hardware, so `generate(name:policy:)`
/// (Ed25519 by default) refuses it before touching the secret store, and a
/// test that waits for that store's read would wait forever.
let softwareIdentityPolicies = IdentityStoragePolicy.allCases.filter {
  $0 != .secureEnclave
}

actor SuspendedIdentitySecrets: IdentitySecretStore {
  let storage = InMemoryIdentitySecretStore()
  private var pauseRead = false
  private var deletionFailure: IdentitySecretError?
  private var entered = false
  private var arrival: CheckedContinuation<Void, Never>?
  private var release: CheckedContinuation<Void, Never>?

  func suspendNextRead() { pauseRead = true }
  func failNextDeletion(_ error: IdentitySecretError) {
    deletionFailure = error
  }
  func waitForRead() async {
    if entered { return }
    await withCheckedContinuation { arrival = $0 }
  }
  func resumeRead() {
    release?.resume();
    release = nil
  }

  func add(
    _ secret: IdentitySecret,
    id: UUID,
    policy: IdentityStoragePolicy
  ) async throws(IdentitySecretError) {
    try await storage.add(secret, id: id, policy: policy)
  }
  func read(
    id: UUID,
    policy: IdentityStoragePolicy
  ) async throws(IdentitySecretError) -> IdentitySecret {
    if pauseRead {
      pauseRead = false
      entered = true
      arrival?.resume()
      arrival = nil
      await withCheckedContinuation { release = $0 }
    }
    return try await storage.read(id: id, policy: policy)
  }
  func delete(
    id: UUID,
    policy: IdentityStoragePolicy
  ) async throws(IdentitySecretError) {
    if let failure = deletionFailure {
      deletionFailure = nil
      throw failure
    }
    try await storage.delete(id: id, policy: policy)
  }
  func storedIdentities(
    policy: IdentityStoragePolicy
  ) async throws(IdentitySecretError) -> Set<UUID> {
    try await storage.storedIdentities(policy: policy)
  }
}

extension MainActorIntegrationTests {
  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(1)))
  struct IdentityAccountBoundaryTests {
    let defaultCloud = FakeCloud()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("identity-account-" + UUID().uuidString)

    func app(
      secrets: any IdentitySecretStore,
      cloud: FakeCloud? = nil,
      legacy: any LegacyKeySource = InMemoryLegacyKeySource()
    ) -> RoamingAppModel {
      let model = RoamingAppModel(
        profile: .profile(for: .mobile),
        store: ConnectionStore(
          fileURL: directory.appendingPathComponent("hosts.json")
        ),
        secrets: secrets,
        legacyKeys: legacy,
        cloud: cloud ?? defaultCloud
      )
      model.load()
      model.sync?.setActive(false)
      return model
    }

    func select(_ account: String, in model: RoamingAppModel) async {
      if let cloud = model.sync?.database as? FakeCloud {
        await cloud.setAccount(account)
      }
      #expect(
        model.commitConnections {
          $0.settings.metadataSync = true
          ConnectionSyncCoordinator.bind(&$0, to: account)
        }
      )
    }

    @Test(arguments: [false, true], softwareIdentityPolicies)
    func cancelledCreationRetainsFailedCleanupUntilRelaunch(
      readFails: Bool,
      policy: IdentityStoragePolicy
    ) async throws {
      defer { try? FileManager.default.removeItem(at: directory) }
      let secrets = SuspendedIdentitySecrets()
      var model = app(secrets: secrets)
      await select("account-a", in: model)
      await secrets.suspendNextRead()
      let identityStore = model.identityStore!
      let creation = Task {
        try await identityStore.generate(name: "Cancelled", policy: policy)
      }
      await secrets.waitForRead()
      if readFails {
        await secrets.storage.failNextRead(.protectedDataUnavailable)
      }
      await secrets.failNextDeletion(.protectedDataUnavailable)
      creation.cancel()
      await secrets.resumeRead()
      await #expect(throws: IdentityOperationError.cancelled) {
        try await creation.value
      }
      #expect(model.identities.isEmpty)
      #expect(model.connections.intents.count == 1)
      #expect(model.connections.intents.first?.kind == .deleteSecret)
      #expect(try await secrets.storedIdentities(policy: policy).count == 1)
      #expect(await model.identityStore.orphans().isEmpty)
      model = app(secrets: secrets)
      await model.identityStore.recover()
      #expect(model.identities.isEmpty)
      #expect(model.connections.intents.isEmpty)
      #expect(try await secrets.storedIdentities(policy: policy).isEmpty)
    }

    @Test
    func cancellationAfterAnAccountSwitchNeverResumesAsCreation() async throws {
      defer { try? FileManager.default.removeItem(at: directory) }
      let secrets = SuspendedIdentitySecrets()
      let model = app(secrets: secrets)
      await select("account-a", in: model)
      await secrets.suspendNextRead()
      let creation = Task {
        try await model.identityStore.generate(
          name: "Cancelled A",
          policy: .iCloudKeychain
        )
      }
      await secrets.waitForRead()
      await select("account-b", in: model)
      creation.cancel()
      await secrets.resumeRead()
      await #expect(throws: IdentityOperationError.cancelled) {
        try await creation.value
      }
      #expect(model.connections.intents.first?.kind == .deleteSecret)
      #expect(model.connections.intents.first?.account == "account-a")
      await model.identityStore.recover()
      #expect(model.connections.identities.isEmpty)
      #expect(
        try await secrets.storedIdentities(policy: .iCloudKeychain).count == 1
      )
      await select("account-a", in: model)
      await model.identityStore.recover()
      #expect(model.connections.identities.isEmpty)
      #expect(model.connections.intents.isEmpty)
      #expect(
        try await secrets.storedIdentities(policy: .iCloudKeychain).isEmpty
      )
    }

    @Test(arguments: [false, true])
    func iCloudWritesRequireTheBoundAccountNotJustAnyAccount(
      copy: Bool
    ) async throws {
      defer { try? FileManager.default.removeItem(at: directory) }
      let secrets = InMemoryIdentitySecretStore()
      let cloud = FakeCloud()
      let model = app(secrets: secrets, cloud: cloud)
      await select("account-a", in: model)
      let source = try await model.identityStore.generate(
        name: "Local A",
        policy: .deviceOnly
      )
      let before = model.connections
      await cloud.setAccount("account-b")
      // No notification has reached the app yet: its persisted binding is A.
      await #expect(throws: IdentityOperationError.accountChanged) {
        if copy {
          _ = try await model.identityStore.createICloudCopy(
            of: source.id,
            name: "Copy A",
            reassign: []
          )
        } else {
          _ = try await model.identityStore.generate(
            name: "New A",
            policy: .iCloudKeychain
          )
        }
      }
      #expect(model.connections == before)
      #expect(
        try await secrets.storedIdentities(policy: .iCloudKeychain).isEmpty
      )
    }

    @Test(arguments: [false, true], softwareIdentityPolicies)
    func pendingCreationStaysWithItsOriginalAccount(
      roundTrip: Bool,
      policy: IdentityStoragePolicy
    ) async throws {
      defer { try? FileManager.default.removeItem(at: directory) }
      let secrets = SuspendedIdentitySecrets()
      var model = app(secrets: secrets)
      await select("account-a", in: model)
      await secrets.suspendNextRead()
      let identityStore = model.identityStore!
      let creation = Task {
        try await identityStore.generate(name: "Pending A", policy: policy)
      }
      await secrets.waitForRead()
      await select("account-b", in: model)
      if roundTrip { await select("account-a", in: model) }
      await secrets.resumeRead()
      let result = await creation.result
      if case .success = result {
        Issue.record("Old account context published an identity")
      }
      #expect(model.connections.identities.isEmpty)
      #expect(model.connections.intents.count == 1)
      #expect(try await secrets.storedIdentities(policy: policy).count == 1)
      await select("account-b", in: model)
      model = app(secrets: secrets)
      await model.identityStore.recover()
      #expect(model.identities.isEmpty)
      #expect(model.connections.intents.count == 1)
      #expect(model.connections.accounts["account-b"]?.outbox.isEmpty == true)
      await select("account-a", in: model)
      await model.identityStore.recover()
      #expect(model.identities.map(\.name) == ["Pending A"])
      #expect(model.connections.intents.isEmpty)
      let id = try #require(model.identities.first?.id)
      #expect(
        model.connections.scopes[ConnectionSnapshot.identityRecord(id)]
          == "account-a"
      )
    }

    @Test(arguments: [false, true])
    func copyAndWithdrawalCannotCrossASuspendedSourceRead(
      withdraw: Bool
    ) async throws {
      defer { try? FileManager.default.removeItem(at: directory) }
      let secrets = SuspendedIdentitySecrets()
      let model = app(secrets: secrets)
      await select("account-a", in: model)
      let original = try await model.identityStore.generate(
        name: "Source A",
        policy: withdraw ? .iCloudKeychain : .deviceOnly
      )
      let host = HostProfile(
        nickname: "A",
        host: "a.local",
        username: "me",
        auth: .key(identityID: original.id)
      )
      #expect(try model.save(host))
      await secrets.suspendNextRead()
      let operation = Task {
        if withdraw {
          return try await model.identityStore.withdrawFromICloud(
            original.id,
            name: "Copy",
            reassign: [host.id]
          )
        }
        return try await model.identityStore.createICloudCopy(
          of: original.id,
          name: "Copy",
          reassign: [host.id]
        )
      }
      await secrets.waitForRead()
      await select("account-b", in: model)
      await secrets.resumeRead()
      await #expect(throws: IdentityOperationError.accountChanged) {
        try await operation.value
      }
      #expect(model.connections.identities == [original])
      #expect(model.connections.hosts == [host])
      #expect(model.connections.intents.isEmpty)
    }

    @Test
    func recoveryDoesNotPublishAnOperationStillInFlight() async throws {
      defer { try? FileManager.default.removeItem(at: directory) }
      let secrets = SuspendedIdentitySecrets()
      let model = app(secrets: secrets)
      await select("account-a", in: model)
      await secrets.suspendNextRead()
      let creation = Task {
        try await model.identityStore.generate(
          name: "Pending",
          policy: .deviceOnly
        )
      }
      await secrets.waitForRead()
      let pending = try #require(model.connections.intents.first)
      await model.identityStore.recover()
      #expect(model.connections.identities.isEmpty)
      #expect(model.connections.intents == [pending])
      await #expect(throws: IdentityOperationError.integrityConflict) {
        try await model.identityStore.deleteOrphan(
          pending.identityID,
          policy: .deviceOnly
        )
      }
      await secrets.resumeRead()
      _ = try await creation.value
      #expect(model.identities.count == 1)
      #expect(model.connections.intents.isEmpty)
    }

    @Test
    func anAccountNotificationInvalidatesAnUnboundICloudLookup() async throws {
      defer { try? FileManager.default.removeItem(at: directory) }
      let secrets = InMemoryIdentitySecretStore()
      let cloud = FakeCloud()
      let model = app(secrets: secrets, cloud: cloud)
      let (started, signalStart) = AsyncStream<Void>.makeStream()
      let (resume, signalResume) = AsyncStream<Void>.makeStream()
      await cloud.onNextAccount {
        signalStart.yield(())
        signalStart.finish()
        for await _ in resume { break }
      }
      let creation = Task {
        try await model.identityStore.generate(
          name: "Cloud",
          policy: .iCloudKeychain
        )
      }
      for await _ in started { break }
      await cloud.setAccount("account-b")
      model.sync?.accountDidChange()
      signalResume.yield(())
      signalResume.finish()
      await #expect(throws: IdentityOperationError.accountChanged) {
        try await creation.value
      }
      #expect(model.connections.identities.isEmpty)
      #expect(model.connections.intents.isEmpty)
      #expect(
        try await secrets.storedIdentities(policy: .iCloudKeychain).isEmpty
      )
    }

    @Test(arguments: [false, true])
    func relaunchVerifiesAccountBeforeResumingKeychainWork(
      delete: Bool
    ) async throws {
      defer { try? FileManager.default.removeItem(at: directory) }
      let secrets = InMemoryIdentitySecretStore()
      let cloud = FakeCloud()
      await cloud.setAccount("account-a")
      var model = app(secrets: secrets, cloud: cloud)
      await select("account-a", in: model)
      if delete {
        let identity = try await model.identityStore.generate(
          name: "Delete A",
          policy: .iCloudKeychain
        )
        await secrets.inject(.protectedDataUnavailable)
        try await model.identityStore.delete(identity.id)
      } else {
        await secrets.failNextRead(.protectedDataUnavailable)
        await #expect(throws: IdentityOperationError.pendingVerification) {
          _ = try await model.identityStore.generate(
            name: "Pending A",
            policy: .iCloudKeychain
          )
        }
      }
      #expect(model.connections.intents.count == 1)
      await cloud.setAccount("account-b")
      model = app(secrets: secrets, cloud: cloud)
      await model.identityStore.recover()
      #expect(model.connections.intents.count == 1)
      #expect(
        try await secrets.storedIdentities(policy: .iCloudKeychain).count == 1
      )
      if !delete { #expect(model.connections.identities.isEmpty) }
      await cloud.setAccount("account-a")
      await model.identityStore.recover()
      #expect(model.connections.intents.isEmpty)
      #expect(
        try await secrets.storedIdentities(policy: .iCloudKeychain).count
          == (delete ? 0 : 1)
      )
    }

    @Test
    func versionTwoIntentsAcquireTheirExistingAccountScope() throws {
      var snapshot = ConnectionSnapshot()
      let id = UUID()
      snapshot.intents = [
        IdentityIntent(
          id: UUID(),
          identityID: id,
          kind: .deleteSecret,
          policy: .deviceOnly,
          name: "Pending",
          publicKey: "unused",
          reassign: [],
          stage: .recorded,
          createdAt: .now
        )
      ]
      snapshot.boundAccount = "account-b"
      snapshot.scopes[ConnectionSnapshot.identityRecord(id)] = "account-a"
      var json = try #require(
        JSONSerialization.jsonObject(with: ConnectionStore.encode(snapshot))
          as? [String: Any]
      )
      json["version"] = 2
      let migrated = try ConnectionStore.decode(
        JSONSerialization.data(withJSONObject: json)
      )
      #expect(migrated.intents.first?.account == "account-a")
      let roundTrip = try ConnectionStore.decode(
        ConnectionStore.encode(migrated)
      )
      #expect(roundTrip.intents.first?.account == "account-a")
    }

    @Test(arguments: [false, true])
    func staleIdentityActionsCannotEditAnotherAccount(delete: Bool) async throws
    {
      defer { try? FileManager.default.removeItem(at: directory) }
      let secrets = InMemoryIdentitySecretStore()
      let model = app(secrets: secrets)
      await select("account-a", in: model)
      let identity = try await model.identityStore.generate(
        name: "Original",
        policy: .deviceOnly
      )
      await select("account-b", in: model)
      await #expect(throws: IdentityOperationError.notFound) {
        if delete {
          try await model.identityStore.delete(identity.id)
        } else {
          try model.identityStore.rename(identity.id, to: "Wrong account")
        }
      }
      #expect(model.connections.identity(identity.id) == identity)
      #expect(
        try await secrets.storedIdentities(policy: .deviceOnly) == [identity.id]
      )
    }
  }
}
