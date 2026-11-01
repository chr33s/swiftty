import AppKit
import MuxNavigation
import Synchronization
import SwiftMuxClient
import SwiftMuxProtocol
import SwifttyCore
import SwifttyMac

/// A workspace window: the app's one terminal window type. A plain shell
/// is a one-tab, one-pane workspace. Owns this window's connection and
/// interactive lease (the service owns the workspace, its panes and
/// processes); pane views only present and forward input. Closing the
/// window or quitting detaches; panes keep running.
@MainActor
final class MuxWorkspaceController: NSWindowController, NSWindowDelegate {
  let connection: MuxConnection
  /// The service instance this window's identities belong to.
  let server: ServerInstanceID
  private let limits: MuxLimits
  /// What the service accepts beyond the original profile.
  let features: ServiceFeatures
  private(set) var config: Configuration
  /// Manual zoom for this window's panes, or nil for the configured size.
  private var fontSize: Double?
  let workspaceContent = NSView()
  private(set) var workspace: WorkspaceSnapshot?
  /// Orders snapshots against the attach, switch and takeover replies.
  private var sequencer = LayoutSequencer()
  /// The workspace this connection holds the lease for, from the last
  /// attach, switch or takeover reply. Snapshots of any other workspace
  /// (a late layout event after a switch) are not shown.
  var attachedWorkspace: WorkspaceID? { sequencer.attachedWorkspace }
  private(set) var views: [PaneID: MuxPaneView] = [:]
  private(set) var containers: [PaneID: MuxPaneContainer] = [:]
  let tabStrip = MuxTabStrip()
  let automationStatus = JavaScriptStatusBar()
  var automationKeys: Set<String> = []
  var automationTabIcons: [TabID: String] = [:]
  var automationFocusedPane: PaneID?
  var automationNotify: @MainActor (String, String) -> Void =
    JavaScriptNotifications.deliver
  /// Sanitized program titles, from snapshots and title events.
  private var titles: [PaneID: String] = [:]
  /// Panes with output the user has not seen (hidden tabs, bells).
  private(set) var activity: Set<PaneID> = []
  /// A divider drag shown locally before the service commits it.
  private var ratioProposal: RatioProposal?
  private var ratioSending = false
  /// Test hook: answers destructive confirmations without a sheet.
  var confirmDestructive: ((String) async -> Bool)?
  let layoutView = MuxLayoutView()
  private var inputs: MuxInputQueue?
  private var commands: AsyncStream<@Sendable () async -> Void>.Continuation?
  /// Buffered commands, in addition to the one already dispatched.
  static let maxQueuedCommands = 64
  private var pipelineTasks: [Task<Void, Never>] = []
  private var tasks: [Task<Void, Never>] = []
  private let connectionAttempts = MuxConnectionAttempts()
  private var geometryGeneration: UInt64 = 0
  private var sentGeometry: (revision: UInt64, entries: [GeometryBatch.Entry])?
  private var geometryScheduled = false
  private var geometryDeferred = false
  private var subscribed: [PaneID] = []
  private var detached = false
  private var presentationAttachment: AttachmentID?
  /// Lease loss leaves inbox metadata available until the window closes.
  private var closed = false
  private var closeRequested = false
  var isClosed: Bool { closed || closeRequested }
  /// Whether this window still holds its workspace's lease: false once
  /// it detached, lost its connection or another frontend took over
  /// (the window then shows "SwiftMux — detached").
  var holdsLease: Bool { !isClosed && !detached && attachedWorkspace != nil }
  var onClose: (() -> Void)?
  /// Receives the window that replaced this one after it lost its lease
  /// (inbox "Open" reattaching); the app keeps one SwiftMux window.
  var onReplaced: ((MuxWorkspaceController) -> Void)?
  /// Connects such a replacement (tests use an in-process service).
  var connectService: @MainActor () async throws -> MuxConnection = {
    try await MuxWorkspaceController.connect()
  }
  private(set) var searchBar: SearchBar?
  private var appearanceObservation: NSKeyValueObservation?
  /// Attention inbox mirror, fed by its own subscription (not frames).
  var inbox = MuxInboxModel()
  lazy var workspaceToolbar = MuxWorkspaceToolbar(tabs: tabStrip)
  var inboxPopover: NSPopover?
  var inboxView: MuxInboxViewController?
  var inboxReadID = UUID()

  private init(
    connection: MuxConnection,
    welcome: Welcome,
    configuration: Configuration
  ) {
    self.connection = connection
    server = welcome.server
    limits = welcome.limits
    features = welcome.features
    config = configuration
    let window = Self.makeWorkspaceWindow()
    super.init(window: window)
    window.delegate = self
    let content = workspaceContent
    tabStrip.translatesAutoresizingMaskIntoConstraints = false
    tabStrip.onSelect = { [weak self] tab in self?.selectTab(tab) }
    tabStrip.onClose = { [weak self] tab in self?.closeTab(tab) }
    tabStrip.onRename = { [weak self] tab, name in self?.renameTab(tab, name) }
    // On the next turn, once AppKit has settled where focus went.
    tabStrip.onRenameEnded = { [weak self] in
      Task { @MainActor in self?.focusAfterRename() }
    }
    layoutView.translatesAutoresizingMaskIntoConstraints = false
    layoutView.controller = self
    content.addSubview(layoutView)
    content.addSubview(automationStatus)
    NSLayoutConstraint.activate([
      layoutView.topAnchor.constraint(equalTo: content.topAnchor),
      layoutView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      layoutView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      layoutView.bottomAnchor.constraint(equalTo: automationStatus.topAnchor),
      automationStatus.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      automationStatus.trailingAnchor.constraint(
        equalTo: content.trailingAnchor
      ),
      automationStatus.bottomAnchor.constraint(equalTo: content.bottomAnchor),
    ])
    TerminalWindowBackground.apply(
      to: window,
      content: content,
      configuration: configuration
    )
    workspaceToolbar.onClick = { [weak self] in self?.toggleInbox() }
    workspaceToolbar.onNewTab = { [weak self] in self?.newTab() }
    window.toolbar = workspaceToolbar.toolbar
    window.toolbarStyle = .unifiedCompact
    window.titleVisibility = .hidden
    startPipelines()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  /// Attaches over an existing connection (also used by tests with an
  /// in-process service). With `expectedLease`, explicitly takes over the
  /// workspace from whoever holds that lease generation; callers pass it
  /// only after the user confirmed a takeover prompt.
  static func open(
    _ selector: WorkspaceSelector?,
    configuration: Configuration,
    connection: MuxConnection,
    takeover expectedLease: UInt64? = nil,
    beforeReturnForTesting: (
      @MainActor (MuxWorkspaceController) async -> Void
    )? = nil,
  ) async throws -> MuxWorkspaceController {
    try Task.checkCancellation()
    guard let welcome = await connection.welcome else {
      throw MuxError(.connectionLost)
    }
    try Task.checkCancellation()
    let target: WorkspaceSelector
    if let selector {
      target = selector
    } else {
      // A timeout may follow creation: the workspace then stays listed
      // (Open Workspace) and is never created again here.
      guard
        case let .created(ws) = try await connection.execute(
          .newWorkspace(WorkspaceLaunch.request(configuration)),
          timeout: .seconds(5),
        )
      else { throw MuxError(.invalidRequest, "unexpected reply") }
      target = .id(ws.id)
    }
    try Task.checkCancellation()
    let attach: MuxCommand =
      expectedLease.map { .takeover(target, expectedLease: $0) }
      ?? .attach(AttachRequest(target))
    guard
      case let .attached(attachment, ws) = try await connection.execute(
        attach,
        timeout: .seconds(5)
      )
    else { throw MuxError(.invalidRequest, "unexpected attach reply") }
    try Task.checkCancellation()
    let controller = MuxWorkspaceController(
      connection: connection,
      welcome: welcome,
      configuration: configuration,
    )
    controller.apply(ws, attached: true, attachment: attachment)
    controller.startEvents()
    controller.startInbox()
    if controller.features.contains(.javaScript) {
      controller.command(.subscribeAutomation(true))
    }
    controller.sendTheme()
    controller.observeAppearance()
    do {
      await beforeReturnForTesting?(controller)
      try Task.checkCancellation()
      try await connection.checkOpen()
      try Task.checkCancellation()
    } catch {
      await controller.detach()
      controller.close()
      throw error
    }
    return controller
  }

  /// Shows `target` for an attention link: in `current` while it holds
  /// that workspace's lease, otherwise attached on a new connection
  /// (`replace`; a takeover only with a confirmed `expectedLease`), so a
  /// detached window reattaches rather than sending commands without a
  /// lease. `attached` receives a new controller as soon as it holds the
  /// lease. Throws when the pane is not shown: `leaseHeld` (keeping
  /// `current`) lets the caller offer a takeover.
  static func reveal(
    _ target: PaneTarget,
    in current: MuxWorkspaceController?,
    configuration: Configuration,
    connect: @escaping @MainActor () async throws -> MuxConnection,
    takeover expectedLease: UInt64? = nil,
    attached: (MuxWorkspaceController) -> Void = { _ in },
  ) async throws -> MuxWorkspaceController {
    try Task.checkCancellation()
    guard current?.isClosed != true else { throw CancellationError() }
    if let current, current.attachedWorkspace == target.workspace,
      current.holdsLease
    {
      do {
        try await current.revealAttention(pane: target.pane, tab: target.tab)
        return current
      } catch let error as MuxError where error.code == .notAttached {
        // The lease moved before the detach event arrived: attach afresh.
      }
    }
    guard current?.isClosed != true else { throw CancellationError() }
    let connection: MuxConnection
    if let current {
      connection = try await current.connectionAttempts.connect(connect)
    } else {
      connection = try await connect()
    }
    let controller = try await replace(
      current,
      with: .id(target.workspace),
      configuration: configuration,
      connection: connection,
      takeover: expectedLease,
    )
    do { try Task.checkCancellation() } catch {
      await controller.detach()
      controller.close()
      throw error
    }
    attached(controller)
    try await controller.revealAttention(pane: target.pane, tab: target.tab)
    return controller
  }

  // MARK: Pipelines

  /// One ordered input writer and one ordered command executor.
  private func startPipelines() {
    inputs = MuxInputQueue(connection: connection, limits: limits) {
      [weak self] message in
      guard let self, !detached else { return }
      window?.subtitle = DisplayText.sanitize(message)
    }
    let (commandStream, commandContinuation) = AsyncStream<
      @Sendable () async -> Void
    >
    .makeStream(bufferingPolicy: .bufferingOldest(Self.maxQueuedCommands))
    commands = commandContinuation
    pipelineTasks.append(
      Task.detached { [weak self] in
        for await command in commandStream {
          guard !Task.isCancelled else { break }
          await command()
          // A full queue may defer the newest divider proposal. Retry
          // as accepted jobs drain, without adding a polling task.
          await self?.flushRatio()
          await MainActor.run { [weak self] in
            guard let self, geometryDeferred else { return }
            sendGeometry()
          }
        }
      }
    )
  }

  private func stopPipelines() {
    inputs?.stop()
    inputs = nil
    commands?.finish()
    commands = nil
    for task in pipelineTasks { task.cancel() }
    pipelineTasks.removeAll()
  }

  /// Consumes events off the main actor; imports frames there and hops
  /// to the main actor only to publish finished presentations.
  private func startEvents() {
    let connection = connection
    let limits = limits
    tasks.append(
      Task.detached { [weak self] in
        do {
          while let event = try await connection.nextEvent() {
            switch event {
            case let .frame(frame):
              guard
                let presentation = MuxPaneView.importFrame(
                  frame,
                  limits: limits
                )
              else { continue }
              await self?.present(presentation)
            default: await self?.handle(event)
            }
          }
          if !Task.isCancelled {
            await self?.connectionEnded("connection closed")
          }
        } catch { await self?.connectionEnded(String(describing: error)) }
      }
    )
  }

  private func present(_ presentation: MuxPresentation) {
    guard !detached,
      presentation.frame.identity.attachment == presentationAttachment
    else { return }
    views[presentation.frame.identity.pane]?
      .receive(presentation, server: server)
  }

  /// Applies one non-frame event (internal for tests).
  func handle(_ event: MuxEvent) {
    switch event {
    case let .automation(data): handleAutomation(data)
    case let .layout(ws): apply(ws)
    case let .title(pane, title):
      titles[pane] = DisplayText.sanitize(title)
      refreshChrome()
    case let .bell(pane):
      guard !detached else { return }
      NSSound.beep()
      if pane != activePane { markActivity(pane) }
    case let .activity(pane): markActivity(pane)
    case let .detached(reason): connectionEnded(reason)
    case let .paneExited(pane, status, truncated):
      if truncated, !detached {
        window?.subtitle =
          "A pane was force-killed; its final output may be incomplete"
      }
      if let i = workspace?.panes.firstIndex(where: { $0.id == pane }) {
        workspace?.panes[i].exitStatus = status
      }
      refreshChrome()
    case let .inbox(update):
      if inbox.apply(update) { Task { await reloadInbox() } }
      refreshInbox()
    case let .clipboardRead(request): handleClipboardRead(request)
    case let .clipboardWrite(request): handleClipboardWrite(request)
    case .paste, .frameUnavailable, .frame, .workspaces, .ready: break
    }
  }

  private func connectionEnded(_ reason: String) {
    guard !detached else { return }
    detached = true
    stopPipelines()
    for view in views.values { view.reset() }
    showsTabs(true)
    window?.title = "\(workspaceTitle) — detached (\(reason))"
  }

  // MARK: Layout

  private var workspaceTitle: String {
    workspace.map { DisplayText.sanitize($0.name) }.flatMap(\.nonEmpty)
      ?? "swiftty"
  }

  var activeTab: TabSnapshot? { workspace?.activeTabSnapshot }
  var activePane: PaneID? { activeTab?.activePane }

  /// Shows `ws`. With `attached`, it is the reply to an attach, switch
  /// or takeover and names the workspace this connection now holds;
  /// otherwise it is shown only for that workspace and when no older
  /// than the layout already shown.
  private func apply(
    _ ws: WorkspaceSnapshot,
    attached: Bool = false,
    attachment: AttachmentID? = nil
  ) {
    // Metadata remains available after lease loss, but this window no
    // longer presents layouts from its retired interactive attachment.
    guard !detached else { return }
    if let attachment, presentationAttachment != attachment {
      presentationAttachment = attachment
      for view in views.values { view.reset() }
    }
    let update = attached ? sequencer.attached(ws) : sequencer.layout(ws)
    switch update {
    case nil: return
    case .resync:
      // The service dropped this connection's subscriptions; the layout
      // shown is newer than the reply.
      subscribed = []
      sentGeometry = nil
      if let workspace { show(workspace) }
    case let .show(ws, resync):
      if resync {
        subscribed = []
        sentGeometry = nil
      }
      if let current = workspace, current.id != ws.id { activity = [] }
      show(ws)
    }
  }

  /// The subscriptions last sent (tests).
  var subscribedPanes: [PaneID] { subscribed }

  private func show(_ ws: WorkspaceSnapshot) {
    workspace = ws
    for pane in ws.panes where titles[pane.id] == nil || !pane.title.isEmpty {
      titles[pane.id] = DisplayText.sanitize(pane.title)
    }
    let known = Set(ws.panes.map(\.id))
    titles = titles.filter { known.contains($0.key) }
    activity.formIntersection(known)
    guard let tab = ws.activeTabSnapshot else {
      refreshChrome()
      return
    }
    // Rebind: keep views for surviving panes, drop the rest.
    let visible = tab.zoomedPane.map { [$0] } ?? tab.layout.panes
    for (id, view) in views where !visible.contains(id) {
      view.cancelComposition()
      containers[id]?.removeFromSuperview()
      containers.removeValue(forKey: id)
      views.removeValue(forKey: id)
    }
    for id in visible where views[id] == nil {
      guard
        let view = try? MuxPaneView(pane: id, configuration: paneConfiguration)
      else { continue }
      view.controller = self
      let container = MuxPaneContainer(paneView: view)
      container.header.onAction = { [weak self] action in
        self?.headerAction(action, pane: id)
      }
      views[id] = view
      containers[id] = container
      layoutView.addSubview(container)
    }
    for (id, view) in views { view.isActivePane = id == tab.activePane }
    // Shown panes are seen.
    activity.subtract(visible)
    if let proposal = ratioProposal, proposal.tab != tab.id {
      ratioProposal = nil
    }
    refreshChrome()
    layoutView.needsLayout = true
    layoutView.layoutSubtreeIfNeeded()
    focusActivePane()
    if visible != subscribed {
      subscribed = visible
      command(.setSubscriptions(visible))
    }
    geometryChanged()
  }

  // MARK: Chrome

  func title(of pane: PaneID) -> String {
    titles[pane].flatMap(\.nonEmpty) ?? "shell"
  }

  /// Tab strip, pane headers and window title from the current snapshot.
  func refreshChrome() {
    guard !detached, let ws = workspace else { return }
    tabStrip.update(
      ws.tabs.map { tab in
        let name = DisplayText.sanitize(tab.name)
        // Service default names are numbers; show the program instead.
        let automatic = name.isEmpty || name.allSatisfy(\.isNumber)
        let label = automatic ? title(of: tab.activePane) : name
        return MuxTabItem(
          id: tab.id,
          title: [automationTabIcons[tab.id], label].compactMap { $0 }
            .filter { !$0.isEmpty }.joined(separator: " "),
          symbol: MuxIcons.symbol(for: title(of: tab.activePane)),
          isActive: tab.id == ws.activeTab,
          hasActivity: tab.id != ws.activeTab
            && tab.layout.panes.contains(where: activity.contains),
          name: automatic ? nil : tab.name
        )
      }
    )
    guard let tab = ws.activeTabSnapshot else { return }
    let split = tab.layout.panes.count > 1
    for (id, container) in containers {
      container.showsHeader = split
      container.update(
        MuxPaneHeaderState(
          title: title(of: id),
          isActive: id == tab.activePane,
          hasActivity: activity.contains(id),
          isZoomed: tab.zoomedPane == id,
          hasExited: ws.pane(id)?.exitStatus != nil
        )
      )
    }
    let active = titles[tab.activePane].flatMap(\.nonEmpty)
    window?.title = [automationTabIcons[tab.id], active ?? workspaceTitle]
      .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    updateAutomationFocus()
    showsTabs(ws.tabs.count > 1)
  }

  /// A one-tab workspace shows its title, not a strip with one choice.
  /// The new-tab and inbox controls stay either way.
  private func showsTabs(_ shown: Bool) {
    workspaceToolbar.tabs.isHidden = !shown
    window?.titleVisibility = shown ? .hidden : .visible
  }

  /// Whether the tab strip is shown (tests).
  var showsTabStrip: Bool { !workspaceToolbar.tabs.isHidden }

  private func markActivity(_ pane: PaneID) {
    guard !detached else { return }
    guard pane != activePane || !subscribed.contains(pane) else { return }
    guard activity.insert(pane).inserted else { return }
    refreshChrome()
  }

  // MARK: Geometry

  /// The active tab's tree with any local divider drag applied.
  private var displayedLayout: LayoutNode? {
    guard let tab = activeTab else { return nil }
    if let p = ratioProposal, p.tab == tab.id,
      let moved = tab.layout.settingRatio(p.ratio, at: p.path)
    {
      return moved
    }
    return tab.layout
  }

  /// Smallest pane in points: 10 columns by 2 rows plus its header.
  var minimumPaneSize: (columns: Int, rows: Int) {
    guard let view = views.values.first else { return (80, 40) }
    let scale = view.window?.backingScaleFactor ?? 2
    let cell = view.renderer.cellSize
    let o = view.renderer.options
    let inset = MuxPaneContainer.cardInset
    return (
      Int(((cell.width * 10 + o.paddingX * 2) / scale).rounded(.up))
        + Int(inset * 2),
      Int(((cell.height * 2 + o.paddingY * 2) / scale).rounded(.up))
        + Int(MuxPaneContainer.headerHeight + inset)
    )
  }

  /// Frames for visible panes in points, plus dividers for dragging.
  func layout(
    in bounds: NSRect
  ) -> (panes: [(MuxPaneContainer, NSRect)], dividers: [LayoutDivider]) {
    guard let tab = activeTab, let tree = displayedLayout else {
      return ([], [])
    }
    let area = MuxLayoutView.area(bounds, split: tree.panes.count > 1)
    if let zoomed = tab.zoomedPane, let view = containers[zoomed] {
      let frame = NSRect(
        x: area.x,
        y: Int(bounds.height) - area.maxY,
        width: area.width,
        height: area.height
      )
      return ([(view, frame)], [])
    }
    let frames = LayoutGeometry.frames(
      tree,
      in: area,
      divider: MuxLayoutView.divider
    )
    let panes = frames.compactMap { id, r -> (MuxPaneContainer, NSRect)? in
      containers[id]
        .map {
          // LayoutRect y grows downward; AppKit's grows upward.
          (
            $0,
            NSRect(
              x: r.x,
              y: Int(bounds.height) - r.maxY,
              width: r.width,
              height: r.height
            )
          )
        }
    }
    return (
      panes,
      LayoutGeometry.dividers(tree, in: area, divider: MuxLayoutView.divider)
    )
  }

  /// A divider drag: shown at once, sent coalesced (one request in
  /// flight, newest ratio pending), clamped to the minimum pane size.
  func setRatio(_ ratio: Double, path: [Bool]) {
    guard let tab = activeTab, let tree = displayedLayout else { return }
    let clamped = LayoutGeometry.clampedRatio(
      ratio,
      at: path,
      of: tree,
      in: MuxLayoutView.area(layoutView.bounds, split: tree.panes.count > 1),
      minimum: minimumPaneSize,
      divider: MuxLayoutView.divider
    )
    ratioProposal = RatioProposal(tab: tab.id, path: path, ratio: clamped)
    layoutView.needsLayout = true
    flushRatio()
  }

  /// The current ratio of the split at `path` as displayed.
  func ratio(at path: [Bool]) -> Double? {
    guard case let .split(_, r, _, _)? = displayedLayout?.node(at: path) else {
      return nil
    }
    return r
  }

  private func flushRatio() {
    guard !ratioSending, !detached, let proposal = ratioProposal, let commands
    else { return }
    ratioSending = true
    let connection = connection
    let admission = commands.yield {
      let reply = try? await connection.execute(
        .setSplitRatio(
          tab: proposal.tab,
          path: proposal.path,
          ratio: proposal.ratio
        )
      )
      await MainActor.run { [weak self] in
        guard let self else { return }
        ratioSending = false
        if ratioProposal == proposal { ratioProposal = nil }
        if case let .layout(ws)? = reply { apply(ws) }
        flushRatio()
      }
    }
    // A refused job owns no completion that could clear this flag.
    // Keep only the latest proposal for the pipeline's next retry.
    guard case .enqueued = admission else {
      ratioSending = false
      return
    }
  }

  /// Coalesces superseded geometry into one batch per run loop turn.
  func geometryChanged() {
    guard !geometryScheduled else { return }
    geometryScheduled = true
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        self?.geometryScheduled = false
        self?.sendGeometry()
      }
    }
  }

  private func sendGeometry() {
    guard !detached, let ws = workspace, let commands else { return }
    let entries =
      views.compactMap { id, view -> GeometryBatch.Entry? in
        guard view.superview != nil, view.bounds.width > 0,
          view.bounds.height > 0
        else {
          return nil  // retain the last valid size; never resize to zero
        }
        let size = view.gridSize
        return .init(
          pane: id,
          columns: min(size.columns, limits.maxColumns),
          rows: min(size.rows, limits.maxRows)
        )
      }
      .sorted { $0.pane.description < $1.pane.description }
    guard !entries.isEmpty else { return }
    if let sent = sentGeometry, sent.revision == ws.layoutRevision,
      sent.entries == entries
    {
      return
    }
    geometryGeneration += 1
    sentGeometry = (ws.layoutRevision, entries)
    let batch = GeometryBatch(
      layoutRevision: ws.layoutRevision,
      generation: geometryGeneration,
      entries: entries
    )
    let connection = connection
    let admission = commands.yield {
      do { try await connection.execute(.setGeometry(batch)) } catch let error
        as MuxError where error.code == .staleGeometry
      {
        // A newer layout is on its way; resend once it arrives.
        await MainActor.run { [weak self] in self?.sentGeometry = nil }
      } catch {}
    }
    guard case .enqueued = admission else {
      // This batch was never accepted. Retry current dimensions when
      // the existing pipeline next makes room, rather than caching it.
      sentGeometry = nil
      geometryDeferred = true
      return
    }
    geometryDeferred = false
  }

  // MARK: Actions

  /// Queues `command` in order. Without `failed`, a failure is only
  /// logged; with it, the failure is handed back and `then` is skipped.
  func command(
    _ command: MuxCommand,
    cancelled: @escaping @Sendable () -> Bool = { false },
    failed: (@MainActor @Sendable (any Error) -> Void)? = nil,
    replied: (@MainActor @Sendable (MuxReply) -> Void)? = nil,
    then: (@MainActor @Sendable () -> Void)? = nil,
  ) {
    guard let commands else {
      failed?(MuxError(.notAttached))
      return
    }
    let connection = connection
    let admission = commands.yield {
      do {
        if cancelled() { throw CancellationError() }
        let reply = try await connection.execute(command)
        switch reply {
        case let .attached(attachment, ws):
          await MainActor.run { [weak self] in
            self?.apply(ws, attached: true, attachment: attachment)
          }
        case let .layout(ws):
          // A switch reply names the workspace now held.
          var switched = false
          if case .switchWorkspace = command { switched = true }
          await MainActor.run { [weak self] in
            self?.apply(ws, attached: switched)
          }
        default: break
        }
        if let replied { await replied(reply) }
        if let then { await then() }
      } catch {
        if Task.isCancelled {
          if let failed { await failed(MuxError(.notAttached)) }
          return
        }
        if let failed {
          await failed(error)
          return
        }
        await MainActor.run {
          FileHandle.standardError.write(
            Data("swiftty: swiftmux: \(error)\n".utf8),
          )
        }
      }
    }
    switch admission {
    case .enqueued: break
    case .dropped:
      let error = MuxError(
        .resourceLimit,
        "Too many pending workspace commands"
      )
      if let failed {
        failed(error)
      } else {
        FileHandle.standardError.write(
          Data("swiftty: swiftmux: \(error)\n".utf8)
        )
      }
    case .terminated: failed?(MuxError(.notAttached))
    @unknown default: failed?(MuxError(.resourceLimit))
    }
  }

  func send(_ input: MuxInput, to pane: PaneID) {
    guard !detached else { return }
    inputs?.send(input, to: pane)
  }

  func paste(_ text: String, to pane: PaneID) {
    guard !detached else { return }
    inputs?.paste(text, to: pane)
  }

  func scroll(_ pane: PaneID, lines: Int) { scroll(pane, .lines(lines)) }

  func scroll(_ pane: PaneID, _ request: ScrollRequest) {
    command(.scroll(pane: pane, request))
  }

  // MARK: Terminal control and shell integration

  func clearScreen(_ pane: PaneID) {
    guard holdsLease else { return }
    command(.clearScreen(pane))
  }

  func resetTerminal(_ pane: PaneID) {
    guard holdsLease else { return }
    command(.resetTerminal(pane))
  }

  /// The link at a viewport cell of `frame`; nil (or no callback) when
  /// there is none or the service cannot say.
  func link(
    in pane: PaneID,
    at address: HistoryAddress,
    column: Int,
    found: @escaping @MainActor @Sendable (MuxLink?) -> Void
  ) {
    guard holdsLease, features.contains(.shellIntegration) else {
      return found(nil)
    }
    command(
      .link(
        pane: pane,
        at: address,
        column: column,
        detectURLs: config.linkURL
      ),
      failed: { _ in found(nil) },
      replied: { reply in
        if case let .link(link) = reply { found(link) } else { found(nil) }
      }
    )
  }

  /// The output of the command around `address` (or the latest); the
  /// service scrolls it into view.
  func commandOutput(
    in pane: PaneID,
    at address: HistoryAddress?,
    found: @escaping @MainActor @Sendable (CommandOutput?) -> Void
  ) {
    guard holdsLease, features.contains(.shellIntegration) else {
      return found(nil)
    }
    command(
      .commandOutput(pane: pane, at: address),
      failed: { _ in found(nil) },
      replied: { reply in
        if case let .commandOutput(output) = reply {
          found(output)
        } else {
          found(nil)
        }
      }
    )
  }

  func focus(_ pane: PaneID) {
    guard pane != activePane else { return }
    command(.focusPane(pane))
  }

  func paneBecameFirstResponder(_ view: MuxPaneView) {
    if view.pane != activePane { focus(view.pane) }
  }

  /// Moves focus to the visible pane beside the active one.
  func focus(_ direction: Direction) {
    guard let tab = activeTab, tab.zoomedPane == nil, let tree = displayedLayout
    else { return }
    let frames = LayoutGeometry.frames(
      tree,
      in: LayoutRect(x: 0, y: 0, width: 10_000, height: 10_000),
      divider: MuxLayoutView.divider
    )
    if let next = LayoutGeometry.neighbor(
      of: tab.activePane,
      direction: direction,
      frames: frames,
      order: tree.panes
    ) {
      focus(next)
      if let view = views[next] { window?.makeFirstResponder(view) }
    }
  }

  /// Moves the nearest divider beside the active pane (keyboard resize).
  func resizeActivePane(_ direction: Direction, step: Double = 0.05) {
    guard let tab = activeTab, let tree = displayedLayout else { return }
    let axis: SplitAxis =
      direction == .left || direction == .right ? .leftRight : .topBottom
    guard let split = tree.enclosingSplit(of: tab.activePane, axis: axis),
      let current = ratio(at: split.path)
    else { return }
    let grow = direction == .right || direction == .down
    setRatio(current + (grow ? step : -step), path: split.path)
  }

  /// Brings the window forward and activates `pane` (selecting `tab`
  /// first when it is not the active one), for attention links. The
  /// layout reply makes the pane's view first responder.
  func reveal(pane: PaneID, tab: TabID?) {
    guard holdsLease else { return }
    if let tab = tab ?? workspace?.tab(containing: pane)?.id { selectTab(tab) }
    if pane != activePane { command(.focusPane(pane)) }
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    if let view = views[pane] { window?.makeFirstResponder(view) }
  }

  /// `reveal(pane:tab:)` that reports failure: `notAttached` once this
  /// window no longer holds the lease, or the service's refusal.
  func revealAttention(pane: PaneID, tab: TabID?) async throws {
    try Task.checkCancellation()
    guard holdsLease else { throw MuxError(.notAttached) }
    if let tab = tab ?? workspace?.tab(containing: pane)?.id,
      tab != workspace?.activeTab
    {
      try await execute(.selectTab(tab))
    }
    try Task.checkCancellation()
    guard holdsLease else { throw MuxError(.notAttached) }
    if pane != activePane { try await execute(.focusPane(pane)) }
    try Task.checkCancellation()
    guard holdsLease else { throw MuxError(.notAttached) }
    reveal(pane: pane, tab: nil)
  }

  /// Runs `command` in order with the others and waits for its outcome.
  /// Cancellation stops waiting and skips commands not yet dispatched;
  /// a command already sent to the service may still commit.
  /// A command dropped unrun (the queue ended on detach) fails
  /// `notAttached`.
  private func execute(_ command: MuxCommand) async throws {
    let state = Mutex(MuxCommandWait())
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation {
        (done: CheckedContinuation<Void, any Error>) in
        let once = MuxCommandCompletion(done)
        let cancelled = state.withLock { state in
          state.once = once
          return state.cancelled
        }
        guard !cancelled else {
          once.resume(throwing: CancellationError())
          return
        }
        self.command(
          command,
          cancelled: { state.withLock { $0.cancelled } },
          failed: { error in once.resume(throwing: error) },
          then: { once.resume() },
        )
      }
    } onCancel: {
      let once = state.withLock { state in
        state.cancelled = true
        return state.once
      }
      once?.resume(throwing: CancellationError())
    }
  }

  func selectTab(_ tab: TabID) {
    guard tab != workspace?.activeTab else { return }
    command(.selectTab(tab))
  }

  /// Tab renames sent, numbering each.
  private var renames = 0
  /// The refused rename the subtitle reports, and what it says.
  private var refusal: (rename: Int, notice: String)?

  /// `name` as `DisplayText.plainName` gives it (the tab strip cleans it).
  func renameTab(_ tab: TabID, _ name: String) {
    renames += 1
    let rename = renames
    command(
      .renameTab(tab, name: name),
      failed: { [weak self] error in
        guard let self, !detached else { return }
        let notice = DisplayText.sanitize("Tab not renamed: \(error)")
        refusal = (rename, notice)
        window?.subtitle = notice
      },
      then: { [weak self] in
        guard let self else { return }
        // A later rename that lands clears an earlier refusal, if the
        // subtitle still reports it.
        guard let refusal, refusal.rename < rename else { return }
        self.refusal = nil
        if window?.subtitle == refusal.notice { window?.subtitle = "" }
      }
    )
  }

  /// Keys go back to the active pane after a tab rename when they would
  /// otherwise reach nothing (no first responder but the window). Focus a
  /// click moved elsewhere (a pane, the search field, another rename) or
  /// Tab moved to the next key view (a toolbar control with Full Keyboard
  /// Access; never a pane) stays.
  private func focusAfterRename() {
    guard let window else { return }
    func idle(_ w: NSWindow) -> Bool {
      w.firstResponder == nil || w.firstResponder === w
    }
    // The workspace window's own keys may be idle (the edit ran there, or
    // the strip left it mid-edit). In full screen the strip lives in
    // AppKit's toolbar window: while the person is still there with keys
    // reaching nothing, they go back to the workspace. Keys taken
    // elsewhere stay.
    var refocus = idle(window)
    if let strip = tabStrip.window, strip !== window, strip.isKeyWindow,
      idle(strip)
    {
      window.makeKey()
      refocus = true
    }
    if refocus { focusActivePane() }
  }

  /// Keys go to the active pane, unless the person is typing in a text
  /// field (search, a tab rename) and `overText` is false.
  private func focusActivePane(overText: Bool = false) {
    guard let window, let view = activePane.flatMap({ views[$0] }),
      window.firstResponder !== view,
      overText || !(window.firstResponder is NSText)
    else { return }
    window.makeFirstResponder(view)
  }

  func beginRenamingActiveTab() {
    tabStrip.buttons.first { $0.item?.isActive == true }?.beginRename()
  }

  /// The service starts it with the workspace's launch spec.
  func newTab() { command(.newTab(name: nil, launch: nil)) }

  func split(_ axis: SplitAxis, pane: PaneID? = nil) {
    guard let pane = pane ?? activePane else { return }
    command(.split(pane: pane, axis: axis, launch: nil))
  }

  func toggleZoom(pane: PaneID? = nil) {
    guard let tab = activeTab else { return }
    if let pane, pane != tab.activePane { command(.focusPane(pane)) }
    command(.toggleZoom(tab.id))
  }

  private func headerAction(_ action: MuxPaneHeader.Action, pane: PaneID) {
    switch action {
    case .splitRight: split(.leftRight, pane: pane)
    case .splitDown: split(.topBottom, pane: pane)
    case .zoom: toggleZoom(pane: pane)
    case .close: endPane(pane)
    }
  }

  /// Whether ending `panes` would terminate a running process.
  private func running(_ panes: [PaneID]) -> Bool {
    panes.contains { workspace?.pane($0)?.exitStatus == nil }
  }

  /// Destructive actions terminate only their target, and ask first
  /// while a process is still running. Hiding and closing views never
  /// end anything.
  func endPane(_ pane: PaneID? = nil) {
    guard let pane = pane ?? activePane else { return }
    let name = title(of: pane)
    confirmThen(
      running([pane]),
      "End the pane “\(name)”?",
      "Its process is still running and will be terminated."
    ) { [weak self] in self?.command(.endPane(pane)) }
  }

  func closeTab(_ tab: TabID? = nil) {
    guard let ws = workspace,
      let snapshot = ws.tabs.first(where: { $0.id == (tab ?? ws.activeTab) })
    else { return }
    let panes = snapshot.layout.panes
    confirmThen(
      running(panes),
      "End the tab “\(title(of: snapshot.activePane))”?",
      panes.count == 1
        ? "Its process is still running and will be terminated."
        : "Its \(panes.count) panes and their processes will be terminated."
    ) { [weak self] in self?.command(.endTab(snapshot.id)) }
  }

  func confirmThen(
    _ ask: Bool,
    _ message: String,
    _ detail: String,
    button: String = "End",
    _ action: @escaping @MainActor () -> Void
  ) {
    guard !isClosed else { return }
    guard ask else { return action() }
    Task { @MainActor [weak self] in
      guard let self, !isClosed else { return }
      let ok: Bool
      if let hook = confirmDestructive {
        ok = await hook(message)
      } else {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        if let window {
          ok =
            await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
        } else {
          ok = alert.runModal() == .alertFirstButtonReturn
        }
      }
      if ok, !isClosed { action() }
    }
  }

  func cycleTab(_ delta: Int) {
    guard let ws = workspace,
      let i = ws.tabs.firstIndex(where: { $0.id == ws.activeTab })
    else { return }
    command(.selectTab(ws.tabs[(i + delta + ws.tabs.count) % ws.tabs.count].id))
  }

  /// Renames the workspace (metadata only).
  func renameWorkspace(_ name: String) {
    guard let id = attachedWorkspace else { return }
    command(
      .renameWorkspace(.id(id), name: name),
      failed: { [weak self] error in
        guard let self, !detached else { return }
        window?.subtitle = DisplayText.sanitize(
          "Workspace not renamed: \(error)"
        )
      }
    )
  }

  /// Ends the workspace and every process in it, after confirmation
  /// while any is running, then closes the window.
  func endWorkspace() {
    guard let ws = workspace, let id = attachedWorkspace, ws.id == id else {
      return
    }
    let live = ws.panes.filter { $0.exitStatus == nil }.count
    confirmThen(
      live > 0,
      "End the workspace “\(workspaceTitle)”?",
      live == 1
        ? "Its process is still running and will be terminated."
        : "Its \(live) running processes will be terminated."
    ) { [weak self] in
      self?
        .command(
          .endWorkspace(.id(id)),
          failed: { [weak self] error in
            // Ending it detaches this window, which may stop the queue
            // before the reply is seen.
            guard (error as? MuxError)?.code != .notAttached else {
              self?.close()
              return
            }
            self?.notice("Workspace not ended: \(error)")
          },
          then: { [weak self] in self?.close() }
        )
    }
  }

  /// Prompts for a workspace name.
  func beginRenamingWorkspace() {
    guard let window, attachedWorkspace != nil else { return }
    let alert = NSAlert()
    alert.messageText = "Rename Workspace"
    let field = NSTextField(
      string: workspace.map { DisplayText.sanitize($0.name) } ?? ""
    )
    field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: "Rename")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn,
        let name = DisplayText.plainName(field.stringValue)
      else { return }
      self?.renameWorkspace(name)
    }
  }

  /// Releases the lease; panes, layout and history stay with the service.
  func detach() async {
    guard !closed else { return }
    closed = true
    connectionAttempts.cancel()
    inboxReadID = UUID()
    detached = true
    for view in views.values { view.cancelComposition() }
    stopPipelines()
    for task in tasks { task.cancel() }
    await connection.detach()
    await connection.close()
    tasks.removeAll()
  }

  // MARK: Theme

  /// Default colours and scheme reported by the service-side engines
  /// follow the app's theme (spec §7.1).
  func sendTheme() {
    let appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
    let scheme = TerminalView.scheme(of: appearance)
    let p = config.palette(for: scheme)
    var colors: [UInt32] = []
    colors.reserveCapacity(256)
    for i in 0 ..< 256 { colors.append(p.colors[i]) }
    command(
      .setTheme(
        MuxTheme(
          palette: FramePalette(
            colors: colors,
            foreground: p.foreground,
            background: p.background,
            cursor: p.cursor,
            cursorText: p.cursorText,
            selectionForeground: p.selectionForeground,
            selectionBackground: p.selectionBackground
          ),
          dark: scheme == .dark
        )
      )
    )
  }

  func observeAppearance() {
    appearanceObservation = NSApp.observe(\.effectiveAppearance) {
      [weak self] _, _ in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.sendTheme() }
      }
    }
  }

  /// The configuration panes render with: this window's zoom applied.
  private var paneConfiguration: Configuration {
    var c = config
    if let fontSize { c.fontSize = fontSize }
    return c
  }

  /// Zooms every pane in this window; nil returns to the configured size.
  func setFontSize(_ size: Double?) {
    fontSize = size.map(Configuration.boundedFontSize)
    let c = paneConfiguration
    for view in views.values { view.apply(c) }
    geometryChanged()
  }

  func adjustFontSize(by delta: Double) {
    setFontSize((fontSize ?? config.fontSize) + delta)
  }

  /// A configuration reload: new colours reach the engines.
  func apply(_ configuration: Configuration) {
    config = configuration
    for view in views.values { view.apply(paneConfiguration) }
    if let window {
      let focused =
        searchBar?.field.currentEditor() === window.firstResponder
        ? searchBar?.field : window.firstResponder as? NSView
      let selection = (focused as? NSControl)?.currentEditor()?.selectedRange
      if TerminalWindowBackground.apply(
        to: window,
        content: workspaceContent,
        configuration: configuration
      ), let focused {
        window.makeFirstResponder(focused)
        if let selection, let control = focused as? NSControl {
          control.currentEditor()?.selectedRange = selection
        }
      }
    }
    sendTheme()
  }

  // MARK: Search

  /// Literal search over the active pane's service-side history; the
  /// viewport follows the selected match and frames carry highlights.
  func performFind(_ action: NSFindPanelAction?) {
    guard let pane = activePane else { return }
    switch action {
    case .next: command(.searchStep(pane: pane, forward: false))
    case .previous: command(.searchStep(pane: pane, forward: true))
    default: showSearch()
    }
  }

  /// Opens the search bar, searching for `text` when given.
  func showSearch(text: String? = nil) {
    let content = workspaceContent
    if searchBar == nil {
      let bar = SearchBar()
      bar.onChange = { [weak self] query in self?.search(query) }
      bar.onNavigate = { [weak self] older in
        guard let pane = self?.activePane else { return }
        self?.command(.searchStep(pane: pane, forward: !older))
      }
      bar.onClose = { [weak self] in self?.hideSearch() }
      bar.autoresizingMask = [.minXMargin, .minYMargin]
      content.addSubview(bar)
      searchBar = bar
    }
    searchBar?.position(in: content.bounds)
    searchBar?.isHidden = false
    window?.makeFirstResponder(searchBar?.field)
    if let text {
      searchBar?.text = text
      search(text)
    }
  }

  private func search(_ query: String) {
    guard let pane = activePane else { return }
    guard limits.validSearchQuery(query) else {
      command(.endSearch(pane: pane))
      return
    }
    command(.search(pane: pane, query: query))
  }

  func hideSearch() {
    searchBar?.isHidden = true
    searchBar?.text = ""
    if let pane = activePane {
      command(.endSearch(pane: pane))
      command(.scroll(pane: pane, .bottom))
      focusActivePane(overText: true)
    }
  }

  // MARK: Attention inbox

  /// Rows requested per inbox page (the service caps it at 100).
  var inboxPageLimit = 100
  /// The last failed inbox command: shown inline while the popover is
  /// open, otherwise kept for the next time it opens.
  var inboxMessage: String?

  func windowWillClose(_ notification: Notification) {
    closeRequested = true
    connectionAttempts.cancel()
    detached = true
    stopPipelines()
    Task { await detach() }
    onClose?()
  }
}

extension String { fileprivate var nonEmpty: String? { isEmpty ? nil : self } }
