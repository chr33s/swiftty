import AppKit
import SwiftMuxProtocol
import SwifttyCore

// Terminal Service › Saved Workspaces… (spec.durability.md §12.2.2). The
// policy belongs to the gateway, not to this app's configuration file, so
// every app instance and `swmux` see the same settings.
extension AppDelegate {
  @objc
  func savedWorkspaces(_ sender: Any?) {
    guard let gateway = gatewayApplication else { return }
    Task { @MainActor in
      do {
        presentSavedSettings(try await gateway.savedWorkspaces(), gateway)
      } catch { NSAlert(error: error).runModal() }
    }
  }

  private func presentSavedSettings(
    _ list: SavedWorkspaceList,
    _ gateway: MuxGatewayApplication
  ) {
    let policy = list.policy
    let layout = NSButton(
      checkboxWithTitle: "Save workspace layouts",
      target: nil,
      action: nil
    )
    layout.state = policy.saveLayout ? .on : .off
    let output = NSButton(
      checkboxWithTitle: "Also save terminal output (main screen only)",
      target: nil,
      action: nil
    )
    output.state = policy.saveOutput ? .on : .off
    let reopen = NSPopUpButton(frame: .zero, pullsDown: false)
    let choices: [(SavedReopenAtLaunch, String)] = [
      (.ask, "Ask"), (.automatic, "Reopen automatically"),
      (.never, "Don't reopen"),
    ]
    for (_, title) in choices { reopen.addItem(withTitle: title) }
    reopen.selectItem(
      at: choices.firstIndex { $0.0 == policy.reopenAtLaunch } ?? 0
    )
    let retention = NSTextField(string: "\(policy.retentionDays)")
    retention.frame.size.width = 60
    let status: String
    switch list.store {
    case .available:
      let saved = list.workspaces.filter { $0.state == .saved }.count
      status = saved == 1 ? "1 saved layout." : "\(saved) saved layouts."
    case let .unavailable(reason):
      status = "Saved workspaces unavailable: \(DisplayText.sanitize(reason))."
    case .keyLost:
      status =
        "The saved layout key was missing, so earlier layouts were deleted."
    }
    let grid = NSGridView(views: [
      [layout, NSGridCell.emptyContentView],
      [output, NSGridCell.emptyContentView],
      [NSTextField(labelWithString: "When Swiftty opens:"), reopen],
      [NSTextField(labelWithString: "Keep saved layouts (days):"), retention],
    ])
    grid.frame = NSRect(x: 0, y: 0, width: 420, height: 120)
    let alert = NSAlert()
    alert.messageText = "Saved Workspaces"
    alert.informativeText =
      "\(status) Reopening starts new shells; earlier processes are not resumed. "
      + "A crash or power loss can lose up to 5 seconds of layout changes and "
      + "60 seconds of output. Saved data is encrypted with a key in your login "
      + "keychain; local snapshots can keep deleted files until they expire."
    alert.accessoryView = grid
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Delete Saved Workspaces…")
    alert.addButton(withTitle: "Cancel")
    switch alert.runModal() {
    case .alertFirstButtonReturn:
      var next = policy
      next.saveLayout = layout.state == .on
      next.saveOutput = next.saveLayout && output.state == .on
      next.reopenAtLaunch = choices[max(0, reopen.indexOfSelectedItem)].0
      next.retentionDays = min(max(1, retention.integerValue), 365)
      guard next != policy else { return }
      Task { @MainActor in
        do {
          _ = try await gateway.setSavedPolicy(
            next,
            expectedRevision: policy.revision
          )
        } catch { NSAlert(error: error).runModal() }
      }
    case .alertSecondButtonReturn:
      let confirm = NSAlert()
      confirm.messageText = "Delete all saved workspaces?"
      confirm.informativeText =
        "Saved layouts and their key are removed. Running workspaces are not affected."
      confirm.alertStyle = .warning
      confirm.addButton(withTitle: "Delete")
      confirm.addButton(withTitle: "Cancel")
      guard confirm.runModal() == .alertFirstButtonReturn else { return }
      Task { @MainActor in
        do { try await gateway.deleteSaved(nil) } catch {
          NSAlert(error: error).runModal()
        }
      }
    default: break
    }
  }
}
