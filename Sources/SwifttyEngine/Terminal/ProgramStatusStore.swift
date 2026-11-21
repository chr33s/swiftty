/// The OSC 7501 records of one terminal: one per id, bounded, in update
/// order. Lives in `TerminalState`, so it outlasts any view.
public struct ProgramStatusStore: Sendable {
  /// Default records kept; inserting past `limit` evicts the least
  /// recently updated.
  public static let capacity = 256
  /// The protocol's minimum record capacity.
  public static let minimumCapacity = 64

  /// Least recently updated first.
  public private(set) var records: [ProgramStatusRecord] = []
  /// Records kept, `minimumCapacity...capacity`.
  public private(set) var limit = Self.capacity
  /// Every change in stream order since the last `takeJournal()`, while
  /// `journalLimit` is positive.
  public private(set) var journal: [ProgramStatusChange] = []
  /// Changes past `journalLimit` were dropped: replay `records` instead.
  public private(set) var journalTruncated = false
  /// Changes kept between takes; 0 (the default) keeps none.
  public var journalLimit = 0 {
    didSet {
      if journalLimit <= 0 {
        _ = takeJournal()
      } else if journal.count > journalLimit {
        truncateJournal()
      }
    }
  }
  /// Incremented by every change, saturating at `UInt64.max`;
  /// unchanged by ignored commands. At the limit, compare snapshot
  /// records or use change notifications to observe further updates.
  public private(set) var revision: UInt64 = 0

  public init() {}

  private var nextRevision: UInt64 { revision == .max ? .max : revision + 1 }

  public var snapshot: ProgramStatusSnapshot {
    ProgramStatusSnapshot(records: records, revision: revision)
  }

  /// Sets `limit`, clamped to the protocol's range, evicting the least
  /// recently updated records past it.
  @discardableResult
  mutating func setLimit(_ n: Int) -> Bool {
    limit = min(max(n, Self.minimumCapacity), Self.capacity)
    let excess = records.count - limit
    guard excess > 0 else { return false }
    let evicted = records.prefix(excess).map(\.id)
    records.removeFirst(excess)
    revision = nextRevision
    record(.removed(evicted))
    return true
  }

  /// The journal since the last take, and whether it is incomplete.
  mutating func takeJournal() -> (
    changes: [ProgramStatusChange], truncated: Bool
  ) {
    defer {
      journal = []
      journalTruncated = false
    }
    return (journal, journalTruncated)
  }

  /// Past `journalLimit` the journal truncates; it then keeps only a
  /// single `.reset`, if one happened, so consumers still see it.
  private mutating func record(_ change: ProgramStatusChange) {
    guard journalLimit > 0 else { return }
    if !journalTruncated, journal.count >= journalLimit { truncateJournal() }
    guard journalTruncated else { return journal.append(change) }
    if change == .reset { journal = [.reset] }
  }

  private mutating func truncateJournal() {
    journalTruncated = true
    journal = journal.contains(.reset) ? [.reset] : []
  }

  /// Applies a report or clear; returns whether anything changed.
  @discardableResult
  mutating func apply(_ command: ProgramStatusCommand) -> Bool {
    switch command {
    case .query: false
    case let .report(record): replace(record)
    case let .clear(id?):
      remove {
        $0.id == id
          || ($0.id.hasPrefix(id)
            && $0.id.utf8.dropFirst(id.utf8.count).first == 0x2F)
      }
    case .clear(nil): removeAll()
    }
  }

  /// Whole-record replacement: omitted fields do not carry over, and the
  /// record becomes the newest.
  @discardableResult
  mutating func replace(_ record: ProgramStatusRecord) -> Bool {
    revision = nextRevision
    if let i = records.firstIndex(where: { $0.id == record.id }) {
      records.remove(at: i)
    } else if records.count >= limit {
      self.record(.removed([records.removeFirst().id]))
    }
    let stored = record.with(revision: revision)
    records.append(stored)
    self.record(.report(stored))
    return true
  }

  /// Adopts the newest record per id from `snapshot`, keeping the newest
  /// `capacity` distinct ids and at least its revision; returns whether
  /// anything changed.
  @discardableResult
  mutating func replaceAll(with snapshot: ProgramStatusSnapshot) -> Bool {
    var seen: Set<String> = []
    var adopted: [ProgramStatusRecord] = []
    adopted.reserveCapacity(min(snapshot.records.count, limit))
    for record in snapshot.records.reversed()
    where seen.insert(record.id).inserted {
      adopted.append(record)
      if adopted.count == limit { break }
    }
    adopted.reverse()
    guard adopted != records || snapshot.revision > revision else {
      return false
    }
    records = adopted
    revision = max(nextRevision, snapshot.revision)
    // Not a stream of changes: consumers replay the records.
    if journalLimit > 0 { truncateJournal() }
    return true
  }

  @discardableResult
  mutating func removeAll() -> Bool { remove { _ in true } }

  /// RIS: removes every record and journals the reset itself, so a
  /// journaling consumer sees it even with no records. Returns whether
  /// anything changed (always, while journaling).
  @discardableResult
  mutating func reset() -> Bool {
    let changed = !records.isEmpty
    if changed {
      records = []
      revision = nextRevision
    }
    guard journalLimit > 0 else { return changed }
    record(.reset)
    return true
  }

  /// Prompt start and process exit: `working`, `blocked` and `idle` no
  /// longer hold; `done` and `error` stay for the embedder to acknowledge.
  @discardableResult
  mutating func removeTransient() -> Bool {
    remove { $0.state != .done && $0.state != .error }
  }

  private mutating func remove(
    where matches: (ProgramStatusRecord) -> Bool
  ) -> Bool {
    let removed = records.filter(matches).map(\.id)
    guard !removed.isEmpty else { return false }
    records.removeAll(where: matches)
    revision = nextRevision
    record(.removed(removed))
    return true
  }
}

/// One store change, for consumers that must see every transition rather
/// than the latest records (an attention inbox).
public enum ProgramStatusChange: Sendable, Equatable {
  /// The record was written; it carries its new revision.
  case report(ProgramStatusRecord)
  /// Records removed by a clear, prompt, exit, eviction or disable.
  case removed([String])
  /// Full reset (RIS): every record is gone and the terminal starts over.
  case reset
}

/// The changes since the last take, then the records they produced.
public struct ProgramStatusJournal: Sendable, Equatable {
  /// In stream order; when `truncated`, at most a single `.reset`.
  public let changes: [ProgramStatusChange]
  /// The journal overflowed (or the records were replaced wholesale):
  /// some transitions are lost and `snapshot` is authoritative.
  public let truncated: Bool
  public let snapshot: ProgramStatusSnapshot
}

// MARK: Checkpoint (spec.durability.md §6)

extension ProgramStatusStore {
  /// Records, bounds and revision. The journal must have been taken: an
  /// untaken change is an unsettled external effect.
  package func checkpoint(
    into w: inout CheckpointWriter
  ) throws(CheckpointError) {
    guard journal.isEmpty, !journalTruncated else {
      throw CheckpointError("program status journal not taken")
    }
    w.int(limit)
    w.int(journalLimit)
    w.u64(revision)
    w.int(records.count)
    for record in records {
      w.string(record.id)
      w.u8(record.state.checkpointTag)
      w.bool(record.kind != nil)
      if let kind = record.kind { w.u8(kind.checkpointTag) }
      w.bool(record.progress != nil)
      if let progress = record.progress { w.u8(progress) }
      w.optionalString(record.app)
      w.optionalString(record.title)
      w.optionalString(record.message)
      w.u64(record.revision)
    }
  }

  package mutating func restore(
    from r: inout CheckpointReader
  ) throws(CheckpointError) {
    limit = try r.bounded(1 ... Self.capacity)
    journalLimit = try r.bounded(0 ... 1 << 20)
    revision = try r.u64()
    let count = try r.count(max: Self.capacity, minimumSize: 16)
    var restored: [ProgramStatusRecord] = []
    for _ in 0 ..< count {
      let id = try r.string(max: 1 << 10)
      let state = try ProgramStatusState(checkpointTag: try r.u8())
      let kind =
        try r.bool()
        ? try ProgramStatusBlockedKind(checkpointTag: try r.u8()) : nil
      let progress = try r.bool() ? try r.u8() : nil
      restored.append(
        ProgramStatusRecord(
          id: id,
          state: state,
          kind: kind,
          progress: progress,
          app: try r.optionalString(max: 1 << 12),
          title: try r.optionalString(max: 1 << 12),
          message: try r.optionalString(max: 1 << 16),
          revision: try r.u64()
        )
      )
    }
    records = restored
    journal = []
    journalTruncated = false
  }
}

extension ProgramStatusState {
  var checkpointTag: UInt8 {
    switch self {
    case .idle: 0
    case .working: 1
    case .done: 2
    case .blocked: 3
    case .error: 4
    }
  }
  init(checkpointTag: UInt8) throws(CheckpointError) {
    switch checkpointTag {
    case 0: self = .idle
    case 1: self = .working
    case 2: self = .done
    case 3: self = .blocked
    case 4: self = .error
    default: throw CheckpointError("invalid program status state")
    }
  }
}

extension ProgramStatusBlockedKind {
  var checkpointTag: UInt8 {
    switch self {
    case .permission: 0
    case .question: 1
    case .auth: 2
    }
  }
  init(checkpointTag: UInt8) throws(CheckpointError) {
    switch checkpointTag {
    case 0: self = .permission
    case 1: self = .question
    case 2: self = .auth
    default: throw CheckpointError("invalid blocked kind")
    }
  }
}
