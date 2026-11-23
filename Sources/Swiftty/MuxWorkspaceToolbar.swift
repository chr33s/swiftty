import AppKit
import SwiftMuxProtocol
import SwifttyCore

/// Workspace tabs and actions in the native window toolbar.
@MainActor
final class MuxWorkspaceToolbar: NSObject, NSToolbarDelegate {
  static let tabsItem = NSToolbarItem.Identifier("swiftmux.tabs")
  static let newTabItem = NSToolbarItem.Identifier("swiftmux.new-tab")
  static let inboxItem = NSToolbarItem.Identifier("swiftmux.inbox")
  /// Each window's own: toolbars sharing an identifier mirror each
  /// other's item changes, and windows may show tabs in different places
  /// while a configuration change reaches them one by one.
  let toolbar = NSToolbar()
  let tabs = NSToolbarItem(itemIdentifier: tabsItem)
  let newTab = NSToolbarItem(itemIdentifier: newTabItem)
  let item = NSToolbarItem(itemIdentifier: inboxItem)
  /// Shown in the sidebar or a pane header, not the toolbar, which tabs on
  /// the left hide.
  let sidebarControls = MuxSidebarControls()
  var onClick: (() -> Void)?
  var onNewTab: (() -> Void)?
  var onToggleSidebar: (() -> Void)?

  init(tabs tabStrip: MuxTabStrip) {
    super.init()
    tabs.label = "Workspace Tabs"
    tabs.view = tabStrip
    tabs.isBordered = false
    tabs.isNavigational = true
    tabs.visibilityPriority = .high
    newTab.label = "New Tab"
    newTab.toolTip = "New Tab"
    newTab.image = MuxIcons.image("plus", "New Tab")
    // Plain glyphs beside the tabs, as the pane headers' actions are.
    newTab.isBordered = false
    newTab.target = self
    newTab.action = #selector(newTabClicked)
    sidebarControls.onNewTab = { [weak self] in self?.onNewTab?() }
    sidebarControls.onToggle = { [weak self] in self?.onToggleSidebar?() }
    sidebarControls.onInbox = { [weak self] in self?.onClick?() }
    item.label = "Inbox"
    item.paletteLabel = "Attention Inbox"
    item.toolTip = "Programs waiting for you, failures and results"
    item.image = MuxIcons.image("tray", "Attention inbox")
    item.isBordered = false
    item.target = self
    item.action = #selector(clicked)
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = false
  }

  func update(_ counts: InboxCounts) {
    sidebarControls.update(counts)
    item.badge = counts.needsYou > 0 ? .count(counts.needsYou) : nil
    item.image = MuxIcons.image(
      counts.needsYou + counts.results > 0 ? "tray.full" : "tray",
      "Attention inbox"
    )
    item.label = counts.needsYou > 0 ? "Inbox (\(counts.needsYou))" : "Inbox"
  }

  @objc
  private func clicked() { onClick?() }

  @objc
  private func newTabClicked() { onNewTab?() }

  func toolbar(
    _ toolbar: NSToolbar,
    itemForItemIdentifier id: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    switch id {
    case Self.tabsItem: tabs
    case Self.newTabItem: newTab
    case Self.inboxItem: item
    default: nil
    }
  }

  func toolbarDefaultItemIdentifiers(
    _ toolbar: NSToolbar
  ) -> [NSToolbarItem.Identifier] {
    [Self.tabsItem, .flexibleSpace, Self.newTabItem, Self.inboxItem]
  }

  func toolbarAllowedItemIdentifiers(
    _ toolbar: NSToolbar
  ) -> [NSToolbarItem.Identifier] {
    [Self.tabsItem, .flexibleSpace, Self.newTabItem, Self.inboxItem]
  }

  /// The items for where tabs show: the strip and New Tab for the top;
  /// none for the left, whose controls live in the sidebar (the toolbar
  /// hides).
  static func items(for position: TabPosition) -> [NSToolbarItem.Identifier] {
    switch position {
    case .top: [tabsItem, .flexibleSpace, newTabItem, inboxItem]
    case .left: []
    }
  }

  /// Replaces the toolbar's items with those for `position`.
  func show(_ position: TabPosition) {
    let wanted = Self.items(for: position)
    // Items still wanted stay put.
    for i in toolbar.items.indices.reversed()
    where !wanted.contains(toolbar.items[i].itemIdentifier) {
      toolbar.removeItem(at: i)
    }
    for (i, id) in wanted.enumerated()
    where toolbar.items.count <= i || toolbar.items[i].itemIdentifier != id {
      toolbar.insertItem(withItemIdentifier: id, at: i)
    }
  }
}

/// The sidebar toggle, the inbox and New Tab. Expanded, they make the
/// sidebar's top row: the toggle leading, the inbox and New Tab trailing.
/// Collapsed, the toggle and the inbox (nothing else opens it) sit at the
/// leading edge of the top-left pane's header.
@MainActor
final class MuxSidebarControls: NSView {
  static let buttonSize: CGFloat = 28
  static let spacing: CGFloat = 2
  let inboxButton = MuxSidebarControls.button("tray", "Attention Inbox")
  let newTabButton = MuxSidebarControls.button("plus", "New Tab")
  let toggleButton = MuxSidebarControls.button("sidebar.left", "Hide Sidebar")
  private let badge = NSTextField(labelWithString: "")
  private let stack = NSStackView()
  /// The count's place on the inbox button, made again whenever the
  /// button moves (moving a view drops its constraints).
  private var badgeConstraints: [NSLayoutConstraint] = []
  var onInbox: (() -> Void)?
  var onNewTab: (() -> Void)?
  var onToggle: (() -> Void)?
  var isCollapsed = false {
    didSet {
      guard isCollapsed != oldValue else { return }
      newTabButton.isHidden = isCollapsed
      let title = isCollapsed ? "Show Sidebar" : "Hide Sidebar"
      toggleButton.toolTip = title
      toggleButton.setAccessibilityLabel(title)
      arrange()
    }
  }

  private static func button(_ symbol: String, _ title: String) -> NSButton {
    let b = NSButton()
    b.image = MuxIcons.image(symbol, title)
    b.imagePosition = .imageOnly
    // Plain glyphs, as the toolbar's and pane headers' actions are.
    b.isBordered = false
    b.bezelStyle = .accessoryBarAction
    b.symbolConfiguration = .init(pointSize: 14, weight: .regular)
    b.contentTintColor = .secondaryLabelColor
    b.toolTip = title
    b.setAccessibilityLabel(title)
    b.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      b.widthAnchor.constraint(equalToConstant: buttonSize),
      b.heightAnchor.constraint(equalToConstant: buttonSize),
    ])
    return b
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    translatesAutoresizingMaskIntoConstraints = false
    for (b, action) in [
      (inboxButton, #selector(inboxClicked)),
      (newTabButton, #selector(newTabClicked)),
      (toggleButton, #selector(toggleClicked)),
    ] {
      b.target = self
      b.action = action
    }
    stack.orientation = .horizontal
    stack.spacing = Self.spacing
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.setHuggingPriority(.defaultHigh, for: .horizontal)
    addSubview(stack)
    badge.font = .systemFont(ofSize: 9, weight: .semibold)
    badge.textColor = .white
    badge.alignment = .center
    badge.wantsLayer = true
    badge.layer?.backgroundColor = NSColor.systemRed.cgColor
    badge.layer?.cornerRadius = 7
    badge.isHidden = true
    badge.setAccessibilityElement(false)
    badge.translatesAutoresizingMaskIntoConstraints = false
    addSubview(badge)
    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: Self.buttonSize),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
      badge.heightAnchor.constraint(equalToConstant: 14),
      badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 14),
    ])
    // The buttons join the view first: a constraint to a view outside it
    // throws.
    arrange()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  /// Expanded: the toggle leads and the inbox and New Tab trail. Collapsed:
  /// the toggle, then the inbox.
  private func arrange() {
    for v in stack.views { stack.removeView(v) }
    stack.addView(toggleButton, in: .leading)
    if isCollapsed {
      stack.addView(inboxButton, in: .leading)
    } else {
      stack.addView(inboxButton, in: .trailing)
      stack.addView(newTabButton, in: .trailing)
    }
    NSLayoutConstraint.deactivate(badgeConstraints)
    badgeConstraints = [
      badge.centerXAnchor.constraint(
        equalTo: inboxButton.trailingAnchor,
        constant: -4
      ),
      badge.centerYAnchor.constraint(
        equalTo: inboxButton.topAnchor,
        constant: 4
      ),
    ]
    NSLayoutConstraint.activate(badgeConstraints)
    invalidateIntrinsicContentSize()
  }

  /// Collapsed, the controls take only their buttons' width.
  override var intrinsicContentSize: NSSize {
    let shown: CGFloat = isCollapsed ? 2 : 3
    return NSSize(
      width: shown * Self.buttonSize + (shown - 1) * Self.spacing,
      height: Self.buttonSize
    )
  }

  func update(_ counts: InboxCounts) {
    inboxButton.image = MuxIcons.image(
      counts.needsYou + counts.results > 0 ? "tray.full" : "tray",
      "Attention inbox"
    )
    badge.stringValue = counts.needsYou > 99 ? "99+" : "\(counts.needsYou)"
    badge.isHidden = counts.needsYou == 0
    inboxButton.setAccessibilityLabel(
      counts.needsYou > 0
        ? "Attention Inbox, \(counts.needsYou) need you" : "Attention Inbox"
    )
  }

  /// Whether the count shows (tests).
  var badgeIsShown: Bool { !badge.isHidden }

  override var mouseDownCanMoveWindow: Bool { false }

  @objc
  private func inboxClicked() { onInbox?() }

  @objc
  private func newTabClicked() { onNewTab?() }

  @objc
  private func toggleClicked() { onToggle?() }
}
