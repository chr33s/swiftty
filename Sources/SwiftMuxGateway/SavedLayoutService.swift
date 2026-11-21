import CryptoKit
import Foundation
import SwiftMuxGuardian
import SwiftMuxProtocol
import os

/// What the gateway knows about one workspace in guardian inventory.
package enum SavedLayoutInventoryState: Sendable, Equatable {
  /// Available with a published graph.
  case live(name: String)
  /// The worker is definitively empty: no published workspace.
  case empty
  case unavailable
  /// Starting or still discovering.
  case pending
}

package struct SavedLayoutInventory: Sendable {
  package var incarnation: UUID?
  package var workspaces: [WorkspaceID: SavedLayoutInventoryState]

  package init(
    incarnation: UUID?,
    workspaces: [WorkspaceID: SavedLayoutInventoryState]
  ) {
    self.incarnation = incarnation
    self.workspaces = workspaces
  }

  var names: Set<String> {
    Set(
      workspaces.values.compactMap {
        if case let .live(name) = $0 { name } else { nil }
      }
    )
  }
}

/// The gateway's saved-layout store (spec.durability.md §12.2). It is never
/// on the PTY I/O, command-admission or migration path: failures here change
/// only what is saved.
package actor SavedLayoutService {
  package struct Timing: Sendable {
    /// Exit-caused changes wait this long (§12.2.5).
    package var exitHold: Duration = .seconds(10)
    /// Per-workspace minimum between writes.
    package var writeInterval: Duration = .seconds(5)
    package var writesPerSecond = 2
    package var maxBackoff: Duration = .seconds(300)
    /// C1: how often changed output is exported from live workspaces.
    package var outputInterval: Duration = .seconds(60)
    package init() {}
  }

  package struct Limits: Sendable {
    package var savedRecords = 32
    package var layoutBytes = 256 << 10
    package var storeBytes = 64 << 20
    package var maxPanes = MuxLimits.standard.maxPanes
    package init() {}
  }

  private struct Loaded {
    var record: SavedLayoutRecord
    var generations: [UInt64]
    /// C1 sections by slot: this workspace's output, and output carried
    /// over from the record it was reopened from.
    var outputs: [Int: Data] = [:]
    var previous: [Int: Data] = [:]
  }

  private struct Live {
    var authority: GuardianAuthority
    var content: SavedLayoutContent?
    var layoutRevision: UInt64 = 0
    /// Content observed but not yet written.
    var pending = false
    /// The pending change includes an exit; it waits out the hold.
    var heldUntil: ContinuousClock.Instant?
    var lastWrite: ContinuousClock.Instant?
    var retryAt: ContinuousClock.Instant?
    var failures = 0
    var notSavedSince: Date?
    /// `exited` waiting out the hold before the record is deleted.
    var exitedAt: ContinuousClock.Instant?
    /// Pane to slot, for the content last observed.
    var slots: [PaneID: Int] = [:]
    var source: SavedOutputSource?
    var outputRevisions: [PaneID: UInt64] = [:]
    var outputs: [Int: Data] = [:]
    /// Carried output by pane; a pane that ends drops its own.
    var previous: [PaneID: Data] = [:]
    /// The record's previous output has been mapped onto panes.
    var previousMapped = false
  }

  private let files: SavedLayoutFiles
  private let keys: any SavedLayoutKeyStore
  private let build: String
  private let timing: Timing
  private let limits: Limits
  private let log = Logger(subsystem: "dev.chr33s.swiftmux", category: "saved")
  private let clock = ContinuousClock()
  /// End and Forget a definitively empty worker after its disposition.
  private var retire: @Sendable (GuardianAuthority) async -> Void = { _ in }

  private var policy = SavedLayoutPolicy.defaults
  private var policyReadable = true
  private var key: SymmetricKey?
  private var store: SavedWorkspaceList.StoreState = .available
  private var records: [WorkspaceID: Loaded] = [:]
  private var newer: Set<WorkspaceID> = []
  private var unreadable: Set<WorkspaceID> = []
  private var live: [WorkspaceID: Live] = [:]
  private var reopening: Set<WorkspaceID> = []
  private var nextStoreSequence: UInt64 = 1
  private var recentWrites: [ContinuousClock.Instant] = []
  private var timer: Task<Void, Never>?
  private var timerDue: ContinuousClock.Instant?
  private var incarnation: UUID?
  private var stopping = false
  private var started = false
  /// Output carried from a reopened record to its new workspace, by pane.
  private var carry: [WorkspaceID: [PaneID: Data]] = [:]
  private var outputTimer: Task<Void, Never>?

  package init(
    files: SavedLayoutFiles,
    keys: any SavedLayoutKeyStore,
    build: String,
    timing: Timing = Timing(),
    limits: Limits = Limits()
  ) {
    self.files = files
    self.keys = keys
    self.build = build
    self.timing = timing
    self.limits = limits
  }

  deinit {
    timer?.cancel()
    outputTimer?.cancel()
  }

  package func setRetire(
    _ value: @escaping @Sendable (GuardianAuthority) async -> Void
  ) { retire = value }

  package var currentPolicy: SavedLayoutPolicy { policy }
  package var storeState: SavedWorkspaceList.StoreState { store }
  package var recordIDs: Set<WorkspaceID> { Set(records.keys) }
  package func record(_ id: WorkspaceID) -> SavedLayoutRecord? {
    records[id]?.record
  }
  package func notSavedSince(_ id: WorkspaceID) -> Date? {
    live[id]?.notSavedSince
  }

  // MARK: Startup

  /// Loads the policy, key and every record. Never creates a shell.
  package func start(incarnation: UUID?) {
    self.incarnation = incarnation
    started = true
    do {
      policy = try files.readPolicy() ?? .defaults
      policyReadable = true
    } catch {
      // An unreadable policy disables writing and deletion (§12.2.2).
      policyReadable = false
      log.error("saved layout policy unreadable: \(error, privacy: .public)")
    }
    guard policy.saveLayout || !policyReadable else { return }
    do { try files.prepare() } catch {
      store = .unavailable("cannot prepare the saved layout directory")
      return
    }
    loadKey()
    if key != nil { loadRecords() }
  }

  private func loadKey() {
    switch keys.lookup() {
    case let .found(value):
      key = value
      if case .unavailable = store { store = .available }
    case .notFound:
      let existing = (try? files.generations()) ?? [:]
      if !existing.isEmpty {
        // Only a definitively missing key loses records (§12.2.4).
        guard policyReadable else { return }
        for id in existing.keys { try? files.removeAll(id) }
        store = .keyLost
        log.error("saved layout key missing; earlier records deleted")
      }
      guard policyReadable, policy.saveLayout else { return }
      do {
        key = try keys.create()
        if case .unavailable = store { store = .available }
      } catch { store = .unavailable("\(error)") }
    case let .unavailable(reason):
      key = nil
      store = .unavailable(reason)
    }
  }

  private func ensureKey() -> SymmetricKey? {
    if let key { return key }
    loadKey()
    if key != nil, records.isEmpty { loadRecords() }
    return key
  }

  private func loadRecords() {
    guard let key else { return }
    records = [:]
    newer = []
    unreadable = []
    let generations = (try? files.generations()) ?? [:]
    for (id, list) in generations {
      var loaded: Loaded?
      var readable: [UInt64] = []
      for generation in list.reversed() {
        do {
          let record = try open(id, generation: generation, key: key)
          if loaded == nil { loaded = record }
          readable.append(generation)
        } catch is SavedLayoutNewerSchema {
          if loaded == nil { newer.insert(id) }
        } catch {
          // Never partially reopen; keep the bytes for diagnostics.
          if policyReadable { files.quarantine(id, generation: generation) }
        }
      }
      if var loaded {
        newer.remove(id)
        loaded.generations = readable.sorted()
        records[id] = loaded
        nextStoreSequence = max(
          nextStoreSequence,
          loaded.record.storeSequence + 1
        )
      } else if !newer.contains(id) {
        unreadable.insert(id)
      }
    }
  }

  private func open(
    _ id: WorkspaceID,
    generation: UInt64,
    key: SymmetricKey
  ) throws -> Loaded {
    let sections = try SavedLayoutSeal.open(
      try files.read(id, generation: generation),
      workspace: id,
      generation: generation,
      key: key
    )
    guard let section = sections.first(where: { $0.kind == .record }) else {
      throw MuxError(.invalidRequest, "saved layout record section missing")
    }
    let record = try SavedLayoutSeal.decode(section.bytes)
    guard record.workspace == id, record.generation == generation else {
      throw MuxError(.invalidRequest, "saved layout record identity mismatch")
    }
    try record.validate(maxPanes: limits.maxPanes)
    var loaded = Loaded(record: record, generations: [generation])
    for section in sections where section.kind != .record {
      // Slot, then the at-rest rows; both are validated before use.
      guard section.bytes.count > 2 else {
        throw MuxError(.invalidRequest, "empty saved output section")
      }
      let start = section.bytes.startIndex
      let slot = Int(section.bytes[start]) << 8 | Int(section.bytes[start + 1])
      let body = section.bytes.subdata(in: start + 2 ..< section.bytes.endIndex)
      guard slot < record.content.paneCount else {
        throw MuxError(.invalidRequest, "saved output slot out of range")
      }
      _ = try SavedOutput(decoding: body)
      if section.kind == .output {
        loaded.outputs[slot] = body
      } else {
        loaded.previous[slot] = body
      }
    }
    return loaded
  }

  // MARK: Observation

  /// Every consumed graph event of a scoped worker (§12.2.5, §12.2.6).
  package func observe(_ authority: GuardianAuthority, state: SavedLayoutState)
  {
    guard started, !stopping else { return }
    let id = authority.workspace
    // A rediscovered workspace compares against its record, not nothing.
    var entry =
      live[id]
      ?? Live(
        authority: authority,
        content: records[id]?.record.content,
        outputs: records[id]?.outputs ?? [:]
      )
    entry.authority = authority
    if let end = state.end {
      live[id] = entry
      ended(id, end: end)
      return
    }
    guard let content = SavedLayoutContent(state) else {
      live[id] = entry
      return
    }
    let changed = entry.content != content
    entry.content = content
    entry.slots = SavedLayoutContent.slots(state)
    if !entry.previousMapped {
      entry.previousMapped = true
      let panes = Dictionary(
        entry.slots.map { ($0.value, $0.key) },
        uniquingKeysWith: { first, _ in first }
      )
      for (slot, bytes) in records[id]?.previous ?? [:] {
        if let pane = panes[slot] { entry.previous[pane] = bytes }
      }
    }
    if let carried = carry.removeValue(forKey: id) {
      // Output from the record this workspace was reopened from (§12.2.8).
      entry.previous.merge(carried) { _, new in new }
      entry.pending = true
    }
    // A pane that ended takes its previous output with it.
    let before = entry.previous.count
    entry.previous = entry.previous.filter { entry.slots[$0.key] != nil }
    if entry.previous.count != before { entry.pending = true }
    entry.layoutRevision = state.graph?.layoutRevision ?? entry.layoutRevision
    if changed || records[id] == nil {
      entry.pending = true
      if state.causes.contains(.exit) {
        // Hold exit-caused changes so shutdown cannot shrink a layout.
        entry.heldUntil = entry.heldUntil ?? clock.now + timing.exitHold
      }
    }
    live[id] = entry
    pump()
  }

  /// A lost worker discards its held exit changes; its record stays.
  package func workerLost(_ id: WorkspaceID) {
    guard var entry = live[id] else { return }
    if entry.heldUntil != nil {
      entry.pending = false
      entry.heldUntil = nil
    }
    entry.exitedAt = nil
    live[id] = entry
  }

  /// Guardian loss: every held exit change is discarded (§12.2.5).
  package func guardianLost() { for id in Array(live.keys) { workerLost(id) } }

  /// SIGTERM: one pass writing command-caused changes only.
  package func shutdown() {
    guard !stopping else { return }
    outputTimer?.cancel()
    outputTimer = nil
    guardianLost()
    for id in Array(live.keys) where live[id]?.pending == true { write(id) }
    stopping = true
    timer?.cancel()
    timer = nil
  }

  private func ended(_ id: WorkspaceID, end: SavedLayoutEnd) {
    guard var entry = live[id] else { return }
    entry.pending = false
    entry.heldUntil = nil
    switch end {
    case .ended(.ended):
      live[id] = entry
      delete(id)
      retireLater(entry.authority)
    case .ended(.retained):
      live.removeValue(forKey: id)
      if records[id] != nil { persist(id) { $0.disposition = .retained } }
      retireLater(entry.authority)
    case .exited:
      if entry.exitedAt == nil { entry.exitedAt = clock.now + timing.exitHold }
      live[id] = entry
      pump()
    }
  }

  private func retireLater(_ authority: GuardianAuthority) {
    live.removeValue(forKey: authority.workspace)
    let retire = self.retire
    Task { await retire(authority) }
  }

  // MARK: Writing

  private func pump() {
    guard !stopping else { return }
    let now = clock.now
    var next: ContinuousClock.Instant?
    recentWrites.removeAll { now - $0 >= .seconds(1) }
    for id in Array(live.keys) {
      guard let entry = live[id] else { continue }
      if let exitedAt = entry.exitedAt {
        if exitedAt <= now {
          delete(id)
          retireLater(entry.authority)
        } else {
          next = min(next ?? exitedAt, exitedAt)
        }
        continue
      }
      guard entry.pending else { continue }
      var due = now
      if let held = entry.heldUntil { due = max(due, held) }
      if let last = entry.lastWrite {
        due = max(due, last + timing.writeInterval)
      }
      if let retry = entry.retryAt { due = max(due, retry) }
      if due <= now, recentWrites.count < timing.writesPerSecond {
        write(id)
        recentWrites.append(now)
      } else {
        let wake = due <= now ? (recentWrites.first ?? now) + .seconds(1) : due
        next = min(next ?? wake, wake)
      }
    }
    if let next { schedule(next) }
  }

  private func schedule(_ instant: ContinuousClock.Instant) {
    if let timerDue, timerDue <= instant, timer != nil { return }
    timer?.cancel()
    timerDue = instant
    timer = Task { [weak self, clock] in
      try? await clock.sleep(until: instant)
      guard !Task.isCancelled else { return }
      await self?.timerFired()
    }
  }

  private func timerFired() {
    timer = nil
    timerDue = nil
    pump()
  }

  private func write(_ id: WorkspaceID) {
    guard var entry = live[id], let content = entry.content else { return }
    entry.pending = false
    entry.heldUntil = nil
    entry.lastWrite = clock.now
    live[id] = entry
    let revision = entry.layoutRevision
    let incarnation = entry.authority.incarnation
    let previous = Dictionary(
      entry.previous.compactMap { pane, bytes in
        entry.slots[pane].map { ($0, bytes) }
      },
      uniquingKeysWith: { first, _ in first }
    )
    let ok = persist(
      id,
      content: content,
      outputs: entry.outputs,
      previous: previous
    ) { record in
      record.content = content
      record.layoutRevision = revision
      record.incarnation = incarnation
    }
    guard var after = live[id] else { return }
    if ok {
      after.failures = 0
      after.retryAt = nil
      after.notSavedSince = nil
    } else {
      // Retry on our own timer, whether or not the workspace changes again.
      after.pending = true
      after.failures += 1
      after.notSavedSince = after.notSavedSince ?? Date()
      let seconds = min(
        Double(1 << min(after.failures, 9)),
        Double(timing.maxBackoff.components.seconds)
      )
      after.retryAt = clock.now + .seconds(seconds)
    }
    live[id] = after
  }

  /// Writes a new generation. The policy revision is checked immediately
  /// before publishing; a change in between drops the write.
  @discardableResult
  private func persist(
    _ id: WorkspaceID,
    content: SavedLayoutContent? = nil,
    outputs newOutputs: [Int: Data]? = nil,
    previous newPrevious: [Int: Data]? = nil,
    _ change: (inout SavedLayoutRecord) -> Void
  ) -> Bool {
    let revision = policy.revision
    guard policyReadable, policy.saveLayout, let key = ensureKey() else {
      return false
    }
    guard !newer.contains(id) || live[id] != nil else { return false }
    let previous = records[id]
    guard
      var record = previous?.record
        ?? content.map({
          SavedLayoutRecord(
            build: build,
            workspace: id,
            generation: 1,
            storeSequence: 0,
            incarnation: incarnation ?? UUID(),
            layoutRevision: 0,
            savedAt: Date(),
            content: $0
          )
        })
    else { return false }
    change(&record)
    let generation = (previous?.generations.last ?? 0) + 1
    record.schema = SavedLayoutRecord.schema
    record.build = build
    record.generation = generation
    record.storeSequence = nextStoreSequence
    record.savedAt = Date()
    // Output is kept only while the policy and the workspace allow it.
    let keepsOutput = policy.saveOutput && !record.content.outputOptOut
    let outputs = keepsOutput ? (newOutputs ?? previous?.outputs ?? [:]) : [:]
    let carried = keepsOutput ? (newPrevious ?? previous?.previous ?? [:]) : [:]
    do {
      let body = try SavedLayoutSeal.encode(record)
      guard body.count <= limits.layoutBytes else {
        throw MuxError(.resourceLimit, "saved layout exceeds its bound")
      }
      var sections = [SavedLayoutSection(kind: .record, bytes: body)]
      for (kind, values) in [
        (SavedLayoutSection.Kind.output, outputs), (.previousOutput, carried),
      ] {
        for (slot, bytes) in values.sorted(by: { $0.key < $1.key })
        where slot < record.content.paneCount {
          var section = Data([UInt8(slot >> 8), UInt8(slot & 0xFF)])
          section.append(bytes)
          sections.append(SavedLayoutSection(kind: kind, bytes: section))
        }
      }
      let size = sections.reduce(64) { $0 + $1.bytes.count }
      if files.totalBytes() + size > limits.storeBytes {
        trimOutput(keeping: id)
      }
      if files.totalBytes() + size > limits.storeBytes, sections.count > 1 {
        // Never drop layout: keep this write to its record section.
        sections = [sections[0]]
      }
      guard
        files.totalBytes() + body.count + 64 <= limits.storeBytes
          || previous != nil
      else { throw MuxError(.resourceLimit, "saved layout store is full") }
      let sealed = try SavedLayoutSeal.seal(
        sections,
        workspace: id,
        generation: generation,
        key: key
      )
      guard policy.revision == revision, policy.saveLayout else { return false }
      try files.write(sealed, id, generation: generation)
    } catch {
      log.error("saved layout write failed: \(error, privacy: .public)")
      return false
    }
    nextStoreSequence += 1
    var generations = (previous?.generations ?? []) + [generation]
    while generations.count > 2 {
      files.remove(id, generation: generations.removeFirst())
    }
    records[id] = Loaded(
      record: record,
      generations: generations,
      outputs: outputs,
      previous: carried
    )
    newer.remove(id)
    unreadable.remove(id)
    evict()
    return true
  }

  /// Over the store bound: output of Saved records goes first, oldest
  /// store sequence first (§12.2.9).
  private func trimOutput(keeping id: WorkspaceID) {
    let candidates = records.values
      .filter {
        $0.record.workspace != id && live[$0.record.workspace] == nil
          && !($0.outputs.isEmpty && $0.previous.isEmpty)
      }
      .sorted { $0.record.storeSequence < $1.record.storeSequence }
    for loaded in candidates {
      guard files.totalBytes() > limits.storeBytes * 3 / 4 else { return }
      persist(loaded.record.workspace, outputs: [:], previous: [:]) { _ in }
    }
  }

  private func delete(_ id: WorkspaceID) {
    guard policyReadable else { return }
    try? files.removeAll(id)
    records.removeValue(forKey: id)
    newer.remove(id)
    unreadable.remove(id)
  }

  /// At most `savedRecords` Saved records; Live and Unavailable never count.
  private func evict() {
    let saved = records.values.filter { live[$0.record.workspace] == nil }
      .sorted { $0.record.storeSequence < $1.record.storeSequence }
    guard saved.count > limits.savedRecords else { return }
    for loaded in saved.prefix(saved.count - limits.savedRecords) {
      delete(loaded.record.workspace)
    }
  }

  // MARK: Saved output (C1)

  /// The worker connection that can export a workspace's output; nil when
  /// its observation ends.
  package func setOutputSource(
    _ authority: GuardianAuthority,
    _ source: SavedOutputSource?
  ) {
    let id = authority.workspace
    if source == nil {
      live[id]?.source = nil
      return
    }
    var entry =
      live[id]
      ?? Live(
        authority: authority,
        content: records[id]?.record.content,
        outputs: records[id]?.outputs ?? [:]
      )
    entry.source = source
    live[id] = entry
    scheduleOutput()
  }

  private func scheduleOutput() {
    guard outputTimer == nil, !stopping else { return }
    let interval = timing.outputInterval
    outputTimer = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: interval)
        guard !Task.isCancelled else { return }
        await self?.exportOutputs()
      }
    }
  }

  /// One export pass; a policy change while it runs drops its results.
  package func exportOutputs() async {
    guard started, !stopping, policyReadable, policy.saveLayout,
      policy.saveOutput
    else { return }
    let revision = policy.revision
    for id in Array(live.keys) {
      guard let entry = live[id], let source = entry.source,
        let content = entry.content, !content.outputOptOut
      else { continue }
      var changed: [Int: Data] = [:]
      var revisions: [PaneID: UInt64] = [:]
      for (pane, slot) in entry.slots {
        do {
          let result = try await source(pane, entry.outputRevisions[pane])
          revisions[pane] = result.revision
          if let bytes = result.bytes { changed[slot] = bytes }
        } catch {
          // Alternate screen, a frozen workspace or a lost worker: keep
          // the previous output section.
          continue
        }
      }
      guard policy.revision == revision, policy.saveOutput,
        var current = live[id]
      else { return }
      for (pane, value) in revisions { current.outputRevisions[pane] = value }
      if !changed.isEmpty {
        for (slot, bytes) in changed { current.outputs[slot] = bytes }
        current.pending = true
      }
      live[id] = current
    }
    pump()
  }

  /// The output carried into a reopened workspace's pane, in pages.
  package func previousOutput(
    _ id: WorkspaceID,
    pane: PaneID,
    offset: Int
  ) throws -> SavedOutputPage {
    guard let bytes = live[id]?.previous[pane] else {
      throw MuxError(.notFound, "no previous output for this pane")
    }
    guard offset >= 0, offset < max(1, bytes.count) else {
      throw MuxError(.invalidRequest, "invalid previous output offset")
    }
    let end = min(bytes.count, offset + SavedOutputPage.maxBytes)
    return SavedOutputPage(
      revision: 0,
      modified: true,
      total: bytes.count,
      offset: offset,
      bytes: bytes.subdata(
        in: bytes.startIndex + offset ..< bytes.startIndex + end
      )
    )
  }

  /// Discard Previous Output, or a pane's end. Nil discards every pane's.
  package func discardPreviousOutput(_ id: WorkspaceID, pane: PaneID?) {
    guard var entry = live[id] else { return }
    if let pane {
      entry.previous.removeValue(forKey: pane)
    } else {
      entry.previous = [:]
    }
    let previous = Dictionary(
      entry.previous.compactMap { pane, bytes in
        entry.slots[pane].map { ($0, bytes) }
      },
      uniquingKeysWith: { first, _ in first }
    )
    live[id] = entry
    persist(id, previous: previous) { _ in }
  }

  /// Save output turned off: every record is rewritten without output under
  /// a new key, and the old generations and key go (§12.2.2).
  private func dropOutputAndRotateKey() throws {
    // Refuse before rewriting anything if the keychain cannot take a key.
    guard case .found = keys.lookup() else {
      throw MuxError(.unauthorized, "the saved layout key is unavailable")
    }
    let newKey = SymmetricKey(size: .bits256)
    key = newKey
    for id in Array(live.keys) {
      live[id]?.outputs = [:]
      live[id]?.previous = [:]
    }
    carry = [:]
    for id in Array(records.keys) {
      let old = records[id]?.generations ?? []
      guard persist(id, outputs: [:], previous: [:], { _ in }) else { continue }
      for generation in old { files.remove(id, generation: generation) }
      if let latest = records[id]?.generations.last {
        records[id]?.generations = [latest]
      }
    }
    try keys.replace(with: newKey)
  }

  // MARK: Gateway-issued End

  /// Before the gateway ends a live workspace itself: a crash after End
  /// still deletes the record.
  package func markEnding(
    _ id: WorkspaceID,
    disposition: SavedLayoutDisposition
  ) {
    guard records[id] != nil else { return }
    persist(id) { $0.disposition = disposition }
  }

  package func didEnd(_ id: WorkspaceID, disposition: SavedLayoutDisposition) {
    live.removeValue(forKey: id)
    if disposition == .ended { delete(id) }
  }

  // MARK: Discovery

  private func state(
    of record: SavedLayoutRecord,
    in inventory: SavedLayoutInventory
  ) -> SavedWorkspaceListing.State {
    let sameIncarnation = record.incarnation == inventory.incarnation
    switch sameIncarnation ? inventory.workspaces[record.workspace] : nil {
    case .live?: return .live
    case .unavailable?: return .unavailable
    default: return .saved
    }
  }

  /// Settlement, supersession, applied dispositions and retention. Runs
  /// after each inventory refresh; never creates or ends a live shell.
  package func reconcile(
    _ inventory: SavedLayoutInventory,
    endEmpty: @Sendable (WorkspaceID) async throws -> Void
  ) async {
    guard started, policyReadable, key != nil || ensureKey() != nil else {
      return
    }
    incarnation = inventory.incarnation ?? incarnation
    for id in Array(records.keys) {
      guard let record = records[id]?.record else { continue }
      // A record whose reopened successor has its own record is superseded.
      if let successor = record.reopeningAs, records[successor] != nil {
        delete(id)
        continue
      }
      if record.disposition == .ended, inventory.workspaces[id] == nil {
        delete(id)
        continue
      }
      if let target = record.reopeningAs, !reopening.contains(id),
        record.incarnation == inventory.incarnation
          || inventory.workspaces[target] != nil
      {
        switch inventory.workspaces[target] {
        case .live?: delete(id)
        case .empty?:
          // The template was never applied; its worker owns no process.
          do {
            try await endEmpty(target)
            persist(id) { $0.reopeningAs = nil }
          } catch {}
        case .unavailable?, .pending?: break
        case nil:
          // The target is gone: the record can be reopened again.
          persist(id) { $0.reopeningAs = nil }
        }
        continue
      }
      if state(of: record, in: inventory) == .saved, live[id] == nil,
        let offered = record.firstOfferedAt
      {
        let expiry = offered.addingTimeInterval(
          Double(policy.retentionDays) * 86_400
        )
        if Date() >= expiry { delete(id) }
      }
    }
    evict()
  }

  /// Lists records and marks Saved ones offered (§12.2.7).
  package func list(
    _ inventory: SavedLayoutInventory,
    markOffered: Bool
  ) -> SavedWorkspaceList {
    var listings: [SavedWorkspaceListing] = []
    for loaded in records.values.sorted(by: {
      $0.record.storeSequence > $1.record.storeSequence
    }) {
      let record = loaded.record
      let state = state(of: record, in: inventory)
      if markOffered, state == .saved, record.firstOfferedAt == nil {
        persist(record.workspace) { $0.firstOfferedAt = Date() }
      }
      listings.append(
        SavedWorkspaceListing(
          id: record.workspace,
          state: state,
          name: record.content.name,
          savedAt: min(record.savedAt, Date()),
          build: record.build == build ? nil : record.build,
          tabCount: record.content.tabs.count,
          paneCount: record.content.paneCount,
          commands: record.content.commandSlots,
          hasOutput: !loaded.outputs.isEmpty || !loaded.previous.isEmpty
        )
      )
    }
    for id in newer.sorted(by: { $0.description < $1.description }) {
      listings.append(
        SavedWorkspaceListing(
          id: id,
          state: .newer,
          name: id.short,
          savedAt: nil,
          build: nil,
          tabCount: 0,
          paneCount: 0,
          commands: [],
          hasOutput: false
        )
      )
    }
    for id in unreadable.sorted(by: { $0.description < $1.description }) {
      listings.append(
        SavedWorkspaceListing(
          id: id,
          state: .unreadable,
          name: id.short,
          savedAt: nil,
          build: nil,
          tabCount: 0,
          paneCount: 0,
          commands: [],
          hasOutput: false
        )
      )
    }
    return SavedWorkspaceList(
      store: store,
      policy: policy,
      workspaces: listings
    )
  }

  // MARK: Reopening

  /// One reopen per record at a time (§12.2.7). `create` runs explicit
  /// gateway creation with the template; an uncertain outcome is never
  /// retried here.
  package func reopen(
    _ request: SavedReopenRequest,
    inventory: SavedLayoutInventory,
    create:
      @Sendable (WorkspaceID, WorkspaceTemplate) async throws ->
      WorkspaceTemplateOutcome
  ) async throws -> (WorkspaceID, WorkspaceTemplateOutcome) {
    let id = request.record
    guard let record = records[id]?.record else {
      throw MuxError(.notFound, "no saved layout \(id.short)")
    }
    guard !reopening.contains(id), record.reopeningAs == nil else {
      throw MuxError(.quiescing, "this saved layout is already reopening")
    }
    switch state(of: record, in: inventory) {
    case .saved, .unavailable: break
    default: throw MuxError(.invalidRequest, "this workspace is still live")
    }
    var name = record.content.name
    let taken = inventory.names
    if taken.contains(name) {
      var n = 2
      while taken.contains("\(record.content.name) (\(n))") { n += 1 }
      name = "\(record.content.name) (\(n))"
    }
    let template = record.content.template(request, name: name)
    try template.validate(maxPanes: limits.maxPanes)
    let target = WorkspaceID()
    reopening.insert(id)
    defer { reopening.remove(id) }
    guard persist(id, { $0.reopeningAs = target }) else {
      throw MuxError(.resourceLimit, "cannot record the reopen; not started")
    }
    let outputs = records[id]?.outputs ?? [:]
    do {
      let outcome = try await create(target, template)
      if policy.saveOutput, !outputs.isEmpty {
        var carried: [PaneID: Data] = [:]
        for (slot, pane) in outcome.panes {
          if let bytes = outputs[slot] { carried[pane] = bytes }
        }
        carry[target] = carried
      }
      delete(id)
      return (target, outcome)
    } catch let error as MuxError where error.code == .connectionLost {
      // Uncertain: discovery settles it from inventory (§12.2.7, step 5).
      throw error
    } catch is CancellationError { throw CancellationError() } catch {
      persist(id) { $0.reopeningAs = nil }
      throw error
    }
  }

  // MARK: Policy and deletion

  package func setPolicy(
    _ value: SavedLayoutPolicy,
    expectedRevision: UInt64
  ) throws -> SavedLayoutPolicy {
    guard value.isValid else {
      throw MuxError(.invalidRequest, "invalid saved layout policy")
    }
    guard !policyReadable || expectedRevision == policy.revision else {
      throw MuxError(.staleRevision, "saved layout policy changed")
    }
    var next = value
    next.revision = max(policy.revision, expectedRevision) + 1
    let wasSaving = policy.saveLayout
    if policy.saveOutput, !next.saveOutput, next.saveLayout, key != nil {
      // Allow the rewrite, then publish the new policy.
      policy.saveOutput = false
      try dropOutputAndRotateKey()
    }
    if !next.saveLayout {
      // Records and key go before the change is acknowledged.
      try files.removeEverything()
      try keys.delete()
      records = [:]
      newer = []
      unreadable = []
      key = nil
      for id in Array(live.keys) { live[id]?.pending = false }
    }
    try files.writePolicy(next)
    policy = next
    policyReadable = true
    if next.saveLayout, !wasSaving || store == .keyLost {
      try? files.prepare()
      store = .available
      loadKey()
      loadRecords()
      for id in Array(live.keys) where live[id]?.content != nil {
        live[id]?.pending = true
      }
      pump()
    }
    return next
  }

  /// Nil deletes every record and the key.
  package func deleteSaved(_ id: WorkspaceID?) throws {
    guard policyReadable else {
      throw MuxError(.unauthorized, "saved layout policy is unreadable")
    }
    if let id {
      delete(id)
      return
    }
    try files.removeEverything()
    try keys.delete()
    records = [:]
    newer = []
    unreadable = []
    key = nil
    try? files.prepare()
    if policy.saveLayout { loadKey() }
    for id in Array(live.keys) where live[id]?.content != nil {
      live[id]?.pending = true
    }
    pump()
  }
}
