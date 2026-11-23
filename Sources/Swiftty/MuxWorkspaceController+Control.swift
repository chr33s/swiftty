import AppKit
import MuxNavigation
import SwiftMuxProtocol

extension MuxWorkspaceController {
  /// Shows the control bar over a window that just lost control.
  func showControlBar(reason: String) {
    guard !isClosed else { return }
    controlBar.message = MuxTakeControl.message(reason: reason)
    controlBar.isHidden = false
  }

  /// Takes control back for this window that lost it, then runs
  /// `replay` (the input that asked) in the window that got it. Called
  /// by typing, pasting or the control bar; never on focus alone. While
  /// asking, further input queues; a declined or failed request drops it.
  func requestControl(
    replay: (@MainActor (MuxWorkspaceController) -> Void)? = nil
  ) {
    guard !holdsLease, !isClosed, gatewayRecovery == nil,
      let wsID = attachedWorkspace ?? workspace?.id
    else { return }
    if let replay, controlReplays.count < Self.maxControlReplays {
      controlReplays.append(replay)
    }
    guard !requestingControl else { return }
    guard let pane = activePane ?? workspace?.panes.first?.id else {
      controlReplays.removeAll()
      return
    }
    requestingControl = true
    reattach(
      PaneTarget(workspace: wsID, tab: activeTab?.id, pane: pane)
    ) { [weak self] replacement in
      guard let self else { return }
      let replays = controlReplays
      controlReplays.removeAll()
      requestingControl = false
      guard let replacement, replacement.holdsLease else { return }
      for replay in replays { replay(replacement) }
    }
  }
}
