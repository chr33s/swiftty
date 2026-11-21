import Foundation

// Saved layouts (spec.durability.md §12.2). Workers describe what a layout
// record needs; only the gateway stores it. None of these values restores a
// process or terminal state.

/// Why the graph changed since the gateway last read `savedLayoutState`.
public struct SavedLayoutCauses: OptionSet, Codable, Sendable, Hashable {
  public var rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }

  /// An attachment, CLI or automation command.
  public static let command = SavedLayoutCauses(rawValue: 1 << 0)
  /// A process exit or launch failure.
  public static let exit = SavedLayoutCauses(rawValue: 1 << 1)
  /// Names, directories or the output opt-out.
  public static let metadata = SavedLayoutCauses(rawValue: 1 << 2)
}

/// How a pane was started, as far as a reopened layout may repeat it.
public enum SavedPaneLaunch: Codable, Sendable, Equatable {
  case loginShell
  /// Runs only when a user explicitly chooses it at reopen time.
  case command([String])
  /// Longer than `SavedPaneLaunch.commandLimit`; reopens as a login shell.
  case commandTooLong

  /// Encoded argv bound (spec.durability.md §12.2.3).
  public static let commandLimit = 4 << 10

  public init(command: [String]?) {
    guard let command else {
      self = .loginShell
      return
    }
    let bytes = command.reduce(0) { $0 + $1.utf8.count + 1 }
    self = bytes <= Self.commandLimit ? .command(command) : .commandTooLong
  }
}

public struct SavedPaneMetadata: Codable, Sendable, Equatable {
  public var pane: PaneID
  public var launch: SavedPaneLaunch
  /// The last local working directory; nil when unknown or remote.
  public var localDirectory: String?
  /// The launcher could not enter the requested directory and used home.
  public var directoryFallback: Bool

  public init(
    pane: PaneID,
    launch: SavedPaneLaunch,
    localDirectory: String?,
    directoryFallback: Bool = false
  ) {
    self.pane = pane
    self.launch = launch
    self.localDirectory = localDirectory
    self.directoryFallback = directoryFallback
  }
}

/// Why a workspace ended; the issuer of End decides (§12.2.6).
public enum SavedLayoutDisposition: String, Codable, Sendable, Equatable {
  /// A user, CLI or automation End: delete the saved record.
  case ended
  /// An update, guardian maintenance, adoption or plain uninstall: keep it.
  case retained
}

/// Why a worker no longer publishes its workspace.
public enum SavedLayoutEnd: Codable, Sendable, Equatable {
  case ended(SavedLayoutDisposition)
  /// The last pane exited; the gateway deletes the record after its hold.
  case exited
}

/// The gateway-only view of a worker's layout for saving.
public struct SavedLayoutState: Codable, Sendable, Equatable {
  /// The same graph `observeWorkspaceGraph` returns, at the same point.
  public var graph: WorkspaceSnapshot?
  public var panes: [SavedPaneMetadata]
  /// The workspace's Don't Save Output flag.
  public var outputOptOut: Bool
  /// Accumulated since the previous read, which clears them.
  public var causes: SavedLayoutCauses
  /// Set once the workspace has ended; kept until the worker retires.
  public var end: SavedLayoutEnd?

  public init(
    graph: WorkspaceSnapshot?,
    panes: [SavedPaneMetadata],
    outputOptOut: Bool,
    causes: SavedLayoutCauses,
    end: SavedLayoutEnd?
  ) {
    self.graph = graph
    self.panes = panes
    self.outputOptOut = outputOptOut
    self.causes = causes
    self.end = end
  }
}

// MARK: Templates

/// A reopened workspace's split tree, by pane slot.
public indirect enum WorkspaceTemplateNode: Codable, Sendable, Equatable {
  case pane(slot: Int)
  case split(
    axis: SplitAxis,
    ratio: Double,
    first: WorkspaceTemplateNode,
    second: WorkspaceTemplateNode
  )

  public var slots: [Int] {
    switch self {
    case let .pane(slot): [slot]
    case let .split(_, _, first, second): first.slots + second.slots
    }
  }
}

public struct WorkspaceTemplateTab: Codable, Sendable, Equatable {
  public var name: String
  public var layout: WorkspaceTemplateNode
  public var activeSlot: Int
  public var zoomedSlot: Int?

  public init(
    name: String,
    layout: WorkspaceTemplateNode,
    activeSlot: Int,
    zoomedSlot: Int? = nil
  ) {
    self.name = name
    self.layout = layout
    self.activeSlot = activeSlot
    self.zoomedSlot = zoomedSlot
  }
}

/// Built by the gateway from a saved record and a frontend's launch settings.
/// Every pane starts fresh; nothing here replays input or a session.
public struct WorkspaceTemplate: Codable, Sendable, Equatable {
  public var name: String?
  public var columns: Int
  public var rows: Int
  public var remainOnExit: Bool
  /// The workspace launch used for new tabs, as for `newWorkspace`.
  public var launch: LaunchSpec
  /// Indexed by slot.
  public var panes: [LaunchSpec]
  public var tabs: [WorkspaceTemplateTab]
  public var activeTab: Int
  public var outputOptOut: Bool

  public init(
    name: String?,
    columns: Int,
    rows: Int,
    remainOnExit: Bool,
    launch: LaunchSpec,
    panes: [LaunchSpec],
    tabs: [WorkspaceTemplateTab],
    activeTab: Int,
    outputOptOut: Bool
  ) {
    self.name = name
    self.columns = columns
    self.rows = rows
    self.remainOnExit = remainOnExit
    self.launch = launch
    self.panes = panes
    self.tabs = tabs
    self.activeTab = activeTab
    self.outputOptOut = outputOptOut
  }

  /// Every slot is used exactly once, ratios are in (0, 1) and indices
  /// are in range. Checked before any pane starts.
  public func validate(maxPanes: Int) throws(MuxError) {
    let slots = tabs.flatMap(\.layout.slots)
    guard !tabs.isEmpty, !panes.isEmpty, panes.count <= maxPanes,
      slots.count == panes.count, Set(slots) == Set(0 ..< panes.count),
      tabs.indices.contains(activeTab),
      tabs.allSatisfy({ tab in
        tab.layout.slots.contains(tab.activeSlot)
          && tab.zoomedSlot.map { tab.layout.slots.contains($0) } ?? true
      }), tabs.allSatisfy({ Self.ratiosValid($0.layout) })
    else { throw MuxError(.invalidRequest, "invalid workspace template") }
  }

  private static func ratiosValid(_ node: WorkspaceTemplateNode) -> Bool {
    switch node {
    case .pane: true
    case let .split(_, ratio, first, second):
      ratio.isFinite && ratio > 0 && ratio < 1 && ratiosValid(first)
        && ratiosValid(second)
    }
  }
}

/// What a template creation started.
public struct WorkspaceTemplateOutcome: Codable, Sendable, Equatable {
  /// Pane identity for each slot that launched.
  public var panes: [Int: PaneID]
  /// Slots whose process failed to start; their panes were removed.
  public var failedSlots: [Int]
  /// Slots that started in home because their directory was unavailable.
  public var directoryFallbackSlots: [Int]

  public init(
    panes: [Int: PaneID],
    failedSlots: [Int],
    directoryFallbackSlots: [Int]
  ) {
    self.panes = panes
    self.failedSlots = failedSlots
    self.directoryFallbackSlots = directoryFallbackSlots
  }
}

// MARK: Local hosts

public enum SavedLayoutHost {
  /// Whether an OSC 7 host names this Mac: empty, `localhost`, or the host
  /// name with or without `.local` (case-insensitive).
  public static func isLocal(_ host: String?, localName: String? = nil) -> Bool
  {
    guard let host, !host.isEmpty else { return true }
    let candidate = normalized(host)
    if candidate == "localhost" { return true }
    guard let name = localName ?? currentHostName() else { return false }
    return candidate == normalized(name)
  }

  private static func normalized(_ name: String) -> String {
    var value = name.lowercased()
    if value.hasSuffix(".") { value.removeLast() }
    if value.hasSuffix(".local") { value.removeLast(6) }
    return value
  }

  /// `gethostname` only: no DNS lookup on the pane queue.
  public static func currentHostName() -> String? {
    var buffer = [CChar](repeating: 0, count: 256)
    guard gethostname(&buffer, buffer.count) == 0 else { return nil }
    buffer[buffer.count - 1] = 0
    let name = String(
      decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
      as: UTF8.self
    )
    return name.isEmpty ? nil : name
  }
}

// MARK: Gateway control

/// What the app does with Saved records when it launches.
public enum SavedReopenAtLaunch: String, Codable, Sendable, Equatable {
  case ask
  case automatic
  case never
}

/// Service-scoped, gateway-owned policy (spec.durability.md §12.2.2).
public struct SavedLayoutPolicy: Codable, Sendable, Equatable {
  /// Advanced by every accepted change.
  public var revision: UInt64
  public var saveLayout: Bool
  /// Requires `saveLayout`.
  public var saveOutput: Bool
  public var reopenAtLaunch: SavedReopenAtLaunch
  /// 1–365 days after a Saved record was first offered.
  public var retentionDays: Int

  public static let defaults = SavedLayoutPolicy(
    revision: 0,
    saveLayout: true,
    saveOutput: false,
    reopenAtLaunch: .ask,
    retentionDays: 30
  )

  public init(
    revision: UInt64,
    saveLayout: Bool,
    saveOutput: Bool,
    reopenAtLaunch: SavedReopenAtLaunch,
    retentionDays: Int
  ) {
    self.revision = revision
    self.saveLayout = saveLayout
    self.saveOutput = saveOutput
    self.reopenAtLaunch = reopenAtLaunch
    self.retentionDays = retentionDays
  }

  public var isValid: Bool {
    (1 ... 365).contains(retentionDays) && (saveLayout || !saveOutput)
  }
}

/// A saved record as a frontend may list it (§12.2.6).
public struct SavedWorkspaceListing: Codable, Sendable, Equatable {
  public enum State: String, Codable, Sendable, Equatable {
    /// The live workspace; nothing to reopen.
    case live
    /// Retained but unavailable; its layout can open in a new workspace.
    case unavailable
    case saved
    /// Written by a newer schema; listed, untouched, not reopenable.
    case newer
    /// Failed validation and was quarantined; not reopenable.
    case unreadable
  }

  public struct CommandSlot: Codable, Sendable, Equatable {
    public var slot: Int
    public var command: [String]
    public init(slot: Int, command: [String]) {
      self.slot = slot
      self.command = command
    }
  }

  public var id: WorkspaceID
  public var state: State
  public var name: String
  public var savedAt: Date?
  /// The writing build, when it differs from this gateway's.
  public var build: String?
  public var tabCount: Int
  public var paneCount: Int
  /// Panes that started a command; they run again only if chosen.
  public var commands: [CommandSlot]
  public var hasOutput: Bool

  public init(
    id: WorkspaceID,
    state: State,
    name: String,
    savedAt: Date?,
    build: String?,
    tabCount: Int,
    paneCount: Int,
    commands: [CommandSlot],
    hasOutput: Bool
  ) {
    self.id = id
    self.state = state
    self.name = name
    self.savedAt = savedAt
    self.build = build
    self.tabCount = tabCount
    self.paneCount = paneCount
    self.commands = commands
    self.hasOutput = hasOutput
  }
}

public struct SavedWorkspaceList: Codable, Sendable, Equatable {
  public enum StoreState: Codable, Sendable, Equatable {
    case available
    /// Keychain locked or denied; nothing is read, written or deleted.
    case unavailable(String)
    /// The key was missing, so earlier records were deleted.
    case keyLost
  }

  public var store: StoreState
  public var policy: SavedLayoutPolicy
  public var workspaces: [SavedWorkspaceListing]

  public init(
    store: StoreState,
    policy: SavedLayoutPolicy,
    workspaces: [SavedWorkspaceListing]
  ) {
    self.store = store
    self.policy = policy
    self.workspaces = workspaces
  }
}

/// A frontend's reopen request: the record contributes shape, names and
/// directories; launch settings come from the frontend, as for a new
/// workspace (§12.2.7).
public struct SavedReopenRequest: Codable, Sendable, Equatable {
  public var record: WorkspaceID
  /// Base launch; its command and directory are replaced per pane.
  public var launch: LaunchSpec
  public var columns: Int
  public var rows: Int
  public var remainOnExit: Bool
  /// Slots whose saved commands the user explicitly chose to run.
  public var runCommandSlots: [Int]

  public init(
    record: WorkspaceID,
    launch: LaunchSpec,
    columns: Int = 80,
    rows: Int = 24,
    remainOnExit: Bool = false,
    runCommandSlots: [Int] = []
  ) {
    self.record = record
    self.launch = launch
    self.columns = columns
    self.rows = rows
    self.remainOnExit = remainOnExit
    self.runCommandSlots = runCommandSlots
  }
}
