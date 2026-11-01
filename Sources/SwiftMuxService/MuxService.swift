import Darwin
import Dispatch
import Foundation
import MuxAttention
import os
import SwiftMuxProtocol

/// The persistent session service: workspace graph, stable identities,
/// one interactive lease per workspace, layout revisions and frame
/// delivery.
///
/// Isolated to one serial queue, which is also every XPC connection's
/// queue, so messages from a client are handled in arrival order.
public actor MuxService {
  public nonisolated let queue: DispatchSerialQueue
  public nonisolated var unownedExecutor: UnownedSerialExecutor {
    queue.asUnownedSerialExecutor()
  }

  public nonisolated let instance = ServerInstanceID()
  nonisolated let configuration: MuxServiceConfiguration
  nonisolated let launcher: PaneLauncher
  private let log = Logger(
    subsystem: "com.chr33s.swiftty.swiftmux",
    category: "service",
  )
  private let startedAt = Date()

  var automation = ServiceAutomation()
  var workspaces: [Workspace] = []
  var panes: [PaneID: PaneRecord] = [:]
  var clients: [UUID: Client] = [:]
  /// At most one writer lease per workspace and per client.
  var leases: [WorkspaceID: Lease] = [:]
  var clientLeases: [UUID: WorkspaceID] = [:]
  /// Read-only viewers. At most `SMX.maxObservers` per workspace.
  var viewers: [WorkspaceID: [Viewer]] = [:]
  var clientViewers: [UUID: WorkspaceID] = [:]
  /// Last observer window id issued (`ViewerViewport.id`).
  var nextWindowID: UInt64 = 0
  /// Last granted lease generation per workspace; `takeover` names it.
  private var leaseGenerations: [WorkspaceID: UInt64] = [:]
  var pendingLaunches = 0
  var pendingHistoryBytes = 0
  /// Latest frontend theme, applied to every pane and to new ones.
  var theme: MuxTheme?
  var quiescing = false
  private var quiesceOwner: UUID?
  var exitRequested = false
  var onExitReady: (@Sendable () -> Void)?
  /// Advances on every `endAllWorkspaces`; a launch begun before one
  /// never joins the graph.
  var endAllEpoch: UInt64 = 0
  /// Frame bytes sent and not yet acknowledged.
  var inflightFrameBytes = 0
  /// Estimates held by captures in progress, so concurrent captures
  /// cannot overrun `pendingFrameBudget` together.
  var reservedFrameBytes = 0
  var pumpScheduled = false
  /// Leases in grant order; `pump` rotates through them.
  var leaseOrder: [WorkspaceID] = []
  var workspaceCursor = 0
  /// A workspace-list publish is queued for the end of this turn.
  var workspacesPublishScheduled = false
  /// Rotates which observer `pumpViewers` serves first.
  var viewerCursor = 0
  var nextCapture: UInt64 = 0
  var idleWork: DispatchWorkItem?
  private var listeners: [SMXListener] = []
  /// Called once the empty-state barrier holds for `idleExitDelay`.
  private var onIdle: (@Sendable () -> Void)?
  /// OSC 7501 attention inbox (spec.inbox.md §3).
  private var attention: InboxHub
  private var snoozeTimer: InboxSnoozeTimer?

  var limits: MuxLimits { configuration.limits }

  public init(configuration: MuxServiceConfiguration) throws(MuxError) {
    try configuration.limits.validateForService()
    self.configuration = configuration
    queue = DispatchSerialQueue(label: "swiftmux.service", qos: .userInitiated)
    attention = InboxHub(serviceEpoch: instance, limits: configuration.limits)
    launcher = PaneLauncher(
      launcherPath: configuration.launcherPath,
      innerTerm: configuration.innerTerm,
      terminfoDirectory: configuration.terminfoDirectory,
    )
  }

  // MARK: Listening

  /// Accepts connections on a launchd Mach service.
  public nonisolated func listen(machService name: String) {
    let listener = SMXListener(machService: name, queue: queue)
    start(listener)
  }

  /// Accepts connections on an anonymous endpoint (tests, in-process).
  public nonisolated func listenAnonymously() -> SMXEndpoint {
    let listener = SMXListener(anonymousOn: queue)
    start(listener)
    return listener.endpoint
  }

  private nonisolated func start(_ listener: SMXListener) {
    listener.activate(connectionQueue: queue) { [weak self] channel in
      guard let self else { return }
      self.queue.async { self.assumeIsolated { $0.accept(channel) } }
    }
    queue.async { self.assumeIsolated { $0.listeners.append(listener) } }
  }

  public nonisolated func setIdleHandler(
    _ handler: @escaping @Sendable () -> Void,
  ) {
    queue.async {
      self.assumeIsolated {
        $0.onIdle = handler
        $0.checkIdle()
      }
    }
  }

  nonisolated func onQueue(
    _ body: @escaping @Sendable (isolated MuxService) -> Void,
  ) { queue.async { self.assumeIsolated(body) } }

  // MARK: Connections

  private func accept(_ channel: SMXChannel) {
    // OS-provided peer identity, never a claimed pid or bundle id.
    guard channel.peerEUID == geteuid() else {
      log.error("rejecting peer with euid \(channel.peerEUID)")
      channel.cancel()
      return
    }
    if let requirement = configuration.peerRequirement,
      !channel.requirePeer(codeSigning: requirement)
    {
      channel.cancel()
      return
    }
    let client = Client(channel: channel)
    register(client)
    let id = client.id
    let recordLimit = SMXCodec.clientRecordLimit(limits)
    channel.activate(
      recordLimit: { recordLimit },
      { [weak self] event in
        guard let self else { return }
        self.assumeIsolated { service in
          switch event {
          case let .message(data): service.receive(data, from: id)
          case let .closed(reason): service.disconnected(id, reason: reason)
          }
        }
      },
    )
  }

  func register(_ client: Client) {
    clients[client.id] = client
    idleWork?.cancel()
  }

  func disconnected(_ id: UUID, reason: String) {
    guard clients.removeValue(forKey: id) != nil else { return }
    if quiesceOwner == id {
      quiesceOwner = nil
      // A lost updater cannot leave admission frozen. Process shutdown
      // remains irreversible even if its former update owner disconnects.
      if !exitRequested { quiescing = false }
    }
    attention.unsubscribe(id)
    automation.subscribers.remove(id)
    if let ws = clientLeases[id] {
      // Connection loss: nobody owns the remaining input any more, so it
      // is fenced like a takeover. Observers and PTYs stay.
      releaseLease(
        ws,
        notify: false,
        fence: true,
        reason: "connection lost: \(reason)",
      )
    } else if clientViewers[id] != nil {
      releaseViewer(id, notify: false, reason: "connection lost: \(reason)")
    }
    checkIdle()
  }

  func send(_ message: ServerMessage, to id: UUID) {
    guard let client = clients[id] else { return }
    switch client.transport {
    case let .xpc(channel):
      do {
        try channel.send(
          SMXCodec.encode(message, limit: SMXCodec.serverRecordLimit(limits)),
        )
      } catch {
        log.error("encode failed: \(error.description)")
        // A reply must settle its request even if the payload cannot fit.
        // Other records cannot be omitted without losing stream state.
        if case let .reply(requestID, _) = message,
          let failure = try? SMXCodec.encode(
            ServerMessage.reply(id: requestID, result: .failure(error)),
            limit: SMXCodec.serverRecordLimit(limits),
          )
        {
          channel.send(failure)
        } else {
          client.cancel()
          disconnected(id, reason: "server record could not be encoded")
        }
      }
    case let .local(sink): sink.onMessage(message)
    }
  }

  private func receive(_ data: Data, from id: UUID) {
    guard clients[id] != nil else { return }
    let message: ClientMessage
    do {
      message = try SMXCodec.decode(
        ClientMessage.self,
        from: data,
        limit: SMXCodec.clientRecordLimit(limits),
      )
    } catch {
      send(.rejected(error), to: id)
      return
    }
    receive(message, from: id)
  }

  /// In-process requests may carry admission constraints. Validate on
  /// this actor before a queued command can change authoritative state.
  func receiveRequest(
    id requestID: UInt64,
    command: MuxCommand,
    from client: UUID,
    expiresAt: ContinuousClock.Instant?,
    isAdmitted: (@Sendable () -> Bool)?,
  ) {
    if let expiresAt, ContinuousClock.now >= expiresAt {
      send(
        .reply(
          id: requestID,
          result: .failure(MuxError(.unauthorized, "request deadline expired")),
        ),
        to: client,
      )
      return
    }
    if let isAdmitted, !isAdmitted() {
      send(
        .reply(
          id: requestID,
          result: .failure(
            MuxError(.unauthorized, "request no longer admitted"),
          ),
        ),
        to: client,
      )
      return
    }
    receive(.request(id: requestID, command: command), from: client)
  }

  func receive(_ message: ClientMessage, from id: UUID) {
    guard let client = clients[id] else { return }
    guard let hello = client.hello else {
      guard case let .hello(hello) = message else {
        send(.rejected(MuxError(.invalidRequest, "expected hello")), to: id)
        client.cancel()
        return
      }
      handshake(hello, client: client)
      return
    }
    switch message {
    case .hello:
      send(.rejected(MuxError(.invalidRequest, "duplicate hello")), to: id)
    case let .request(requestID, command):
      handle(command, from: client, hello: hello) { [weak self] result in
        self?.onQueue { $0.send(.reply(id: requestID, result: result), to: id) }
      }
    case let .input(record): input(record, from: id)
    case let .frameAck(pane, revision, attachment):
      frameAck(pane, revision, attachment: attachment, from: id)
    case .inboxAck: inboxAcknowledged(by: id)
    }
  }

  private func handshake(_ hello: Hello, client: Client) {
    guard SMX.compatibleVersions.contains(hello.protocolVersion) else {
      send(
        .rejected(
          MuxError(
            .incompatibleVersion,
            "service speaks SMX/\(SMX.protocolVersion) (\(SMX.build)); client \(hello.build) speaks SMX/\(hello.protocolVersion)",
          ),
        ),
        to: client.id,
      )
      client.cancel()
      return
    }
    if hello.frontend == .terminal, hello.terminalProfile != SMX.terminalProfile
    {
      send(
        .rejected(
          MuxError(
            .invalidRequest,
            "unsupported terminal profile \(hello.terminalProfile ?? "none")",
          ),
        ),
        to: client.id,
      )
      client.cancel()
      return
    }
    client.hello = hello
    send(
      .welcome(
        Welcome(
          protocolVersion: SMX.protocolVersion,
          build: SMX.build,
          server: instance,
          acceptedProfile: hello.frontend == .terminal
            ? SMX.terminalProfile : nil,
          limits: limits,
          innerTerm: configuration.innerTerm,
          features: .supported,
        ),
      ),
      to: client.id,
    )
  }

  // MARK: Commands

  typealias Reply = @Sendable (MuxResult) -> Void

  private func handle(
    _ command: MuxCommand,
    from client: Client,
    hello: Hello,
    reply: @escaping Reply,
  ) {
    let fail = { (e: MuxError) in reply(.failure(e)) }
    if let refusal = admission(of: command, from: client) {
      return fail(refusal)
    }
    do throws(MuxError) {
      try dispatch(command, from: client, hello: hello, reply: reply)
    } catch { fail(error) }
  }

  /// `handle` after admission; a thrown error is the reply.
  private func dispatch(
    _ command: MuxCommand,
    from client: Client,
    hello: Hello,
    reply: @escaping Reply,
  ) throws(MuxError) {
    let ok = { reply(.success(.ok)) }
    let fail = { (e: MuxError) in reply(.failure(e)) }
    switch command {
    case let .subscribeAutomation(on):
      guard !client.remote, hello.frontend == .native else {
        return fail(
          MuxError(
            .unauthorized,
            "automation UI requires a local native client"
          )
        )
      }
      subscribeAutomation(client.id, enabled: on)
      ok()
    case .status: reply(.success(.status(status)))
    case .listWorkspaces: reply(.success(.workspaces(summaries)))
    case let .newWorkspace(request): newWorkspace(request, reply: reply)
    case let .endWorkspace(selector):
      let ws = try workspace(selector)
      endWorkspace(ws.id)
      ok()
    case let .renameWorkspace(selector, name):
      let i = try workspaceIndex(selector)
      guard validName(name) else { return fail(invalidName) }
      // Names select workspaces, so they stay unique (as on creation).
      guard
        !workspaces.contains(where: {
          $0.id != workspaces[i].id && $0.name == name
        })
      else {
        return fail(MuxError(.invalidRequest, "workspace \"\(name)\" exists"))
      }
      workspaces[i].name = name
      commitLayout(workspaces[i].id)
      ok()
    case .detachActive:
      // Update barrier and `swmux detach`: every holder is told.
      // A forced release fences like a takeover: another frontend may
      // attach next, so the holder's unwritten input must not run.
      for ws in Array(leases.keys) {
        releaseLease(
          ws,
          notify: true,
          fence: true,
          reason: "detached by request",
        )
      }
      for ws in Array(viewers.keys) {
        releaseViewers(in: ws, reason: "detached by request")
      }
      ok()
    case .endAllWorkspaces:
      quiescing = true
      endAllEpoch &+= 1
      for ws in workspaces { endWorkspace(ws.id) }
      ok()
    case let .attach(request):
      try attach(request, client: client, hello: hello, reply: reply)
    case let .takeover(selector, expected):
      try takeover(
        selector,
        expected: expected,
        client: client,
        hello: hello,
        reply: reply,
      )
    case .detach:
      if let ws = clientLeases[client.id] {
        releaseLease(ws, notify: false, reason: "detached")
      } else if clientViewers[client.id] != nil {
        releaseViewer(client.id, notify: false, reason: "detached")
      }
      ok()
    case let .switchWorkspace(selector):
      try switchWorkspace(selector, client: client, reply: reply)
    case let .observeWorkspaces(on):
      client.observesWorkspaces = on
      reply(.success(.workspaces(summaries)))
    case let .quiesce(on):
      guard !exitRequested else {
        return fail(MuxError(.quiescing, "service is shutting down"))
      }
      guard quiesceOwner == nil || quiesceOwner == client.id else {
        return fail(
          MuxError(.quiescing, "another connection owns the update barrier"),
        )
      }
      quiesceOwner = on ? client.id : nil
      quiescing = on
      ok()
    case let .setTheme(theme):
      guard theme.isValid else {
        return fail(MuxError(.invalidRequest, "theme"))
      }
      self.theme = theme
      for record in panes.values { record.runtime.setTheme(theme) }
      ok()
    case .subscribeInbox, .inbox, .locateAttention, .markSeen, .snooze,
      .markReviewed:
      handleAttention(command, client: client, reply: reply)
    default:
      if let ws = clientViewers[client.id] {
        handleViewer(command, workspace: ws, client: client.id, reply: reply)
        return
      }
      guard let ws = clientLeases[client.id] else {
        return fail(MuxError(.notAttached))
      }
      handleLeased(command, workspace: ws, client: client.id, reply: reply)
    }
  }

  private func attach(
    _ request: AttachRequest,
    client: Client,
    hello: Hello,
    reply: @escaping Reply,
  ) throws(MuxError) {
    let fail = { (e: MuxError) in reply(.failure(e)) }
    guard hello.frontend != .control else {
      return fail(
        MuxError(.invalidRequest, "control connections cannot attach"),
      )
    }
    guard !quiescing else {
      return fail(MuxError(.quiescing, "service is preparing to update"))
    }
    guard clientLeases[client.id] == nil, clientViewers[client.id] == nil else {
      return fail(MuxError(.alreadyAttached, "this connection is attached"))
    }
    let ws = try workspace(request.selector)
    if request.role == .observer {
      guard hello.capabilities.contains(.observers) else {
        return fail(
          MuxError(
            .invalidRequest,
            "observer attach needs the observers capability",
          ),
        )
      }
      do throws(MuxError) {
        reply(.success(try grantViewer(ws, to: client, hello: hello)))
      } catch { fail(error) }
      return
    }
    guard leases[ws.id] == nil else {
      return fail(
        MuxError(.leaseHeld, "another frontend controls this workspace"),
      )
    }
    reply(.success(grantLease(ws, to: client, hello: hello)))
  }

  private func takeover(
    _ selector: WorkspaceSelector,
    expected: UInt64,
    client: Client,
    hello: Hello,
    reply: @escaping Reply,
  ) throws(MuxError) {
    let fail = { (e: MuxError) in reply(.failure(e)) }
    guard hello.frontend != .control else {
      return fail(
        MuxError(.invalidRequest, "control connections cannot attach"),
      )
    }
    guard !quiescing else {
      return fail(MuxError(.quiescing, "service is preparing to update"))
    }
    let ws = try workspace(selector)
    // Names the lease the user agreed to displace; a newer holder
    // (or none) means the prompt is stale.
    guard expected == leaseGenerations[ws.id, default: 0] else {
      return fail(
        MuxError(.staleRevision, "the workspace's controller changed"),
      )
    }
    if let held = clientLeases[client.id] {
      releaseLease(held, notify: false, reason: "took over another workspace")
    }
    if leases[ws.id] != nil {
      // Fence the old holder: its pastes close and its attachment ID
      // stops admitting input before the new lease exists.
      releaseLease(
        ws.id,
        notify: true,
        fence: true,
        reason: "another frontend took control",
      )
    }
    reply(.success(grantLease(ws, to: client, hello: hello)))
  }

  private func switchWorkspace(
    _ selector: WorkspaceSelector,
    client: Client,
    reply: @escaping Reply,
  ) throws(MuxError) {
    let fail = { (error: MuxError) in reply(.failure(error)) }
    guard let from = clientLeases[client.id] else {
      return fail(MuxError(.notAttached))
    }
    let ws = try workspace(selector)
    guard ws.id == from || leases[ws.id] == nil else {
      return fail(
        MuxError(.leaseHeld, "another frontend controls this workspace"),
      )
    }
    // The same writer keeps the lease: its pastes close, but queued
    // keystrokes are not discarded (only a takeover fence does that).
    cancelPastes(from)
    _ = setSubscriptions([], client: client.id)
    if ws.id != from, var moved = leases.removeValue(forKey: from) {
      // Leaving returns the old workspace to live output, as a release
      // does: no scrollback position or search outlives the lease.
      resetViewports(from)
      leaseGenerations[ws.id, default: 0] &+= 1
      moved.workspace = ws.id
      moved.generation = leaseGenerations[ws.id, default: 0]
      moved.reportedActivity = []
      leases[ws.id] = moved
      if let i = leaseOrder.firstIndex(of: from) { leaseOrder[i] = ws.id }
      clientLeases[client.id] = ws.id
      publishWorkspaces()
    }
    // Subscriptions were cleared: the panes shown next need their own Ready.
    if let enabled = leases[ws.id]?.readiness.enabled {
      leases[ws.id]?.readiness = Readiness(enabled: enabled)
    }
    recordLocalUse(ws.id, by: client)
    reply(.success(.layout(snapshot(ws))))
  }

  func recordLocalUse(_ id: WorkspaceID, by client: Client) {
    if !client.remote, let index = workspaces.firstIndex(where: { $0.id == id })
    {
      workspaces[index].wasAttachedLocally = true
    }
  }

  /// Lease and snapshot at one ordering point; frames follow on
  /// subscription.
  private func grantLease(
    _ ws: Workspace,
    to client: Client,
    hello: Hello,
  ) -> MuxReply {
    recordLocalUse(ws.id, by: client)
    leaseGenerations[ws.id, default: 0] &+= 1
    let lease = Lease(
      client: client.id,
      workspace: ws.id,
      generation: leaseGenerations[ws.id, default: 0],
      holder: LeaseHolder(
        transport: client.remote ? .remote : .local,
        frontend: hello.frontend,
        since: Date(),
      ),
    )
    var granted = lease
    granted.readiness.enabled = hello.capabilities.contains(.attachReadiness)
    leases[ws.id] = granted
    leaseOrder.append(ws.id)
    clientLeases[client.id] = ws.id
    idleWork?.cancel()
    publishWorkspaces()
    var snap = snapshot(ws)
    snap.attachmentRole = .controller
    return .attached(attachment: granted.attachment, workspace: snap)
  }

  /// OSC 7501 inbox commands: metadata only. They never take a lease,
  /// resize a pane or subscribe frames.
  private func handleAttention(
    _ command: MuxCommand,
    client: Client,
    reply: @escaping Reply,
  ) {
    do throws(MuxError) {
      switch command {
      case let .subscribeInbox(on):
        if on {
          let snapshot = try attention.subscribe(client.id)
          client.subscribesInbox = true
          reply(.success(.inbox(snapshot)))
        } else {
          attention.unsubscribe(client.id)
          client.subscribesInbox = false
          reply(.success(.ok))
        }
      case let .inbox(query): try reply(.success(.inbox(attention.page(query))))
      case let .locateAttention(ref):
        reply(
          .success(
            .attention(location(attention.inbox.lookup(ref), for: client)),
          ),
        )
      case let .markSeen(ref):
        let lookup = attention.markSeen(ref)
        reply(.success(.attention(location(lookup, for: client))))
      case let .snooze(ref, until):
        let lookup = attention.snooze(ref, until: until)
        reply(.success(.attention(location(lookup, for: client))))
      case let .markReviewed(ref):
        let lookup = try attention.markReviewed(ref)
        reply(.success(.attention(location(lookup, for: client))))
      default: throw MuxError(.invalidRequest, "not an inbox command")
      }
    } catch { reply(.failure(error)) }
    attentionChanged()
  }

  /// Where an occurrence lives now. The lease is reported, never taken.
  private func location(
    _ lookup: AttentionLookup,
    for client: Client,
  ) -> AttentionLocation {
    guard let item = lookup.item else {
      return AttentionLocation(availability: .missing)
    }
    let pane = item.source.pane
    var availability = lookup.availability
    if availability == .available, panes[pane]?.exitStatus != nil {
      availability = .paneExited
    }
    let placed = locate(pane: pane)
    let workspace = placed.map { workspaces[$0.0].id } ?? item.workspace
    let holder = leases[workspace]?.client
    return AttentionLocation(
      availability: availability,
      item: item,
      workspace: workspace,
      tab: placed.map { workspaces[$0.0].tabs[$0.1].id } ?? item.tab,
      pane: pane,
      leaseHeldElsewhere: holder != nil && holder != client.id,
    )
  }

  /// After any reduction or acknowledgement: schedule the coalesced
  /// flush and the next snooze expiry.
  private func attentionChanged() {
    if attention.inbox.hasPendingUpdate, !attention.flushScheduled {
      attention.flushScheduled = true
      queue.asyncAfter(deadline: .now() + InboxHub.flushDelay) { [weak self] in
        self?.assumeIsolated { $0.flushInbox() }
      }
    }
    let expiry = attention.inbox.nextSnoozeExpiry
    guard let expiry else {
      snoozeTimer = nil
      return
    }
    if snoozeTimer == nil {
      snoozeTimer = InboxSnoozeTimer(queue: queue) { [weak self] in
        self?
          .assumeIsolated { service in
            service.attention.expireSnoozes()
            service.attentionChanged()
          }
      }
    }
    snoozeTimer?.schedule(expiry)
  }

  private func flushInbox() {
    for (client, update) in attention.flush() {
      send(.event(.inbox(update)), to: client)
    }
  }

  private func inboxAcknowledged(by client: UUID) {
    if let resync = attention.acknowledge(client) {
      send(.event(.inbox(resync)), to: client)
    }
  }

  /// Sends the workspace list to metadata observers once the current turn
  /// is done, so a change made in several steps (a teardown) sends one.
  func publishWorkspaces() {
    guard !workspacesPublishScheduled,
      clients.values.contains(where: \.observesWorkspaces)
    else { return }
    workspacesPublishScheduled = true
    // An exit can flush early; the queued turn then has nothing to send.
    onQueue { if $0.workspacesPublishScheduled { $0.flushWorkspaces() } }
  }

  private func flushWorkspaces() {
    workspacesPublishScheduled = false
    let observers = clients.values.filter(\.observesWorkspaces)
    guard !observers.isEmpty else { return }
    let list = summaries
    for client in observers { send(.event(.workspaces(list)), to: client.id) }
  }

  /// Commands acting on the attached workspace (lease already checked).
  private func handleLeased(
    _ command: MuxCommand,
    workspace leased: WorkspaceID,
    client: UUID,
    reply: @escaping Reply,
  ) {
    let ok = { reply(.success(.ok)) }
    let fail = { (e: MuxError) in reply(.failure(e)) }
    switch command {
    case let .automationKey(pane, shortcut):
      guard clients[client]?.remote == false, shortcut.utf8.count <= 128,
        locate(pane: pane, in: leased) != nil
      else {
        return fail(
          MuxError(
            .unauthorized,
            "automation requires a locally controlled pane"
          )
        )
      }
      _ = automation.runtime?.handleKey(shortcut, pane: pane.description)
      ok()
    case let .automationFocus(pane):
      guard clients[client]?.remote == false,
        locate(pane: pane, in: leased) != nil
      else {
        return fail(
          MuxError(
            .unauthorized,
            "automation focus requires a locally controlled pane"
          )
        )
      }
      automation.runtime?.setActivePane(pane.description)
      ok()
    case let .newTab(name, launch):
      if let name, !validName(name) { return fail(invalidName) }
      newTab(name: name, launch: launch, in: leased, reply: reply)
    case let .selectTab(tab):
      guard let (w, t) = locate(tab: tab, in: leased) else {
        return fail(MuxError(.notFound, "tab"))
      }
      workspaces[w].activeTab = workspaces[w].tabs[t].id
      commitLayout(workspaces[w].id)
      reply(.success(.layout(snapshot(workspaces[w]))))
    case let .renameTab(tab, name):
      guard let (w, t) = locate(tab: tab, in: leased) else {
        return fail(MuxError(.notFound, "tab"))
      }
      guard validName(name) else { return fail(invalidName) }
      workspaces[w].tabs[t].name = name
      commitLayout(workspaces[w].id)
      reply(.success(.layout(snapshot(workspaces[w]))))
    case let .endTab(tab):
      guard let (w, t) = locate(tab: tab, in: leased) else {
        return fail(MuxError(.notFound, "tab"))
      }
      let wsID = workspaces[w].id
      for pane in workspaces[w].tabs[t].layout.panes { endPane(pane) }
      reply(
        .success(
          workspaces.contains { $0.id == wsID } ? .layout(snapshot(wsID)!) : .ok,
        ),
      )
    case let .split(pane, axis, launch):
      split(pane, axis: axis, launch: launch, in: leased, reply: reply)
    case let .focusPane(pane):
      guard let (w, t) = locate(pane: pane, in: leased) else {
        return fail(MuxError(.notFound, "pane"))
      }
      workspaces[w].tabs[t].activePane = pane
      workspaces[w].activeTab = workspaces[w].tabs[t].id
      if let z = workspaces[w].tabs[t].zoomedPane, z != pane {
        workspaces[w].tabs[t].zoomedPane = nil
      }
      commitLayout(workspaces[w].id)
      reply(.success(.layout(snapshot(workspaces[w]))))
    case let .toggleZoom(tab):
      guard let (w, t) = locate(tab: tab, in: leased) else {
        return fail(MuxError(.notFound, "tab"))
      }
      let current = workspaces[w].tabs[t]
      workspaces[w].tabs[t].zoomedPane =
        current.zoomedPane == nil && current.layout.panes.count > 1
        ? current.activePane : nil
      commitLayout(workspaces[w].id)
      reply(.success(.layout(snapshot(workspaces[w]))))
    case let .setSplitRatio(tab, path, ratio):
      guard let (w, t) = locate(tab: tab, in: leased) else {
        return fail(MuxError(.notFound, "tab"))
      }
      guard ratio.isFinite, ratio > 0.02, ratio < 0.98,
        let layout = workspaces[w].tabs[t].layout.settingRatio(ratio, at: path,
        )
      else { return fail(MuxError(.invalidRequest, "split ratio")) }
      workspaces[w].tabs[t].layout = layout
      commitLayout(workspaces[w].id)
      reply(.success(.layout(snapshot(workspaces[w]))))
    case let .endPane(pane):
      guard panes[pane]?.workspace == leased,
        locate(pane: pane) != nil || panes[pane]?.detachedFromLayout == false
      else { return fail(MuxError(.notFound, "pane")) }
      let ws = panes[pane]?.workspace
      endPane(pane)
      if let ws, let snap = snapshot(ws) {
        reply(.success(.layout(snap)))
      } else {
        ok()
      }
    case let .setGeometry(batch):
      if let error = setGeometry(batch, workspace: leased) {
        fail(error)
      } else {
        ok()
      }
    case let .setSubscriptions(list):
      if let error = setSubscriptions(list, client: client) {
        fail(error)
      } else {
        ok()
      }
    case let .setViewport(request):
      setControllerViewport(request, workspace: leased, reply: reply)
    case let .scroll(pane, request):
      if let error = scrollError(request) { return fail(error) }
      guard let runtime = attachedRuntime(pane, in: leased) else {
        return fail(MuxError(.notFound, "pane"))
      }
      runtime.scroll(request) { error in
        reply(error.map { .failure($0) } ?? .success(.ok))
      }
    case let .search(pane, query):
      search(query, pane: pane, workspace: leased, reply: reply)
    case let .searchStep(pane, forward):
      runSearch(nil, step: forward, pane: pane, workspace: leased, reply: reply)
    case let .endSearch(pane):
      runSearch(nil, step: nil, pane: pane, workspace: leased, reply: reply)
    case .clearScreen, .resetTerminal, .link, .commandOutput,
      .clipboardReadResult, .clipboardWriteResult:
      handleTerminal(command, workspace: leased, reply: reply)
    case .status, .listWorkspaces, .newWorkspace, .endWorkspace,
      .renameWorkspace, .detachActive, .endAllWorkspaces, .attach, .detach,
      .switchWorkspace, .quiesce, .setTheme, .takeover, .observeWorkspaces,
      .subscribeAutomation, .subscribeInbox, .inbox, .locateAttention,
      .markSeen, .snooze, .markReviewed:
      ok()  // handled by `handle`
    }
  }

  /// Terminal control and shell-integration queries on a leased pane.
  private func handleTerminal(
    _ command: MuxCommand,
    workspace leased: WorkspaceID,
    reply: @escaping Reply,
  ) {
    let ok = { reply(.success(.ok)) }
    let fail = { (e: MuxError) in reply(.failure(e)) }
    switch command {
    case let .clearScreen(pane), let .resetTerminal(pane):
      guard let runtime = attachedRuntime(pane, in: leased) else {
        return fail(MuxError(.notFound, "pane"))
      }
      if case .clearScreen = command {
        runtime.clearScreen()
      } else {
        runtime.resetTerminal()
      }
      ok()
    case let .link(pane, address, column, detectURLs):
      guard let runtime = attachedRuntime(pane, in: leased) else {
        return fail(MuxError(.notFound, "pane"))
      }
      runtime.link(at: address, column: column, detectURLs: detectURLs) {
        reply(.success(.link($0)))
      }
    case let .commandOutput(pane, address):
      guard let runtime = attachedRuntime(pane, in: leased) else {
        return fail(MuxError(.notFound, "pane"))
      }
      runtime.commandOutput(at: address) { reply(.success(.commandOutput($0))) }
    case let .clipboardReadResult(pane, token, result):
      guard let runtime = attachedRuntime(pane, in: leased) else {
        return fail(MuxError(.notFound, "pane"))
      }
      runtime.completeClipboardRead(token, result)
      ok()
    case let .clipboardWriteResult(pane, token, result):
      guard let runtime = attachedRuntime(pane, in: leased) else {
        return fail(MuxError(.notFound, "pane"))
      }
      runtime.completeClipboardWrite(token, result)
      ok()
    default: fail(MuxError(.invalidRequest, "not a terminal command"))
    }
  }

  private func search(
    _ query: String,
    pane: PaneID,
    workspace leased: WorkspaceID,
    reply: @escaping Reply,
  ) {
    if let error = searchQueryError(query) { return reply(.failure(error)) }
    runSearch(query, step: nil, pane: pane, workspace: leased, reply: reply)
  }

  /// A new search (`query`), a step, or with neither, the end of search.
  private func runSearch(
    _ query: String?,
    step forward: Bool?,
    pane: PaneID,
    workspace leased: WorkspaceID,
    reply: @escaping Reply,
  ) {
    guard let runtime = attachedRuntime(pane, in: leased) else {
      reply(.failure(MuxError(.notFound, "pane")))
      return
    }
    runtime.search(query, step: forward) { reply(.success(.search($0))) }
  }

  /// Lease and update-barrier admission for a command.
  private func admission(
    of command: MuxCommand,
    from client: Client,
  ) -> MuxError? {
    if case .setViewport = command,
      client.hello?.capabilities.contains(.viewerViewport) != true
    {
      return MuxError(
        .invalidRequest,
        "viewports need the viewerViewport capability",
      )
    }
    if clientViewers[client.id] != nil, !command.allowedForObserver {
      return MuxError(.unauthorized, "observers cannot mutate the session")
    }
    if command.requiresLease, clientLeases[client.id] == nil,
      clientViewers[client.id] == nil
    {
      return MuxError(.notAttached, "this connection holds no attachment")
    }
    // At the update barrier only status, ending sessions and leaving are
    // admitted; the workspace graph is otherwise frozen.
    if quiescing, !command.allowedWhileQuiescing {
      return MuxError(.quiescing, "service is preparing to update")
    }
    return nil
  }

  func notFound(_ selector: WorkspaceSelector) -> MuxError {
    switch selector {
    case let .id(id): MuxError(.notFound, "workspace \(id.short)")
    case let .name(n):
      MuxError(.notFound, "workspace \"\(DisplayText.sanitize(n))\"")
    case .latest: MuxError(.notFound, "no workspaces")
    }
  }

  /// A search query is non-empty and within the limit (either role).
  func searchQueryError(_ query: String) -> MuxError? {
    limits.validSearchQuery(query)
      ? nil : MuxError(.invalidRequest, "search query")
  }

  /// A scroll distance a pane could ever move (either role): history plus
  /// a screen, in lines or (at least one line each) pages.
  func scrollError(_ request: ScrollRequest) -> MuxError? {
    switch request {
    case .bottom, .top, .oldest: return nil
    case let .lines(n), let .pages(n), let .prompt(n):
      guard limits.historyRowsPerPane >= 0, limits.maxRows >= 0 else {
        return Self.badScroll
      }
      let (bound, overflow) = limits.historyRowsPerPane.addingReportingOverflow(
        limits.maxRows,
      )
      // An overflowing nonnegative sum covers every Int distance, including
      // Int.min. The pane clamps the actual movement to retained history.
      return (overflow || (-bound ... bound).contains(n)) ? nil : Self.badScroll
    }
  }

  private static let badScroll = MuxError(.invalidRequest, "scroll distance")

  /// Names show in every client's chrome: plain text only (no controls,
  /// bidi overrides, invisible scalars or extra spaces).
  func validName(_ name: String) -> Bool {
    name.utf8.count <= limits.maxNameBytes && DisplayText.isPlainName(name)
  }

  /// Why `validName` refused a name, for the person who typed it.
  var invalidName: MuxError {
    MuxError(
      .invalidRequest,
      "name: plain text of at most \(limits.maxNameBytes) bytes"
    )
  }

  // MARK: Model queries

  private var status: ServiceStatus {
    ServiceStatus(
      server: instance,
      build: SMX.build,
      pid: getpid(),
      startedAt: startedAt,
      workspaces: workspaces.count,
      panes: paneCount,
      attached: !leases.isEmpty || !viewers.isEmpty,
      quiescing: quiescing,
      innerTerm: configuration.innerTerm,
    )
  }

  private var summaries: [WorkspaceSummary] {
    workspaces.map { ws in
      WorkspaceSummary(
        id: ws.id,
        name: ws.name,
        tabCount: ws.tabs.count,
        paneCount: ws.allPanes.count,
        createdAt: ws.createdAt,
        isAttached: leases[ws.id] != nil,
        leaseGeneration: leaseGenerations[ws.id, default: 0],
        leaseHolder: leases[ws.id]?.holder,
        livePaneCount: ws.allPanes.filter { panes[$0]?.exitStatus == nil }.count,
      )
    }
  }

  /// Shortest ID prefix a name selector may stand for (`WorkspaceID.short`).
  static let minimumIDPrefix = 8

  /// An exact name first; otherwise an unambiguous ID prefix of at least
  /// `minimumIDPrefix` hex digits. Default names are numbers, which are
  /// also hex, so a short or shared prefix never selects anything.
  private func workspaceIndex(
    _ selector: WorkspaceSelector,
  ) throws(MuxError) -> Int {
    let found: Int? =
      switch selector {
      case let .id(id): workspaces.firstIndex { $0.id == id }
      case .latest: workspaces.indices.last
      case let .name(name):
        if name.isEmpty {
          nil
        } else if let i = workspaces.firstIndex(where: { $0.name == name }) {
          i
        } else {
          try idPrefixIndex(name)
        }
      }
    guard let found else { throw notFound(selector) }
    return found
  }

  private func idPrefixIndex(_ text: String) throws(MuxError) -> Int? {
    let prefix = text.uppercased()
    let digits = prefix.unicodeScalars.filter { $0 != "-" }
    guard digits.count >= Self.minimumIDPrefix,
      digits.allSatisfy(\.properties.isASCIIHexDigit)
    else { return nil }
    let matches = workspaces.indices.filter {
      workspaces[$0].id.description.uppercased().hasPrefix(prefix)
    }
    guard matches.count <= 1 else {
      throw MuxError(
        .invalidRequest,
        "workspace prefix \"\(text)\" is ambiguous (\(matches.count) matches)",
      )
    }
    return matches.first
  }

  func workspace(_ selector: WorkspaceSelector) throws(MuxError) -> Workspace {
    try workspaces[workspaceIndex(selector)]
  }

  func locate(tab: TabID) -> (Int, Int)? {
    for (w, ws) in workspaces.enumerated() {
      if let t = ws.tabs.firstIndex(where: { $0.id == tab }) { return (w, t) }
    }
    return nil
  }

  func locate(pane: PaneID) -> (Int, Int)? {
    for (w, ws) in workspaces.enumerated() {
      if let t = ws.tabIndex(containing: pane) { return (w, t) }
    }
    return nil
  }

  /// Restricted to one workspace: a lease never reaches another's tabs.
  func locate(tab: TabID, in workspace: WorkspaceID) -> (Int, Int)? {
    locate(tab: tab).flatMap { workspaces[$0.0].id == workspace ? $0 : nil }
  }

  func locate(pane: PaneID, in workspace: WorkspaceID) -> (Int, Int)? {
    locate(pane: pane).flatMap { workspaces[$0.0].id == workspace ? $0 : nil }
  }

  /// A pane of the attached workspace.
  func attachedRuntime(
    _ pane: PaneID,
    in workspace: WorkspaceID,
  ) -> PaneRuntime? {
    guard let record = panes[pane], record.workspace == workspace,
      !record.detachedFromLayout
    else { return nil }
    return record.runtime
  }

  func snapshot(_ ws: Workspace) -> WorkspaceSnapshot {
    WorkspaceSnapshot(
      id: ws.id,
      name: ws.name,
      tabs: ws.tabs.map(\.snapshot),
      activeTab: ws.activeTab,
      panes: ws.allPanes.compactMap { id in panes[id]?.summary(id) },
      layoutRevision: ws.layoutRevision,
    )
  }

  func snapshot(_ id: WorkspaceID) -> WorkspaceSnapshot? {
    workspaces.first { $0.id == id }.map(snapshot)
  }

  /// Commits a validated mutation: new revision, then notify the lease.
  func commitLayout(_ id: WorkspaceID) {
    guard let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
    workspaces[i].layoutRevision &+= 1
    let snap = snapshot(workspaces[i])
    if let lease = leases[id] { send(.event(.layout(snap)), to: lease.client) }
    for viewer in viewers[id] ?? [] {
      send(.event(.layout(snap)), to: viewer.client)
    }
    // The visible panes may have changed (tab, zoom, split, exit).
    recheckReady(id)
    publishWorkspaces()
  }

  // MARK: Pane events

  /// `reportActivity` is off for a pane's launch, which is not unseen
  /// output in a hidden tab.
  func paneChanged(_ id: PaneID, reportActivity: Bool = true) {
    guard let record = panes[id] else { return }
    record.runtime.changePosted.store(false, ordering: .releasing)
    let wsID = record.workspace
    if let holder = leases[wsID], let sink = clients[holder.client]?.local {
      // The roaming bridge exports its own screens on demand. Observers
      // still need a pump: a dirty slot is not delivered on its own.
      sink.onPaneChanged(id)
      if viewerSubscribed(wsID, pane: id) {
        markViewersDirty(wsID, pane: id)
        pump()
      }
      return
    }
    if reportActivity, let current = leases[wsID],
      let ws = workspaces.first(where: { $0.id == wsID }),
      let tab = ws.tabIndex(containing: id), ws.tabs[tab].id != ws.activeTab
    {
      if current.frames[id] != nil {
        leases[wsID]?.frames[id]?.hiddenActivity = true
      } else if !current.reportedActivity.contains(id) {
        leases[wsID]?.reportedActivity.insert(id)
        send(.event(.activity(id)), to: current.client)
      }
    }
    if leases[wsID]?.frames[id] != nil {
      leases[wsID]?.frames[id]?.dirty = true
    }
    markViewersDirty(wsID, pane: id)
    guard leases[wsID]?.frames[id] != nil || viewerSubscribed(wsID, pane: id)
    else { return }
    pump()
  }

  func paneEvent(_ id: PaneID, _ event: PaneEvent) {
    guard let wsID = panes[id]?.workspace else { return }
    let client = leases[wsID]?.client
    switch event {
    case let .title(title):
      panes[id]?.title = title
      if let client { send(.event(.title(id, title)), to: client) }
    case .bell: if let client { send(.event(.bell(id)), to: client) }
    case let .workingDirectory(dir): panes[id]?.workingDirectory = dir
    case let .status(epoch, changes):
      let tab = locate(pane: id).map { workspaces[$0.0].tabs[$0.1].id }
      attention.apply(
        changes,
        pane: id,
        epoch: epoch,
        context: AttentionContext(workspace: wsID, tab: tab),
      )
      attentionChanged()
    case let .finished(status, forced):
      // The final status was drained ahead of this event.
      attention.paneExited(id)
      attentionChanged()
      if forced {
        log.notice(
          "pane \(id.short) terminated forcibly; output may be truncated",
        )
      }
      panes[id]?.exitStatus = status
      if let client {
        send(
          .event(.paneExited(id, status: status, truncated: forced)),
          to: client,
        )
      }
      let record = panes[id]!
      if record.detachedFromLayout {
        panes.removeValue(forKey: id)
      } else if let ws = workspaces.first(where: { $0.id == record.workspace }),
        ws.remainOnExit
      {
        commitLayout(ws.id)
      } else {
        removeFromLayout(id)
        panes.removeValue(forKey: id)
      }
      checkIdle()
    case let .clipboardRead(request):
      // Only an app that answers may see it; otherwise refuse at once so
      // the program is not left waiting.
      if let client,
        clients[client]?.hello?.capabilities.contains(.clipboardRequests)
          == true
      {
        send(.event(.clipboardRead(request)), to: client)
      } else {
        panes[id]?.runtime.completeClipboardRead(request.token, .denied)
      }
    case let .clipboardWrite(request):
      if let client,
        clients[client]?.hello?.capabilities.contains(.clipboardRequests)
          == true
      {
        send(.event(.clipboardWrite(request)), to: client)
      } else {
        panes[id]?.runtime.completeClipboardWrite(request.token, .unsupported)
      }
    }
  }

  // MARK: Lease and lifetime

  /// `fence` (takeover, `detachActive`, connection loss) also drops the
  /// holder's unwritten input so it cannot run under a later lease. An
  /// explicit `detach` lets the input it was acknowledged for drain.
  func releaseLease(
    _ wsID: WorkspaceID,
    notify: Bool,
    fence: Bool = false,
    reason: String,
  ) {
    guard let current = leases[wsID] else { return }
    // Cancellation cleanup is queued on each pane ahead of any later input.
    cancelPastes(wsID, discardDeferredInput: fence)
    resetViewports(wsID)
    for slot in current.frames.values { releaseBudget(slot) }
    leases.removeValue(forKey: wsID)
    leaseOrder.removeAll { $0 == wsID }
    clientLeases.removeValue(forKey: current.client)
    if notify { send(.event(.detached(reason: reason)), to: current.client) }
    publishWorkspaces()
    checkIdle()
  }

  private func resetViewports(_ wsID: WorkspaceID) {
    guard let ws = workspaces.first(where: { $0.id == wsID }) else { return }
    for pane in ws.allPanes { panes[pane]?.runtime.resetViewport() }
  }

  /// The ordered empty-state barrier: no workspaces, retained screens,
  /// attachment, pending launches or teardowns. Live control connections
  /// do not hold this process barrier; idle exit additionally checks them.
  public var isEmpty: Bool {
    workspaces.isEmpty && panes.isEmpty && pendingLaunches == 0
      && leases.isEmpty
  }

  func checkIdle() {
    idleWork?.cancel()
    idleWork = nil
    if exitRequested {
      if isEmpty, let ready = onExitReady {
        onExitReady = nil
        // The process exits in `ready`: send the queued list first.
        if workspacesPublishScheduled { flushWorkspaces() }
        ready()
      }
      return
    }
    guard let delay = configuration.idleExitDelay, let onIdle, isEmpty,
      clients.isEmpty
    else { return }
    guard delay.isFinite, delay >= 0 else {
      log.error("invalid idle exit delay; keeping the service running")
      return
    }
    let work = DispatchWorkItem { [weak self] in
      self?
        .assumeIsolated { service in
          guard service.isEmpty, service.clients.isEmpty else { return }
          onIdle()
        }
    }
    idleWork = work
    queue.asyncAfter(deadline: .now() + delay, execute: work)
  }

  // MARK: Diagnostics

  /// Visible text of a pane (tests).
  public func screenLines(_ pane: PaneID) -> [String]? {
    panes[pane]?.runtime.screenLines()
  }

  /// A pane's history share and the service total (tests, diagnostics).
  public func historyBudget(_ pane: PaneID) -> (pane: Int, total: Int)? {
    panes[pane].map { ($0.runtime.historyBytes, allocatedHistoryBytes) }
  }

  func runtime(_ pane: PaneID) -> PaneRuntime? { panes[pane]?.runtime }

  /// Frame bytes sent and not yet acknowledged, plus estimates held by
  /// captures in progress (tests, diagnostics).
  package var pendingFrameBytes: Int { inflightFrameBytes + reservedFrameBytes }

  /// In-flight plus replaceable queued frames one observer holds for
  /// `pane` (tests). A capture still in progress is not included.
  package func observerQueuedFrames(_ pane: PaneID) -> Int {
    var most = 0
    for list in viewers.values {
      for viewer in list {
        guard let slot = viewer.frames[pane] else { continue }
        var held = 0
        if slot.inflight != nil { held += 1 }
        if slot.queued != nil { held += 1 }
        most = max(most, held)
      }
    }
    return most
  }

  /// Frames being captured or awaiting acknowledgement (tests).
  package var outstandingFrames: Int {
    let held: (FrameSlot) -> Bool = {
      $0.capture != nil || $0.inflight != nil || $0.queued != nil
    }
    let controllers = leases.values.reduce(0) { n, lease in
      n + lease.frames.values.count(where: held)
    }
    let watching = viewers.values.reduce(0) { n, list in
      n
        + list.reduce(0) { count, viewer in
          count + viewer.frames.values.count(where: held)
        }
    }
    return controllers + watching
  }

  public func panePID(_ pane: PaneID) -> Int32? {
    panes[pane].map(\.runtime.pid)
  }

}
