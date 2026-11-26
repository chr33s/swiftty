import AppKit
import SwiftMuxProtocol

/// Workspace menu commands. They travel the responder chain, so each
/// reaches the focused window's controller (the window's delegate), never
/// another workspace; a text field or field editor that handles a
/// selector itself keeps it.
extension MuxWorkspaceController {
  @objc
  func newTerminalTab(_ sender: Any?) { newTab() }

  @objc
  func splitRight(_ sender: Any?) { split(.leftRight) }

  @objc
  func splitDown(_ sender: Any?) { split(.topBottom) }

  @objc
  func toggleZoomPane(_ sender: Any?) { toggleZoom() }

  @objc
  func endActivePane(_ sender: Any?) { endPane() }

  @objc
  func endActiveTab(_ sender: Any?) { closeTab() }

  @objc
  func endCurrentWorkspace(_ sender: Any?) { endWorkspace() }

  @objc
  func renameActiveTab(_ sender: Any?) { beginRenamingActiveTab() }

  @objc
  func renameCurrentWorkspace(_ sender: Any?) { beginRenamingWorkspace() }

  /// Shows the active pane's saved output, read-only (§12.2.8).
  @objc
  func showPreviousOutput(_ sender: Any?) {
    guard let gateway, let id = attachedWorkspace, let pane = activePane else {
      return
    }
    let font = NSFont.monospacedSystemFont(
      ofSize: CGFloat(config.fontSize),
      weight: .regular
    )
    let title = "Previous Output — \(window?.title ?? "")"
    Task { @MainActor [weak self] in
      do {
        let output = try await gateway.previousOutput(id, pane: pane)
        let viewer = SavedOutputViewer(output: output, title: title, font: font)
        self?.previousOutputViewers.append(viewer)
        viewer.showWindow(nil)
      } catch {
        let alert = NSAlert(error: error)
        alert.messageText = "No previous output for this pane"
        alert.runModal()
      }
    }
  }

  @objc
  func discardPreviousOutput(_ sender: Any?) {
    guard let gateway, let id = attachedWorkspace else { return }
    offersPreviousOutput = false
    for viewer in previousOutputViewers { viewer.close() }
    previousOutputViewers.removeAll()
    Task { try? await gateway.discardPreviousOutput(id, pane: nil) }
  }

  @objc
  func selectNextTab(_ sender: Any?) { cycleTab(1) }

  @objc
  func selectPreviousTab(_ sender: Any?) { cycleTab(-1) }

  /// Focus and resize items carry their direction in the tag.
  @objc
  func focusPaneInDirection(_ sender: NSMenuItem) {
    Self.direction(sender.tag).map { focus($0) }
  }

  @objc
  func resizePaneInDirection(_ sender: NSMenuItem) {
    Self.direction(sender.tag).map { resizeActivePane($0) }
  }

  static let directions: [Direction] = [.left, .right, .up, .down]

  static func direction(_ tag: Int) -> Direction? {
    directions.indices.contains(tag) ? directions[tag] : nil
  }

  @objc
  func increaseFontSize(_ sender: Any?) { adjustFontSize(by: 1) }

  @objc
  func decreaseFontSize(_ sender: Any?) { adjustFontSize(by: -1) }

  @objc
  func resetFontSize(_ sender: Any?) { setFontSize(nil) }

  /// Commands need this window's lease (a detached window offers none)
  /// and the target they name.
  @objc
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(increaseFontSize(_:)), #selector(decreaseFontSize(_:)),
      #selector(resetFontSize(_:)):
      return !isClosed
    default: break
    }
    guard holdsLease, let ws = workspace, let tab = activeTab else {
      return false
    }
    switch item.action {
    case #selector(showPreviousOutput(_:)),
      #selector(discardPreviousOutput(_:)):
      return offersPreviousOutput && gateway != nil
    case #selector(selectNextTab(_:)), #selector(selectPreviousTab(_:)):
      return ws.tabs.count > 1
    case #selector(focusPaneInDirection(_:)):
      return tab.zoomedPane == nil && tab.visiblePanes.count > 1
    case #selector(resizePaneInDirection(_:)):
      return (tab.tree(containing: tab.activePane)?.panes.count ?? 0) > 1
    case #selector(floatActivePane(_:)):
      return features.contains(.floatingLayers)
        && tab.layer(containing: tab.activePane) == nil
    case #selector(dockActivePane(_:)), #selector(closeActiveLayer(_:)):
      return features.contains(.floatingLayers)
        && tab.layer(containing: tab.activePane) != nil
    case #selector(minimizeActiveLayer(_:)):
      guard features.contains(.floatingLayers),
        let layer = tab.layer(containing: tab.activePane)
      else { return false }
      return tab.canMinimize(layer)
    case #selector(splitRight(_:)), #selector(splitDown(_:)),
      #selector(toggleZoomPane(_:)), #selector(endActivePane(_:)):
      return ws.pane(tab.activePane) != nil
    default: return true
    }
  }

}
