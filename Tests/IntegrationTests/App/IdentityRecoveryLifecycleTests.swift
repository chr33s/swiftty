import Foundation
@testable import RoamingApp
import SSHClient
import SSHIdentity
import Testing

extension MainActorIntegrationTests.IdentityAccountBoundaryTests {
  @Test
  func foregroundRecoveryDoesNotWaitForCloudAccountLookup() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = SuspendedIdentitySecrets()
    let model = app(secrets: secrets)
    await secrets.storage.failNextRead(.protectedDataUnavailable)
    await #expect(throws: IdentityOperationError.pendingVerification) {
      _ = try await model.identityStore.generate(
        name: "Local",
        policy: .deviceOnly
      )
    }
    let (started, signalStart) = AsyncStream<Void>.makeStream()
    let (resume, signalResume) = AsyncStream<Void>.makeStream()
    defer {
      signalResume.yield(());
      signalResume.finish()
    }
    await defaultCloud.onNextAccount {
      signalStart.yield(())
      signalStart.finish()
      for await _ in resume { break }
    }
    let refresh = Task { await model.refreshConnections() }
    for await _ in started { break }
    let deadline = ContinuousClock.now + .seconds(2)
    while model.identities.isEmpty && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.identities.map(\.name) == ["Local"])
    signalResume.yield(())
    signalResume.finish()
    await refresh.value
    #expect(!model.connections.settings.metadataSync)
    #expect(await defaultCloud.saveCount == 0)
  }

  @Test(arguments: softwareIdentityPolicies)
  func foregroundRefreshResumesKeysAfterUnlockWithoutEnablingSync(
    policy: IdentityStoragePolicy
  ) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = InMemoryIdentitySecretStore()
    let model = app(secrets: secrets)
    await secrets.failNextRead(.protectedDataUnavailable)
    await #expect(throws: IdentityOperationError.pendingVerification) {
      _ = try await model.identityStore.generate(
        name: "Deferred",
        policy: policy
      )
    }
    #expect(model.identities.isEmpty)
    await model.refreshConnections()
    #expect(model.identities.map(\.name) == ["Deferred"])
    #expect(model.connections.intents.isEmpty)
    #expect(!model.connections.settings.metadataSync)
    #expect(await defaultCloud.saveCount == 0)
  }
}
