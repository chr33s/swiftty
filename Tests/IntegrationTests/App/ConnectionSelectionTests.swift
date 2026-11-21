import Foundation
import NIOSSH
@testable import RoamingApp
import SSHIdentity
import Testing

extension MainActorIntegrationTests.IdentityAccountBoundaryTests {
  @Test(arguments: [false, true], [false, true])
  func delayedChooserDoesNotConnectToAnotherAccountsHost(
    identical: Bool,
    lateInitialization: Bool
  ) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = app(secrets: InMemoryIdentitySecretStore())
    await select("account-a", in: model)
    let server = try await TestSSHServer.start()
    do {
      let original = HostProfile(
        nickname: "A",
        host: "127.0.0.1",
        port: server.port,
        username: TestSSHServer.username
      )
      #expect(try model.save(original))
      let context = model.hostMutationContext(for: original)
      var chooser =
        lateInitialization
        ? nil : WorkspaceChooserModel(model: model, host: original)
      defer { chooser?.close() }
      await select("account-b", in: model)
      var replacement = original
      if !identical { replacement.nickname = "B" }
      #expect(
        model.commitConnections {
          $0.activateRecord(
            ConnectionSnapshot.hostRecord(original.id),
            for: "account-b"
          )
          $0.upsertHost(replacement)
        }
      )
      if lateInitialization {
        chooser = WorkspaceChooserModel(
          model: model,
          host: original,
          context: context
        )
      }
      let selected = try #require(chooser)
      selected.load()
      try #require(
        await eventually { @MainActor in
          if case .failed = selected.phase { return true }
          return model.pendingTrust != nil || model.pendingPassword != nil
        }
      )
      #expect(model.pendingTrust == nil)
      #expect(model.pendingPassword == nil)
      #expect(server.state.authRequests.withLock { $0 } == 0)
      model.resolveTrust(.reject)
      selected.close()
    } catch {
      await server.shutdown()
      throw error
    }
    await server.shutdown()
  }

  @Test
  func migratedChooserCanReconnectAfterAMetadataFailure() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = IdentitySecret(.init())
    let model = app(
      secrets: InMemoryIdentitySecretStore(),
      legacy: InMemoryLegacyKeySource(keys: ["phone": key.ed25519PrivateKey!])
    )
    let server = try await TestSSHServer.start(authorizedKeys: [
      NIOSSHPrivateKey(ed25519Key: key.ed25519PrivateKey!).publicKey
    ])
    do {
      let host = HostProfile(
        nickname: "Legacy",
        host: "127.0.0.1",
        port: server.port,
        username: TestSSHServer.username,
        auth: .legacyKey(label: "phone")
      )
      #expect(try model.save(host))
      #expect(model.commitConnections { $0.migration.completed = false })
      try await model.ssh.trustFile.setTrustedKey(
        server.hostKeyLine,
        for: server.identity
      )
      let chooser = WorkspaceChooserModel(model: model, host: host)
      defer { chooser.close() }
      // This server authenticates and returns unknownSession to metadata
      // requests. Both attempts must reach it using the migrated selection.
      for attempt in 1 ... 2 {
        chooser.load()
        try #require(
          await eventually { @MainActor in
            if case .failed = chooser.phase { return true }
            return false
          }
        )
        #expect(
          chooser.host.auth.identityID == model.hosts.first?.auth.identityID
        )
        #expect(chooser.host.auth.identityID != nil)
        #expect(server.state.bootstrapRequests.withLock { $0.count } == attempt)
        #expect(model.pendingTrust == nil)
        #expect(model.pendingPassword == nil)
      }
    } catch {
      await server.shutdown()
      throw error
    }
    await server.shutdown()
  }

}
