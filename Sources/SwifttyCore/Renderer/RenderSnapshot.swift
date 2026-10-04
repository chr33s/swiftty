/// Per-row metadata in a snapshot.
public struct RowSnapshot: Sendable, BitwiseCopyable {
    /// Row changed since the previous snapshot.
    public var isDirty: Bool
    public var isWrapped: Bool
}

public struct CursorState: Sendable, Equatable {
    public var x: Int
    public var y: Int
    public var isVisible: Bool
    public var style: CursorStyle
    public var isBlinking: Bool
}

/// Immutable view of the screen for the renderer.
///
/// Backed by pooled storage that is refilled only for damaged rows, so
/// producing a snapshot does not copy the whole grid every frame. Storage is
/// never mutated while any snapshot referencing it is alive.
public struct RenderSnapshot: @unchecked Sendable {
    let storage: SnapshotStorage
    // Base pointers into `storage`, valid while `storage` is retained. Kept
    // here (rather than read through the class) so span accessors do not
    // borrow the class reference; Swift 6.4's optimizer miscompiles that.
    private let rowBase: UnsafeMutablePointer<RowSnapshot>
    private let cellBase: UnsafeMutablePointer<Cell>
    private let graphemeScalarBase: UnsafeMutablePointer<UInt32>
    private let graphemeEntryBase: UnsafeMutablePointer<UInt64>
    public let columns: Int
    public let rowCount: Int
    public let cursor: CursorState
    /// Rows that changed since the previous snapshot returned by the session.
    public internal(set) var damage: DamageRegion
    public let palette: Palette
    public let modes: Modes
    public let viewportOffset: Int
    public let scrollbackCount: Int
    /// Monotonic counter; equal sequences mean identical content.
    public let sequence: UInt64

    init(
        storage: SnapshotStorage, columns: Int, rowCount: Int, cursor: CursorState, damage: DamageRegion,
        palette: Palette, modes: Modes, viewportOffset: Int, scrollbackCount: Int, sequence: UInt64,
    ) {
        self.storage = storage
        rowBase = storage.rowRecords
        cellBase = storage.cells
        graphemeScalarBase = storage.graphemeScalars
        graphemeEntryBase = storage.graphemeEntries
        self.columns = columns
        self.rowCount = rowCount
        self.cursor = cursor
        self.damage = damage
        self.palette = palette
        self.modes = modes
        self.viewportOffset = viewportOffset
        self.scrollbackCount = scrollbackCount
        self.sequence = sequence
    }

    public var rows: Span<RowSnapshot> {
        @_lifetime(borrow self) get {
            let span = Span(_unsafeStart: rowBase, count: rowCount)
            return _overrideLifetime(span, borrowing: self)
        }
    }

    @_lifetime(borrow self)
    public func cells(row y: Int) -> Span<Cell> {
        precondition(y >= 0 && y < rowCount)
        let span = Span(_unsafeStart: cellBase + y * columns, count: columns)
        return _overrideLifetime(span, borrowing: self)
    }

    /// Scalars of a `.grapheme` cell from this snapshot.
    @_lifetime(borrow self)
    public func graphemeScalars(_ cell: Cell) -> Span<UInt32> {
        precondition(cell.isGrapheme)
        let entry = graphemeEntryBase[Int(cell.glyph)]
        let span = Span(_unsafeStart: graphemeScalarBase + Int(entry >> 32), count: Int(entry & 0xFFFF_FFFF))
        return _overrideLifetime(span, borrowing: self)
    }

    /// Plain-text dump of the snapshot (tests and accessibility).
    public var text: [String] {
        var lines: [String] = []
        for y in 0 ..< rowCount {
            var s = String.UnicodeScalarView()
            let row = cells(row: y)
            for x in 0 ..< row.count {
                let cell = row[x]
                if cell.isSpacer {
                    continue
                }
                if cell.isGrapheme {
                    let scalars = graphemeScalars(cell)
                    for i in 0 ..< scalars.count {
                        s.append(Unicode.Scalar(scalars[i]) ?? "\u{FFFD}")
                    }
                } else {
                    s.append(cell.glyph == 0 ? " " : Unicode.Scalar(cell.glyph) ?? "\u{FFFD}")
                }
            }
            var line = String(s)
            while line.last == " " {
                line.removeLast()
            }
            lines.append(line)
        }
        return lines
    }
}

final class SnapshotStorage: @unchecked Sendable {
    private(set) var columns = 0
    private(set) var rows = 0
    private(set) var cells: UnsafeMutablePointer<Cell>
    private(set) var rowRecords: UnsafeMutablePointer<RowSnapshot>
    private var cellCapacity = 0
    private var rowCapacity = 0

    private(set) var graphemeScalars: UnsafeMutablePointer<UInt32>
    private(set) var graphemeEntries: UnsafeMutablePointer<UInt64>
    private var scalarCount = 0, scalarCapacity = 64
    private var entryCount = 0, entryCapacity = 16
    private(set) var hasGraphemes = false

    /// Damage accumulated since this storage was last filled.
    var pending = DamageRegion.full

    init() {
        cells = .allocate(capacity: 1)
        rowRecords = .allocate(capacity: 1)
        graphemeScalars = .allocate(capacity: scalarCapacity)
        graphemeEntries = .allocate(capacity: entryCapacity)
    }

    deinit {
        cells.deallocate()
        rowRecords.deallocate()
        graphemeScalars.deallocate()
        graphemeEntries.deallocate()
    }

    func ensureSize(columns: Int, rows: Int) {
        guard columns != self.columns || rows != self.rows else { return }
        if columns * rows > cellCapacity {
            cells.deallocate()
            cellCapacity = columns * rows
            cells = .allocate(capacity: cellCapacity)
        }
        if rows > rowCapacity {
            rowRecords.deallocate()
            rowCapacity = rows
            rowRecords = .allocate(capacity: rowCapacity)
        }
        self.columns = columns
        self.rows = rows
        pending.setFull()
    }

    /// Copies damaged rows from `state`; everything when graphemes are
    /// involved since their side table is rebuilt from scratch.
    func fill(from state: borrowing TerminalState, damage: DamageRegion) {
        var full = pending.isFull || hasGraphemes
        if !full {
            for y in 0 ..< rows where pending.contains(row: y) && state.viewportRow(y).cells.contains(where: \.isGrapheme) {
                full = true
                break
            }
        }
        if full {
            scalarCount = 0
            entryCount = 0
            hasGraphemes = false
        }
        for y in 0 ..< rows {
            let changed = full || pending.contains(row: y)
            rowRecords[y] = RowSnapshot(isDirty: damage.contains(row: y), isWrapped: false)
            guard changed else { continue }
            let (src, wrapped) = state.viewportRow(y)
            rowRecords[y].isWrapped = wrapped
            let dst = cells + y * columns
            let n = min(src.count, columns)
            if n > 0 {
                dst.update(from: src.baseAddress!, count: n)
            }
            if n < columns {
                (dst + n).update(repeating: .blank, count: columns - n)
            }
            for x in 0 ..< n where dst[x].isGrapheme {
                dst[x].glyph = appendGrapheme(state.graphemeScalars(dst[x].glyph))
                hasGraphemes = true
            }
        }
        pending = .none
    }

    private func appendGrapheme(_ scalars: UnsafeBufferPointer<UInt32>) -> UInt32 {
        if scalarCount + scalars.count > scalarCapacity {
            let grown = UnsafeMutablePointer<UInt32>.allocate(capacity: max(scalarCapacity * 2, scalarCount + scalars.count))
            grown.update(from: graphemeScalars, count: scalarCount)
            graphemeScalars.deallocate()
            graphemeScalars = grown
            scalarCapacity = max(scalarCapacity * 2, scalarCount + scalars.count)
        }
        if entryCount == entryCapacity {
            let grown = UnsafeMutablePointer<UInt64>.allocate(capacity: entryCapacity * 2)
            grown.update(from: graphemeEntries, count: entryCount)
            graphemeEntries.deallocate()
            graphemeEntries = grown
            entryCapacity *= 2
        }
        (graphemeScalars + scalarCount).update(from: scalars.baseAddress!, count: scalars.count)
        graphemeEntries[entryCount] = UInt64(scalarCount) << 32 | UInt64(scalars.count)
        scalarCount += scalars.count
        entryCount += 1
        return UInt32(entryCount - 1)
    }
}

/// Produces snapshots from terminal state using a small storage pool.
struct SnapshotBuilder {
    private var pool: [SnapshotStorage] = []
    private var sequence: UInt64 = 0
    private(set) var last: RenderSnapshot?

    init() {
        pool.reserveCapacity(3)
    }

    mutating func build(from state: inout TerminalState) -> RenderSnapshot {
        var damage = state.takeDamage()
        if state.viewportOffset > 0, !damage.isEmpty {
            damage.setFull()
        }
        if last == nil || last!.columns != state.columns || last!.rowCount != state.rows {
            damage.setFull()
        }
        for storage in pool {
            storage.pending.formUnion(damage)
        }

        let storage = takeFreeStorage()
        storage.ensureSize(columns: state.columns, rows: state.rows)
        storage.fill(from: state, damage: damage)

        sequence &+= 1
        let modes = state.modes
        let snapshot = RenderSnapshot(
            storage: storage,
            columns: state.columns,
            rowCount: state.rows,
            cursor: CursorState(
                x: state.cursor.x,
                y: state.cursor.y,
                isVisible: modes.contains(.cursorVisible) && state.viewportOffset == 0,
                style: state.cursorStyle,
                isBlinking: modes.contains(.cursorBlink),
            ),
            damage: damage,
            palette: state.palette,
            modes: modes,
            viewportOffset: state.viewportOffset,
            scrollbackCount: state.scrollbackCount,
            sequence: sequence,
        )
        last = snapshot
        return snapshot
    }

    /// The previous snapshot with no damage (synchronized output).
    func repeatLast() -> RenderSnapshot? {
        guard var snapshot = last else { return nil }
        snapshot.damage = .none
        return snapshot
    }

    private mutating func takeFreeStorage() -> SnapshotStorage {
        last = nil // drop our own reference so the last storage can be reused
        for i in pool.indices where isKnownUniquelyReferenced(&pool[i]) {
            return pool[i]
        }
        let storage = SnapshotStorage()
        if pool.count < 3 {
            pool.append(storage)
        } else {
            pool[0] = storage
        }
        return storage
    }
}
