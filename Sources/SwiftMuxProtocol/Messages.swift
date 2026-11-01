import Foundation

/// SMX/2: tagged Codable records carried as bounded XPC data payloads.
/// A change a running service of the previous version cannot decode bumps
/// the version, so a stale agent is reported as a different version rather
/// than failing to decode; additive requests use `ServiceFeatures`.
public enum SMX {
  public static let protocolVersion = 2
  /// Read-only viewers per workspace. Not configurable.
  public static let maxObservers = 4
  /// Versions this build can talk to. Only exact matches for now.
  public static let compatibleVersions: ClosedRange<Int> = 2 ... 2
  public static let build = "swiftmux-0.2"
  /// The one supported outer host profile for the terminal frontend.
  public static let terminalProfile = "swiftty-xterm-256color/1"
  /// The `TERM` installed for programs inside panes.
  public static let innerTerm = "swmux-256color"
  public static let fallbackInnerTerm = "xterm-256color"
  public static let defaultMachService = "com.chr33s.swiftty.swiftmux"
  public static let agentPlistName = "com.chr33s.swiftty.swiftmux.plist"
}

// MARK: Errors

public struct MuxError: Error, Codable, Sendable, Equatable,
  CustomStringConvertible, LocalizedError
{
  public enum Code: String, Codable, Sendable {
    case alreadyAttached, notAttached, staleAttachment, staleGeometry
    case staleLayout, paneExited, historyUnavailable, resourceLimit
    case incompatibleVersion, notFound, invalidRequest, unauthorized
    case launchFailed, quiescing, serverInstanceChanged, connectionLost
    /// Another attachment holds the workspace lease; take over explicitly.
    case leaseHeld
    /// A mutation named an expected revision or generation that moved on.
    case staleRevision
    /// Input skipped a sequence number; resend from `nextExpected`.
    case inputGap
  }

  public var code: Code
  public var message: String

  public init(_ code: Code, _ message: String = "") {
    self.code = code
    self.message = message
  }

  public var description: String {
    message.isEmpty ? code.rawValue : "\(code.rawValue): \(message)"
  }

  /// Alerts show the code and message rather than a bridged error number.
  public var errorDescription: String? { description }
}

// MARK: Handshake

public enum FrontendKind: String, Codable, Sendable {
  /// `swmux` inside Swiftty.
  case terminal
  /// Native Swiftty pane views.
  case native
  /// Status, registration and one-shot commands; never holds a lease.
  case control
}

/// What a client can consume beyond the original single-controller attach.
/// A hello that omits this set attaches only as the sole controller, is
/// never sent a `ready` event, and cannot set a viewport.
public struct ClientCapabilities: OptionSet, Codable, Sendable, Equatable {
  public var rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  /// The client installs owned frames and waits for `ready`.
  public static let attachReadiness = ClientCapabilities(rawValue: 1 << 0)
  /// The client may request `role: observer`.
  public static let observers = ClientCapabilities(rawValue: 1 << 1)
  /// The client scrolls a viewport without resizing the PTY.
  public static let viewerViewport = ClientCapabilities(rawValue: 1 << 2)
  /// The client answers `clipboardRead` and `clipboardWrite` events.
  /// Only frontends with a pasteboard ask for it (not in `supported`).
  public static let clipboardRequests = ClientCapabilities(rawValue: 1 << 3)

  public static let supported: ClientCapabilities = [
    .attachReadiness, .observers, .viewerViewport,
  ]
}

/// Writer or read-only viewer.
public enum AttachmentRole: String, Codable, Sendable, Equatable {
  case controller
  case observer
}

public struct Hello: Codable, Sendable {
  public var protocolVersion: Int
  public var build: String
  public var frontend: FrontendKind
  public var terminalProfile: String?
  /// Empty when the peer omitted the field (single controller only).
  public var capabilities: ClientCapabilities

  public init(
    frontend: FrontendKind,
    terminalProfile: String? = nil,
    protocolVersion: Int = SMX.protocolVersion,
    build: String = SMX.build,
    capabilities: ClientCapabilities = .supported
  ) {
    self.protocolVersion = protocolVersion
    self.build = build
    self.frontend = frontend
    self.terminalProfile = terminalProfile
    self.capabilities = capabilities
  }

  private enum CodingKeys: String, CodingKey {
    case protocolVersion, build, frontend, terminalProfile, capabilities
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    build = try container.decode(String.self, forKey: .build)
    frontend = try container.decode(FrontendKind.self, forKey: .frontend)
    terminalProfile = try container.decodeIfPresent(
      String.self,
      forKey: .terminalProfile
    )
    capabilities =
      try container.decodeIfPresent(
        ClientCapabilities.self,
        forKey: .capabilities
      ) ?? []
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(protocolVersion, forKey: .protocolVersion)
    try container.encode(build, forKey: .build)
    try container.encode(frontend, forKey: .frontend)
    try container.encodeIfPresent(terminalProfile, forKey: .terminalProfile)
    if !capabilities.isEmpty {
      try container.encode(capabilities, forKey: .capabilities)
    }
  }
}

/// Requests and input a service accepts beyond the original profile. A
/// frontend uses a feature only when the welcome lists it, so it can
/// still talk to a service started from an older build.
public struct ServiceFeatures: OptionSet, Codable, Sendable, Equatable {
  public var rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  /// `MuxInput.mouse` and the frame's mouse-reporting modes.
  public static let mouseReporting = ServiceFeatures(rawValue: 1 << 0)
  /// `ScrollRequest.oldest` and `.prompt`.
  public static let historyJumps = ServiceFeatures(rawValue: 1 << 1)
  /// `clearScreen` and `resetTerminal`.
  public static let terminalControl = ServiceFeatures(rawValue: 1 << 2)
  /// `link`, `commandOutput` and `MuxInput.moveCursor`.
  public static let shellIntegration = ServiceFeatures(rawValue: 1 << 3)
  /// `MuxKey.keypad`. Clients send the main-keyboard key without it.
  public static let keypadKeys = ServiceFeatures(rawValue: 1 << 4)
  /// Kitty clipboard events (to clients with `clipboardRequests`), their
  /// result commands, and `MuxInput.clipboardPaste`.
  public static let kittyClipboard = ServiceFeatures(rawValue: 1 << 5)
  /// `PaneFrame.dropTarget` and `MuxInput.drag`.
  public static let dropTargets = ServiceFeatures(rawValue: 1 << 6)

  public static let javaScript = ServiceFeatures(rawValue: 1 << 7)

  public static let supported: ServiceFeatures = [
    .mouseReporting, .historyJumps, .terminalControl, .shellIntegration,
    .keypadKeys, .kittyClipboard, .dropTargets, .javaScript,
  ]
}

public struct Welcome: Codable, Sendable {
  public var protocolVersion: Int
  public var build: String
  public var server: ServerInstanceID
  public var acceptedProfile: String?
  public var limits: MuxLimits
  public var innerTerm: String
  /// Empty when the service omitted the field (an older build).
  public var features: ServiceFeatures

  public init(
    protocolVersion: Int,
    build: String,
    server: ServerInstanceID,
    acceptedProfile: String?,
    limits: MuxLimits,
    innerTerm: String,
    features: ServiceFeatures = []
  ) {
    self.protocolVersion = protocolVersion
    self.build = build
    self.server = server
    self.acceptedProfile = acceptedProfile
    self.limits = limits
    self.innerTerm = innerTerm
    self.features = features
  }

  private enum CodingKeys: String, CodingKey {
    case protocolVersion, build, server, acceptedProfile, limits, innerTerm
    case features
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    build = try container.decode(String.self, forKey: .build)
    server = try container.decode(ServerInstanceID.self, forKey: .server)
    acceptedProfile = try container.decodeIfPresent(
      String.self,
      forKey: .acceptedProfile
    )
    limits = try container.decode(MuxLimits.self, forKey: .limits)
    innerTerm = try container.decode(String.self, forKey: .innerTerm)
    features =
      try container.decodeIfPresent(ServiceFeatures.self, forKey: .features)
      ?? []
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(protocolVersion, forKey: .protocolVersion)
    try container.encode(build, forKey: .build)
    try container.encode(server, forKey: .server)
    try container.encodeIfPresent(acceptedProfile, forKey: .acceptedProfile)
    try container.encode(limits, forKey: .limits)
    try container.encode(innerTerm, forKey: .innerTerm)
    if !features.isEmpty { try container.encode(features, forKey: .features) }
  }
}

// MARK: Workspace model snapshots

public struct PaneSummary: Codable, Sendable, Equatable {
  public var id: PaneID
  public var columns: Int
  public var rows: Int
  public var title: String
  public var pid: Int32?
  /// Set once the pane's process exited and output drained.
  public var exitStatus: Int32?
  public var workingDirectory: String?

  public init(
    id: PaneID,
    columns: Int,
    rows: Int,
    title: String = "",
    pid: Int32? = nil,
    exitStatus: Int32? = nil,
    workingDirectory: String? = nil
  ) {
    self.id = id
    self.columns = columns
    self.rows = rows
    self.title = title
    self.pid = pid
    self.exitStatus = exitStatus
    self.workingDirectory = workingDirectory
  }
}

public struct TabSnapshot: Codable, Sendable, Equatable {
  public var id: TabID
  public var name: String
  public var layout: LayoutNode
  public var activePane: PaneID
  /// Displayed alone while set; the split tree is retained.
  public var zoomedPane: PaneID?

  public init(
    id: TabID,
    name: String,
    layout: LayoutNode,
    activePane: PaneID,
    zoomedPane: PaneID? = nil
  ) {
    self.id = id
    self.name = name
    self.layout = layout
    self.activePane = activePane
    self.zoomedPane = zoomedPane
  }
}

public struct WorkspaceSnapshot: Codable, Sendable, Equatable {
  public var id: WorkspaceID
  public var name: String
  public var tabs: [TabSnapshot]
  public var activeTab: TabID
  public var panes: [PaneSummary]
  /// Increments on every committed layout mutation.
  public var layoutRevision: UInt64
  /// Set on an attach or takeover reply. Layout events leave it nil.
  public var attachmentRole: AttachmentRole?

  public var activeTabSnapshot: TabSnapshot? {
    tabs.first { $0.id == activeTab }
  }

  public func pane(_ id: PaneID) -> PaneSummary? { panes.first { $0.id == id } }

  public func tab(containing pane: PaneID) -> TabSnapshot? {
    tabs.first { $0.layout.contains(pane) }
  }

  public init(
    id: WorkspaceID,
    name: String,
    tabs: [TabSnapshot],
    activeTab: TabID,
    panes: [PaneSummary],
    layoutRevision: UInt64,
    attachmentRole: AttachmentRole? = nil
  ) {
    self.id = id
    self.name = name
    self.tabs = tabs
    self.activeTab = activeTab
    self.panes = panes
    self.layoutRevision = layoutRevision
    self.attachmentRole = attachmentRole
  }
}

public struct WorkspaceSummary: Codable, Sendable, Hashable {
  public var id: WorkspaceID
  public var name: String
  public var tabCount: Int
  public var paneCount: Int
  public var createdAt: Date
  public var isAttached: Bool
  /// Generation of the current (or last) lease; `takeover` names it.
  public var leaseGeneration: UInt64
  /// Who holds the lease, for takeover prompts.
  public var leaseHolder: LeaseHolder?
  /// Panes whose process has not exited (nil from older services).
  public var livePaneCount: Int?

  public init(
    id: WorkspaceID,
    name: String,
    tabCount: Int,
    paneCount: Int,
    createdAt: Date,
    isAttached: Bool,
    leaseGeneration: UInt64 = 0,
    leaseHolder: LeaseHolder? = nil,
    livePaneCount: Int? = nil
  ) {
    self.id = id
    self.name = name
    self.tabCount = tabCount
    self.paneCount = paneCount
    self.createdAt = createdAt
    self.isAttached = isAttached
    self.leaseGeneration = leaseGeneration
    self.leaseHolder = leaseHolder
    self.livePaneCount = livePaneCount
  }
}

public struct LeaseHolder: Codable, Sendable, Hashable {
  public enum Transport: String, Codable, Sendable { case local, remote }
  public var transport: Transport
  public var frontend: FrontendKind
  public var since: Date

  public init(transport: Transport, frontend: FrontendKind, since: Date) {
    self.transport = transport
    self.frontend = frontend
    self.since = since
  }
}

public struct ServiceStatus: Codable, Sendable, Equatable {
  public var server: ServerInstanceID
  public var build: String
  public var pid: Int32
  public var startedAt: Date
  public var workspaces: Int
  /// Includes admitted launches and panes retained through teardown, so
  /// zero is meaningful at the ordered update barrier.
  public var panes: Int
  public var attached: Bool
  public var quiescing: Bool
  public var innerTerm: String

  public init(
    server: ServerInstanceID,
    build: String,
    pid: Int32,
    startedAt: Date,
    workspaces: Int,
    panes: Int,
    attached: Bool,
    quiescing: Bool,
    innerTerm: String
  ) {
    self.server = server
    self.build = build
    self.pid = pid
    self.startedAt = startedAt
    self.workspaces = workspaces
    self.panes = panes
    self.attached = attached
    self.quiescing = quiescing
    self.innerTerm = innerTerm
  }
}

// MARK: Commands

/// Attach payload: always `{selector, role}` on the wire.
public struct AttachRequest: Codable, Sendable, Equatable {
  public var selector: WorkspaceSelector
  public var role: AttachmentRole

  public init(_ selector: WorkspaceSelector, role: AttachmentRole = .controller)
  {
    self.selector = selector
    self.role = role
  }
}

/// One viewer's window onto a pane. Display size crops or pads the
/// authoritative grid; it does not change the PTY.
public struct ViewportRequest: Codable, Sendable, Equatable {
  public var pane: PaneID
  /// Absolute row pinned at the top of the viewport. Ignored when
  /// `followTail` is set.
  public var anchorRow: Int?
  public var followTail: Bool
  public var historyGeneration: UInt64
  /// Nil uses the authoritative grid size.
  public var rows: Int?
  public var columns: Int?

  public init(
    pane: PaneID,
    anchorRow: Int? = nil,
    followTail: Bool,
    historyGeneration: UInt64,
    rows: Int? = nil,
    columns: Int? = nil
  ) {
    self.pane = pane
    self.anchorRow = anchorRow
    self.followTail = followTail
    self.historyGeneration = historyGeneration
    self.rows = rows
    self.columns = columns
  }
}

/// Sent once the attachment has installed a current frame for every
/// required visible pane. Hidden panes are absent from `initialFrames`.
public struct ReadyNotice: Codable, Sendable, Equatable {
  public struct PaneRevision: Codable, Sendable, Equatable {
    public var pane: PaneID
    public var frameRevision: UInt64
    public var geometryRevision: UInt64

    public init(pane: PaneID, frameRevision: UInt64, geometryRevision: UInt64) {
      self.pane = pane
      self.frameRevision = frameRevision
      self.geometryRevision = geometryRevision
    }
  }

  public var attachment: AttachmentID
  public var server: ServerInstanceID
  public var initialFrames: [PaneRevision]

  public init(
    attachment: AttachmentID,
    server: ServerInstanceID,
    initialFrames: [PaneRevision]
  ) {
    self.attachment = attachment
    self.server = server
    self.initialFrames = initialFrames
  }
}

/// Selects a workspace by identity or display name.
public enum WorkspaceSelector: Codable, Sendable, Equatable {
  case id(WorkspaceID)
  case name(String)
  /// The most recently created workspace.
  case latest
}

public struct LaunchSpec: Codable, Sendable, Equatable {
  /// Program and arguments; nil starts the user's login shell.
  public var command: [String]?
  public var workingDirectory: String?
  /// Environment snapshot, taken by the creating frontend.
  public var environment: [String: String]

  public init(
    command: [String]? = nil,
    workingDirectory: String? = nil,
    environment: [String: String] = [:]
  ) {
    self.command = command
    self.workingDirectory = workingDirectory
    self.environment = environment
  }
}

public struct NewWorkspaceRequest: Codable, Sendable, Equatable {
  public var name: String?
  public var columns: Int
  public var rows: Int
  public var launch: LaunchSpec
  /// Keep a pane's final screen after its process exits.
  public var remainOnExit: Bool

  public init(
    name: String? = nil,
    columns: Int = 80,
    rows: Int = 24,
    launch: LaunchSpec = LaunchSpec(),
    remainOnExit: Bool = false
  ) {
    self.name = name
    self.columns = columns
    self.rows = rows
    self.launch = launch
    self.remainOnExit = remainOnExit
  }
}

/// Cell dimensions for visible panes, computed by the frontend after
/// subtracting its own decoration.
public struct GeometryBatch: Codable, Sendable, Equatable {
  public struct Entry: Codable, Sendable, Equatable {
    public var pane: PaneID
    public var columns: Int
    public var rows: Int
    public init(pane: PaneID, columns: Int, rows: Int) {
      self.pane = pane
      self.columns = columns
      self.rows = rows
    }
  }

  public var layoutRevision: UInt64
  /// Frontend-chosen, increasing; frames echo the accepted generation.
  public var generation: UInt64
  public var entries: [Entry]

  public init(layoutRevision: UInt64, generation: UInt64, entries: [Entry]) {
    self.layoutRevision = layoutRevision
    self.generation = generation
    self.entries = entries
  }
}

/// Stable history address: absolute row valid for one addressing
/// generation of one screen.
public struct HistoryAddress: Codable, Sendable, Hashable {
  public var generation: UInt64
  public var alternateScreen: Bool
  public var row: Int

  public init(generation: UInt64, alternateScreen: Bool, row: Int) {
    self.generation = generation
    self.alternateScreen = alternateScreen
    self.row = row
  }
}

public enum ScrollRequest: Codable, Sendable, Equatable {
  /// Positive scrolls toward older history.
  case lines(Int)
  case pages(Int)
  case bottom
  /// Show `address` as the top viewport row.
  case top(HistoryAddress)
  /// The oldest retained row at the top (`historyJumps`).
  case oldest
  /// The `n`th shell prompt above (negative) or below (positive) the top
  /// row becomes the top row (`historyJumps`). Fails with `notFound` when
  /// there is no such prompt.
  case prompt(Int)
}

public enum MuxCommand: Codable, Sendable, Equatable {
  // Control (no lease required).
  case status
  case listWorkspaces
  case newWorkspace(NewWorkspaceRequest)
  case endWorkspace(WorkspaceSelector)
  case renameWorkspace(WorkspaceSelector, name: String)
  /// Releases the current interactive lease, whoever holds it.
  case detachActive
  /// Quiesce, then end every workspace and report the empty barrier.
  case endAllWorkspaces
  /// Stops (or resumes) admitting new workspaces and panes, for updates.
  /// An update freeze belongs to the connection that began it. Only that
  /// owner may repeat or release it; losing the owner restores admission
  /// unless the service has begun terminal shutdown.
  case quiesce(Bool)
  /// Default colours and light/dark scheme reported by every pane's
  /// engine (OSC 10/11/4 queries, mode 2031); also used for new panes.
  case setTheme(MuxTheme)

  // Attachment.
  case attach(AttachRequest)
  /// Fences the current holder of the workspace's lease and attaches.
  /// `expectedLease` must name the lease generation the user saw, so a
  /// stale prompt cannot displace a newer holder.
  case takeover(WorkspaceSelector, expectedLease: UInt64)
  case detach
  case switchWorkspace(WorkspaceSelector)

  // Metadata observation (no lease, never resizes panes).
  /// Workspace list and lease changes as `workspaces` events.
  case observeWorkspaces(Bool)
  case subscribeInbox(Bool)
  /// Local native automation UI; events only follow an explicit subscription.
  case subscribeAutomation(Bool)
  case automationKey(pane: PaneID, shortcut: String)
  case automationFocus(PaneID)
  case inbox(InboxQuery)
  case locateAttention(AttentionReference)
  /// Marks exactly this occurrence seen; never resolves it.
  case markSeen(AttentionReference)
  /// Nil `until` clears the snooze.
  case snooze(AttentionReference, until: Date?)
  /// Dismisses a failure or result (`reviewed`); a request stays until
  /// the program resolves it.
  case markReviewed(AttentionReference)

  // Layout (lease required).
  case newTab(name: String?, launch: LaunchSpec?)
  case selectTab(TabID)
  case renameTab(TabID, name: String)
  case endTab(TabID)
  case split(pane: PaneID, axis: SplitAxis, launch: LaunchSpec?)
  case focusPane(PaneID)
  case toggleZoom(TabID)
  case setSplitRatio(tab: TabID, path: [Bool], ratio: Double)
  case endPane(PaneID)
  case setGeometry(GeometryBatch)
  /// Visible panes whose frames this attachment wants.
  case setSubscriptions([PaneID])
  /// Moves this attachment's viewport. Does not resize the PTY.
  /// Observers may call it; it never changes another viewer's anchor.
  case setViewport(ViewportRequest)

  // History: each attachment's viewport. Observers may scroll and search.
  case scroll(pane: PaneID, ScrollRequest)
  case search(pane: PaneID, query: String)
  case searchStep(pane: PaneID, forward: Bool)
  case endSearch(pane: PaneID)

  // Terminal control (lease required; `terminalControl`).
  /// Clears the screen, keeping the cursor's line at the top.
  case clearScreen(PaneID)
  /// Full terminal reset (RIS) of the pane's emulator; the process stays.
  case resetTerminal(PaneID)

  // Shell integration (`shellIntegration`); read-only.
  /// The link at a cell: an OSC 8 hyperlink, or with `detectURLs` a URL in
  /// the text. Replies `link`.
  case link(pane: PaneID, at: HistoryAddress, column: Int, detectURLs: Bool)
  /// The output of the command around `at` (nil: the most recent with
  /// output), from OSC 133 marks. Scrolls it into view; replies
  /// `commandOutput`.
  case commandOutput(pane: PaneID, at: HistoryAddress?)

  // Kitty clipboard (lease required; `kittyClipboard`).
  case clipboardReadResult(pane: PaneID, token: UInt64, MuxClipboardReadResult)
  case clipboardWriteResult(
    pane: PaneID,
    token: UInt64,
    MuxClipboardWriteResult
  )

  /// Admitted at the update barrier: status, leaving, ending sessions
  /// and toggling quiescence. Everything that changes the workspace
  /// graph or starts work is refused.
  public var allowedWhileQuiescing: Bool {
    switch self {
    case .status, .listWorkspaces, .detachActive, .detach, .endWorkspace,
      .endAllWorkspaces, .quiesce, .endPane, .endTab, .setGeometry,
      .setSubscriptions, .setViewport, .scroll, .searchStep, .endSearch,
      .clearScreen, .resetTerminal, .link, .commandOutput, .setTheme,
      .observeWorkspaces, .subscribeAutomation, .subscribeInbox, .inbox,
      .locateAttention, .markSeen, .snooze, .markReviewed, .clipboardReadResult,
      .clipboardWriteResult:
      true
    default: false
    }
  }

  /// Read-only viewer commands. Everything else is refused to an observer.
  public var allowedForObserver: Bool {
    switch self {
    case .status, .listWorkspaces, .detach, .observeWorkspaces,
      .subscribeAutomation, .subscribeInbox, .inbox, .locateAttention,
      .setSubscriptions, .setViewport, .scroll, .search, .searchStep,
      .endSearch:
      true
    default: false
    }
  }

  /// Whether this command needs the interactive lease.
  public var requiresLease: Bool {
    switch self {
    case .status, .listWorkspaces, .newWorkspace, .endWorkspace,
      .renameWorkspace, .detachActive, .endAllWorkspaces, .quiesce, .attach,
      .setTheme, .takeover, .observeWorkspaces, .subscribeAutomation,
      .subscribeInbox, .inbox, .locateAttention, .markSeen, .snooze,
      .markReviewed:
      false
    default: true
    }
  }
}

public struct MuxTheme: Codable, Sendable, Equatable {
  public var palette: FramePalette
  public var dark: Bool

  public init(palette: FramePalette, dark: Bool) {
    self.palette = palette
    self.dark = dark
  }

  public var isValid: Bool { palette.isValid }
}

public struct SearchResult: Codable, Sendable, Equatable {
  public var matchCount: Int
  public var selected: Int?

  public init(matchCount: Int, selected: Int?) {
    self.matchCount = matchCount
    self.selected = selected
  }

  /// No search: nothing matched, nothing selected.
  public static let empty = SearchResult(matchCount: 0, selected: nil)
}

public enum MuxReply: Codable, Sendable, Equatable {
  case ok
  case status(ServiceStatus)
  case workspaces([WorkspaceSummary])
  case created(WorkspaceSnapshot)
  case attached(attachment: AttachmentID, workspace: WorkspaceSnapshot)
  case layout(WorkspaceSnapshot)
  case pane(PaneID)
  case search(SearchResult)
  case inbox(InboxPage)
  case attention(AttentionLocation)
  case link(MuxLink?)
  case commandOutput(CommandOutput?)
}

/// A link found by `MuxCommand.link`.
public struct MuxLink: Codable, Sendable, Equatable {
  public var url: String
  /// Cells it covers, as history addresses (same generation as the query).
  public var start: HistoryAddress
  public var startColumn: Int
  public var end: HistoryAddress
  public var endColumn: Int

  public init(
    url: String,
    start: HistoryAddress,
    startColumn: Int,
    end: HistoryAddress,
    endColumn: Int
  ) {
    self.url = url
    self.start = start
    self.startColumn = startColumn
    self.end = end
    self.endColumn = endColumn
  }
}

/// A command's output found by `MuxCommand.commandOutput`: whole rows
/// from `start` through `end`, and their text (which may extend beyond
/// the rows a frame shows).
public struct CommandOutput: Codable, Sendable, Equatable {
  public var start: HistoryAddress
  public var end: HistoryAddress
  public var text: String

  public init(start: HistoryAddress, end: HistoryAddress, text: String) {
    self.start = start
    self.end = end
    self.text = text
  }
}

// MARK: Input

public struct MuxKeyModifiers: OptionSet, Codable, Sendable, Hashable {
  public var rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }
  public static let shift = MuxKeyModifiers(rawValue: 1 << 0)
  public static let alt = MuxKeyModifiers(rawValue: 1 << 1)
  public static let control = MuxKeyModifiers(rawValue: 1 << 2)
}

public enum MuxKey: Codable, Sendable, Hashable {
  case character(UInt32)
  case enter, tab, backspace, escape
  case up, down, left, right
  case home, end, pageUp, pageDown, insert, delete
  case function(Int)
  /// Requires `ServiceFeatures.keypadKeys`.
  case keypad(MuxKeypadKey)
}

/// Numeric keypad keys.
public enum MuxKeypadKey: String, Codable, CaseIterable, Sendable, Hashable {
  case zero, one, two, three, four, five, six, seven, eight, nine
  case decimal, divide, multiply, subtract, add, enter, equal, separator
  case left, right, up, down, pageUp, pageDown, home, end, insert, delete
  case begin
}

public struct MuxMouse: Codable, Sendable, Hashable {
  public enum Action: String, Codable, Sendable { case press, release, motion }
  public enum Button: String, Codable, Sendable {
    case left, middle, right, none, wheelUp, wheelDown, wheelLeft, wheelRight
  }

  public var action: Action
  public var button: Button
  public var column: Int
  public var row: Int
  public var modifiers: MuxKeyModifiers

  public init(
    _ action: Action,
    _ button: Button,
    column: Int,
    row: Int,
    modifiers: MuxKeyModifiers = []
  ) {
    self.action = action
    self.button = button
    self.column = column
    self.row = row
    self.modifiers = modifiers
  }
}

/// Semantic input; the service encodes it using authoritative pane modes.
public enum MuxInput: Codable, Sendable, Hashable {
  case text(String)
  case key(MuxKey, MuxKeyModifiers)
  case focus(Bool)
  /// A pointer event, encoded only while the pane's program enabled mouse
  /// reporting (`mouseReporting`). Coordinates are viewport cells.
  case mouse(MuxMouse)
  /// Click-to-move: arrow keys that move the shell's cursor to the cell,
  /// sent only while the shell edits a command line there (OSC 133;
  /// `shellIntegration`). Nothing is written otherwise.
  case moveCursor(HistoryAddress, column: Int)
  /// The user pasted from the clipboard while the program asked for kitty
  /// paste events (`SupportedViewModes.kittyPasteEvents`): the service
  /// reports these available types instead of typing (`kittyClipboard`).
  case clipboardPaste(types: [String])
  /// A native drag over the pane (`dropTargets`).
  case drag(MuxDrag)
  /// One bounded paste (at most `maxPasteChunkBytes`), admitted or
  /// refused whole and bracketed per the pane's modes. Larger pastes use
  /// the `pasteBegin`/`pasteChunk`/`pasteEnd` records.
  case paste(String)
}

extension MuxInput {
  /// Arrow presses a `moveCursor` may write, and their reserved bytes
  /// (three per press, the longest arrow encoding).
  public static let maxCursorMoves = 1024
  public static let moveCursorBytes = 3 * maxCursorMoves
}

public enum InputPayload: Codable, Sendable, Equatable {
  case input(MuxInput)
  /// Starts a paste fixed to this record's pane and attachment.
  case pasteBegin(id: UInt64)
  case pasteChunk(id: UInt64, text: String)
  case pasteEnd(id: UInt64)
  /// Abandons a paste: unstarted chunks are discarded and the envelope is
  /// closed, so later input is no longer deferred behind it.
  case pasteCancel(id: UInt64)
}

public struct InputRecord: Codable, Sendable, Equatable {
  /// Per attachment, starting at 1 and increasing by one. The service
  /// drops duplicates (at or below its watermark) and rejects gaps.
  public var sequence: UInt64
  public var attachment: AttachmentID
  public var pane: PaneID
  public var payload: InputPayload

  public init(
    sequence: UInt64,
    attachment: AttachmentID,
    pane: PaneID,
    payload: InputPayload
  ) {
    self.sequence = sequence
    self.attachment = attachment
    self.pane = pane
    self.payload = payload
  }
}

// MARK: Envelopes

public enum ClientMessage: Codable, Sendable {
  case hello(Hello)
  case request(id: UInt64, command: MuxCommand)
  case input(InputRecord)
  /// Releases transport credit for the pane's in-flight frame. A frame of
  /// any other attachment releases nothing.
  case frameAck(pane: PaneID, revision: UInt64, attachment: AttachmentID)
  /// The consumer took one `inbox` event (inbox flow control).
  case inboxAck(revision: UInt64)
}

public enum MuxEvent: Codable, Sendable {
  /// JSON-encoded automation presentation value, never executable code.
  case automation(Data)
  case frame(PaneFrame)
  case layout(WorkspaceSnapshot)
  /// `truncated`: an explicit end had to force-kill the processes, so
  /// final output may be incomplete.
  case paneExited(PaneID, status: Int32, truncated: Bool)
  case title(PaneID, String)
  case bell(PaneID)
  /// An unsubscribed pane in another tab of the attached workspace
  /// changed. Sent once until it is subscribed again.
  case activity(PaneID)
  /// Initial visible frames are installed. Hidden panes are not listed.
  case ready(ReadyNotice)
  /// The lease ended without this client asking (e.g. another client
  /// released it, or the workspace ended).
  case detached(reason: String)
  case paste(id: UInt64, state: PasteState)
  /// A frame could not be exported; the session is preserved.
  case frameUnavailable(PaneID, MuxError)
  /// Observers only (`observeWorkspaces`).
  case workspaces([WorkspaceSummary])
  /// Subscribers only (`subscribeInbox`), after reduction.
  case inbox(InboxUpdate)
  /// The controller only, with `ClientCapabilities.clipboardRequests`.
  case clipboardRead(MuxClipboardRead)
  case clipboardWrite(MuxClipboardWrite)
}

public enum PasteState: String, Codable, Sendable {
  case completed, aborted, partial
}

public enum ServerMessage: Codable, Sendable {
  case welcome(Welcome)
  case rejected(MuxError)
  case reply(id: UInt64, result: MuxResult)
  /// Admission to the ordered writer, not execution by the shell. A
  /// duplicate is acknowledged again without being written.
  case inputAck(sequence: UInt64, error: MuxError?)
  case event(MuxEvent)
}

public enum MuxResult: Codable, Sendable, Equatable {
  case success(MuxReply)
  case failure(MuxError)

  public func get() throws(MuxError) -> MuxReply {
    switch self {
    case let .success(r): return r
    case let .failure(e): throw e
    }
  }
}
