#if !os(tvOS)
import Foundation
import NIOSSH
import SSHClient
@testable import RoamingApp
import SSHIdentity
import Testing

extension MainActorIntegrationTests.IdentityAccountBoundaryTests {
  @Test(arguments: ["first", "reconnect", "active"], ["account", "key"])
  func sftpKeepsTheSelectedIdentityAcrossDelayedSignIn(
    stage: String,
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
    let original = try await model.identityStore.resolve(identity.id)
    let replacement = IdentitySecret(.init())
    let server = try await TestSSHServer.start(authorizedKeys: [
      NIOSSHPrivateKey(ed25519Key: original.ed25519PrivateKey!).publicKey,
      NIOSSHPrivateKey(ed25519Key: replacement.ed25519PrivateKey!).publicKey,
    ])
    let host = HostProfile(
      nickname: "A",
      host: "127.0.0.1",
      port: server.port,
      username: TestSSHServer.username,
      auth: .key(identityID: identity.id)
    )
    #expect(try model.save(host))
    let browser = SFTPBrowserModel(
      host: host,
      app: model,
      transferDirectory: directory.appendingPathComponent("transfers")
    )
    do {
      try await model.ssh.trustFile.setTrustedKey(
        server.hostKeyLine,
        for: server.identity
      )
      if stage != "first" {
        await browser.connect()
        try #require(browser.status == .ready)
        if stage == "reconnect" { await browser.shutdown().value }
      }
      let authentications = server.state.authRequests.withLock { $0 }
      if change == "account" { await select("account-b", in: model) }
      #expect(
        model.commitConnections {
          if change == "account" {
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
              name: "Replacement",
              publicKeyLine: replacement.publicKeyLine,
              storage: .deviceOnly,
              revision: .init(counter: 100, deviceID: UUID())
            )
          )
        }
      )
      try await secrets.delete(id: identity.id, policy: .deviceOnly)
      try await secrets.add(replacement, id: identity.id, policy: .deviceOnly)
      if stage == "reconnect" {
        await browser.start()
      } else {
        await browser.connect()
      }
      if stage == "active" {
        #expect(browser.status == .ready)
        await browser.list()
        #expect(browser.status == .ready)
      } else {
        #expect(browser.status != .ready)
      }
      #expect(server.state.authRequests.withLock { $0 } == authentications)
      #expect(model.pendingPassword == nil)
    } catch {
      await browser.shutdown().value
      await server.shutdown()
      throw error
    }
    await browser.shutdown().value
    await server.shutdown()
  }

  @Test
  func legacySFTPReopenKeepsMigrationAfterACancelledSignIn() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = IdentitySecret(.init())
    let model = app(
      secrets: InMemoryIdentitySecretStore(),
      legacy: InMemoryLegacyKeySource(keys: ["phone": key.ed25519PrivateKey!])
    )
    let server = try await TestSSHServer.start()
    let host = HostProfile(
      nickname: "Legacy",
      host: "127.0.0.1",
      port: server.port,
      username: TestSSHServer.username,
      auth: .legacyKey(label: "phone")
    )
    #expect(try model.save(host))
    #expect(model.commitConnections { $0.migration.completed = false })
    var attempts = 0
    var release: CheckedContinuation<Void, Never>?
    let browser = SFTPBrowserModel(
      host: host,
      app: model,
      transferDirectory: directory.appendingPathComponent("transfers"),
      connectSSH: {
        attempts += 1
        if attempts == 1 { await withCheckedContinuation { release = $0 } }
        // Deliberately hand back a late connection even after cancellation.
        return try await Task.detached { try await server.connect() }.value
      }
    )
    let first = Task { await browser.connect() }
    do {
      try #require(await eventually { @MainActor in release != nil })
      let retirement = browser.shutdown()
      await browser.start()
      #expect(attempts == 2)
      #expect(browser.status == .ready)
      release?.resume();
      release = nil
      await first.value
      await retirement.value
      #expect(browser.status == .ready)
    } catch {
      release?.resume();
      release = nil
      await first.value
      await browser.shutdown().value
      await server.shutdown()
      throw error
    }
    await browser.shutdown().value
    await server.shutdown()
  }

  @Test(arguments: [
    "saved", "unsaved", "rename", "legacy", "backgroundMigration",
  ])
  func validSFTPSelectionsSurviveReopening(kind: String) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = IdentitySecret(.init())
    let model = app(
      secrets: InMemoryIdentitySecretStore(),
      legacy: InMemoryLegacyKeySource(keys: ["phone": key.ed25519PrivateKey!])
    )
    let legacy = kind == "legacy" || kind == "backgroundMigration"
    let identity =
      legacy
      ? nil
      : try await model.identityStore.generate(name: "A", policy: .deviceOnly)
    let authorized =
      if let identity {
        try await model.identityStore.resolve(identity.id).ed25519PrivateKey!
      } else { key.ed25519PrivateKey! }
    let server = try await TestSSHServer.start(authorizedKeys: [
      NIOSSHPrivateKey(ed25519Key: authorized).publicKey
    ])
    let host = HostProfile(
      nickname: "A",
      host: "127.0.0.1",
      port: server.port,
      username: TestSSHServer.username,
      auth: legacy ? .legacyKey(label: "phone") : .key(identityID: identity!.id)
    )
    if kind != "unsaved" { #expect(try model.save(host)) }
    if legacy {
      #expect(model.commitConnections { $0.migration.completed = false })
    }
    let browser = SFTPBrowserModel(
      host: host,
      app: model,
      transferDirectory: directory.appendingPathComponent("transfers")
    )
    do {
      try await model.ssh.trustFile.setTrustedKey(
        server.hostKeyLine,
        for: server.identity
      )
      if kind == "backgroundMigration" { await model.identityStore.recover() }
      if kind == "rename" {
        try model.identityStore.rename(identity!.id, to: "Renamed")
      }
      for attempt in 1 ... 2 {
        await browser.start()
        #expect(browser.status == .ready)
        #expect(server.state.authRequests.withLock { $0 } == attempt)
        await browser.shutdown().value
      }
    } catch {
      await browser.shutdown().value
      await server.shutdown()
      throw error
    }
    await server.shutdown()
  }

  @Test(arguments: [
    "roundTrip", "notification", "deleted", "revision", "arrival",
  ])
  func sftpRefusesAnInvalidatedHostSelection(change: String) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = app(secrets: InMemoryIdentitySecretStore())
    await select("account-a", in: model)
    let identity = try await model.identityStore.generate(
      name: "A",
      policy: .deviceOnly
    )
    let secret = try await model.identityStore.resolve(identity.id)
    let server = try await TestSSHServer.start(authorizedKeys: [
      NIOSSHPrivateKey(ed25519Key: secret.ed25519PrivateKey!).publicKey
    ])
    let host = HostProfile(
      nickname: "A",
      host: "127.0.0.1",
      port: server.port,
      username: TestSSHServer.username,
      auth: .key(identityID: identity.id)
    )
    if change != "arrival" { #expect(try model.save(host)) }
    let browser = SFTPBrowserModel(
      host: host,
      app: model,
      transferDirectory: directory.appendingPathComponent("transfers")
    )
    do {
      try await model.ssh.trustFile.setTrustedKey(
        server.hostKeyLine,
        for: server.identity
      )
      switch change {
      case "roundTrip":
        await select("account-b", in: model);
        await select("account-a", in: model)
      case "notification": model.identityStore.accountDidChange()
      case "deleted": model.delete(host)
      case "revision":
        var edited = host
        edited.nickname = "Elsewhere"
        #expect(try model.save(edited))
        #expect(try model.save(host))
      default: #expect(try model.save(host))
      }
      await browser.connect()
      #expect(browser.status != .ready)
      #expect(server.state.authRequests.withLock { $0 } == 0)
      #expect(model.pendingTrust == nil)
      #expect(model.pendingPassword == nil)
    } catch {
      await browser.shutdown().value
      await server.shutdown()
      throw error
    }
    await browser.shutdown().value
    await server.shutdown()
  }

}

#endif
