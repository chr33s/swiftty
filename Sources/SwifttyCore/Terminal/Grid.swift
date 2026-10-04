import Darwin

/// The visible screen: one contiguous, row-major cell buffer.
///
/// Logical rows map to physical rows through `rowMap`, so scrolling a region
/// rotates a few indices instead of moving cells. `rowMap` is always a
/// permutation of `0..<rowCapacity`; entries past `rows` are spare rows that
/// growth can reuse without reallocating.
///
/// Each row tracks an `extent`: every cell at or past it is `.blank`. Clearing
/// and scrollback trimming only touch cells below the extent, which makes
/// line-feed-heavy output cheap. Code writing through `row(_:)` must call
/// `extend(_:to:)`.
public struct Grid: ~Copyable {
    public private(set) var columns: Int
    public private(set) var rows: Int

    private var cells: UnsafeMutablePointer<Cell>
    private var rowMap: UnsafeMutablePointer<Int32>
    private var wrapped: UnsafeMutablePointer<Bool>
    private var extents: UnsafeMutablePointer<Int32>
    private var rowCapacity: Int

    public init(columns: Int, rows: Int) {
        let columns = max(1, columns), rows = max(1, rows)
        self.columns = columns
        self.rows = rows
        rowCapacity = rows
        cells = .allocate(capacity: columns * rows)
        cells.initialize(repeating: .blank, count: columns * rows)
        rowMap = .allocate(capacity: rows)
        for i in 0 ..< rows {
            rowMap[i] = Int32(i)
        }
        wrapped = .allocate(capacity: rows)
        wrapped.initialize(repeating: false, count: rows)
        extents = .allocate(capacity: rows)
        extents.initialize(repeating: 0, count: rows)
    }

    deinit {
        cells.deallocate()
        rowMap.deallocate()
        wrapped.deallocate()
        extents.deallocate()
    }

    // MARK: Access

    /// Base pointer of logical row `y`. Valid until the next resize.
    @inline(__always)
    public func row(_ y: Int) -> UnsafeMutablePointer<Cell> {
        cells + Int(rowMap[y]) * columns
    }

    public func cells(row y: Int) -> UnsafeBufferPointer<Cell> {
        UnsafeBufferPointer(start: row(y), count: columns)
    }

    /// Cells of row `y` up to its extent (everything after is blank).
    public func usedCells(row y: Int) -> UnsafeBufferPointer<Cell> {
        UnsafeBufferPointer(start: row(y), count: extent(y))
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
        }
    }

    /// Scrolls logical rows `top...bottom` up by `count`; vacated rows at the
    /// bottom are filled. Callers save rows that scroll off first.
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
    public func setRow(_ y: Int, _ source: UnsafeBufferPointer<Cell>, wrapped isWrapped: Bool) {
        let n = min(source.count, columns)
        let base = row(y)
        if n > 0 {
            base.update(from: source.baseAddress!, count: n)
        }
        if n < columns {
            Self.fill(base + n, columns - n, .blank)
        }
        extents[Int(rowMap[y])] = Int32(n)
        setWrapped(y, isWrapped)
    }

    /// Resizes keeping the top-left content (no reflow). Row-only changes
    /// within capacity reuse storage.
    public mutating func resize(columns newColumns: Int, rows newRows: Int) {
        let newColumns = max(1, newColumns), newRows = max(1, newRows)
        if newColumns == columns, newRows <= rowCapacity {
            let old = rows
            // Spare rows hold stale cells: force a full clear.
            for y in old ..< max(old, newRows) {
                extents[Int(rowMap[y])] = Int32(columns)
            }
            rows = newRows
            if newRows > old {
                clear(rows: old ..< newRows, with: .blank)
            }
            return
        }
        let fresh = Grid(columns: newColumns, rows: newRows)
        for y in 0 ..< min(rows, newRows) {
            fresh.setRow(
                y,
                UnsafeBufferPointer(start: row(y), count: min(extent(y), newColumns)),
                wrapped: newColumns == columns && isWrapped(y),
            )
        }
        self = fresh
    }

    /// Resizes and blanks everything.
    public mutating func reset(columns newColumns: Int, rows newRows: Int) {
        if newColumns != columns || newRows > rowCapacity {
            self = Grid(columns: newColumns, rows: newRows)
        } else {
            for y in rows ..< max(rows, newRows) {
                extents[Int(rowMap[y])] = Int32(columns)
            }
            rows = max(1, newRows)
            clear(rows: 0 ..< rows, with: .blank)
        }
    }

    // MARK: Helpers

    @inline(__always)
    static func fill(_ p: UnsafeMutablePointer<Cell>, _ count: Int, _ cell: Cell) {
        guard count > 0 else { return }
        if MemoryLayout<Cell>.stride == 16 {
            withUnsafeBytes(of: cell) { pattern in
                memset_pattern16(p, pattern.baseAddress!, count * 16)
            }
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
