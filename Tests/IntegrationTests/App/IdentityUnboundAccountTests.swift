import Foundation
@testable import RoamingApp
import SSHClient
import SSHIdentity
import Testing

extension MainActorIntegrationTests.IdentityAccountBoundaryTests {
  @Test(arguments: [false, true])
  func unboundICloudIntentsRetainTheirAccountAcrossRelaunch(
    delete: Bool
  ) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = InMemoryIdentitySecretStore()
    let cloud = FakeCloud()
    await cloud.setAccount("account-a")
    var model = app(secrets: secrets, cloud: cloud)
    #expect(model.connections.boundAccount == nil)
    #expect(!model.connections.settings.metadataSync)
    if delete {
      let key = try await model.identityStore.generate(
        name: "A",
        policy: .iCloudKeychain
      )
      await secrets.inject(.protectedDataUnavailable)
      try await model.identityStore.delete(key.id)
    } else {
      await secrets.failNextRead(.protectedDataUnavailable)
      await #expect(throws: IdentityOperationError.pendingVerification) {
        _ = try await model.identityStore.generate(
          name: "A",
          policy: .iCloudKeychain
        )
      }
    }
    #expect(model.connections.intents.count == 1)
    await cloud.setAccount("account-b")
    model = app(secrets: secrets, cloud: cloud)
    await model.identityStore.recover()
    #expect(model.connections.intents.count == 1)
    #expect(model.identities.isEmpty)
    #expect(
      try await secrets.storedIdentities(policy: .iCloudKeychain).count == 1
    )
    await cloud.setAccount("account-a")
    await model.identityStore.recover()
    #expect(model.connections.intents.isEmpty)
    #expect(model.identities.count == (delete ? 0 : 1))
    #expect(
      try await secrets.storedIdentities(policy: .iCloudKeychain).count
        == (delete ? 0 : 1)
    )
    #expect(model.connections.boundAccount == nil)
    #expect(!model.connections.settings.metadataSync)
    #expect(await cloud.saveCount == 0)
  }

  @Test(arguments: [false, true], [false, true])
  func enablingSyncAdoptsOnlyPendingWorkAuthorizedForThatAccount(
    otherAccount: Bool,
    cancelled: Bool
  ) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = SuspendedIdentitySecrets()
    let cloud = FakeCloud()
    await cloud.setAccount("account-a")
    let model = app(secrets: secrets, cloud: cloud)
    await secrets.suspendNextRead()
    let creation = Task {
      try await model.identityStore.generate(
        name: "Pending A",
        policy: .iCloudKeychain
      )
    }
    await secrets.waitForRead()
    let coordinator = try #require(model.sync)
    if otherAccount { await cloud.setAccount("account-b") }
    try await coordinator.setMetadataSync(true)
    await coordinator.refresh()?.value
    if cancelled { creation.cancel() }
    await secrets.resumeRead()
    await #expect(
      throws: cancelled ? IdentityOperationError.cancelled : .accountChanged
    ) { try await creation.value }
    await model.identityStore.recover()
    if otherAccount {
      #expect(model.identities.isEmpty)
      #expect(model.connections.intents.count == 1)
      #expect(await cloud.records("account-b").isEmpty)
      await cloud.setAccount("account-a")
      try await coordinator.setMetadataSync(true)
      await coordinator.refresh()?.value
      await model.identityStore.recover()
    }
    #expect(model.identities.map(\.name) == (cancelled ? [] : ["Pending A"]))
    #expect(model.connections.intents.isEmpty)
    await coordinator.refresh()?.value
    #expect(await cloud.records("account-a").count == (cancelled ? 0 : 1))
  }

  @Test(arguments: [false, true])
  func unboundCopiesRejectAnUnreportedAccountSwitch(withdraw: Bool) async throws
  {
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = SuspendedIdentitySecrets()
    let cloud = FakeCloud()
    await cloud.setAccount("account-a")
    let model = app(secrets: secrets, cloud: cloud)
    let source = try await model.identityStore.generate(
      name: "Source",
      policy: withdraw ? .iCloudKeychain : .deviceOnly
    )
    await secrets.suspendNextRead()
    let operation = Task {
      if withdraw {
        return try await model.identityStore.withdrawFromICloud(
          source.id,
          name: "Copy",
          reassign: []
        )
      }
      return try await model.identityStore.createICloudCopy(
        of: source.id,
        name: "Copy",
        reassign: []
      )
    }
    await secrets.waitForRead()
    await cloud.setAccount("account-b")
    await secrets.resumeRead()
    await #expect(throws: IdentityOperationError.accountChanged) {
      try await operation.value
    }
    #expect(model.connections.identities == [source])
    #expect(model.connections.intents.isEmpty)
    #expect(
      try await secrets.storedIdentities(policy: .iCloudKeychain).count
        == (withdraw ? 1 : 0)
    )
    #expect(
      try await secrets.storedIdentities(policy: .deviceOnly).count
        == (withdraw ? 0 : 1)
    )
  }

  @Test
  func anOldUnboundDeletionCannotGuessItsOriginalAccount() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = InMemoryIdentitySecretStore()
    let model = app(secrets: secrets)
    let key = IdentitySecret(.init())
    let id = UUID()
    try await secrets.add(key, id: id, policy: .iCloudKeychain)
    let intent = IdentityIntent(
      id: UUID(),
      identityID: id,
      kind: .deleteSecret,
      policy: .iCloudKeychain,
      name: "Old cleanup",
      publicKey: key.publicKeyLine,
      reassign: [],
      stage: .recorded,
      createdAt: .now
    )
    #expect(model.commitConnections { $0.intents.append(intent) })
    await model.identityStore.recover()
    #expect(model.connections.intents == [intent])
    #expect(try await secrets.storedIdentities(policy: .iCloudKeychain) == [id])
  }

  @Test(arguments: [false, true])
  func legacyUnboundCreationsNeedExplicitAccountReview(
    withdrawal: Bool
  ) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = InMemoryIdentitySecretStore()
    let cloud = FakeCloud()
    let model = app(secrets: secrets, cloud: cloud)
    let key = IdentitySecret(.init())
    let id = UUID()
    let policy: IdentityStoragePolicy =
      withdrawal ? .deviceOnly : .iCloudKeychain
    try await secrets.add(key, id: id, policy: policy)
    let intent = IdentityIntent(
      id: UUID(),
      identityID: id,
      kind: withdrawal ? .withdraw(source: UUID()) : .generate,
      policy: policy,
      name: "Legacy pending",
      publicKey: key.publicKeyLine,
      reassign: [],
      stage: .secretWritten,
      createdAt: .now
    )
    #expect(model.commitConnections { $0.intents.append(intent) })
    await model.identityStore.recover()
    #expect(model.identities.isEmpty)
    #expect(model.connections.intents == [intent])
    #expect(await model.identityStore.orphans().map(\.id) == [id])
    try await model.identityStore.adoptOrphan(
      id,
      policy: policy,
      name: "Reviewed"
    )
    #expect(model.identities.map(\.id) == [id])
    #expect(model.connections.intents.isEmpty)
    #expect(!model.connections.settings.metadataSync)
  }

}
