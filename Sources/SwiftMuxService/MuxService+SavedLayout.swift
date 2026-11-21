import Foundation
import SwiftMuxProtocol
import SwiftMuxXPC

// Saved layouts, worker side (spec.durability.md §12.2.3, §12.2.6, §12.2.7).
// The worker never stores a record; it reports what one needs and builds a
// reopened workspace with fresh processes.

/// A saved-output snapshot held for paging; released after its last page,
/// on a new snapshot, or after 10 idle seconds.
struct SavedOutputExport: Sendable {
  var pane: PaneID
  var revision: UInt64
  var bytes: Data
  var touched: ContinuousClock.Instant
}

/// Launches of one template, settled on the service queue.
struct TemplateCreation {
  var started: [Int: PaneID] = [:]
  var failed: [Int] = []
  var error: MuxError?
  var remaining: Int
}

extension MuxService {
  /// The scoped workspace, when `client` is the current local gateway.
  func gatewayGraphWorkspace(_ client: Client) -> WorkspaceID? {
    guard configuration.requiresGatewayBinding,
      let workspace = configuration.workerWorkspace, !client.remote,
      case let .xpc(channel) = client.transport,
      gatewayPeerPID == channel.peerPID
    else { return nil }
    return workspace
  }

  /// Reading clears the accumulated causes, so each graph change is
  /// attributed once.
  func takeSavedLayoutState(_ id: WorkspaceID) -> SavedLayoutState {
    let ws = workspaces.first { $0.id == id }
    let metadata =
      ws?.allPanes
      .compactMap { pane -> SavedPaneMetadata? in
        guard let record = panes[pane] else { return nil }
        return SavedPaneMetadata(
          pane: pane,
          launch: record.launch,
          localDirectory: record.localDirectory,
          directoryFallback: record.directoryFallback
        )
      } ?? []
    let state = SavedLayoutState(
      graph: ws.map(snapshot),
      panes: metadata,
      outputOptOut: ws?.outputOptOut ?? false,
      causes: savedLayoutCauses,
      end: ws == nil ? savedLayoutEnd : nil
    )
    savedLayoutCauses = []
    return state
  }

  func exportSavedOutput(
    pane: PaneID,
    ifChangedSince revision: UInt64?,
    offset: Int,
    reply: @escaping Reply
  ) {
    guard !quiescing else {
      return reply(.failure(MuxError(.quiescing, "workspace is frozen")))
    }
    guard let record = panes[pane], !record.detachedFromLayout,
      locate(pane: pane) != nil
    else { return reply(.failure(MuxError(.notFound, "pane"))) }
    @Sendable
    func page(_ export: SavedOutputExport, from offset: Int) -> MuxReply {
      let end = min(export.bytes.count, offset + SavedOutputPage.maxBytes)
      return .savedOutputPage(
        SavedOutputPage(
          revision: export.revision,
          modified: true,
          total: export.bytes.count,
          offset: offset,
          bytes: export.bytes.subdata(
            in: export.bytes.startIndex + offset ..< export.bytes.startIndex
              + end
          )
        )
      )
    }
    if offset > 0 {
      guard var export = savedOutputExport, export.pane == pane,
        offset < export.bytes.count
      else {
        return reply(
          .failure(MuxError(.staleRevision, "saved output snapshot is gone"))
        )
      }
      export.touched = .now
      let value = page(export, from: offset)
      if offset + SavedOutputPage.maxBytes >= export.bytes.count {
        savedOutputExport = nil
      } else {
        savedOutputExport = export
      }
      return reply(.success(value))
    }
    record.runtime.exportSavedOutput(ifChangedSince: revision) {
      [weak self] result in
      self?
        .onQueue { service in
          switch result {
          case let .failure(error): reply(.failure(error))
          case let .success((current, nil)):
            reply(
              .success(
                .savedOutputPage(
                  SavedOutputPage(
                    revision: current,
                    modified: false,
                    total: 0,
                    offset: 0,
                    bytes: Data()
                  )
                )
              )
            )
          case let .success((current, output?)):
            do {
              let export = SavedOutputExport(
                pane: pane,
                revision: current,
                bytes: try output.encoded(),
                touched: .now
              )
              service.savedOutputExport =
                export.bytes.count > SavedOutputPage.maxBytes ? export : nil
              reply(.success(page(export, from: 0)))
              service.expireSavedOutputExport(after: .seconds(10))
            } catch {
              reply(.failure(error as? MuxError ?? MuxError(.resourceLimit)))
            }
          }
        }
    }
  }

  private func expireSavedOutputExport(after delay: Duration) {
    Task { [weak self] in
      try? await Task.sleep(for: delay)
      await self?.dropIdleSavedOutputExport(idle: delay)
    }
  }

  private func dropIdleSavedOutputExport(idle: Duration) {
    if let export = savedOutputExport, export.touched + idle <= .now {
      savedOutputExport = nil
    }
  }

  /// Called when the workspace leaves the graph. The first reason wins.
  func recordSavedLayoutEnd(_ id: WorkspaceID) {
    guard configuration.workerWorkspace == id, savedLayoutEnd == nil else {
      return
    }
    savedLayoutCauses.insert(savedLayoutCause ?? .command)
    if let pendingEndDisposition {
      savedLayoutEnd = .ended(pendingEndDisposition)
    } else {
      savedLayoutEnd = savedLayoutCause == .exit ? .exited : .ended(.ended)
    }
  }

  /// Builds every tab and split, then publishes once. A pane that fails to
  /// start leaves its split; creation fails only if every pane fails.
  func newWorkspace(from template: WorkspaceTemplate, reply: @escaping Reply) {
    do throws(MuxError) {
      try template.validate(maxPanes: limits.maxPanes)
    } catch { return reply(.failure(error)) }
    if let name = template.name, !validName(name) {
      return reply(.failure(invalidName))
    }
    if let name = template.name, workspaces.contains(where: { $0.name == name })
    {
      return reply(
        .failure(MuxError(.invalidRequest, "workspace \"\(name)\" exists"))
      )
    }
    guard configuration.workerWorkspace != nil, !workerWorkspaceClaimed else {
      return reply(
        .failure(MuxError(.invalidRequest, "worker workspace already claimed"))
      )
    }
    workerWorkspaceClaimed = true
    let wsID = configuration.workerWorkspace!
    let creation = UUID()
    templateCreations[creation] = TemplateCreation(
      remaining: template.panes.count
    )
    for (slot, launch) in template.panes.enumerated() {
      spawnPane(
        workspace: wsID,
        columns: template.columns,
        rows: template.rows,
        launch: launch,
        defersPlacement: true
      ) { service, result in
        guard var progress = service.templateCreations[creation] else { return }
        switch result {
        case let .success(pane): progress.started[slot] = pane
        case let .failure(error):
          progress.failed.append(slot)
          if progress.error == nil { progress.error = error }
        }
        progress.remaining -= 1
        guard progress.remaining == 0 else {
          service.templateCreations[creation] = progress
          return
        }
        service.templateCreations.removeValue(forKey: creation)
        service.finishTemplate(
          template,
          workspace: wsID,
          started: progress.started,
          failed: progress.failed,
          error: progress.error,
          reply: reply
        )
      }
    }
  }

  private func finishTemplate(
    _ template: WorkspaceTemplate,
    workspace wsID: WorkspaceID,
    started launched: [Int: PaneID],
    failed launchFailures: [Int],
    error: MuxError?,
    reply: @escaping Reply
  ) {
    // A pane that already exited (its record retired) or was cancelled by an
    // update barrier counts as failed; it never joins the graph.
    var started: [Int: PaneID] = [:]
    var failed = launchFailures
    for (slot, pane) in launched {
      if let record = panes[pane], !record.detachedFromLayout,
        record.exitStatus == nil
      {
        started[slot] = pane
      } else {
        failed.append(slot)
        if let record = panes[pane], !record.detachedFromLayout {
          panes[pane]?.detachedFromLayout = true
          if record.exitStatus != nil {
            retirePaneRecord(pane)
          } else {
            record.runtime.terminate()
          }
        }
      }
    }
    guard !started.isEmpty, !quiescing else {
      for pane in started.values { endPane(pane) }
      if error?.code != .connectionLost { workerWorkspaceClaimed = false }
      return reply(
        .failure(
          quiescing
            ? MuxError(.quiescing, "service is preparing to update")
            : error ?? MuxError(.launchFailed, "no pane started")
        )
      )
    }
    var tabs: [Tab] = []
    var activeTab: TabID?
    for (index, tab) in template.tabs.enumerated() {
      guard let layout = Self.layout(tab.layout, started: started) else {
        continue
      }
      let panesInTab = layout.panes
      let active = started[tab.activeSlot]
        .flatMap { panesInTab.contains($0) ? $0 : nil }
      var value = Tab(
        name: validName(tab.name) ? tab.name : "\(tabs.count + 1)",
        layout: layout,
        activePane: active ?? panesInTab[0]
      )
      if let zoomed = tab.zoomedSlot.flatMap({ started[$0] }),
        panesInTab.contains(zoomed), panesInTab.count > 1
      {
        value.zoomedPane = zoomed
      }
      if index == template.activeTab { activeTab = value.id }
      tabs.append(value)
    }
    var name = template.name ?? "\(workspaces.count)"
    var n = workspaces.count
    while workspaces.contains(where: { $0.name == name }) {
      n += 1
      name = "\(n)"
    }
    var ws = Workspace(
      id: wsID,
      name: name,
      tabs: tabs,
      activeTab: activeTab ?? tabs[0].id,
      remainOnExit: template.remainOnExit,
      launch: template.launch
    )
    ws.outputOptOut = template.outputOptOut
    workspaces.append(ws)
    savedLayoutCauses.insert(.command)
    publishWorkspaces()
    let fallbacks = started.compactMap { slot, pane in
      panes[pane]?.directoryFallback == true ? slot : nil
    }
    reply(
      .success(
        .createdFromTemplate(
          snapshot(ws),
          WorkspaceTemplateOutcome(
            panes: started,
            failedSlots: failed.sorted(),
            directoryFallbackSlots: fallbacks.sorted()
          )
        )
      )
    )
  }

  /// The template tree with failed slots removed; nil if none started.
  static func layout(
    _ node: WorkspaceTemplateNode,
    started: [Int: PaneID]
  ) -> LayoutNode? {
    switch node {
    case let .pane(slot): return started[slot].map(LayoutNode.pane)
    case let .split(axis, ratio, first, second):
      let a = layout(first, started: started)
      let b = layout(second, started: started)
      switch (a, b) {
      case let (a?, b?):
        return .split(axis: axis, ratio: ratio, first: a, second: b)
      case let (a?, nil): return a
      case let (nil, b?): return b
      case (nil, nil): return nil
      }
    }
  }
}
