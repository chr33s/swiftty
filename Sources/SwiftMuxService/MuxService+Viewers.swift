import Dispatch
import Foundation
import SwiftMuxProtocol
import SwiftMuxXPC

extension MuxService {
  // MARK: Viewers

  func grantViewer(
    _ ws: Workspace,
    to client: Client,
    hello: Hello,
  ) throws(MuxError) -> MuxReply {
    guard !client.remote else {
      throw MuxError(.unauthorized, "roaming observers are not enabled")
    }
    // Observer frames are only delivered over XPC.
    guard client.local == nil else {
      throw MuxError(.invalidRequest, "in-process clients cannot observe")
    }
    var list = viewers[ws.id] ?? []
    guard list.count < SMX.maxObservers else {
      throw MuxError(
        .resourceLimit,
        "this workspace already has \(SMX.maxObservers) observers",
      )
    }
    recordLocalUse(ws.id, by: client)
    var viewer = Viewer(client: client.id, workspace: ws.id)
    viewer.readiness.enabled = hello.capabilities.contains(.attachReadiness)
    list.append(viewer)
    viewers[ws.id] = list
    clientViewers[client.id] = ws.id
    idleWork?.cancel()
    scheduleAutomationTopology()
    var snap = snapshot(ws)
    snap.attachmentRole = .observer
    return .attached(attachment: viewer.attachment, workspace: snap)
  }

  func viewerIndex(_ client: UUID) -> (WorkspaceID, Int)? {
    guard let wsID = clientViewers[client],
      let index = viewers[wsID]?.firstIndex(where: { $0.client == client })
    else { return nil }
    return (wsID, index)
  }

  /// `notify` is false when the observer asked to leave or is gone.
  func releaseViewer(_ client: UUID, notify: Bool, reason: String) {
    guard let (wsID, index) = viewerIndex(client) else { return }
    let viewer = viewers[wsID]!.remove(at: index)
    if viewers[wsID]?.isEmpty == true { viewers[wsID] = nil }
    tearDown(viewer)
    if notify { send(.event(.detached(reason: reason)), to: client) }
    scheduleAutomationTopology()
  }

  func releaseViewers(in wsID: WorkspaceID, reason: String) {
    for viewer in viewers.removeValue(forKey: wsID) ?? [] {
      tearDown(viewer)
      send(.event(.detached(reason: reason)), to: viewer.client)
    }
    scheduleAutomationTopology()
  }

  /// Releases what a viewer already removed from `viewers` held: its frame
  /// budget, and its waiting window commands fail.
  func tearDown(_ viewer: Viewer) {
    for slot in viewer.frames.values { releaseBudget(slot) }
    forgetRowVersions(viewer.workspace, of: viewer.attachment)
    clientViewers.removeValue(forKey: viewer.client)
    failWindowCommands(
      viewer.windowCommands.values.flatMap(\.waiting),
      MuxError(.notAttached),
    )
  }

  /// Fails window commands already taken from their queue. A reply only
  /// queues its send, so this never re-enters viewer state; one pane's
  /// commands fail in the order they were queued.
  func failWindowCommands(
    _ commands: [WaitingWindowCommand],
    _ error: MuxError,
  ) { for command in commands { command.reply(.failure(error)) } }

  /// Drops `pane`'s window from a viewer (unsubscribed, or gone from the
  /// layout): its frame budget and notices go, and its waiting window
  /// commands fail (one in progress replies itself). Ready keeps the
  /// pane's resize floor; `arm` trims the rest, and a pane leaving the
  /// layout is forgotten by the caller.
  func forgetPane(_ pane: PaneID, in viewer: inout Viewer) {
    viewer.viewports[pane] = nil
    viewer.staleAnchorReported.remove(pane)
    if let slot = viewer.frames.removeValue(forKey: pane) {
      releaseBudget(slot)
    }
    failWindowCommands(
      viewer.windowCommands[pane]?.takeWaiting() ?? [],
      MuxError(.notFound, "pane"),
    )
  }

  func dropPaneFromViewers(_ pane: PaneID, workspace wsID: WorkspaceID) {
    guard var list = viewers[wsID] else { return }
    for index in list.indices {
      list[index].subscriptions.removeAll { $0 == pane }
      // Gone from the layout: Ready forgets it too.
      list[index].readiness.forget(pane)
      forgetPane(pane, in: &list[index])
    }
    viewers[wsID] = list
  }

  /// Observers together hold at most this much of the shared budget (plus
  /// one capture), so stalled observers cannot starve a controller.
  var viewerFrameBudget: Int { limits.pendingFrameBudget / 4 }

  /// Frame bytes all observers hold (in flight, queued or being captured).
  var viewerFrameBytes: Int {
    viewers.values.reduce(0) { total, list in
      list.reduce(total) { $0 + $1.heldFrameBytes }
    }
  }

  /// Publishes Ready wherever it is now due in the workspace. Readiness
  /// is derived on publish, so callers only report that something changed.
  func recheckReady(_ wsID: WorkspaceID) {
    publishControllerReady(wsID)
    // A failed send can drop a viewer, so look each one up afresh.
    for client in (viewers[wsID] ?? []).map(\.client) {
      publishViewerReady(client, in: wsID)
    }
  }

  func publishControllerReady(_ wsID: WorkspaceID) {
    guard let lease = leases[wsID],
      let frames = readyFrames(
        lease.readiness,
        subscriptions: lease.subscriptions,
        workspace: wsID,
        viewport: {
          self.panes[$0]?.runtime.currentViewport.load(ordering: .acquiring)
            ?? 0
        },
      )
    else { return }
    leases[wsID]?.readiness.sent = true
    sendReady(frames, attachment: lease.attachment, to: lease.client)
  }

  func publishViewerReady(_ client: UUID, in wsID: WorkspaceID) {
    guard var viewer = viewer(client, in: wsID),
      let frames = readyFrames(
        viewer.readiness,
        subscriptions: viewer.subscriptions,
        workspace: wsID,
        viewport: { viewer.viewports[$0]?.revision ?? 0 },
      )
    else { return }
    viewer.readiness.sent = true
    store(viewer)
    sendReady(frames, attachment: viewer.attachment, to: client)
  }

  /// Ready's initial frames once every subscribed visible pane that has
  /// not failed is installed. Nil while waiting, and while no visible
  /// pane is subscribed (the client has not named what it shows yet).
  /// `viewport` is the pane's current window revision: a frame of an
  /// older window (scrolled, searched or moved since) does not count.
  func readyFrames(
    _ readiness: Readiness,
    subscriptions: [PaneID],
    workspace wsID: WorkspaceID,
    viewport: (PaneID) -> UInt64,
  ) -> [ReadyNotice.PaneRevision]? {
    guard readiness.enabled, readiness.armed, !readiness.sent,
      let ws = workspaces.first(where: { $0.id == wsID })
    else { return nil }
    let visible = visiblePaneIDs(ws)
    let shown = Set(subscriptions).intersection(visible)
    if shown.isEmpty, !visible.isEmpty { return nil }
    var frames: [ReadyNotice.PaneRevision] = []
    for pane in shown.subtracting(readiness.failed) {
      guard let installed = readiness.installed[pane],
        installed.viewport == viewport(pane)
      else { return nil }
      frames.append(
        ReadyNotice.PaneRevision(
          pane: pane,
          frameRevision: installed.frame,
          geometryRevision: installed.geometry,
        )
      )
    }
    return frames.sorted {
      $0.pane.rawValue.uuidString < $1.pane.rawValue.uuidString
    }
  }

  func sendReady(
    _ frames: [ReadyNotice.PaneRevision],
    attachment: AttachmentID,
    to client: UUID,
  ) {
    send(
      .event(
        .ready(
          ReadyNotice(
            attachment: attachment,
            server: instance,
            initialFrames: frames,
          )
        )
      ),
      to: client,
    )
  }

  func viewerSubscribed(_ wsID: WorkspaceID, pane: PaneID) -> Bool {
    viewers[wsID]?.contains { $0.frames[pane] != nil } ?? false
  }

  func markViewersDirty(_ wsID: WorkspaceID, pane: PaneID) {
    guard let count = viewers[wsID]?.count else { return }
    for index in 0 ..< count {
      viewers[wsID]?[index].frames[pane]?.dirty = true
    }
  }

  func visiblePaneIDs(_ ws: Workspace) -> Set<PaneID> {
    guard let tab = ws.tabs.first(where: { $0.id == ws.activeTab }) else {
      return []
    }
    return Set(tab.visiblePanes)
  }

  /// A viewer's window for `pane` moved somewhere usable. Its stale-anchor
  /// notice and failure clear, and a late failure of a capture of the old
  /// window cannot mark the pane failed again.
  func recover(_ pane: PaneID, in viewer: inout Viewer) {
    viewer.staleAnchorReported.remove(pane)
    viewer.readiness.retry(pane)
    viewer.frames[pane]?.supersededThrough = nextCapture
    viewer.frames[pane]?.dirty = true
  }

  func setControllerViewport(
    _ request: ViewportRequest,
    workspace leased: WorkspaceID,
    reply: @escaping Reply,
  ) {
    // The controller's display size is its PTY geometry.
    guard request.rows == nil, request.columns == nil else {
      reply(
        .failure(
          MuxError(.invalidRequest, "a controller is sized by setGeometry")
        )
      )
      return
    }
    guard let runtime = attachedRuntime(request.pane, in: leased) else {
      reply(.failure(MuxError(.notFound, "pane")))
      return
    }
    if let error = viewportAnchorError(request) {
      return reply(.failure(error))
    }
    runtime.setViewport(
      followTail: request.followTail,
      historyGeneration: request.historyGeneration,
      anchorRow: request.anchorRow,
    ) { error in reply(error.map { .failure($0) } ?? .success(.ok)) }
  }

  /// Nil when the display size is absent or within the frame limits.
  /// A size is display-only: it never resizes the PTY.
  func displaySize(_ request: ViewportRequest) -> MuxError? {
    guard request.rows != nil || request.columns != nil else { return nil }
    guard let rows = request.rows, let columns = request.columns,
      limits.cellCount(columns: columns, rows: rows) != nil
    else { return MuxError(.invalidRequest, "viewport size") }
    return nil
  }

  func handleViewer(
    _ command: MuxCommand,
    workspace wsID: WorkspaceID,
    client: UUID,
    reply: @escaping Reply,
  ) {
    let fail = { (error: MuxError) in reply(.failure(error)) }
    switch command {
    case let .setSubscriptions(list):
      if let error = setViewerSubscriptions(
        list,
        client: client,
        workspace: wsID
      ) {
        fail(error)
      } else {
        reply(.success(.ok))
      }
    // Validation runs in the queue too, so replies keep the order sent
    // (a command refused on arrival, as unattached, unsubscribed or over
    // the limit, replies at once).
    case let .setViewport(request):
      inWindowOrder(client, wsID, request.pane, reply) {
        service,
        window,
        reply in
        if let error = service.viewerRequestError(request) {
          return reply(.failure(error))
        }
        service.moveViewer(
          request,
          client: client,
          window: window,
          workspace: wsID,
          reply: reply,
        )
      }
    case let .scroll(pane, request):
      inWindowOrder(client, wsID, pane, reply) { service, window, reply in
        if let error = service.scrollError(request) {
          return reply(.failure(error))
        }
        service.scrollViewer(
          pane,
          request,
          client: client,
          window: window,
          workspace: wsID,
          reply: reply,
        )
      }
    case let .search(pane, query):
      inWindowOrder(client, wsID, pane, reply) { service, window, reply in
        if let error = service.searchQueryError(query) {
          return reply(.failure(error))
        }
        service.searchViewer(
          pane,
          query: query,
          step: nil,
          client: client,
          window: window,
          workspace: wsID,
          reply: reply,
        )
      }
    case let .searchStep(pane, forward):
      inWindowOrder(client, wsID, pane, reply) { service, window, reply in
        service.searchViewer(
          pane,
          query: nil,
          step: forward,
          client: client,
          window: window,
          workspace: wsID,
          reply: reply,
        )
      }
    case let .endSearch(pane):
      inWindowOrder(client, wsID, pane, reply) { service, window, reply in
        service.endViewerSearch(
          pane,
          client: client,
          window: window,
          workspace: wsID,
          reply: reply,
        )
      }
    case let .copySelection(request):
      copySelection(
        request,
        attachment: viewers[wsID]?.first { $0.client == client }?.attachment,
        workspace: wsID,
        reply: reply
      )
    default: reply(.success(.ok))
    }
  }

  /// Runs an observer's window commands for `pane` one at a time, in
  /// order: each starts from the window the previous one left, so a step
  /// continues the search before it and a scroll moves from its match.
  /// Commands are queued per viewer and pane (`Viewer.windowCommands`), so
  /// a resubscribe joins the same queue. One runs only while the window it
  /// was sent for is current (window ids never repeat, so an
  /// unsubscribe, a resubscribe or a reattach ends it); `op` gets that
  /// window as it is then and replies exactly once, on this queue.
  func inWindowOrder(
    _ client: UUID,
    _ wsID: WorkspaceID,
    _ pane: PaneID,
    _ reply: @escaping Reply,
    _ op:
      @escaping @Sendable (isolated MuxService, ViewerViewport, @escaping Reply)
      -> Void,
  ) {
    // Runs the command if its window is still current when its turn comes.
    func turn(
      windowID: UInt64,
      attachment: AttachmentID
    ) -> (isolated MuxService) -> Void {
      let finish: Reply = { [weak self] result in
        reply(result)
        self?
          .onQueue { $0.windowCommandFinished(client, wsID, attachment, pane) }
      }
      return { service in
        guard let viewer = service.viewer(client, in: wsID) else {
          return finish(.failure(MuxError(.notAttached)))
        }
        guard let current = viewer.viewports[pane], current.id == windowID
        else { return finish(.failure(MuxError(.notFound, "pane"))) }
        op(service, current, finish)
      }
    }
    enum Turn {
      case now((isolated MuxService) -> Void)
      case waiting
      case refused(MuxError)
    }
    let next =
      withViewer(client, in: wsID) { viewer -> Turn in
        // The window the command was sent for. Ids never repeat, so a
        // later subscription or attachment has a different one.
        guard let window = viewer.viewports[pane]?.id else {
          return .refused(MuxError(.notFound, "pane"))
        }
        // One queue per viewer and pane: a resubscribe does not start a
        // fresh one beside commands still waiting.
        var queue = viewer.windowCommands[pane] ?? WindowCommandQueue()
        if queue.running, queue.waiting.count >= Self.maxWaitingCommands {
          return .refused(MuxError(.resourceLimit, "too many window commands"))
        }
        defer { viewer.windowCommands[pane] = queue }
        let run = turn(windowID: window, attachment: viewer.attachment)
        guard queue.running else {
          queue.running = true
          return .now(run)
        }
        queue.waiting.append(WaitingWindowCommand(run: run, reply: reply))
        return .waiting
      } ?? .refused(MuxError(.notAttached))
    switch next {
    case let .now(run): run(self)
    case .waiting: break
    case let .refused(error): reply(.failure(error))
    }
  }

  /// Window commands one observer pane may have waiting.
  static let maxWaitingCommands = 32

  private func windowCommandFinished(
    _ client: UUID,
    _ wsID: WorkspaceID,
    _ attachment: AttachmentID,
    _ pane: PaneID,
  ) {
    let next = withViewer(client, in: wsID) { viewer -> WaitingWindowCommand? in
      guard viewer.attachment == attachment,
        var queue = viewer.windowCommands[pane]
      else { return nil }
      guard !queue.waiting.isEmpty else {
        viewer.windowCommands[pane] = nil
        return nil
      }
      let next = queue.waiting.removeFirst()
      viewer.windowCommands[pane] = queue
      return next
    }
    next?.run(self)
  }

  /// Changes the stored viewer in place, by client. Whole-viewer writes
  /// (`store`), window-command queues and settling a frame (captured and
  /// placed, acknowledged) go through here; the pump marks captures
  /// through the index it is iterating, within one call.
  @discardableResult
  func withViewer<T>(
    _ client: UUID,
    in wsID: WorkspaceID,
    _ body: (inout Viewer) -> T,
  ) -> T? {
    guard let index = viewers[wsID]?.firstIndex(where: { $0.client == client })
    else { return nil }
    return body(&viewers[wsID]![index])
  }
  /// `withViewer` for a body with an optional result: nil when the viewer
  /// or the result is missing.
  @discardableResult
  func withViewer<T>(
    _ client: UUID,
    in wsID: WorkspaceID,
    _ body: (inout Viewer) -> T?,
  ) -> T? {
    guard let index = viewers[wsID]?.firstIndex(where: { $0.client == client })
    else { return nil }
    return body(&viewers[wsID]![index])
  }

  func endViewerSearch(
    _ pane: PaneID,
    client: UUID,
    window: ViewerViewport,
    workspace wsID: WorkspaceID,
    reply: @escaping Reply,
  ) {
    // Nothing to end: the window and its frames stand.
    guard window.searchQuery != nil else {
      return reply(.success(.search(.empty)))
    }
    commitWindow(
      window.id,
      pane: pane,
      client: client,
      workspace: wsID,
      reply: reply,
      success: .search(.empty),
    ) {
      $0.searchQuery = nil
      $0.searchSelected = nil
    }
  }

  /// Stores a changed observer window as a new revision (frames of the
  /// old one stop counting), clears its earlier failure, and replies.
  func commitWindow(
    _ windowID: UInt64,
    pane: PaneID,
    client: UUID,
    workspace wsID: WorkspaceID,
    reply: Reply,
    success: MuxReply,
    change: (inout ViewerViewport) -> Void,
  ) {
    guard var viewer = viewer(client, in: wsID) else {
      return reply(.failure(MuxError(.notAttached)))
    }
    guard var window = viewer.viewports[pane], window.id == windowID else {
      return reply(.failure(MuxError(.notFound, "pane")))
    }
    change(&window)
    window.revision &+= 1
    viewer.viewports[pane] = window
    recover(pane, in: &viewer)
    store(viewer)
    reply(.success(success))
    pump()
  }

  func viewer(_ client: UUID, in wsID: WorkspaceID) -> Viewer? {
    viewers[wsID]?.first { $0.client == client }
  }

  func store(_ viewer: Viewer) {
    withViewer(viewer.client, in: viewer.workspace) { $0 = viewer }
  }

  func setViewerSubscriptions(
    _ list: [PaneID],
    client: UUID,
    workspace wsID: WorkspaceID,
  ) -> MuxError? {
    guard var viewer = viewer(client, in: wsID),
      let ws = workspaces.first(where: { $0.id == wsID })
    else { return MuxError(.notAttached) }
    let members = Set(ws.allPanes)
    guard list.count <= limits.maxPanes, Set(list).count == list.count,
      list.allSatisfy(members.contains)
    else { return MuxError(.invalidRequest, "subscription list") }
    let kept = Set(list)
    for pane in Array(viewer.frames.keys) where !kept.contains(pane) {
      forgetPane(pane, in: &viewer)
    }
    for pane in list {
      if viewer.frames[pane] == nil { viewer.frames[pane] = FrameSlot() }
      if viewer.viewports[pane] == nil {
        nextWindowID &+= 1
        viewer.viewports[pane] = ViewerViewport(
          id: nextWindowID,
          followTail: true,
          historyGeneration: 0,
          anchorRow: nil,
        )
      }
    }
    viewer.subscriptions = list
    viewer.readiness.arm(list)
    store(viewer)
    publishViewerReady(client, in: wsID)
    pump()
    return nil
  }

  /// A viewport follows the tail or names an anchor row.
  func viewportAnchorError(_ request: ViewportRequest) -> MuxError? {
    request.followTail || request.anchorRow != nil
      ? nil : MuxError(.invalidRequest, "viewport anchor")
  }

  /// An observer viewport request that can never resolve.
  func viewerRequestError(_ request: ViewportRequest) -> MuxError? {
    displaySize(request) ?? viewportAnchorError(request)
  }

  /// Applies a resolved move or search to the observer window it was
  /// issued for, then replies `success`. A window replaced meanwhile
  /// (unsubscribed, resubscribed or reattached: ids never repeat) is gone.
  func applyResolved(
    _ resolved: PaneRuntime.ResolvedViewport,
    of request: ViewportRequest,
    window windowID: UInt64,
    client: UUID,
    workspace wsID: WorkspaceID,
    reply: Reply,
    success: MuxReply,
    update: (inout ViewerViewport) -> Void = { _ in },
  ) {
    commitWindow(
      windowID,
      pane: request.pane,
      client: client,
      workspace: wsID,
      reply: reply,
      success: success,
    ) {
      $0.followTail = resolved.followTail
      $0.historyGeneration = resolved.historyGeneration
      $0.anchorRow = resolved.anchorRow
      $0.rows = request.rows
      $0.columns = request.columns
      update(&$0)
    }
  }

  /// `request` is valid (`viewerRequestError`).
  func moveViewer(
    _ request: ViewportRequest,
    scroll: ScrollRequest? = nil,
    client: UUID,
    window: ViewerViewport,
    workspace wsID: WorkspaceID,
    reply: @escaping Reply,
  ) {
    guard let runtime = panes[request.pane]?.runtime else {
      return reply(.failure(MuxError(.notFound, "pane")))
    }
    let windowID = window.id
    runtime.resolveViewer(
      request,
      searchQuery: nil,
      searchStep: nil,
      scroll: scroll,
    ) { [weak self] result in
      self?
        .onQueue { service in
          switch result {
          case let .failure(error): reply(.failure(error))
          case let .success(resolved):
            service.applyResolved(
              resolved,
              of: request,
              window: windowID,
              client: client,
              workspace: wsID,
              reply: reply,
              success: .ok,
            )
          }
        }
    }
  }

  /// `.bottom` and `.top` name an absolute window and do not depend on
  /// the current anchor, so they recover a viewer whose anchor went
  /// stale. Relative scrolls start from the viewer's window and stop at
  /// the history edges.
  func scrollViewer(
    _ pane: PaneID,
    _ request: ScrollRequest,
    client: UUID,
    window: ViewerViewport,
    workspace wsID: WorkspaceID,
    reply: @escaping Reply,
  ) {
    var viewport = window.request(pane)
    var relative: ScrollRequest?
    switch request {
    case .bottom:
      viewport.followTail = true
      viewport.anchorRow = nil
    case let .top(address):
      viewport.followTail = false
      viewport.anchorRow = address.row
      viewport.historyGeneration = address.generation
    case .lines, .pages, .oldest, .prompt: relative = request
    }
    moveViewer(
      viewport,
      scroll: relative,
      client: client,
      window: window,
      workspace: wsID,
      reply: reply,
    )
  }

  func searchViewer(
    _ pane: PaneID,
    query: String?,
    step: Bool?,
    client: UUID,
    window: ViewerViewport,
    workspace wsID: WorkspaceID,
    reply: @escaping Reply,
  ) {
    guard let runtime = panes[pane]?.runtime else {
      return reply(.failure(MuxError(.notFound, "pane")))
    }
    // A step needs a search to continue.
    guard let existing = query ?? window.searchQuery else {
      return reply(.failure(MuxError(.invalidRequest, "search query")))
    }
    // Only a step continues from the stored selection.
    let selected = query == nil ? window.searchSelected : nil
    let windowID = window.id
    let request = window.request(pane)
    runtime.resolveViewer(
      request,
      searchQuery: existing,
      searchStep: step,
      searchSelected: selected,
    ) { [weak self] result in
      self?
        .onQueue { service in
          switch result {
          case let .failure(error): reply(.failure(error))
          case let .success(resolved):
            service.applyResolved(
              resolved,
              of: request,
              window: windowID,
              client: client,
              workspace: wsID,
              reply: reply,
              success: .search(resolved.search ?? .empty),
            ) {
              $0.searchQuery = existing
              $0.searchSelected = resolved.selectedMatch
            }
          }
        }
    }
  }

  /// Observers are served after controllers, and only while a controller
  /// is not waiting on the shared frame budget. Like workspaces, observers
  /// take turns going first so one cannot starve the rest of the budget.
  func pumpViewers(now: UInt64) -> UInt64? {
    guard !viewers.isEmpty, !controllerWaitingForBudget(now: now) else {
      return nil
    }
    let order = workspaces.flatMap { ws in
      (viewers[ws.id] ?? []).indices.map { (ws.id, $0) }
    }
    let n = order.count
    let start = n == 0 ? 0 : viewerCursor % n
    let share = viewerFrameBudget / max(1, n)
    // Summed once per pump; pumpViewer adds what it reserves.
    var held = viewerFrameBytes
    var wake: UInt64?
    var served: Int?
    for k in 0 ..< n {
      let i = (start + k) % n
      let (due, started) = pumpViewer(
        order[i].0,
        index: order[i].1,
        now: now,
        held: &held,
        share: share,
      )
      if started, served == nil { served = i }
      if let due { wake = min(wake ?? due, due) }
    }
    viewerCursor = n == 0 ? 0 : ((served ?? start) + 1) % n
    return wake
  }

  func controllerWaitingForBudget(now: UInt64) -> Bool {
    let interval = limits.frameIntervalNanoseconds
    for lease in leases.values {
      for slot in lease.frames.values {
        guard slot.dirty, slot.capture == nil, slot.inflight == nil else {
          continue
        }
        if slot.lastSent != 0, now &- slot.lastSent < interval { continue }
        return inflightFrameBytes + reservedFrameBytes
          >= limits.pendingFrameBudget
      }
    }
    return false
  }

  /// The earliest throttled pane's due time, and whether a capture began.
  /// `held` is every observer's frame bytes; one observer may hold up to
  /// `share` of `viewerFrameBudget`, so a stalled one cannot block the rest.
  func pumpViewer(
    _ wsID: WorkspaceID,
    index: Int,
    now: UInt64,
    held: inout Int,
    share: Int,
  ) -> (UInt64?, Bool) {
    guard let viewer = viewers[wsID]?[safe: index],
      !viewer.subscriptions.isEmpty
    else { return (nil, false) }
    var mine = viewer.heldFrameBytes
    let interval = limits.frameIntervalNanoseconds
    var wake: UInt64?
    var started = false
    let order = viewer.subscriptions
    let count = order.count
    let first = viewer.paneCursor % count
    viewers[wsID]?[index].paneCursor = (first + 1) % count
    for step in 0 ..< count {
      let pane = order[(first + step) % count]
      guard let slot = viewers[wsID]?[index].frames[pane], slot.dirty,
        slot.capture == nil, let record = panes[pane]
      else { continue }
      guard let capture = viewers[wsID]?[index].viewports[pane] else {
        assertionFailure("subscribed pane without a window")
        continue
      }
      let stamp = max(slot.lastSent, slot.lastCapture)
      if stamp != 0, now &- stamp < interval {
        let due = stamp + interval
        wake = min(wake ?? due, due)
        continue
      }
      // One in flight plus one replaceable newest frame.
      if slot.inflight != nil, slot.queued != nil { continue }
      guard inflightFrameBytes + reservedFrameBytes < limits.pendingFrameBudget,
        held < viewerFrameBudget, mine < share
      else { return (wake, started) }
      started = true
      nextCapture &+= 1
      let token = nextCapture
      let estimate = captureEstimate(record)
      reservedFrameBytes += estimate
      held += estimate
      mine += estimate
      viewers[wsID]?[index].frames[pane]?.dirty = false
      viewers[wsID]?[index].frames[pane]?.capture = token
      viewers[wsID]?[index].frames[pane]?.reserved = estimate
      viewers[wsID]?[index].frames[pane]?.lastCapture = now
      let attachment = viewer.attachment
      let client = viewer.client
      let layoutRevision =
        workspaces.first { $0.id == wsID }?.layoutRevision ?? 0
      record.runtime.captureFrame(
        server: instance,
        attachment: attachment,
        layoutRevision: layoutRevision,
        viewport: capture,
        encoding: clients[client]?.frameEncoding ?? PaneRuntime.FrameEncoding(),
        baseline: slot.baseline,
      ) { [weak self] result in
        self?
          .onQueue {
            $0.viewerFrameCaptured(
              pane,
              workspace: wsID,
              client: client,
              token: token,
              result,
            )
          }
      }
    }
    return (wake, started)
  }

  func viewerFrameCaptured(
    _ pane: PaneID,
    workspace wsID: WorkspaceID,
    client: UUID,
    token: UInt64,
    _ result: Result<PaneRuntime.CapturedFrame, MuxError>,
  ) {
    enum Outcome {
      case send(SMXChannel, QueuedFrame)
      case queued(QueuedFrame, replacing: QueuedFrame?)
      /// Nothing more to send or report.
      case settled
      case failed(MuxError, notify: Bool, newlyFailed: Bool)
    }
    // Settles the capture and decides what follows: a frame is sent now or
    // becomes the replaceable newest behind the one in flight; a failure is
    // recorded before any notice goes out (a failed send can drop this
    // viewer). Nil when the capture belongs to an earlier subscription.
    var reserved = 0
    let outcome = withViewer(client, in: wsID) { viewer -> Outcome? in
      guard let slot = viewer.frames[pane], slot.capture == token else {
        return nil
      }
      reserved = slot.reserved
      viewer.frames[pane]?.capture = nil
      viewer.frames[pane]?.reserved = 0
      switch result {
      case let .success(captured):
        // Only XPC clients observe, and a lost client releases its viewer
        // in the same turn.
        guard case let .xpc(channel)? = clients[client]?.transport else {
          assertionFailure("observer without an XPC transport")
          return .settled
        }
        let frame = QueuedFrame(frame: captured.sent, data: captured.data)
        if slot.inflight == nil {
          viewer.frames[pane]?.sent(frame.frame)
          return .send(channel, frame)
        }
        viewer.frames[pane]?.queued = frame
        return .queued(frame, replacing: slot.queued)
      case .failure where token <= slot.supersededThrough:
        // The window it captured has moved: recapture, report nothing.
        viewer.frames[pane]?.dirty = true
        return .settled
      case let .failure(error):
        let newlyFailed = viewer.readiness.failed.insert(pane).inserted
        let notify =
          error.code != .historyUnavailable
          || viewer.staleAnchorReported.insert(pane).inserted
        return .failed(error, notify: notify, newlyFailed: newlyFailed)
      }
    }
    guard let outcome else { return }
    reservedFrameBytes -= reserved
    switch outcome {
    case let .send(channel, frame):
      channel.send(frame.data)
      inflightFrameBytes += frame.frame.bytes
    case let .queued(frame, replaced):
      inflightFrameBytes += frame.frame.bytes - (replaced?.frame.bytes ?? 0)
    case .settled: break
    case let .failed(error, notify, newlyFailed):
      if notify { send(.event(.frameUnavailable(pane, error)), to: client) }
      // Ready follows the notice that explains the missing pane.
      if newlyFailed { publishViewerReady(client, in: wsID) }
    }
    pump()
  }

  func acknowledgeViewer(
    _ pane: PaneID,
    _ revision: UInt64,
    attachment: AttachmentID,
    from id: UUID,
  ) {
    guard let wsID = clientViewers[id], let client = clients[id],
      case let .xpc(channel) = client.transport
    else { return }
    // Settles the acknowledged frame, promotes the queued one (sent below),
    // and records it for Ready.
    let ack = withViewer(id, in: wsID) {
      viewer -> (acked: SentFrame, next: QueuedFrame?, ready: Bool)? in
      guard viewer.attachment == attachment, let slot = viewer.frames[pane],
        let inflight = slot.inflight, inflight.revision == revision
      else { return nil }
      viewer.frames[pane]?.inflight = nil
      viewer.frames[pane]?.baseline = inflight.baseline
      if let queued = slot.queued {
        viewer.frames[pane]?.queued = nil
        viewer.frames[pane]?.sent(queued.frame)
      }
      let window = viewer.viewports[pane]?.revision ?? 0
      let ready = viewer.readiness.install(pane, inflight, window: window)
      return (inflight, slot.queued, ready)
    }
    guard let ack else { return }
    inflightFrameBytes -= ack.acked.bytes
    if let next = ack.next { channel.send(next.data) }
    // Last: publishing Ready can drop this viewer if its send fails.
    if ack.ready { publishViewerReady(id, in: wsID) }
    pump()
  }

}

extension Array {
  fileprivate subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
