import AppKit
import SwiftMuxProtocol
@testable import Swiftty
import SwifttyCore
import Testing

extension MuxNativeTests {
  @Test(.enabled(if: hasMetal))
  func `workspace toolbar hosts tabs and dispatches native actions`()
    async throws
  {
    let f = try await open()
    defer { f.controller.close() }
    let c = f.controller
    let window = try #require(c.window)
    c.confirmDestructive = { _ in true }
    let toolbar = c.workspaceToolbar
    let firstTab = try #require(c.activeTab?.id)
    #expect(window.toolbar === toolbar.toolbar)
    #expect(window.toolbarStyle == .unifiedCompact)
    #expect(toolbar.tabs.view === c.tabStrip)
    #expect(
      toolbar.toolbar.items.map(\.itemIdentifier) == [
        MuxWorkspaceToolbar.tabsItem, .flexibleSpace,
        MuxWorkspaceToolbar.newTabItem, MuxWorkspaceToolbar.inboxItem,
      ]
    )
    // One tab: the title shows instead of a strip with one choice, and
    // the new-tab and inbox actions stay.
    #expect(!c.showsTabStrip)
    #expect(window.titleVisibility == .visible)
    let action = try #require(toolbar.newTab.action)
    #expect(
      NSApp.sendAction(action, to: toolbar.newTab.target, from: toolbar.newTab)
    )
    #expect(await until { c.workspace?.tabs.count == 2 })
    #expect(c.showsTabStrip)
    #expect(window.titleVisibility == .hidden)
    window.contentView?.superview?.layoutSubtreeIfNeeded()
    let tabsRect = c.tabStrip.convert(c.tabStrip.bounds, to: nil)
    let panesRect = c.layoutView.convert(c.layoutView.bounds, to: nil)
    #expect(tabsRect.minY >= panesRect.maxY)
    #expect(abs(panesRect.maxY - window.contentLayoutRect.maxY) < 1)
    #expect(c.tabStrip.bounds.width >= 102)
    #expect(toolbar.tabs.isVisible)
    #expect(toolbar.newTab.isVisible && toolbar.item.isVisible)
    let firstButton = try #require(c.tabStrip.buttons.first)
    #expect(!firstButton.mouseDownCanMoveWindow)
    let frameView = try #require(window.contentView?.superview)
    let point = firstButton.convert(NSPoint(x: 20, y: 12), to: frameView)
    #expect(frameView.hitTest(point)?.isDescendant(of: firstButton) == true)

    let secondTab = try #require(c.activeTab?.id)
    #expect(secondTab != firstTab)
    c.tabStrip.onSelect?(firstTab)
    #expect(await until { c.activeTab?.id == firstTab })
    c.tabStrip.onRename?(firstTab, "Renamed")
    #expect(await until { c.activeTab?.name == "Renamed" })
    // Editing starts from the stored name. A refused rename keeps the
    // stored title on the label and says why until a rename lands.
    let named = try #require(
      c.tabStrip.buttons.first { $0.item?.id == firstTab }
    )
    #expect(await until { named.item?.name == "Renamed" })
    named.beginRename()
    #expect(named.label.stringValue == "Renamed")
    await commit(window, String(repeating: "x", count: 300), on: named)
    #expect(await until { window.subtitle.hasPrefix("Tab not renamed: ") })
    #expect(await until { named.label.stringValue == "Renamed" })
    // A second rename request keeps the edit already open.
    named.beginRename()
    type(" Again ", into: named)
    named.beginRename()
    #expect(named.label.currentEditor()?.string == " Again ")
    await commit(window, " Again ", on: named)
    #expect(await until { c.activeTab?.name == "Again" })
    let onRename = c.tabStrip.onRename
    let log = RenameLog()
    c.tabStrip.onRename = { tab, name in
      log.tabs.append(tab)
      log.names.append(name)
    }
    try await checkRenameCommits(c, window, named, firstTab: firstTab, log: log)
    try await checkRenameFocusLoss(
      c,
      window,
      named,
      secondTab: secondTab,
      log: log
    )
    c.tabStrip.onRename = onRename
    let secondButton = try #require(
      c.tabStrip.buttons.first { $0.item?.id == secondTab }
    )
    secondButton.closeButton.performClick(nil)
    #expect(await until { c.workspace?.tabs.count == 1 })

    let originalFrame = window.frame
    for opacity in [1.0, 0.8] {
      var configuration = Configuration()
      configuration.backgroundOpacity = opacity
      c.apply(configuration)
      window.contentView?.superview?.layoutSubtreeIfNeeded()
      #expect(window.frame == originalFrame)
      #expect(window.toolbar === toolbar.toolbar)
      #expect(c.tabStrip.window === window)
      #expect(
        c.tabStrip.convert(c.tabStrip.bounds, to: nil).minY
          >= c.layoutView.convert(c.layoutView.bounds, to: nil).maxY
      )
    }
    let inboxAction = try #require(toolbar.item.action)
    #expect(
      NSApp.sendAction(inboxAction, to: toolbar.item.target, from: toolbar.item)
    )
    #expect(c.inboxView?.view.window != nil)
    c.toggleInbox()
    // Tab out of the search field never lands on, and activates, a pane.
    c.split(.leftRight)
    #expect(await until { c.views.count == 2 })
    let focused = c.activePane
    c.showSearch()
    let searching = try #require(
      c.searchBar?.field.currentEditor() as? NSTextView
    )
    searching.doCommand(by: #selector(NSResponder.insertTab(_:)))
    try await Task.sleep(for: .milliseconds(100))
    #expect(c.activePane == focused)
    #expect(
      !(window.firstResponder is MuxPaneView)
        || window.firstResponder === focused.flatMap { c.views[$0] }
    )
    c.hideSearch()
  }

  /// Types `text` into the open edit and presses Return; keys go back to
  /// the active pane whether or not it renamed.
  func commit(_ window: NSWindow, _ text: String, on button: MuxTabButton) async
  {
    type(text, into: button)
    guard let editor = button.label.currentEditor() as? NSTextView else {
      return
    }
    editor.insertNewline(nil)
    #expect(await until { window.firstResponder is MuxPaneView })
  }

  /// Commits, unchanged edits, aborts, hidden and minimized windows, and
  /// another window taking the keys.
  func checkRenameCommits(
    _ c: MuxWorkspaceController,
    _ window: NSWindow,
    _ named: MuxTabButton,
    firstTab: TabID,
    log: RenameLog
  ) async throws {
    // An unchanged edit renames nothing, nor does Return with no typing.
    named.beginRename()
    await commit(window, "Again", on: named)
    #expect(log.tabs.isEmpty)
    named.beginRename()
    let untyped = try #require(named.label.currentEditor() as? NSTextView)
    untyped.string = "Other"
    untyped.insertNewline(nil)
    #expect(log.tabs.isEmpty)
    #expect(!named.label.isSelectable)
    // An aborted edit ends the rename and gives keys back to the pane.
    named.beginRename()
    type("half", into: named)
    named.label.abortEditing()
    #expect(await until { window.firstResponder is MuxPaneView })
    #expect(log.tabs.isEmpty)
    named.beginRename()
    #expect(named.label.stringValue == "Again")
    await commit(window, "Fourth", on: named)
    #expect(log.tabs == [firstTab])
    // A window out of sight opens no rename.
    window.orderOut(nil)
    named.beginRename()
    #expect(named.label.currentEditor() == nil)
    #expect(!named.label.isEditable)
    window.makeKeyAndOrderFront(nil)
    // Another of the app's windows taking the keys ends the edit (typed
    // text renames), and keys go back to the active pane; a floating panel
    // serving it does not, while another panel (a popover) does.
    named.beginRename()
    type("Keyed", into: named)
    let frame = NSRect(x: 0, y: 0, width: 80, height: 60)
    func panel(floating: Bool) -> NSPanel {
      let panel = NSPanel(
        contentRect: frame,
        styleMask: [.titled],
        backing: .buffered,
        defer: true
      )
      panel.isFloatingPanel = floating
      return panel
    }
    let center = NotificationCenter.default
    center.post(
      name: NSWindow.didBecomeKeyNotification,
      object: panel(floating: true)
    )
    #expect(named.label.currentEditor() != nil)
    center.post(
      name: NSWindow.didBecomeKeyNotification,
      object: panel(floating: false)
    )
    #expect(named.label.currentEditor() == nil)
    #expect(log.names.last == "Keyed")
    #expect(await until { window.firstResponder is MuxPaneView })
    // A minimized window comes back, in front, for a rename.
    window.miniaturize(nil)
    #expect(await until { window.isMiniaturized })
    named.beginRename()
    #expect(await until { !window.isMiniaturized })
    #expect(window.isVisible)
    // (Key status cannot be checked here: the test runner's app is
    // inactive.) The restored edit takes typing and renames.
    await commit(window, "Restored", on: named)
    #expect(log.names.last == "Restored")
  }

  /// Losing focus renames to the typed text; an unnamed tab's edit starts
  /// empty.
  func checkRenameFocusLoss(
    _ c: MuxWorkspaceController,
    _ window: NSWindow,
    _ named: MuxTabButton,
    secondTab: TabID,
    log: RenameLog
  ) async throws {
    // Losing focus renames to the typed text: a click elsewhere (whose
    // focus stays), Tab, the toolbar hiding, the search field taking focus,
    // or the field moving to another window. Keys go back to the active
    // pane when they would otherwise reach nothing; Tab reaches the next
    // key view (a toolbar control with Full Keyboard Access), never a pane.
    let elsewhere = FocusableView()
    window.contentView?.addSubview(elsewhere)
    named.beginRename()
    type("Clicked", into: named)
    window.makeFirstResponder(elsewhere)
    try await Task.sleep(for: .milliseconds(100))
    #expect(window.firstResponder === elsewhere)
    elsewhere.removeFromSuperview()
    named.beginRename()
    type("Tabbed", into: named)
    let editor = try #require(named.label.currentEditor() as? NSTextView)
    editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
    try await Task.sleep(for: .milliseconds(100))
    let active = try #require(c.activePane.flatMap { c.views[$0] })
    // The active pane, or a key view that is not a pane; never nothing
    // (the window, a field editor left open, or a tab title).
    let next = window.firstResponder
    #expect(
      next === active
        || (next is NSView && !(next is MuxPaneView) && !(next is NSText)
          && !(next is MuxTabLabel))
    )
    named.beginRename()
    type("Hidden", into: named)
    window.toolbar?.isVisible = false
    try await Task.sleep(for: .milliseconds(100))
    #expect(window.firstResponder is MuxPaneView)
    window.toolbar?.isVisible = true
    named.beginRename()
    type("Searched", into: named)
    c.showSearch()
    try await Task.sleep(for: .milliseconds(100))
    let search = try #require(c.searchBar?.field.currentEditor())
    #expect(window.firstResponder === search)
    c.hideSearch()
    #expect(window.firstResponder is MuxPaneView)
    named.beginRename()
    type("Moved", into: named)
    named.viewWillMove(toWindow: nil)
    #expect(
      log.names.suffix(5) == [
        "Clicked", "Tabbed", "Hidden", "Searched", "Moved",
      ]
    )
    #expect(await until { window.firstResponder is MuxPaneView })
    #expect(named.label.stringValue == "Again")
    #expect(await until { window.subtitle.isEmpty })
    let secondButton = try #require(
      c.tabStrip.buttons.first { $0.item?.id == secondTab }
    )
    // An unnamed tab's edit starts empty, its program's title shown as a
    // placeholder; clearing it renames nothing.
    secondButton.beginRename()
    #expect(secondButton.label.stringValue.isEmpty)
    #expect(secondButton.label.placeholderString == secondButton.item?.title)
    type("x", into: secondButton)
    await commit(window, "", on: secondButton)
    #expect(log.names.count == 8)
    #expect(secondButton.label.stringValue == secondButton.item?.title)
    #expect(secondButton.label.placeholderString == nil)
  }

  @Test(.enabled(if: hasMetal))
  func `tabs move between the toolbar and a left sidebar`() async throws {
    let f = try await open()
    defer { f.controller.close() }
    let c = f.controller
    let window = try #require(c.window)
    let toolbar = c.workspaceToolbar
    c.newTab()
    try #require(await until { c.workspace?.tabs.count == 2 })
    var configuration = Configuration()
    configuration.tabPosition = .left
    c.apply(configuration)
    window.contentView?.superview?.layoutSubtreeIfNeeded()
    #expect(c.tabPosition == .left)
    #expect(c.showsTabStrip)
    #expect(c.tabStrip.isVertical)
    #expect(c.tabStrip.superview === c.tabSidebar)
    #expect(toolbar.tabs.view == nil)
    #expect(
      toolbar.toolbar.items.map(\.itemIdentifier) == [
        MuxWorkspaceToolbar.sidebarItem, .flexibleSpace,
      ]
    )
    #expect(window.titleVisibility == .hidden)
    // The sidebar sits beside the panes, which show in a rounded card;
    // rows stack top down, full width.
    let sidebar = c.tabSidebar.convert(c.tabSidebar.bounds, to: nil)
    let panes = c.layoutView.convert(c.layoutView.bounds, to: nil)
    #expect(abs(sidebar.maxX - panes.minX) < 1)
    #expect(c.panesInCard)
    #expect(c.layoutView.layer?.cornerRadius == MuxPaneContainer.cornerRadius)
    let content = c.workspaceContent.convert(c.workspaceContent.bounds, to: nil)
    let margin = MuxWorkspaceController.cardMargin
    #expect(abs(content.maxX - panes.maxX - margin) < 1)
    #expect(abs(sidebar.width - MuxTabSidebar.width) < 1)
    #expect(c.tabStrip.buttons.count == 2)
    let rows = c.tabStrip.buttons.map { $0.convert($0.bounds, to: nil) }
    #expect(rows[0].minY > rows[1].maxY)
    #expect(rows.allSatisfy { $0.height == MuxTabButton.columnHeight })
    #expect(rows.allSatisfy { $0.width > MuxTabSidebar.width - 30 })
    // Selecting and renaming work the same from the sidebar.
    let first = try #require(c.tabStrip.buttons.first?.item?.id)
    c.tabStrip.onSelect?(first)
    #expect(await until { c.activeTab?.id == first })
    c.tabStrip.onRename?(first, "Named")
    #expect(await until { c.tabStrip.buttons.first?.item?.name == "Named" })
    let named = try #require(c.tabStrip.buttons.first)
    #expect(!named.detailText.isEmpty)
    // The active row's glass holds its title (glass draws over siblings);
    // other rows show no glass, their title directly.
    #expect(named.showsGlass && named.titleIsInGlass)
    let other = try #require(c.tabStrip.buttons.last)
    #expect(!other.showsGlass && other.label.window === window)
    #expect(other.label.isDescendant(of: other))
    // Back to the toolbar.
    c.apply(Configuration())
    window.contentView?.superview?.layoutSubtreeIfNeeded()
    #expect(c.tabPosition == .top)
    #expect(!c.tabStrip.isVertical)
    #expect(toolbar.tabs.view === c.tabStrip)
    #expect(c.tabSidebar.isHidden)
    #expect(
      toolbar.toolbar.items.map(\.itemIdentifier) == [
        MuxWorkspaceToolbar.tabsItem, .flexibleSpace,
        MuxWorkspaceToolbar.newTabItem, MuxWorkspaceToolbar.inboxItem,
      ]
    )
    #expect(c.showsTabStrip)
    #expect(window.titleVisibility == .hidden)
    #expect(
      c.tabStrip.buttons.allSatisfy { $0.showsGlass && $0.titleIsInGlass }
    )
    let panesAfter = c.layoutView.convert(c.layoutView.bounds, to: nil)
    #expect(abs(panesAfter.minX) < 1)
    #expect(!c.panesInCard)
  }

  @Test(.enabled(if: hasMetal))
  func `the sidebar toggle hides and shows the left tabs`() async throws {
    let f = try await open()
    defer { f.controller.close() }
    let c = f.controller
    let window = try #require(c.window)
    let controls = c.workspaceToolbar.sidebarControls
    c.newTab()
    try #require(await until { c.workspace?.tabs.count == 2 })
    var configuration = Configuration()
    configuration.tabPosition = .left
    c.apply(configuration)
    try await settle(window)
    // Expanded: the inbox, New Tab and the toggle end at the sidebar's
    // trailing edge, and clicks there reach them (the toolbar measured the
    // controls at their final width).
    #expect(!controls.newTabButton.isHidden)
    let toggle = controls.toggleButton.convert(
      controls.toggleButton.bounds,
      to: nil
    )
    #expect(
      abs(
        toggle.maxX - (MuxTabSidebar.width - MuxSidebarControls.trailingInset)
      ) < 2
    )
    for b in [
      controls.inboxButton, controls.newTabButton, controls.toggleButton,
    ] { #expect(receivesClicks(b, in: window)) }
    // The inbox opens from its button over the sidebar.
    controls.inboxButton.performClick(nil)
    #expect(c.inboxView?.view.window != nil)
    c.toggleInbox()
    let newTab = try #require(controls.newTabButton.action)
    #expect(
      NSApp.sendAction(newTab, to: controls.newTabButton.target, from: nil)
    )
    #expect(await until { c.workspace?.tabs.count == 3 })
    // Collapsed: the sidebar and New Tab hide; the inbox and the toggle
    // sit beside the window controls and the card takes the sidebar's
    // place.
    let action = try #require(controls.toggleButton.action)
    #expect(
      NSApp.sendAction(action, to: controls.toggleButton.target, from: nil)
    )
    window.contentView?.superview?.layoutSubtreeIfNeeded()
    controls.layoutSubtreeIfNeeded()
    #expect(c.sidebarCollapsed)
    #expect(c.tabSidebar.isHidden && !c.showsTabStrip)
    try await settle(window)
    // The inbox (nothing else opens it) and the toggle show, beside the
    // window controls.
    #expect(controls.newTabButton.isHidden)
    #expect(!controls.inboxButton.isHidden && !controls.toggleButton.isHidden)
    let collapsed = controls.inboxButton.convert(
      controls.inboxButton.bounds,
      to: nil
    )
    let zoom = try #require(window.standardWindowButton(.zoomButton))
    #expect(collapsed.minX > zoom.convert(zoom.bounds, to: nil).maxX)
    #expect(
      controls.bounds.width
        == 2 * MuxSidebarControls.buttonSize + MuxSidebarControls.spacing
    )
    for b in [controls.inboxButton, controls.toggleButton] {
      #expect(receivesClicks(b, in: window))
    }
    // Its count stays in view.
    c.workspaceToolbar.update(InboxCounts(needsYou: 2, results: 0))
    #expect(controls.badgeIsShown)
    controls.inboxButton.performClick(nil)
    #expect(c.inboxView?.view.window != nil)
    c.toggleInbox()
    let panes = c.layoutView.convert(c.layoutView.bounds, to: nil)
    #expect(abs(panes.minX - MuxWorkspaceController.cardMargin) < 1)
    #expect(c.panesInCard)
    // Clicking it again reopens the drawer.
    #expect(
      NSApp.sendAction(action, to: controls.toggleButton.target, from: nil)
    )
    window.contentView?.superview?.layoutSubtreeIfNeeded()
    #expect(!c.sidebarCollapsed && c.showsTabStrip)
    #expect(!controls.newTabButton.isHidden && !controls.inboxButton.isHidden)
    let reopened = c.layoutView.convert(c.layoutView.bounds, to: nil)
    #expect(abs(reopened.minX - MuxTabSidebar.width) < 1)
    try await settle(window)
    #expect(receivesClicks(controls.newTabButton, in: window))
  }

  /// Lets the toolbar place and measure its items again.
  private func settle(_ window: NSWindow) async throws {
    for _ in 0 ..< 3 {
      window.contentView?.superview?.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(50))
    }
  }

  /// A click at the middle of `button` reaches it.
  private func receivesClicks(_ button: NSButton, in window: NSWindow) -> Bool {
    guard let frameView = window.contentView?.superview else { return false }
    let rect = button.convert(button.bounds, to: nil)
    let point = frameView.convert(
      NSPoint(x: rect.midX, y: rect.midY),
      from: nil
    )
    return frameView.hitTest(point)?.isDescendant(of: button) == true
  }

  @Test(.enabled(if: hasMetal))
  func `narrow workspace toolbars retain actions and scroll to the active tab`()
    async throws
  {
    let f = try await open()
    defer { f.controller.close() }
    let strip = f.controller.tabStrip
    let toolbar = f.controller.workspaceToolbar
    let window = try #require(f.controller.window)
    // The strip shows once the workspace has more than one tab.
    f.controller.newTab()
    try #require(await until { f.controller.showsTabStrip })
    window.setContentSize(NSSize(width: 420, height: 200))
    let items = (0 ..< 12)
      .map { index in
        MuxTabItem(
          id: TabID(),
          title: "Workspace tab \(index)",
          symbol: "terminal",
          isActive: index == 11,
          hasActivity: false
        )
      }
    strip.update(items)
    window.contentView?.superview?.layoutSubtreeIfNeeded()
    strip.update(items)
    #expect(toolbar.tabs.isVisible)
    #expect(toolbar.newTab.isVisible && toolbar.item.isVisible)
    #expect(strip.bounds.width < strip.intrinsicContentSize.width)
    let active = try #require(strip.buttons.last)
    let visible = active.visibleRect
    #expect(visible.width > 0)
    #expect(visible.height == active.bounds.height)
    #expect(visible.contains(active.bounds))
    #expect(active.closeButton.visibleRect.contains(active.closeButton.bounds))
    // A tab keeps its button, and a rename open on it, when an earlier tab
    // goes.
    active.beginRename()
    #expect(active.label.currentEditor() != nil)
    strip.update(Array(items.dropFirst()))
    #expect(strip.buttons.count == 11)
    #expect(strip.buttons.last === active)
    #expect(active.label.currentEditor() != nil)
    // Moving the tab being renamed keeps the edit with it.
    let rest = Array(items.dropFirst())
    let moving = strip.buttons[1]
    window.makeFirstResponder(nil)
    moving.beginRename()
    strip.update([rest[1], rest[0]] + rest.dropFirst(2))
    #expect(strip.buttons[0] === moving)
    #expect(moving.label.currentEditor() != nil)
    window.makeFirstResponder(nil)
    // A rename open on a tab that goes ends with it, without renaming,
    // even when its button serves a new tab.
    let (onRename, onRenameEnded) = (strip.onRename, strip.onRenameEnded)
    var renamed: [TabID] = []
    var ended = 0
    strip.onRename = { tab, _ in renamed.append(tab) }
    strip.onRenameEnded = { ended += 1 }
    active.beginRename()
    type("typed", into: active)
    var replaced = rest
    replaced[replaced.count - 1] = MuxTabItem(
      id: TabID(),
      title: "New tab",
      symbol: "terminal",
      isActive: true,
      hasActivity: false
    )
    strip.update(replaced)
    #expect(strip.buttons.last === active)
    #expect(active.label.currentEditor() == nil)
    #expect(!active.label.isEditable)
    #expect(active.label.stringValue == "New tab")
    #expect(renamed.isEmpty)
    #expect(ended == 1)
    // Escape cancels a rename the same way.
    active.beginRename()
    type("typed", into: active)
    let editor = try #require(active.label.currentEditor() as? NSTextView)
    editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
    #expect(active.label.currentEditor() == nil)
    #expect(active.label.stringValue == "New tab")
    #expect(renamed.isEmpty)
    #expect(ended == 2)
    // A rename open on a tab that goes, its button removed, ends without
    // renaming too.
    active.beginRename()
    type("typed", into: active)
    strip.update(Array(replaced.dropLast()))
    #expect(active.superview == nil)
    #expect(!strip.buttons.contains { $0 === active })
    #expect(renamed.isEmpty)
    #expect(ended == 3)
    strip.onRename = onRename
    strip.onRenameEnded = onRenameEnded
  }
}

/// A view that takes focus, standing in for anywhere a click may move it.
private final class FocusableView: NSView {
  override var acceptsFirstResponder: Bool { true }
}

/// Tab renames recorded by a test's `onRename`.
@MainActor
final class RenameLog {
  var tabs: [TabID] = []
  var names: [String] = []
}

/// Types `text` into `button`'s open rename as a person would (an edit
/// counts only once its text changes).
@MainActor
private func type(_ text: String, into button: MuxTabButton) {
  guard let editor = button.label.currentEditor() as? NSTextView else {
    Issue.record("no rename open")
    return
  }
  editor.selectAll(nil)
  if text.isEmpty {
    editor.deleteBackward(nil)
  } else {
    editor.insertText(text, replacementRange: editor.selectedRange())
  }
}
