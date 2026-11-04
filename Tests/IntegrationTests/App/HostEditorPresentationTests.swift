#if os(macOS)
import AppKit
import Foundation
@testable import RoamingApp
import SSHIdentity
import SwiftUI
import Testing

extension MainActorIntegrationTests.IdentityAccountBoundaryTests {
  @MainActor
  private final class DisplayedMenu: NSObject {
    var item: NSMenuItem?

    @objc
    func beganTracking(_ notification: Notification) {
      guard let menu = notification.object as? NSMenu else { return }
      item = menu.items.first { $0.title.contains("Update") }
      DispatchQueue.main.async { menu.cancelTracking() }
    }
  }

  private func replacementPicker(in view: NSView) -> NSPopUpButton? {
    if let picker = view as? NSPopUpButton,
      picker.itemArray.contains(where: { $0.title.contains("Update") })
    {
      return picker
    }
    for child in view.subviews {
      if let picker = replacementPicker(in: child) { return picker }
    }
    return nil
  }

  private func withHostEditor(
    _ model: RoamingAppModel,
    original: HostProfile?,
    candidate: HostCandidate? = nil,
    dismiss: @escaping () -> Void = {},
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
      window.contentView = nil;
      window.close()
    }
    window.contentView = NSHostingView(
      rootView: HostEditorView(
        model: model,
        host: original,
        candidate: candidate,
        dismiss: dismiss
      )
    )
    window.makeKeyAndOrderFront(nil)
    let restoreEnhancedUI = enableEnhancedUserInterface()
    defer { restoreEnhancedUI() }
    try await body(window)
  }

  @Test
  func retainedReplacementPickerChoiceDoesNotAdoptNewMetadata() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = app(secrets: InMemoryIdentitySecretStore())
    await select("account-a", in: model)
    var host = HostProfile(nickname: "A", host: "a.local", username: "me")
    #expect(try model.save(host))
    let candidate = HostCandidate(
      nearbyName: "Nearby",
      host: host.host,
      port: host.port
    )
    try await withHostEditor(model, original: nil, candidate: candidate) {
      window in
      try #require(
        try await waitForKeyUI {
          keyElement("host.replacement", in: window) != nil
        }
      )
      let element = try #require(keyElement("host.replacement", in: window))
      let content = try #require(window.contentView)
      let item: NSMenuItem
      if let picker = replacementPicker(in: content) {
        item = try #require(
          picker.itemArray.first { $0.title.contains("Update") }
        )
      } else {
        // Newer SwiftUI hosts expose a menu-backed accessibility element
        // instead of NSPopUpButton. Retain the displayed menu's actual action.
        let displayed = DisplayedMenu()
        NotificationCenter.default.addObserver(
          displayed,
          selector: #selector(DisplayedMenu.beganTracking(_:)),
          name: NSMenu.didBeginTrackingNotification,
          object: nil
        )
        defer { NotificationCenter.default.removeObserver(displayed) }
        _ = (element as AnyObject).accessibilityPerformPress?()
        try #require(try await waitForKeyUI { displayed.item != nil })
        item = try #require(displayed.item)
      }
      let action = try #require(item.action)
      let target = try #require(item.target)
      host.nickname = "Changed elsewhere"
      #expect(try model.save(host))
      // Select an option retained from before the update, without a UI turn.
      #expect(NSApp.sendAction(action, to: target, from: item))
      let connect = try #require(keyElement("host.connect", in: window))
      _ = (connect as AnyObject).accessibilityPerformPress?()
      #expect(model.lastError == RoamingAppModel.hostChangedMessage)
      #expect(model.hosts == [host])
      #expect(model.pendingTrust == nil)
      #expect(model.pendingPassword == nil)
    }
  }

  @Test(
    arguments: [
      "valid", "hidden", "collision", "identical", "roundTrip", "revision",
      "notification",
    ],
    [false, true]
  )
  func retainedHostEditorSaveRequiresTheReviewedContext(
    change: String,
    adding: Bool
  ) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = NSApplication.shared
    let model = app(secrets: InMemoryIdentitySecretStore())
    await select("account-a", in: model)
    let original = HostProfile(nickname: "A", host: "a.local", username: "me")
    if !adding { #expect(try model.save(original)) }
    var dismissed = false
    try await withHostEditor(
      model,
      original: adding ? nil : original,
      dismiss: { dismissed = true }
    ) { window in
      for (id, value) in [
        ("host.nickname", "Edited A"), ("host.address", original.host),
        ("host.username", original.username),
      ] {
        try #require(
          try await waitForKeyUI { keyElement(id, in: window) != nil }
        )
        let element = try #require(keyElement(id, in: window))
        let field = try #require(
          (element as? NSTextField) ?? (element as? NSCell)?.controlView
            as? NSTextField
        )
        let delegate = try #require(field.delegate)
        field.stringValue = value
        delegate.controlTextDidChange?(
          Notification(name: NSControl.textDidChangeNotification, object: field)
        )
      }
      let save = try #require(keyElement("host.save", in: window))
      switch change {
      case "valid": break
      case "notification": model.identityStore.accountDidChange()
      case "revision":
        if adding {
          // An unrelated record must not invalidate a new-host draft.
          #expect(try model.save(original))
        } else {
          var remote = original
          remote.nickname = "Remote"
          #expect(try model.save(remote))
        }
      default:
        await select("account-b", in: model)
        if change == "collision" || change == "identical" {
          var replacement = original
          if change == "collision" {
            replacement.nickname = "B";
            replacement.host = "b.local"
          }
          #expect(
            model.commitConnections {
              $0.activateRecord(
                ConnectionSnapshot.hostRecord(original.id),
                for: "account-b"
              )
              $0.upsertHost(replacement)
            }
          )
        } else if change == "roundTrip" {
          await select("account-a", in: model)
        }
      }
      let before = model.connections
      _ = (save as AnyObject).accessibilityPerformPress?()
      let allowed = change == "valid" || (adding && change == "revision")
      #expect(dismissed == allowed)
      if allowed {
        #expect(
          model.hosts.contains {
            $0.nickname == "Edited A" && $0.host == original.host
              && $0.username == original.username
          }
        )
      } else {
        #expect(model.connections == before)
        try #require(
          try await waitForKeyUI { keyElement("host.error", in: window) != nil }
        )
      }
    }
  }
}
#endif
