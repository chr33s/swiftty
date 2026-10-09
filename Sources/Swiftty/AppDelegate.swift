import AppKit
import SwifttyCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [TerminalWindowController] = []
    private var config = Configuration.load()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMenu()
        newWindow(nil)
        NSApp.activate()
        reportProblems()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc func newWindow(_ sender: Any?) {
        do {
            let controller = try TerminalWindowController(configuration: config)
            controller.onClose = { [weak self, weak controller] in
                self?.windows.removeAll { $0 === controller }
            }
            windows.append(controller)
            controller.showWindow(nil)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc func reloadConfiguration(_ sender: Any?) {
        config = Configuration.load()
        NSApp.mainMenu = makeMenu()
        for window in windows {
            window.apply(config)
        }
        reportProblems()
    }

    @objc func openConfiguration(_ sender: Any?) {
        let url = Configuration.defaultURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "# swiftty configuration (Ghostty syntax)\n".write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }

    /// Configuration errors, shown as a sheet on the front window.
    private func reportProblems() {
        let problems = config.diagnostics + config.missingThemes.map { "theme not found: \($0)" }
        guard !problems.isEmpty else { return }
        for problem in problems {
            FileHandle.standardError.write(Data("swiftty: \(problem)\n".utf8))
        }
        let alert = NSAlert()
        alert.messageText = "Configuration problems"
        alert.informativeText = problems.prefix(10).joined(separator: "\n") + (problems.count > 10 ? "\n…" : "")
        if let window = NSApp.keyWindow ?? windows.first?.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: Menus

    private func makeMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem()
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }
        submenu("swiftty", [
            item("Settings…", #selector(openConfiguration(_:)), key: ","),
            item("Reload Configuration", #selector(reloadConfiguration(_:)), key: ",", modifiers: [.command, .shift]),
            .separator(),
            item("Quit swiftty", #selector(NSApplication.terminate(_:)), key: "q"),
        ])
        submenu("Shell", [
            item("New Window", #selector(newWindow(_:)), key: "n"),
            item("Close", #selector(NSWindow.performClose(_:)), key: "w"),
        ])
        submenu("Edit", [
            item("Copy", #selector(TerminalView.copy(_:)), action: .copyToClipboard),
            item("Paste", #selector(TerminalView.paste(_:)), action: .pasteFromClipboard),
            item("Select All", #selector(NSResponder.selectAll(_:)), action: .selectAll),
            item("Select Command Output", #selector(TerminalView.selectCommandOutput(_:))),
            .separator(),
            item("Find…", #selector(TerminalView.performFindPanelAction(_:)), action: .startSearch, tag: .showFindPanel),
            item("Find Next", #selector(TerminalView.performFindPanelAction(_:)), action: .navigateSearch(next: true), tag: .next),
            item("Find Previous", #selector(TerminalView.performFindPanelAction(_:)), action: .navigateSearch(next: false), tag: .previous),
            item(
                "Use Selection for Find",
                #selector(TerminalView.performFindPanelAction(_:)),
                action: .searchSelection,
                tag: .setFindString,
            ),
        ])
        submenu("View", [
            item("Bigger", #selector(TerminalView.increaseFontSize(_:)), action: .increaseFontSize(1)),
            item("Smaller", #selector(TerminalView.decreaseFontSize(_:)), action: .decreaseFontSize(1)),
            item("Reset Size", #selector(TerminalView.resetFontSize(_:)), action: .resetFontSize),
            .separator(),
            item("Previous Prompt", #selector(TerminalView.jumpToPreviousPrompt(_:)), action: .jumpToPrompt(-1)),
            item("Next Prompt", #selector(TerminalView.jumpToNextPrompt(_:)), action: .jumpToPrompt(1)),
            .separator(),
            item("Clear Screen", #selector(TerminalView.clearScreen(_:)), action: .clearScreen),
            item("Reset Terminal", #selector(TerminalView.resetTerminal(_:)), action: .reset),
        ])
        return main
    }

    /// A menu item whose shortcut is whatever `action` is bound to (the
    /// view's key bindings handle the key itself; this only shows it).
    private func item(
        _ title: String, _ selector: Selector, action: KeyAction? = nil, key: String = "",
        modifiers: NSEvent.ModifierFlags = .command, tag: NSFindPanelAction? = nil,
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        if let action {
            if let trigger = config.keybindings.trigger(for: action), let equivalent = Self.keyEquivalent(trigger) {
                item.keyEquivalent = equivalent.key
                item.keyEquivalentModifierMask = equivalent.modifiers
            }
        } else {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = modifiers
        }
        if let tag {
            item.tag = Int(tag.rawValue)
        }
        return item
    }

    static func keyEquivalent(_ trigger: KeyTrigger) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        var mods: NSEvent.ModifierFlags = []
        if trigger.modifiers.contains(.command) {
            mods.insert(.command)
        }
        if trigger.modifiers.contains(.shift) {
            mods.insert(.shift)
        }
        if trigger.modifiers.contains(.control) {
            mods.insert(.control)
        }
        if trigger.modifiers.contains(.alt) {
            mods.insert(.option)
        }
        func function(_ key: Int) -> String {
            String(UnicodeScalar(UInt16(key)).map(Character.init) ?? " ")
        }
        let key: String? = switch trigger.key {
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
        case .insert: nil
        }
        return key.map { ($0, mods) }
    }
}

@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let terminal: TerminalView
    private lazy var searchFieldEditor: SearchFieldEditor = {
        let editor = SearchFieldEditor(frame: .zero)
        editor.isFieldEditor = true
        editor.terminal = terminal
        return editor
    }()

    init(configuration: Configuration, columns: Int = 100, rows: Int = 30) throws {
        terminal = try TerminalView(configuration: configuration)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: terminal.preferredSize(columns: columns, rows: rows)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false,
        )
        window.title = "swiftty"
        window.center()
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        applyBackground(configuration)
        window.makeFirstResponder(terminal)
        terminal.onTitle = { [weak window] title in window?.title = title }
        terminal.onExit = { [weak window] in window?.close() }
        try terminal.start()
    }

    @available(*, unavailable) required init?(coder: NSCoder) {
        fatalError()
    }

    func apply(_ configuration: Configuration) {
        terminal.apply(configuration)
        applyBackground(configuration)
    }

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        guard let field = terminal.searchBar?.field, (client as? NSSearchField) === field else { return nil }
        return searchFieldEditor
    }

    /// A translucent background (`background-opacity`) shows the desktop,
    /// blurred behind a visual-effect view when `background-blur` is set.
    private func applyBackground(_ configuration: Configuration) {
        guard let window else { return }
        let focusedView: NSView? = if let field = terminal.searchBar?.field, window.firstResponder === field.currentEditor() {
            field
        } else if let view = window.firstResponder as? NSView, view === terminal || view.isDescendant(of: terminal) {
            view
        } else {
            nil
        }
        let selection = (focusedView as? NSControl)?.currentEditor()?.selectedRange
        var reparented = false
        let translucent = configuration.backgroundOpacity < 1
        window.isOpaque = !translucent
        window.backgroundColor = translucent ? .clear : .windowBackgroundColor
        terminal.layer?.isOpaque = !translucent
        let frame = window.contentLayoutRect
        if translucent, configuration.backgroundBlur > 0 {
            guard !(window.contentView is NSVisualEffectView) else { return }
            let effect = NSVisualEffectView(frame: frame)
            effect.blendingMode = .behindWindow
            effect.material = .underWindowBackground
            effect.state = .active
            terminal.removeFromSuperview()
            terminal.frame = effect.bounds
            terminal.autoresizingMask = [.width, .height]
            effect.addSubview(terminal)
            window.contentView = effect
            reparented = true
        } else if window.contentView !== terminal {
            terminal.removeFromSuperview()
            window.contentView = terminal
            reparented = true
        }
        if reparented, let focusedView {
            window.makeFirstResponder(focusedView)
            if let selection, let control = focusedView as? NSControl {
                control.currentEditor()?.selectedRange = selection
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        terminal.stop()
        onClose?()
    }
}
