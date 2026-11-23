import AppKit
import MuxNavigation
import SwiftMuxClient
import SwiftMuxProtocol
import SwifttyCore

/// The attention inbox: its own metadata subscription (no lease, frames
/// or resize), the popover, and opening an item's pane.
extension MuxWorkspaceController {
  /// Subscribes to inbox metadata: no lease, frames or resize involved.
  func startInbox() {
    let connection = connection
    Task { [weak self] in
      do {
        _ = try await connection.execute(.subscribeInbox(true))
        await self?.reloadInbox()
      } catch { self?.inboxFailed(error, alert: false) }
    }
  }

  /// Rereads the first page of each section (after subscribing, a
  /// `resync` or a stale or missing item).
  func reloadInbox() async {
    let id = UUID()
    inboxReadID = id
    var pages: [InboxQuery.Section: InboxPage] = [:]
    for section in MuxInboxModel.sections {
      do {
        guard
          case let .inbox(page) = try await connection.execute(
            .inbox(InboxQuery(section: section, limit: inboxPageLimit))
          )
        else { throw MuxError(.invalidRequest, "unexpected inbox reply") }
        guard inboxReadID == id, !Task.isCancelled else { return }
        pages[section] = page
      } catch {
        guard inboxReadID == id, !Task.isCancelled else { return }
        inboxFailed(error, alert: false)
        return
      }
    }
    inbox.reset(pages)
    refreshInbox()
  }

  /// Reads the next page of every section that has one ("Load More").
  func loadMoreInbox() async {
    let id = UUID()
    inboxReadID = id
    var pages: [InboxQuery.Section: InboxPage] = [:]
    for section in MuxInboxModel.sections {
      guard let cursor = inbox.cursors[section] else { continue }
      do {
        guard
          case let .inbox(page) = try await connection.execute(
            .inbox(
              InboxQuery(
                section: section,
                cursor: cursor,
                limit: inboxPageLimit
              )
            )
          )
        else { throw MuxError(.invalidRequest, "unexpected inbox reply") }
        guard inboxReadID == id, !Task.isCancelled else { return }
        pages[section] = page
      } catch {
        guard inboxReadID == id, !Task.isCancelled else { return }
        // A cursor the service no longer accepts: start over.
        inboxFailed(error, alert: true)
        await reloadInbox()
        return
      }
    }
    guard inboxReadID == id, !Task.isCancelled else { return }
    for (section, page) in pages { inbox.append(page, section: section) }
    refreshInbox()
  }

  func refreshInbox() {
    workspaceToolbar.update(inbox.counts)
    if inboxPopover?.isShown == true { inboxView?.update(inbox) }
  }

  /// Reports a failed inbox command: inline while the popover is open,
  /// otherwise as an alert when `alert` (user-initiated commands).
  private func inboxFailed(_ error: any Error, alert: Bool) {
    inboxProblem(MuxInboxModel.describe(error), alert: alert)
  }

  private func inboxProblem(_ message: String, alert: Bool) {
    if isClosed {
      if !alert { inboxMessage = message }
      return
    }
    inboxMessage = message
    if inboxPopover?.isShown == true {
      inboxView?.show(message: message)
    } else if alert {
      notice(message)
    }
  }

  /// Checks a lookup reply: a stale or missing item is reported, dropped
  /// and the list reread. Returns the location while the item is there.
  private func checked(
    _ reply: MuxReply,
    _ item: AttentionItem,
    alert: Bool
  ) -> AttentionLocation? {
    guard case let .attention(location) = reply else {
      inboxFailed(MuxError(.invalidRequest, "unexpected reply"), alert: alert)
      return nil
    }
    if let problem = MuxInboxModel.describe(location.availability) {
      inbox.forget(item.occurrence)
      inboxProblem(problem, alert: alert)
      Task { [weak self] in await self?.reloadInbox() }
      return nil
    }
    return location
  }

  func toggleInbox() {
    if let popover = inboxPopover, popover.isShown {
      popover.performClose(nil)
      return
    }
    let view = inboxView ?? MuxInboxViewController()
    // A failure from while the popover was closed is shown once.
    view.show(message: inboxMessage)
    inboxMessage = nil
    view.onOpen = { [weak self] item in self?.openAttention(item) }
    view.onReview = { [weak self] item in self?.markReviewed(item) }
    view.onSnooze = { [weak self] item, until in
      self?.snooze(item, until: until)
    }
    view.onLoadMore = { [weak self] in Task { await self?.loadMoreInbox() } }
    // Showing an item marks it seen; it never resolves it.
    view.onShown = { [weak self] items in
      for item in items where !item.seen { self?.markSeen(item) }
    }
    inboxView = view
    let popover = inboxPopover ?? NSPopover()
    popover.behavior = .transient
    popover.contentViewController = view
    inboxPopover = popover
    view.update(inbox)
    // Tabs on the left keep the inbox over the sidebar; on top, in the
    // toolbar's trailing corner.
    let button = workspaceToolbar.sidebarControls.inboxButton
    if tabPosition == .left, button.window != nil {
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
      return
    }
    let content = workspaceContent
    popover.show(
      relativeTo: NSRect(
        x: content.bounds.maxX - 40,
        y: content.bounds.maxY - 2,
        width: 1,
        height: 1
      ),
      of: content,
      preferredEdge: .minY
    )
  }

  private func reference(_ item: AttentionItem) -> AttentionReference {
    AttentionReference(source: item.source, occurrence: item.occurrence)
  }

  /// Runs one inbox command against `item`, reporting failures and
  /// stale or missing items.
  private func attention(
    _ command: MuxCommand,
    _ item: AttentionItem,
    alert: Bool,
    then: (@MainActor (AttentionLocation) -> Void)? = nil
  ) {
    let connection = connection
    Task { [weak self] in
      do {
        let reply = try await connection.execute(command)
        guard let self, !isClosed,
          let location = checked(reply, item, alert: alert)
        else { return }
        then?(location)
      } catch { if let self, !isClosed { inboxFailed(error, alert: alert) } }
    }
  }

  private func markSeen(_ item: AttentionItem) {
    attention(.markSeen(reference(item)), item, alert: false)
  }

  func markReviewed(_ item: AttentionItem) {
    guard item.category != .needsYou else { return }
    attention(.markReviewed(reference(item)), item, alert: true)
  }

  /// Snoozes a waiting request until `until`, or clears its snooze.
  func snooze(_ item: AttentionItem, until: Date?) {
    guard MuxInboxModel.canSnooze(item) else { return }
    attention(.snooze(reference(item), until: until), item, alert: true)
  }

  /// Opens the item's pane: marks it seen, then reveals the pane in this
  /// workspace. Another workspace is switched to, and one controlled
  /// elsewhere is taken over only after explicit confirmation.
  func openAttention(_ item: AttentionItem) {
    attention(.markSeen(reference(item)), item, alert: true) {
      [weak self] location in self?.reveal(location)
    }
  }

  private func reveal(_ location: AttentionLocation) {
    guard let wsID = location.workspace, let pane = location.pane else {
      inboxProblem("This item is no longer available.", alert: true)
      return
    }
    inboxPopover?.performClose(nil)
    guard holdsLease else {
      // Detached (another frontend took over): no commands without a
      // lease; reattach like an attention link instead.
      reattach(PaneTarget(workspace: wsID, tab: location.tab, pane: pane))
      return
    }
    if wsID == workspace?.id {
      guard workspace?.pane(pane) != nil else {
        notice("That pane is no longer open.")
        return
      }
      if pane != activePane { command(.focusPane(pane)) }
      return
    }
    let takeOver: @MainActor (UInt64) -> Void = { [weak self] lease in
      self?.takeOver(wsID, pane: pane, lease: lease)
    }
    guard location.leaseHeldElsewhere else {
      command(
        .switchWorkspace(.id(wsID)),
        failed: { [weak self] error in
          // Another frontend attached in between: ask before taking over.
          if (error as? MuxError)?.code == .leaseHeld {
            self?.confirmTakeover(wsID, moved: false, take: takeOver)
          } else {
            self?.inboxFailed(error, alert: true)
          }
        },
        then: { [weak self] in self?.focusRevealed(pane) }
      )
      return
    }
    confirmTakeover(wsID, moved: false, take: takeOver)
  }

  /// Takes over `wsID` on this connection at lease generation `lease`.
  private func takeOver(_ wsID: WorkspaceID, pane: PaneID, lease: UInt64) {
    command(
      .takeover(.id(wsID), expectedLease: lease),
      failed: { [weak self] error in
        if (error as? MuxError)?.code == .staleRevision {
          self?
            .confirmTakeover(wsID, moved: true) { [weak self] lease in
              self?.takeOver(wsID, pane: pane, lease: lease)
            }
        } else {
          self?.inboxFailed(error, alert: true)
        }
      },
      then: { [weak self] in self?.focusRevealed(pane) }
    )
  }

  /// Shows `target` in a new window on a new connection, replacing this
  /// one that lost its lease (`MuxWorkspaceController.reveal`) in its
  /// place. A workspace held elsewhere is taken over silently or after
  /// confirmation (`MuxTakeControl.decide`). `done` receives the window
  /// that took control, or nil when declined or failed.
  func reattach(
    _ target: PaneTarget,
    takeover lease: UInt64? = nil,
    done: @escaping @MainActor (MuxWorkspaceController?) -> Void = { _ in }
  ) {
    Task { [weak self] in
      guard let self else { return done(nil) }
      let frame = window?.frame
      var replacement: MuxWorkspaceController?
      do {
        let shown = try await Self.reveal(
          target,
          in: self,
          configuration: config,
          connect: connectService,
          takeover: lease
        ) { controller in
          replacement = controller
          if let frame { controller.window?.setFrame(frame, display: false) }
          controller.connectService = self.connectService
          controller.decideTakeControl = self.decideTakeControl
          controller.onReplaced = self.onReplaced
          self.onReplaced?(controller)
        }
        done(shown)
      } catch is CancellationError { done(nil) } catch let error as MuxError
        where replacement == nil && !isClosed
        && (error.code == .leaseHeld || error.code == .staleRevision)
      {
        confirmTakeover(
          target.workspace,
          moved: lease != nil,
          declined: { done(nil) }
        ) { [weak self] lease in
          guard let self else { return done(nil) }
          reattach(target, takeover: lease, done: done)
        }
      } catch {
        let recipient = replacement ?? self
        if !recipient.isClosed { recipient.inboxFailed(error, alert: true) }
        done(replacement)
      }
    }
  }

  /// Focuses `pane` after a switch or takeover, reporting a pane that
  /// ended in the meantime.
  private func focusRevealed(_ pane: PaneID) {
    command(
      .focusPane(pane),
      failed: { [weak self] error in self?.inboxFailed(error, alert: true) }
    )
  }

  /// Takes over `wsID` at the lease generation listed now, asking first
  /// unless `MuxTakeControl.decide` allows it silently, then calls `take`
  /// with it. If the lease moves meanwhile, the takeover fails
  /// `staleRevision` and `take`'s caller decides again.
  func confirmTakeover(
    _ wsID: WorkspaceID,
    moved: Bool,
    declined: @escaping @MainActor () -> Void = {},
    take: @escaping @MainActor (UInt64) -> Void
  ) {
    let connection = connection
    Task { [weak self] in
      let summary: WorkspaceSummary
      do {
        guard
          case let .workspaces(list) = try await connection.execute(
            .listWorkspaces,
            timeout: .seconds(5)
          )
        else {
          throw MuxError(.invalidRequest, "unexpected workspace-list reply")
        }
        guard let found = list.first(where: { $0.id == wsID }) else {
          throw MuxError(.notFound)
        }
        summary = found
      } catch {
        if let self, !isClosed { inboxFailed(error, alert: true) }
        return declined()
      }
      guard let self, !isClosed else { return declined() }
      let decision = decideTakeControl(summary)
      guard case .ask = decision else { return take(decision.generation) }
      let name = DisplayText.workspaceName(summary.name)
      let holder = MuxTakeControl.describe(summary.leaseHolder)
      confirmThen(
        true,
        moved
          ? "Control of workspace “\(name)” changed while you were deciding. Take control now?"
          : "Take control of workspace “\(name)”?",
        "It is in use on \(holder). Taking over disconnects it there; its programs keep running.",
        button: "Take Over",
        declined: declined
      ) { take(decision.generation) }
    }
  }
}
