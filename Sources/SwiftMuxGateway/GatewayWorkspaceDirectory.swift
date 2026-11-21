import Foundation
import SwiftMuxGuardian
import SwiftMuxProtocol

/// Disposable gateway metadata. Guardian inventory owns membership; workers own
/// summaries. A failed worker remains addressable by authority for explicit End.
/// Available records require both subscriptions; they are not terminal-frame readiness.
package actor GatewayWorkspaceDirectory {
  package enum State: Sendable, Equatable {
    case starting
    case discovering
    case empty
    case available(WorkspaceSummary)
    case unavailable(MuxError)
  }

  package struct Record: Sendable {
    package let inventory: GuardianWorkspaceInventory
    package let state: State
    package let graph: WorkspaceSnapshot?
    package let lastKnownSummary: WorkspaceSummary?
  }

  private struct Entry {
    var inventory: GuardianWorkspaceInventory
    var state: State
    var summary: WorkspaceSummary?
    var graph: WorkspaceSnapshot?
    var lastKnownSummary: WorkspaceSummary?
    let token = UUID()
    var task: Task<Void, Never>?
  }

  private let supervisor: GatewaySupervisor
  private let peerRequirement: String?
  private let capacity: Int
  /// Saved layouts (spec.durability.md §12.2): each consumed graph's saved
  /// view, and observation loss. Never on the discovery critical path.
  private var onSavedLayout:
    (@Sendable (GuardianAuthority, SavedLayoutState) async -> Void)?
  private var onObservationLost: (@Sendable (WorkspaceID) async -> Void)?
  private var onOutputSource:
    (@Sendable (GuardianAuthority, SavedOutputSource?) async -> Void)?
  private var entries: [WorkspaceID: Entry] = [:]
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var opening = 0
  private var hasInventory = false
  private var refreshing = false
  private var monitoring = false
  private var closed = false
  package private(set) var failure: MuxError?
  package var activeObservationCount: Int { tasks.count }

  package init(
    supervisor: GatewaySupervisor,
    peerRequirement: String?,
    capacity: Int = MuxLimits.standard.maxPanes
  ) throws {
    guard capacity > 0, capacity <= 4096 else {
      throw MuxError(.invalidRequest, "invalid gateway directory capacity")
    }
    self.supervisor = supervisor
    self.peerRequirement = peerRequirement
    self.capacity = capacity
  }

  package func setSavedLayoutHooks(
    state:
      @escaping @Sendable (GuardianAuthority, SavedLayoutState) async -> Void,
    lost: @escaping @Sendable (WorkspaceID) async -> Void,
    output: (@Sendable (GuardianAuthority, SavedOutputSource?) async -> Void)? =
      nil
  ) {
    onSavedLayout = state
    onObservationLost = lost
    onOutputSource = output
  }

  package var records: [Record] {
    entries.values
      .map {
        Record(
          inventory: $0.inventory,
          state: $0.state,
          graph: $0.graph,
          lastKnownSummary: $0.lastKnownSummary
        )
      }
      .sorted {
        $0.inventory.authority.workspace.description
          < $1.inventory.authority.workspace.description
      }
  }

  /// Identity lookup includes unavailable records so explicit End remains possible.
  /// Cached names are presentation metadata, never evidence of worker readiness.
  package func resolve(_ selector: WorkspaceSelector) throws -> Record {
    guard !closed else {
      throw MuxError(.connectionLost, "gateway directory closed")
    }
    if let failure { throw failure }
    guard hasInventory else {
      throw MuxError(.quiescing, "initial inventory is pending")
    }
    return try Self.select(selector, from: records)
  }

  /// Selects a native route without taking a lease or granting writer authority.
  /// The listener must revalidate this authority with the guardian on admission.
  package func nativeAuthority(
    for selector: WorkspaceSelector
  ) throws -> GuardianAuthority {
    let record = try resolve(selector)
    switch record.state {
    case .available: return record.inventory.authority
    case let .unavailable(error): throw error
    case .empty: throw MuxError(.notFound, "workspace has no published graph")
    case .starting, .discovering:
      throw MuxError(.quiescing, "workspace discovery is incomplete")
    }
  }

  deinit { for task in tasks.values { task.cancel() } }

  /// Runs for the gateway lifetime. The caller owns and cancels this task.
  /// Polls never overlap or accumulate after sleep; no mutation is retried.
  /// Exiting drains observations without ending any guardian-owned process.
  package func monitor(
    interval: Duration = .seconds(1),
    afterRefresh: @Sendable () async throws -> Void = {}
  ) async throws {
    guard interval > .zero, interval <= .seconds(60) else {
      throw MuxError(.invalidRequest, "invalid directory polling interval")
    }
    guard !monitoring else {
      throw MuxError(.quiescing, "directory monitor already running")
    }
    guard !closed else {
      throw MuxError(.connectionLost, "gateway directory closed")
    }
    monitoring = true
    defer { monitoring = false }
    do {
      while !closed {
        try Task.checkCancellation()
        // An explicit refresh can already own the single inventory request.
        if !refreshing {
          try await refresh()
          try await afterRefresh()
        }
        try await Task.sleep(for: interval)
      }
    } catch {
      await close()
      throw error
    }
    await close()
  }

  /// Refresh membership explicitly; no automatic creation or uncertain retries.
  /// Observations subsequently update summaries independently of this request.
  package func refresh() async throws {
    guard !closed else {
      throw MuxError(.connectionLost, "gateway directory closed")
    }
    guard !refreshing else {
      throw MuxError(.quiescing, "discovery already in progress")
    }
    refreshing = true
    defer { refreshing = false }
    let inventory: [GuardianWorkspaceInventory]
    do { inventory = try await supervisor.inventory() } catch {
      let error =
        (error as? MuxError)
        ?? MuxError(.connectionLost, "guardian discovery failed")
      // Cancelling a read does not prove that the guardian was lost.
      if Task.isCancelled { throw CancellationError() }
      invalidate(error)
      throw error
    }
    try Task.checkCancellation()
    guard !closed else {
      throw MuxError(.connectionLost, "gateway directory closed")
    }
    guard inventory.count <= capacity else {
      let error = MuxError(
        .resourceLimit,
        "guardian inventory exceeds directory capacity"
      )
      invalidate(error)
      throw error
    }
    failure = nil
    hasInventory = true
    let present = Set(inventory.map { $0.authority.workspace })
    for id in entries.keys.filter({ !present.contains($0) }) {
      entries.removeValue(forKey: id)?.task?.cancel()
    }
    for item in inventory {
      let id = item.authority.workspace
      if var entry = entries[id], entry.inventory.authority == item.authority,
        item.available, entry.task != nil
      {
        entry.inventory = item
        entries[id] = entry
        continue
      }
      let previous = entries.removeValue(forKey: id)
      previous?.task?.cancel()
      let state: State
      if item.starting {
        state = .starting
      } else if item.available {
        state = .discovering
      } else {
        state = .unavailable(
          item.launchError
            ?? MuxError(
              .notAttached,
              "terminal worker unavailable; processes retained"
            )
        )
      }
      entries[id] = Entry(
        inventory: item,
        state: state,
        lastKnownSummary: previous?.inventory.authority == item.authority
          ? previous?.lastKnownSummary : nil
      )
    }
    pump()
  }

  package func close() async {
    closed = true
    let tasks = Array(tasks.values)
    invalidate(failure ?? MuxError(.connectionLost, "gateway directory closed"))
    for task in tasks { await task.value }
  }

  private func invalidate(_ error: MuxError) {
    failure = error
    for task in tasks.values { task.cancel() }
    for id in Array(entries.keys) {
      entries[id]?.task?.cancel()
      // Replace the token so late callbacks cannot revive stale readiness.
      if let inventory = entries[id]?.inventory {
        entries[id] = Entry(
          inventory: inventory,
          state: .unavailable(error),
          lastKnownSummary: entries[id]?.lastKnownSummary
        )
      }
    }
  }

  private func pump() {
    guard !closed, failure == nil else { return }
    // A stalled handshake consumes one opening slot, not every workspace's progress.
    for id in Array(entries.keys)
    where opening < 4 && tasks.count < capacity + 4 {
      guard let entry = entries[id], entry.task == nil,
        entry.state == .discovering
      else { continue }
      opening += 1
      let authority = entry.inventory.authority
      let token = entry.token
      let supervisor = supervisor
      let requirement = peerRequirement
      entries[id]?.task = Task { [weak self] in
        let observation: GatewayWorkspaceObservation
        do {
          observation = try await GatewayWorkspaceObservation.open(
            authority: authority,
            supervisor: supervisor,
            peerRequirement: requirement
          )
        } catch {
          await self?.openingFailed(id, token: token, error: error)
          await self?.taskFinished(token)
          return
        }
        let graphObservation: GatewayGraphObservation
        do {
          graphObservation = try await GatewayGraphObservation.open(
            authority: authority,
            supervisor: supervisor,
            peerRequirement: requirement
          )
        } catch {
          await observation.close()
          await self?.openingFailed(id, token: token, error: error)
          await self?.taskFinished(token)
          return
        }
        let summary = await observation.summary
        let graph = await graphObservation.graph
        if let state = try? await graphObservation.savedLayoutState() {
          await self?.savedLayout(id, token: token, state: state)
        }
        await self?
          .outputSource(
            authority,
            source: { pane, revision in
              try await graphObservation.savedOutput(
                pane: pane,
                ifChangedSince: revision
              )
            }
          )
        guard
          await self?.opened(id, token: token, summary: summary, graph: graph)
            == true
        else {
          await observation.close()
          await graphObservation.close()
          await self?.taskFinished(token)
          return
        }
        do {
          try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
              while !Task.isCancelled {
                let summary = try await observation.next()
                guard
                  await self?.updated(id, token: token, summary: summary)
                    == true
                else { return }
              }
            }
            group.addTask { [weak self] in
              while !Task.isCancelled {
                let graph = try await graphObservation.next()
                guard
                  await self?.updatedGraph(id, token: token, graph: graph)
                    == true
                else { return }
                if let state = try await graphObservation.savedLayoutState() {
                  await self?.savedLayout(id, token: token, state: state)
                }
              }
            }
            defer { group.cancelAll() }
            _ = try await group.next()
          }
        } catch {
          await self?.observationFailed(id, token: token, error: error)
        }
        await self?.outputSource(authority, source: nil)
        await observation.close()
        await graphObservation.close()
        await self?.taskFinished(token)
      }
      tasks[token] = entries[id]?.task
    }
  }

  private func taskFinished(_ token: UUID) {
    tasks.removeValue(forKey: token)
    pump()
  }

  private func opened(
    _ id: WorkspaceID,
    token: UUID,
    summary: WorkspaceSummary?,
    graph: WorkspaceSnapshot?
  ) -> Bool {
    opening -= 1
    if entries[id]?.token == token { entries[id]?.graph = graph }
    let accepted = updated(id, token: token, summary: summary)
    pump()
    return accepted
  }

  private func openingFailed(_ id: WorkspaceID, token: UUID, error: any Error) {
    opening -= 1
    observationFailed(id, token: token, error: error)
    pump()
  }

  private func updated(
    _ id: WorkspaceID,
    token: UUID,
    summary: WorkspaceSummary?
  ) -> Bool {
    guard !closed, entries[id]?.token == token else { return false }
    entries[id]?.summary = summary
    entries[id]?.lastKnownSummary = summary
    reconcileState(id)
    return true
  }

  private func updatedGraph(
    _ id: WorkspaceID,
    token: UUID,
    graph: WorkspaceSnapshot?
  ) -> Bool {
    guard !closed, entries[id]?.token == token else { return false }
    entries[id]?.graph = graph
    reconcileState(id)
    return true
  }

  private func reconcileState(_ id: WorkspaceID) {
    guard let entry = entries[id] else { return }
    if let summary = entry.summary, entry.graph != nil {
      entries[id]?.state = .available(summary)
    } else if entry.summary == nil, entry.graph == nil {
      entries[id]?.state = .empty
    } else {
      // Separate ordered streams may briefly straddle creation or removal.
      entries[id]?.state = .discovering
    }
  }

  private func outputSource(
    _ authority: GuardianAuthority,
    source: SavedOutputSource?
  ) async {
    guard let hook = onOutputSource else { return }
    await hook(authority, source)
  }

  private func savedLayout(
    _ id: WorkspaceID,
    token: UUID,
    state: SavedLayoutState
  ) async {
    guard !closed, let entry = entries[id], entry.token == token,
      let hook = onSavedLayout
    else { return }
    await hook(entry.inventory.authority, state)
  }

  private func observationFailed(
    _ id: WorkspaceID,
    token: UUID,
    error: any Error
  ) {
    guard !closed, entries[id]?.token == token else { return }
    if let lost = onObservationLost { Task { await lost(id) } }
    entries[id]?.task = nil
    entries[id]?.summary = nil
    entries[id]?.graph = nil
    entries[id]?.state = .unavailable(
      (error as? MuxError)
        ?? MuxError(.connectionLost, "workspace observation ended")
    )
  }
}
