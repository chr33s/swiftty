import Darwin

/// Shell-integration role of a row, from OSC 133 (FinalTerm semantic
/// prompts). Only the row where each part starts is marked.
public enum RowMark: UInt8, Sendable {
    case none
    /// `OSC 133 ; A`: a prompt starts on this row.
    case prompt
    /// `OSC 133 ; A ; k=s` (or `k=c`): a continuation prompt.
    case promptContinuation
    /// `OSC 133 ; C`: command output starts on this row.
    case output
}

/// Screen cells plus (for the primary screen) scrollback history.
///
/// All rows live in one pool of fixed-width, row-major rows allocated in
/// contiguous 64-row chunks. Logical screen rows map to physical row ids
/// through `rowMap`, so scrolling a region rotates a few indices instead of
/// moving cells, and scrolling the whole screen into history moves an id
/// into the `Scrollback` ring instead of copying the row.
///
/// Each physical row tracks an `extent`: every cell at or past it is
/// `.blank`. Clearing only touches cells below the extent, which makes
/// line-feed-heavy output cheap. Code writing through `row(_:)` must call
/// `extend(_:to:)`.
public struct Grid: ~Copyable {
    public private(set) var columns: Int
    public private(set) var rows: Int

    static let chunkShift = 6
    static let chunkRows = 1 << chunkShift

    private let capacity: Int // physical rows: screen + history
    private let chunks: UnsafeMutablePointer<UnsafeMutablePointer<Cell>>
    private var chunkCount = 0
    private let rowMap: UnsafeMutablePointer<Int32>
    private let wrapped: UnsafeMutablePointer<Bool>
    /// Per physical row: `RowMark` raw value (OSC 133 semantic prompts),
    /// plus `inputLineBit` on the first row of the line being edited.
    private let marks: UnsafeMutablePointer<UInt8>
    private static let inputLineBit: UInt8 = 0x80
    private let extents: UnsafeMutablePointer<Int32>
    private let free: UnsafeMutablePointer<Int32>
    private var freeCount = 0
    private var history: Scrollback
    private let historyLimitBytes: Int
    private let maxHistoryRows: Int
    /// Lines scrolled off the top with no history to keep them.
    private var dropped = 0

    /// - Parameters:
    ///   - historyLimitBytes: cell memory for scrollback (Ghostty's
    ///     `scrollback-limit`); 0 disables history.
    ///   - maxHistoryRows: upper bound on history rows regardless of size.
    public init(columns: Int, rows: Int, historyLimitBytes: Int = 0, maxHistoryRows: Int = 100_000) {
        let columns = max(1, columns), rows = max(1, rows)
        self.columns = columns
        self.rows = rows
        self.historyLimitBytes = historyLimitBytes
        self.maxHistoryRows = maxHistoryRows
        let rowBytes = columns * MemoryLayout<Cell>.stride
        let historyRows = historyLimitBytes > 0 ? max(1, min(maxHistoryRows, historyLimitBytes / rowBytes)) : 0
        history = Scrollback(capacity: historyRows)
        capacity = rows + historyRows
        chunks = .allocate(capacity: (capacity + Self.chunkRows - 1) >> Self.chunkShift)
        rowMap = .allocate(capacity: rows)
        wrapped = .allocate(capacity: capacity)
        wrapped.initialize(repeating: false, count: capacity)
        marks = .allocate(capacity: capacity)
        marks.initialize(repeating: 0, count: capacity)
        extents = .allocate(capacity: capacity)
        extents.initialize(repeating: 0, count: capacity)
        free = .allocate(capacity: capacity)
        for y in 0 ..< rows {
            rowMap[y] = takeRow()
        }
    }

    deinit {
        for i in 0 ..< chunkCount {
            chunks[i].deallocate()
        }
        chunks.deallocate()
        rowMap.deallocate()
        wrapped.deallocate()
        marks.deallocate()
        extents.deallocate()
        free.deallocate()
    }

    // MARK: Pool

    @inline(__always)
    private func physical(_ id: Int32) -> UnsafeMutablePointer<Cell> {
        let p = Int(id)
        return chunks[p >> Self.chunkShift] + (p & (Self.chunkRows - 1)) * columns
    }

    /// A blank row id: from the free list, or a newly allocated chunk.
    private mutating func takeRow() -> Int32 {
        if freeCount == 0 {
            let first = chunkCount << Self.chunkShift
            let count = min(Self.chunkRows, capacity - first)
            precondition(count > 0, "row pool exhausted")
            let chunk = UnsafeMutablePointer<Cell>.allocate(capacity: Self.chunkRows * columns)
            chunk.initialize(repeating: .blank, count: Self.chunkRows * columns)
            chunks[chunkCount] = chunk
            chunkCount += 1
            for id in stride(from: first + count - 1, through: first, by: -1) {
                free[freeCount] = Int32(id)
                freeCount += 1
            }
        }
        freeCount -= 1
        return free[freeCount]
    }

    // MARK: Access

    /// Base pointer of logical row `y`. Valid until the next resize.
    @inline(__always)
    public func row(_ y: Int) -> UnsafeMutablePointer<Cell> {
        physical(rowMap[y])
    }

    public func cells(row y: Int) -> UnsafeBufferPointer<Cell> {
        UnsafeBufferPointer(start: row(y), count: columns)
    }

    @inline(__always)
    public subscript(x: Int, y: Int) -> Cell {
        get { row(y)[x] }
        nonmutating set {
            row(y)[x] = newValue
            extend(y, to: x + 1)
        }
    }

    /// Whether row `y` soft-wraps into row `y + 1`.
    @inline(__always)
    public func isWrapped(_ y: Int) -> Bool {
        wrapped[Int(rowMap[y])]
    }

    @inline(__always)
    public func setWrapped(_ y: Int, _ value: Bool) {
        wrapped[Int(rowMap[y])] = value
    }

    /// Semantic mark of row `y` (OSC 133).
    @inline(__always)
    public func mark(_ y: Int) -> RowMark {
        RowMark(rawValue: marks[Int(rowMap[y])] & ~Self.inputLineBit) ?? .none
    }

    @inline(__always)
    public func setMark(_ y: Int, _ value: RowMark) {
        let p = Int(rowMap[y])
        marks[p] = marks[p] & Self.inputLineBit | value.rawValue
    }

    /// Whether row `y` starts the command line being edited (OSC 133 ; B).
    public func isInputLine(_ y: Int) -> Bool {
        marks[Int(rowMap[y])] & Self.inputLineBit != 0
    }

    public func setInputLine(_ y: Int, _ value: Bool) {
        let p = Int(rowMap[y])
        marks[p] = value ? marks[p] | Self.inputLineBit : marks[p] & ~Self.inputLineBit
    }

    /// Clears row `y`'s mark and input-line flag.
    public func clearMarks(_ y: Int) {
        marks[Int(rowMap[y])] = 0
    }

    /// Both per-row flags as one byte, for copying rows (reflow).
    func markBits(_ y: Int) -> UInt8 {
        marks[Int(rowMap[y])]
    }

    func historyMarkBits(_ index: Int) -> UInt8 {
        marks[Int(history.id(index))]
    }

    @inline(__always)
    public func extent(_ y: Int) -> Int {
        Int(extents[Int(rowMap[y])])
    }

    /// Records that cells before `x` on row `y` may be non-blank.
    @inline(__always)
    public func extend(_ y: Int, to x: Int) {
        let p = Int(rowMap[y])
        if extents[p] < Int32(x) {
            extents[p] = Int32(x)
        }
    }

    // MARK: History

    public var historyCount: Int {
        history.count
    }

    /// History lines dropped off the top since the last clear.
    public var historyEvicted: Int {
        history.evicted + dropped
    }

    public var historyCapacity: Int {
        history.capacity
    }

    /// History line `index` (0 = oldest): full-width cells and wrap flag.
    public func historyLine(_ index: Int) -> (cells: UnsafeBufferPointer<Cell>, wrapped: Bool) {
        let id = history.id(index)
        return (UnsafeBufferPointer(start: physical(id), count: columns), wrapped[Int(id)])
    }

    public func historyMark(_ index: Int) -> RowMark {
        RowMark(rawValue: marks[Int(history.id(index))] & ~Self.inputLineBit) ?? .none
    }

    func historyMutableCells(_ index: Int) -> UnsafeMutableBufferPointer<Cell> {
        UnsafeMutableBufferPointer(start: physical(history.id(index)), count: Int(extents[Int(history.id(index))]))
    }

    /// Scrolls rows `0...bottom` (default: the whole screen) up by `count`,
    /// moving the top rows into history without copying them. Without
    /// history this is `scrollUp`.
    public mutating func scrollUpIntoHistory(count: Int, bottom: Int? = nil, fill cell: Cell) {
        let bottom = bottom ?? rows - 1
        guard history.capacity > 0 else {
            scrollUp(top: 0, bottom: bottom, count: count, fill: cell)
            dropped += min(count, bottom + 1)
            return
        }
        for _ in 0 ..< min(count, bottom + 1) {
            let top = rowMap[0]
            let fresh = history.push(top) ?? takeRow()
            if bottom > 0 {
                rowMap.update(from: rowMap + 1, count: bottom)
            }
            rowMap[bottom] = fresh
            clear(rows: bottom ..< bottom + 1, with: cell)
        }
    }

    /// Appends a copy of `source` as the newest history line (reflow).
    public mutating func appendHistory(_ source: UnsafeBufferPointer<Cell>, wrapped isWrapped: Bool, marks markBits: UInt8 = 0) {
        guard history.capacity > 0 else { return }
        let id: Int32
        if history.isFull {
            // Rotate: the oldest row becomes the newest.
            id = history.id(0)
            _ = history.push(id)
        } else {
            id = takeRow()
            _ = history.push(id)
        }
        write(id, source, wrapped: isWrapped, marks: markBits)
    }

    public mutating func clearHistory() {
        dropped = 0
        var released: [Int32] = []
        history.removeAll { released.append($0) }
        for id in released {
            write(id, UnsafeBufferPointer(start: nil, count: 0), wrapped: false)
            free[freeCount] = id
            freeCount += 1
        }
    }

    // MARK: Mutation

    public func fill(row y: Int, from x0: Int, to x1: Int, with cell: Cell) {
        guard x0 < x1 else { return }
        if cell.isBlank {
            // Cells past the extent are already blank.
            let p = Int(rowMap[y])
            let e = Int(extents[p])
            let end = min(x1, e)
            if x0 < end {
                Self.fill(row(y) + x0, end - x0, cell)
            }
            if x1 >= e, x0 < e {
                extents[p] = Int32(x0)
            }
        } else {
            Self.fill(row(y) + x0, x1 - x0, cell)
            extend(y, to: x1)
        }
    }

    public func clear(rows range: Range<Int>, with cell: Cell) {
        for y in range {
            fill(row: y, from: 0, to: columns, with: cell)
            setWrapped(y, false)
            clearMarks(y)
        }
    }

    /// Scrolls logical rows `top...bottom` up by `count`; vacated rows at the
    /// bottom are filled. Nothing goes to history.
    public func scrollUp(top: Int, bottom: Int, count: Int, fill cell: Cell) {
        let height = bottom - top + 1
        let n = min(count, height)
        guard n > 0 else { return }
        if n < height {
            rotate(top, bottom + 1, by: n)
        }
        clear(rows: bottom + 1 - n ..< bottom + 1, with: cell)
    }

    /// Scrolls logical rows `top...bottom` down by `count`; vacated rows at
    /// the top are filled.
    public func scrollDown(top: Int, bottom: Int, count: Int, fill cell: Cell) {
        let height = bottom - top + 1
        let n = min(count, height)
        guard n > 0 else { return }
        if n < height {
            rotate(top, bottom + 1, by: height - n)
        }
        clear(rows: top ..< top + n, with: cell)
    }

    /// Shifts cells at and after `x` right by `count`, dropping overflow.
    public func insertCells(row y: Int, at x: Int, count: Int, fill cell: Cell) {
        let base = row(y)
        let n = min(count, columns - x)
        guard n > 0 else { return }
        if columns - x - n > 0 {
            (base + x + n).update(from: base + x, count: columns - x - n)
        }
        Self.fill(base + x, n, cell)
        extend(y, to: min(columns, max(extent(y) + n, cell.isBlank ? 0 : x + n)))
    }

    /// Removes `count` cells at `x`, shifting the rest left and filling the end.
    public func deleteCells(row y: Int, at x: Int, count: Int, fill cell: Cell) {
        let base = row(y)
        let n = min(count, columns - x)
        guard n > 0 else { return }
        if columns - x - n > 0 {
            (base + x).update(from: base + x + n, count: columns - x - n)
        }
        Self.fill(base + columns - n, n, cell)
        if !cell.isBlank {
            extend(y, to: columns)
        }
    }

    /// Replaces row `y` with `source` (padded with blanks).
    public func setRow(_ y: Int, _ source: UnsafeBufferPointer<Cell>, wrapped isWrapped: Bool, marks markBits: UInt8 = 0) {
        write(rowMap[y], source, wrapped: isWrapped, marks: markBits)
    }

    private func write(_ id: Int32, _ source: UnsafeBufferPointer<Cell>, wrapped isWrapped: Bool, marks markBits: UInt8 = 0) {
        var n = min(source.count, columns)
        while n > 0, source[n - 1].isBlank {
            n -= 1 // keep the extent tight
        }
        let base = physical(id)
        if n > 0 {
            base.update(from: source.baseAddress!, count: n)
        }
        // Blank the remainder only up to the previous extent.
        let old = Int(extents[Int(id)])
        if n < old {
            Self.fill(base + n, old - n, .blank)
        }
        extents[Int(id)] = Int32(n)
        wrapped[Int(id)] = isWrapped
        marks[Int(id)] = markBits
    }

    /// Resizes keeping the top-left content and history (no reflow).
    public mutating func resize(columns newColumns: Int, rows newRows: Int) {
        let newColumns = max(1, newColumns), newRows = max(1, newRows)
        guard newColumns != columns || newRows != rows else { return }
        var fresh = Grid(
            columns: newColumns, rows: newRows,
            historyLimitBytes: historyLimitBytes, maxHistoryRows: maxHistoryRows,
        )
        for i in 0 ..< history.count {
            let id = history.id(i)
            fresh.appendHistory(
                UnsafeBufferPointer(start: physical(id), count: min(Int(extents[Int(id)]), newColumns)),
                wrapped: newColumns == columns && wrapped[Int(id)],
                marks: marks[Int(id)],
            )
        }
        for y in 0 ..< min(rows, newRows) {
            fresh.setRow(
                y,
                UnsafeBufferPointer(start: row(y), count: min(extent(y), newColumns)),
                wrapped: newColumns == columns && isWrapped(y),
                marks: markBits(y),
            )
        }
        if newColumns < columns {
            // A wide character whose tail was cut off becomes blank.
            for y in 0 ..< min(rows, newRows) where fresh.row(y)[newColumns - 1].width == 2 {
                fresh.row(y)[newColumns - 1] = .blank
            }
        }
        self = fresh
    }

    /// A blank grid of the new size with the same history settings.
    public mutating func reset(columns newColumns: Int, rows newRows: Int) {
        self = Grid(
            columns: newColumns, rows: newRows,
            historyLimitBytes: historyLimitBytes, maxHistoryRows: maxHistoryRows,
        )
    }

    // MARK: Helpers

    @inline(__always)
    static func fill(_ p: UnsafeMutablePointer<Cell>, _ count: Int, _ cell: Cell) {
        guard count > 0 else { return }
        if MemoryLayout<Cell>.stride == 16 {
            // Cell's size is 15 bytes; widen to a full 16-byte pattern.
            var pattern = SIMD4<UInt32>()
            withUnsafeMutableBytes(of: &pattern) { $0.storeBytes(of: cell, as: Cell.self) }
            withUnsafeBytes(of: &pattern) { memset_pattern16(p, $0.baseAddress!, count * 16) }
        } else {
            p.update(repeating: cell, count: count)
        }
    }

    /// Rotates rowMap[lo..<hi] left by k.
    private func rotate(_ lo: Int, _ hi: Int, by k: Int) {
        let n = hi - lo
        if k == 1 { // the common line-feed case
            let first = rowMap[lo]
            (rowMap + lo).update(from: rowMap + lo + 1, count: n - 1)
            rowMap[hi - 1] = first
        } else if k == n - 1 {
            let last = rowMap[hi - 1]
            (rowMap + lo + 1).update(from: rowMap + lo, count: n - 1)
            rowMap[lo] = last
        } else {
            reverse(lo, lo + k)
            reverse(lo + k, hi)
            reverse(lo, hi)
        }
    }

    private func reverse(_ lo: Int, _ hi: Int) {
        var i = lo, j = hi - 1
        while i < j {
            let t = rowMap[i]
            rowMap[i] = rowMap[j]
            rowMap[j] = t
            i += 1
            j -= 1
        }
    }
}
