import Foundation
@testable import RoamingApp
import SSHClient
import SSHIdentity
import Testing

extension MainActorIntegrationTests.IdentityAccountBoundaryTests {
  func legacyDeletion(
    in model: RoamingAppModel,
    secrets: any IdentitySecretStore
  ) async throws -> IdentityIntent {
    let key = IdentitySecret(.init())
    let id = UUID()
    try await secrets.add(key, id: id, policy: .iCloudKeychain)
    let intent = IdentityIntent(
      id: UUID(),
      identityID: id,
      kind: .deleteSecret,
      policy: .iCloudKeychain,
      name: "Old removal",
      publicKey: key.publicKeyLine,
      reassign: [],
      stage: .recorded,
      createdAt: .now
    )
    #expect(model.commitConnections { $0.intents.append(intent) })
    return intent
  }

  @Test
  func reviewingLegacyRemovalDoesNotAuthorizeIt() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = InMemoryIdentitySecretStore()
    let model = app(secrets: secrets)
    let intent = try await legacyDeletion(in: model, secrets: secrets)
    let before = model.connections
    let review = try await model.identityStore.prepareLegacyDeletion(intent.id)
    #expect(
      review.fingerprint
        == SSHPublicKeyFormat.fingerprint(openSSHPublicKey: intent.publicKey)
    )
    await model.identityStore.recover()
    #expect(model.connections == before)
    #expect(model.keyDeletionReviews == [intent])
    #expect(
      try await secrets.storedIdentities(policy: .iCloudKeychain) == [
        intent.identityID
      ]
    )
    #expect(try await model.identityStore.confirmLegacyDeletion(review))
    #expect(model.connections.intents.isEmpty)
    #expect(model.keyDeletionReviews.isEmpty)
    #expect(try await secrets.storedIdentities(policy: .iCloudKeychain).isEmpty)
    #expect(!model.connections.settings.metadataSync)
    #expect(await defaultCloud.saveCount == 0)
  }

  @Test(arguments: [false, true])
  func legacyRemovalRejectsReplacedKeyMaterial(afterReview: Bool) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = InMemoryIdentitySecretStore()
    let model = app(secrets: secrets)
    let intent = try await legacyDeletion(in: model, secrets: secrets)
    let review =
      afterReview
      ? try await model.identityStore.prepareLegacyDeletion(intent.id) : nil
    try await secrets.delete(id: intent.identityID, policy: .iCloudKeychain)
    try await secrets.add(
      IdentitySecret(.init()),
      id: intent.identityID,
      policy: .iCloudKeychain
    )
    await #expect(throws: IdentityOperationError.integrityConflict) {
      if let review {
        _ = try await model.identityStore.confirmLegacyDeletion(review)
      } else {
        _ = try await model.identityStore.prepareLegacyDeletion(intent.id)
      }
    }
    #expect(model.connections.intents == [intent])
    #expect(
      try await secrets.storedIdentities(policy: .iCloudKeychain) == [
        intent.identityID
      ]
    )
  }

  @Test(arguments: [false, true])
  func legacyRemovalRejectsAnAccountChange(returnToOriginal: Bool) async throws
  {
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = InMemoryIdentitySecretStore()
    let model = app(secrets: secrets)
    let intent = try await legacyDeletion(in: model, secrets: secrets)
    let review = try await model.identityStore.prepareLegacyDeletion(intent.id)
    await defaultCloud.setAccount("account-b")
    if returnToOriginal {
      // Even a return to the same account invalidates an earlier review.
      model.identityStore.accountDidChange()
      await defaultCloud.setAccount("acct-a")
      model.identityStore.accountDidChange()
    }
    await #expect(throws: IdentityOperationError.accountChanged) {
      _ = try await model.identityStore.confirmLegacyDeletion(review)
    }
    #expect(model.connections.intents == [intent])
    #expect(
      try await secrets.storedIdentities(policy: .iCloudKeychain) == [
        intent.identityID
      ]
    )
  }

  @Test(arguments: [false, true])
  func legacyRemovalRetriesOnlyTheAuthorizedKey(replaceKey: Bool) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = SuspendedIdentitySecrets()
    var model = app(secrets: secrets)
    let intent = try await legacyDeletion(in: model, secrets: secrets)
    let review = try await model.identityStore.prepareLegacyDeletion(intent.id)
    await secrets.failNextDeletion(.protectedDataUnavailable)
    #expect(try await !model.identityStore.confirmLegacyDeletion(review))
    #expect(model.connections.intents.first?.keychainAccount == "acct-a")
    #expect(model.keyDeletionReviews.isEmpty)
    #expect(
      try await secrets.storedIdentities(policy: .iCloudKeychain) == [
        intent.identityID
      ]
    )
    if replaceKey {
      try await secrets.delete(id: intent.identityID, policy: .iCloudKeychain)
      try await secrets.add(
        IdentitySecret(.init()),
        id: intent.identityID,
        policy: .iCloudKeychain
      )
    }
    model = app(secrets: secrets)
    await model.identityStore.recover()
    #expect(model.connections.intents.isEmpty == !replaceKey)
    #expect(
      try await secrets.storedIdentities(policy: .iCloudKeychain).isEmpty
        == !replaceKey
    )
  }

  @Test
  func missingLegacyKeyDoesNotProveRemovalFromItsUnknownAccount() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = InMemoryIdentitySecretStore()
    let model = app(secrets: secrets)
    let intent = try await legacyDeletion(in: model, secrets: secrets)
    try await secrets.delete(id: intent.identityID, policy: .iCloudKeychain)
    await #expect(
      throws: IdentityOperationError.keyNotAvailableInCurrentAccount
    ) { _ = try await model.identityStore.prepareLegacyDeletion(intent.id) }
    #expect(model.connections.intents == [intent])
  }

  @Test(arguments: [false, true])
  func legacyRemovalRejectsChangedJournalOrCancelledConfirmation(
    cancel: Bool
  ) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = InMemoryIdentitySecretStore()
    let model = app(secrets: secrets)
    let intent = try await legacyDeletion(in: model, secrets: secrets)
    let review = try await model.identityStore.prepareLegacyDeletion(intent.id)
    if !cancel {
      #expect(model.commitConnections { $0.intents[0].stage = .verified })
    }
    let before = model.connections
    let confirmation = Task {
      try await model.identityStore.confirmLegacyDeletion(review)
    }
    if cancel { confirmation.cancel() }
    await #expect(
      throws: cancel ? IdentityOperationError.cancelled : .integrityConflict
    ) { _ = try await confirmation.value }
    #expect(model.connections == before)
    #expect(
      try await secrets.storedIdentities(policy: .iCloudKeychain) == [
        intent.identityID
      ]
    )
  }
}
