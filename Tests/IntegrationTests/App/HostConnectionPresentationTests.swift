#if os(macOS)
import AppKit
import Foundation
@testable import RoamingApp
import SSHIdentity
import SwiftUI
import Testing

extension MainActorIntegrationTests.IdentityAccountBoundaryTests {
  @Test
  func retainedHostRowRejectsAnIdenticalReplacementAccountRecord() async throws
  {
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = app(secrets: InMemoryIdentitySecretStore())
    await select("account-a", in: model)
    let host = HostProfile(nickname: "A", host: "a.local", username: "me")
    #expect(try model.save(host))
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    defer {
      window.contentView = nil;
      window.close()
    }
    window.contentView = NSHostingView(rootView: HostListView(model: model))
    window.makeKeyAndOrderFront(nil)
    let restoreEnhancedUI = enableEnhancedUserInterface()
    defer { restoreEnhancedUI() }
    let identifier = "host.open.\(host.id)"
    try #require(
      try await waitForKeyUI { keyElement(identifier, in: window) != nil }
    )
    let retained = try #require(keyElement(identifier, in: window))
    // Commit synchronously so the retained native callback still belongs to
    // the account the user saw, before SwiftUI can replace the row.
    #expect(
      model.commitConnections {
        ConnectionSyncCoordinator.bind(&$0, to: "account-b")
        $0.activateRecord(
          ConnectionSnapshot.hostRecord(host.id),
          for: "account-b"
        )
        $0.upsertHost(host)
      }
    )
    _ = (retained as AnyObject).accessibilityPerformPress?()
    #expect(model.lastError == RoamingAppModel.hostChangedMessage)
    #expect(model.activeSession == nil)
    #expect(model.pendingTrust == nil)
    #expect(model.pendingPassword == nil)
  }
}
#endif
