import Foundation

// OSC 7501 attention inbox (spec.inbox.md §3). These are the
// wire values; the reducer that produces them lives in MuxAttention.

public enum TerminalEpochTag: Sendable {}
public enum OccurrenceTag: Sendable {}

/// Changes when a pane's terminal is reset (RIS) or its program status
/// store is otherwise discarded, so records with equal paths from before
/// and after the reset are never confused.
public typealias TerminalEpochID = MuxID<TerminalEpochTag>
/// One attention occurrence: a single stretch of `blocked`, one failure
/// or one result. A source that blocks again gets a new occurrence.
public typealias OccurrenceID = MuxID<OccurrenceTag>

/// Who reported a status. Never keyed by program name or message text.
public struct AttentionSource: Codable, Sendable, Hashable {
  public var serviceEpoch: ServerInstanceID
  /// Pane IDs are never reused, so this is also the pane instance.
  public var pane: PaneID
  public var terminalEpoch: TerminalEpochID
  /// OSC 7501 record id; `""` is the root record.
  public var recordPath: String
  /// Increments each time the record is created again after a clear.
  public var recordIncarnation: UInt64

  public init(
    serviceEpoch: ServerInstanceID,
    pane: PaneID,
    terminalEpoch: TerminalEpochID,
    recordPath: String,
    recordIncarnation: UInt64
  ) {
    self.serviceEpoch = serviceEpoch
    self.pane = pane
    self.terminalEpoch = terminalEpoch
    self.recordPath = recordPath
    self.recordIncarnation = recordIncarnation
  }
}

public enum AttentionState: String, Codable, Sendable {
  case idle, working, done, blocked, error
}

public enum AttentionBlockedKind: String, Codable, Sendable {
  case permission, question, auth
}

/// The current reported status of one record (model 1).
public struct AttentionStatus: Codable, Sendable, Hashable {
  public var source: AttentionSource
  public var state: AttentionState
  public var kind: AttentionBlockedKind?
  public var progress: UInt8?
  /// Untrusted program text: display only, never markup or navigation.
  public var app: String?
  public var title: String?
  public var message: String?
  public var updatedAt: Date

  public init(
    source: AttentionSource,
    state: AttentionState,
    kind: AttentionBlockedKind? = nil,
    progress: UInt8? = nil,
    app: String? = nil,
    title: String? = nil,
    message: String? = nil,
    updatedAt: Date
  ) {
    self.source = source
    self.state = state
    self.kind = kind
    self.progress = progress
    self.app = app
    self.title = title
    self.message = message
    self.updatedAt = updatedAt
  }
}

public enum AttentionCategory: String, Codable, Sendable {
  /// A current `blocked` request.
  case needsYou
  /// An unreviewed `error`.
  case failure
  /// The latest unreviewed `done` of a source.
  case result
}

public enum AttentionResolution: String, Codable, Sendable {
  /// Still waiting (needsYou) or unreviewed (failure/result).
  case open
  /// The program moved on (`blocked → working`, prompt, clear).
  case resolved
  /// A newer occurrence of the same source replaced this one.
  case superseded
  case reviewed
  /// The pane exited; final output may still be retained.
  case paneExited
}

/// One attention occurrence (model 2), or a source's retained result
/// (model 3).
public struct AttentionItem: Codable, Sendable, Hashable {
  public var occurrence: OccurrenceID
  public var source: AttentionSource
  public var workspace: WorkspaceID
  public var tab: TabID?
  public var category: AttentionCategory
  public var resolution: AttentionResolution
  /// Status that opened or last updated this occurrence.
  public var status: AttentionStatus
  public var createdAt: Date
  public var updatedAt: Date
  /// Opening an item marks it seen; it does not resolve it.
  public var seen: Bool
  public var snoozedUntil: Date?
  /// Increments on every change; lets clients drop stale deltas.
  public var revision: UInt64

  public init(
    occurrence: OccurrenceID,
    source: AttentionSource,
    workspace: WorkspaceID,
    tab: TabID?,
    category: AttentionCategory,
    resolution: AttentionResolution,
    status: AttentionStatus,
    createdAt: Date,
    updatedAt: Date,
    seen: Bool = false,
    snoozedUntil: Date? = nil,
    revision: UInt64
  ) {
    self.occurrence = occurrence
    self.source = source
    self.workspace = workspace
    self.tab = tab
    self.category = category
    self.resolution = resolution
    self.status = status
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.seen = seen
    self.snoozedUntil = snoozedUntil
    self.revision = revision
  }

  public func isSnoozed(at now: Date) -> Bool {
    snoozedUntil.map { $0 > now } ?? false
  }
}

/// Exactly one occurrence; every component must still match.
public struct AttentionReference: Codable, Sendable, Hashable {
  public var source: AttentionSource
  public var occurrence: OccurrenceID

  public init(source: AttentionSource, occurrence: OccurrenceID) {
    self.source = source
    self.occurrence = occurrence
  }
}

public struct InboxCounts: Codable, Sendable, Hashable {
  /// Distinct sources with a current unsnoozed request or an unreviewed
  /// failure: the main badge.
  public var needsYou: Int
  /// Unreviewed results.
  public var results: Int

  public init(needsYou: Int = 0, results: Int = 0) {
    self.needsYou = needsYou
    self.results = results
  }
}

public struct InboxQuery: Codable, Sendable, Hashable {
  public enum Section: String, Codable, Sendable {
    /// Open needsYou and failure items.
    case needsYou
    case results
    /// Everything retained, including resolved history.
    case all
  }

  public var section: Section
  /// Opaque cursor from a previous page.
  public var cursor: String?
  /// At most `MuxLimits.inboxPageSize`.
  public var limit: Int

  public init(
    section: Section = .needsYou,
    cursor: String? = nil,
    limit: Int = 100
  ) {
    self.section = section
    self.cursor = cursor
    self.limit = limit
  }
}

public struct InboxPage: Codable, Sendable, Hashable {
  public var items: [AttentionItem]
  public var counts: InboxCounts
  /// Inbox revision the page was read at.
  public var revision: UInt64
  public var nextCursor: String?

  public init(
    items: [AttentionItem],
    counts: InboxCounts,
    revision: UInt64,
    nextCursor: String?
  ) {
    self.items = items
    self.counts = counts
    self.revision = revision
    self.nextCursor = nextCursor
  }
}

/// Coalesced inbox change, sent to subscribers after reduction.
public struct InboxUpdate: Codable, Sendable, Hashable {
  public var revision: UInt64
  public var counts: InboxCounts
  public var changed: [AttentionItem]
  public var removed: [OccurrenceID]
  /// Set when a change batch or subscriber backlog exceeded its budget:
  /// refetch the current inbox.
  public var resync: Bool

  public init(
    revision: UInt64,
    counts: InboxCounts,
    changed: [AttentionItem],
    removed: [OccurrenceID],
    resync: Bool = false
  ) {
    self.revision = revision
    self.counts = counts
    self.changed = changed
    self.removed = removed
    self.resync = resync
  }
}

/// Where an occurrence lives now, read without a lease.
public struct AttentionLocation: Codable, Sendable, Hashable {
  public enum Availability: String, Codable, Sendable {
    /// The pane is live and the occurrence is current.
    case available
    /// The occurrence exists but was resolved, reviewed or superseded.
    case stale
    /// The pane exited; its retained final screen may be shown.
    case paneExited
    /// Unknown occurrence, other service epoch or replaced terminal.
    case missing
  }

  public var availability: Availability
  public var item: AttentionItem?
  public var workspace: WorkspaceID?
  public var tab: TabID?
  public var pane: PaneID?
  /// Another attachment holds the workspace's interactive lease.
  public var leaseHeldElsewhere: Bool

  public init(
    availability: Availability,
    item: AttentionItem? = nil,
    workspace: WorkspaceID? = nil,
    tab: TabID? = nil,
    pane: PaneID? = nil,
    leaseHeldElsewhere: Bool = false
  ) {
    self.availability = availability
    self.item = item
    self.workspace = workspace
    self.tab = tab
    self.pane = pane
    self.leaseHeldElsewhere = leaseHeldElsewhere
  }
}
