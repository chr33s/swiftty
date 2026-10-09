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

/// A highlighted span in snapshot rows (inclusive; rows may lie outside
/// the snapshot when the span is partly scrolled out).
public struct HighlightSpan: Sendable, Equatable {
    public var startRow: Int
    public var startColumn: Int
    public var endRow: Int
    public var endColumn: Int
    public var rectangle: Bool

    public init(startRow: Int, startColumn: Int, endRow: Int, endColumn: Int, rectangle: Bool = false) {
        self.startRow = startRow
        self.startColumn = startColumn
        self.endRow = endRow
        self.endColumn = endColumn
        self.rectangle = rectangle
    }

    public func contains(row: Int, column: Int) -> Bool {
        guard row >= startRow, row <= endRow else { return false }
        if rectangle {
            return column >= min(startColumn, endColumn) && column <= max(startColumn, endColumn)
        }
        if row == startRow, column < startColumn {
            return false
        }
        if row == endRow, column > endColumn {
            return false
        }
        return true
    }
}

/// Stable identity of the builder that produced a snapshot.
final class SnapshotSource: Sendable {}

/// Immutable view of the screen for the renderer.
///
/// Backed by pooled storage that is refilled only for damaged rows, so
/// producing a snapshot does not copy the whole grid every frame. Storage is
/// never mutated while any snapshot referencing it is alive.
public struct RenderSnapshot: @unchecked Sendable {
    let storage: SnapshotStorage
    let source: SnapshotSource
    // Base pointers into `storage`, valid while `storage` is retained. Kept
    // here (rather than read through the class) so span accessors do not
    // borrow the class reference; Swift 6.4's optimizer miscompiles that.
    private let rowBase: UnsafeMutablePointer<RowSnapshot>
    private let cellBase: UnsafeMutablePointer<Cell>
    private let graphemeScalarBase: UnsafeMutablePointer<UInt32>
    private let graphemeEntryBase: UnsafeMutablePointer<UInt64>
    public let columns: Int
    /// Visible rows plus `overscanRows` rows below them.
    public let rowCount: Int
    /// Rows after the screen's last row, drawn when the viewport is offset by
    /// a fraction of a row (smooth scrolling) or into a bottom inset.
    public let overscanRows: Int
    public let cursor: CursorState
    public let selection: HighlightSpan?
    /// Visible search matches, ordered by both start and end position.
    public let searchMatches: [HighlightSpan]
    /// Index into `searchMatches` of the selected match, if visible.
    public let selectedSearchMatch: Int?
    /// Total matches and selected index across the screen and scrollback.
    public let searchMatchCount: Int
    public let searchSelectedIndex: Int?
    /// Rows that changed since the previous snapshot returned by the session.
    public internal(set) var damage: DamageRegion
    public let palette: Palette
    /// Colors for `CellAttributes.underlineColor` ids (id 1 is index 0).
    public let underlineColors: [TerminalColor]
    public let modes: Modes
    public let viewportOffset: Int
    public let scrollbackCount: Int
    /// Monotonic counter within one session; equal sequences from that
    /// session mean identical content.
    public let sequence: UInt64

    init(
        storage: SnapshotStorage, source: SnapshotSource, columns: Int, rowCount: Int, overscanRows: Int, cursor: CursorState,
        selection: HighlightSpan?, searchMatches: [HighlightSpan], selectedSearchMatch: Int?,
        searchMatchCount: Int, searchSelectedIndex: Int?,
        damage: DamageRegion, palette: Palette, underlineColors: [TerminalColor] = [], modes: Modes,
        viewportOffset: Int, scrollbackCount: Int, sequence: UInt64,
    ) {
        self.storage = storage
        self.source = source
        rowBase = storage.rowRecords
        cellBase = storage.cells
        graphemeScalarBase = storage.graphemeScalars
        graphemeEntryBase = storage.graphemeEntries
        self.columns = columns
        self.rowCount = rowCount
        self.overscanRows = overscanRows
        self.cursor = cursor
        self.selection = selection
        self.searchMatches = searchMatches
        self.selectedSearchMatch = selectedSearchMatch
        self.searchMatchCount = searchMatchCount
        self.searchSelectedIndex = searchSelectedIndex
        self.damage = damage
        self.palette = palette
        self.underlineColors = underlineColors
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
    /// involved in a changed frame since their side table is rebuilt from scratch.
    func fill(from state: borrowing TerminalState, damage: DamageRegion) {
        var full = pending.isFull || (hasGraphemes && !pending.isEmpty)
        if !full {
            for y in 0 ..< rows where pending.contains(row: y) && Self.row(y, of: state).cells.contains(where: \.isGrapheme) {
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
            guard changed else {
                rowRecords[y].isDirty = damage.contains(row: y) // isWrapped is still current
                continue
            }
            let (src, wrapped) = Self.row(y, of: state)
            rowRecords[y] = RowSnapshot(isDirty: damage.contains(row: y), isWrapped: wrapped)
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

    /// Visible row `y`, or for `y >= state.rows` the overscan row below.
    static func row(_ y: Int, of state: borrowing TerminalState) -> (cells: UnsafeBufferPointer<Cell>, wrapped: Bool) {
        if y < state.rows {
            return state.viewportRow(y)
        }
        return state.line(absoluteRow: state.absoluteRow(viewportRow: y)) ?? (UnsafeBufferPointer(start: nil, count: 0), false)
    }

    private func appendGrapheme(_ scalars: borrowing Span<UInt32>) -> UInt32 {
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
        scalars.withUnsafeBufferPointer { buffer in
            (graphemeScalars + scalarCount).update(from: buffer.baseAddress!, count: buffer.count)
        }
        graphemeEntries[entryCount] = UInt64(scalarCount) << 32 | UInt64(scalars.count)
        scalarCount += scalars.count
        entryCount += 1
        return UInt32(entryCount - 1)
    }
}

/// Produces snapshots from terminal state using a small storage pool.
struct SnapshotBuilder {
    private let source = SnapshotSource()
    private var pool: [SnapshotStorage] = []
    private var sequence: UInt64 = 0
    private(set) var last: RenderSnapshot?

    init() {
        pool.reserveCapacity(3)
    }

    mutating func build(from state: inout TerminalState, overscan: Int = 0) -> RenderSnapshot {
        state.refreshSearchIfNeeded()
        var damage = state.takeDamage()
        if state.viewportOffset > 0, !damage.isEmpty {
            damage.setFull()
        }
        // Overscan rows exist only while scrolled back: the rows below the
        // viewport are then still on screen or in history.
        let extra = min(max(overscan, 0), state.viewportOffset)
        let rowCount = state.rows + extra
        if last == nil || last!.columns != state.columns || last!.rowCount != rowCount {
            damage.setFull()
        }
        for storage in pool {
            storage.pending.formUnion(damage)
        }

        let storage = takeFreeStorage()
        storage.ensureSize(columns: state.columns, rows: rowCount)
        storage.fill(from: state, damage: damage)

        sequence &+= 1
        let modes = state.modes
        func span(_ start: TerminalPoint, _ end: TerminalPoint, rectangle: Bool) -> HighlightSpan {
            HighlightSpan(
                startRow: state.viewportRow(absoluteRow: start.row), startColumn: start.column,
                endRow: state.viewportRow(absoluteRow: end.row), endColumn: end.column, rectangle: rectangle,
            )
        }
        let selection = state.selection.map { span($0.start, $0.end, rectangle: $0.rectangle) }
        var matches: [HighlightSpan] = []
        var selectedMatch: Int?
        if !state.searchMatches.isEmpty {
            let top = state.absoluteRow(viewportRow: 0), bottom = top + rowCount - 1
            // Match starts and ends are monotonic. Skip history outside the
            // viewport without walking every result on each redraw.
            var first = 0, upper = state.searchMatches.count
            while first < upper {
                let middle = first + (upper - first) / 2
                if state.searchMatches[middle].end.row < top {
                    first = middle + 1
                } else {
                    upper = middle
                }
            }
            var end = first
            upper = state.searchMatches.count
            while end < upper {
                let middle = end + (upper - end) / 2
                if state.searchMatches[middle].start.row <= bottom {
                    end = middle + 1
                } else {
                    upper = middle
                }
            }
            matches.reserveCapacity(end - first)
            for i in first ..< end {
                let m = state.searchMatches[i]
                if i == state.searchSelected {
                    selectedMatch = matches.count
                }
                matches.append(span(m.start, m.end, rectangle: false))
            }
        }
        let snapshot = RenderSnapshot(
            storage: storage,
            source: source,
            columns: state.columns,
            rowCount: rowCount,
            overscanRows: extra,
            cursor: CursorState(
                x: state.cursor.x,
                y: state.cursor.y,
                isVisible: modes.contains(.cursorVisible) && state.viewportOffset == 0,
                style: state.cursorStyle,
                isBlinking: modes.contains(.cursorBlink),
            ),
            selection: selection,
            searchMatches: matches,
            selectedSearchMatch: selectedMatch,
            searchMatchCount: state.searchMatches.count,
            searchSelectedIndex: state.searchSelected,
            damage: damage,
            palette: state.palette,
            underlineColors: state.underlineColors,
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
