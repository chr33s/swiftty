import AppKit
import SwiftMuxProtocol

/// Floating layers over a tab: placement, dragging, and the menu actions.
extension MuxWorkspaceController {
  /// The active tab with a divider drag and a layer drag applied locally.
  func displayedTab() -> TabSnapshot? {
    guard var tab = activeTab else { return nil }
    if let proposal = ratioProposal, proposal.tab == tab.id {
      if let id = proposal.layer,
        let index = tab.layers.firstIndex(where: { $0.id == id }),
        let moved = tab.layers[index].layout
          .settingRatio(proposal.ratio, at: proposal.path)
      {
        tab.layers[index].layout = moved
      } else if proposal.layer == nil,
        let moved = tab.layout?.settingRatio(proposal.ratio, at: proposal.path)
      {
        tab.layout = moved
      }
    }
    if let proposal = layerProposal, proposal.tab == tab.id,
      let index = tab.layers.firstIndex(where: { $0.id == proposal.layer })
    {
      tab.layers[index].bounds = proposal.bounds
    }
    return tab
  }

  /// The rectangle `placement` maps onto, in layout coordinates (y down).
  /// A split keeps its outer margin. Minimized layers reserve a chip strip.
  func contentRect(for tab: TabSnapshot, in bounds: NSRect) -> LayoutRect {
    let reserve =
      tab.zoomedPane == nil && tab.layers.contains(where: \.minimized)
      ? MuxLayoutView.chipStrip : 0
    let box = NSRect(
      x: 0,
      y: 0,
      width: max(0, bounds.width),
      height: CGFloat(max(0, Int(bounds.height) - reserve))
    )
    return MuxLayoutView.area(
      box,
      split: tab.tiledPanes.count > 1,
      margin: layoutView.splitMargin
    )
  }

  /// Frames for visible panes in points, plus dividers and layer chrome.
  func layout(in bounds: NSRect) -> MuxArrangedPanes {
    guard let tab = displayedTab() else {
      return MuxArrangedPanes(panes: [], dividers: [], layers: [], chips: [])
    }
    let area = contentRect(for: tab, in: bounds)
    let placed = tab.placement(
      in: area,
      divider: MuxLayoutView.divider,
      floatInset: MuxLayoutView.floatInset
    )
    let panes = placed.order.compactMap { id -> (MuxPaneContainer, NSRect)? in
      guard let container = containers[id], let rect = placed.panes[id] else {
        return nil
      }
      // LayoutRect y grows downward; AppKit's grows upward.
      return (
        container,
        NSRect(
          x: rect.x,
          y: Int(bounds.height) - rect.maxY,
          width: rect.width,
          height: rect.height
        )
      )
    }
    let chips: [(id: LayerID, title: String)] =
      tab.zoomedPane == nil
      ? tab.layers.filter(\.minimized)
        .map { ($0.id, title(of: $0.focusedPane)) } : []
    return MuxArrangedPanes(
      panes: panes,
      dividers: placed.dividers,
      layers: placed.layers,
      chips: chips
    )
  }

  /// A divider drag: shown at once, sent coalesced (one request in
  /// flight, newest ratio pending), clamped to the minimum pane size.
  func setRatio(_ ratio: Double, path: [Bool], layer: LayerID? = nil) {
    guard let tab = displayedTab(), let tree = tab.tree(of: layer) else {
      return
    }
    let clamped = LayoutGeometry.clampedRatio(
      ratio,
      at: path,
      of: tree,
      in: splitArea(tab, layer: layer),
      minimum: minimumPaneSize,
      divider: MuxLayoutView.divider
    )
    ratioProposal = RatioProposal(
      tab: tab.id,
      path: path,
      ratio: clamped,
      layer: layer
    )
    layoutView.needsLayout = true
    flushRatio()
  }

  /// The current ratio of the split at `path` as displayed.
  func ratio(at path: [Bool], layer: LayerID? = nil) -> Double? {
    guard let tab = displayedTab(), let tree = tab.tree(of: layer),
      let node = tree.node(at: path), case let .split(_, ratio, _, _) = node
    else { return nil }
    return ratio
  }

  /// The area a divider divides: the layer's inset, or the tiled content.
  private func splitArea(_ tab: TabSnapshot, layer: LayerID?) -> LayoutRect {
    let content = contentRect(for: tab, in: layoutView.bounds)
    guard let layer else { return content }
    let placed = tab.placement(
      in: content,
      divider: MuxLayoutView.divider,
      floatInset: MuxLayoutView.floatInset
    )
    let outer = placed.layers.first { $0.id == layer }?.outer ?? content
    return LayoutGeometry.inset(outer, by: MuxLayoutView.floatInset)
  }

  /// Moves focus inside the focused layer, then to the layer below it.
  func focus(_ direction: Direction) {
    guard let tab = displayedTab(), tab.zoomedPane == nil else { return }
    let area = contentRect(for: tab, in: layoutView.bounds)
    let frames =
      tab.placement(
        in: area,
        divider: MuxLayoutView.divider,
        floatInset: MuxLayoutView.floatInset
      )
      .panes
    guard
      let next = LayoutGeometry.focusNeighbor(
        of: tab.activePane,
        direction: direction,
        tab: tab,
        frames: frames
      )
    else { return }
    focus(next)
    if let view = views[next] { window?.makeFirstResponder(view) }
  }

  /// Moves the nearest divider beside the active pane (keyboard resize).
  func resizeActivePane(_ direction: Direction, step: Double = 0.05) {
    guard let tab = displayedTab() else { return }
    let axis: SplitAxis =
      direction == .left || direction == .right ? .leftRight : .topBottom
    let layer = tab.layer(containing: tab.activePane)
    guard
      let split = tab.tree(containing: tab.activePane)?
        .enclosingSplit(of: tab.activePane, axis: axis),
      let current = ratio(at: split.path, layer: layer?.id)
    else { return }
    let grow = direction == .right || direction == .down
    setRatio(
      current + (grow ? step : -step),
      path: split.path,
      layer: layer?.id
    )
  }

  /// Brings `layer` to the front unless it already is.
  func raise(_ layer: LayerID) {
    guard activeTab?.layers.last?.id != layer else { return }
    command(.orderLayer(layer: layer, before: nil))
  }

  /// Drags a floating pane's layer by the pane's header.
  func trackLayerMove(_ pane: PaneID, _ event: NSEvent) {
    guard let layer = activeTab?.layer(containing: pane) else { return }
    if pane != activePane { focus(pane) }
    trackLayer(layer.id, event)
  }

  /// Drags a floating layer: no edges moves it, otherwise those edges
  /// resize it. One `placeLayer` is sent on release.
  func trackLayer(_ id: LayerID, edges: LayerEdges = [], _ event: NSEvent) {
    guard let tab = activeTab, let layer = tab.layer(id: id) else { return }
    raise(id)
    let origin = layer.bounds
    let area = contentRect(for: tab, in: layoutView.bounds)
    let start = fraction(
      of: layoutView.convert(event.locationInWindow, from: nil),
      in: area
    )
    var proposal: LayerProposal?
    trackPointer(from: event) { [weak self] point in
      guard let self else { return }
      let now = self.fraction(of: point, in: area)
      proposal = self.propose(
        origin.dragged(dx: now.x - start.x, dy: now.y - start.y, edges: edges),
        layer: id,
        from: origin,
        area: area,
        resizing: !edges.isEmpty
      )
    }
    commitLayerDrag(proposal, original: origin)
  }

  /// Restores a minimized layer, brings it forward, and focuses its pane.
  func restoreLayer(_ id: LayerID) {
    guard let layer = activeTab?.layer(id: id) else { return }
    command(.minimizeLayer(layer: id, minimized: false))
    raise(id)
    command(.focusPane(layer.focusedPane))
  }

  /// Floats a tiled pane, or docks a floating pane back into the tile.
  func toggleFloat(pane: PaneID) {
    guard let tab = activeTab else { return }
    if tab.layer(containing: pane) != nil {
      command(.dockPane(pane: pane, beside: nil, axis: .leftRight))
    } else {
      command(.floatPane(pane: pane, bounds: .standard))
    }
  }

  @objc
  func floatActivePane(_ sender: Any?) {
    guard let pane = activePane else { return }
    command(.floatPane(pane: pane, bounds: .standard))
  }

  @objc
  func dockActivePane(_ sender: Any?) {
    guard let pane = activePane, let tab = activeTab,
      tab.layer(containing: pane) != nil
    else { return }
    command(.dockPane(pane: pane, beside: nil, axis: .leftRight))
  }

  @objc
  func minimizeActiveLayer(_ sender: Any?) {
    guard let pane = activePane, let layer = activeTab?.layer(containing: pane)
    else { return }
    command(.minimizeLayer(layer: layer.id, minimized: true))
  }

  @objc
  func closeActiveLayer(_ sender: Any?) {
    guard let tab = activeTab, let layer = tab.layer(containing: tab.activePane)
    else { return }
    let panes = layer.layout.panes
    confirmThen(
      running(panes),
      "Close the floating layer?",
      panes.count == 1
        ? "Its process is still running and will be terminated."
        : "Its \(panes.count) panes and their processes will be terminated."
    ) { [weak self] in self?.command(.closeLayer(layer.id)) }
  }

  /// `point` is in the layout view (y up). The result is a fraction of `area`.
  private func fraction(
    of point: NSPoint,
    in area: LayoutRect
  ) -> (x: Double, y: Double) {
    let width = Double(max(1, area.width))
    let height = Double(max(1, area.height))
    return (
      (Double(point.x) - Double(area.x)) / width,
      (Double(layoutView.bounds.height - point.y) - Double(area.y)) / height
    )
  }

  private func propose(
    _ candidate: LayerRect,
    layer: LayerID,
    from origin: LayerRect,
    area: LayoutRect,
    resizing: Bool
  ) -> LayerProposal? {
    guard candidate.isValid, let tab = activeTab else { return layerProposal }
    if resizing {
      guard let tree = tab.tree(of: layer),
        LayoutGeometry.respectsPaneMinimum(
          candidate,
          tree: tree,
          from: origin,
          in: area,
          minimum: minimumPaneSize,
          divider: MuxLayoutView.divider,
          floatInset: MuxLayoutView.floatInset
        )
      else { return layerProposal }
    }
    let proposal = LayerProposal(tab: tab.id, layer: layer, bounds: candidate)
    layerProposal = proposal
    layoutView.needsLayout = true
    layoutView.layoutSubtreeIfNeeded()
    return proposal
  }

  private func trackPointer(from event: NSEvent, onMove: (NSPoint) -> Void) {
    guard let window = layoutView.window else { return }
    var next: NSEvent? = event
    while let current = next, current.type != .leftMouseUp {
      if current.type == .leftMouseDragged {
        autoreleasepool {
          onMove(layoutView.convert(current.locationInWindow, from: nil))
        }
      }
      next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp])
    }
  }

  private func commitLayerDrag(_ proposal: LayerProposal?, original: LayerRect)
  {
    guard let proposal, proposal.bounds != original else {
      layerProposal = nil
      layoutView.needsLayout = true
      return
    }
    let clear: @MainActor @Sendable () -> Void = { [weak self] in
      guard let self, self.layerProposal == proposal else { return }
      self.layerProposal = nil
      self.layoutView.needsLayout = true
    }
    command(
      .placeLayer(layer: proposal.layer, bounds: proposal.bounds),
      failed: { _ in clear() },
      then: clear
    )
  }
}
