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
  func `layout control is advertised by name`() {
    #expect(RSTFeatures.supported.contains(.layoutControl))
    #expect(RSTFeatures(names: ["layoutControl"]) == .layoutControl)
    #expect(RSTFeatures.layoutControl.names == ["layoutControl"])
  }
}
