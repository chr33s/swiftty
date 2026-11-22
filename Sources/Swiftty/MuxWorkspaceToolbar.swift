import AppKit
import SwiftMuxProtocol
import SwifttyCore

/// Workspace tabs and actions in the native window toolbar.
@MainActor
final class MuxWorkspaceToolbar: NSObject, NSToolbarDelegate {
  static let tabsItem = NSToolbarItem.Identifier("swiftmux.tabs")
  static let newTabItem = NSToolbarItem.Identifier("swiftmux.new-tab")
  static let inboxItem = NSToolbarItem.Identifier("swiftmux.inbox")
  /// The inbox, New Tab and the sidebar toggle over the sidebar
  /// (`window.tabs` left).
  static let sidebarItem = NSToolbarItem.Identifier("swiftmux.sidebar")
  /// Each window's own: toolbars sharing an identifier mirror each
  /// other's item changes, and windows may show tabs in different places
  /// while a configuration change reaches them one by one.
  let toolbar = NSToolbar()
  let tabs = NSToolbarItem(itemIdentifier: tabsItem)
  let newTab = NSToolbarItem(itemIdentifier: newTabItem)
  let item = NSToolbarItem(itemIdentifier: inboxItem)
  let sidebar = NSToolbarItem(itemIdentifier: sidebarItem)
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
    newTab.target = self
    newTab.action = #selector(newTabClicked)
    sidebar.label = "Sidebar"
    sidebar.view = sidebarControls
    sidebar.isBordered = false
    sidebar.isNavigational = true
    sidebar.visibilityPriority = .high
    sidebarControls.onNewTab = { [weak self] in self?.onNewTab?() }
    sidebarControls.onToggle = { [weak self] in self?.onToggleSidebar?() }
    sidebarControls.onInbox = { [weak self] in self?.onClick?() }
    sidebarControls.onResize = { [weak self] in self?.remeasureSidebar() }
    item.label = "Inbox"
    item.paletteLabel = "Attention Inbox"
    item.toolTip = "Programs waiting for you, failures and results"
    item.image = MuxIcons.image("tray", "Attention inbox")
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
    case Self.sidebarItem: sidebar
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
    [
      Self.sidebarItem, Self.tabsItem, .flexibleSpace, Self.newTabItem,
      Self.inboxItem,
    ]
  }

  /// The items for where tabs show: the strip and New Tab for the top; the
  /// sidebar's controls (New Tab among them) for the left.
  static func items(for position: TabPosition) -> [NSToolbarItem.Identifier] {
    switch position {
    case .top: [tabsItem, .flexibleSpace, newTabItem, inboxItem]
    case .left: [sidebarItem, .flexibleSpace]
    }
  }

  /// Replaces the toolbar's items with those for `position`.
  func show(_ position: TabPosition) {
    let wanted = Self.items(for: position)
    // Items both positions show (the inbox) stay put.
    for i in toolbar.items.indices.reversed()
    where !wanted.contains(toolbar.items[i].itemIdentifier) {
      toolbar.removeItem(at: i)
    }
    for (i, id) in wanted.enumerated()
    where toolbar.items.count <= i || toolbar.items[i].itemIdentifier != id {
      toolbar.insertItem(withItemIdentifier: id, at: i)
    }
  }

  /// The toolbar measures an item's view once, as it is inserted: the
  /// controls, resized, go back in to be measured again.
  private func remeasureSidebar() {
    guard
      let index = toolbar.items.firstIndex(where: {
        $0.itemIdentifier == Self.sidebarItem
      })
    else { return }
    toolbar.removeItem(at: index)
    toolbar.insertItem(withItemIdentifier: Self.sidebarItem, at: index)
  }
}

/// The inbox, New Tab and the sidebar toggle, at the sidebar's trailing
/// edge beside the window controls. With the sidebar collapsed, the inbox
/// (and its count) and the toggle show, next to the window controls:
/// nothing else opens the inbox.
@MainActor
final class MuxSidebarControls: NSView {
  /// Space between the buttons and the sidebar's trailing edge.
  static let trailingInset: CGFloat = 8
  static let buttonSize: CGFloat = 30
  static let spacing: CGFloat = 6
  let inboxButton = MuxSidebarControls.button("tray", "Attention Inbox")
  let newTabButton = MuxSidebarControls.button("plus", "New Tab")
  let toggleButton = MuxSidebarControls.button("sidebar.left", "Hide Sidebar")
  private let badge = NSTextField(labelWithString: "")
  private let stack = NSStackView()
  var onInbox: (() -> Void)?
  var onNewTab: (() -> Void)?
  var onToggle: (() -> Void)?
  /// The width wanted changed: the toolbar must measure the view again.
  var onResize: (() -> Void)?
  /// The sidebar's width, whose trailing edge the buttons end at.
  var sidebarWidth: CGFloat = 220 { didSet { needsLayout = true } }
  var isCollapsed = false {
    didSet {
      guard isCollapsed != oldValue else { return }
      newTabButton.isHidden = isCollapsed
      let title = isCollapsed ? "Show Sidebar" : "Hide Sidebar"
      toggleButton.toolTip = title
      toggleButton.setAccessibilityLabel(title)
      fit()
    }
  }
  private var width: NSLayoutConstraint!
  /// Where the toolbar placed the controls, in the window: they reach from
  /// there to the sidebar's trailing edge.
  private var placedX: CGFloat?

  private static func button(_ symbol: String, _ title: String) -> NSButton {
    let b = NSButton()
    b.image = MuxIcons.image(symbol, title)
    b.imagePosition = .imageOnly
    b.bezelStyle = .glass
    b.borderShape = .circle
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
      stack.addArrangedSubview(b)
    }
    stack.orientation = .horizontal
    stack.spacing = Self.spacing
    stack.translatesAutoresizingMaskIntoConstraints = false
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
    width = widthAnchor.constraint(equalToConstant: Self.minimumWidth(false))
    NSLayoutConstraint.activate([
      width, heightAnchor.constraint(equalToConstant: Self.buttonSize),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
      badge.heightAnchor.constraint(equalToConstant: 14),
      badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 14),
      badge.centerXAnchor.constraint(
        equalTo: inboxButton.trailingAnchor,
        constant: -4
      ),
      badge.centerYAnchor.constraint(
        equalTo: inboxButton.topAnchor,
        constant: 4
      ),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  private static func minimumWidth(_ collapsed: Bool) -> CGFloat {
    let buttons: CGFloat = collapsed ? 2 : 3
    return buttons * buttonSize + (buttons - 1) * spacing
  }

  /// The width the controls want now (tests).
  var wantedWidth: CGFloat {
    let minimum = Self.minimumWidth(isCollapsed)
    guard !isCollapsed, let placedX else { return minimum }
    return max(minimum, sidebarWidth - Self.trailingInset - placedX)
  }

  /// Sizes the controls for where they sit, and has the toolbar measure
  /// them again if that changed.
  private func fit() {
    let wanted = wantedWidth
    guard abs(width.constant - wanted) > 0.5 else { return }
    width.constant = wanted
    // After the click or layout that got here: the item goes out and back.
    DispatchQueue.main.async { [weak self] in self?.onResize?() }
  }

  func update(_ counts: InboxCounts) {
    inboxButton.image = MuxIcons.image(
      counts.needsYou + counts.results > 0 ? "tray.full" : "tray",
      "Attention inbox"
    )
    badge.stringValue = counts.needsYou > 99 ? "99+" : "\(counts.needsYou)"
    needsYou = counts.needsYou
    refreshBadge()
    inboxButton.setAccessibilityLabel(
      counts.needsYou > 0
        ? "Attention Inbox, \(counts.needsYou) need you" : "Attention Inbox"
    )
  }

  private var needsYou = 0
  /// Whether the count shows (tests).
  var badgeIsShown: Bool { !badge.isHidden }

  /// The count shows on the inbox button, collapsed or not.
  private func refreshBadge() { badge.isHidden = needsYou == 0 }

  override var mouseDownCanMoveWindow: Bool { false }

  override func layout() {
    super.layout()
    // The toolbar places the controls after the window controls; measure our
    // own origin (and any trailing overhang on the toggle button) once the
    // toolbar item viewer is at least as wide as us, so any viewer padding
    // between macOS versions is accounted for.
    guard window != nil, let viewer = superview,
      bounds.width <= viewer.bounds.width + 0.5
    else { return }
    let trailingOffset =
      toggleButton.bounds.width > 0
      ? toggleButton.convert(toggleButton.bounds, to: self).maxX - bounds.maxX
      : 0
    let x = convert(NSPoint.zero, to: nil).x + trailingOffset
    guard placedX.map({ abs($0 - x) > 0.5 }) ?? true else { return }
    placedX = x
    fit()
  }

  @objc
  private func inboxClicked() { onInbox?() }

  @objc
  private func newTabClicked() { onNewTab?() }

  @objc
  private func toggleClicked() { onToggle?() }
}
