import Checksum
import Darwin

/// Unique owner of one logical 64-row chunk's cell backing: a dedicated
/// anonymous mapping (reclaimable) or a heap allocation (fallback).
/// The memory is released exactly once, when the owner is destroyed.
struct MappedCellChunk: ~Copyable {
  let base: UnsafeMutablePointer<Cell>
  /// Mapped length in bytes; zero for a heap chunk.
  let mappedBytes: Int

  /// A fresh mapping; its pages read as zero until written.
  init?(mappedBytes: Int) {
    guard let raw = ScrollbackMemory.map(mappedBytes) else { return nil }
    base = raw.bindMemory(
      to: Cell.self,
      capacity: mappedBytes / MemoryLayout<Cell>.stride
    )
    self.mappedBytes = mappedBytes
  }

  /// A heap chunk with its first `initialized` cells blank.
  init(heapCells: Int, initialized: Int) {
    base = .allocate(capacity: heapCells)
    base.initialize(repeating: .blank, count: initialized)
    mappedBytes = 0
  }

  var isMapped: Bool { mappedBytes > 0 }

  deinit {
    if mappedBytes > 0 {
      ScrollbackMemory.unmap(UnsafeMutableRawPointer(base), mappedBytes)
    } else {
      base.deallocate()
    }
  }
}

/// Fixed layout of a chunk's VM-page-aligned compression units.
struct ChunkGeometry {
  static let maximumUnitBytes = 256 * 1024

  let rowBytes: Int
  let chunkBytes: Int
  /// Chunk mapping length (whole pages); zero for the heap backend.
  let mappedBytes: Int
  /// Bytes per unit: a positive page multiple of at most 256 KiB that
  /// holds at least one row, so a row intersects at most two units.
  let unitBytes: Int
  let unitsPerChunk: Int

  /// Mapped geometry, or nil when this width cannot satisfy the bounds.
  init?(mappedColumns columns: Int) {
    let rowBytes = checkedAllocationCount(columns, MemoryLayout<Cell>.stride)
    let chunkBytes = checkedAllocationCount(GridStorage.chunkRows, rowBytes)
    let page = ScrollbackMemory.pageSize
    let limit = ScrollbackMemory.roundDown(Self.maximumUnitBytes)
    guard limit >= page, limit >= rowBytes, page % 16 == 0 else { return nil }
    self.rowBytes = rowBytes
    self.chunkBytes = chunkBytes
    mappedBytes = ScrollbackMemory.roundUp(chunkBytes)
    unitBytes = min(limit, mappedBytes)
    unitsPerChunk = (chunkBytes + unitBytes - 1) / unitBytes
  }

  /// Heap geometry: one never-compressed unit per chunk.
  init(heapColumns columns: Int) {
    rowBytes = checkedAllocationCount(columns, MemoryLayout<Cell>.stride)
    chunkBytes = checkedAllocationCount(GridStorage.chunkRows, rowBytes)
    mappedBytes = 0
    unitBytes = chunkBytes
    unitsPerChunk = 1
  }
}

/// Storage state of one compression unit.
enum UnitState: UInt8 {
  /// The raw mapping is authoritative.
  case resident
  /// The validated payload is authoritative; the mapping must not be read.
  case compressed
  /// No retained row depends on the bytes; pages were reclaimed.
  case discarded
}

/// Whether a physical row is in use. Screen and history rows are both
/// `used`: a line feed moves rows between them without touching this
/// metadata, and maintenance finds screen rows through the row map.
enum RowOwner: UInt8 {
  /// Free, but its bytes were never initialized (or were reclaimed).
  case uninitialized
  /// Free and blank.
  case free
  /// On a screen or in history.
  case used
}

/// Why a cold unit became resident, for instrumentation.
package enum ScrollbackRestoreReason: Int, Sendable, CaseIterable {
  /// A borrowed read (viewport, capture, public accessor).
  case read
  /// Recycling or rewriting a retained row.
  case recycle
  /// Grapheme compaction rewriting ids.
  case compaction
  case other
}

/// Descriptor for one unit; lives outside reclaimable cell memory.
struct UnitDescriptor {
  var state = UnitState.resident
  /// Encoding was unprofitable for the current content; skip until the
  /// content or its row ownership changes.
  var incompressible = false
  /// Pages were passed to `reclaim` and need `reuse` before writing.
  var reclaimed = false
  /// Usable rows intersecting the unit. Their owners are read from the
  /// row-owner bytes on demand, keeping the line-feed path to two stores.
  var rows: Int32 = 0
  var payload: UnsafeMutableRawPointer?
  var payloadBytes = 0
  /// Decoded length: the unit's row prefixes up to their extents.
  var packedBytes = 0
  var checksum: UInt32 = 0
  /// Shared-table epoch the payload was encoded under.
  var epoch: UInt32 = 0
  /// Identifies one encoded payload; scan caches key on it.
  var serial: UInt64 = 0
  var protectedStamp: UInt64 = 0
}

/// Test-only fault injection for the cold-storage paths.
package struct ScrollbackFaults: Sendable, Equatable {
  package var failEncode = false
  package var failPayloadAllocation = false
  package var failReclaim = false
  package init() {}
}

/// Work counts and durations, by reason.
package struct ScrollbackWork: Sendable, Equatable {
  package var compressions = 0
  package var compressNanoseconds: UInt64 = 0
  package var unprofitable = 0
  package var failures = 0
  package var restores = [Int](
    repeating: 0,
    count: ScrollbackRestoreReason.allCases.count
  )
  package var restoreNanoseconds: UInt64 = 0
  /// Units decoded into scan scratch without changing residency.
  package var scanDecodes = 0
  /// Encoded units dropped without decoding (clear, reset).
  package var discardedPayloads = 0
  package var reclaimedUnits = 0
  package init() {}

  package func restoreCount(_ reason: ScrollbackRestoreReason) -> Int {
    restores[reason.rawValue]
  }
}

/// Interior-mutable state: promotions and scans occur in borrowed reads.
struct CellStoreShared {
  var work = ScrollbackWork()
  var faults = ScrollbackFaults()
  /// Bumped by any ownership, content-eligibility or residency change.
  var mutationEpoch: UInt64 = 0
  var serial: UInt64 = 0
  var tableEpoch: UInt32 = 0
  var compressedUnits = 0
  /// Eviction count when encoding verdicts were last validated.
  var verdictEvicted = 0
  /// Up to eight recently promoted or captured units, kept warm.
  var recent = InlineArray<8, Int32>(repeating: -1)
  var recentNext = 0
  /// A promotion or eligibility change happened since the owner last
  /// consumed this flag (`takeMaintenanceDirty`).
  var maintenanceDirty = false
  // Scan workspace: one decoded unit plus a row for straddling rows.
  var scanUnit: UnsafeMutableRawPointer?
  var scanUnitSerial: UInt64 = 0
  var scanRow: UnsafeMutablePointer<Cell>?
  var scanDepth = 0
  // Codec workspace. Decode scratch stays while any unit is compressed.
  var decodeScratch: UnsafeMutableRawPointer?
  var encodeScratch: UnsafeMutableRawPointer?
  var encodeStage: UnsafeMutableRawPointer?
  var packStage: UnsafeMutableRawPointer?
  // Maintenance cursor over unit descriptors.
  var cursor = 0
  var passRemaining = 0
  var passEpoch: UInt64 = .max
  var passProtection = 0
  var protectStamp: UInt64 = 0
  var protectedUnits = 0
}

@inline(__always)
func monotonicNanoseconds() -> UInt64 {
  clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
}

/// Cell backing for a row pool: chunk ownership, unit descriptors, cold
/// payloads and row ownership. Every transition is local to the owner's
/// queue; borrowed reads may only promote (never demote or unmap).
struct CellStore: ~Copyable {
  let columns: Int
  let capacity: Int
  let geometry: ChunkGeometry
  /// Mapped, reclaimable backend (compression is possible).
  let isMapped: Bool
  let maxChunks: Int
  let chunks: UnsafeMutablePointer<UnsafeMutablePointer<Cell>>
  private let owners: UnsafeMutablePointer<MappedCellChunk>
  private(set) var chunkCount = 0
  let rowOwner: UnsafeMutablePointer<UInt8>
  let units: UnsafeMutablePointer<UnitDescriptor>
  let shared: UnsafeMutablePointer<CellStoreShared>
  /// Per-row extents, owned by `GridStorage`. Cells past a row's extent
  /// are blank, and a cold row's extent cannot change, so payloads store
  /// only row prefixes and restoration refills the blank tails.
  let extents: UnsafeMutablePointer<Int32>

  init(
    columns: Int,
    capacity: Int,
    extents: UnsafeMutablePointer<Int32>,
    mapped: Bool
  ) {
    self.columns = columns
    self.capacity = capacity
    self.extents = extents
    let mappedGeometry =
      mapped && ScrollbackMemory.isSupported
        && ScrollbackCodec.cellLayoutIsDense
      ? ChunkGeometry(mappedColumns: columns) : nil
    geometry = mappedGeometry ?? ChunkGeometry(heapColumns: columns)
    isMapped = mappedGeometry != nil
    maxChunks = (capacity + GridStorage.chunkRows - 1) >> GridStorage.chunkShift
    chunks = .allocate(capacity: max(1, maxChunks))
    owners = .allocate(capacity: max(1, maxChunks))
    rowOwner = .allocate(capacity: max(1, capacity))
    rowOwner.initialize(
      repeating: RowOwner.uninitialized.rawValue,
      count: capacity
    )
    let unitCount = checkedAllocationCount(
      max(1, maxChunks),
      geometry.unitsPerChunk
    )
    units = .allocate(capacity: unitCount)
    units.initialize(repeating: UnitDescriptor(), count: unitCount)
    shared = .allocate(capacity: 1)
    shared.initialize(to: CellStoreShared())
  }

  deinit {
    for g in 0 ..< chunkCount * geometry.unitsPerChunk {
      units[g].payload?.deallocate()
    }
    owners.deinitialize(count: chunkCount)
    owners.deallocate()
    chunks.deallocate()
    rowOwner.deallocate()
    units.deinitialize(count: max(1, maxChunks) * geometry.unitsPerChunk)
    units.deallocate()
    releaseScanWorkspace()
    releaseEncodeWorkspace()
    shared.pointee.decodeScratch?.deallocate()
    shared.deinitialize(count: 1)
    shared.deallocate()
  }

  // MARK: Geometry

  var unitCount: Int { chunkCount * geometry.unitsPerChunk }

  @inline(__always)
  func physical(_ id: Int32) -> UnsafeMutablePointer<Cell> {
    let p = Int(id)
    return chunks[p >> GridStorage.chunkShift]
      + (p & (GridStorage.chunkRows - 1)) * columns
  }

  @inline(__always)
  func rowsInChunk(_ c: Int) -> Int {
    min(GridStorage.chunkRows, capacity - (c << GridStorage.chunkShift))
  }

  /// First and last unit a row intersects.
  @inline(__always)
  func unitSpan(_ id: Int32) -> (first: Int, last: Int) {
    let p = Int(id)
    if geometry.unitsPerChunk == 1 {
      let g = p &>> GridStorage.chunkShift
      return (g, g)
    }
    // Bounded by the checked chunk geometry, so wrapping math is exact.
    let base = (p &>> GridStorage.chunkShift) &* geometry.unitsPerChunk
    let start = (p & (GridStorage.chunkRows - 1)) &* geometry.rowBytes
    return (
      base &+ start / geometry.unitBytes,
      base &+ (start &+ geometry.rowBytes &- 1) / geometry.unitBytes
    )
  }

  /// Unit `g`'s usable byte range within its chunk.
  func unitBytes(_ g: Int) -> (offset: Int, count: Int) {
    let c = g / geometry.unitsPerChunk
    let k = g % geometry.unitsPerChunk
    let usable = rowsInChunk(c) * geometry.rowBytes
    let offset = k * geometry.unitBytes
    return (offset, max(0, min(offset + geometry.unitBytes, usable) - offset))
  }

  @inline(__always)
  func unitBase(_ g: Int) -> UnsafeMutableRawPointer {
    UnsafeMutableRawPointer(chunks[g / geometry.unitsPerChunk])
      + unitBytes(g).offset
  }

  /// Page-rounded backing length a unit's reclamation covers.
  func unitBackingBytes(_ g: Int) -> Int {
    ScrollbackMemory.roundUp(unitBytes(g).count)
  }

  /// Physical rows intersecting unit `g` (within usable capacity).
  func unitRows(_ g: Int) -> Range<Int> {
    let c = g / geometry.unitsPerChunk
    let (offset, count) = unitBytes(g)
    guard count > 0 else { return 0 ..< 0 }
    let first = offset / geometry.rowBytes
    let end = (offset + count + geometry.rowBytes - 1) / geometry.rowBytes
    let base = c << GridStorage.chunkShift
    return base + first ..< base + end
  }

  // MARK: Allocation

  /// Allocates the next chunk; returns its usable row ids.
  mutating func allocateChunk() -> Range<Int> {
    let c = chunkCount
    precondition(c < maxChunks, "row pool exhausted")
    let count = rowsInChunk(c)
    let first = c << GridStorage.chunkShift
    let usableCells = checkedAllocationCount(count, columns)
    if isMapped {
      guard let chunk = MappedCellChunk(mappedBytes: geometry.mappedBytes)
      else { fatalError("cannot map scrollback cell storage") }
      chunks[c] = chunk.base
      (owners + c).initialize(to: chunk)
    } else {
      // Rows beyond the capacity never enter the free list. Leave their pages untouched.
      let chunk = MappedCellChunk(
        heapCells: GridStorage.chunkRows * columns,
        initialized: usableCells
      )
      chunks[c] = chunk.base
      (owners + c).initialize(to: chunk)
    }
    chunkCount += 1
    let initial: RowOwner = isMapped ? .uninitialized : .free
    rowOwner.advanced(by: first)
      .update(repeating: initial.rawValue, count: count)
    for k in 0 ..< geometry.unitsPerChunk {
      let g = c * geometry.unitsPerChunk + k
      let rows = Int32(unitRows(g).count)
      units[g] = UnitDescriptor()
      units[g].rows = rows
    }
    shared.pointee.mutationEpoch &+= 1
    return first ..< first + count
  }

  @inline(__always)
  func owner(_ id: Int32) -> RowOwner {
    unsafeBitCast(rowOwner[Int(id)], to: RowOwner.self)
  }

  /// Moves row `id` to `new`; its units' encoding verdicts become stale.
  @inline(__always)
  func setOwner(_ id: Int32, _ new: RowOwner) {
    guard owner(id) != new else { return }
    rowOwner[Int(id)] = new.rawValue
    let (first, last) = unitSpan(id)
    for g in first ... last { units[g].incompressible = false }
    shared.pointee.mutationEpoch &+= 1
  }

  /// Free and uninitialized rows of unit `g`: at most 65 bytes read.
  func ownership(_ g: Int) -> (free: Int, uninitialized: Int) {
    var free = 0
    var uninitialized = 0
    for row in unitRows(g) {
      switch owner(Int32(row)) {
      case .used: continue
      case .free: free &+= 1
      case .uninitialized:
        free &+= 1
        uninitialized &+= 1
      }
    }
    return (free, uninitialized)
  }

  /// Whether every row of unit `g` is in use (screen or history).
  func isFullyUsed(_ g: Int) -> Bool {
    for row in unitRows(g) where owner(Int32(row)) != .used { return false }
    return units[g].rows > 0
  }

  /// Makes a free row usable: recommits reclaimed units and blanks
  /// uninitialized bytes. The caller then assigns its owner.
  func prepareFreeRow(_ id: Int32) {
    let (first, last) = unitSpan(id)
    for g in first ... last where units[g].state != .resident {
      precondition(units[g].state == .discarded, "free row in a cold unit")
      let base = unitBase(g)
      if units[g].reclaimed {
        ScrollbackMemory.reuse(base, unitBackingBytes(g))
        units[g].reclaimed = false
      }
      units[g].state = .resident
      shared.pointee.mutationEpoch &+= 1
    }
    if owner(id) == .uninitialized {
      Grid.fill(physical(id), columns, .blank)
      setOwner(id, .free)
    }
  }

  // MARK: Residency

  /// Whether every unit row `id` touches is resident.
  @inline(__always)
  func isResident(_ id: Int32) -> Bool {
    let (first, last) = unitSpan(id)
    if units[first].state != .resident { return false }
    return first == last || units[last].state == .resident
  }

  /// Restores a retained row's units in place before exposing a pointer.
  /// Only promotes: never demotes, unmaps or moves other units.
  @inline(__always)
  func ensureResident(_ id: Int32, _ reason: ScrollbackRestoreReason) {
    let (first, last) = unitSpan(id)
    for g in first ... last where units[g].state != .resident {
      restore(g, reason)
    }
  }

  /// Invalidates per-unit encoding verdicts before a retained row's cells
  /// change. Resident units never keep a payload, so none can go stale.
  @inline(__always)
  func noteWrite(_ id: Int32) {
    let (first, last) = unitSpan(id)
    for g in first ... last { units[g].incompressible = false }
    shared.pointee.mutationEpoch &+= 1
  }

  /// Restores every compressed unit (shared-table rewrites).
  func restoreAll(_ reason: ScrollbackRestoreReason) {
    for g in 0 ..< unitCount where units[g].state == .compressed {
      restore(g, reason)
    }
  }

  /// Content may have changed anywhere: every encoding verdict is stale.
  func invalidateVerdicts() {
    for g in 0 ..< unitCount { units[g].incompressible = false }
    shared.pointee.mutationEpoch &+= 1
  }

  /// Notes a read of row `id`, keeping its unit in the recent set.
  @inline(__always)
  func noteAccess(_ id: Int32) {
    guard isMapped else { return }
    let g = unitSpan(id).first
    let s = shared
    for i in 0 ..< 8 where s.pointee.recent[i] == Int32(g) { return }
    s.pointee.recent[s.pointee.recentNext] = Int32(g)
    s.pointee.recentNext = (s.pointee.recentNext + 1) & 7
    s.pointee.maintenanceDirty = true
  }

  private func ensureDecodeScratch() {
    let bytes = ScrollbackCodec.decodeScratchBytes
    if shared.pointee.decodeScratch == nil, bytes > 0 {
      shared.pointee.decodeScratch = .allocate(byteCount: bytes, alignment: 16)
    }
  }

  /// Decodes unit `g`'s payload into `destination`; any integrity failure
  /// of committed cold state is a fail-fast invariant violation.
  private func decodePayload(
    _ g: Int,
    into destination: UnsafeMutableRawPointer
  ) {
    let unit = units[g]
    precondition(unit.state == .compressed, "decoding a non-compressed unit")
    precondition(
      unit.epoch == shared.pointee.tableEpoch,
      "compressed scrollback outlived its shared-table epoch"
    )
    let result = ScrollbackCodec.decode(
      unit.payload!,
      unit.payloadBytes,
      into: destination,
      count: unit.packedBytes,
      checksum: unit.checksum,
      scratch: shared.pointee.decodeScratch
    )
    precondition(result == .ok, "corrupt compressed scrollback: \(result)")
    unpack(g, destination, unit.packedBytes)
  }

  /// Bytes of each row segment in unit `g` (unit-relative offset and
  /// length) and how many lead bytes lie within the row's extent.
  @inline(__always)
  private func segment(
    _ g: Int,
    row: Int
  ) -> (offset: Int, length: Int, kept: Int) {
    let (offset, count) = unitBytes(g)
    let rowStart = (row & (GridStorage.chunkRows - 1)) &* geometry.rowBytes
    let start = max(rowStart, offset)
    let end = min(rowStart &+ geometry.rowBytes, offset &+ count)
    let used = rowStart &+ Int(extents[row]) &* MemoryLayout<Cell>.stride
    return (start &- offset, end &- start, max(0, min(end, used) &- start))
  }

  /// Copies the in-extent prefix of each row segment of unit `g`
  /// contiguously into `stage`; returns the packed length.
  private func pack(_ g: Int, _ stage: UnsafeMutableRawPointer) -> Int {
    let base = unitBase(g)
    var packed = 0
    for row in unitRows(g) {
      let s = segment(g, row: row)
      (stage + packed).copyMemory(from: base + s.offset, byteCount: s.kept)
      packed &+= s.kept
    }
    return packed
  }

  /// Expands a packed unit in place: prefixes move to their rows, last
  /// first (each destination is at or after its source), and tails are
  /// refilled with blank cells.
  private func unpack(
    _ g: Int,
    _ buffer: UnsafeMutableRawPointer,
    _ packed: Int
  ) {
    var position = packed
    for row in unitRows(g).reversed() {
      let s = segment(g, row: row)
      position &-= s.kept
      if s.offset != position, s.kept > 0 {
        (buffer + s.offset)
          .copyMemory(from: buffer + position, byteCount: s.kept)
      }
      Grid.fill(
        (buffer + s.offset + s.kept).assumingMemoryBound(to: Cell.self),
        (s.length &- s.kept) / MemoryLayout<Cell>.stride,
        .blank
      )
    }
    precondition(position == 0, "packed scrollback length mismatch")
  }

  /// Compressed → resident: recommit pages, decode, verify, then free the
  /// payload so only one authoritative copy remains.
  func restore(_ g: Int, _ reason: ScrollbackRestoreReason) {
    let start = monotonicNanoseconds()
    let base = unitBase(g)
    if units[g].reclaimed {
      ScrollbackMemory.reuse(base, unitBackingBytes(g))
      units[g].reclaimed = false
    }
    decodePayload(g, into: base)
    units[g].payload!.deallocate()
    units[g].payload = nil
    units[g].payloadBytes = 0
    units[g].state = .resident
    let s = shared
    s.pointee.compressedUnits -= 1
    s.pointee.mutationEpoch &+= 1
    s.pointee.maintenanceDirty = true
    s.pointee.work.restores[reason.rawValue] += 1
    s.pointee.work.restoreNanoseconds &+= monotonicNanoseconds() &- start
  }

  // MARK: Preserved scans

  /// Reads row `id` without changing residency. Cold rows decode one unit
  /// at a time into owned scratch (at most one unit plus one row); the
  /// buffer is valid only inside `body`, which must not start another scan.
  func withRow<R, E: Error>(
    _ id: Int32,
    _ body: (UnsafeBufferPointer<Cell>) throws(E) -> R
  ) throws(E) -> R {
    if isResident(id) {
      return try body(UnsafeBufferPointer(start: physical(id), count: columns))
    }
    let s = shared
    precondition(s.pointee.scanDepth == 0, "nested cold scrollback scan")
    s.pointee.scanDepth += 1
    defer { s.pointee.scanDepth -= 1 }
    let (first, last) = unitSpan(id)
    let rowStart = (Int(id) & (GridStorage.chunkRows - 1)) * geometry.rowBytes
    if first == last {
      let unit = scanUnit(first)
      let offset = rowStart - unitBytes(first).offset
      return try body(
        UnsafeBufferPointer(
          start: (unit + offset).assumingMemoryBound(to: Cell.self),
          count: columns
        )
      )
    }
    if s.pointee.scanRow == nil {
      s.pointee.scanRow = .allocate(capacity: columns)
    }
    let row = UnsafeMutableRawPointer(s.pointee.scanRow!)
    var copied = 0
    for g in first ... last {
      let (offset, count) = unitBytes(g)
      let lo = max(rowStart, offset)
      let hi = min(rowStart + geometry.rowBytes, offset + count)
      let unit = units[g].state == .resident ? unitBase(g) : scanUnit(g)
      (row + copied).copyMemory(from: unit + (lo - offset), byteCount: hi - lo)
      copied += hi - lo
    }
    precondition(copied == geometry.rowBytes)
    return try body(
      UnsafeBufferPointer(start: s.pointee.scanRow!, count: columns)
    )
  }

  /// Unit `g` decoded into scan scratch, reusing the last decode.
  private func scanUnit(_ g: Int) -> UnsafeMutableRawPointer {
    let s = shared
    if s.pointee.scanUnit == nil {
      s.pointee.scanUnit = .allocate(
        byteCount: geometry.unitBytes,
        alignment: 16
      )
      s.pointee.scanUnitSerial = 0
    }
    let buffer = s.pointee.scanUnit!
    if s.pointee.scanUnitSerial != units[g].serial {
      s.pointee.scanUnitSerial = 0
      decodePayload(g, into: buffer)
      s.pointee.scanUnitSerial = units[g].serial
      s.pointee.work.scanDecodes += 1
    }
    return buffer
  }

  func releaseScanWorkspace() {
    let s = shared
    s.pointee.scanUnit?.deallocate()
    s.pointee.scanUnit = nil
    s.pointee.scanUnitSerial = 0
    s.pointee.scanRow?.deallocate()
    s.pointee.scanRow = nil
  }

  func releaseEncodeWorkspace() {
    let s = shared
    s.pointee.encodeScratch?.deallocate()
    s.pointee.encodeScratch = nil
    s.pointee.encodeStage?.deallocate()
    s.pointee.encodeStage = nil
    s.pointee.packStage?.deallocate()
    s.pointee.packStage = nil
  }

  /// Frees workspace no remaining cold state needs.
  func releaseIdleWorkspace() {
    releaseEncodeWorkspace()
    releaseScanWorkspace()
    if shared.pointee.compressedUnits == 0 {
      shared.pointee.decodeScratch?.deallocate()
      shared.pointee.decodeScratch = nil
    }
  }

  // MARK: Compression

  enum CompressOutcome { case compressed, unprofitable, failed }

  /// Resident → compressed. Commits only after the payload is complete
  /// and reclamation succeeded; otherwise the unit stays resident.
  mutating func compress(_ g: Int) -> CompressOutcome {
    precondition(isMapped && units[g].state == .resident)
    precondition(isFullyUsed(g), "compressing a unit with free rows")
    let s = shared
    let start = monotonicNanoseconds()
    defer {
      s.pointee.work.compressNanoseconds &+= monotonicNanoseconds() &- start
    }
    let (_, count) = unitBytes(g)
    let base = unitBase(g)
    let backing = unitBackingBytes(g)
    if s.pointee.encodeStage == nil {
      s.pointee.encodeStage = .allocate(
        byteCount: geometry.unitBytes,
        alignment: 16
      )
    }
    let scratchBytes = ScrollbackCodec.encodeScratchBytes
    if s.pointee.encodeScratch == nil, scratchBytes > 0 {
      s.pointee.encodeScratch = .allocate(
        byteCount: scratchBytes,
        alignment: 16
      )
    }
    ensureDecodeScratch()
    _ = count
    if s.pointee.packStage == nil {
      s.pointee.packStage = .allocate(
        byteCount: geometry.unitBytes,
        alignment: 16
      )
    }
    let packed = pack(g, s.pointee.packStage!)
    let checksum = CRC32C.checksum(s.pointee.packStage!, packed)
    let encoded =
      s.pointee.faults.failEncode || packed == 0
      ? 0
      : ScrollbackCodec.encode(
        s.pointee.packStage!,
        packed,
        into: s.pointee.encodeStage!,
        capacity: packed,
        scratch: s.pointee.encodeScratch
      )
    // An all-blank unit packs to nothing: an empty payload restores it.
    guard packed == 0 || encoded > 0 && malloc_good_size(encoded) < backing
    else {
      units[g].incompressible = true
      s.pointee.work.unprofitable += 1
      return .unprofitable
    }
    guard !s.pointee.faults.failPayloadAllocation,
      let payload = malloc(max(1, encoded))
    else {
      s.pointee.work.failures += 1
      return .failed
    }
    payload.copyMemory(from: s.pointee.encodeStage!, byteCount: encoded)
    s.pointee.serial &+= 1
    units[g].payload = payload
    units[g].payloadBytes = encoded
    units[g].packedBytes = packed
    units[g].checksum = checksum
    units[g].epoch = s.pointee.tableEpoch
    units[g].serial = s.pointee.serial
    units[g].state = .compressed
    guard !s.pointee.faults.failReclaim, ScrollbackMemory.reclaim(base, backing)
    else {
      // The advice may have affected part of the range: rebuild from the
      // completed payload before returning to the resident state.
      ScrollbackMemory.reuse(base, backing)
      decodePayload(g, into: base)
      payload.deallocate()
      units[g].payload = nil
      units[g].payloadBytes = 0
      units[g].state = .resident
      s.pointee.work.failures += 1
      return .failed
    }
    units[g].reclaimed = true
    s.pointee.compressedUnits += 1
    s.pointee.work.compressions += 1
    return .compressed
  }

  /// Discards every unit whose rows are all free, without decoding:
  /// payloads are dropped and resident pages reclaimed. Their rows become
  /// uninitialized and are blanked lazily on reuse.
  func discardFreeUnits() {
    guard isMapped else { return }
    let s = shared
    for g in 0 ..< unitCount
    where units[g].rows > 0 && units[g].state != .discarded {
      let owners = ownership(g)
      guard owners.free == Int(units[g].rows) else { continue }
      if units[g].state == .compressed {
        units[g].payload!.deallocate()
        units[g].payload = nil
        units[g].payloadBytes = 0
        s.pointee.compressedUnits -= 1
        s.pointee.work.discardedPayloads += 1
      } else if owners.uninitialized == owners.free {
        // Never written since mapping or the last discard.
        continue
      } else {
        guard !s.pointee.faults.failReclaim,
          ScrollbackMemory.reclaim(unitBase(g), unitBackingBytes(g))
        else { continue }
        units[g].reclaimed = true
        s.pointee.work.reclaimedUnits += 1
      }
      units[g].state = .discarded
      for row in unitRows(g) { setOwner(Int32(row), .uninitialized) }
      units[g].incompressible = false
    }
    s.pointee.mutationEpoch &+= 1
  }
}
