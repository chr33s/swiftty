import Crypto
import Foundation
import NIOSSH
@testable import RoamingApp
import SSHClient
import SSHIdentity
import TerminalSurface
import Testing

extension MainActorIntegrationTests.IdentityAccountBoundaryTests {
  @Test(arguments: [false, true])
  func deferredKeyResolutionCannotAdoptAnotherAccountsIdentity(
    bootstrap: Bool
  ) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = InMemoryIdentitySecretStore()
    let model = app(secrets: secrets)
    await select("account-a", in: model)
    let identity = try await model.identityStore.generate(
      name: "A",
      policy: .deviceOnly
    )
    let host = HostProfile(
      nickname: "A",
      host: "a.local",
      username: "me",
      auth: .key(identityID: identity.id)
    )
    #expect(try model.save(host))
    let original = try await model.identityStore.resolve(identity.id)
    let endpoint =
      bootstrap
      ? try await model.ssh.bootstrapEndpoint(for: host)
      : model.ssh.endpoint(for: host, credential: .ed25519(original.ed25519PrivateKey!))
    await select("account-b", in: model)
    let replacement = IdentitySecret(.init())
    #expect(
      model.commitConnections {
        $0.activateRecord(
          ConnectionSnapshot.identityRecord(identity.id),
          for: "account-b"
        )
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
    guard case .resolved(let resolve) = endpoint.credentialSource else {
      Issue.record("Key endpoint retained a fixed credential")
      return
    }
    await #expect(throws: SSHAccessError.self) { _ = try await resolve() }
    #expect(endpoint.configuration.host == "a.local")
  }

  @Test(arguments: [
    "unchanged", "account", "roundTrip", "fields", "auth", "deleted",
    "notification", "unsaved",
  ])
  func waitingForMigrationKeepsTheSelectedEndpoint(change: String) async throws
  {
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = SuspendedIdentitySecrets()
    let legacy = InMemoryLegacyKeySource(keys: [
      "phone": Curve25519.Signing.PrivateKey()
    ])
    let model = app(secrets: secrets, legacy: legacy)
    await select("account-a", in: model)
    let host = legacyHost("A")
    #expect(try model.save(host))
    #expect(model.commitConnections { $0.migration.completed = false })
    await secrets.suspendNextRead()
    var draft = host
    if change == "unsaved" { draft.nickname = "Unreviewed draft" }
    let selected = draft
    let endpoint = Task { try await model.ssh.bootstrapEndpoint(for: selected) }
    await secrets.waitForRead()
    switch change {
    case "account", "roundTrip":
      await select("account-b", in: model)
      if change == "roundTrip" {
        await select("account-a", in: model)
      } else {
        var replacement = host
        replacement.host = "b.local"
        replacement.auth = .key(identityID: UUID())
        #expect(
          model.commitConnections {
            $0.activateRecord(
              ConnectionSnapshot.hostRecord(host.id),
              for: "account-b"
            )
            $0.upsertHost(replacement)
          }
        )
      }
    case "fields", "auth":
      var replacement = host
      if change == "fields" {
        replacement.host = "changed.local"
      } else {
        replacement.auth = .key(identityID: UUID())
      }
      #expect(try model.save(replacement))
    case "deleted": model.delete(host)
    case "notification": model.identityStore.accountDidChange()
    default: break
    }
    await secrets.resumeRead()
    if change == "unchanged" {
      let result = try await endpoint.value
      #expect(result.configuration.host == host.host)
      #expect(model.hosts.first?.auth.identityID != nil)
    } else {
      await #expect(throws: SSHAccessError.self) {
        _ = try await endpoint.value
      }
    }
  }

  @Test(arguments: [
    "unchanged", "rename", "roundTrip", "notification", "key", "storage",
    "deleted",
  ])
  func deferredKeyResolutionChecksSelectionWithoutPinningItsName(
    change: String
  ) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = InMemoryIdentitySecretStore()
    let model = app(secrets: secrets)
    await select("account-a", in: model)
    let identity = try await model.identityStore.generate(
      name: "A",
      policy: .deviceOnly
    )
    let host = HostProfile(
      nickname: "A",
      host: "a.local",
      username: "me",
      auth: .key(identityID: identity.id)
    )
    let endpoint = try await model.ssh.bootstrapEndpoint(for: host)
    switch change {
    case "rename": try model.identityStore.rename(identity.id, to: "Renamed")
    case "roundTrip":
      await select("account-b", in: model)
      await select("account-a", in: model)
    case "notification": model.identityStore.accountDidChange()
    case "deleted":
      #expect(model.commitConnections { $0.tombstoneIdentity(identity.id) })
    case "key", "storage":
      let secret =
        change == "key"
        ? IdentitySecret(.init())
        : try await model.identityStore.resolve(identity.id)
      let policy: IdentityStoragePolicy =
        change == "storage" ? .iCloudKeychain : .deviceOnly
      #expect(
        model.commitConnections {
          let index = $0.identities.firstIndex { $0.id == identity.id }!
          $0.identities[index] = SSHIdentityMetadata(
            id: identity.id,
            name: "Replacement",
            publicKeyLine: secret.publicKeyLine,
            storage: policy,
            revision: .init(counter: 100, deviceID: UUID())
          )
        }
      )
      try await secrets.delete(id: identity.id, policy: .deviceOnly)
      try await secrets.add(secret, id: identity.id, policy: policy)
    default: break
    }
    guard case .resolved(let resolve) = endpoint.credentialSource else {
      Issue.record("Missing per-bootstrap lookup");
      return
    }
    if change == "unchanged" || change == "rename" {
      guard case .publicKey(.ed25519(let key)) = try await resolve() else {
        Issue.record("Unexpected credential");
        return
      }
      #expect(
        IdentitySecret(key).publicKeyLine == identity.publicKey
      )
    } else {
      await #expect(throws: SSHAccessError.self) { _ = try await resolve() }
    }
  }

  @Test
  func anAuthenticationAlreadyReadingItsKeyKeepsTheCapturedSelection()
    async throws
  {
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = SuspendedIdentitySecrets()
    let model = app(secrets: secrets)
    await select("account-a", in: model)
    let identity = try await model.identityStore.generate(
      name: "A",
      policy: .deviceOnly
    )
    let host = HostProfile(
      nickname: "A",
      host: "a.local",
      username: "me",
      auth: .key(identityID: identity.id)
    )
    let endpoint = try await model.ssh.bootstrapEndpoint(for: host)
    guard case .resolved(let resolve) = endpoint.credentialSource else {
      Issue.record("Missing per-bootstrap lookup");
      return
    }
    await secrets.suspendNextRead()
    let reading = Task { try await resolve() }
    await secrets.waitForRead()
    await select("account-b", in: model)
    await secrets.resumeRead()
    guard case .publicKey(.ed25519(let key)) = try await reading.value else {
      Issue.record("Unexpected credential");
      return
    }
    #expect(
      IdentitySecret(key).publicKeyLine == identity.publicKey
    )
    await #expect(throws: SSHAccessError.self) { _ = try await resolve() }
  }

  @Test
  func trustConfirmationCannotAdoptAnotherAccountsKey() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = InMemoryIdentitySecretStore()
    let model = app(secrets: secrets)
    await select("account-a", in: model)
    let identity = try await model.identityStore.generate(
      name: "A",
      policy: .deviceOnly
    )
    let replacement = IdentitySecret(.init())
    let server = try await TestSSHServer.start(authorizedKeys: [
      NIOSSHPrivateKey(ed25519Key: replacement.ed25519PrivateKey!).publicKey
    ])
    do {
      // Unsaved pairing drafts are not invalidated by the saved-host prompt cleanup.
      let host = HostProfile(
        nickname: "Draft",
        host: "127.0.0.1",
        port: server.port,
        username: TestSSHServer.username,
        auth: .key(identityID: identity.id)
      )
      let access = SSHAccess(
        app: model,
        trustStore: FileHostTrustStore(
          fileURL: directory.appendingPathComponent("trust.json")
        )
      )
      let connection = Task { try await access.connect(host) }
      defer { connection.cancel() }
      try #require(await eventually { @MainActor in model.pendingTrust != nil })
      await select("account-b", in: model)
      #expect(
        model.commitConnections {
          $0.activateRecord(
            ConnectionSnapshot.identityRecord(identity.id),
            for: "account-b"
          )
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
      model.resolveTrust(.trust)
      // Close even a wrongly accepted connection so the red proof cannot leak it.
      let result = await connection.result
      if case .success(let connected) = result {
        await connected.close()
        Issue.record("Authenticated with the replacement account's key")
      }
      #expect(server.state.authRequests.withLock { $0 } == 0)
    } catch {
      await server.shutdown()
      throw error
    }
    await server.shutdown()
  }

}
