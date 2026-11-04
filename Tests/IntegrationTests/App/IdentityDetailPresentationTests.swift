#if os(macOS)
import AppKit
import Foundation
@testable import RoamingApp
import SSHIdentity
import SwiftUI
import Testing

extension MainActorIntegrationTests.IdentityAccountBoundaryTests {
  private func withKeyDetail(
    _ model: RoamingAppModel,
    id: UUID,
    body: (NSWindow) async throws -> Void
  ) async throws {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    defer {
      if let sheet = window.attachedSheet {
        window.endSheet(sheet)
        sheet.orderOut(nil)
      }
      window.contentView = nil
      window.close()
    }
    window.contentView = NSHostingView(
      rootView: NavigationStack { SSHKeyDetailView(model: model, id: id) }
    )
    window.makeKeyAndOrderFront(nil)
    let restoreEnhancedUI = enableEnhancedUserInterface()
    defer { restoreEnhancedUI() }
    try await body(window)
  }

  private func detailNameField(in window: NSWindow) async throws -> NSTextField
  {
    try #require(
      try await waitForKeyUI { keyElement("key.name", in: window) != nil }
    )
    let element = try #require(keyElement("key.name", in: window))
    return try #require(
      (element as? NSTextField) ?? (element as? NSCell)?.controlView
        as? NSTextField
    )
  }

  private func typeName(_ name: String, in field: NSTextField) throws {
    // Drive the hosted control's text-change callback without requiring the
    // test application to own global keyboard focus.
    let delegate = try #require(field.delegate)
    try #require(
      delegate.responds(
        to: #selector(NSTextFieldDelegate.controlTextDidChange(_:))
      )
    )
    field.stringValue = name
    delegate.controlTextDidChange?(
      Notification(name: NSControl.textDidChangeNotification, object: field)
    )
  }

  @Test(arguments: [
    "unchanged", "collision", "hidden", "roundTrip", "metadata", "notification",
  ])
  func openKeyDetailRejectsStaleNameSubmission(change: String) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = app(secrets: InMemoryIdentitySecretStore())
    await select("account-a", in: model)
    let original = try await model.identityStore.generate(
      name: "Account A",
      policy: .deviceOnly
    )
    try await withKeyDetail(model, id: original.id) { window in
      let field = try await detailNameField(in: window)
      try #require(
        try await waitForKeyUI { field.stringValue == original.name }
      )
      try typeName("Draft A", in: field)
      let action = try #require(field.action)
      let target = try #require(field.target)
      var expected = original.name
      switch change {
      case "unchanged": expected = "Draft A"
      case "notification": model.identityStore.accountDidChange()
      case "metadata":
        try model.identityStore.rename(original.id, to: "Remote edit")
        expected = "Remote edit"
      default:
        await select("account-b", in: model)
        if change == "collision" {
          let replacement = SSHIdentityMetadata(
            id: original.id,
            name: "Account B",
            publicKey: IdentitySecret(.init()).publicKey,
            storage: .deviceOnly,
            revision: LogicalRevision(counter: 100, deviceID: UUID())
          )
          #expect(
            model.commitConnections {
              $0.activateRecord(
                ConnectionSnapshot.identityRecord(original.id),
                for: "account-b"
              )
              $0.insertIdentity(replacement)
            }
          )
          expected = replacement.name
        } else if change == "roundTrip" {
          await select("account-a", in: model)
        }
      }
      // Keep the old callback: even before SwiftUI redraws, it cannot retarget.
      #expect(NSApp.sendAction(action, to: target, from: field))
      #expect(model.identity(original.id)?.name == expected)
      if change == "unchanged" {
        try typeName("Second edit", in: field)
        #expect(NSApp.sendAction(action, to: target, from: field))
        #expect(model.identity(original.id)?.name == "Second edit")
      } else {
        try #require(
          try await waitForKeyUI {
            keyElement("key.detailUnavailable", in: window) != nil
          }
        )
        #expect(keyElement("key.name", in: window) == nil)
        if change == "collision" || change == "hidden" {
          await select("account-a", in: model)
          #expect(model.identity(original.id)?.name == original.name)
          #expect(keyElement("key.name", in: window) == nil)
        }
      }
    }
  }

  @Test(arguments: [false, true])
  func keyDeletionConfirmationStaysWithTheReviewedAccount(
    changeAccount: Bool
  ) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = InMemoryIdentitySecretStore()
    let model = app(secrets: secrets)
    await select("account-a", in: model)
    let original = try await model.identityStore.generate(
      name: "Account A",
      policy: .deviceOnly
    )
    try await withKeyDetail(model, id: original.id) { window in
      try #require(
        try await waitForKeyUI { keyElement("key.delete", in: window) != nil }
      )
      let button = try #require(keyElement("key.delete", in: window))
      #expect((button as AnyObject).accessibilityPerformPress?() == true)
      try #require(try await waitForKeyUI { window.attachedSheet != nil })
      let sheet = try #require(window.attachedSheet)
      try #require(
        try await waitForKeyUI {
          keyElement("key.confirmDelete", in: sheet) != nil
        }
      )
      let confirm = try #require(keyElement("key.confirmDelete", in: sheet))
      let confirmButton = try #require(
        (confirm as? NSButton) ?? (confirm as? NSCell)?.controlView as? NSButton
      )
      if changeAccount {
        await select("account-b", in: model)
        var replacement = original
        replacement.name = "Account B"
        #expect(
          model.commitConnections {
            $0.activateRecord(
              ConnectionSnapshot.identityRecord(original.id),
              for: "account-b"
            )
            $0.insertIdentity(replacement)
          }
        )
      }
      confirmButton.performClick(nil)
      try #require(try await waitForKeyUI { window.attachedSheet == nil })
      try #require(
        try await waitForKeyUI {
          keyElement("key.detailUnavailable", in: window) != nil
        }
      )
      #expect(model.identity(original.id)?.isDeleted == !changeAccount)
      await model.identityStore.recover()
      #expect(model.identity(original.id)?.isDeleted == !changeAccount)
      #expect(
        try await secrets.storedIdentities(policy: .deviceOnly)
          .contains(original.id) == changeAccount
      )
    }
  }
}
#endif
