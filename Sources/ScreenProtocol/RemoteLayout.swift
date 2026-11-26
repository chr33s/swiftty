import SessionCore
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

  /// Tabs one layout may list, and panes across all its tabs: with every
  /// name and title empty, a full layout takes under a fifth of a record.
  public static let maxTabs = 64
  public static let maxPanes = 64
  /// Bytes of one name or title; longer ones are cut at a character.
  public static let maxNameBytes = 256
  /// Encoded bytes of a layout the host sends, leaving its `Layout`
  /// message room in one control record. Titles of control characters
  /// escape to six bytes each, so the host cuts names and titles further
  /// until the layout fits.
  static let maxEncodedBytes = RSTLimits.maxControlRecordBytes - 512

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

  /// The client's view of `ws`, bounded to the wire limits and to one
  /// control record.
  public init(_ ws: WorkspaceSnapshot) {
    var tabs: [Tab] = []
    var remaining = Self.maxPanes
    for tab in ws.tabs.prefix(Self.maxTabs) where remaining > 0 {
      let panes = tab.panes.prefix(remaining)
      remaining -= panes.count
      tabs.append(
        Tab(
          id: tab.id,
          name: Self.bounded(tab.name),
          panes: panes.map { id in
            let summary = ws.pane(id)
            return Pane(
              id: id,
              title: Self.bounded(summary?.title ?? ""),
              exited: summary?.exitStatus != nil
            )
          },
          activePane: tab.activePane
        )
      )
    }
    self.init(
      workspaceName: Self.bounded(ws.name),
      revision: ws.layoutRevision,
      tabs: tabs,
      activeTab: ws.activeTab
    )
    fitToRecord()
  }

  /// Halves the bytes every name and title may keep until the encoded
  /// layout fits `maxEncodedBytes`; with all of them empty it does.
  mutating func fitToRecord() {
    let encoder = makeEncoder()
    var budget = Self.maxNameBytes
    while budget > 0, let size = try? encoder.encode(self).count,
      size > Self.maxEncodedBytes
    {
      budget /= 2
      workspaceName = Self.bounded(workspaceName, to: budget)
      for t in tabs.indices {
        tabs[t].name = Self.bounded(tabs[t].name, to: budget)
        for p in tabs[t].panes.indices {
          tabs[t].panes[p].title = Self.bounded(
            tabs[t].panes[p].title,
            to: budget
          )
        }
      }
    }
  }

  public var activeTabLayout: Tab? { tabs.first { $0.id == activeTab } }

  /// Within the wire limits (a decoded layout must be).
  public var isValid: Bool {
    tabs.count <= Self.maxTabs && workspaceName.utf8.count <= Self.maxNameBytes
      && tabs.reduce(0) { $0 + $1.panes.count } <= Self.maxPanes
      && tabs.allSatisfy { tab in
        tab.name.utf8.count <= Self.maxNameBytes
          && tab.panes.allSatisfy { $0.title.utf8.count <= Self.maxNameBytes }
      }
  }

  /// `text` cut at a character to at most `limit` UTF-8 bytes, as the
  /// host cuts names and a client cuts a name it sends.
  public static func bounded(
    _ text: String,
    to limit: Int = maxNameBytes
  ) -> String {
    guard text.utf8.count > limit else { return text }
    var result = ""
    for character in text {
      guard result.utf8.count + character.utf8.count <= limit else { break }
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

// MARK: Display names

extension RemoteLayout.Pane {
  /// The title as native chrome shows it (`DisplayText.sanitize`); nil
  /// when the program reported none.
  public var displayTitle: String? {
    let title = DisplayText.sanitize(title)
    return title.isEmpty ? nil : title
  }
}

extension RemoteLayout.Tab {
  /// The service names new tabs by number; chrome shows the active pane's
  /// program instead, as the Mac's tab strip does.
  public var hasAutomaticName: Bool {
    let name = DisplayText.sanitize(name)
    return name.isEmpty || name.allSatisfy(\.isNumber)
  }

  /// What chrome shows for the tab: a name someone gave it, else the
  /// active pane's title; nil when neither is known.
  public var displayName: String? {
    guard hasAutomaticName else { return DisplayText.sanitize(name) }
    return panes.first { $0.id == activePane }?.displayTitle
  }
}
