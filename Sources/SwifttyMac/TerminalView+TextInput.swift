import AppKit
import SwifttyCore

/// IME composition: marked text is drawn as the renderer's preedit at the
/// cursor, and the candidate window is placed over the cursor cell.
extension TerminalView: @MainActor NSTextInputClient {
  public func insertText(_ string: Any, replacementRange: NSRange) {
    let text =
      (string as? NSAttributedString)?.string ?? string as? String ?? ""
    let wasComposing = hasMarkedText()
    setPreedit("")
    if capabilities.textInput, !text.isEmpty {
      clearSelection()
      let flags = session.keyboardFlags
      if !wasComposing, InputEncoder.isKittyKeyboardActive(flags),
        let event = interpretingEvent,
        let key = Self.terminalKey(for: event, keyboardFlags: flags)
      {
        var key = key
        key.text = text
        sendHardwareKey(key, event: event)
      } else {
        submitInput(.text(text))
      }
    }
  }

  /// Selectors the input method did not turn into text (for example a
  /// dead key followed by an arrow); send the key as typed.
  public override func doCommand(by selector: Selector) {
    guard capabilities.textInput, let event = interpretingEvent,
      !sendKey(event), let text = event.characters, !text.isEmpty
    else { return }
    submitInput(.text(text))
  }

  public func setMarkedText(
    _ string: Any,
    selectedRange: NSRange,
    replacementRange: NSRange
  ) {
    guard capabilities.textInput else {
      discardComposition()
      return
    }
    setPreedit(
      (string as? NSAttributedString)?.string ?? string as? String ?? "",
      selection: selectedRange
    )
  }

  public func unmarkText() {
    guard !markedText.isEmpty else { return }
    insertText(
      markedText,
      replacementRange: NSRange(location: NSNotFound, length: 0)
    )
  }

  func discardComposition() {
    composition.discard(renderer: renderer, view: self)
  }

  private func setPreedit(
    _ text: String,
    selection: NSRange = NSRange(location: NSNotFound, length: 0)
  ) {
    composition.set(text, selection: selection, renderer: renderer, view: self)
  }

  public func hasMarkedText() -> Bool { !composition.text.isEmpty }
  public func markedRange() -> NSRange { composition.markedRange }
  public func selectedRange() -> NSRange { composition.selection }

  public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

  public func attributedSubstring(
    forProposedRange range: NSRange,
    actualRange: NSRangePointer?
  ) -> NSAttributedString? { nil }

  public func characterIndex(for point: NSPoint) -> Int { NSNotFound }

  /// The composition range in screen coordinates, where the candidate window goes.
  public func firstRect(
    forCharacterRange range: NSRange,
    actualRange: NSRangePointer?
  ) -> NSRect {
    composition.firstRect(
      for: range,
      actualRange: actualRange,
      cursor: (lastSnapshot?.cursor.x ?? 0, lastSnapshot?.cursor.y ?? 0),
      renderer: renderer,
      view: self
    )
  }
}
