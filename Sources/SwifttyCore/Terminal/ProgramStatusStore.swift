/// The OSC 7501 records of one terminal: one per id, bounded, in update
/// order. Lives in `TerminalState`, so it outlasts any view.
public struct ProgramStatusStore: Sendable {
    /// Records kept; inserting past this evicts the least recently updated.
    public static let capacity = 256

    /// Least recently updated first.
    public private(set) var records: [ProgramStatusRecord] = []
    /// Incremented by every change; unchanged by ignored commands.
    public private(set) var revision: UInt64 = 0

    public init() {}

    public var snapshot: ProgramStatusSnapshot {
        ProgramStatusSnapshot(records: records, revision: revision)
    }

    /// Applies a report or clear; returns whether anything changed.
    @discardableResult
    mutating func apply(_ command: ProgramStatusCommand) -> Bool {
        switch command {
        case .query: false
        case let .report(record): replace(record)
        case let .clear(id?): remove { $0.id == id || ($0.id.hasPrefix(id) && $0.id.utf8.dropFirst(id.utf8.count).first == 0x2F) }
        case .clear(nil): removeAll()
        }
    }

    /// Whole-record replacement: omitted fields do not carry over, and the
    /// record becomes the newest.
    @discardableResult
    mutating func replace(_ record: ProgramStatusRecord) -> Bool {
        revision += 1
        if let i = records.firstIndex(where: { $0.id == record.id }) {
            records.remove(at: i)
        } else if records.count >= Self.capacity {
            records.removeFirst()
        }
        records.append(record.with(revision: revision))
        return true
    }

    /// Adopts `snapshot`'s records (the newest `capacity`) and at least its
    /// revision; returns whether anything changed.
    @discardableResult
    mutating func replaceAll(with snapshot: ProgramStatusSnapshot) -> Bool {
        let adopted = Array(snapshot.records.suffix(Self.capacity))
        guard adopted != records || snapshot.revision > revision else { return false }
        records = adopted
        revision = max(revision + 1, snapshot.revision)
        return true
    }

    @discardableResult
    mutating func removeAll() -> Bool {
        remove { _ in true }
    }

    /// Prompt start and process exit: `working`, `blocked` and `idle` no
    /// longer hold; `done` and `error` stay for the embedder to acknowledge.
    @discardableResult
    mutating func removeTransient() -> Bool {
        remove { $0.state != .done && $0.state != .error }
    }

    private mutating func remove(where matches: (ProgramStatusRecord) -> Bool) -> Bool {
        let before = records.count
        records.removeAll(where: matches)
        guard records.count != before else { return false }
        revision += 1
        return true
    }
}
