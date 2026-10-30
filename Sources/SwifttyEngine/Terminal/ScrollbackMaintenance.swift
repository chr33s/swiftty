import Darwin
import Dispatch
import Synchronization

/// Bounds one maintenance step.
public struct ScrollbackMaintenanceBudget: Sendable, Equatable {
  /// Unit descriptors examined per step.
  public var maximumCandidates = 8
  /// Units encoded per step.
  public var maximumUnits = 1
  /// Largest unit input encoded.
  public var maximumUnitBytes = ChunkGeometry.maximumUnitBytes
  public init() {}
}

/// Requested and effective scrollback compression, with the reason for
/// any fallback to uncompressed storage.
public struct ScrollbackCompressionPolicy: Sendable, Equatable {
  public var requested: Bool
  public var effective: Bool
  /// Why `effective` is false while `requested` is true (or compression
  /// was turned off); nil when effective.
  public var fallbackReason: String?
}

/// Outcome of one maintenance step.
public enum ScrollbackMaintenanceResult: Sendable, Equatable {
  /// More eligible units may remain: run another step after a short delay.
  case pending
  /// Nothing eligible remains until new activity.
  case idle
  /// Compression is off or unsupported for this terminal.
  case disabled
  /// The storage changed since the step was scheduled; nothing was done.
  case stale
}

/// Distinct memory quantities for one terminal's scrollback. Sampling
/// reads metadata only and never restores compressed history.
public struct ScrollbackStatistics: Sendable, Equatable {
  /// Retained history rows × columns × cell stride.
  public var logicalHistoryCellBytes = 0
  /// Address space (or heap) retained by cell chunks.
  public var reservedMappingBytes = 0
  /// Backing the store considers resident; not a substitute for RSS.
  public var residentUnitBytes = 0
  /// Encoded payloads including allocator rounding.
  public var compressedPayloadBytes = 0
  /// Ring, row, descriptor and protection metadata.
  public var metadataBytes = 0
  /// Encode, decode and scan scratch currently retained.
  public var workspaceBytes = 0
  /// Backing excluded by live screens and current or recent captures,
  /// as of the last maintenance step.
  public var protectedUnitBytes = 0
  /// Cold candidates as of this sample.
  public var eligibleUnitBytes = 0
  /// Reclaimed backing with no retained content.
  public var reclaimedFreeBytes = 0
  public var residentUnits = 0
  public var compressedUnits = 0
  public var discardedUnits = 0
  public var compressions = 0
  public var compressNanoseconds: UInt64 = 0
  public var unprofitableAttempts = 0
  public var failedAttempts = 0
  /// Restores by reason: read (viewport, capture or accessor), recycle,
  /// compaction, other.
  public var readRestores = 0
  public var recycleRestores = 0
  public var compactionRestores = 0
  public var otherRestores = 0
  public var restoreNanoseconds: UInt64 = 0
  /// Units decoded into scan scratch without changing residency.
  public var scanDecodes = 0
  /// Encoded units dropped without decoding.
  public var discardedPayloads = 0
  public var reclaimedUnits = 0

  public init() {}

  public var restores: Int {
    readRestores + recycleRestores + compactionRestores + otherRestores
  }

  public static func += (a: inout Self, b: Self) { a = a + b }

  public static func + (a: Self, b: Self) -> Self {
    var r = a
    r.logicalHistoryCellBytes += b.logicalHistoryCellBytes
    r.reservedMappingBytes += b.reservedMappingBytes
    r.residentUnitBytes += b.residentUnitBytes
    r.compressedPayloadBytes += b.compressedPayloadBytes
    r.metadataBytes += b.metadataBytes
    r.workspaceBytes += b.workspaceBytes
    r.protectedUnitBytes += b.protectedUnitBytes
    r.eligibleUnitBytes += b.eligibleUnitBytes
    r.reclaimedFreeBytes += b.reclaimedFreeBytes
    r.residentUnits += b.residentUnits
    r.compressedUnits += b.compressedUnits
    r.discardedUnits += b.discardedUnits
    r.compressions += b.compressions
    r.compressNanoseconds += b.compressNanoseconds
    r.unprofitableAttempts += b.unprofitableAttempts
    r.failedAttempts += b.failedAttempts
    r.readRestores += b.readRestores
    r.recycleRestores += b.recycleRestores
    r.compactionRestores += b.compactionRestores
    r.otherRestores += b.otherRestores
    r.restoreNanoseconds += b.restoreNanoseconds
    r.scanDecodes += b.scanDecodes
    r.discardedPayloads += b.discardedPayloads
    r.reclaimedUnits += b.reclaimedUnits
    return r
  }
}

// MARK: Grid

extension Grid {
  /// Identifies the current row pool; reset and resize replace it.
  var storageGeneration: UInt64 { storage.generation }

  /// Whether this grid's history can be compressed.
  var isCompressible: Bool { storage.store.isMapped }

  var scrollbackFallbackReason: String? {
    guard !storage.store.isMapped else { return nil }
    if storage.history.capacity == 0 { return "history is disabled" }
    if !storage.reclaimable { return "reclaimable storage was not requested" }
    if !ScrollbackMemory.isSupported {
      return "compression is not validated on this platform"
    }
    if !ScrollbackCodec.cellLayoutIsDense { return "cell layout has padding" }
    return "rows are wider than one compression unit"
  }

  /// Consumes the flag a promotion or recent access set, so the owner can
  /// rearm maintenance after a borrowed read ends.
  func takeScrollbackMaintenanceDirty() -> Bool {
    let s = storage.store.shared
    defer { s.pointee.maintenanceDirty = false }
    return s.pointee.maintenanceDirty
  }

  /// Starts a new shared-table epoch after every referring cell was
  /// rewritten; no compressed unit may exist under the old epoch.
  func noteSharedTableChange() {
    let s = storage.store.shared
    precondition(
      s.pointee.compressedUnits == 0,
      "cold cells missed by compaction"
    )
    s.pointee.tableEpoch &+= 1
    s.pointee.scanUnitSerial = 0
  }

  /// Frees idle encode and scan workspace (memory pressure, clear).
  func releaseScrollbackWorkspace() { storage.store.releaseIdleWorkspace() }

  /// Flips one byte of the first compressed payload, simulating memory
  /// corruption after the cold state was committed (tests). Returns false
  /// when nothing is compressed.
  package func corruptFirstScrollbackPayloadForTesting() -> Bool {
    for g in 0 ..< storage.store.unitCount
    where storage.store.units[g].state == .compressed {
      let unit = storage.store.units[g]
      guard unit.payloadBytes > 0, let payload = unit.payload else { continue }
      let p = payload.assumingMemoryBound(to: UInt8.self)
      p[unit.payloadBytes / 2] ^= 0x5A
      return true
    }
    return false
  }

  /// Changing faults restarts the maintenance pass, as new activity would.
  package var scrollbackFaults: ScrollbackFaults {
    get { storage.store.shared.pointee.faults }
    nonmutating set {
      storage.store.shared.pointee.faults = newValue
      storage.store.shared.pointee.mutationEpoch &+= 1
    }
  }

  /// Storage state of every unit history line `index` touches (tests).
  package func historyUnitStates(_ index: Int) -> [UInt8] {
    let (first, last) = storage.store.unitSpan(storage.history.id(index))
    return (first ... last).map { storage.store.units[$0].state.rawValue }
  }

  /// One bounded compression step over history. Protects every unit
  /// touching `protecting` (history indices), recent captures and the
  /// next eviction horizon; live and free rows are never eligible.
  mutating func maintainScrollback(
    protecting: Range<Int>,
    budget: ScrollbackMaintenanceBudget
  ) -> ScrollbackMaintenanceResult {
    guard storage.store.isMapped else { return .disabled }
    let s = storage.store.shared
    s.pointee.protectStamp &+= 1
    let stamp = s.pointee.protectStamp
    var protectedUnits = 0
    var signature = Hasher()
    func protect(_ g: Int) {
      if storage.store.units[g].protectedStamp != stamp {
        storage.store.units[g].protectedStamp = stamp
        protectedUnits += 1
      }
    }
    func protectRow(_ index: Int) {
      let (first, last) = storage.store.unitSpan(storage.history.id(index))
      for g in first ... last { protect(g) }
    }
    // Live screen rows are never eligible.
    for y in 0 ..< storage.rows {
      let (first, last) = storage.store.unitSpan(storage.rowMap[y])
      for g in first ... last { protect(g) }
    }
    // Encoding verdicts expire when output may have changed a unit.
    if s.pointee.verdictEvicted != storage.history.evicted {
      s.pointee.verdictEvicted = storage.history.evicted
      for g in 0 ..< storage.store.unitCount {
        storage.store.units[g].incompressible = false
      }
    }
    let count = storage.history.count
    let lower = min(max(0, protecting.lowerBound), count)
    let upper = min(max(lower, protecting.upperBound), count)
    for index in lower ..< upper { protectRow(index) }
    signature.combine(lower)
    signature.combine(upper)
    if storage.history.isFull {
      // The next rows to recycle stay warm to soften resumed output.
      for index in 0 ..< min(GridStorage.chunkRows, count) { protectRow(index) }
      signature.combine(true)
    }
    for i in 0 ..< 8 {
      let g = Int(s.pointee.recent[i])
      signature.combine(g)
      if g >= 0, g < storage.store.unitCount { protect(g) }
    }
    s.pointee.protectedUnits = protectedUnits
    let total = storage.store.unitCount
    guard total > 0 else { return .idle }
    let protection = signature.finalize()
    // Line feeds change ownership without bumping the epoch; the eviction
    // and row counts identify them instead.
    var key = Hasher()
    key.combine(s.pointee.mutationEpoch)
    key.combine(storage.history.evicted)
    key.combine(storage.history.count)
    key.combine(storage.freeCount)
    let epoch = UInt64(truncatingIfNeeded: key.finalize())
    if s.pointee.passEpoch != epoch || s.pointee.passProtection != protection {
      s.pointee.passEpoch = epoch
      s.pointee.passProtection = protection
      s.pointee.passRemaining = total
    }
    var examined = 0
    var encoded = 0
    while examined < budget.maximumCandidates, s.pointee.passRemaining > 0,
      encoded < budget.maximumUnits
    {
      let g = s.pointee.cursor % total
      s.pointee.cursor = (g + 1) % total
      s.pointee.passRemaining -= 1
      examined += 1
      let unit = storage.store.units[g]
      guard unit.state == .resident, !unit.incompressible,
        unit.protectedStamp != stamp,
        storage.store.unitBytes(g).count <= budget.maximumUnitBytes,
        storage.store.isFullyUsed(g)
      else { continue }
      if storage.store.compress(g) == .compressed { encoded += 1 }
    }
    // Compression changes no ownership, so the pass continues.
    guard s.pointee.passRemaining == 0 else { return .pending }
    storage.store.releaseEncodeWorkspace()
    return .idle
  }

  /// Metadata-only accounting; never decodes.
  func scrollbackStatistics() -> ScrollbackStatistics {
    let geometry = storage.store.geometry
    var r = ScrollbackStatistics()
    r.logicalHistoryCellBytes = storage.history.count * geometry.rowBytes
    r.reservedMappingBytes =
      storage.store.chunkCount
      * (storage.store.isMapped ? geometry.mappedBytes : geometry.chunkBytes)
    let s = storage.store.shared.pointee
    let screen = storage.screenUnits()
    for g in 0 ..< storage.store.unitCount {
      let unit = storage.store.units[g]
      guard unit.rows > 0 else { continue }
      let backing =
        storage.store.isMapped
        ? storage.store.unitBackingBytes(g) : storage.store.unitBytes(g).count
      switch unit.state {
      case .resident:
        let owners = storage.store.ownership(g)
        if owners.uninitialized < Int(unit.rows) {
          r.residentUnits += 1
          r.residentUnitBytes += backing
        }
        if storage.store.isMapped, owners.free == 0, !screen.contains(g),
          !unit.incompressible,
          s.protectStamp == 0 || unit.protectedStamp != s.protectStamp
        {
          r.eligibleUnitBytes += backing
        }
      case .compressed:
        r.compressedUnits += 1
        r.compressedPayloadBytes += malloc_size(unit.payload!)
      case .discarded:
        r.discardedUnits += 1
        r.reclaimedFreeBytes += backing
      }
      if s.protectStamp != 0, unit.protectedStamp == s.protectStamp {
        r.protectedUnitBytes += backing
      }
    }
    r.metadataBytes =
      storage.history.capacity * 4 + storage.rows * 4 + storage.capacity
      * (MemoryLayout<Bool>.stride + 1 + 4 + 4 + 1) + storage.store.maxChunks
      * geometry.unitsPerChunk * MemoryLayout<UnitDescriptor>.stride + storage
      .store.maxChunks
      * (MemoryLayout<UnsafeMutablePointer<Cell>>.stride
        + MemoryLayout<MappedCellChunk>.stride)
      + MemoryLayout<CellStoreShared>.stride
    for p in [
      s.scanUnit, s.decodeScratch, s.encodeScratch, s.encodeStage, s.packStage,
    ] { if let p { r.workspaceBytes += malloc_size(p) } }
    if let row = s.scanRow { r.workspaceBytes += malloc_size(row) }
    let work = s.work
    r.compressions = work.compressions
    r.compressNanoseconds = work.compressNanoseconds
    r.unprofitableAttempts = work.unprofitable
    r.failedAttempts = work.failures
    r.readRestores = work.restoreCount(.read)
    r.recycleRestores = work.restoreCount(.recycle)
    r.compactionRestores = work.restoreCount(.compaction)
    r.otherRestores = work.restoreCount(.other)
    r.restoreNanoseconds = work.restoreNanoseconds
    r.scanDecodes = work.scanDecodes
    r.discardedPayloads = work.discardedPayloads
    r.reclaimedUnits = work.reclaimedUnits
    return r
  }
}

// MARK: TerminalState

extension TerminalState {
  /// Requested and effective compression for primary-screen history.
  public var scrollbackCompression: ScrollbackCompressionPolicy {
    let reason =
      isAlternateScreen
      ? inactiveGrid.scrollbackFallbackReason : grid.scrollbackFallbackReason
    let requested = scrollbackCompressionRequested
    return ScrollbackCompressionPolicy(
      requested: requested,
      effective: requested && reason == nil,
      fallbackReason: requested ? reason : "compression is turned off"
    )
  }

  /// Turns compression maintenance on or off. Turning it off never decodes
  /// existing history: cold rows stay readable and restore on demand.
  public mutating func setScrollbackCompression(_ requested: Bool) {
    scrollbackCompressionRequested = requested
  }

  /// Changes whenever either screen's row pool is replaced (reset,
  /// resize), so a stale scheduled step can be recognised.
  public var scrollbackGeneration: UInt64 {
    grid.storageGeneration &* 0x9E37_79B9_7F4A_7C15
      ^ inactiveGrid.storageGeneration
  }

  /// One bounded maintenance step over primary history: encodes at most
  /// `budget.maximumUnits` cold units outside the viewport and the recent
  /// captures. Changes no terminal content, damage or generations.
  /// `expectedGeneration` makes a step scheduled against replaced storage
  /// a no-op.
  public mutating func maintainScrollback(
    budget: ScrollbackMaintenanceBudget = ScrollbackMaintenanceBudget(),
    expectedGeneration: UInt64? = nil
  ) -> ScrollbackMaintenanceResult {
    if let expectedGeneration, expectedGeneration != scrollbackGeneration {
      return .stale
    }
    guard scrollbackCompression.effective else { return .disabled }
    if isAlternateScreen {
      return inactiveGrid.maintainScrollback(
        protecting: 0 ..< 0,
        budget: budget
      )
    }
    var protecting = 0 ..< 0
    if viewportOffset > 0 {
      // The viewport plus one screen either side stays warm.
      let top = grid.historyCount - viewportOffset
      protecting = top - rows ..< top + 2 * rows
    }
    return grid.maintainScrollback(protecting: protecting, budget: budget)
  }

  /// Metadata-only accounting for both screens' storage.
  public var scrollbackStatistics: ScrollbackStatistics {
    grid.scrollbackStatistics() + inactiveGrid.scrollbackStatistics()
  }

  /// Whether a borrowed read promoted history or changed recent captures
  /// since the last call; the owner rearms maintenance when it did.
  public func takeScrollbackMaintenanceDirty() -> Bool {
    let a = grid.takeScrollbackMaintenanceDirty()
    let b = inactiveGrid.takeScrollbackMaintenanceDirty()
    return a || b
  }

  /// Releases idle codec and scan workspace (for example under memory
  /// pressure). Never encodes and never reduces retained history.
  public func releaseScrollbackWorkspace() {
    grid.releaseScrollbackWorkspace()
    inactiveGrid.releaseScrollbackWorkspace()
  }
}

// MARK: Scheduling

/// Monotonic time and a single re-armable deadline for the coordinator.
public protocol ScrollbackMaintenanceClock: AnyObject, Sendable {
  /// Monotonic nanoseconds.
  var now: UInt64 { get }
  /// Calls `handler` once at or after `deadline`, replacing any deadline
  /// armed earlier.
  func arm(_ deadline: UInt64, _ handler: @escaping @Sendable () -> Void)
  func disarm()
}

/// A dispatch-timer clock on a private queue.
public final class DispatchScrollbackMaintenanceClock:
  ScrollbackMaintenanceClock, Sendable
{
  private let queue = DispatchQueue(label: "swiftty.scrollback-maintenance")
  private let timer = Mutex<DispatchSourceTimer?>(nil)

  public init() {}

  public var now: UInt64 { monotonicNanoseconds() }

  public func arm(_ deadline: UInt64, _ handler: @escaping @Sendable () -> Void)
  {
    let source = DispatchSource.makeTimerSource(queue: queue)
    // Maintenance is opportunistic; allow the OS to coalesce wakeups.
    source.schedule(
      deadline: DispatchTime(uptimeNanoseconds: deadline),
      leeway: .milliseconds(5)
    )
    source.setEventHandler(handler: handler)
    source.resume()
    timer.withLock {
      $0?.cancel()
      $0 = source
    }
  }

  public func disarm() {
    timer.withLock {
      $0?.cancel()
      $0 = nil
    }
  }
}

/// An owner of terminal state whose maintenance runs on its own queue.
public protocol ScrollbackMaintenanceOwner: AnyObject, Sendable {
  /// Runs one step on the owner's queue (never synchronously on the
  /// caller's), then calls `completion` from any thread. `generation` is
  /// the storage generation reported with the latest activity.
  func performScrollbackMaintenance(
    generation: UInt64,
    completion: @escaping @Sendable (ScrollbackMaintenanceReport) -> Void
  )
  /// Releases idle workspace on the owner's queue (memory pressure).
  func releaseScrollbackWorkspace()
}

/// What one step did and how long it waited and ran.
public struct ScrollbackMaintenanceReport: Sendable, Equatable {
  public var result: ScrollbackMaintenanceResult
  /// From dispatch to the start of work on the owner's queue.
  public var queueWaitNanoseconds: UInt64
  public var executionNanoseconds: UInt64

  public init(
    result: ScrollbackMaintenanceResult,
    queueWaitNanoseconds: UInt64 = 0,
    executionNanoseconds: UInt64 = 0
  ) {
    self.result = result
    self.queueWaitNanoseconds = queueWaitNanoseconds
    self.executionNanoseconds = executionNanoseconds
  }
}

/// Process-wide, fair scheduling of small maintenance steps. Holds owners
/// weakly, runs one step at a time, never waits on an owner's queue, and
/// stops its single timer when no work remains.
public final class ScrollbackMaintenanceCoordinator: Sendable {
  public static let shared = ScrollbackMaintenanceCoordinator()

  /// Quiet period after relevant activity before encoding.
  public let idleDelay: UInt64
  /// Minimum delay before another pending step.
  public let stepDelay: UInt64

  /// Scheduling counters.
  public struct Counters: Sendable, Equatable {
    public var steps = 0
    public var wakeups = 0
    public var totalQueueWaitNanoseconds: UInt64 = 0
    public var maximumQueueWaitNanoseconds: UInt64 = 0
    public var totalExecutionNanoseconds: UInt64 = 0
    public var maximumExecutionNanoseconds: UInt64 = 0
  }

  /// A registered owner; unregisters on `cancel()` or deinit.
  public final class Registration: Sendable {
    let id: UInt64
    weak let coordinator: ScrollbackMaintenanceCoordinator?

    init(id: UInt64, coordinator: ScrollbackMaintenanceCoordinator) {
      self.id = id
      self.coordinator = coordinator
    }

    /// Records relevant activity (output, input, viewport, resize, clear):
    /// work waits for `idleDelay` of quiet. Call once per batch.
    public func noteActivity(generation: UInt64) {
      coordinator?.noteActivity(id, generation: generation, postpone: true)
    }

    /// Requests a pass without postponing pending work (for example after
    /// a borrowed read promoted cold history).
    public func requestMaintenance(generation: UInt64) {
      coordinator?.noteActivity(id, generation: generation, postpone: false)
    }

    public func cancel() { coordinator?.unregister(id) }

    deinit { coordinator?.unregister(id) }
  }

  private struct Entry {
    weak var owner: (any ScrollbackMaintenanceOwner)?
    var pending = false
    var eligibleAt: UInt64 = 0
    var generation: UInt64 = 0
    var activity: UInt64 = 0
  }

  private struct State {
    var entries: [UInt64: Entry] = [:]
    var order: [UInt64] = []
    var next = 0
    var nextID: UInt64 = 0
    var inFlight: (id: UInt64, activity: UInt64)?
    var armedAt: UInt64?
    var counters = Counters()
  }

  private let clock: any ScrollbackMaintenanceClock
  private let state = Mutex(State())
  private let pressure: DispatchSourceMemoryPressure?

  public init(
    clock: any ScrollbackMaintenanceClock =
      DispatchScrollbackMaintenanceClock(),
    idleDelay: UInt64 = 250_000_000,
    stepDelay: UInt64 = 1_000_000,
    observesMemoryPressure: Bool = true
  ) {
    self.clock = clock
    self.idleDelay = idleDelay
    self.stepDelay = stepDelay
    if observesMemoryPressure {
      let source = DispatchSource.makeMemoryPressureSource(
        eventMask: [.warning, .critical],
        queue: .global(qos: .utility)
      )
      pressure = source
    } else {
      pressure = nil
    }
    pressure?.setEventHandler { [weak self] in self?.releaseWorkspace() }
    pressure?.resume()
  }

  deinit {
    pressure?.cancel()
    clock.disarm()
  }

  public var counters: Counters { state.withLock { $0.counters } }

  /// Registered owners still alive.
  public var ownerCount: Int {
    state.withLock { $0.entries.values.count { $0.owner != nil } }
  }

  /// Whether a wakeup is currently armed.
  public var isTimerArmed: Bool { state.withLock { $0.armedAt != nil } }

  public func register(_ owner: any ScrollbackMaintenanceOwner) -> Registration
  {
    let id = state.withLock {
      $0.nextID += 1
      $0.entries[$0.nextID] = Entry(owner: owner)
      $0.order.append($0.nextID)
      return $0.nextID
    }
    return Registration(id: id, coordinator: self)
  }

  func unregister(_ id: UInt64) {
    let disarm = state.withLock { s -> Bool in
      s.entries[id] = nil
      s.order.removeAll { $0 == id }
      guard s.armedAt != nil, !s.entries.values.contains(where: \.pending)
      else { return false }
      s.armedAt = nil
      return true
    }
    if disarm { clock.disarm() }
  }

  func noteActivity(_ id: UInt64, generation: UInt64, postpone: Bool) {
    let now = clock.now
    state.withLock { s in
      guard var entry = s.entries[id] else { return }
      entry.activity &+= 1
      entry.generation = generation
      if postpone {
        entry.eligibleAt = now + idleDelay
      } else if !entry.pending {
        entry.eligibleAt = max(entry.eligibleAt, now + idleDelay)
      }
      entry.pending = true
      s.entries[id] = entry
    }
    pump()
  }

  /// Timer callback.
  private func fire() {
    state.withLock {
      $0.armedAt = nil
      $0.counters.wakeups += 1
    }
    pump()
  }

  /// Dispatches the next eligible owner round-robin, or arms the timer
  /// for the earliest pending one. Owners are called outside the lock.
  private func pump() {
    let now = clock.now
    enum Action {
      case none
      case run(any ScrollbackMaintenanceOwner, UInt64, UInt64)
      case arm(UInt64)
      case disarm
    }
    let action = state.withLock { s -> Action in
      guard s.inFlight == nil else { return .none }
      // Drop owners that were torn down without cancelling.
      for id in s.order where s.entries[id]?.owner == nil {
        s.entries[id] = nil
      }
      s.order.removeAll { s.entries[$0] == nil }
      var earliest: UInt64?
      for step in 0 ..< s.order.count {
        let index = (s.next + step) % s.order.count
        let id = s.order[index]
        guard let entry = s.entries[id], entry.pending else { continue }
        if entry.eligibleAt <= now, let owner = entry.owner {
          s.next = (index + 1) % s.order.count
          s.inFlight = (id, entry.activity)
          s.entries[id]!.pending = false
          return .run(owner, id, entry.generation)
        }
        earliest = min(earliest ?? .max, entry.eligibleAt)
      }
      guard let earliest else {
        if s.armedAt != nil {
          s.armedAt = nil
          return .disarm
        }
        return .none
      }
      if let armed = s.armedAt, armed <= earliest { return .none }
      s.armedAt = earliest
      return .arm(earliest)
    }
    switch action {
    case .none: break
    case .disarm: clock.disarm()
    case let .arm(deadline): clock.arm(deadline) { [weak self] in self?.fire() }
    case let .run(owner, id, generation):
      owner.performScrollbackMaintenance(generation: generation) {
        [weak self] report in self?.complete(id, report)
      }
    }
  }

  private func complete(_ id: UInt64, _ report: ScrollbackMaintenanceReport) {
    let now = clock.now
    state.withLock { s in
      let dispatched = s.inFlight
      s.inFlight = nil
      s.counters.steps += 1
      s.counters.totalQueueWaitNanoseconds &+= report.queueWaitNanoseconds
      s.counters.maximumQueueWaitNanoseconds = max(
        s.counters.maximumQueueWaitNanoseconds,
        report.queueWaitNanoseconds
      )
      s.counters.totalExecutionNanoseconds &+= report.executionNanoseconds
      s.counters.maximumExecutionNanoseconds = max(
        s.counters.maximumExecutionNanoseconds,
        report.executionNanoseconds
      )
      guard var entry = s.entries[id] else { return }
      let newer = dispatched.map { $0.activity != entry.activity } ?? false
      if report.result == .pending {
        entry.pending = true
        entry.eligibleAt = max(entry.eligibleAt, now + stepDelay)
      } else {
        // Activity during the step keeps its own (already armed) request.
        entry.pending = entry.pending || newer
      }
      s.entries[id] = entry
    }
    pump()
  }

  private func releaseWorkspace() {
    let owners = state.withLock { $0.entries.values.compactMap(\.owner) }
    for owner in owners { owner.releaseScrollbackWorkspace() }
  }
}

/// Owner adapter: runs maintenance for one terminal state on its serial
/// queue. `step` runs on that queue and returns nil after teardown.
///
/// Sendable: the non-Sendable `step`/`release` closures run only on the
/// owner's `queue`; `registration` is behind a `Mutex`, so `cancel()` is
/// safe from any thread (an owner's `deinit` runs wherever its last
/// reference is dropped). Queued work holds the client weakly.
public final class ScrollbackMaintenanceClient: ScrollbackMaintenanceOwner,
  @unchecked Sendable
{
  private let queue: DispatchQueue
  private let step: (UInt64) -> ScrollbackMaintenanceResult?
  private let release: () -> Void
  private let registration:
    Mutex<ScrollbackMaintenanceCoordinator.Registration?>

  /// - Parameters:
  ///   - queue: The owner's serial queue, which owns the terminal state.
  ///   - coordinator: Schedules steps across owners.
  ///   - step: Runs one bounded step on `queue`; nil once torn down.
  ///   - release: Releases idle workspace on `queue`.
  public init(
    queue: DispatchQueue,
    coordinator: ScrollbackMaintenanceCoordinator = .shared,
    step: @escaping (UInt64) -> ScrollbackMaintenanceResult?,
    release: @escaping () -> Void
  ) {
    self.queue = queue
    self.step = step
    self.release = release
    registration = Mutex(nil)
    let registered = coordinator.register(self)
    registration.withLock { $0 = registered }
  }

  /// Call on the owner's queue after each batch of relevant activity.
  public func noteActivity(generation: UInt64) {
    registration.withLock { $0 }?.noteActivity(generation: generation)
  }

  /// Call on the owner's queue when a read promoted cold history.
  public func requestMaintenance(generation: UInt64) {
    registration.withLock { $0 }?.requestMaintenance(generation: generation)
  }

  /// Ends scheduling; queued steps become no-ops.
  public func cancel() {
    // Taken under the lock, cancelled outside it: the coordinator has its
    // own lock.
    registration.withLock { $0.take() }?.cancel()
  }

  public func performScrollbackMaintenance(
    generation: UInt64,
    completion: @escaping @Sendable (ScrollbackMaintenanceReport) -> Void
  ) {
    let dispatched = monotonicNanoseconds()
    queue.async { [weak self] in
      let start = monotonicNanoseconds()
      let result = self?.step(generation) ?? .idle
      completion(
        ScrollbackMaintenanceReport(
          result: result,
          queueWaitNanoseconds: start &- dispatched,
          executionNanoseconds: monotonicNanoseconds() &- start
        )
      )
    }
  }

  public func releaseScrollbackWorkspace() {
    queue.async { [weak self] in self?.release() }
  }
}
