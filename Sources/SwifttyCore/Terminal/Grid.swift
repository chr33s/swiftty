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

/// Noncopyable screen and history storage, shared only through borrowed views.
/// Scrolling rotates row ids; resize replaces the pool and copies retained cells.
public struct Grid: ~Copyable {
  public private(set) var columns: Int
  public private(set) var rows: Int

  private var storage: GridStorage

  /// Creates a blank grid. Nonpositive dimensions become one.
  /// History cell allocation is lazy, in chunks of at most 64 usable rows.
  /// - Complexity: O(rows * columns + historyCapacity).
  public init(
    columns: Int,
    rows: Int,
    historyLimitBytes: Int = 0,
    maxHistoryRows: Int = 100_000
  ) {
    storage = GridStorage(
      columns: columns,
      rows: rows,
      historyLimitBytes: historyLimitBytes,
      maxHistoryRows: maxHistoryRows
    )
    self.columns = storage.columns
    self.rows = storage.rows
  }

  @inline(__always)
  private func physical(_ id: Int32) -> UnsafeMutablePointer<Cell> {
    storage.physical(id)
  }

  // MARK: Access

  /// Borrowed row cells; valid only while this grid is borrowed.
  /// - Complexity: O(1), with no allocation.
  @_lifetime(borrow self)
  public func cells(row y: Int) -> Span<Cell> {
    checkRow(y)
    let span = Span(_unsafeStart: _unsafeRow(y), count: columns)
    return _overrideLifetime(span, borrowing: self)
  }

  /// Borrowed history cells, oldest first. O(1), with no allocation.
  @_lifetime(borrow self)
  public func historyCells(at index: Int) -> Span<Cell> {
    let span = Span(
      _unsafeStart: physical(storage.history.id(index)),
      count: columns
    )
    return _overrideLifetime(span, borrowing: self)
  }

  public func isHistoryWrapped(_ index: Int) -> Bool {
    storage.wrapped[Int(storage.history.id(index))]
  }

  /// Mutates a row exclusively and updates its extent, including on throws.
  /// The buffer must not escape the closure. O(columns), with no allocation.
  public mutating func withMutableCells<R>(
    row y: Int,
    _ body: (inout MutableSpan<Cell>) throws -> R
  ) rethrows -> R {
    defer { _checkInvariants() }
    checkRow(y)
    let base = _unsafeRow(y)
    defer {
      var end = columns
      while end > 0 && base[end - 1].isBlank { end -= 1 }
      storage.extents[Int(storage.rowMap[y])] = Int32(end)
    }
    var span = MutableSpan(_unsafeStart: base, count: columns)
    return try body(&span)
  }

  @inline(__always)
  private func checkRow(_ y: Int) {
    precondition(y >= 0 && y < rows, "row out of bounds")
  }

  @inline(__always)
  private func checkColumn(_ x: Int) {
    precondition(x >= 0 && x < columns, "column out of bounds")
  }

  private func checkRegion(top: Int, bottom: Int, count: Int) {
    precondition(top >= 0 && top <= bottom && bottom < rows && count >= 0)
  }

  /// Internal writes must extend the row; pointers must not survive pool mutation.
  @inline(__always)
  func _unsafeRow(_ y: Int) -> UnsafeMutablePointer<Cell> {
    return physical(storage.rowMap[y])
  }

  func _unsafeCells(row y: Int) -> UnsafeBufferPointer<Cell> {
    UnsafeBufferPointer(start: _unsafeRow(y), count: columns)
  }

  /// Checked cell access. O(1), with no allocation; writes extend the row.
  @inline(__always)
  public subscript(x: Int, y: Int) -> Cell {
    get {
      checkRow(y)
      checkColumn(x)
      return _unsafeRow(y)[x]
    }
    set {
      checkRow(y)
      checkColumn(x)
      _unsafeRow(y)[x] = newValue
      extend(y, to: x + 1)
      _checkInvariants()
    }
  }

  /// Whether row `y` soft-wraps into row `y + 1`.
  @inline(__always)
  public func isWrapped(_ y: Int) -> Bool {
    checkRow(y)
    return storage.wrapped[Int(storage.rowMap[y])]
  }

  @inline(__always)
  public mutating func setWrapped(_ y: Int, _ value: Bool) {
    checkRow(y)
    storage.wrapped[Int(storage.rowMap[y])] = value
  }

  /// Semantic mark of row `y` (OSC 133).
  @inline(__always)
  public func mark(_ y: Int) -> RowMark {
    checkRow(y)
    return RowMark(
      rawValue: storage.marks[Int(storage.rowMap[y])] & ~GridStorage
        .inputLineBit
    ) ?? .none
  }

  @inline(__always)
  public mutating func setMark(_ y: Int, _ value: RowMark) {
    checkRow(y)
    let p = Int(storage.rowMap[y])
    storage.marks[p] =
      storage.marks[p] & GridStorage.inputLineBit | value.rawValue
  }

  /// Whether row `y` starts the command line being edited (OSC 133 ; B).
  public func isInputLine(_ y: Int) -> Bool {
    checkRow(y)
    return storage.marks[Int(storage.rowMap[y])] & GridStorage.inputLineBit != 0
  }

  public mutating func setInputLine(_ y: Int, _ value: Bool) {
    checkRow(y)
    let p = Int(storage.rowMap[y])
    storage.marks[p] =
      value
      ? storage.marks[p] | GridStorage.inputLineBit
      : storage.marks[p] & ~GridStorage.inputLineBit
  }

  /// Clears row `y`'s mark and input-line flag.
  public mutating func clearMarks(_ y: Int) {
    defer { _checkInvariants() }
    checkRow(y)
    storage.marks[Int(storage.rowMap[y])] = 0
  }

  /// Both per-row flags as one byte, for copying rows (reflow).
  func markBits(_ y: Int) -> UInt8 {
    checkRow(y)
    return storage.marks[Int(storage.rowMap[y])]
  }

  /// Merging rows keeps the first semantic role and any input-line flag.
  static func mergingMarkBits(_ first: UInt8, _ second: UInt8) -> UInt8 {
    let role = first & ~GridStorage.inputLineBit
    return (role == 0 ? second & ~GridStorage.inputLineBit : role)
      | ((first | second) & GridStorage.inputLineBit)
  }

  func historyMarkBits(_ index: Int) -> UInt8 {
    storage.marks[Int(storage.history.id(index))]
  }

  @inline(__always)
  public func extent(_ y: Int) -> Int {
    checkRow(y)
    return Int(storage.extents[Int(storage.rowMap[y])])
  }

  /// Records that cells before `x` on row `y` may be non-blank.
  @inline(__always)
  func extend(_ y: Int, to x: Int) {
    checkRow(y)
    let p = Int(storage.rowMap[y])
    precondition(x >= 0 && x <= columns)
    if storage.extents[p] < Int32(x) { storage.extents[p] = Int32(x) }
  }

  // MARK: History

  public var historyCount: Int { storage.history.count }

  /// History lines dropped off the top since the last clear.
  public var historyEvicted: Int { storage.history.evicted + storage.dropped }

  public var historyCapacity: Int { storage.history.capacity }

  /// History line `index` (0 = oldest): full-width cells and wrap flag.
  func historyLine(
    _ index: Int
  ) -> (cells: UnsafeBufferPointer<Cell>, wrapped: Bool) {
    let id = storage.history.id(index)
    return (
      UnsafeBufferPointer(start: physical(id), count: columns),
      storage.wrapped[Int(id)]
    )
  }

  public func historyMark(_ index: Int) -> RowMark {
    RowMark(
      rawValue: storage.marks[Int(storage.history.id(index))] & ~GridStorage
        .inputLineBit
    ) ?? .none
  }

  func isHistoryInputLine(_ index: Int) -> Bool {
    storage.marks[Int(storage.history.id(index))] & GridStorage.inputLineBit
      != 0
  }

  func setHistoryInputLine(_ index: Int, _ value: Bool) {
    let p = Int(storage.history.id(index))
    storage.marks[p] =
      value
      ? storage.marks[p] | GridStorage.inputLineBit
      : storage.marks[p] & ~GridStorage.inputLineBit
  }

  func historyMutableCells(_ index: Int) -> UnsafeMutableBufferPointer<Cell> {
    UnsafeMutableBufferPointer(
      start: physical(storage.history.id(index)),
      count: Int(storage.extents[Int(storage.history.id(index))])
    )
  }

  /// Moves top rows into history, recycling evicted rows.
  /// O(min(count, height) * (rows + columns)); chunk allocation is lazy.
  public mutating func scrollUpIntoHistory(
    count: Int,
    bottom: Int? = nil,
    fill cell: Cell
  ) {
    defer { _checkInvariants() }
    let bottom = bottom ?? rows - 1
    checkRegion(top: 0, bottom: bottom, count: count)
    guard storage.history.capacity > 0 else {
      scrollUp(top: 0, bottom: bottom, count: count, fill: cell)
      storage.dropped += min(count, bottom + 1)
      return
    }
    for _ in 0 ..< min(count, bottom + 1) {
      let top = storage.rowMap[0]
      let fresh = storage.history.push(top) ?? storage.takeRow()
      if bottom > 0 {
        storage.rowMap.update(from: storage.rowMap + 1, count: bottom)
      }
      storage.rowMap[bottom] = fresh
      clear(rows: bottom ..< bottom + 1, with: cell)
    }
  }

  /// Appends a copy of `source` as the newest history line (reflow).
  mutating func appendHistory(
    _ source: UnsafeBufferPointer<Cell>,
    wrapped isWrapped: Bool,
    marks markBits: UInt8 = 0
  ) {
    guard storage.history.capacity > 0 else { return }
    let id: Int32
    if storage.history.isFull {
      id = storage.history.id(0)
      _ = storage.history.push(id)
    } else {
      id = storage.takeRow()
      _ = storage.history.push(id)
    }
    write(id, source, wrapped: isWrapped, marks: markBits)
  }

  /// Recycles history rows and resets eviction counts without allocating.
  /// O(historyCount + stored history cells).
  public mutating func clearHistory() {
    storage.clearHistory()
    _checkInvariants()
  }

  // MARK: Mutation

  /// Fills a checked row range. O(to - from), with no allocation.
  public mutating func fill(
    row y: Int,
    from x0: Int,
    to x1: Int,
    with cell: Cell
  ) {
    defer { _checkInvariants() }
    checkRow(y)
    precondition(x0 >= 0 && x0 <= x1 && x1 <= columns)
    guard x0 < x1 else { return }
    if cell.isBlank {
      // Cells past the extent are already blank.
      let p = Int(storage.rowMap[y])
      let e = Int(storage.extents[p])
      let end = min(x1, e)
      if x0 < end { Self.fill(_unsafeRow(y) + x0, end - x0, cell) }
      if x1 >= e, x0 < e { storage.extents[p] = Int32(x0) }
    } else {
      Self.fill(_unsafeRow(y) + x0, x1 - x0, cell)
      extend(y, to: x1)
    }
  }

  /// Clears rows and their metadata. O(range.count * columns), no allocation.
  public mutating func clear(rows range: Range<Int>, with cell: Cell) {
    defer { _checkInvariants() }
    precondition(range.lowerBound >= 0 && range.upperBound <= rows)
    for y in range {
      fill(row: y, from: 0, to: columns, with: cell)
      setWrapped(y, false)
      clearMarks(y)
    }
  }

  /// Scrolls logical rows `top...bottom` up by `count`; vacated rows at the
  /// bottom are filled. O(height + count * columns), with no allocation.
  public mutating func scrollUp(
    top: Int,
    bottom: Int,
    count: Int,
    fill cell: Cell
  ) {
    defer { _checkInvariants() }
    checkRegion(top: top, bottom: bottom, count: count)
    let height = bottom - top + 1
    let n = min(count, height)
    guard n > 0 else { return }
    if n < height { rotate(top, bottom + 1, by: n) }
    clear(rows: bottom + 1 - n ..< bottom + 1, with: cell)
  }

  /// Scrolls logical rows `top...bottom` down by `count`; vacated rows at
  /// the top are filled. O(height + count * columns), with no allocation.
  public mutating func scrollDown(
    top: Int,
    bottom: Int,
    count: Int,
    fill cell: Cell
  ) {
    defer { _checkInvariants() }
    checkRegion(top: top, bottom: bottom, count: count)
    let height = bottom - top + 1
    let n = min(count, height)
    guard n > 0 else { return }
    if n < height { rotate(top, bottom + 1, by: height - n) }
    clear(rows: top ..< top + n, with: cell)
  }

  /// Shifts cells at `x` right, dropping overflow. O(columns), no allocation.
  public mutating func insertCells(
    row y: Int,
    at x: Int,
    count: Int,
    fill cell: Cell
  ) {
    defer { _checkInvariants() }
    checkRow(y)
    precondition(x >= 0 && x <= columns && count >= 0)
    let base = _unsafeRow(y)
    let n = min(count, columns - x)
    guard n > 0 else { return }
    if columns - x - n > 0 {
      (base + x + n).update(from: base + x, count: columns - x - n)
    }
    Self.fill(base + x, n, cell)
    extend(y, to: min(columns, max(extent(y) + n, cell.isBlank ? 0 : x + n)))
  }

  /// Removes cells at `x`, shifting left and filling the end.
  /// O(columns), with no allocation.
  public mutating func deleteCells(
    row y: Int,
    at x: Int,
    count: Int,
    fill cell: Cell
  ) {
    defer { _checkInvariants() }
    checkRow(y)
    precondition(x >= 0 && x <= columns && count >= 0)
    let base = _unsafeRow(y)
    let n = min(count, columns - x)
    guard n > 0 else { return }
    if columns - x - n > 0 {
      (base + x).update(from: base + x + n, count: columns - x - n)
    }
    Self.fill(base + columns - n, n, cell)
    if !cell.isBlank { extend(y, to: columns) }
  }

  /// Replaces row `y` with `source` (padded with blanks).
  func setRow(
    _ y: Int,
    _ source: UnsafeBufferPointer<Cell>,
    wrapped isWrapped: Bool,
    marks markBits: UInt8 = 0
  ) {
    checkRow(y)
    write(storage.rowMap[y], source, wrapped: isWrapped, marks: markBits)
  }

  private func write(
    _ id: Int32,
    _ source: UnsafeBufferPointer<Cell>,
    wrapped isWrapped: Bool,
    marks markBits: UInt8 = 0
  ) {
    var n = min(source.count, columns)
    while n > 0, source[n - 1].isBlank { n -= 1 }
    let base = physical(id)
    if n > 0 { base.update(from: source.baseAddress!, count: n) }
    // Blank the remainder only up to the previous extent.
    let old = Int(storage.extents[Int(id)])
    if n < old { Self.fill(base + n, old - n, .blank) }
    storage.extents[Int(id)] = Int32(n)
    storage.wrapped[Int(id)] = isWrapped
    storage.marks[Int(id)] = markBits
  }

  private func clearWrapPadding(_ id: Int32) {
    let row = physical(id)
    for x in 0 ..< Int(storage.extents[Int(id)])
    where row[x].flags.contains(.spacerHead) {
      row[x].attributes.flags.remove(.spacerHead)
    }
  }

  /// Keeps top-left content and history without reflow. Replaces the pool.
  /// O(new screen cells + retained cells + row capacity), allocating storage.
  public mutating func resize(columns newColumns: Int, rows newRows: Int) {
    defer { _checkInvariants() }
    let newColumns = max(1, newColumns)
    let newRows = max(1, newRows)
    guard newColumns != columns || newRows != rows else { return }
    var fresh = Grid(
      columns: newColumns,
      rows: newRows,
      historyLimitBytes: storage.historyLimitBytes,
      maxHistoryRows: storage.maxHistoryRows,
    )
    // A wide character whose tail is cut off becomes blank on both
    // screen and history rows. Omit its lead before copying the row.
    func retainedCount(_ row: UnsafeMutablePointer<Cell>, extent: Int) -> Int {
      let count = min(extent, newColumns)
      return count > 0 && row[count - 1].width == 2 ? count - 1 : count
    }
    for i in 0 ..< storage.history.count {
      let id = storage.history.id(i)
      let source = physical(id)
      fresh.appendHistory(
        UnsafeBufferPointer(
          start: source,
          count: retainedCount(source, extent: Int(storage.extents[Int(id)]))
        ),
        wrapped: newColumns == columns && storage.wrapped[Int(id)],
        marks: storage.marks[Int(id)],
      )
      if newColumns != columns {
        fresh.clearWrapPadding(fresh.storage.history.id(fresh.historyCount - 1))
      }
    }
    for y in 0 ..< min(rows, newRows) {
      let source = _unsafeRow(y)
      fresh.setRow(
        y,
        UnsafeBufferPointer(
          start: source,
          count: retainedCount(source, extent: extent(y))
        ),
        wrapped: newColumns == columns && isWrapped(y),
        marks: markBits(y),
      )
      if newColumns != columns {
        fresh.clearWrapPadding(fresh.storage.rowMap[y])
      }
    }
    self = fresh
  }

  /// Replaces the pool with a blank grid using the same history limits.
  /// O(rows * columns + row capacity), allocating new storage.
  public mutating func reset(columns newColumns: Int, rows newRows: Int) {
    defer { _checkInvariants() }
    self = Grid(
      columns: newColumns,
      rows: newRows,
      historyLimitBytes: storage.historyLimitBytes,
      maxHistoryRows: storage.maxHistoryRows,
    )
  }

  func checkInvariants() -> Bool { storage.checkInvariants() }

  @inline(__always)
  func _checkInvariants() {
    #if SWIFTTY_INTERNAL_CHECKS
    precondition(storage.checkBounds(), "invalid grid storage bounds")
    #endif
  }

  // MARK: Helpers

  @inline(__always)
  static func fill(_ p: UnsafeMutablePointer<Cell>, _ count: Int, _ cell: Cell)
  {
    guard count > 0 else { return }
    if MemoryLayout<Cell>.stride == 16 {
      // Cell's size is 15 bytes; widen to a full 16-byte pattern.
      var pattern = SIMD4<UInt32>()
      withUnsafeMutableBytes(of: &pattern) {
        $0.storeBytes(of: cell, as: Cell.self)
      }
      // Direct stores avoid the pattern-fill call for short rows.
      // Larger clears retain the library's bulk implementation.
      if count <= 128 {
        let raw = UnsafeMutableRawPointer(p)
        let grouped = count & ~3
        var i = 0
        while i < grouped {
          raw.storeBytes(
            of: pattern,
            toByteOffset: i &* 16,
            as: SIMD4<UInt32>.self
          )
          raw.storeBytes(
            of: pattern,
            toByteOffset: (i &+ 1) &* 16,
            as: SIMD4<UInt32>.self
          )
          raw.storeBytes(
            of: pattern,
            toByteOffset: (i &+ 2) &* 16,
            as: SIMD4<UInt32>.self
          )
          raw.storeBytes(
            of: pattern,
            toByteOffset: (i &+ 3) &* 16,
            as: SIMD4<UInt32>.self
          )
          i &+= 4
        }
        while i < count {
          raw.storeBytes(
            of: pattern,
            toByteOffset: i &* 16,
            as: SIMD4<UInt32>.self
          )
          i &+= 1
        }
      } else {
        withUnsafeBytes(of: &pattern) {
          memset_pattern16(p, $0.baseAddress!, count * 16)
        }
      }
    } else {
      p.update(repeating: cell, count: count)
    }
  }

  /// Rotates rowMap[lo..<hi] left by k.
  private func rotate(_ lo: Int, _ hi: Int, by k: Int) {
    let n = hi - lo
    if k == 1 {  // the common line-feed case
      let first = storage.rowMap[lo]
      (storage.rowMap + lo).update(from: storage.rowMap + lo + 1, count: n - 1)
      storage.rowMap[hi - 1] = first
    } else if k == n - 1 {
      let last = storage.rowMap[hi - 1]
      (storage.rowMap + lo + 1).update(from: storage.rowMap + lo, count: n - 1)
      storage.rowMap[lo] = last
    } else {
      reverse(lo, lo + k)
      reverse(lo + k, hi)
      reverse(lo, hi)
    }
  }

  private func reverse(_ lo: Int, _ hi: Int) {
    var i = lo
    var j = hi - 1
    while i < j {
      let t = storage.rowMap[i]
      storage.rowMap[i] = storage.rowMap[j]
      storage.rowMap[j] = t
      i += 1
      j -= 1
    }
  }
}
