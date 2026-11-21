import Foundation
import SwiftMuxProtocol
import SwiftMuxXPC

// Saved layouts, worker side (spec.durability.md §12.2.3, §12.2.6, §12.2.7).
// The worker never stores a record; it reports what one needs and builds a
// reopened workspace with fresh processes.

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
