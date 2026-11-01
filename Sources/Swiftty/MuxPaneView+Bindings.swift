import AppKit
import SwiftMuxProtocol
import SwifttyCore
import SwifttyMac

/// User key bindings (`keybind`), matched as the direct terminal view
/// matches them. Actions a service from an older build does not offer
/// (prompt jumps, clear screen, reset, scroll to top) are not performed
/// there, so a binding that requires a performable action passes its key
/// on.
extension MuxPaneView {
  func binding(for event: NSEvent) -> Keybindings.Binding? {
    TerminalView.trigger(for: event)
      .flatMap { config.keybindings.binding(for: $0) }
  }

  /// Key bindings run before the menu's key equivalents.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if window?.firstResponder === self, !hasMarkedText(),
      controller?.handleAutomationKey(event, pane: pane) == true
    {
      return true
    }
    return keyboard.keyEquivalent(
      in: self,
      composing: hasMarkedText(),
      binding: binding(for: event),
      perform: { perform($0.action) },
      sendUnbound: { sendUnbound(event) }
    ) ?? super.performKeyEquivalent(with: event)
  }

  /// A non-consuming binding's key, as the terminal would get it unbound.
  private func sendUnbound(_ event: NSEvent) {
    if let key = Self.semanticKey(
      for: event,
      keypadKeys: features.contains(.keypadKeys)
    ) {
      clearSelection()
      controller?.send(.key(key.0, key.1), to: pane)
    } else if let text = event.characters, !text.isEmpty {
      clearSelection()
      controller?.send(.text(text), to: pane)
    }
  }

  @discardableResult
  func perform(_ action: KeyAction) -> Bool {
    guard let controller else { return false }
    switch action {
    case .newTab: controller.newTab()
    case .copyToClipboard:
      guard selection != nil else { return false }
      copy(nil)
    case .pasteFromClipboard:
      guard NSPasteboard.general.string(forType: .string) != nil else {
        return false
      }
      paste(nil)
    case let .increaseFontSize(n): controller.adjustFontSize(by: n)
    case let .decreaseFontSize(n): controller.adjustFontSize(by: -n)
    case .resetFontSize: controller.setFontSize(nil)
    case .selectAll: selectAll(nil)
    case .scrollToBottom: controller.scroll(pane, .bottom)
    // Positive requests scroll toward older history.
    case .scrollPageUp: controller.scroll(pane, .pages(1))
    case .scrollPageDown: controller.scroll(pane, .pages(-1))
    case let .scrollPageLines(n): controller.scroll(pane, .lines(-n))
    case .startSearch: controller.showSearch()
    case .searchSelection:
      guard let text = selectedText, !text.isEmpty else { return false }
      controller.showSearch(text: text)
    case let .navigateSearch(next):
      controller.performFind(next ? .next : .previous)
    case .endSearch:
      guard controller.searchBar?.isHidden == false else { return false }
      controller.hideSearch()
    case .scrollToTop:
      guard controller.features.contains(.historyJumps) else { return false }
      controller.scroll(pane, .oldest)
    case let .jumpToPrompt(n):
      guard controller.features.contains(.historyJumps),
        presented?.frame.modes.contains(.alternateScreen) == false
      else { return false }
      controller.scroll(pane, .prompt(n))
    case .clearScreen:
      guard controller.holdsLease,
        controller.features.contains(.terminalControl)
      else { return false }
      controller.clearScreen(pane)
    case .reset:
      guard controller.holdsLease,
        controller.features.contains(.terminalControl)
      else { return false }
      controller.resetTerminal(pane)
    case .text, .textBytes, .csi, .esc:
      guard let bytes = action.bytes,
        let text = String(validating: bytes, as: UTF8.self)
      else { return false }
      clearSelection()
      controller.send(.text(text), to: pane)
    case .ignore: break
    }
    return true
  }
}
