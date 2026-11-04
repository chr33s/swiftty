#if os(macOS)
import AppKit
import Foundation
@testable import RoamingApp
import SwiftUI
import Testing

extension MainActorIntegrationTests.IdentityAccountBoundaryTests {
  func keyElement(_ id: String, in root: NSObject) -> NSObject? {
    // SwiftUI nodes implement the selectors without declaring protocol conformance.
    if (root as AnyObject).accessibilityIdentifier?() == id { return root }
    for child in (root as AnyObject).accessibilityChildren?()
      ?? legacyAccessibilityValue(root, .children) as? [Any] ?? []
    {
      if let child = child as? NSObject, let found = keyElement(id, in: child) {
        return found
      }
    }
    return nil
  }

  func waitForKeyUI(_ condition: () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition() {
      guard ContinuousClock.now < deadline else { return false }
      try await Task.sleep(for: .milliseconds(5))
    }
    return true
  }

  @Test
  func olderIdentityIsRestoredThroughTheActualSettingsAction() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = NSApplication.shared
    let secrets = SuspendedIdentitySecrets()
    let (model, original) = try await olderUnscopedIdentity(secrets: secrets)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    defer {
      window.contentView = nil;
      window.close()
    }
    window.contentView = NSHostingView(
      rootView: NavigationStack { SSHKeysView(model: model) }
    )
    window.makeKeyAndOrderFront(nil)
    let restoreEnhancedUI = enableEnhancedUserInterface()
    defer { restoreEnhancedUI() }
    let identifier = "keys.restoreAccount.\(original.id)"
    try #require(
      try await waitForKeyUI { keyElement(identifier, in: window) != nil }
    )
    #expect(model.identities.isEmpty)
    let button = try #require(keyElement(identifier, in: window))
    #expect((button as AnyObject).accessibilityPerformPress?() == true)
    try #require(try await waitForKeyUI { model.keyAccountReviews.isEmpty })
    #expect(model.identities == [original])
    #expect(!model.connections.settings.metadataSync)
    #expect(await defaultCloud.saveCount == 0)
  }

  @Test(arguments: [false, true])
  func legacyRemovalSheetReportsTheActualOutcome(pending: Bool) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = NSApplication.shared
    let secrets = SuspendedIdentitySecrets()
    let model = app(secrets: secrets)
    let intent = try await legacyDeletion(in: model, secrets: secrets)
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
      rootView: NavigationStack { SSHKeysView(model: model) }
    )
    window.makeKeyAndOrderFront(nil)
    let restoreEnhancedUI = enableEnhancedUserInterface()
    defer { restoreEnhancedUI() }
    let buttonID = "keys.reviewRemoval.\(intent.id)"
    try #require(
      try await waitForKeyUI { keyElement(buttonID, in: window) != nil }
    )
    let reviewButton = try #require(keyElement(buttonID, in: window))
    #expect((reviewButton as AnyObject).accessibilityPerformPress?() == true)
    try #require(try await waitForKeyUI { window.attachedSheet != nil })
    let sheet = try #require(window.attachedSheet)
    try #require(
      try await waitForKeyUI {
        keyElement("keys.confirmRemoval", in: sheet) != nil
      }
    )
    #expect(keyElement("keys.removalFingerprint", in: sheet) != nil)
    #expect(model.connections.intents == [intent])
    if pending { await secrets.failNextDeletion(.protectedDataUnavailable) }
    let confirm = try #require(keyElement("keys.confirmRemoval", in: sheet))
    #expect((confirm as AnyObject).accessibilityPerformPress?() == true)
    if pending {
      try #require(
        try await waitForKeyUI {
          keyElement("keys.removalPending", in: sheet) != nil
        }
      )
      #expect(window.attachedSheet === sheet)
      #expect(keyElement("keys.confirmRemoval", in: sheet) == nil)
      #expect(
        try await secrets.storedIdentities(policy: .iCloudKeychain) == [
          intent.identityID
        ]
      )
    } else {
      try #require(try await waitForKeyUI { window.attachedSheet == nil })
      #expect(model.connections.intents.isEmpty)
      #expect(
        try await secrets.storedIdentities(policy: .iCloudKeychain).isEmpty
      )
    }
    #expect(model.keyDeletionReviews.isEmpty)
  }
}
#endif
