import Foundation
@testable import RoamingApp
import SSHIdentity
import Testing

extension MainActorIntegrationTests.IdentityAccountBoundaryTests {
  func olderUnscopedIdentity(
    secrets: any IdentitySecretStore,
    version: Int = 3
  ) async throws -> (RoamingAppModel, SSHIdentityMetadata) {
    let originalModel = app(secrets: secrets)
    let identity = try await originalModel.identityStore.generate(
      name: "Older key",
      policy: .iCloudKeychain
    )
    var snapshot = originalModel.connections
    snapshot.scopes = [:]
    snapshot.accounts = [:]
    snapshot.verifiedKeychainAccount = nil
    var json = try #require(
      JSONSerialization.jsonObject(with: ConnectionStore.encode(snapshot))
        as? [String: Any]
    )
    json["version"] = version
    json.removeValue(forKey: "verifiedKeychainAccount")
    json.removeValue(forKey: "unverifiedKeychainIdentities")
    try JSONSerialization.data(withJSONObject: json)
      .write(to: originalModel.store.fileURL, options: .atomic)
    let reloaded = app(secrets: secrets)
    return (reloaded, try #require(reloaded.connections.identity(identity.id)))
  }

  @Test(arguments: [2, 3])
  func olderUnscopedMetadataRequiresExplicitAccountReview(
    version: Int
  ) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = InMemoryIdentitySecretStore()
    let (model, original) = try await olderUnscopedIdentity(
      secrets: secrets,
      version: version
    )
    await defaultCloud.setAccount("account-b")
    await model.refreshConnections()
    #expect(model.identities.isEmpty)
    #expect(model.keyAccountReviews == [original])
    await #expect(throws: IdentityResolutionError.unknownIdentity) {
      _ = try await model.identityStore.resolve(original.id)
    }
    #expect(await defaultCloud.saveCount == 0)
    try await model.identityStore.restoreAccountReviewedIdentity(original.id)
    #expect(model.identities == [original])
    #expect(model.keyAccountReviews.isEmpty)
    #expect(!model.connections.settings.metadataSync)
    #expect(await defaultCloud.saveCount == 0)
    #expect(
      model.connections.scopes[ConnectionSnapshot.identityRecord(original.id)]
        == "account-b"
    )
    try await #require(model.sync).setMetadataSync(true)
    await model.sync?.refresh()?.value
    #expect(await defaultCloud.records("account-b").count == 1)
    let relaunched = app(secrets: secrets)
    #expect(relaunched.keyAccountReviews.isEmpty)
    #expect(relaunched.identities == [original])
  }

  @Test(arguments: [false, true])
  func accountReviewRejectsMissingOrReplacedSecrets(replace: Bool) async throws
  {
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = InMemoryIdentitySecretStore()
    let (model, original) = try await olderUnscopedIdentity(secrets: secrets)
    try await secrets.delete(id: original.id, policy: .iCloudKeychain)
    if replace {
      try await secrets.add(
        IdentitySecret(.init()),
        id: original.id,
        policy: .iCloudKeychain
      )
    }
    let before = model.connections
    await #expect(
      throws: replace
        ? IdentityOperationError.integrityConflict : .keychain(.notFound)
    ) {
      try await model.identityStore.restoreAccountReviewedIdentity(original.id)
    }
    #expect(model.connections == before)
    #expect(model.identities.isEmpty)
  }

  @Test
  func accountReviewRejectsASwitchDuringFingerprintVerification() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = SuspendedIdentitySecrets()
    let (model, original) = try await olderUnscopedIdentity(secrets: secrets)
    await secrets.suspendNextRead()
    let restoring = Task {
      try await model.identityStore.restoreAccountReviewedIdentity(original.id)
    }
    await secrets.waitForRead()
    await defaultCloud.setAccount("account-b")
    model.sync?.accountDidChange()
    await model.sync?.refresh()?.value
    await secrets.resumeRead()
    await #expect(throws: IdentityOperationError.accountChanged) {
      try await restoring.value
    }
    #expect(model.identities.isEmpty)
    #expect(model.keyAccountReviews == [original])
  }

  @Test(arguments: ["matching", "different", "deleted"])
  func accountReviewReconcilesMetadataDeliveredBeforeTheDecision(
    kind: String
  ) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = InMemoryIdentitySecretStore()
    let (model, original) = try await olderUnscopedIdentity(secrets: secrets)
    try await #require(model.sync).setMetadataSync(true)
    await model.sync?.refresh()?.value
    #expect(await defaultCloud.records("acct-a").isEmpty)
    let key = try await secrets.read(id: original.id, policy: .iCloudKeychain)
    let remote = SSHIdentityMetadata(
      id: original.id,
      name: "Delivered",
      publicKeyLine: kind == "different"
        ? IdentitySecret(.init()).publicKeyLine : key.publicKeyLine,
      storage: .iCloudKeychain,
      createdAt: original.createdAt,
      revision: LogicalRevision(counter: 100, deviceID: UUID()),
      deletedAt: kind == "deleted" ? .now : nil
    )
    let name = ConnectionSnapshot.identityRecord(original.id)
    #expect(
      model.commitConnections {
        ConnectionSyncCoordinator.merge(
          remote,
          name: name,
          account: "acct-a",
          into: &$0
        )
      }
    )
    #expect(model.connections.identity(original.id) == original)
    #expect(model.keyAccountReviews == [original])
    if kind == "matching" {
      try await model.identityStore.restoreAccountReviewedIdentity(original.id)
      #expect(model.identities == [remote])
      #expect(model.connections.identities.count == 1)
    } else {
      await #expect(
        throws: kind == "deleted"
          ? IdentityOperationError.notFound : .integrityConflict
      ) {
        try await model.identityStore.restoreAccountReviewedIdentity(
          original.id
        )
      }
      #expect(model.identities.isEmpty)
      #expect(model.keyAccountReviews == [original])
    }
  }

  @Test
  func sameUUIDDeliveryKeepsTheUnsyncedOriginalAccountCache() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = InMemoryIdentitySecretStore()
    let model = app(secrets: secrets)
    let original = try await model.identityStore.generate(
      name: "A",
      policy: .iCloudKeychain
    )
    await defaultCloud.setAccount("account-b")
    try await #require(model.sync).setMetadataSync(true)
    await model.sync?.refresh()?.value
    let remote = SSHIdentityMetadata(
      id: original.id,
      name: "B",
      publicKeyLine: IdentitySecret(.init()).publicKeyLine,
      storage: .iCloudKeychain,
      revision: LogicalRevision(counter: 10, deviceID: UUID())
    )
    let name = ConnectionSnapshot.identityRecord(original.id)
    #expect(
      model.commitConnections {
        ConnectionSyncCoordinator.merge(
          remote,
          name: name,
          account: "account-b",
          into: &$0
        )
      }
    )
    #expect(model.identities == [remote])
    await defaultCloud.setAccount("acct-a")
    model.sync?.accountDidChange()
    await model.refreshConnections()
    #expect(model.identities == [original])
    #expect(model.connections.accounts["acct-a"]?.consented != true)
    #expect(await defaultCloud.records("acct-a").isEmpty)
    await defaultCloud.setAccount("account-b")
    model.sync?.accountDidChange()
    await model.refreshConnections()
    #expect(model.identities == [remote])
  }
}
