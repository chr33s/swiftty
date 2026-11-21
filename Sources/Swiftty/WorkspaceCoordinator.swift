import AppKit
import MuxNavigation
import SwiftMuxClient
import SwiftMuxProtocol
import SwifttyCore

/// The app's workspace windows: creates workspaces, opens existing ones
/// and reveals attention targets as distinct operations, and applies
/// app-wide configuration, update and Quit to every window.
///
/// Each window has its own connection and holds its workspace's lease;
/// SwiftMux stays authoritative for workspaces, layouts and processes, so
/// nothing here mirrors them. A window is found by the identity it holds
/// a lease on right now (service instance and workspace), never by name:
/// a window that lost its lease or connection matches nothing.
@MainActor
final class WorkspaceCoordinator {
  struct Key: Hashable {
    var server: ServerInstanceID
    var workspace: WorkspaceID
  }

  /// An operation in flight; a repeat of it joins the pending one.
  enum Intent: Hashable {
    case create
    case open(WorkspaceID)
  }

  typealias Open =
    @MainActor (WorkspaceSelector?, Configuration, UInt64?) async throws ->
    MuxWorkspaceController

  private(set) var controllers: [MuxWorkspaceController] = []
  var configuration: Configuration
  private let listWorkspaces: @MainActor () async throws -> WorkspaceListing
  private let openWorkspace: Open
  private let reportListError: @MainActor (any Error) -> Void
  private let reportOpenError: @MainActor (any Error) -> Void
  private let defaults: UserDefaults
  private var pending: [Intent: (id: UUID, task: Task<Void, Never>)] = [:]
  private var listing = false
  /// Set by Quit: late results are detached rather than shown.
  private var terminating = false

  /// The workspace last shown, offered again at launch.
  static let lastWorkspaceKey = "LastWorkspace"

  init(
    configuration: Configuration,
    listWorkspaces: @escaping @MainActor () async throws -> WorkspaceListing,
    openWorkspace: @escaping Open,
    reportListError: @escaping @MainActor (any Error) -> Void,
    reportOpenError: @escaping @MainActor (any Error) -> Void,
    defaults: UserDefaults = .standard
  ) {
    self.configuration = configuration
    self.listWorkspaces = listWorkspaces
    self.openWorkspace = openWorkspace
    self.reportListError = reportListError
    self.reportOpenError = reportOpenError
    self.defaults = defaults
  }

  // MARK: Registry

  func controller(for key: Key) -> MuxWorkspaceController? {
    controllers.first {
      $0.holdsLease && $0.server == key.server
        && $0.attachedWorkspace == key.workspace
    }
  }

  /// This app's window holding `workspace`'s lease on the local service.
  func controller(holding workspace: WorkspaceID) -> MuxWorkspaceController? {
    controllers.first { $0.holdsLease && $0.attachedWorkspace == workspace }
  }

  func isPending(_ intent: Intent) -> Bool { pending[intent] != nil }

  /// Registers a window shown by this app; it leaves the registry when it
  /// closes, and a window that replaces it (an inbox reattach) joins.
  func install(_ controller: MuxWorkspaceController) {
    guard !controllers.contains(where: { $0 === controller }) else { return }
    controllers.append(controller)
    controller.onClose = { [weak self, weak controller] in
      self?.controllers.removeAll { $0 === controller || $0.isClosed }
    }
    controller.onReplaced = { [weak self] replacement in
      self?.install(replacement)
    }
    remember(controller)
  }

  private func remember(_ controller: MuxWorkspaceController) {
    guard let id = controller.attachedWorkspace else { return }
    defaults.set(id.description, forKey: Self.lastWorkspaceKey)
  }

  var lastWorkspace: WorkspaceID? {
    defaults.string(forKey: Self.lastWorkspaceKey).flatMap(WorkspaceID.init)
  }

  // MARK: Create, open, reveal

  /// A new workspace with one shell, in its own window. A repeat while
  /// one is being created joins it; once shown, the next creates another.
  func create() { start(.create, selector: nil, takeover: nil) }

  /// Shows `workspace`: reveals this app's window holding it, otherwise
  /// attaches in a new window (taking it over only with a confirmed
  /// `lease`). Never creates a workspace or shell.
  func open(
    _ workspace: WorkspaceID,
    server: ServerInstanceID? = nil,
    takeover lease: UInt64? = nil
  ) {
    let existing =
      server.map { controller(for: Key(server: $0, workspace: workspace)) }
      ?? controller(holding: workspace)
    if let existing {
      existing.showWindow(nil)
      remember(existing)
      return
    }
    start(.open(workspace), selector: .id(workspace), takeover: lease)
  }

  private func start(
    _ intent: Intent,
    selector: WorkspaceSelector?,
    takeover lease: UInt64?
  ) {
    guard !terminating, pending[intent] == nil else { return }
    let id = UUID()
    let configuration = configuration
    let task = Task { [weak self] in
      guard let self else { return }
      // Cleared after any report, so a repeat during its alert joins.
      defer { if pending[intent]?.id == id { pending[intent] = nil } }
      do {
        let controller = try await openWorkspace(selector, configuration, lease)
        guard !terminating, !Task.isCancelled else {
          await controller.detach()
          controller.close()
          return
        }
        install(controller)
        controller.showWindow(nil)
      } catch is CancellationError {} catch {
        guard !terminating else { return }
        reportOpenError(error)
      }
    }
    pending[intent] = (id, task)
  }

  /// Shows `target` for an attention link. A window holding its workspace
  /// reveals it; a window that lost that workspace's lease is replaced
  /// once the target attaches; otherwise it opens in a new window. Other
  /// workspaces' windows are never detached.
  func reveal(
    _ target: PaneTarget,
    takeover lease: UInt64?,
    connect: @escaping @MainActor () async throws -> MuxConnection = {
      try await MuxWorkspaceController.connect()
    }
  ) async throws {
    guard !terminating else { throw CancellationError() }
    let current =
      controller(holding: target.workspace)
      ?? controllers.first {
        !$0.isClosed && $0.attachedWorkspace == target.workspace
      }
    _ = try await MuxWorkspaceController.reveal(
      target,
      in: current,
      configuration: configuration,
      connect: connect,
      takeover: lease,
      attached: { [weak self] controller in
        guard let self, !terminating else {
          Task {
            await controller.detach()
            controller.close()
          }
          return
        }
        install(controller)
      }
    )
  }

  // MARK: Workspace chooser

  /// Lists workspaces and opens the chosen one. Workspaces this app shows
  /// are revealed; one controlled elsewhere is taken over only after the
  /// user confirms. The chooser can also create a workspace instead.
  func chooseWorkspace() {
    guard !listing else { return }
    // Reserved through modal presentation, whose nested event loop can
    // deliver the action again.
    listing = true
    Task {
      defer { listing = false }
      do {
        let result = try await listWorkspaces()
        guard !terminating else { return }
        present(result)
      } catch { reportListError(error) }
    }
  }

  private func present(_ result: WorkspaceListing) {
    let list = result.workspaces
    let alert = NSAlert()
    alert.informativeText = "Workspaces keep running after their windows close."
    guard !list.isEmpty else {
      alert.messageText = "No workspaces"
      alert.addButton(withTitle: "New Workspace")
      alert.addButton(withTitle: "Cancel")
      if alert.runModal() == .alertFirstButtonReturn { create() }
      return
    }
    alert.messageText = "Open Workspace"
    let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
    for ws in list {
      let shownHere = controller(holding: ws.id) != nil
      let state =
        shownHere ? " (open)" : ws.isAttached ? " (in use elsewhere)" : ""
      let panes = ws.paneCount == 1 ? "1 pane" : "\(ws.paneCount) panes"
      popup.addItem(
        withTitle: "\(DisplayText.workspaceName(ws.name)) — \(panes)\(state)"
      )
    }
    if let last = lastWorkspace,
      let i = list.firstIndex(where: { $0.id == last })
    {
      popup.selectItem(at: i)
    }
    alert.accessoryView = popup
    alert.addButton(withTitle: "Open")
    alert.addButton(withTitle: "New Workspace")
    alert.addButton(withTitle: "Cancel")
    switch alert.runModal() {
    case .alertFirstButtonReturn:
      let chosen = list[popup.indexOfSelectedItem]
      openChosen(chosen, server: result.server)
    case .alertSecondButtonReturn: create()
    default: break
    }
  }

  private func openChosen(_ ws: WorkspaceSummary, server: ServerInstanceID?) {
    guard controller(holding: ws.id) == nil, ws.isAttached else {
      return open(ws.id, server: server)
    }
    let alert = NSAlert()
    alert.messageText =
      "Take control of workspace “\(DisplayText.workspaceName(ws.name))”?"
    alert.informativeText =
      "Another window or device controls it. Taking over disconnects it there; its programs keep running."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Take Over")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    open(ws.id, server: server, takeover: ws.leaseGeneration)
  }

  // MARK: Launch

  /// First launch creates a one-shell workspace. Later launches reopen
  /// the last workspace when it is free, or the only free one when the
  /// last is unknown or gone; otherwise they offer the existing ones
  /// before creating another. A service that is unavailable or awaiting
  /// approval is reported with a retry; no non-persistent shell starts
  /// in its place.
  func launch(
    retry: @escaping @MainActor (any Error) -> Bool = WorkspaceCoordinator
      .askRetry
  ) {
    Task {
      while !terminating {
        do {
          let result = try await listWorkspaces()
          guard !terminating else { return }
          switch Self.launchAction(result.workspaces, last: lastWorkspace) {
          case .open(let id): open(id, server: result.server)
          case .create: create()
          case .choose: present(result)
          }
          return
        } catch { guard !terminating, retry(error) else { return } }
      }
    }
  }

  enum LaunchAction: Equatable, Sendable {
    case open(WorkspaceID)
    case create
    case choose
  }

  nonisolated static func launchAction(
    _ workspaces: [WorkspaceSummary],
    last: WorkspaceID?
  ) -> LaunchAction {
    let free = workspaces.filter { !$0.isAttached }
    if let last, free.contains(where: { $0.id == last }) { return .open(last) }
    if free.isEmpty { return .create }
    // Nothing to choose between: the last workspace is unknown or gone,
    // and only one is free.
    if free.count == 1, !workspaces.contains(where: { $0.id == last }) {
      return .open(free[0].id)
    }
    return .choose
  }

  static func askRetry(_ error: any Error) -> Bool {
    let alert = NSAlert(error: error)
    alert.messageText = "Terminals are unavailable"
    alert.informativeText = error.localizedDescription
    alert.addButton(withTitle: "Retry")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }

  // MARK: App-wide

  func apply(_ configuration: Configuration) {
    self.configuration = configuration
    for controller in controllers { controller.apply(configuration) }
  }

  /// Detaches every window (Quit, updates); processes keep running.
  /// Pending creates and opens are cancelled.
  func detachAll(closing: Bool) async {
    for (_, entry) in pending { entry.task.cancel() }
    pending.removeAll()
    let all = controllers
    controllers.removeAll()
    // Concurrently: one slow connection does not hold up the others.
    let detaching = all.map { controller in
      Task {
        await controller.detach()
        if closing { controller.close() }
      }
    }
    for task in detaching { await task.value }
  }

  /// Quit: detaches everything and admits nothing new.
  func terminate() async {
    terminating = true
    await detachAll(closing: false)
  }
}
