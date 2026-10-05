import AppKit
import SwifttyCore

/// Key-binding actions and the menu commands that share them.
extension TerminalView {
    func perform(_ action: KeyAction) {
        switch action {
        case .copyToClipboard: copy(nil)
        case .pasteFromClipboard: paste(nil)
        case let .increaseFontSize(n): fontSize = min(fontSize + CGFloat(n), 72); applyFont()
        case let .decreaseFontSize(n): fontSize = max(fontSize - CGFloat(n), 6); applyFont()
        case .resetFontSize: fontSize = CGFloat(config.fontSize); applyFont()
        case .selectAll: selectAll(nil)
        case .scrollToTop, .scrollToBottom, .scrollPageUp, .scrollPageDown, .scrollPageLines:
            session.mutate { state in
                if let delta = ActionDispatch.viewportDelta(for: action, rows: state.rows, history: state.scrollbackCount) {
                    state.scrollViewport(by: delta)
                }
            }
        case let .jumpToPrompt(n): session.mutate { _ = $0.jumpToPrompt(n) }
        case .startSearch: showSearch(text: nil)
        case .searchSelection: showSearch(text: session.withState { $0.selectionText })
        // Matching starts at the newest output, so "next" walks back through history.
        case let .navigateSearch(next): session.mutate { _ = $0.selectSearchMatch(forward: !next) }
        case .endSearch: closeSearch()
        case .clearScreen: session.mutate { $0.clearScreenKeepingCursorLine() }
        case .reset: session.mutate { $0.reset() }
        case .text, .csi, .esc: action.bytes.map { session.send(.bytes($0)) }
        case .ignore: break
        }
    }

    @objc func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string) {
            session.send(.paste(text))
        }
    }

    @objc func copy(_ sender: Any?) {
        guard let text = session.withState({ $0.selectionText }), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        session.mutate { $0.selectAll() }
        hasSelection = true
    }

    /// Selects the output of the command at the last click (or the most
    /// recent one), from shell-integration marks.
    @objc func selectCommandOutput(_ sender: Any?) {
        let click = lastClick
        let found = session.mutate { state -> Bool in
            let p = click ?? TerminalPoint(row: state.promptRows().last.map { $0 - 1 } ?? 0, column: 0)
            guard let range = state.commandOutputRange(at: p) else { return false }
            state.setSelection(Selection(anchor: range.start, head: range.end))
            state.scrollToShow(row: range.start.row)
            return true
        }
        if found {
            hasSelection = true
        } else {
            NSSound.beep()
        }
    }

    @objc func jumpToPreviousPrompt(_ sender: Any?) {
        perform(.jumpToPrompt(-1))
    }

    @objc func jumpToNextPrompt(_ sender: Any?) {
        perform(.jumpToPrompt(1))
    }

    @objc func performFindPanelAction(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? Int(NSFindPanelAction.showFindPanel.rawValue)
        switch NSFindPanelAction(rawValue: UInt(tag)) {
        case .next: perform(.navigateSearch(next: true))
        case .previous: perform(.navigateSearch(next: false))
        case .setFindString: perform(.searchSelection)
        default: perform(.startSearch)
        }
    }

    @objc func clearScreen(_ sender: Any?) {
        perform(.clearScreen)
    }

    @objc func resetTerminal(_ sender: Any?) {
        perform(.reset)
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): session.withState { $0.selection != nil }
        case #selector(jumpToPreviousPrompt(_:)), #selector(jumpToNextPrompt(_:)), #selector(selectCommandOutput(_:)):
            session.withState { $0.hasSemanticPrompts }
        default: true
        }
    }

    // MARK: Search

    func showSearch(text: String?) {
        if searchBar == nil {
            let bar = SearchBar()
            bar.onChange = { [weak self] needle in
                self?.session.mutate { state in
                    state.search(needle)
                    _ = state.selectSearchMatch(forward: false) // the newest match
                }
            }
            bar.onNavigate = { [weak self] next in self?.perform(.navigateSearch(next: next)) }
            bar.onClose = { [weak self] in self?.closeSearch() }
            addSubview(bar)
            searchBar = bar
        }
        guard let bar = searchBar else { return }
        bar.position(in: bounds)
        if let text, !text.isEmpty {
            bar.text = text
            bar.onChange?(text)
        }
        window?.makeFirstResponder(bar.field)
    }

    func closeSearch() {
        searchBar?.removeFromSuperview()
        searchBar = nil
        session.mutate { $0.endSearch() }
        window?.makeFirstResponder(self)
    }
}

/// The find bar: a search field with previous/next buttons, pinned to the
/// top-right of the terminal.
@MainActor
final class SearchBar: NSView, NSSearchFieldDelegate {
    let field = NSSearchField()
    var onChange: ((String) -> Void)?
    var onNavigate: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.cornerRadius = 6
        field.frame = NSRect(x: 6, y: 5, width: 220, height: 22)
        field.delegate = self
        field.sendsSearchStringImmediately = true
        addSubview(field)
        let previous = NSButton(title: "▲", target: self, action: #selector(previous))
        let next = NSButton(title: "▼", target: self, action: #selector(next))
        for (i, button) in [previous, next].enumerated() {
            button.bezelStyle = .smallSquare
            button.frame = NSRect(x: 232 + i * 32, y: 5, width: 28, height: 22)
            addSubview(button)
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) {
        fatalError()
    }

    func position(in bounds: NSRect) {
        setFrameOrigin(NSPoint(x: bounds.maxX - frame.width - 12, y: bounds.maxY - frame.height - 8))
    }

    func controlTextDidChange(_ notification: Notification) {
        onChange?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onNavigate?(!(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)) // shift: previous
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }

    /// ▲ goes back to older output (the next match), ▼ to newer.
    @objc private func previous() {
        onNavigate?(true)
    }

    @objc private func next() {
        onNavigate?(false)
    }
}
