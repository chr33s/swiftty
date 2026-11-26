import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
import SwiftMuxTerminal
import TTYKit
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct FloatingLayerTests {
  @Test
  func layerRectsFitTheTab() {
    #expect(LayerRect.standard.isValid)
    #expect(LayerRect(x: 0, y: 0, w: 1, h: 1).isValid)
    #expect(LayerRect(x: -1e-7, y: 0, w: 1, h: 1).isValid)
    #expect(!LayerRect(x: 0, y: 0, w: 0, h: 0.5).isValid)
    #expect(!LayerRect(x: 0.5, y: 0, w: 0.6, h: 0.5).isValid)
    #expect(!LayerRect(x: .nan, y: 0, w: 0.5, h: 0.5).isValid)
    #expect(
      LayerRect(x: 0.2, y: -0.1, w: 0.5, h: 0.4).fitted()
        == LayerRect(x: 0.2, y: 0, w: 0.5, h: 0.4)
    )
    #expect(
      LayerRect(x: 0.8, y: 0.2, w: 0.5, h: 0.4).fitted()
        == LayerRect(x: 0.5, y: 0.2, w: 0.5, h: 0.4)
    )
  }

  @Test
  func layerDragsMoveOrClampTheDraggedEdges() {
    let rect = LayerRect(x: 0.2, y: 0.2, w: 0.4, h: 0.4)
    // A move slides inside the tab, keeping the size.
    let moved = rect.dragged(dx: -0.5, dy: 0.1)
    #expect(moved.x == 0)
    #expect(abs(moved.y - 0.3) < 1e-9)
    #expect(moved.w == 0.4 && moved.h == 0.4)
    // An edge stops at the tab; the opposite edge stays put.
    let left = rect.dragged(dx: -0.5, dy: 0, edges: .left)
    #expect(left.x == 0)
    #expect(abs((left.x + left.w) - 0.6) < 1e-9)
    let corner = rect.dragged(dx: 0.1, dy: 0.7, edges: [.right, .bottom])
    #expect(abs(corner.w - 0.5) < 1e-9)
    #expect(abs((corner.y + corner.h) - 1) < 1e-9)
    // Crossing the opposite edge collapses, which is invalid.
    #expect(!rect.dragged(dx: 0.6, dy: 0, edges: .left).isValid)
  }

  @Test
  func endingTheLastVisiblePaneShowsAHiddenLayer() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, first) = try await workspace(c)
    let created = try await layout(
      c,
      .newLayer(tab: ws.tabs[0].id, bounds: .standard, launch: shellLaunch())
    )
    let layer = try #require(created.tabs[0].layers.first)
    _ = try await layout(c, .minimizeLayer(layer: layer.id, minimized: true))
    let kept = try await layout(c, .endPane(first))
    #expect(kept.tabs[0].layout == nil)
    #expect(kept.tabs[0].layers.first?.minimized == false)
    #expect(kept.tabs[0].visiblePanes == [layer.focusedPane])
    #expect(kept.tabs[0].activePane == layer.focusedPane)
    try await c.execute(.endWorkspace(.id(ws.id)))
    await c.close()
  }

  @Test
  func oldSnapshotsOmitEmptyLayers() throws {
    let pane = PaneID()
    let tab = TabSnapshot(
      id: TabID(),
      name: "1",
      layout: .pane(pane),
      activePane: pane
    )
    let data = try JSONEncoder().encode(tab)
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.contains("layers"))
    #expect(text.contains("layout"))
    var object = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    object.removeValue(forKey: "layers")
    let decoded = try JSONDecoder()
      .decode(
        TabSnapshot.self,
        from: JSONSerialization.data(withJSONObject: object)
      )
    #expect(decoded.layers.isEmpty)
    #expect(decoded.layout == .pane(pane))
    #expect(decoded == tab)

    let floated = TabSnapshot(
      id: tab.id,
      name: "1",
      layout: nil,
      activePane: pane,
      layers: [
        FloatingLayer(layout: .pane(pane), bounds: .standard, focusedPane: pane)
      ]
    )
    let floatedObject = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(floated))
        as? [String: Any]
    )
    #expect(floatedObject["layout"] == nil)
    #expect(floatedObject["layers"] != nil)
  }

  @Test
  func placementStacksFloatsOverTheTile() {
    let tiled = PaneID()
    let floated = PaneID()
    let hidden = PaneID()
    let layer = FloatingLayer(
      layout: .pane(floated),
      bounds: .standard,
      focusedPane: floated
    )
    let minimized = FloatingLayer(
      layout: .pane(hidden),
      bounds: LayerRect(x: 0.1, y: 0.1, w: 0.2, h: 0.2),
      minimized: true,
      focusedPane: hidden
    )
    let tab = TabSnapshot(
      id: TabID(),
      name: "1",
      layout: .pane(tiled),
      activePane: floated,
      layers: [layer, minimized]
    )
    let area = LayoutRect(x: 0, y: 0, width: 1000, height: 800)
    let placed = tab.placement(in: area, divider: 5, floatInset: 8)
    #expect(placed.order == [tiled, floated])
    #expect(placed.layers.map(\.id) == [layer.id])
    let outer = placed.layers[0].outer
    #expect(outer == LayoutRect(x: 200, y: 120, width: 600, height: 440))
    #expect(placed.panes[floated] == LayoutGeometry.inset(outer, by: 8))
    #expect(placed.panes[hidden] == nil)
    #expect(placed.dividers.isEmpty)

    var zoomed = tab
    zoomed.zoomedPane = tiled
    let zoom = zoomed.placement(in: area, divider: 5, floatInset: 8)
    #expect(zoom.order == [tiled])
    #expect(zoom.layers.isEmpty)
    #expect(zoom.panes[tiled] == area)

    let below = LayoutGeometry.focusNeighbor(
      of: floated,
      direction: .down,
      tab: tab,
      frames: placed.panes
    )
    #expect(below == tiled)
    let stays = LayoutGeometry.focusNeighbor(
      of: tiled,
      direction: .up,
      tab: tab,
      frames: placed.panes
    )
    #expect(stays == nil)
  }

  @Test
  func aLayerResizeKeepsEveryPaneAtTheMinimum() {
    let first = PaneID()
    let second = PaneID()
    let tree: LayoutNode = .split(
      axis: .leftRight,
      ratio: 0.5,
      first: .pane(first),
      second: .pane(second)
    )
    let area = LayoutRect(x: 0, y: 0, width: 1000, height: 800)
    let wide = LayerRect(x: 0, y: 0, w: 0.5, h: 0.5)
    let narrow = LayerRect(x: 0, y: 0, w: 0.2, h: 0.5)
    let tighter = LayerRect(x: 0, y: 0, w: 0.15, h: 0.5)
    let minimum = (columns: 200, rows: 40)
    let fits = LayoutGeometry.respectsPaneMinimum(
      wide,
      tree: tree,
      from: wide,
      in: area,
      minimum: minimum,
      divider: 5,
      floatInset: 8
    )
    let crushed = LayoutGeometry.respectsPaneMinimum(
      narrow,
      tree: tree,
      from: wide,
      in: area,
      minimum: minimum,
      divider: 5,
      floatInset: 8
    )
    let alreadySmall = LayoutGeometry.respectsPaneMinimum(
      narrow,
      tree: tree,
      from: narrow,
      in: area,
      minimum: minimum,
      divider: 5,
      floatInset: 8
    )
    let smallerStill = LayoutGeometry.respectsPaneMinimum(
      tighter,
      tree: tree,
      from: narrow,
      in: area,
      minimum: minimum,
      divider: 5,
      floatInset: 8
    )
    #expect(fits)
    #expect(!crushed)
    #expect(alreadySmall)
    #expect(!smallerStill)
  }

  @Test
  func compositorPaintsTheFrontLayerLast() {
    let backPane = PaneID()
    let frontPane = PaneID()
    let back = FloatingLayer(
      layout: .pane(backPane),
      bounds: .standard,
      focusedPane: backPane
    )
    let front = FloatingLayer(
      layout: .pane(frontPane),
      bounds: .standard,
      focusedPane: frontPane
    )
    let tab = TabSnapshot(
      id: TabID(),
      name: "1",
      layout: nil,
      activePane: frontPane,
      layers: [back, front]
    )
    let workspace = WorkspaceSnapshot(
      id: WorkspaceID(),
      name: "work",
      tabs: [tab],
      activeTab: tab.id,
      panes: [
        PaneSummary(id: backPane, columns: 20, rows: 10, title: "back"),
        PaneSummary(id: frontPane, columns: 20, rows: 10, title: "front"),
      ],
      layoutRevision: 1
    )
    let compositor = Compositor(columns: 40, rows: 20)
    let screen = compositor.compose(
      workspace: workspace,
      frames: [:],
      status: StatusLine(),
      showCursor: false
    )
    let placed = tab.placement(
      in: compositor.paneArea,
      divider: 1,
      floatInset: 1
    )
    let row = placed.layers[1].outer.y
    #expect(screen.text(row: row).contains("front"))
    #expect(!screen.text(row: row).contains("back"))
    var renamed = workspace
    renamed.panes[1].title = "other"
    let next = compositor.compose(
      workspace: renamed,
      frames: [:],
      status: StatusLine(),
      showCursor: false
    )
    #expect(screen.rowKeys[row] != nil)
    #expect(screen.rowKeys[row] != next.rowKeys[row])
  }

  @Test
  func floatingCommandsKeepTheTabAndTheStack() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await workspace(c)
    let floated = try await layout(c, .floatPane(pane: pane, bounds: .standard))
    let tab = try #require(floated.tabs.first)
    #expect(tab.layout == nil)
    #expect(tab.layers.count == 1)
    #expect(tab.layers[0].layout == .pane(pane))
    #expect(tab.zoomedPane == nil)
    #expect(floated.layoutRevision > ws.layoutRevision)
    await expectInvalid(c) {
      try await c.execute(
        .floatPane(pane: pane, bounds: LayerRect(x: 0, y: 0, w: 1.2, h: 0.4))
      )
    }
    let moved = LayerRect(x: 0.05, y: 0.1, w: 0.5, h: 0.4)
    let placed = try await layout(
      c,
      .placeLayer(layer: tab.layers[0].id, bounds: moved)
    )
    #expect(placed.tabs[0].layers[0].bounds == moved)

    let created = try await layout(
      c,
      .newLayer(tab: tab.id, bounds: .standard, launch: shellLaunch())
    )
    let pair = created.tabs[0]
    #expect(pair.layers.count == 2)
    #expect(pair.activePane != pane)
    #expect(pair.layers[1].focusedPane == pair.activePane)
    let brought = try await layout(
      c,
      .orderLayer(layer: pair.layers[0].id, before: nil)
    )
    #expect(
      brought.tabs[0].layers.map(\.id) == [
        pair.layers[1].id, pair.layers[0].id,
      ]
    )
    let hidden = try await layout(
      c,
      .minimizeLayer(layer: pair.layers[1].id, minimized: true)
    )
    #expect(hidden.tabs[0].layers[0].minimized)
    #expect(hidden.tabs[0].visiblePanes == [pair.layers[0].focusedPane])
    await expectInvalid(c) {
      try await c.execute(
        .minimizeLayer(layer: pair.layers[0].id, minimized: true)
      )
    }
    let docked = try await layout(
      c,
      .dockPane(pane: pair.layers[0].focusedPane, beside: nil, axis: .leftRight)
    )
    #expect(docked.tabs[0].layout == .pane(pair.layers[0].focusedPane))
    #expect(docked.tabs[0].layers.count == 1)
    #expect(docked.tabs[0].layers[0].minimized)
    let closed = try await layout(c, .closeLayer(docked.tabs[0].layers[0].id))
    #expect(closed.tabs[0].layers.isEmpty)
    #expect(closed.tabs[0].panes == [pair.layers[0].focusedPane])
    try await c.execute(.endWorkspace(.id(ws.id)))
    await c.close()
  }

  @Test
  func floatingClearsZoomAndClosingTheTileKeepsTheLayer() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (_, first) = try await workspace(c)
    let split = try await layout(
      c,
      .split(pane: first, axis: .leftRight, launch: shellLaunch())
    )
    let tab = split.tabs[0]
    let second = tab.activePane
    #expect(tab.panes.count == 2)
    let zoomed = try await layout(c, .toggleZoom(tab.id))
    #expect(zoomed.tabs[0].zoomedPane == second)
    let floated = try await layout(
      c,
      .floatPane(pane: second, bounds: .standard)
    )
    #expect(floated.tabs[0].zoomedPane == nil)
    #expect(floated.tabs[0].layout == .pane(first))
    #expect(floated.tabs[0].layers.count == 1)
    #expect(floated.tabs[0].layers[0].layout == .pane(second))
    let returned = try await layout(
      c,
      .dockPane(pane: second, beside: nil, axis: .topBottom)
    )
    #expect(returned.tabs[0].layers.isEmpty)
    #expect(
      returned.tabs[0].layout
        == .split(
          axis: .topBottom,
          ratio: 0.5,
          first: .pane(first),
          second: .pane(second)
        )
    )
    let floatedAgain = try await layout(
      c,
      .floatPane(pane: second, bounds: .standard)
    )
    #expect(floatedAgain.tabs[0].layout == .pane(first))
    let inside = try await layout(
      c,
      .split(pane: second, axis: .topBottom, launch: shellLaunch())
    )
    #expect(inside.tabs[0].layout == .pane(first))
    #expect(inside.tabs[0].layers[0].layout.panes.count == 2)
    let kept = try await layout(c, .endPane(first))
    #expect(kept.tabs.count == 1)
    #expect(kept.tabs[0].layout == nil)
    #expect(kept.tabs[0].layers.count == 1)
    let ended = try await c.execute(.closeLayer(kept.tabs[0].layers[0].id))
    #expect(ended == .ok)
    await c.close()
  }

  @Test
  func anOlderClientCannotAttachAFloatingWorkspace() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await workspace(c)
    let plain = try await c.execute(
      .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
    )
    guard case let .created(other) = plain else {
      throw MuxError(.invalidRequest, "create")
    }
    _ = try await layout(c, .floatPane(pane: pane, bounds: .standard))
    let old = try await MuxConnection.connect(
      endpoint: h.endpoint,
      frontend: .native,
      capabilities: .supported.subtracting(.floatingLayers)
    )
    do {
      _ = try await old.execute(.attach(AttachRequest(.id(ws.id))))
      Issue.record("a client without floating layers attached")
    } catch let error as MuxError {
      #expect(error.code == .incompatibleVersion)
    }
    let attached = try await old.execute(.attach(AttachRequest(.id(other.id))))
    guard case .attached = attached else {
      throw MuxError(.invalidRequest, "attach")
    }
    try await c.execute(.endWorkspace(.id(ws.id)))
    try await old.execute(.endWorkspace(.id(other.id)))
    await old.close()
    await c.close()
  }

  private func workspace(
    _ connection: MuxConnection
  ) async throws -> (WorkspaceSnapshot, PaneID) {
    guard
      case let .created(ws) = try await connection.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      )
    else { throw MuxError(.invalidRequest, "create") }
    try await connection.attachAndShow(.id(ws.id))
    return (ws, ws.tabs[0].activePane)
  }

  private func layout(
    _ connection: MuxConnection,
    _ command: MuxCommand
  ) async throws -> WorkspaceSnapshot {
    guard case let .layout(ws) = try await connection.execute(command) else {
      throw MuxError(.invalidRequest, "layout")
    }
    return ws
  }

  private func expectInvalid(
    _ connection: MuxConnection,
    _ body: () async throws -> Void
  ) async {
    do {
      try await body()
      Issue.record("invalid layer command was accepted")
    } catch let error as MuxError {
      #expect(error.code == .invalidRequest)
    } catch { Issue.record("unexpected error \(error)") }
  }
}
