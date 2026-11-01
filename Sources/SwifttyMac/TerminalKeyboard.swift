import AppKit
import SwifttyCore

/// AppKit dispatch shared by native terminal surfaces. Adapters encode keys
/// against their own authority and implement actions; this code only decides
/// whether a binding consumes the event and when the input method receives it.
@MainActor
package final class TerminalKeyboard {
  package var interpretingEvent: NSEvent?

  package init() {}

  package func consumesKeyDown(
    hideMouse: Bool,
    composing: Bool,
    binding: Keybindings.Binding?,
    perform: (Keybindings.Binding) -> Bool
  ) -> Bool {
    if hideMouse { NSCursor.setHiddenUntilMouseMoves(true) }
    guard !composing, let binding else { return false }
    let performed = perform(binding)
    return binding.consumesInput && (!binding.requiresPerformable || performed)
  }

  /// nil delegates to AppKit's normal key equivalent handling.
  package func keyEquivalent(
    in view: NSView,
    composing: Bool,
    binding: Keybindings.Binding?,
    perform: (Keybindings.Binding) -> Bool,
    sendUnbound: () -> Void
  ) -> Bool? {
    guard view.window?.firstResponder === view, !composing, let binding else {
      return nil
    }
    let performed = perform(binding)
    if binding.requiresPerformable, !performed { return false }
    if !binding.consumesInput { sendUnbound() }
    return true
  }

  package func interpret(
    _ event: NSEvent,
    in view: NSView,
    composing: Bool,
    sendSpecial: () -> Bool
  ) {
    // A composing input method receives all keys, including arrows/dead keys.
    if !composing, sendSpecial() { return }
    interpretingEvent = event
    defer { interpretingEvent = nil }
    view.interpretKeyEvents([event])
  }
}
