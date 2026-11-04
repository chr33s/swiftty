import Foundation
import NIOSSH
@testable import RoamingApp
import SessionCore
import SSHClient
import SSHIdentity
import SwiftMuxProtocol
import TerminalSurface
import Testing
#if os(macOS)
import AppKit
import SwiftUI
#endif

extension MainActorIntegrationTests.IdentityAccountBoundaryTests {
  @Test(
    arguments: ["shell", "roaming", "workspace"],
    ["unchanged", "rename", "account", "key", "host", "revision", "roundTrip"]
  )
  func selectingAReplacementHostDoesNotReuseItsOldTerminal(
    kind: String,
    change: String
  ) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = app(secrets: InMemoryIdentitySecretStore())
    await select("account-a", in: model)
    let identity = try await model.identityStore.generate(
      name: "A",
      policy: .deviceOnly
    )
    var host = HostProfile(
      nickname: "A",
      host: "a.local",
      username: "me",
      auth: .key(identityID: identity.id)
    )
    #expect(try model.save(host))
    let workspace = SessionID(WorkspaceID())
    func open() {
      if kind == "workspace" {
        model.openWorkspace(host, intent: .resume(workspace, nil))
      } else {
        model.open(host, kind: kind == "shell" ? .ordinarySSH : .roaming)
      }
    }
    open()
    let original = try #require(model.activeSession)
    original.observe(RoamingStatus(state: .active, sessionID: workspace))
    switch change {
    case "account":
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
    case "key":
      #expect(
        model.commitConnections {
          $0.identities.removeAll { $0.id == identity.id }
          $0.insertIdentity(
            SSHIdentityMetadata(
              id: identity.id,
              name: "B",
              publicKey: IdentitySecret(.init()).publicKey,
              storage: .deviceOnly,
              revision: .init(counter: 100, deviceID: UUID())
            )
          )
        }
      )
    case "roundTrip":
      await select("account-b", in: model)
      await select("account-a", in: model)
    case "revision":
      var changed = host
      changed.nickname = "Elsewhere"
      #expect(try model.save(changed))
      #expect(try model.save(host))
    case "host":
      host.host = "b.local"
      #expect(try model.save(host))
    case "rename": try model.identityStore.rename(identity.id, to: "Renamed")
    default: break
    }
    open()
    let reused = change == "unchanged" || change == "rename"
    #expect((model.activeSession === original) == reused)
    #expect(original.isClosed == !reused)
    #expect(model.activeSession?.host == host)
    model.close()
  }

  @Test(arguments: ["unchanged", "superseded", "cancelled", "account"])
  func delayedTerminalShellActionKeepsItsScreenAndMigration(
    change: String
  ) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = SuspendedIdentitySecrets()
    let key = IdentitySecret(.init())
    let model = app(
      secrets: secrets,
      legacy: InMemoryLegacyKeySource(keys: ["phone": key.privateKey])
    )
    await select("account-a", in: model)
    let host = HostProfile(
      nickname: "A",
      host: "a.local",
      username: "me",
      auth: .legacyKey(label: "phone")
    )
    #expect(try model.save(host))
    #expect(model.commitConnections { $0.migration.completed = false })
    model.open(host)
    let original = try #require(model.activeSession)
    await secrets.suspendNextRead()
    let action = Task { await model.openOrdinarySSH(from: original) }
    await secrets.waitForRead()
    switch change {
    case "superseded":
      model.open(
        HostProfile(nickname: "New", host: "new.local", username: "me")
      )
    case "cancelled": action.cancel()
    case "account": await select("account-b", in: model)
    default: break
    }
    let active = model.activeSession
    await secrets.resumeRead()
    await action.value
    if change == "unchanged" {
      #expect(model.activeSession !== original)
      #expect(model.activeSession?.kind == .ordinarySSH)
      #expect(model.activeSession?.host.auth.identityID != nil)
      #expect(
        model.activeSession?.host.auth.identityID
          == model.hosts.first?.auth.identityID
      )
    } else {
      #expect(model.activeSession === active)
      #expect(active?.isClosed == false)
      if change == "account" { #expect(original.actionError != nil) }
    }
    #expect(model.pendingTrust == nil)
    #expect(model.pendingPassword == nil)
    model.close()
  }

  #if os(macOS)
  @Test(arguments: ["unchanged", "account", "key"])
  func retainedTerminalFallbackDoesNotAdoptAReplacementIdentity(
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
      NIOSSHPrivateKey(ed25519Key: original.privateKey).publicKey,
      NIOSSHPrivateKey(ed25519Key: replacement.privateKey).publicKey,
    ])
    let host = HostProfile(
      nickname: "A",
      host: "127.0.0.1",
      port: server.port,
      username: TestSSHServer.username,
      auth: .key(identityID: identity.id)
    )
    #expect(try model.save(host))
    model.open(host)
    let screen = try #require(model.activeSession)
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    defer {
      window.contentView = nil;
      window.close()
    }
    let restoreEnhancedUI = enableEnhancedUserInterface()
    defer { restoreEnhancedUI() }
    var controller: SSHShellController?
    do {
      try await model.ssh.trustFile.setTrustedKey(
        server.hostKeyLine,
        for: server.identity
      )
      window.contentView = NSHostingView(
        rootView: FallbackBanner(model: screen, app: model)
      )
      window.makeKeyAndOrderFront(nil)
      try #require(
        try await waitForKeyUI {
          keyElement("session.openSSH", in: window) != nil
        }
      )
      let button = try #require(keyElement("session.openSSH", in: window))
      if change == "account" { await select("account-b", in: model) }
      if change != "unchanged" {
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
                name: "B",
                publicKey: replacement.publicKey,
                storage: .deviceOnly,
                revision: .init(counter: 100, deviceID: UUID())
              )
            )
          }
        )
        try await secrets.delete(id: identity.id, policy: .deviceOnly)
        try await secrets.add(replacement, id: identity.id, policy: .deviceOnly)
      }
      #expect((button as AnyObject).accessibilityPerformPress?() == true)
      try #require(
        await eventually { @MainActor in
          model.activeSession !== screen || screen.actionError != nil
        }
      )
      if let selected = model.activeSession, selected !== screen {
        let shell = SSHShellController(model: selected, app: model)
        controller = shell
        shell.start()
        try #require(
          await eventually { @MainActor in
            if case .preparing = shell.phase { return false }
            return true
          }
        )
      }
      #expect((model.activeSession === screen) == (change != "unchanged"))
      #expect(
        server.state.authRequests.withLock { $0 }
          == (change == "unchanged" ? 1 : 0)
      )
    } catch {
      await controller?.close(.detach)
      model.close()
      await server.shutdown()
      throw error
    }
    await controller?.close(.detach)
    model.close()
    await server.shutdown()
  }
  #endif
}
