import SwiftMuxProtocol

/// The attached workspace's tabs and panes, as a roaming client shows them
/// in its menus (`layoutControl`, spec.roaming.md §7.6). Names and titles
/// only: no geometry, processes or working directories.
public struct RemoteLayout: Codable, Hashable, Sendable {
  public struct Pane: Codable, Hashable, Sendable {
    public var id: PaneID
    public var title: String
    public var exited: Bool

    public init(id: PaneID, title: String, exited: Bool = false) {
      self.id = id
      self.title = title
      self.exited = exited
    }
  }

  public struct Tab: Codable, Hashable, Sendable {
    public var id: TabID
    public var name: String
    /// In display order.
    public var panes: [Pane]
    public var activePane: PaneID

    public init(id: TabID, name: String, panes: [Pane], activePane: PaneID) {
      self.id = id
      self.name = name
      self.panes = panes
      self.activePane = activePane
    }
  }

  public var workspaceName: String
  /// The workspace's layout revision; a client keeps the newest.
  public var revision: UInt64
  public var tabs: [Tab]
  public var activeTab: TabID

  /// Tabs one layout may list, and panes per tab.
  public static let maxTabs = 64
  public static let maxPanesPerTab = 64
  /// Bytes of one name or title; longer ones are cut at a character.
  public static let maxNameBytes = 256

  public init(
    workspaceName: String,
    revision: UInt64,
    tabs: [Tab],
    activeTab: TabID
  ) {
    self.workspaceName = workspaceName
    self.revision = revision
    self.tabs = tabs
    self.activeTab = activeTab
  }

  /// The client's view of `ws`, bounded to the wire limits.
  public init(_ ws: WorkspaceSnapshot) {
    let tabs = ws.tabs.prefix(Self.maxTabs)
      .map { tab in
        Tab(
          id: tab.id,
          name: Self.bounded(tab.name),
          panes: tab.layout.panes.prefix(Self.maxPanesPerTab)
            .map { id in
              let summary = ws.pane(id)
              return Pane(
                id: id,
                title: Self.bounded(summary?.title ?? ""),
                exited: summary?.exitStatus != nil
              )
            },
          activePane: tab.activePane
        )
      }
    self.init(
      workspaceName: Self.bounded(ws.name),
      revision: ws.layoutRevision,
      tabs: Array(tabs),
      activeTab: ws.activeTab
    )
  }

  public var activeTabLayout: Tab? { tabs.first { $0.id == activeTab } }

  /// Within the wire limits (a decoded layout must be).
  public var isValid: Bool {
    tabs.count <= Self.maxTabs && workspaceName.utf8.count <= Self.maxNameBytes
      && tabs.allSatisfy { tab in
        tab.panes.count <= Self.maxPanesPerTab
          && tab.name.utf8.count <= Self.maxNameBytes
          && tab.panes.allSatisfy { $0.title.utf8.count <= Self.maxNameBytes }
      }
  }

  static func bounded(_ text: String) -> String {
    guard text.utf8.count > maxNameBytes else { return text }
    var result = ""
    for character in text {
      guard result.utf8.count + character.utf8.count <= maxNameBytes else {
        break
      }
      result.append(character)
    }
    return result
  }
}

/// A layout change a roaming client asks of the host (`layoutControl`).
/// The host applies it with the workspace lease it holds for the client;
/// the screen follows the workspace's active pane as before.
public enum LayoutAction: Codable, Hashable, Sendable {
  /// Splits the shown pane; the new pane becomes active.
  case split(axis: SplitAxis)
  case focusPane(pane: PaneID)
  case closePane(pane: PaneID)
  case newTab
  case selectTab(tab: TabID)
  case renameTab(tab: TabID, name: String)
  case closeTab(tab: TabID)
  case renameWorkspace(name: String)

  /// A name within the wire limit, where the action carries one.
  public var isValid: Bool {
    switch self {
    case let .renameTab(_, name), let .renameWorkspace(name):
      !name.isEmpty && name.utf8.count <= RemoteLayout.maxNameBytes
    default: true
    }
  }
}
