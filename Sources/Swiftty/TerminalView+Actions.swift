import AppKit
import SwifttyCore

/// Key-binding actions and the menu commands that share them.
extension TerminalView {
  @discardableResult
  func perform(_ action: KeyAction) -> Bool {
    switch action {
    case .copyToClipboard: return copySelection()
    case .pasteFromClipboard: return pasteClipboard()
    case let .increaseFontSize(n): setFontSize(fontSize + CGFloat(n))
    case let .decreaseFontSize(n): setFontSize(fontSize - CGFloat(n))
    case .resetFontSize: setFontSize(nil)
    case .selectAll: selectAll(nil)
    case .scrollToTop, .scrollToBottom, .scrollPageUp, .scrollPageDown,
      .scrollPageLines:
      return session.mutate { state in
        let before = state.viewportOffset
        if let delta = ActionDispatch.viewportDelta(
          for: action,
          rows: state.rows,
          history: state.scrollbackCount
        ) {
          state.scrollViewport(by: delta)
        }
        return state.viewportOffset != before
      }
    case let .jumpToPrompt(n): return session.mutate { $0.jumpToPrompt(n) }
    case .startSearch: showSearch(text: nil)
    case .searchSelection:
      guard let text = session.withState({ $0.selectionText }), !text.isEmpty
      else { return false }
      showSearch(text: text)
    // Matching starts at the newest output, so "next" walks back through history.
    case let .navigateSearch(next):
      return session.mutate { $0.selectSearchMatch(forward: !next) != nil }
    case .endSearch:
      guard searchBar != nil else { return false }
      closeSearch()
    case .clearScreen: session.mutate { $0.clearScreenKeepingCursorLine() }
    case .reset: session.reset()
    case .text, .textBytes, .csi, .esc:
      action.bytes.map { session.send(.bytes($0)) }
    case .ignore: break
    }
    return true
  }

  @objc
  func paste(_ sender: Any?) { _ = pasteClipboard() }

  private func pasteClipboard() -> Bool {
    guard let text = pasteboard.string(forType: .string) else { return false }
    clearSelection()
    session.send(.paste(text))
    return true
  }

  @objc
  func copy(_ sender: Any?) { _ = copySelection() }

  private func copySelection() -> Bool {
    guard let text = session.withState({ $0.selectionText }), !text.isEmpty
    else { return false }
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    return true
  }

  override func selectAll(_ sender: Any?) {
    session.mutate { $0.selectAll() }
    hasSelection = true
  }

  /// Selects the output of the command at the last click (or the most
  /// recent one), from shell-integration marks.
  @objc
  func selectCommandOutput(_ sender: Any?) {
    let context = lastClick
    let found = session.mutate { state -> Bool in
      let click: TerminalPoint? =
        if let context, context.generation == state.addressingGeneration,
          context.point.row >= state.firstAbsoluteRow,
          context.point.row - state.firstAbsoluteRow < state.addressableRows
        { context.point } else { nil }
      let prompts = state.promptRows()
      let prompt = prompts.last ?? 0
      let p = click ?? TerminalPoint(row: prompt, column: 0)
      var output = state.commandOutputRange(at: p)
      if output == nil, click == nil {
        // Fresh prompts and commands without output are skipped.
        for boundary in prompts.reversed() {
          // Probe before the boundary so output remains reachable
          // even when its own prompt has already left history.
          output = state.commandOutputRange(
            at: TerminalPoint(row: boundary - 1, column: 0)
          )
          if output != nil { break }
        }
      }
      guard let range = output else { return false }
      state.setSelection(Selection(anchor: range.start, head: range.end))
      state.scrollToShow(row: range.start.row)
      return true
    }
    if found { hasSelection = true } else { NSSound.beep() }
  }

  @objc
  func jumpToPreviousPrompt(_ sender: Any?) { perform(.jumpToPrompt(-1)) }

  @objc
  func jumpToNextPrompt(_ sender: Any?) { perform(.jumpToPrompt(1)) }

  @objc
  func performFindPanelAction(_ sender: Any?) {
    let tag =
      (sender as? NSMenuItem)?.tag
      ?? Int(NSFindPanelAction.showFindPanel.rawValue)
    let action = UInt(exactly: tag).flatMap { NSFindPanelAction(rawValue: $0) }
    switch action {
    case .next: perform(.navigateSearch(next: true))
    case .previous: perform(.navigateSearch(next: false))
    case .setFindString: perform(.searchSelection)
    default: perform(.startSearch)
    }
  }

  @objc
  func clearScreen(_ sender: Any?) { perform(.clearScreen) }

  @objc
  func resetTerminal(_ sender: Any?) { perform(.reset) }

  @objc
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(copy(_:)): session.withState { $0.selection != nil }
    case #selector(jumpToPreviousPrompt(_:)), #selector(jumpToNextPrompt(_:)),
      #selector(selectCommandOutput(_:)):
      session.withState { $0.hasSemanticPrompts }
    default: true
    }
  }

  // MARK: Search

  func showSearch(text: String?) {
    if searchBar == nil {
      let bar = SearchBar()
      bar.onChange = { [weak self] needle in
        self?.session
          .mutate { state in
            state.search(needle)
            _ = state.selectSearchMatch(forward: false)  // the newest match
          }
      }
      bar.onNavigate = { [weak self] next in
        self?.perform(.navigateSearch(next: next))
      }
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

/// Routes find commands from the query editor to the terminal's results.
@MainActor
final class SearchFieldEditor: NSTextView {
  weak var terminal: TerminalView?

  override func performFindPanelAction(_ sender: Any?) {
    terminal?.performFindPanelAction(sender)
  }
}

/// Find controls pinned to the terminal's top-right corner.
@MainActor
final class SearchBar: NSView, NSSearchFieldDelegate {
  let field = NSSearchField()
  private let navigationButtons: [NSButton]
  var onChange: ((String) -> Void)?
  var onNavigate: ((Bool) -> Void)?
  var onClose: (() -> Void)?

  var text: String {
    get { field.stringValue }
    set { field.stringValue = newValue }
  }

  init() {
    navigationButtons = [
      NSButton(title: "▲", target: nil, action: nil),
      NSButton(title: "▼", target: nil, action: nil),
    ]
    super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
    wantsLayer = true
    layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    layer?.cornerRadius = 6
    field.frame = NSRect(x: 6, y: 5, width: 220, height: 22)
    field.delegate = self
    field.sendsSearchStringImmediately = true
    addSubview(field)
    for (i, button) in navigationButtons.enumerated() {
      button.target = self
      button.action = i == 0 ? #selector(previous) : #selector(next)
      button.bezelStyle = .smallSquare
      button.frame = NSRect(x: 232 + i * 32, y: 5, width: 28, height: 22)
      addSubview(button)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  func position(in bounds: NSRect) {
    let margin = min(12, max(0, bounds.width / 4))
    let width = min(300, max(0, bounds.width - 2 * margin))
    let height = min(32, max(0, bounds.height))
    frame = NSRect(
      x: bounds.maxX - width - margin,
      y: max(bounds.minY, bounds.maxY - height - 8),
      width: width,
      height: height,
    )
    // Keep room to edit the query; Return/Shift-Return still navigate
    // when a narrow surface cannot fit the buttons.
    let showButtons = width >= 120
    let inset = min(6, width / 2)
    let controlHeight = min(22, height)
    let y = (height - controlHeight) / 2
    field.frame = NSRect(
      x: inset,
      y: y,
      width: max(0, width - 2 * inset - (showButtons ? 68 : 0)),
      height: controlHeight,
    )
    for (i, button) in navigationButtons.enumerated() {
      button.isHidden = !showButtons
      button.frame = NSRect(
        x: width - 68 + CGFloat(i) * 32,
        y: y,
        width: 28,
        height: controlHeight
      )
    }
  }

  func controlTextDidChange(_ notification: Notification) {
    onChange?(field.stringValue)
  }

  func control(
    _ control: NSControl,
    textView: NSTextView,
    doCommandBy selector: Selector
  ) -> Bool {
    switch selector {
    case #selector(NSResponder.insertNewline(_:)):
      onNavigate?(
        !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
      )  // shift: previous
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      onClose?()
      return true
    default: return false
    }
  }

  /// ▲ goes back to older output (the next match), ▼ to newer.
  @objc
  private func previous() { onNavigate?(true) }

  @objc
  private func next() { onNavigate?(false) }
}
