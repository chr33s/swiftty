#if os(macOS)
import AppKit
import Foundation
@testable import RoamingApp
import SessionCore
import SwiftUI
import Testing

@MainActor
private final class WorkspaceMenuCapture: NSObject {
  var item: NSMenuItem?
  private var trackingMenu: NSMenu?
  @objc
  func beganTracking(_ notification: Notification) {
    guard let menu = notification.object as? NSMenu else { return }
    item = menu.items.first { $0.title.contains("Resume Last Workspace") }
    trackingMenu = menu
    // Showing a context menu synchronously enters AppKit's tracking loop;
    // a main-queue block cannot run until that call returns.
    RunLoop.main.perform(inModes: [.eventTracking]) { [self] in
      MainActor.assumeIsolated {
        trackingMenu?.cancelTracking()
        trackingMenu = nil
      }
    }
  }
}

extension MainActorIntegrationTests.IdentityAccountBoundaryTests {
  @Test(arguments: ["unchanged", "newChoice", "forgotten", "account"])
  func retainedResumeMenuUsesItsDisplayedWorkspace(change: String) async throws
  {
    let suite = "resume-menu-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    let model = resumeApp(defaults)
    await select("account-a", in: model)
    let host = HostProfile(nickname: "A", host: "a.local", username: "me")
    #expect(try model.save(host))
    let selection = model.connectionSelection(for: host)
    let displayedWorkspace = SessionID.random()
    model.rememberSession(displayedWorkspace, for: selection)
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    defer {
      model.close()
      window.contentView = nil
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
    let row = try #require(keyElement(identifier, in: window))
    let displayed = WorkspaceMenuCapture()
    NotificationCenter.default.addObserver(
      displayed,
      selector: #selector(WorkspaceMenuCapture.beganTracking(_:)),
      name: NSMenu.didBeginTrackingNotification,
      object: nil
    )
    defer { NotificationCenter.default.removeObserver(displayed) }
    _ = (row as AnyObject).accessibilityPerformShowMenu?()
    try #require(try await waitForKeyUI { displayed.item != nil })
    let item = try #require(displayed.item)
    #expect(item.title.contains(String(displayedWorkspace.hex.prefix(8))))
    let target = try #require(item.target)
    let action = try #require(item.action)
    switch change {
    case "newChoice": model.rememberSession(.random(), for: selection)
    case "forgotten": model.forgetSession(for: selection)
    case "account":
      _ = try await replaceResumeHost(host, change: "account", in: model)
    default: break
    }
    #expect(NSApp.sendAction(action, to: target, from: item))
    if change == "account" {
      #expect(model.activeSession == nil)
      #expect(model.lastError == RoamingAppModel.hostChangedMessage)
    } else {
      #expect(
        model.activeSession?.takeWorkspaceIntent()
          == .resume(displayedWorkspace, nil)
      )
      #expect(model.resumableSessionID(for: host) == displayedWorkspace)
    }
    #expect(model.pendingPassword == nil)
    #expect(model.pendingTrust == nil)
  }
}
#endif
