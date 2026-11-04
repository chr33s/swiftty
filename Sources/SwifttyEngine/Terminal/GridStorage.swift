import Synchronization

/// Owns chunk allocation, row metadata, and the screen/history row pool.
@usableFromInline
struct GridStorage: ~Copyable {
  let columns: Int
  let rows: Int
  static let chunkShift = 6
  static let chunkRows = 1 << chunkShift

  let capacity: Int  // physical rows: screen + history
  /// Cell backing, unit descriptors and cold payloads.
  var store: CellStore
  let rowMap: UnsafeMutablePointer<Int32>
  let wrapped: UnsafeMutablePointer<Bool>
  /// Per physical row: `RowMark` raw value (OSC 133 semantic prompts),
  /// plus `inputLineBit` on the first row of the line being edited.
  let marks: UnsafeMutablePointer<UInt8>
  static let inputLineBit: UInt8 = 0x80
  let extents: UnsafeMutablePointer<Int32>
  /// Cells in `extents[id] ..< stale[id]` are leftovers that read as blank.
  /// Nonzero only for screen rows during a parser batch.
  let stale: UnsafeMutablePointer<Int32>
  var hasStaleRows = false
  /// Rows deferred since the last resolve; on overflow, resolving scans the screen.
  let staleList: UnsafeMutablePointer<Int32>
  var staleCount = 0
  static let staleListCapacity = 8
  /// Set during the parser's CR LF fast path.
  var deferClears = false
  let free: UnsafeMutablePointer<Int32>
  var freeCount = 0
  var history: Scrollback
  let historyLimitBytes: Int
  let maxHistoryRows: Int
  /// Whether the mapped backend was requested (kept across resize).
  let reclaimable: Bool
  /// Identifies this pool; reset and resize replace it, so maintenance
  /// scheduled against an older generation becomes a no-op.
  let generation: UInt64
  /// Lines scrolled off the top with no history to keep them.
  var dropped = 0
  #if SWIFTTY_INTERNAL_CHECKS
  private let checkOwners: UnsafeMutablePointer<UInt8>
  #endif

  private static let generations = Atomic<UInt64>(0)

  /// History rows for a byte and row budget at `columns`; nonpositive byte
  /// budgets disable history, positive ones keep at least one row.
  static func historyRows(
    columns: Int,
    historyLimitBytes: Int,
    maxHistoryRows: Int
  ) -> Int {
    let rowBytes = checkedAllocationCount(
      max(1, columns),
      MemoryLayout<Cell>.stride
    )
    return historyLimitBytes > 0
      ? min(max(0, maxHistoryRows), max(1, historyLimitBytes / rowBytes)) : 0
  }

  /// History uses at most `historyLimitBytes` of cell storage, rounded up
  /// to one row; `maxHistoryRows` imposes an additional cap. Zero disables it.
  /// `reclaimable` selects the mapped backend where it is supported.
  init(
    columns: Int,
    rows: Int,
    historyLimitBytes: Int = 0,
    maxHistoryRows: Int = 100_000,
    reclaimable: Bool = true
  ) {
    let columns = max(1, columns)
    let rows = max(1, rows)
    self.columns = columns
    self.rows = rows
    self.historyLimitBytes = historyLimitBytes
    self.maxHistoryRows = max(0, maxHistoryRows)
    self.reclaimable = reclaimable
    precondition(columns <= Int(Int32.max), "too many columns")
    precondition(rows <= Int(Int32.max), "too many rows")
    _ = checkedAllocationCount(
      columns,
      Self.chunkRows * MemoryLayout<Cell>.stride
    )
    let historyRows = Self.historyRows(
      columns: columns,
      historyLimitBytes: historyLimitBytes,
      maxHistoryRows: maxHistoryRows
    )
    precondition(historyRows <= Int(Int32.max) - rows, "too many physical rows")
    capacity = rows + historyRows
    history = Scrollback(capacity: historyRows)
    generation = Self.generations.wrappingAdd(1, ordering: .relaxed).newValue
    #if SWIFTTY_INTERNAL_CHECKS
    checkOwners = .allocate(capacity: capacity)
    checkOwners.initialize(repeating: 0, count: capacity)
    #endif
    extents = .allocate(capacity: capacity)
    extents.initialize(repeating: 0, count: capacity)
    stale = .allocate(capacity: capacity)
    stale.initialize(repeating: 0, count: capacity)
    staleList = .allocate(capacity: Self.staleListCapacity)
    // Screen-only pools gain nothing from reclaimable mappings.
    store = CellStore(
      columns: columns,
      capacity: capacity,
      extents: extents,
      mapped: reclaimable && historyRows > 0
    )
    rowMap = .allocate(capacity: rows)
    wrapped = .allocate(capacity: capacity)
    wrapped.initialize(repeating: false, count: capacity)
    marks = .allocate(capacity: capacity)
    marks.initialize(repeating: 0, count: capacity)
    free = .allocate(capacity: capacity)
    for y in 0 ..< rows { rowMap[y] = takeRow() }
  }

  deinit {
    rowMap.deallocate()
    wrapped.deallocate()
    marks.deallocate()
    extents.deallocate()
    stale.deallocate()
    staleList.deallocate()
    free.deallocate()
    #if SWIFTTY_INTERNAL_CHECKS
    checkOwners.deallocate()
    #endif
  }

  var chunkCount: Int { store.chunkCount }

  /// Raw row cells. Screen rows are always resident; history rows must be
  /// promoted (`ensureResident`) or read through `store.withRow` first.
  @inline(__always)
  func physical(_ id: Int32) -> UnsafeMutablePointer<Cell> {
    #if SWIFTTY_INTERNAL_CHECKS
    precondition(store.isResident(id), "raw access to a cold row")
    #endif
    return store.physical(id)
  }

  /// A blank row id: from the free list, or a new chunk.
  mutating func takeRow() -> Int32 {
    if freeCount == 0 {
      let ids = store.allocateChunk()
      for id in ids.reversed() {
        free[freeCount] = Int32(id)
        freeCount += 1
      }
    }
    freeCount -= 1
    let id = free[freeCount]
    store.prepareFreeRow(id)
    store.setOwner(id, .used)
    return id
  }

  /// Pushes screen row `top` into history and returns the row that
  /// replaces it on screen: the recycled oldest line, or a fresh row.
  @inline(__always)
  mutating func pushHistory(_ top: Int32) -> Int32 {
    guard let evicted = history.push(top) else { return growHistory(top) }
    // The evicted row returns to the screen; ownership metadata is
    // unchanged. Checked here rather than through a `CellStore` method so
    // the warm line feed never materializes the store for a call.
    if store.geometry.unitsPerChunk != 1
      || store.units[Int(evicted) &>> Self.chunkShift].state != .resident
    {
      restoreRecycled(evicted)
    }
    return evicted
  }

  /// Neighbouring retained rows may share the evicted row's units, so
  /// they are restored rather than discarded.
  @inline(never)
  private mutating func restoreRecycled(_ id: Int32) {
    store.ensureResident(id, .recycle)
  }

  /// The ring is still filling: `top` joins history and a free row
  /// replaces it on screen.
  @inline(never)
  private mutating func growHistory(_ top: Int32) -> Int32 {
    store.noteWrite(top)
    return takeRow()
  }

  /// Releases history without decoding cold units: payloads are dropped,
  /// fully free units reclaimed and mixed units keep their live rows.
  mutating func clearHistory() {
    dropped = 0
    for index in 0 ..< history.count {
      store.setOwner(history.id(index), .free)
    }
    store.discardFreeUnits()
    for index in 0 ..< history.count {
      let id = history.id(index)
      // Rows in discarded units are blanked when reused.
      if store.owner(id) == .free {
        Grid.fill(physical(id), Int(extents[Int(id)]), .blank)
      }
      extents[Int(id)] = 0
      wrapped[Int(id)] = false
      marks[Int(id)] = 0
      free[freeCount] = id
      freeCount += 1
    }
    history.removeAll { _ in }
    store.releaseIdleWorkspace()
  }

  func checkBounds() -> Bool {
    let allocated = min(capacity, chunkCount * Self.chunkRows)
    return history.checkInvariants() && chunkCount > 0
      && chunkCount <= (capacity + Self.chunkRows - 1) / Self.chunkRows
      && freeCount >= 0 && freeCount <= allocated
      && rows + history.count + freeCount == allocated
  }

  /// `screenOnly` skips history and free rows, keeping the cost independent
  /// of scrollback size. Cold rows are inspected through scan scratch, so
  /// checking never changes residency; uninitialized rows are skipped.
  func checkInvariants(screenOnly: Bool = false) -> Bool {
    let allocated = min(capacity, chunkCount * Self.chunkRows)
    guard checkBounds() else { return false }
    func checkExtent(_ id: Int) -> Bool {
      let extent = Int(extents[id])
      guard extent >= 0 && extent <= columns else { return false }
      if store.owner(Int32(id)) == .uninitialized { return extent == 0 }
      let end = max(extent, Int(stale[id]))
      guard end <= columns else { return false }
      return store.withRow(Int32(id)) { row in
        for x in end ..< columns where !row[x].isBlank { return false }
        return true
      }
    }
    #if SWIFTTY_INTERNAL_CHECKS
    checkOwners.update(repeating: 0, count: allocated)
    func claim(_ id: Int32, _ owner: RowOwner) -> Bool {
      guard id >= 0 && Int(id) < allocated, checkOwners[Int(id)] == 0 else {
        return false
      }
      checkOwners[Int(id)] = 1
      return store.owner(id) == owner
        || owner == .free && store.owner(id) == .uninitialized
    }
    #else
    var owners = Set<Int32>()
    func claim(_ id: Int32, _ owner: RowOwner) -> Bool {
      id >= 0 && Int(id) < allocated && owners.insert(id).inserted
        && (store.owner(id) == owner
          || owner == .free && store.owner(id) == .uninitialized)
    }
    #endif
    for y in 0 ..< rows where !claim(rowMap[y], .used) { return false }
    // Every active-screen unit is resident.
    for y in 0 ..< rows where !store.isResident(rowMap[y]) { return false }
    if screenOnly {
      for y in 0 ..< rows where !checkExtent(Int(rowMap[y])) { return false }
      return true
    }
    for i in 0 ..< history.count where !claim(history.id(i), .used) {
      return false
    }
    for i in 0 ..< freeCount where !claim(free[i], .free) { return false }
    for id in 0 ..< allocated where !checkExtent(id) { return false }
    return checkUnits()
  }

  /// Units holding live screen rows.
  func screenUnits() -> Set<Int> {
    var units = Set<Int>()
    for y in 0 ..< rows {
      let (first, last) = store.unitSpan(rowMap[y])
      for g in first ... last { units.insert(g) }
    }
    return units
  }

  /// No cold unit holds a live, free or uninitialized row, and only
  /// compressed units own payloads.
  func checkUnits() -> Bool {
    let screen = screenUnits()
    for g in 0 ..< store.unitCount {
      let owners = store.ownership(g)
      let unit = store.units[g]
      guard unit.rows == Int32(store.unitRows(g).count) else { return false }
      switch unit.state {
      case .resident: if unit.payload != nil { return false }
      case .compressed:
        if unit.payload == nil || owners.free != 0 || screen.contains(g) {
          return false
        }
      case .discarded:
        if unit.payload != nil || owners.uninitialized != Int(unit.rows) {
          return false
        }
      }
    }
    return true
  }
}
