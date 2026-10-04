import AppKit
import SwifttyCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [TerminalWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMenu()
        newWindow(nil)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc func newWindow(_ sender: Any?) {
        do {
            let controller = try TerminalWindowController()
            controller.onClose = { [weak self, weak controller] in
                self?.windows.removeAll { $0 === controller }
            }
            windows.append(controller)
            controller.showWindow(nil)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit swiftty", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let shellItem = NSMenuItem()
        let shellMenu = NSMenu(title: "Shell")
        shellMenu.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n")
        shellMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        shellItem.submenu = shellMenu
        main.addItem(shellItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Paste", action: #selector(TerminalView.paste(_:)), keyEquivalent: "v")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Bigger", action: #selector(TerminalView.increaseFontSize(_:)), keyEquivalent: "+")
        viewMenu.addItem(withTitle: "Smaller", action: #selector(TerminalView.decreaseFontSize(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Reset Size", action: #selector(TerminalView.resetFontSize(_:)), keyEquivalent: "0")
        viewItem.submenu = viewMenu
        main.addItem(viewItem)
        return main
    }
}

@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let terminal: TerminalView

    init(columns: Int = 100, rows: Int = 30) throws {
        terminal = try TerminalView()
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: terminal.preferredSize(columns: columns, rows: rows)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false,
        )
        window.title = "swiftty"
        window.contentView = terminal
        window.center()
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        window.makeFirstResponder(terminal)
        terminal.onTitle = { [weak window] title in window?.title = title }
        terminal.onExit = { [weak window] in window?.close() }
        try terminal.start()
    }

    @available(*, unavailable) required init?(coder: NSCoder) {
        fatalError()
    }

    func windowWillClose(_ notification: Notification) {
        terminal.stop()
        onClose?()
    }
}
