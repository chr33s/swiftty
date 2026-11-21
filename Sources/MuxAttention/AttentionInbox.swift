import Foundation
import SwiftMuxProtocol

/// The OSC 7501 attention reducer (spec.inbox.md §3). Pure and
/// synchronous: the owner feeds it status changes in stream order, with
/// a clock, and flushes `takeUpdate()` to subscribers afterwards, so
/// every transition is reduced before any coalescing.
///
/// Three models are kept apart:
/// 1. current status: the live records of each pane (`currentStatus`);
/// 2. occurrences: one `needsYou` item per stretch of `blocked`, with
///    seen and snooze state, resolved only by the program;
/// 3. retained outcomes: the latest unreviewed failure and result of
///    each source, kept until reviewed even after the program moves on.
///
/// Items are keyed by `AttentionSource` plus `OccurrenceID`, never by
/// program name or text. Memory is bounded by `MuxLimits`: records per
/// pane, decoded text (with a fixed per-item charge), resolved history
/// and page size.
public struct AttentionInbox: Sendable {
  public let serviceEpoch: ServerInstanceID
  public let limits: MuxLimits
  /// Advances with every item change.
  public private(set) var revision: UInt64 = 0
  /// Decoded current-status and item text, including record paths and
  /// inherited app names, plus `itemOverhead` per retained item.
  public private(set) var textBytes = 0

  /// Bytes charged per retained item on top of its text, so text-free
  /// items are bounded too.
  public static let itemOverhead = 256

  private struct Current: Codable {
    var incarnation: UInt64
    var record: StatusRecord
    var status: AttentionStatus
    /// The open `needsYou` occurrence while `blocked`.
    var request: OccurrenceID?
  }

  private struct PaneState: Codable {
    var epoch: TerminalEpochID
    var records: [String: Current] = [:]
    /// Least recently updated first.
    var order: [String] = []
    var nextIncarnation: UInt64 = 0
  }

  private struct Entry: Codable {
    var item: AttentionItem
    /// Creation order: the stable page order and cursor.
    var sequence: UInt64
    var bytes: Int
  }

  private var panes: [PaneID: PaneState] = [:]
  private var entries: [OccurrenceID: Entry] = [:]
  private var openFailure: [AttentionSource: OccurrenceID] = [:]
  private var openResult: [AttentionSource: OccurrenceID] = [:]
  /// Closed occurrences, oldest first; bounded by `resolvedHistory`.
  private var history: [OccurrenceID] = []
  private var nextSequence: UInt64 = 0
  private var pendingChanged: [OccurrenceID] = []
  private var pendingChangedSet: Set<OccurrenceID> = []
  private var pendingRemoved: Set<OccurrenceID> = []
  private var pendingResync = false

  public init(serviceEpoch: ServerInstanceID, limits: MuxLimits = .standard) {
    self.serviceEpoch = serviceEpoch
    self.limits = limits
  }

  // MARK: Planned replacement (spec.durability.md §6)

  private struct Snapshot: Codable {
    var serviceEpoch: ServerInstanceID
    var revision: UInt64
    var textBytes: Int
    var panes: [PaneID: PaneState]
    var entries: [OccurrenceID: Entry]
    var openFailure: [AttentionSource: OccurrenceID]
    var openResult: [AttentionSource: OccurrenceID]
    var history: [OccurrenceID]
    var nextSequence: UInt64
  }

  /// Items, records and occurrence bookkeeping. Pending change notices
  /// must have been flushed: they are undelivered effects.
  public func checkpoint() throws -> Data {
    guard pendingChanged.isEmpty, pendingRemoved.isEmpty, !pendingResync else {
      throw MuxError(.quiescing, "attention changes not yet delivered")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(
      Snapshot(
        serviceEpoch: serviceEpoch,
        revision: revision,
        textBytes: textBytes,
        panes: panes,
        entries: entries,
        openFailure: openFailure,
        openResult: openResult,
        history: history,
        nextSequence: nextSequence
      )
    )
  }

  /// The inbox continues under its original service epoch, so existing
  /// sources and locators keep their meaning after replacement.
  public init(checkpoint data: Data, limits: MuxLimits) throws {
    let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
    guard snapshot.entries.count <= limits.statusRecordsPerPane * 64 + 1024,
      snapshot.textBytes >= 0
    else { throw MuxError(.invalidRequest, "invalid attention checkpoint") }
    self.init(serviceEpoch: snapshot.serviceEpoch, limits: limits)
    revision = snapshot.revision
    textBytes = snapshot.textBytes
    panes = snapshot.panes
    entries = snapshot.entries
    openFailure = snapshot.openFailure
    openResult = snapshot.openResult
    history = snapshot.history
    nextSequence = snapshot.nextSequence
  }

  // MARK: Input

  /// Applies `changes` from `pane`, in order. A new `epoch` (terminal
  /// created or reset) first removes every record of the old one.
  public mutating func apply(
    _ changes: [StatusChange],
    pane: PaneID,
    epoch: TerminalEpochID,
    context: AttentionContext,
    at now: Date
  ) {
    var ps = panes[pane] ?? PaneState(epoch: epoch)
    if ps.epoch != epoch {
      for path in ps.order { remove(path, from: &ps, as: .resolved, at: now) }
      ps.epoch = epoch
    }
    for change in changes {
      switch change {
      case let .report(record):
        report(record, pane: pane, into: &ps, context: context, at: now)
      case let .removed(paths):
        for path in paths { remove(path, from: &ps, as: .resolved, at: now) }
      case let .sync(records):
        let listed = Set(records.map(\.path))
        for path in ps.order where !listed.contains(path) {
          remove(path, from: &ps, as: .resolved, at: now)
        }
        for record in records where ps.records[record.path]?.record != record {
          report(record, pane: pane, into: &ps, context: context, at: now)
        }
      }
    }
    panes[pane] = ps
    enforceTextBudget()
  }

  /// The pane's process exited and its final output and status were
  /// drained. Remaining requests close as `paneExited`; unreviewed
  /// failures and results stay unreviewed, marked `paneExited`.
  public mutating func paneExited(_ pane: PaneID, at now: Date) {
    if var ps = panes.removeValue(forKey: pane) {
      for path in ps.order { remove(path, from: &ps, as: .paneExited, at: now) }
    }
    for (id, entry) in entries
    where entry.item.source.pane == pane && entry.item.category != .needsYou
      && entry.item.resolution == .open
    { modify(id, at: now) { $0.resolution = .paneExited } }
  }

  // MARK: Acknowledgement

  /// Marks exactly `ref` seen; never resolves it. Returns what `ref`
  /// names afterwards.
  @discardableResult
  public mutating func markSeen(
    _ ref: AttentionReference,
    at now: Date
  ) -> AttentionLookup {
    if let id = exact(ref), entries[id]?.item.seen == false {
      modify(id, at: now) { $0.seen = true }
    }
    return lookup(ref)
  }

  /// Snoozes a current item until `until`; nil (or a past date) clears
  /// the snooze. Closed items are left alone.
  @discardableResult
  public mutating func snooze(
    _ ref: AttentionReference,
    until: Date?,
    at now: Date
  ) -> AttentionLookup {
    let until = until.flatMap { $0 > now ? $0 : nil }
    if let id = exact(ref), let item = entries[id]?.item, Self.isCurrent(item),
      item.snoozedUntil != until
    {
      modify(id, at: now) { $0.snoozedUntil = until }
    }
    return lookup(ref)
  }

  /// Reviews an unreviewed failure or result. A request cannot be
  /// reviewed: only the program resolves it.
  public mutating func markReviewed(
    _ ref: AttentionReference,
    at now: Date
  ) throws(MuxError) -> AttentionLookup {
    guard let id = exact(ref), let item = entries[id]?.item else {
      return .missing
    }
    guard item.category != .needsYou else {
      throw MuxError(
        .invalidRequest,
        "a request stays until the program resolves it"
      )
    }
    if Self.isUnreviewed(item) { close(id, as: .reviewed, at: now) }
    return lookup(ref)
  }

  /// Clears expired snoozes so subscribers hear about them.
  public mutating func expireSnoozes(at now: Date) {
    for (id, entry) in entries {
      if let until = entry.item.snoozedUntil, until <= now {
        modify(id, at: now) { $0.snoozedUntil = nil }
      }
    }
  }

  /// The earliest pending snooze expiry.
  public var nextSnoozeExpiry: Date? {
    entries.values.compactMap(\.item.snoozedUntil).min()
  }

  // MARK: Queries

  /// What `ref` names: every field must match.
  public func lookup(_ ref: AttentionReference) -> AttentionLookup {
    guard let id = exact(ref), let item = entries[id]?.item else {
      return .missing
    }
    if item.resolution == .paneExited { return .paneExited(item) }
    return Self.isCurrent(item) ? .available(item) : .stale(item)
  }

  /// Current reported records of `pane` (model 1), least recently
  /// updated first.
  public func currentStatus(of pane: PaneID) -> [AttentionStatus] {
    guard let ps = panes[pane] else { return [] }
    return ps.order.compactMap { ps.records[$0]?.status }
  }

  /// Retained items (tests, diagnostics).
  public var itemCount: Int { entries.count }

  public func item(_ id: OccurrenceID) -> AttentionItem? { entries[id]?.item }

  public func counts(at now: Date) -> InboxCounts {
    var needsYou: Set<AttentionSource> = []
    var results = 0
    for entry in entries.values {
      let item = entry.item
      guard Self.isCurrent(item), !item.isSnoozed(at: now) else { continue }
      switch item.category {
      case .needsYou, .failure: needsYou.insert(item.source)
      case .result: results += 1
      }
    }
    return InboxCounts(needsYou: needsYou.count, results: results)
  }

  /// One page, newest first. The cursor is stable across changes:
  /// later pages never repeat or skip items that existed when the first
  /// page was read.
  public func page(
    _ query: InboxQuery,
    at now: Date
  ) throws(MuxError) -> InboxPage {
    guard query.limit > 0 else { throw MuxError(.invalidRequest, "page limit") }
    let limit = min(query.limit, limits.inboxPageSize)
    var before = UInt64.max
    if let cursor = query.cursor {
      guard let s = Self.decodeCursor(cursor) else {
        throw MuxError(.invalidRequest, "inbox cursor")
      }
      before = s
    }
    guard limit > 0 else { throw MuxError(.resourceLimit, "inbox page budget") }
    let matching = entries.values
      .filter { $0.sequence < before && Self.matches($0.item, query.section) }
      .sorted { $0.sequence > $1.sequence }
    let items = matching.prefix(limit)
    return InboxPage(
      items: items.map(\.item),
      counts: counts(at: now),
      revision: revision,
      nextCursor: matching.count > limit
        ? Self.encodeCursor(items.last!.sequence) : nil
    )
  }

  /// Whether `takeUpdate` has anything to send.
  public var hasPendingUpdate: Bool {
    pendingResync || !pendingChanged.isEmpty || !pendingRemoved.isEmpty
  }

  /// Every item changed or removed since the last take, coalesced: an
  /// item appears once, in its latest state. An oversized change list
  /// becomes a resync notification; the retained inbox is unaffected.
  public mutating func takeUpdate(at now: Date) -> InboxUpdate? {
    guard hasPendingUpdate else { return nil }
    let changed = pendingChanged.compactMap { entries[$0] }
      .sorted { $0.sequence < $1.sequence }.map(\.item)
    let removed = pendingRemoved.sorted { $0.description < $1.description }
    let resync = pendingResync
    pendingChanged = []
    pendingChangedSet = []
    pendingRemoved = []
    pendingResync = false
    return InboxUpdate(
      revision: revision,
      counts: counts(at: now),
      changed: changed,
      removed: removed,
      resync: resync
    )
  }

  // MARK: Transitions

  private mutating func report(
    _ record: StatusRecord,
    pane: PaneID,
    into ps: inout PaneState,
    context: AttentionContext,
    at now: Date
  ) {
    let previous = ps.records[record.path]
    var incarnation = previous?.incarnation ?? 0
    if previous == nil {
      // Unique per terminal epoch: a recreated path is a new source.
      ps.nextIncarnation += 1
      incarnation = ps.nextIncarnation
      if ps.order.count >= limits.statusRecordsPerPane,
        let oldest = ps.order.first
      {
        remove(oldest, from: &ps, as: .resolved, at: now)
      }
    }
    let source = AttentionSource(
      serviceEpoch: serviceEpoch,
      pane: pane,
      terminalEpoch: ps.epoch,
      recordPath: record.path,
      recordIncarnation: incarnation
    )
    let status = AttentionStatus(
      source: source,
      state: record.state,
      kind: record.kind,
      progress: record.progress,
      app: record.app ?? Self.inheritedApp(record.path, in: ps),
      title: record.title,
      message: record.message,
      updatedAt: now
    )
    var request = previous?.request
    if record.state == .blocked {
      if let id = request {
        // Repeated blocked or progress: the same occurrence.
        modify(id, at: now) { $0.status = status }
      } else {
        request = create(.needsYou, status, context: context, at: now)
      }
    } else {
      if let id = request {
        close(id, as: .resolved, at: now)
        request = nil
      }
      switch record.state {
      case .error:
        retain(.failure, status, previous: previous, context: context, at: now)
      case .done:
        retain(.result, status, previous: previous, context: context, at: now)
      default: break  // done → working keeps the unreviewed result
      }
    }
    if let previous { textBytes -= previous.status.textBytes }
    textBytes += status.textBytes
    ps.records[record.path] = Current(
      incarnation: incarnation,
      record: record,
      status: status,
      request: request
    )
    ps.order.removeAll { $0 == record.path }
    ps.order.append(record.path)
  }

  /// The latest failure or result of a source: a repeated report updates
  /// it, a new one supersedes the previous unreviewed one.
  private mutating func retain(
    _ category: AttentionCategory,
    _ status: AttentionStatus,
    previous: Current?,
    context: AttentionContext,
    at now: Date
  ) {
    let source = status.source
    let open = category == .failure ? openFailure[source] : openResult[source]
    if let id = open, previous?.record.state == status.state,
      entries[id]?.item.resolution == .open
    {
      modify(id, at: now) { $0.status = status }
      return
    }
    if let old = open { close(old, as: .superseded, at: now) }
    let id = create(category, status, context: context, at: now)
    if category == .failure {
      openFailure[source] = id
    } else {
      openResult[source] = id
    }
  }

  private mutating func remove(
    _ path: String,
    from ps: inout PaneState,
    as resolution: AttentionResolution,
    at now: Date
  ) {
    guard let current = ps.records.removeValue(forKey: path) else { return }
    ps.order.removeAll { $0 == path }
    textBytes -= current.status.textBytes
    if let id = current.request { close(id, as: resolution, at: now) }
  }

  private mutating func create(
    _ category: AttentionCategory,
    _ status: AttentionStatus,
    context: AttentionContext,
    at now: Date
  ) -> OccurrenceID {
    let id = OccurrenceID()
    revision &+= 1
    nextSequence &+= 1
    let item = AttentionItem(
      occurrence: id,
      source: status.source,
      workspace: context.workspace,
      tab: context.tab,
      category: category,
      resolution: .open,
      status: status,
      createdAt: now,
      updatedAt: now,
      revision: revision
    )
    let bytes = Self.itemOverhead + status.textBytes
    entries[id] = Entry(item: item, sequence: nextSequence, bytes: bytes)
    textBytes += bytes
    noteChanged(id)
    return id
  }

  private mutating func modify(
    _ id: OccurrenceID,
    at now: Date,
    _ body: (inout AttentionItem) -> Void
  ) {
    guard var entry = entries[id] else { return }
    body(&entry.item)
    revision &+= 1
    entry.item.revision = revision
    entry.item.updatedAt = now
    let bytes = Self.itemOverhead + entry.item.status.textBytes
    textBytes += bytes - entry.bytes
    entry.bytes = bytes
    entries[id] = entry
    noteChanged(id)
  }

  /// Closes an item for good and moves it into bounded history.
  private mutating func close(
    _ id: OccurrenceID,
    as resolution: AttentionResolution,
    at now: Date
  ) {
    guard let item = entries[id]?.item, Self.isCurrent(item) else { return }
    modify(id, at: now) {
      $0.resolution = resolution
      $0.snoozedUntil = nil
    }
    if openFailure[item.source] == id { openFailure[item.source] = nil }
    if openResult[item.source] == id { openResult[item.source] = nil }
    history.append(id)
    while history.count > limits.resolvedHistory {
      evict(history.removeFirst())
    }
  }

  private mutating func evict(_ id: OccurrenceID) {
    guard let entry = entries.removeValue(forKey: id) else { return }
    textBytes -= entry.bytes
    let source = entry.item.source
    if openFailure[source] == id { openFailure[source] = nil }
    if openResult[source] == id { openResult[source] = nil }
    if pendingChangedSet.remove(id) != nil {
      pendingChanged.removeAll { $0 == id }
    }
    if !pendingResync {
      pendingRemoved.insert(id)
      limitPendingChanges()
    }
  }

  /// Evicts history oldest first, then the oldest unreviewed results,
  /// then failures. Current records and open requests are bounded per
  /// pane and never evicted here.
  private mutating func enforceTextBudget() {
    while textBytes > limits.statusTextBytes, !history.isEmpty {
      evict(history.removeFirst())
    }
    for category in [AttentionCategory.result, .failure]
    where textBytes > limits.statusTextBytes {
      let oldest = entries.filter { $0.value.item.category == category }
        .sorted { $0.value.sequence < $1.value.sequence }.map(\.key)
      for id in oldest where textBytes > limits.statusTextBytes { evict(id) }
    }
  }

  private mutating func noteChanged(_ id: OccurrenceID) {
    guard !pendingResync else { return }
    if pendingChangedSet.insert(id).inserted {
      pendingChanged.append(id)
      limitPendingChanges()
    }
  }

  /// Charge pending IDs conservatively against the control-record
  /// budget. After overflow, keep only the need to refetch rather than
  /// accumulating tombstones until the owner gets a chance to flush.
  private mutating func limitPendingChanges() {
    let limit = max(1, limits.maxControlRecordBytes / Self.itemOverhead)
    guard pendingChanged.count + pendingRemoved.count > limit else { return }
    pendingResync = true
    pendingChanged = []
    pendingChangedSet = []
    pendingRemoved = []
  }

  // MARK: Helpers

  private func exact(_ ref: AttentionReference) -> OccurrenceID? {
    guard ref.source.serviceEpoch == serviceEpoch,
      entries[ref.occurrence]?.item.source == ref.source
    else { return nil }
    return ref.occurrence
  }

  /// A request still waiting, or a failure or result not yet reviewed.
  static func isCurrent(_ item: AttentionItem) -> Bool {
    item.category == .needsYou ? item.resolution == .open : isUnreviewed(item)
  }

  static func isUnreviewed(_ item: AttentionItem) -> Bool {
    item.category != .needsYou
      && (item.resolution == .open || item.resolution == .paneExited)
  }

  static func matches(
    _ item: AttentionItem,
    _ section: InboxQuery.Section
  ) -> Bool {
    switch section {
    case .needsYou: item.category != .result && isCurrent(item)
    case .results: item.category == .result && isCurrent(item)
    case .all: true
    }
  }

  /// The nearest ancestor's `app` (`build/test` → `build` → root).
  private static func inheritedApp(_ path: String, in ps: PaneState) -> String?
  {
    var p = Substring(path)
    while !p.isEmpty {
      p = p.lastIndex(of: "/").map { p[..<$0] } ?? ""
      if let app = ps.records[String(p)]?.record.app { return app }
    }
    return nil
  }

  static func encodeCursor(_ sequence: UInt64) -> String {
    Data("i1:\(sequence)".utf8).base64EncodedString()
  }

  static func decodeCursor(_ cursor: String) -> UInt64? {
    guard cursor.utf8.count <= 64, let data = Data(base64Encoded: cursor),
      let text = String(data: data, encoding: .utf8), text.hasPrefix("i1:")
    else { return nil }
    return UInt64(text.dropFirst(3))
  }
}

extension AttentionStatus {
  var textBytes: Int {
    source.recordPath.utf8.count + (app?.utf8.count ?? 0)
      + (title?.utf8.count ?? 0) + (message?.utf8.count ?? 0)
  }
}
