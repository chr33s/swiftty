#if os(macOS)
import AppKit
import Foundation
@testable import RoamingApp
import SSHClient
import SSHIdentity
import SwiftUI
import Testing

extension MainActorIntegrationTests.IdentityAccountBoundaryTests {
  @Test(arguments: ["confirm", "cancel", "account"])
  func oldTransferRecoveryRequiresTheDisplayedConfirmation(
    action: String
  ) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = app(secrets: InMemoryIdentitySecretStore())
    await select("account-a", in: model)
    let host = HostProfile(nickname: "A", host: "a.local", username: "me")
    #expect(try model.save(host))
    let root = directory.appendingPathComponent("transfers")
    let source = directory.appendingPathComponent("source.bin")
    try Data("older-source".utf8).write(to: source)
    let manifest = try await SFTPTransfers.prepareUpload(
      source: source,
      remotePath: "/source.bin",
      stagingDirectory: root.appendingPathComponent("staging"),
      overwriteExisting: true
    )
    let store = TransferManifestStore(
      directory: root.appendingPathComponent("manifests")
    )
    try store.save(manifest)
    var connections = 0
    let browser = SFTPBrowserModel(
      host: host,
      app: model,
      transferDirectory: root,
      connectSSH: {
        connections += 1;
        throw SSHAccessError.unreachable
      }
    )
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    defer {
      if let sheet = window.attachedSheet {
        window.endSheet(sheet);
        sheet.orderOut(nil)
      }
      window.contentView = nil;
      window.close()
    }
    let restoreEnhancedUI = enableEnhancedUserInterface()
    defer { restoreEnhancedUI() }
    window.contentView = NSHostingView(
      rootView: SFTPBrowserContent(model: browser, app: model)
    )
    window.makeKeyAndOrderFront(nil)
    do {
      func actionElement(_ id: String) -> NSObject? {
        var current: NSWindow? = window
        while let shown = current {
          if let found = keyElement(id, in: shown) { return found }
          current = shown.attachedSheet
        }
        return nil
      }
      try #require(
        try await waitForKeyUI {
          actionElement("sftp.reviewTransfers") != nil && connections == 1
        }
      )
      let entry = try #require(actionElement("sftp.reviewTransfers"))
      _ = (entry as AnyObject).accessibilityPerformPress?()
      let reviewID = "sftp.recover.\(manifest.id)"
      try #require(try await waitForKeyUI { actionElement(reviewID) != nil })
      let button = try #require(actionElement(reviewID))
      _ = (button as AnyObject).accessibilityPerformPress?()
      try #require(
        try await waitForKeyUI { actionElement("sftp.confirmRecovery") != nil }
      )
      #expect(browser.transfers.isEmpty)
      #expect(store.loadAll() == [manifest])
      #expect(connections == 1)
      if action == "account" { await select("account-b", in: model) }
      let confirm = try #require(
        actionElement(
          action == "cancel" ? "sftp.cancelRecovery" : "sftp.confirmRecovery"
        )
      )
      _ = (confirm as AnyObject).accessibilityPerformPress?()
      if action == "confirm" {
        try #require(try await waitForKeyUI { browser.transfers.count == 1 })
        let recovered = try #require(browser.transfers.first)
        #expect(!recovered.manifest.overwriteExisting)
        #expect(
          recovered.manifest.remoteTemporaryPath != manifest.remoteTemporaryPath
        )
        #expect(recovered.state != .running)
      } else {
        if action == "account" {
          try #require(try await waitForKeyUI { browser.message != nil })
        } else {
          try #require(
            try await waitForKeyUI {
              actionElement("sftp.confirmRecovery") == nil
            }
          )
        }
        #expect(browser.transfers.isEmpty)
        #expect(store.loadAll() == [manifest])
      }
      #expect(connections == 1)
    } catch {
      await browser.shutdown().value
      throw error
    }
    await browser.shutdown().value
  }
}
#endif
