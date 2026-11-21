import Foundation
@testable import ScreenProtocol
import SessionCore
import SwiftMuxProtocol
import Testing

/// RST/1 `Layout`, `LayoutAction` and `LayoutResult` (`layoutControl`).
struct LayoutWireTests {
  let pane = PaneID()
  let tab = TabID()

  var layout: RemoteLayout {
    RemoteLayout(
      workspaceName: "work",
      revision: 7,
      tabs: [
        .init(
          id: tab,
          name: "main",
          panes: [.init(id: pane, title: "zsh")],
          activePane: pane
        )
      ],
      activeTab: tab
    )
  }

  @Test
  func `layout messages round-trip`() throws {
    let actions: [LayoutAction] = [
      .split(axis: .leftRight), .split(axis: .topBottom),
      .focusPane(pane: pane), .closePane(pane: pane), .newTab,
      .selectTab(tab: tab), .renameTab(tab: tab, name: "logs"),
      .closeTab(tab: tab), .renameWorkspace(name: "phone"),
    ]
    var messages: [ControlMessage] = [
      .layout(epoch: 3, layout),
      .layoutResult(epoch: 3, requestID: 1, error: nil),
      .layoutResult(epoch: 3, requestID: 2, error: .inputInvalid),
    ]
    messages += actions.enumerated()
      .map { .layoutAction(epoch: 3, requestID: UInt64($0.offset), $0.element) }
    for message in messages {
      #expect(message.epoch == 3)
      let record = try ControlRecord.encode(message)
      #expect(try ControlRecord.decodeBody(record.dropFirst(4)) == message)
    }
  }

  @Test
  func `oversized layouts and empty names are rejected`() throws {
    var big = layout
    big.tabs = Array(repeating: big.tabs[0], count: RemoteLayout.maxTabs + 1)
    let encoded = try JSONEncoder().encode(ControlMessage.layout(epoch: 1, big))
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(ControlMessage.self, from: encoded)
    }
    let empty = try JSONEncoder()
      .encode(
        ControlMessage.layoutAction(
          epoch: 1,
          requestID: 1,
          .renameTab(tab: tab, name: "")
        )
      )
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(ControlMessage.self, from: empty)
    }
  }

  @Test
  func `snapshots are bounded to the wire limits`() {
    let long = String(repeating: "é", count: RemoteLayout.maxNameBytes)
    let ws = WorkspaceSnapshot(
      id: WorkspaceID(),
      name: long,
      tabs: [
        TabSnapshot(id: tab, name: "", layout: .pane(pane), activePane: pane)
      ],
      activeTab: tab,
      panes: [PaneSummary(id: pane, columns: 80, rows: 24, exitStatus: 0)],
      layoutRevision: 4
    )
    let remote = RemoteLayout(ws)
    #expect(remote.isValid)
    #expect(remote.workspaceName.utf8.count <= RemoteLayout.maxNameBytes)
    #expect(remote.revision == 4)
    #expect(remote.tabs.first?.panes.first?.exited == true)
  }

  @Test
  func `a layout at every limit fits one control record`() throws {
    // Control characters escape to six bytes each in JSON.
    let noisy = String(repeating: "\u{1}", count: RemoteLayout.maxNameBytes)
    let ids = (0 ..< RemoteLayout.maxTabs).map { _ in (TabID(), PaneID()) }
    let ws = WorkspaceSnapshot(
      id: WorkspaceID(),
      name: noisy,
      tabs: ids.map {
        TabSnapshot(
          id: $0.0,
          name: noisy,
          layout: .pane($0.1),
          activePane: $0.1
        )
      },
      activeTab: ids[0].0,
      panes: ids.map {
        PaneSummary(id: $0.1, columns: 80, rows: 24, title: noisy)
      },
      layoutRevision: 1
    )
    let remote = RemoteLayout(ws)
    #expect(remote.isValid)
    #expect(remote.tabs.count == RemoteLayout.maxTabs)
    // Cut, not emptied.
    #expect(remote.tabs.allSatisfy { !$0.name.isEmpty })
    let message = ControlMessage.layout(epoch: .max, remote)
    let record = try ControlRecord.encode(message)
    #expect(try ControlRecord.decodeBody(record.dropFirst(4)) == message)
    // Emptied, the same layout leaves room to spare.
    var empty = remote
    empty.workspaceName = ""
    for t in empty.tabs.indices {
      empty.tabs[t].name = ""
      for p in empty.tabs[t].panes.indices { empty.tabs[t].panes[p].title = "" }
    }
    let emptySize = try JSONEncoder().encode(empty).count
    #expect(emptySize < RSTLimits.maxControlRecordBytes / 5)
    // A layout that fits keeps its names whole.
    let small = RemoteLayout(
      WorkspaceSnapshot(
        id: WorkspaceID(),
        name: noisy,
        tabs: [ws.tabs[0]],
        activeTab: ids[0].0,
        panes: [ws.panes[0]],
        layoutRevision: 1
      )
    )
    #expect(small.workspaceName == noisy)
    #expect(small.tabs[0].panes[0].title == noisy)
  }

  @Test
  func `panes are bounded across all tabs`() throws {
    // Two tabs of 40 panes: the second keeps what the first leaves.
    func fortyPanes() -> (TabSnapshot, [PaneID]) {
      let panes = (0 ..< 40).map { _ in PaneID() }
      let node = panes.dropFirst()
        .reduce(LayoutNode.pane(panes[0])) {
          .split(axis: .leftRight, ratio: 0.5, first: $0, second: .pane($1))
        }
      return (
        TabSnapshot(id: TabID(), name: "", layout: node, activePane: panes[0]),
        panes
      )
    }
    let (first, firstPanes) = fortyPanes()
    let (second, secondPanes) = fortyPanes()
    let ws = WorkspaceSnapshot(
      id: WorkspaceID(),
      name: "w",
      tabs: [first, second],
      activeTab: first.id,
      panes: (firstPanes + secondPanes)
        .map { PaneSummary(id: $0, columns: 80, rows: 24) },
      layoutRevision: 1
    )
    let remote = RemoteLayout(ws)
    #expect(remote.isValid)
    #expect(remote.tabs.map(\.panes.count) == [40, RemoteLayout.maxPanes - 40])
    #expect(remote.tabs[1].panes.map(\.id) == Array(secondPanes.prefix(24)))

    var big = layout
    let many = (0 ..< 33)
      .map { _ in RemoteLayout.Pane(id: PaneID(), title: "") }
    big.tabs = [
      .init(id: tab, name: "", panes: many, activePane: many[0].id),
      .init(id: TabID(), name: "", panes: many, activePane: many[0].id),
    ]
    #expect(!big.isValid)
    let encoded = try JSONEncoder().encode(ControlMessage.layout(epoch: 1, big))
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(ControlMessage.self, from: encoded)
    }
  }

  @Test
  func `numbered default tabs are named by their program`() {
    var tab = layout.tabs[0]
    #expect(tab.displayName == "main")
    tab.name = "3"
    #expect(tab.hasAutomaticName)
    #expect(tab.displayName == "zsh")
    tab.panes[0].title = "\u{1B}"
    #expect(tab.displayName == nil)
  }

  @Test
  func `layout control is advertised by name`() {
    #expect(RSTFeatures.supported.contains(.layoutControl))
    #expect(RSTFeatures(names: ["layoutControl"]) == .layoutControl)
    #expect(RSTFeatures.layoutControl.names == ["layoutControl"])
  }
}
