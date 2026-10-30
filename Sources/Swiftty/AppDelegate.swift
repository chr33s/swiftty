import AppKit
import MuxNavigation
import SwiftMuxProtocol
import SwifttyCore
import SwifttyMac

/// One window type: every terminal window is a service-backed workspace,
/// and a plain shell is a workspace with one tab and one pane. Adding a
/// tab or splitting grows the same workspace; closing a window or quitting
/// detaches, and only the End commands terminate processes.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var config: Configuration
  let workspaces: WorkspaceCoordinator
  private let muxUpdate = MuxUpdateController()
  /// Connect a Device… (one panel; it owns the Bonjour registration).
  private var connectPanel: ConnectDevicePanelController?
  /// swiftty › Settings… (one window).
  private var settings: SettingsWindowController?
  private lazy var attentionLinks = AttentionLinkRouter(
    ownsWorkspace: { [weak self] id in
      self?.workspaces.controller(holding: id) != nil
    },
    reveal: { [weak self] target, lease in
      NSApp.activate()
      try await self?.workspaces.reveal(target, takeover: lease)
    }
  )

  init(
    listMuxWorkspaces:
      @escaping @MainActor () async throws -> WorkspaceListing = {
        try await MuxWorkspaceController.listing()
      },
    reportMuxAttachError: @escaping @MainActor (any Error) -> Void = {
      NSAlert(error: $0).runModal()
    },
    openMuxWorkspace: @escaping WorkspaceCoordinator.Open = {
      try await MuxWorkspaceController.open($0, configuration: $1, takeover: $2)
    },
    reportMuxOpenError: @escaping @MainActor (any Error) -> Void = {
      NSAlert(error: $0).runModal()
    }
  ) {
    let config = Configuration.load()
    self.config = config
    workspaces = WorkspaceCoordinator(
      configuration: config.accommodating(.current),
      listWorkspaces: listMuxWorkspaces,
      openWorkspace: openMuxWorkspace,
      reportListError: reportMuxAttachError,
      reportOpenError: reportMuxOpenError
    )
    super.init()
  }

  /// `swiftty://attention/open?ref=…` and configured Universal Links
  /// (spec.inbox.md §4). Other URLs are rejected without
  /// contacting anything.
  func application(_ application: NSApplication, open urls: [URL]) {
    // A burst of links: only the newest navigates.
    guard let url = urls.last else { return }
    attentionLinks.handle(url)
  }

  func application(
    _ application: NSApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
  ) -> Bool {
    guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
      let url = userActivity.webpageURL
    else { return false }
    attentionLinks.handle(url)
    return true
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(accommodationsChanged),
      name: DisplayAccommodations.didChangeNotification,
      object: nil
    )
    NSApp.mainMenu = makeMenu()
    workspaces.launch()
    NSApp.activate()
    reportProblems()
  }

  func applicationShouldTerminateAfterLastWindowClosed(
    _ sender: NSApplication
  ) -> Bool { true }

  /// Quit only detaches, every window: service-owned panes keep running
  /// and the agent stays registered.
  func applicationShouldTerminate(
    _ sender: NSApplication
  ) -> NSApplication.TerminateReply {
    // Quitting withdraws any discovery registration with the panel.
    connectPanel?.model.close()
    Task {
      await workspaces.terminate()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  // MARK: Workspaces

  /// New Workspace: a workspace with one shell, in its own window.
  @objc
  func newWorkspace(_ sender: Any?) { workspaces.create() }

  /// Open Workspace…: reveals or attaches an existing workspace.
  @objc
  func openWorkspace(_ sender: Any?) { workspaces.chooseWorkspace() }

  // MARK: SwiftMux service

  @objc
  func muxStageUpdate(_ sender: Any?) { muxUpdate.stage() }

  @objc
  func muxInstallUpdate(_ sender: Any?) {
    muxUpdate.install { [weak self] in
      await self?.workspaces.detachAll(closing: true)
    }
  }

  @objc
  func muxCancelUpdate(_ sender: Any?) { muxUpdate.cancel() }

  /// Connection details, pairing code and foreground discovery for
  /// phones and tablets (spec.connection-setup.md D2).
  @objc
  func connectDevice(_ sender: Any?) {
    let panel = connectPanel ?? ConnectDevicePanelController()
    connectPanel = panel
    panel.present()
  }

  // MARK: Configuration

  @objc
  func reloadConfiguration(_ sender: Any?) {
    reload()
    // An open Settings window lists the problems itself.
    if settings?.window?.isVisible != true { reportProblems() }
  }

  /// Re-reads the file and applies it everywhere, Settings included.
  private func reload() {
    config = Configuration.load()
    NSApp.mainMenu = makeMenu()
    workspaces.apply(config.accommodating(.current))
    settings?.model.refresh(config)
  }

  /// The native Settings window (spec.apple.md A01); its problems list
  /// replaces the alert while it is open.
  @objc
  func openSettings(_ sender: Any?) {
    let window =
      settings
      ?? SettingsWindowController(
        model: SettingsModel(
          url: Configuration.defaultURL,
          configuration: config,
          reload: { [weak self] in
            guard let self else { return Configuration.load() }
            reload()
            return config
          }
        ),
        editFile: { [weak self] in self?.openConfiguration(nil) }
      )
    settings = window
    window.model.refresh(config)
    window.present()
  }

  /// Reduce Motion, Reduce Transparency or Increase Contrast changed: the
  /// file is unchanged, only its presentation (spec.apple.md A05).
  @objc
  private func accommodationsChanged() {
    workspaces.apply(config.accommodating(.current))
  }

  @objc
  func openConfiguration(_ sender: Any?) {
    let url = Configuration.defaultURL
    if !FileManager.default.fileExists(atPath: url.path) {
      try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try? "# swiftty configuration (Ghostty syntax)\n"
        .write(to: url, atomically: true, encoding: .utf8)
    }
    NSWorkspace.shared.open(url)
  }

  /// Configuration errors, shown as a sheet on the front window.
  private func reportProblems() {
    let problems = config.problems
    guard !problems.isEmpty else { return }
    for problem in problems {
      FileHandle.standardError.write(Data("swiftty: \(problem)\n".utf8))
    }
    let alert = NSAlert()
    alert.messageText = "Configuration problems"
    alert.informativeText =
      problems.prefix(10).joined(separator: "\n")
      + (problems.count > 10 ? "\n…" : "")
    if let window = NSApp.keyWindow ?? workspaces.controllers.first?.window {
      alert.beginSheetModal(for: window)
    } else {
      alert.runModal()
    }
  }

  // MARK: Menus

  /// Workspace commands have no target: the responder chain delivers them
  /// to the focused window's controller, which validates them.
  private func makeMenu() -> NSMenu {
    let main = NSMenu()
    @discardableResult
    func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
      let item = NSMenuItem()
      let menu = NSMenu(title: title)
      items.forEach(menu.addItem)
      item.submenu = menu
      main.addItem(item)
      return menu
    }
    submenu(
      "swiftty",
      [
        item("Settings…", #selector(openSettings(_:)), key: ","),
        item(
          "Edit Configuration File…",
          #selector(openConfiguration(_:)),
          key: ",",
          modifiers: [.command, .option]
        ),
        item(
          "Reload Configuration",
          #selector(reloadConfiguration(_:)),
          key: ",",
          modifiers: [.command, .shift]
        ), .separator(), serviceMenuItem(), .separator(),
        item("Quit swiftty", #selector(NSApplication.terminate(_:)), key: "q"),
      ]
    )
    submenu("Workspace", workspaceMenuItems())
    submenu(
      "Edit",
      [
        item(
          "Copy",
          #selector(TerminalView.copy(_:)),
          action: .copyToClipboard
        ),
        item(
          "Paste",
          #selector(TerminalView.paste(_:)),
          action: .pasteFromClipboard
        ),
        item(
          "Select All",
          #selector(NSResponder.selectAll(_:)),
          action: .selectAll
        ),
        item(
          "Select Command Output",
          #selector(TerminalView.selectCommandOutput(_:))
        ), .separator(),
        item(
          "Find…",
          #selector(TerminalView.performFindPanelAction(_:)),
          action: .startSearch,
          tag: .showFindPanel
        ),
        item(
          "Find Next",
          #selector(TerminalView.performFindPanelAction(_:)),
          action: .navigateSearch(next: true),
          tag: .next
        ),
        item(
          "Find Previous",
          #selector(TerminalView.performFindPanelAction(_:)),
          action: .navigateSearch(next: false),
          tag: .previous
        ),
        item(
          "Use Selection for Find",
          #selector(TerminalView.performFindPanelAction(_:)),
          action: .searchSelection,
          tag: .setFindString,
        ),
      ]
    )
    submenu(
      "View",
      [
        item(
          "Bigger",
          #selector(TerminalView.increaseFontSize(_:)),
          action: .increaseFontSize(1)
        ),
        item(
          "Smaller",
          #selector(TerminalView.decreaseFontSize(_:)),
          action: .decreaseFontSize(1)
        ),
        item(
          "Reset Size",
          #selector(TerminalView.resetFontSize(_:)),
          action: .resetFontSize
        ), .separator(),
        item(
          "Previous Prompt",
          #selector(TerminalView.jumpToPreviousPrompt(_:)),
          action: .jumpToPrompt(-1)
        ),
        item(
          "Next Prompt",
          #selector(TerminalView.jumpToNextPrompt(_:)),
          action: .jumpToPrompt(1)
        ), .separator(),
        item(
          "Clear Screen",
          #selector(TerminalView.clearScreen(_:)),
          action: .clearScreen
        ),
        item(
          "Reset Terminal",
          #selector(TerminalView.resetTerminal(_:)),
          action: .reset
        ),
      ]
    )
    NSApp.windowsMenu = submenu("Window", windowMenuItems())
    return main
  }

  /// Helper management, apart from the terminal commands.
  private func serviceMenuItem() -> NSMenuItem {
    let service = NSMenuItem(
      title: "Terminal Service",
      action: nil,
      keyEquivalent: ""
    )
    service.submenu = NSMenu(title: "Terminal Service")
    service.submenu?
      .addItem(item("Connect a Device…", #selector(connectDevice(_:))))
    service.submenu?.addItem(.separator())
    for update in [
      item("Stage Update…", #selector(muxStageUpdate(_:))),
      item("Install Staged Update…", #selector(muxInstallUpdate(_:))),
      item("Cancel Update", #selector(muxCancelUpdate(_:))),
    ] { service.submenu?.addItem(update) }
    return service
  }

  /// Creating, opening, growing and ending workspaces. Close Window
  /// detaches; only the End items terminate processes.
  private func workspaceMenuItems() -> [NSMenuItem] {
    let workspace = MuxWorkspaceController.self
    return [
      item("New Workspace", #selector(newWorkspace(_:)), key: "n"),
      item("New Tab", #selector(workspace.newTerminalTab(_:)), key: "t"),
      item(
        "Open Workspace…",
        #selector(openWorkspace(_:)),
        key: "o",
        modifiers: [.command, .shift]
      ), .separator(),
      item("Split Right", #selector(workspace.splitRight(_:)), key: "d"),
      item(
        "Split Below",
        #selector(workspace.splitDown(_:)),
        key: "d",
        modifiers: [.command, .shift]
      ), .separator(),
      item("Rename Tab…", #selector(workspace.renameActiveTab(_:))),
      item(
        "Rename Workspace…",
        #selector(workspace.renameCurrentWorkspace(_:))
      ), .separator(),
      item("Close Window", #selector(NSWindow.performClose(_:)), key: "w"),
      item(
        "End Pane…",
        #selector(workspace.endActivePane(_:)),
        key: "w",
        modifiers: [.command, .option]
      ),
      item(
        "End Tab…",
        #selector(workspace.endActiveTab(_:)),
        key: "w",
        modifiers: [.command, .control]
      ), item("End Workspace…", #selector(workspace.endCurrentWorkspace(_:))),
    ]
  }

  private func windowMenuItems() -> [NSMenuItem] {
    let workspace = MuxWorkspaceController.self
    func arrow(_ key: Int) -> String {
      String(UnicodeScalar(UInt16(key)).map(Character.init) ?? " ")
    }
    let arrows = [
      ("Left", NSLeftArrowFunctionKey), ("Right", NSRightArrowFunctionKey),
      ("Up", NSUpArrowFunctionKey), ("Down", NSDownArrowFunctionKey),
    ]
    func directional(
      _ verb: String,
      _ selector: Selector,
      _ modifiers: NSEvent.ModifierFlags
    ) -> [NSMenuItem] {
      arrows.enumerated()
        .map { i, a in
          let menuItem = item(
            "\(verb) \(a.0)",
            selector,
            key: arrow(a.1),
            modifiers: modifiers
          )
          menuItem.tag = i
          return menuItem
        }
    }
    return [
      item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"),
      .separator(),
      item(
        "Next Tab",
        #selector(workspace.selectNextTab(_:)),
        key: "]",
        modifiers: [.command, .shift]
      ),
      item(
        "Previous Tab",
        #selector(workspace.selectPreviousTab(_:)),
        key: "[",
        modifiers: [.command, .shift]
      ),
      item(
        "Zoom Pane",
        #selector(workspace.toggleZoomPane(_:)),
        key: "\r",
        modifiers: [.command, .shift]
      ), .separator(),
    ]
      + directional(
        "Focus Pane",
        #selector(workspace.focusPaneInDirection(_:)),
        [.command, .option]
      ) + [.separator()]
      + directional(
        "Resize Pane",
        #selector(workspace.resizePaneInDirection(_:)),
        [.command, .control]
      ) + [.separator()]
  }

  private func item(
    _ title: String,
    _ selector: Selector,
    action: KeyAction? = nil,
    key: String = "",
    modifiers: NSEvent.ModifierFlags = .command,
    tag: NSFindPanelAction? = nil,
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
    if let action {
      if let trigger = config.keybindings.trigger(for: action),
        let equivalent = Self.keyEquivalent(trigger)
      {
        item.keyEquivalent = equivalent.key
        item.keyEquivalentModifierMask = equivalent.modifiers
      }
    } else {
      item.keyEquivalent = key
      item.keyEquivalentModifierMask = modifiers
    }
    if let tag { item.tag = Int(tag.rawValue) }
    return item
  }

  static func keyEquivalent(
    _ trigger: KeyTrigger
  ) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
    var mods: NSEvent.ModifierFlags = []
    if trigger.modifiers.contains(.command) { mods.insert(.command) }
    if trigger.modifiers.contains(.shift) { mods.insert(.shift) }
    if trigger.modifiers.contains(.control) { mods.insert(.control) }
    if trigger.modifiers.contains(.alt) { mods.insert(.option) }
    func function(_ key: Int) -> String {
      String(UnicodeScalar(UInt16(key)).map(Character.init) ?? " ")
    }
    let key: String? =
      switch trigger.key {
      case let .character(c): String(c)
      case .up: function(NSUpArrowFunctionKey)
      case .down: function(NSDownArrowFunctionKey)
      case .left: function(NSLeftArrowFunctionKey)
      case .right: function(NSRightArrowFunctionKey)
      case .home: function(NSHomeFunctionKey)
      case .end: function(NSEndFunctionKey)
      case .pageUp: function(NSPageUpFunctionKey)
      case .pageDown: function(NSPageDownFunctionKey)
      case .enter: "\r"
      case .tab: "\t"
      case .escape: "\u{1B}"
      case .backspace: "\u{8}"
      case .delete: function(NSDeleteFunctionKey)
      case let .function(n): function(NSF1FunctionKey + n - 1)
      case .insert, .keypad: nil
      }
    return key.map { ($0, mods) }
  }
}
