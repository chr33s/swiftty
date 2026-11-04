#if os(macOS)
import AppKit
import Foundation
import NIOSSH
@testable import RoamingApp
import SSHIdentity
import SwiftUI
import Testing

extension MainActorIntegrationTests.IdentityAccountBoundaryTests {
  @Test(arguments: [false, true], ["unchanged", "account", "key"])
  func delayedSFTPPresentationKeepsItsOriginalSelection(
    lateView: Bool,
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
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    func close() {
      window.contentView = nil;
      window.close()
    }
    defer { close() }
    let restoreEnhancedUI = enableEnhancedUserInterface()
    defer { restoreEnhancedUI() }
    do {
      let host = HostProfile(
        nickname: "A",
        host: "127.0.0.1",
        port: server.port,
        username: TestSSHServer.username,
        auth: .key(identityID: identity.id)
      )
      #expect(try model.save(host))
      try await model.ssh.trustFile.setTrustedKey(
        server.hostKeyLine,
        for: server.identity
      )
      let selection = model.connectionSelection(for: host)
      let retained = SFTPBrowserView(host: host, app: model)
      if change != "unchanged" {
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
      let shown =
        lateView ? SFTPBrowserView(selection: selection, app: model) : retained
      window.contentView = NSHostingView(rootView: shown)
      window.makeKeyAndOrderFront(nil)
      try #require(
        try await waitForKeyUI {
          keyElement("sftp.retry", in: window) != nil
            || keyElement("sftp.path", in: window) != nil
        }
      )
      if change == "unchanged" {
        #expect(keyElement("sftp.path", in: window) != nil)
        #expect(server.state.authRequests.withLock { $0 } == 1)
      } else {
        #expect(keyElement("sftp.retry", in: window) != nil)
        #expect(server.state.authRequests.withLock { $0 } == 0)
      }
      #expect(model.modalDepth == 1)
      close()
      try #require(try await waitForKeyUI { model.modalDepth == 0 })
    } catch {
      close()
      await server.shutdown()
      throw error
    }
    await server.shutdown()
  }
}
#endif
