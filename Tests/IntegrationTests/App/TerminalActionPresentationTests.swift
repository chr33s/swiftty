#if os(macOS)
import AppKit
import Foundation
import NIOSSH
@testable import RoamingApp
import SSHIdentity
import SwiftUI
import Testing

@MainActor
private struct TerminalActionRoot: View {
  @Bindable
  var app: RoamingAppModel
  var body: some View {
    NavigationStack {
      if let screen = app.activeSession {
        TerminalScreen(model: screen) { app.close() }
      }
    }
    .environment(\.terminalSurfaceFactory, LiveTerminalSurfaceFactory(app: app))
  }
}

extension MainActorIntegrationTests.IdentityAccountBoundaryTests {
  @MainActor
  private final class TerminalFilesMenu: NSObject {
    var item: NSMenuItem?
    @objc
    func tracking(_ notification: Notification) {
      guard let menu = notification.object as? NSMenu else { return }
      item = menu.items.first { $0.title.contains("Files") }
      DispatchQueue.main.async { menu.cancelTracking() }
    }
  }

  @Test(
    arguments: ["shellFiles", "roamingFiles", "shellRetry", "roamingFallback"],
    ["unchanged", "account", "key"]
  )
  func retainedTerminalActionsKeepTheirAccountAndKey(
    action: String,
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
    server.state.faults.withLock { $0.rejectShell = action == "shellRetry" }
    if action == "roamingFallback" {
      server.state.bootstrapFailure.withLock { $0 = .malformed }
    }
    let host = HostProfile(
      nickname: "A",
      host: "127.0.0.1",
      port: server.port,
      username: TestSSHServer.username,
      auth: .key(identityID: identity.id)
    )
    #expect(try model.save(host))
    if action.hasPrefix("shell") {
      model.open(host, kind: .ordinarySSH)
    } else {
      model.openWorkspace(host, intent: .create)
    }
    let screen = try #require(model.activeSession)
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 650),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    let restoreEnhancedUI = enableEnhancedUserInterface()
    defer { restoreEnhancedUI() }
    func close() async {
      let active = model.activeSession?.controller
      let first = screen.controller
      if let sheet = window.attachedSheet {
        window.endSheet(sheet);
        sheet.orderOut(nil)
      }
      window.contentView = nil
      window.close()
      model.close()
      await active?.close(.detach)
      await first?.close(.detach)
      _ = await eventually { @MainActor in model.modalDepth == 0 }
    }
    do {
      try await model.ssh.trustFile.setTrustedKey(
        server.hostKeyLine,
        for: server.identity
      )
      window.contentView = NSHostingView(
        rootView: TerminalActionRoot(app: model)
      )
      window.makeKeyAndOrderFront(nil)
      try #require(
        await eventually { @MainActor in
          if let shell = screen.controller as? SSHShellController {
            if case .preparing = shell.phase { return false };
            return true
          }
          if let roaming = screen.controller as? RoamingTerminalController {
            if case .failed = roaming.phase { return true }
          }
          return false
        }
      )
      let connection = (screen.controller as? SSHShellController)?.connection
      let authentications = server.state.authRequests.withLock { $0 }
      let files = action.hasSuffix("Files")
      let identifier =
        files
        ? "session.files"
        : action == "shellRetry" ? "session.retry" : "session.openSSH"
      let press: () -> Void
      if action == "roamingFiles" {
        try #require(
          try await waitForKeyUI {
            keyElement("session.menu", in: window) != nil
          }
        )
        let menu = try #require(keyElement("session.menu", in: window))
        let displayed = TerminalFilesMenu()
        NotificationCenter.default.addObserver(
          displayed,
          selector: #selector(TerminalFilesMenu.tracking(_:)),
          name: NSMenu.didBeginTrackingNotification,
          object: nil
        )
        defer { NotificationCenter.default.removeObserver(displayed) }
        // A press can be dropped while the previous case's menu is still
        // dismissing; press again until tracking begins.
        var pressed = ContinuousClock.now - .seconds(1)
        try #require(
          try await waitForKeyUI {
            if displayed.item == nil,
              ContinuousClock.now - pressed >= .milliseconds(250)
            {
              pressed = .now
              _ = (menu as AnyObject).accessibilityPerformPress?()
            }
            return displayed.item != nil
          }
        )
        let item = try #require(displayed.item)
        let target = try #require(item.target)
        let selector = try #require(item.action)
        press = { #expect(NSApp.sendAction(selector, to: target, from: item)) }
      } else {
        try #require(
          try await waitForKeyUI { keyElement(identifier, in: window) != nil }
        )
        let button = try #require(keyElement(identifier, in: window))
        press = {
          // Native toolbar elements may return false after dispatching their
          // action. The resulting sheet/connection below proves it ran.
          _ = (button as AnyObject).accessibilityPerformPress?()
        }
      }
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
      server.state.faults.withLock { $0.rejectShell = false }
      press()
      if files {
        try #require(
          try await waitForKeyUI {
            guard let sheet = window.attachedSheet else { return false }
            return keyElement("sftp.path", in: sheet) != nil
              || keyElement("sftp.retry", in: sheet) != nil
          }
        )
        let sheet = try #require(window.attachedSheet)
        #expect(
          keyElement(
            change == "unchanged" ? "sftp.path" : "sftp.retry",
            in: sheet
          ) != nil
        )
        #expect(model.activeSession === screen)
        #expect(model.modalDepth == 1)
        if action == "shellFiles" { #expect(connection?.isActive == true) }
      } else if change == "unchanged" {
        try #require(
          await eventually { @MainActor in
            guard model.activeSession !== screen,
              let shell = model.activeSession?.controller as? SSHShellController
            else { return false }
            return shell.phase == .running
          }
        )
      } else {
        try #require(
          try await waitForKeyUI {
            screen.actionError != nil && window.attachedSheet != nil
          }
        )
        #expect(model.activeSession === screen)
        #expect(!screen.isClosed)
      }
      #expect(
        server.state.authRequests.withLock { $0 } == authentications
          + (change == "unchanged" ? 1 : 0)
      )
      await close()
      #expect(model.modalDepth == 0)
    } catch {
      await close()
      await server.shutdown()
      throw error
    }
    await server.shutdown()
  }
}
#endif
