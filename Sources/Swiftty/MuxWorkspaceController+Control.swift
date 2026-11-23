import AppKit
import MuxNavigation
import SwiftMuxClient
import SwiftMuxProtocol

extension MuxWorkspaceController {
  /// Shows the control bar over a window that just lost control and
  /// names who has it now, when the service still answers.
  func showControlBar(reason: String) {
    guard !isClosed else { return }
    controlBar.message = MuxTakeControl.message(reason: reason)
    controlBar.isHidden = false
    refreshControlHolder()
  }

  /// An observer window: the bar, kept current as control moves.
  func startWatchingControl() {
    controlBar.message = MuxTakeControl.message(
      reason: MuxTakeControl.takenOverReason
    )
    controlBar.isHidden = false
    command(.observeWorkspaces(true))
    refreshControlHolder()
  }

  /// Lists the workspaces once to name the current holder.
  func refreshControlHolder() {
    let connection = connection
    Task { [weak self] in
      guard
        case let .workspaces(list) = try? await connection.execute(
          .listWorkspaces,
          timeout: .seconds(5)
        )
      else { return }
      self?.controlHolderChanged(list)
    }
  }

  /// Names the holder in the bar of a window that does not control.
  func controlHolderChanged(_ list: [WorkspaceSummary]) {
    guard !holdsLease, !isClosed, !controlBar.isHidden,
      let id = attachedWorkspace ?? workspace?.id,
      let summary = list.first(where: { $0.id == id })
    else { return }
    controlBar.message = MuxTakeControl.message(for: summary)
  }

  /// Replaces this window, just taken over, with one that observes the
  /// workspace live in its place. Typing there takes control back. When
  /// observing is refused (observer limit, older service), this window
  /// stays with its last frames.
  func startObserving() {
    guard !isClosed, !startingObserver,
      let wsID = attachedWorkspace ?? workspace?.id
    else { return }
    startingObserver = true
    Task { [weak self] in
      guard let self else { return }
      let observer = await openObserver(wsID)
      startingObserver = false
      let wanted = controlRequestedWhileObserving
      controlRequestedWhileObserving = false
      guard let observer else {
        if wanted { requestControl() }
        return
      }
      // Input typed meanwhile asks the observer instead.
      observer.controlReplays = controlReplays
      controlReplays.removeAll()
      if wanted { observer.requestControl() }
    }
  }

  private func openObserver(
    _ wsID: WorkspaceID
  ) async -> MuxWorkspaceController? {
    let frame = window?.frame
    let visible = window?.isVisible == true
    let replaced = onReplaced
    do {
      let connection: MuxConnection
      if let gateway {
        connection = try await connectionAttempts.connect {
          try await gateway.openWorkspace(
            .id(wsID),
            role: .observer,
            capabilities: Self.clientCapabilities
          )
          .connection
        }
      } else {
        connection = try await connectionAttempts.connect(connectService)
      }
      let observer = try await Self.replace(
        self,
        with: .id(wsID),
        configuration: config,
        connection: connection,
        role: .observer
      )
      observer.connectService = connectService
      observer.decideTakeControl = decideTakeControl
      observer.confirmDestructive = confirmDestructive
      observer.onReplaced = replaced
      if let frame { observer.window?.setFrame(frame, display: false) }
      replaced?(observer)
      if visible { observer.window?.orderFront(nil) }
      return observer
    } catch { return nil }
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
    if startingObserver {
      controlRequestedWhileObserving = true
      return
    }
    guard !requestingControl else { return }
    guard let pane = activePane ?? workspace?.panes.first?.id else {
      controlReplays.removeAll()
      return
    }
    requestingControl = true
    reattach(PaneTarget(workspace: wsID, tab: activeTab?.id, pane: pane)) {
      [weak self] replacement in
      guard let self else { return }
      let replays = controlReplays
      controlReplays.removeAll()
      requestingControl = false
      guard let replacement, replacement.holdsLease else { return }
      for replay in replays { replay(replacement) }
    }
  }

  /// Asks before displacing a holder in use: in the control bar when this
  /// window shows one, otherwise in a sheet.
  func askTakeover(
    _ message: String,
    holder: String,
    declined: @escaping @MainActor () -> Void,
    confirmed: @escaping @MainActor () -> Void
  ) {
    let detail =
      "It is in use on \(holder). Taking over disconnects it there; its programs keep running."
    guard confirmDestructive == nil, !holdsLease, !controlBar.isHidden,
      !isClosed
    else {
      return confirmThen(
        true,
        message,
        detail,
        button: "Take Over",
        declined: declined,
        confirmed
      )
    }
    controlBar.ask(
      "\(message) It is in use on \(holder).",
      confirm: { [weak self] in
        guard let self, !isClosed else { return declined() }
        confirmed()
      },
      decline: declined
    )
  }
}
