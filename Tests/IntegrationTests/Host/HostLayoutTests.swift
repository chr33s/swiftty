#if os(macOS)
import Foundation
import ScreenProtocol
import SessionCore
import SwiftMuxProtocol
@testable import TerminalHost
import TestSupport
import Testing

/// `layoutControl` (spec.roaming.md §7.6): the host reports the
/// workspace's tabs and panes and applies a client's layout changes with
/// the lease it holds for it.
@Suite(.timeLimit(.minutes(1)))
struct HostLayoutTests {
  /// The newest `Layout` the client has received.
  private func layout(
    _ client: TestClient,
    _ what: String,
    where predicate: @escaping (RemoteLayout) -> Bool = { _ in true }
  ) async throws -> RemoteLayout {
    try await hostEventually(what) {
      client.messages.reversed().lazy
        .compactMap { message -> RemoteLayout? in
          if case let .layout(_, layout) = message { return layout }
          return nil
        }
        .first.flatMap { predicate($0) ? $0 : nil }
    }
  }

  private func result(
    _ client: TestClient,
    _ request: UInt64
  ) async throws -> RSTErrorCode? {
    let reply = try await client.message("LayoutResult \(request)") {
      if case let .layoutResult(_, id, _) = $0 { return id == request }
      return false
    }
    guard case let .layoutResult(_, _, error) = reply else { return nil }
    return error
  }

  /// A history window belongs to the pane it was opened on: switching
  /// panes shows the new pane's live screen, not the same row number in
  /// its history.
  @Test
  func `switching panes returns the history window to live output`()
    async throws
  {
    try await withRegistry { registry in
      let grant = try await registry.create(
        grid: GridSize(columns: 40, rows: 8)
      )
      let client = TestClient(registry)
      _ = try await client.attached(grant, features: [.layoutControl])
      let first = try #require(
        try await layout(client, "initial layout").activeTabLayout?.activePane
      )
      var sequence: UInt64 = 0
      func run(_ command: String) async throws {
        sequence += 1
        try await client.send(
          .input(
            .init(
              attachmentEpoch: 1,
              sequence: sequence,
              operation: .committedText(command)
            )
          )
        )
        sequence += 1
        try await client.send(
          .input(
            .init(
              attachmentEpoch: 1,
              sequence: sequence,
              operation: .key(SemanticKey(.enter))
            )
          )
        )
      }
      _ = try await client.snapshot("prompt") { screenText($0).contains("$") }
      try await run("i=0; while [ $i -lt 200 ]; do echo a-$i; i=$((i+1)); done")
      _ = try await client.snapshot("first pane output") {
        $0.textLines.contains("a-199")
      }
      try await client.send(
        .layoutAction(epoch: 1, requestID: 1, .split(axis: .leftRight))
      )
      #expect(try await result(client, 1) == nil)
      let second = try #require(
        try await layout(client, "two panes") {
          $0.activeTabLayout?.panes.count == 2
        }
        .activeTabLayout?
        .activePane
      )
      _ = try await client.snapshot("second prompt") {
        screenText($0).contains("$") && !$0.textLines.contains("a-199")
      }
      try await run("i=0; while [ $i -lt 400 ]; do echo b-$i; i=$((i+1)); done")
      _ = try await client.snapshot("second pane output") {
        $0.textLines.contains("b-399")
      }
      try await client.send(
        .layoutAction(epoch: 1, requestID: 2, .focusPane(pane: first))
      )
      #expect(try await result(client, 2) == nil)
      let back = try await client.snapshot("first pane again") {
        $0.textLines.contains("a-199")
      }
      try await client.send(.viewport(epoch: 1, lines: 50))
      let window = try await client.snapshot("first pane window", after: back) {
        !$0.cursor.visible
      }
      try await client.send(
        .layoutAction(epoch: 1, requestID: 3, .focusPane(pane: second))
      )
      #expect(try await result(client, 3) == nil)
      // Bounded by the window: older frames of the second pane match too.
      let shown = try await client.snapshot("second pane", after: window) {
        $0.textLines.contains { $0.hasPrefix("b-") }
      }
      #expect(shown.cursor.visible)
      #expect(shown.textLines.contains("b-399"))
    }
  }

  @Test
  func `a client changes panes, tabs and the workspace name`() async throws {
    try await withRegistry { registry in
      let grant = try await registry.create(
        grid: GridSize(columns: 80, rows: 24)
      )
      let client = TestClient(registry)
      let attached = try await client.attached(
        grant,
        features: [.layoutControl]
      )
      #expect(attached.features.contains(.layoutControl))
      let initial = try await layout(client, "initial layout")
      #expect(initial.tabs.count == 1)
      let firstTab = try #require(initial.activeTabLayout)
      #expect(firstTab.panes.count == 1)
      let firstPane = firstTab.activePane

      try await client.send(
        .layoutAction(epoch: 1, requestID: 1, .split(axis: .leftRight))
      )
      #expect(try await result(client, 1) == nil)
      let split = try await layout(client, "two panes") {
        $0.activeTabLayout?.panes.count == 2
      }
      #expect(split.activeTabLayout?.activePane != firstPane)

      try await client.send(
        .layoutAction(epoch: 1, requestID: 2, .focusPane(pane: firstPane))
      )
      #expect(try await result(client, 2) == nil)
      _ = try await layout(client, "first pane active") {
        $0.activeTabLayout?.activePane == firstPane
      }

      try await client.send(.layoutAction(epoch: 1, requestID: 3, .newTab))
      #expect(try await result(client, 3) == nil)
      let twoTabs = try await layout(client, "two tabs") {
        $0.tabs.count == 2 && $0.activeTab != firstTab.id
      }
      let newTab = twoTabs.activeTab

      try await client.send(
        .layoutAction(
          epoch: 1,
          requestID: 4,
          .renameTab(tab: newTab, name: "logs")
        )
      )
      #expect(try await result(client, 4) == nil)
      _ = try await layout(client, "renamed tab") {
        $0.tabs.contains { $0.id == newTab && $0.name == "logs" }
      }

      try await client.send(
        .layoutAction(epoch: 1, requestID: 5, .selectTab(tab: firstTab.id))
      )
      #expect(try await result(client, 5) == nil)
      _ = try await layout(client, "first tab again") {
        $0.activeTab == firstTab.id
      }

      try await client.send(
        .layoutAction(epoch: 1, requestID: 6, .closeTab(tab: newTab))
      )
      #expect(try await result(client, 6) == nil)
      _ = try await layout(client, "one tab") { $0.tabs.count == 1 }

      let second = try #require(
        split.activeTabLayout?.panes.first { $0.id != firstPane }?.id
      )
      try await client.send(
        .layoutAction(epoch: 1, requestID: 7, .closePane(pane: second))
      )
      #expect(try await result(client, 7) == nil)
      _ = try await layout(client, "one pane") {
        $0.activeTabLayout?.panes.count == 1
      }

      try await client.send(
        .layoutAction(epoch: 1, requestID: 8, .renameWorkspace(name: "phone"))
      )
      #expect(try await result(client, 8) == nil)
      _ = try await layout(client, "renamed workspace") {
        $0.workspaceName == "phone"
      }

      // A tab that is not there is refused; the attachment stays.
      try await client.send(
        .layoutAction(epoch: 1, requestID: 9, .selectTab(tab: TabID()))
      )
      #expect(try await result(client, 9) == .inputInvalid)
      #expect(!client.isClosed)
    }
  }

  @Test
  func `a revision alone does not resend the layout`() {
    let pane = PaneID()
    let tab = TabID()
    var layout = RemoteLayout(
      workspaceName: "w",
      revision: 1,
      tabs: [
        .init(
          id: tab,
          name: "0",
          panes: [.init(id: pane, title: "zsh")],
          activePane: pane
        )
      ],
      activeTab: tab
    )
    #expect(RoamingSession.layoutChanged(from: nil, to: layout))
    var next = layout
    next.revision = 2
    #expect(!RoamingSession.layoutChanged(from: layout, to: next))
    next.tabs[0].panes[0].title = "vim"
    #expect(RoamingSession.layoutChanged(from: layout, to: next))
    layout.revision = 3
    #expect(RoamingSession.layoutChanged(from: next, to: layout))
  }

  @Test
  func `a client without layout control gets no layout and may not change it`()
    async throws
  {
    try await withRegistry { registry in
      let grant = try await registry.create(
        grid: GridSize(columns: 80, rows: 24)
      )
      let client = TestClient(registry)
      let attached = try await client.attached(grant)
      #expect(!attached.features.isEmpty)
      _ = try await client.snapshot("first screen") { _ in true }
      #expect(
        !client.messages.contains {
          if case .layout = $0 { return true }
          return false
        }
      )
      try await client.send(.layoutAction(epoch: 1, requestID: 1, .newTab))
      #expect(try await client.errorCode() == .malformed)
    }
  }
}
#endif
