import AppKit
import SwiftMuxProtocol
import SwifttyJS
import UserNotifications

extension MuxWorkspaceController {
  func handleAutomation(_ data: Data) {
    guard data.count <= 64 << 10,
      let action = try? JSONDecoder().decode(JavaScriptAction.self, from: data)
    else { return }
    switch action.kind {
    case .badge:
      NSApp.dockTile.badgeLabel = action.text.flatMap { $0.isEmpty ? nil : $0 }
    case .status:
      if let status = action.status { automationStatus.update(status) }
    case .tabIcon:
      guard let raw = action.id, let tab = TabID(raw)
      else { return }
      // Subscription replay includes tabs in workspaces we may show later.
      automationTabIcons[tab] = action.text
      refreshChrome()
    case .notification:
      automationNotify(action.title ?? "Swiftty", action.text ?? "")
    case .keybinding:
      if let shortcut = action.text { automationKeys.insert(shortcut) }
    default: break
    }
  }

  func handleAutomationKey(_ event: NSEvent, pane: PaneID) -> Bool {
    guard holdsLease, features.contains(.javaScript),
      let shortcut = Self.automationShortcut(event),
      automationKeys.contains(shortcut)
    else { return false }
    command(.automationKey(pane: pane, shortcut: shortcut))
    return true
  }

  static func automationShortcut(_ event: NSEvent) -> String? {
    guard var key = event.charactersIgnoringModifiers?.lowercased(),
      !key.isEmpty
    else { return nil }
    let special = [
      "\r": "enter", "\t": "tab", " ": "space", "\u{1b}": "escape",
      "\u{7f}": "backspace", "\u{f700}": "up", "\u{f701}": "down",
      "\u{f702}": "left", "\u{f703}": "right",
    ]
    key = special[key] ?? key
    var parts = [key]
    for (flag, name): (NSEvent.ModifierFlags, String) in [
      (.command, "cmd"), (.control, "ctrl"), (.option, "alt"),
      (.shift, "shift"),
    ] { if event.modifierFlags.contains(flag) { parts.append(name) } }
    return parts.sorted().joined(separator: "+")
  }

  func updateAutomationFocus() {
    guard holdsLease, features.contains(.javaScript),
      window?.isKeyWindow == true, let pane = activePane,
      pane != automationFocusedPane
    else { return }
    automationFocusedPane = pane
    command(.automationFocus(pane))
  }

  func windowDidBecomeKey(_ notification: Notification) {
    automationFocusedPane = nil
    updateAutomationFocus()
  }
}

@MainActor
enum JavaScriptNotifications {
  private static let delegate = JavaScriptNotificationDelegate()
  static func deliver(title: String, message: String) {
    // The development command-line executable has no notification identity.
    guard Bundle.main.bundleURL.pathExtension == "app" else {
      NSLog("Swiftty notification — %@: %@", title, message)
      return
    }
    Task {
      let center = UNUserNotificationCenter.current()
      center.delegate = delegate
      do {
        guard try await center.requestAuthorization(options: [.alert, .sound])
        else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        try await center.add(
          UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
          )
        )
      } catch { NSLog("Swiftty notification: %@", String(describing: error)) }
    }
  }
}

private final class JavaScriptNotificationDelegate: NSObject,
  UNUserNotificationCenterDelegate
{
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions { [.banner, .sound] }
}
