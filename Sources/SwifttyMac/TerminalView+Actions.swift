import AppKit
import SwifttyCore

/// Key-binding actions and the menu commands that share them.
extension TerminalView {
  @discardableResult
  func perform(_ action: KeyAction) -> Bool {
    guard capabilities.allows(action, presentation: session.isPresentation)
    else { return false }
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
      guard let bytes = action.bytes else { return false }
      return submitInput(.bytes(bytes))
    case .ignore: break
    }
    return true
  }

  @objc
  public func paste(_ sender: Any?) { _ = pasteClipboard() }

  private func pasteClipboard() -> Bool {
    guard capabilities.allows(.pasteFromClipboard) else { return false }
    if sendKittyPasteEvent() {
      clearSelection()
      return true
    }
    guard let text = pasteboard.string(forType: .string) else { return false }
    clearSelection()
    return submitInput(.paste(text))
  }

  @objc
  public func copy(_ sender: Any?) { _ = copySelection() }

  private func copySelection() -> Bool {
    guard capabilities.localCopy else { return false }
    guard let text = session.withState({ $0.selectionText }), !text.isEmpty
    else { return false }
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    return true
  }

  public override func selectAll(_ sender: Any?) {
    session.mutate { $0.selectAll() }
    hasSelection = true
  }

  /// Selects the output of the command at the last click (or the most
  /// recent one), from shell-integration marks.
  @objc
  public func selectCommandOutput(_ sender: Any?) {
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
  public func jumpToPreviousPrompt(_ sender: Any?) {
    perform(.jumpToPrompt(-1))
  }

  @objc
  public func jumpToNextPrompt(_ sender: Any?) { perform(.jumpToPrompt(1)) }

  @objc
  public func performFindPanelAction(_ sender: Any?) {
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
  public func clearScreen(_ sender: Any?) { perform(.clearScreen) }

  @objc
  public func resetTerminal(_ sender: Any?) { perform(.reset) }

  @objc
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    let presentation = session.isPresentation
    func allows(_ action: KeyAction) -> Bool {
      capabilities.allows(action, presentation: presentation)
    }
    return switch item.action {
    case #selector(copy(_:)):
      allows(.copyToClipboard) && session.withState { $0.selection != nil }
    case #selector(paste(_:)): allows(.pasteFromClipboard)
    case #selector(performFindPanelAction(_:)): allows(.startSearch)
    case #selector(clearScreen(_:)): allows(.clearScreen)
    case #selector(resetTerminal(_:)): allows(.reset)
    case #selector(jumpToPreviousPrompt(_:)), #selector(jumpToNextPrompt(_:)):
      allows(.jumpToPrompt(1)) && session.withState { $0.hasSemanticPrompts }
    case #selector(selectCommandOutput(_:)):
      session.withState { $0.hasSemanticPrompts }
    default: true
    }
  }

  /// Applies a capability change: closes search, returns to the live
  /// screen and re-derives the routing modes.
  func capabilitiesChanged() {
    installKittyClipboard()
    if !capabilities.textInput {
      releaseHeldKeys()
      discardComposition()
    }
    if !capabilities.search, searchBar != nil { closeSearch() }
    if !capabilities.scrollback {
      session.mutateAsync { state in
        if state.viewportOffset != 0 { state.scrollViewportToBottom() }
      }
    }
    lastModes = capabilities.effectiveModes(
      lastSnapshot?.modes ?? session.modes
    )
    refreshHover()
    needsDisplay = true
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
package final class SearchFieldEditor: NSTextView {
  package weak var terminal: TerminalView?

  public override func performFindPanelAction(_ sender: Any?) {
    terminal?.performFindPanelAction(sender)
  }
}

/// Find controls pinned to the terminal's top-right corner.
@MainActor
package final class SearchBar: NSGlassEffectView, NSSearchFieldDelegate {
  package let field = NSSearchField()
  private let navigationButtons: [NSButton]
  package var onChange: ((String) -> Void)?
  package var onNavigate: ((Bool) -> Void)?
  package var onClose: (() -> Void)?

  package var text: String {
    get { field.stringValue }
    set { field.stringValue = newValue }
  }

  package init() {
    navigationButtons = [
      NSButton(title: "▲", target: nil, action: nil),
      NSButton(title: "▼", target: nil, action: nil),
    ]
    super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
    style = .regular
    cornerRadius = 8
    effectIsInteractive = true
    let content = NSView(frame: bounds)
    content.autoresizingMask = [.width, .height]
    contentView = content
    field.frame = NSRect(x: 6, y: 5, width: 220, height: 22)
    field.delegate = self
    field.sendsSearchStringImmediately = true
    content.addSubview(field)
    for (i, button) in navigationButtons.enumerated() {
      button.target = self
      button.action = i == 0 ? #selector(previous) : #selector(next)
      button.bezelStyle = .accessoryBarAction
      button.isBordered = false
      button.frame = NSRect(x: 232 + i * 32, y: 5, width: 28, height: 22)
      content.addSubview(button)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  package func position(in bounds: NSRect) {
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
    layoutSubtreeIfNeeded()
  }

  package func controlTextDidChange(_ notification: Notification) {
    onChange?(field.stringValue)
  }

  package func control(
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
