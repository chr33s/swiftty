import Foundation
import SwiftMuxProtocol

extension MuxService {
  /// A tab keeps at most this many floating layers.
  static let maxFloatingLayers = 8

  func floatPane(
    _ pane: PaneID,
    bounds: LayerRect,
    in leased: WorkspaceID,
    reply: @escaping Reply
  ) {
    guard bounds.isValid else {
      return reply(.failure(MuxError(.invalidRequest, "layer bounds")))
    }
    guard let (w, t) = locate(pane: pane, in: leased) else {
      return reply(.failure(MuxError(.notFound, "pane")))
    }
    var tab = workspaces[w].tabs[t]
    guard tab.layerIndex(containing: pane) == nil else {
      return reply(
        .failure(MuxError(.invalidRequest, "pane is already floating"))
      )
    }
    guard tab.layers.count < Self.maxFloatingLayers else {
      return reply(.failure(MuxError(.resourceLimit, "floating layers")))
    }
    guard let layout = tab.layout, layout.contains(pane) else {
      return reply(.failure(MuxError(.notFound, "pane")))
    }
    tab.layout = layout.removing(pane)
    tab.layers.append(
      FloatingLayer(layout: .pane(pane), bounds: bounds, focusedPane: pane)
    )
    tab.zoomedPane = nil
    workspaces[w].tabs[t] = tab
    commitLayout(leased)
    reply(.success(.layout(snapshot(workspaces[w]))))
  }

  func newLayer(
    _ tabID: TabID,
    bounds: LayerRect,
    launch: LaunchSpec?,
    in leased: WorkspaceID,
    newPaneID: PaneID = PaneID(),
    reply: @escaping Reply
  ) {
    guard bounds.isValid else {
      return reply(.failure(MuxError(.invalidRequest, "layer bounds")))
    }
    guard let (w, t) = locate(tab: tabID, in: leased) else {
      return reply(.failure(MuxError(.notFound, "tab")))
    }
    let tab = workspaces[w].tabs[t]
    guard tab.layers.count < Self.maxFloatingLayers else {
      return reply(.failure(MuxError(.resourceLimit, "floating layers")))
    }
    let reference = panes[tab.activePane]
    let ws = workspaces[w]
    spawnPane(
      workspace: ws.id,
      id: newPaneID,
      columns: reference?.columns ?? 80,
      rows: reference?.rows ?? 24,
      launch: launch
        ?? LaunchSpec(
          command: nil,
          workingDirectory: reference?.localDirectory
            ?? ws.launch.workingDirectory,
          environment: ws.launch.environment
        )
    ) { service, result in
      switch result {
      case let .failure(error): reply(.failure(error))
      case let .success(pane):
        guard let (w, t) = service.locate(tab: tabID, in: leased),
          service.workspaces[w].tabs[t].layers.count < Self.maxFloatingLayers
        else {
          service.endPane(pane)
          return reply(.failure(MuxError(.notFound, "tab ended")))
        }
        var tab = service.workspaces[w].tabs[t]
        tab.layers.append(
          FloatingLayer(layout: .pane(pane), bounds: bounds, focusedPane: pane)
        )
        tab.focus(pane)
        tab.zoomedPane = nil
        service.workspaces[w].tabs[t] = tab
        service.workspaces[w].activeTab = tab.id
        service.commitLayout(leased)
        reply(.success(.layout(service.snapshot(service.workspaces[w]))))
      }
    }
  }

  func placeLayer(
    _ layer: LayerID,
    bounds: LayerRect,
    in leased: WorkspaceID,
    reply: @escaping Reply
  ) {
    guard bounds.isValid else {
      return reply(.failure(MuxError(.invalidRequest, "layer bounds")))
    }
    guard let (w, t, index) = locate(layer: layer, in: leased) else {
      return reply(.failure(MuxError(.notFound, "layer")))
    }
    guard workspaces[w].tabs[t].layers[index].bounds != bounds else {
      return reply(.success(.layout(snapshot(workspaces[w]))))
    }
    workspaces[w].tabs[t].layers[index].bounds = bounds
    commitLayout(leased)
    reply(.success(.layout(snapshot(workspaces[w]))))
  }

  func orderLayer(
    _ layer: LayerID,
    before: LayerID?,
    in leased: WorkspaceID,
    reply: @escaping Reply
  ) {
    guard let (w, t, index) = locate(layer: layer, in: leased) else {
      return reply(.failure(MuxError(.notFound, "layer")))
    }
    var tab = workspaces[w].tabs[t]
    if let before {
      guard before != layer else {
        return reply(.failure(MuxError(.invalidRequest, "layer order")))
      }
      guard tab.layers.contains(where: { $0.id == before }) else {
        return reply(.failure(MuxError(.notFound, "layer")))
      }
    }
    let moved = tab.layers.remove(at: index)
    let destination: Int
    if let before, let at = tab.layers.firstIndex(where: { $0.id == before }) {
      destination = at
    } else {
      destination = tab.layers.count
    }
    tab.layers.insert(moved, at: destination)
    guard tab.layers != workspaces[w].tabs[t].layers else {
      return reply(.success(.layout(snapshot(workspaces[w]))))
    }
    workspaces[w].tabs[t] = tab
    commitLayout(leased)
    reply(.success(.layout(snapshot(workspaces[w]))))
  }

  func minimizeLayer(
    _ layer: LayerID,
    minimized: Bool,
    in leased: WorkspaceID,
    reply: @escaping Reply
  ) {
    guard let (w, t, index) = locate(layer: layer, in: leased) else {
      return reply(.failure(MuxError(.notFound, "layer")))
    }
    var tab = workspaces[w].tabs[t]
    guard tab.layers[index].minimized != minimized else {
      return reply(.success(.layout(snapshot(workspaces[w]))))
    }
    if minimized {
      guard tab.canMinimize(tab.layers[index]) else {
        return reply(
          .failure(MuxError(.invalidRequest, "a tab keeps a visible pane"))
        )
      }
      let hiding = Set(tab.layers[index].layout.panes)
      tab.layers[index].minimized = true
      if hiding.contains(tab.activePane)
        || tab.zoomedPane.map(hiding.contains) == true
      {
        tab.zoomedPane = nil
        tab.restoreFocus()
      }
    } else {
      tab.layers[index].minimized = false
    }
    workspaces[w].tabs[t] = tab
    commitLayout(leased)
    reply(.success(.layout(snapshot(workspaces[w]))))
  }

  func closeLayer(
    _ layer: LayerID,
    in leased: WorkspaceID,
    reply: @escaping Reply
  ) {
    guard let (w, t, index) = locate(layer: layer, in: leased) else {
      return reply(.failure(MuxError(.notFound, "layer")))
    }
    let wsID = workspaces[w].id
    let panes = workspaces[w].tabs[t].layers[index].layout.panes
    for pane in panes { endPane(pane) }
    if let snap = snapshot(wsID) {
      reply(.success(.layout(snap)))
    } else {
      reply(.success(.ok))
    }
  }

  func dockPane(
    _ pane: PaneID,
    beside: PaneID?,
    axis: SplitAxis,
    in leased: WorkspaceID,
    reply: @escaping Reply
  ) {
    guard let (w, t) = locate(pane: pane, in: leased) else {
      return reply(.failure(MuxError(.notFound, "pane")))
    }
    var tab = workspaces[w].tabs[t]
    guard tab.layerIndex(containing: pane) != nil else {
      return reply(.failure(MuxError(.invalidRequest, "pane is not floating")))
    }
    tab.remove(pane)
    if let beside {
      guard let tiled = tab.layout, tiled.contains(beside), beside != pane
      else { return reply(.failure(MuxError(.notFound, "pane"))) }
      tab.layout = tiled.splitting(beside, axis: axis, newPane: pane)
    } else if let tiled = tab.layout {
      tab.layout = tiled.splitting(tiled.panes[0], axis: axis, newPane: pane)
    } else {
      tab.layout = .pane(pane)
    }
    tab.zoomedPane = nil
    tab.focus(pane)
    workspaces[w].tabs[t] = tab
    commitLayout(leased)
    reply(.success(.layout(snapshot(workspaces[w]))))
  }

  func setLayerRatio(
    _ layer: LayerID,
    path: [Bool],
    ratio: Double,
    in leased: WorkspaceID,
    reply: @escaping Reply
  ) {
    guard let (w, t, index) = locate(layer: layer, in: leased) else {
      return reply(.failure(MuxError(.notFound, "layer")))
    }
    guard ratio.isFinite, ratio > 0.02, ratio < 0.98,
      let layout = workspaces[w].tabs[t].layers[index].layout
        .settingRatio(ratio, at: path)
    else { return reply(.failure(MuxError(.invalidRequest, "split ratio"))) }
    workspaces[w].tabs[t].layers[index].layout = layout
    commitLayout(leased)
    reply(.success(.layout(snapshot(workspaces[w]))))
  }

  func locate(layer: LayerID, in workspace: WorkspaceID) -> (Int, Int, Int)? {
    guard let w = workspaces.firstIndex(where: { $0.id == workspace }) else {
      return nil
    }
    for (t, tab) in workspaces[w].tabs.enumerated() {
      if let index = tab.layers.firstIndex(where: { $0.id == layer }) {
        return (w, t, index)
      }
    }
    return nil
  }
}
