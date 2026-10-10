/// Owns chunk allocation, row metadata, and the screen/history row pool.
@usableFromInline
struct GridStorage: ~Copyable {
  let columns: Int
  let rows: Int
  static let chunkShift = 6
  static let chunkRows = 1 << chunkShift

  let capacity: Int  // physical rows: screen + history
  let chunks: UnsafeMutablePointer<UnsafeMutablePointer<Cell>>
  var chunkCount = 0
  let rowMap: UnsafeMutablePointer<Int32>
  let wrapped: UnsafeMutablePointer<Bool>
  /// Per physical row: `RowMark` raw value (OSC 133 semantic prompts),
  /// plus `inputLineBit` on the first row of the line being edited.
  let marks: UnsafeMutablePointer<UInt8>
  static let inputLineBit: UInt8 = 0x80
  let extents: UnsafeMutablePointer<Int32>
  let free: UnsafeMutablePointer<Int32>
  var freeCount = 0
  var history: Scrollback
  let historyLimitBytes: Int
  let maxHistoryRows: Int
  /// Lines scrolled off the top with no history to keep them.
  var dropped = 0
  #if SWIFTTY_INTERNAL_CHECKS
  private let checkOwners: UnsafeMutablePointer<UInt8>
  #endif

  /// History uses at most `historyLimitBytes` of cell storage, rounded up
  /// to one row; `maxHistoryRows` imposes an additional cap. Zero disables it.
  init(
    columns: Int,
    rows: Int,
    historyLimitBytes: Int = 0,
    maxHistoryRows: Int = 100_000
  ) {
    let columns = max(1, columns)
    let rows = max(1, rows)
    self.columns = columns
    self.rows = rows
    self.historyLimitBytes = historyLimitBytes
    self.maxHistoryRows = max(0, maxHistoryRows)
    precondition(columns <= Int(Int32.max), "too many columns")
    precondition(rows <= Int(Int32.max), "too many rows")
    _ = checkedAllocationCount(
      columns,
      Self.chunkRows * MemoryLayout<Cell>.stride
    )
    let rowBytes = checkedAllocationCount(columns, MemoryLayout<Cell>.stride)
    let historyRows =
      historyLimitBytes > 0
      ? min(self.maxHistoryRows, max(1, historyLimitBytes / rowBytes)) : 0
    precondition(historyRows <= Int(Int32.max) - rows, "too many physical rows")
    capacity = rows + historyRows
    history = Scrollback(capacity: historyRows)
    #if SWIFTTY_INTERNAL_CHECKS
    checkOwners = .allocate(capacity: capacity)
    checkOwners.initialize(repeating: 0, count: capacity)
    #endif
    chunks = .allocate(
      capacity: (capacity + Self.chunkRows - 1) >> Self.chunkShift
    )
    rowMap = .allocate(capacity: rows)
    wrapped = .allocate(capacity: capacity)
    wrapped.initialize(repeating: false, count: capacity)
    marks = .allocate(capacity: capacity)
    marks.initialize(repeating: 0, count: capacity)
    extents = .allocate(capacity: capacity)
    extents.initialize(repeating: 0, count: capacity)
    free = .allocate(capacity: capacity)
    for y in 0 ..< rows { rowMap[y] = takeRow() }
  }

  deinit {
    for i in 0 ..< chunkCount { chunks[i].deallocate() }
    chunks.deallocate()
    rowMap.deallocate()
    wrapped.deallocate()
    marks.deallocate()
    extents.deallocate()
    free.deallocate()
    #if SWIFTTY_INTERNAL_CHECKS
    checkOwners.deallocate()
    #endif
  }

  @inline(__always)
  func physical(_ id: Int32) -> UnsafeMutablePointer<Cell> {
    let p = Int(id)
    return chunks[p >> Self.chunkShift] + (p & (Self.chunkRows - 1)) * columns
  }

  /// A blank row id: from the free list, or a newly allocated chunk.
  mutating func takeRow() -> Int32 {
    if freeCount == 0 {
      let first = chunkCount << Self.chunkShift
      let count = min(Self.chunkRows, capacity - first)
      precondition(count > 0, "row pool exhausted")
      let chunk = UnsafeMutablePointer<Cell>
        .allocate(capacity: Self.chunkRows * columns)
      // Rows beyond the capacity never enter the free list. Leave their pages untouched.
      chunk.initialize(repeating: .blank, count: count * columns)
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

  mutating func clearHistory() {
    dropped = 0
    for index in 0 ..< history.count {
      let id = history.id(index)
      Grid.fill(physical(id), Int(extents[Int(id)]), .blank)
      extents[Int(id)] = 0
      wrapped[Int(id)] = false
      marks[Int(id)] = 0
      free[freeCount] = id
      freeCount += 1
    }
    history.removeAll { _ in }
  }

  func checkBounds() -> Bool {
    let allocated = min(capacity, chunkCount * Self.chunkRows)
    return history.checkInvariants() && chunkCount > 0
      && chunkCount <= (capacity + Self.chunkRows - 1) / Self.chunkRows
      && freeCount >= 0 && freeCount <= allocated
      && rows + history.count + freeCount == allocated
  }

  func checkInvariants() -> Bool {
    let allocated = min(capacity, chunkCount * Self.chunkRows)
    guard checkBounds() else { return false }
    #if SWIFTTY_INTERNAL_CHECKS
    checkOwners.update(repeating: 0, count: allocated)
    func claim(_ id: Int32) -> Bool {
      guard id >= 0 && Int(id) < allocated, checkOwners[Int(id)] == 0 else {
        return false
      }
      checkOwners[Int(id)] = 1
      return true
    }
    #else
    var owners = Set<Int32>()
    func claim(_ id: Int32) -> Bool {
      id >= 0 && Int(id) < allocated && owners.insert(id).inserted
    }
    #endif
    for y in 0 ..< rows where !claim(rowMap[y]) { return false }
    for i in 0 ..< history.count where !claim(history.id(i)) { return false }
    for i in 0 ..< freeCount where !claim(free[i]) { return false }
    for id in 0 ..< allocated {
      let end = Int(extents[id])
      guard end >= 0 && end <= columns else { return false }
      let row = physical(Int32(id))
      for x in end ..< columns where !row[x].isBlank { return false }
    }
    return true
  }

}
