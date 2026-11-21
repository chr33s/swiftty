import Foundation
import SwiftMuxProtocol

/// One pane of a saved layout, by slot.
package struct SavedPaneContent: Codable, Sendable, Equatable {
  package var launch: SavedPaneLaunch
  package var localDirectory: String?

  package init(launch: SavedPaneLaunch, localDirectory: String?) {
    self.launch = launch
    self.localDirectory = localDirectory
  }
}

/// The saved fields of a workspace (spec.durability.md §12.2.3). Equality
/// is the dirty check: a change elsewhere (a title) never causes a write.
package struct SavedLayoutContent: Codable, Sendable, Equatable {
  package var name: String
  package var tabs: [WorkspaceTemplateTab]
  package var activeTab: Int
  package var outputOptOut: Bool
  /// Indexed by slot.
  package var panes: [SavedPaneContent]

  package var paneCount: Int { panes.count }

  /// Nil while the worker publishes no workspace.
  package init?(_ state: SavedLayoutState) {
    guard let graph = state.graph, !graph.tabs.isEmpty else { return nil }
    let metadata = Dictionary(
      state.panes.map { ($0.pane, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    var slots: [PaneID: Int] = [:]
    var panes: [SavedPaneContent] = []
    func node(_ layout: LayoutNode) -> WorkspaceTemplateNode {
      switch layout {
      case let .pane(id):
        if let slot = slots[id] { return .pane(slot: slot) }
        let slot = panes.count
        slots[id] = slot
        let pane = metadata[id]
        panes.append(
          SavedPaneContent(
            launch: pane?.launch ?? .loginShell,
            localDirectory: pane?.localDirectory
          )
        )
        return .pane(slot: slot)
      case let .split(axis, ratio, first, second):
        return .split(
          axis: axis,
          ratio: ratio,
          first: node(first),
          second: node(second)
        )
      }
    }
    var tabs: [WorkspaceTemplateTab] = []
    for tab in graph.tabs {
      let layout = node(tab.layout)
      guard let active = slots[tab.activePane] ?? layout.slots.first else {
        continue
      }
      tabs.append(
        WorkspaceTemplateTab(
          name: tab.name,
          layout: layout,
          activeSlot: active,
          zoomedSlot: tab.zoomedPane.flatMap { slots[$0] }
        )
      )
    }
    guard !tabs.isEmpty else { return nil }
    self.name = graph.name
    self.tabs = tabs
    self.activeTab = graph.tabs.firstIndex { $0.id == graph.activeTab } ?? 0
    self.outputOptOut = state.outputOptOut
    self.panes = panes
  }

  /// The frontend's launch for every pane, with each saved directory and,
  /// for chosen slots only, the saved command.
  package func template(
    _ request: SavedReopenRequest,
    name: String
  ) -> WorkspaceTemplate {
    let chosen = Set(request.runCommandSlots)
    let launches = panes.enumerated()
      .map { slot, pane in
        var launch = request.launch
        if let directory = pane.localDirectory {
          launch.workingDirectory = directory
        }
        if case let .command(argv) = pane.launch, chosen.contains(slot) {
          launch.command = argv
        }
        return launch
      }
    return WorkspaceTemplate(
      name: name,
      columns: request.columns,
      rows: request.rows,
      remainOnExit: request.remainOnExit,
      launch: request.launch,
      panes: launches,
      tabs: tabs,
      activeTab: min(max(0, activeTab), tabs.count - 1),
      outputOptOut: outputOptOut
    )
  }

  package var commandSlots: [SavedWorkspaceListing.CommandSlot] {
    panes.enumerated()
      .compactMap { slot, pane in
        guard case let .command(argv) = pane.launch else { return nil }
        return SavedWorkspaceListing.CommandSlot(slot: slot, command: argv)
      }
  }
}

/// A sealed record generation's plaintext header and layout.
package struct SavedLayoutRecord: Codable, Sendable, Equatable {
  /// Readers support this schema and the previous one.
  package static let schema = 1

  package var schema: Int
  package var build: String
  /// The source workspace; also the record's file name.
  package var workspace: WorkspaceID
  package var generation: UInt64
  /// Store-wide write order; eviction uses it, never wall-clock time.
  package var storeSequence: UInt64
  package var incarnation: UUID
  package var layoutRevision: UInt64
  /// Display and retention only.
  package var savedAt: Date
  package var firstOfferedAt: Date?
  package var reopeningAs: WorkspaceID?
  package var disposition: SavedLayoutDisposition?
  package var content: SavedLayoutContent

  package init(
    build: String,
    workspace: WorkspaceID,
    generation: UInt64,
    storeSequence: UInt64,
    incarnation: UUID,
    layoutRevision: UInt64,
    savedAt: Date,
    content: SavedLayoutContent
  ) {
    self.schema = Self.schema
    self.build = build
    self.workspace = workspace
    self.generation = generation
    self.storeSequence = storeSequence
    self.incarnation = incarnation
    self.layoutRevision = layoutRevision
    self.savedAt = savedAt
    self.content = content
  }

  /// Bounds checked before a record is trusted (§12.2.9).
  package func validate(maxPanes: Int) throws(MuxError) {
    guard schema >= 1, schema <= Self.schema, generation > 0,
      !content.tabs.isEmpty, !content.panes.isEmpty,
      content.panes.count <= maxPanes, content.name.utf8.count <= 256,
      content.tabs.allSatisfy({ $0.name.utf8.count <= 256 }),
      content.panes.allSatisfy({ ($0.localDirectory?.utf8.count ?? 0) <= 4096 })
    else { throw MuxError(.invalidRequest, "invalid saved layout record") }
    let template = WorkspaceTemplate(
      name: nil,
      columns: 80,
      rows: 24,
      remainOnExit: false,
      launch: LaunchSpec(command: nil, workingDirectory: nil, environment: [:]),
      panes: content.panes.map { _ in
        LaunchSpec(command: nil, workingDirectory: nil, environment: [:])
      },
      tabs: content.tabs,
      activeTab: min(max(0, content.activeTab), content.tabs.count - 1),
      outputOptOut: false
    )
    try template.validate(maxPanes: maxPanes)
  }
}

/// Reads a pane's saved output from its worker (C1): the revision and, when
/// changed since the given one, the encoded rows.
package typealias SavedOutputSource =
  @Sendable (PaneID, UInt64?) async throws -> (revision: UInt64, bytes: Data?)

extension SavedLayoutContent {
  /// Pane to slot, in the same depth-first order the content uses.
  package static func slots(_ state: SavedLayoutState) -> [PaneID: Int] {
    var slots: [PaneID: Int] = [:]
    func visit(_ node: LayoutNode) {
      switch node {
      case let .pane(id): if slots[id] == nil { slots[id] = slots.count }
      case let .split(_, _, first, second):
        visit(first)
        visit(second)
      }
    }
    for tab in state.graph?.tabs ?? [] { visit(tab.layout) }
    return slots
  }
}
