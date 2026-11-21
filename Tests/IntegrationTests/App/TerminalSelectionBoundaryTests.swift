import Foundation
import NIOSSH
@testable import RoamingApp
import SSHClient
import SSHIdentity
import Testing

extension MainActorIntegrationTests.IdentityAccountBoundaryTests {
  @Test(
    arguments: [false, true],
    [
      "screenAccount", "controllerAccount", "screenKey", "controllerKey",
      "unchanged", "rename", "unsaved", "legacy", "backgroundMigration",
    ]
  )
  func terminalSignInKeepsItsOriginalSelection(
    shell: Bool,
    change: String
  ) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = InMemoryIdentitySecretStore()
    let legacyKey = IdentitySecret(.init())
    let model = app(
      secrets: secrets,
      legacy: InMemoryLegacyKeySource(keys: ["phone": legacyKey.ed25519PrivateKey!])
    )
    await select("account-a", in: model)
    let identity = try await model.identityStore.generate(
      name: "A",
      policy: .deviceOnly
    )
    let original = try await model.identityStore.resolve(identity.id)
    let replacement = IdentitySecret(.init())
    let server = try await TestSSHServer.start(authorizedKeys: [
      NIOSSHPrivateKey(ed25519Key: original.ed25519PrivateKey!).publicKey,
      NIOSSHPrivateKey(ed25519Key: replacement.ed25519PrivateKey!).publicKey,
      NIOSSHPrivateKey(ed25519Key: legacyKey.ed25519PrivateKey!).publicKey,
    ])
    let legacy = change == "legacy" || change == "backgroundMigration"
    let host = HostProfile(
      nickname: "A",
      host: "127.0.0.1",
      port: server.port,
      username: TestSSHServer.username,
      auth: legacy ? .legacyKey(label: "phone") : .key(identityID: identity.id)
    )
    if change != "unsaved" { #expect(try model.save(host)) }
    if legacy {
      #expect(model.commitConnections { $0.migration.completed = false })
    }
    if shell {
      model.open(host, kind: .ordinarySSH)
    } else {
      model.openWorkspace(host, intent: .create)
    }
    let screen = try #require(model.activeSession)
    var ordinary: SSHShellController?
    var roaming: RoamingTerminalController?
    func createController() {
      if shell {
        ordinary = SSHShellController(model: screen, app: model)
      } else {
        roaming = RoamingTerminalController(model: screen, app: model)
      }
    }
    do {
      try await model.ssh.trustFile.setTrustedKey(
        server.hostKeyLine,
        for: server.identity
      )
      if change == "backgroundMigration" { await model.identityStore.recover() }
      if change.hasPrefix("controller") { createController() }
      if change.hasSuffix("Account") { await select("account-b", in: model) }
      if change.hasSuffix("Account") || change.hasSuffix("Key") {
        #expect(
          model.commitConnections {
            if change.hasSuffix("Account") {
              $0.activateRecord(
                ConnectionSnapshot.hostRecord(host.id),
                for: "account-b"
              )
              $0.upsertHost(host)
              $0.activateRecord(
                ConnectionSnapshot.identityRecord(identity.id),
                for: "account-b"
              )
            } else {
              $0.identities.removeAll { $0.id == identity.id }
            }
            $0.insertIdentity(
              SSHIdentityMetadata(
                id: identity.id,
                name: "B",
                publicKeyLine: replacement.publicKeyLine,
                storage: .deviceOnly,
                revision: .init(counter: 100, deviceID: UUID())
              )
            )
          }
        )
        try await secrets.delete(id: identity.id, policy: .deviceOnly)
        try await secrets.add(replacement, id: identity.id, policy: .deviceOnly)
      } else if change == "rename" {
        try model.identityStore.rename(identity.id, to: "Renamed")
      }
      if ordinary == nil && roaming == nil { createController() }
      ordinary?.start()
      roaming?.start()
      try #require(
        await eventually { @MainActor in
          let phase = ordinary?.phase ?? roaming!.phase
          if case .preparing = phase { return false }
          return true
        }
      )
      let allowed = !change.hasSuffix("Account") && !change.hasSuffix("Key")
      #expect(
        server.state.authRequests.withLock { $0 }
          == (allowed ? (shell ? 1 : 2) : 0)
      )
      if shell { #expect((ordinary?.phase == .running) == allowed) }
      #expect(
        server.state.bootstrapRequests.withLock { $0.count }
          == (allowed && !shell ? 1 : 0)
      )
    } catch {
      await ordinary?.close(.detach)
      await roaming?.close(.detach)
      model.close()
      await server.shutdown()
      throw error
    }
    await ordinary?.close(.detach)
    await roaming?.close(.detach)
    model.close()
    await server.shutdown()
  }

  @Test(arguments: [false, true])
  func roamingProbeCannotRecaptureAnAccountAtBootstrap(
    changeAccount: Bool
  ) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = SuspendedIdentitySecrets()
    let model = app(secrets: secrets)
    await select("account-a", in: model)
    let identity = try await model.identityStore.generate(
      name: "A",
      policy: .deviceOnly
    )
    let original = try await model.identityStore.resolve(identity.id)
    let server = try await TestSSHServer.start(authorizedKeys: [
      NIOSSHPrivateKey(ed25519Key: original.ed25519PrivateKey!).publicKey
    ])
    let host = HostProfile(
      nickname: "A",
      host: "127.0.0.1",
      port: server.port,
      username: TestSSHServer.username,
      auth: .key(identityID: identity.id)
    )
    #expect(try model.save(host))
    model.openWorkspace(host, intent: .create)
    let screen = try #require(model.activeSession)
    let controller = RoamingTerminalController(model: screen, app: model)
    do {
      try await model.ssh.trustFile.setTrustedKey(
        server.hostKeyLine,
        for: server.identity
      )
      await secrets.suspendNextRead()
      controller.start()
      await secrets.waitForRead()
      if changeAccount {
        await select("account-b", in: model)
        #expect(
          model.commitConnections {
            $0.activateRecord(
              ConnectionSnapshot.hostRecord(host.id),
              for: "account-b"
            )
            $0.upsertHost(host)
            $0.activateRecord(
              ConnectionSnapshot.identityRecord(identity.id),
              for: "account-b"
            )
            $0.insertIdentity(identity)
          }
        )
      }
      await secrets.resumeRead()
      try #require(
        await eventually { @MainActor in
          if case .failed = controller.phase { return true }
          return false
        }
      )
      // The captured probe may finish. A fresh bootstrap must not recapture B,
      // even when B happens to expose identical host and key metadata.
      #expect(
        server.state.authRequests.withLock { $0 } == (changeAccount ? 1 : 2)
      )
      #expect(
        server.state.bootstrapRequests.withLock { $0.count }
          == (changeAccount ? 0 : 1)
      )
    } catch {
      await secrets.resumeRead()
      await controller.close(.detach)
      model.close()
      await server.shutdown()
      throw error
    }
    await controller.close(.detach)
    model.close()
    await server.shutdown()
  }
  @Test
  func anActiveShellKeepsItsAuthenticatedConnectionAfterAccountChange()
    async throws
  {
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = app(secrets: InMemoryIdentitySecretStore())
    await select("account-a", in: model)
    let identity = try await model.identityStore.generate(
      name: "A",
      policy: .deviceOnly
    )
    let original = try await model.identityStore.resolve(identity.id)
    let server = try await TestSSHServer.start(authorizedKeys: [
      NIOSSHPrivateKey(ed25519Key: original.ed25519PrivateKey!).publicKey
    ])
    let host = HostProfile(
      nickname: "A",
      host: "127.0.0.1",
      port: server.port,
      username: TestSSHServer.username,
      auth: .key(identityID: identity.id)
    )
    #expect(try model.save(host))
    model.open(host, kind: .ordinarySSH)
    let screen = try #require(model.activeSession)
    let controller = SSHShellController(model: screen, app: model)
    do {
      try await model.ssh.trustFile.setTrustedKey(
        server.hostKeyLine,
        for: server.identity
      )
      controller.start()
      try #require(
        await eventually { @MainActor in controller.phase == .running }
      )
      let connection = try #require(controller.connection)
      await select("account-b", in: model)
      controller.start()
      controller.session.send(.text("still-connected"))
      #expect(
        await eventually { @MainActor in
          controller.session.withState {
            $0.screenLines.contains { $0.contains("still-connected") }
          }
        }
      )
      #expect(controller.phase == .running)
      #expect(controller.connection === connection)
      #expect(connection.isActive)
      #expect(model.activeSession === screen)
      #expect(server.state.authRequests.withLock { $0 } == 1)
    } catch {
      await controller.close(.detach)
      model.close()
      await server.shutdown()
      throw error
    }
    await controller.close(.detach)
    model.close()
    await server.shutdown()
  }

}
