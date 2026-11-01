import Dispatch
import Foundation
import SwiftMuxProtocol

extension MuxService {
  // MARK: Pane creation

  var paneCount: Int { panes.count + pendingLaunches }

  /// Logical history committed to live and starting panes.
  var allocatedHistoryBytes: Int {
    panes.values.reduce(pendingHistoryBytes) {
      let (sum, overflow) = $0.addingReportingOverflow($1.runtime.historyBytes)
      return overflow ? Int.max : sum
    }
  }

  /// Up to the per-pane cap from the shared budget, keeping the minimum
  /// back for every pane that may still be created. The sum of shares
  /// never exceeds `totalHistoryBytes`; ended panes return theirs. Refuse
  /// creation when the minimum reservations cannot fit the remaining pool.
  private func nextHistoryShare() throws(MuxError) -> Int {
    guard limits.historyBytesPerPane >= 0, limits.totalHistoryBytes >= 0,
      limits.minHistoryBytesPerPane >= 0
    else { throw MuxError(.invalidRequest, "invalid history budgets") }
    let allocated = allocatedHistoryBytes
    guard allocated <= limits.totalHistoryBytes else {
      throw MuxError(.resourceLimit, "history pool exhausted")
    }
    let remaining = limits.totalHistoryBytes - allocated
    let minimum = min(limits.minHistoryBytesPerPane, limits.historyBytesPerPane)
    // Pane admission above the call guarantees at least this one slot.
    let slots = limits.maxPanes - paneCount
    let (reserved, overflow) = slots.multipliedReportingOverflow(by: minimum)
    guard !overflow, reserved <= remaining else {
      throw MuxError(
        .resourceLimit,
        "history minimum reservations exceed the pool"
      )
    }
    let futureReserve = reserved - minimum
    return min(limits.historyBytesPerPane, remaining - futureReserve)
  }

  private func spawnPane(
    workspace: WorkspaceID,
    id: PaneID = PaneID(),
    columns: Int,
    rows: Int,
    launch: LaunchSpec,
    completion:
      @escaping @Sendable (isolated MuxService, Result<PaneID, MuxError>) ->
      Void
  ) {
    guard !quiescing else {
      return completion(
        self,
        .failure(MuxError(.quiescing, "service is preparing to update"))
      )
    }
    guard paneCount < limits.maxPanes else {
      return completion(
        self,
        .failure(
          MuxError(.resourceLimit, "pane limit \(limits.maxPanes) reached")
        )
      )
    }
    let columns = min(max(columns, limits.minPaneColumns), limits.maxColumns)
    let rows = min(max(rows, limits.minPaneRows), limits.maxRows)
    let historyBytes: Int
    do throws(MuxError) { historyBytes = try nextHistoryShare() } catch {
      return completion(self, .failure(error))
    }
    prepareAutomation(initialPane: id, environment: launch.environment)
    automation.starting.insert(id)
    let runtime = PaneRuntime(
      id: id,
      workspace: workspace,
      columns: columns,
      rows: rows,
      historyBytes: historyBytes,
      innerTerm: configuration.innerTerm,
      limits: limits,
      scrollbackCompression: configuration.scrollbackCompression,
      javaScriptRuntime: automation.runtime ?? configuration.javaScriptRuntime,
      observingIO: configuration.observePaneIO
    )
    if let theme { runtime.setTheme(theme) }
    runtime.onChange = { [weak self] in self?.onQueue { $0.paneChanged(id) } }
    runtime.onEvent = { [weak self] event in
      self?.onQueue { $0.paneEvent(id, event) }
    }
    pendingLaunches += 1
    pendingHistoryBytes += historyBytes
    let launcher = self.launcher
    let beforeLaunch = configuration.beforeLaunch
    let epoch = endAllEpoch
    runtime.queue.async { [weak self] in
      beforeLaunch?()
      let result: Result<Void, MuxError>
      do throws(MuxError) {
        try runtime.launch(launch, launcher: launcher)
        result = .success(())
      } catch { result = .failure(error) }
      self?
        .onQueue { service in
          service.pendingLaunches -= 1
          service.pendingHistoryBytes -= historyBytes
          switch result {
          case .success:
            service.panes[id] = PaneRecord(
              runtime: runtime,
              workspace: workspace,
              columns: columns,
              rows: rows,
              workingDirectory: launch.workingDirectory
            )
            // The update barrier (or end-all) arrived while this pane was
            // starting: it never joins the frozen graph.
            if service.quiescing || service.endAllEpoch != epoch {
              service.panes[id]?.detachedFromLayout = true
              runtime.terminate()
              service.automationPaneStarted(id, succeeded: false)
              return completion(
                service,
                .failure(
                  MuxError(.quiescing, "service is preparing to update", )
                )
              )
            }
            completion(service, .success(id))
            service.automationPaneStarted(id, succeeded: true)
            // Output read before the record existed posted a change that
            // found no pane; take it now, which also re-arms `onChange`.
            service.paneChanged(id, reportActivity: false)
            // Creation generation: the target may have ended meanwhile.
            if service.locate(pane: id) == nil {
              service.panes[id]?.detachedFromLayout = true
              runtime.terminate()
            }
          case let .failure(error):
            service.automationPaneStarted(id, succeeded: false)
            completion(service, .failure(error))
            service.checkIdle()
          }
        }
    }
  }

  func newWorkspace(_ request: NewWorkspaceRequest, reply: @escaping Reply) {
    if let name = request.name, !validName(name) {
      return reply(.failure(invalidName))
    }
    if let name = request.name, workspaces.contains(where: { $0.name == name })
    {
      return reply(
        .failure(MuxError(.invalidRequest, "workspace \"\(name)\" exists"))
      )
    }
    let wsID = WorkspaceID()
    spawnPane(
      workspace: wsID,
      columns: request.columns,
      rows: request.rows,
      launch: request.launch
    ) { service, result in
      switch result {
      case let .failure(error): reply(.failure(error))
      case let .success(pane):
        let tab = Tab(name: "1", layout: .pane(pane), activePane: pane)
        var name = request.name ?? "\(service.workspaces.count)"
        var n = service.workspaces.count
        while service.workspaces.contains(where: { $0.name == name }) {
          n += 1
          name = "\(n)"
        }
        let ws = Workspace(
          id: wsID,
          name: name,
          tabs: [tab],
          activeTab: tab.id,
          remainOnExit: request.remainOnExit,
          launch: request.launch
        )
        service.workspaces.append(ws)
        reply(.success(.created(service.snapshot(ws))))
      }
    }
  }

  func newTab(
    name: String?,
    launch: LaunchSpec?,
    in leased: WorkspaceID,
    reply: @escaping Reply
  ) {
    guard let w = workspaces.firstIndex(where: { $0.id == leased }) else {
      return reply(.failure(MuxError(.notAttached)))
    }
    let ws = workspaces[w]
    let reference = ws.tabs.first { $0.id == ws.activeTab }
      .flatMap { panes[$0.activePane] }
    spawnPane(
      workspace: ws.id,
      columns: reference?.columns ?? 80,
      rows: reference?.rows ?? 24,
      launch: launch ?? ws.launch
    ) { service, result in
      switch result {
      case let .failure(error): reply(.failure(error))
      case let .success(pane):
        guard let w = service.workspaces.firstIndex(where: { $0.id == ws.id })
        else { return reply(.failure(MuxError(.notFound, "workspace ended"))) }
        let tab = Tab(
          name: name ?? "\(service.workspaces[w].tabs.count + 1)",
          layout: .pane(pane),
          activePane: pane
        )
        service.workspaces[w].tabs.append(tab)
        service.workspaces[w].activeTab = tab.id
        service.commitLayout(ws.id)
        reply(.success(.layout(service.snapshot(service.workspaces[w]))))
      }
    }
  }

  func split(
    _ pane: PaneID,
    axis: SplitAxis,
    launch: LaunchSpec?,
    in leased: WorkspaceID,
    newPaneID: PaneID = PaneID(),
    reply: @escaping Reply
  ) {
    guard let (w, _) = locate(pane: pane, in: leased), let record = panes[pane]
    else { return reply(.failure(MuxError(.notFound, "pane"))) }
    let ws = workspaces[w]
    let columns =
      axis == .leftRight ? max(1, (record.columns - 1) / 2) : record.columns
    let rows = axis == .topBottom ? max(1, (record.rows - 1) / 2) : record.rows
    guard columns >= limits.minPaneColumns, rows >= limits.minPaneRows else {
      return reply(
        .failure(MuxError(.resourceLimit, "pane too small to split"))
      )
    }
    spawnPane(
      workspace: ws.id,
      id: newPaneID,
      columns: columns,
      rows: rows,
      launch: launch
        ?? LaunchSpec(
          command: ws.launch.command == nil ? nil : nil,
          workingDirectory: record.workingDirectory
            ?? ws.launch.workingDirectory,
          environment: ws.launch.environment
        )
    ) { service, result in
      switch result {
      case let .failure(error): reply(.failure(error))
      case let .success(newPane):
        guard let (w, t) = service.locate(pane: pane) else {
          return reply(.failure(MuxError(.notFound, "pane ended")))
        }
        service.workspaces[w].tabs[t].layout = service.workspaces[w].tabs[t]
          .layout.splitting(pane, axis: axis, newPane: newPane)
        service.workspaces[w].tabs[t].activePane = newPane
        service.workspaces[w].tabs[t].zoomedPane = nil
        service.commitLayout(ws.id)
        reply(.success(.layout(service.snapshot(service.workspaces[w]))))
      }
    }
  }

  // MARK: Pane removal

  /// Removes `pane` from its layout and terminates only its processes.
  func endPane(_ pane: PaneID) {
    removeFromLayout(pane)
    panes[pane]?.detachedFromLayout = true
    if let record = panes[pane] {
      if record.exitStatus != nil {
        panes.removeValue(forKey: pane)
      } else {
        record.runtime.terminate()
      }
    }
    checkIdle()
  }

  func endWorkspace(_ id: WorkspaceID) {
    guard let ws = workspaces.first(where: { $0.id == id }) else { return }
    // Detach first: the teardown's layout commits are not for anyone.
    releaseLease(id, notify: true, reason: "workspace ended")
    releaseViewers(in: id, reason: "workspace ended")
    for pane in ws.allPanes { endPane(pane) }
    // endPane removes the workspace with its last pane.
    workspaces.removeAll { $0.id == id }
    publishWorkspaces()
  }

  func removeFromLayout(_ pane: PaneID) {
    guard let (w, t) = locate(pane: pane) else { return }
    let wsID = workspaces[w].id
    leases[wsID]?.subscriptions.removeAll { $0 == pane }
    leases[wsID]?.reportedActivity.remove(pane)
    leases[wsID]?.readiness.forget(pane)
    if let slot = leases[wsID]?.frames.removeValue(forKey: pane) {
      releaseBudget(slot)
    }
    dropPaneFromViewers(pane, workspace: wsID)
    if let pasteIDs = leases[wsID]?.pastes.filter({ $0.value.pane == pane })
      .map(\.key)
    {
      for id in pasteIDs { leases[wsID]?.pastes.removeValue(forKey: id) }
    }
    guard let layout = workspaces[w].tabs[t].layout.removing(pane) else {
      // Last pane of the tab.
      let tabID = workspaces[w].tabs[t].id
      automation.presentation.removeValue(forKey: "icon:" + tabID.description)
      workspaces[w].tabs.remove(at: t)
      if workspaces[w].tabs.isEmpty {
        workspaces.remove(at: w)
        releaseLease(wsID, notify: true, reason: "workspace ended")
        releaseViewers(in: wsID, reason: "workspace ended")
        publishWorkspaces()
        return
      }
      if workspaces[w].activeTab == tabID {
        workspaces[w].activeTab =
          workspaces[w].tabs[min(t, workspaces[w].tabs.count - 1)].id
      }
      commitLayout(wsID)
      return
    }
    workspaces[w].tabs[t].layout = layout
    if workspaces[w].tabs[t].activePane == pane {
      workspaces[w].tabs[t].activePane = layout.panes.first!
    }
    if workspaces[w].tabs[t].zoomedPane == pane {
      workspaces[w].tabs[t].zoomedPane = nil
    }
    commitLayout(wsID)
  }

  // MARK: Geometry

  func setGeometry(
    _ batch: GeometryBatch,
    workspace wsID: WorkspaceID
  ) -> MuxError? {
    guard var current = leases[wsID],
      let ws = workspaces.first(where: { $0.id == wsID })
    else { return MuxError(.notAttached) }
    guard batch.layoutRevision == ws.layoutRevision else {
      return MuxError(
        .staleGeometry,
        "layout revision \(batch.layoutRevision) is not current (\(ws.layoutRevision))"
      )
    }
    guard batch.generation > current.geometryGeneration else {
      return MuxError(.staleGeometry, "geometry generation did not advance")
    }
    guard batch.entries.count <= limits.maxGeometryBatch else {
      return MuxError(.resourceLimit, "geometry batch size")
    }
    let members = Set(ws.allPanes)
    var entries: [PaneID: GeometryBatch.Entry] = [:]
    for e in batch.entries {
      guard members.contains(e.pane) else {
        return MuxError(
          .staleGeometry,
          "pane \(e.pane.short) is not in this workspace"
        )
      }
      guard limits.cellCount(columns: e.columns, rows: e.rows) != nil,
        e.columns >= limits.minPaneColumns, e.rows >= limits.minPaneRows
      else {
        return MuxError(.invalidRequest, "pane size \(e.columns)x\(e.rows)")
      }
      entries[e.pane] = e
    }
    guard entries.count <= limits.maxPanes else {
      return MuxError(.resourceLimit, "geometry pane count")
    }
    current.geometryGeneration = batch.generation
    var resized: [PaneID: UInt64] = [:]
    for e in entries.values {
      guard let record = panes[e.pane] else { continue }
      // Every entry advances the pane's geometry generation (frames show
      // the batch was applied); only a changed size resets Ready.
      let changed = record.columns != e.columns || record.rows != e.rows
      panes[e.pane]?.columns = e.columns
      panes[e.pane]?.rows = e.rows
      let generation = record.runtime.resize(columns: e.columns, rows: e.rows)
      if changed { resized[e.pane] = generation }
    }
    // Frames at an older size, acknowledged or on the way, no longer count
    // for Ready, and a capture at that size that fails is not reported;
    // every resize produces a new frame. An unchanged size (a resent
    // batch) keeps them.
    for (pane, generation) in resized {
      current.readiness.resized(pane, to: generation)
      current.frames[pane]?.supersededThrough = nextCapture
    }
    leases[wsID] = current
    for index in (viewers[wsID] ?? []).indices {
      for (pane, generation) in resized {
        viewers[wsID]![index].readiness.resized(pane, to: generation)
        viewers[wsID]![index].frames[pane]?.supersededThrough = nextCapture
      }
    }
    return nil
  }
}
