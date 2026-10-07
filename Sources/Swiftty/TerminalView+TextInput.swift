import AppKit
import SwifttyCore

/// IME composition: marked text is drawn as the renderer's preedit at the
/// cursor, and the candidate window is placed over the cursor cell.
extension TerminalView: @MainActor NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        let wasComposing = hasMarkedText()
        setPreedit("")
        if !text.isEmpty {
            let flags = session.keyboardFlags
            if !wasComposing, InputEncoder.isKittyKeyboardActive(flags), let event = interpretingEvent,
               let key = Self.terminalKey(for: event, keyboardFlags: flags) {
                var key = key
                key.text = text
                sendHardwareKey(key, event: event)
            } else {
                session.send(.text(text))
            }
        }
    }

    /// Selectors the input method did not turn into text (for example a
    /// dead key followed by an arrow); send the key as typed.
    override func doCommand(by selector: Selector) {
        guard let event = interpretingEvent, !sendKey(event), let text = event.characters, !text.isEmpty else { return }
        session.send(.text(text))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        setPreedit((string as? NSAttributedString)?.string ?? string as? String ?? "")
    }

    func unmarkText() {
        guard !markedText.isEmpty else { return }
        insertText(markedText, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func setPreedit(_ text: String) {
        guard text != markedText else { return }
        markedText = text
        renderer.options.preedit = Array(text.unicodeScalars)
        needsDisplay = true
    }

    func hasMarkedText() -> Bool {
        !markedText.isEmpty
    }

    func markedRange() -> NSRange {
        hasMarkedText() ? NSRange(location: 0, length: markedText.utf16.count) : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }

    /// The cursor cell in screen coordinates, where the candidate window goes.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        let scale = window?.backingScaleFactor ?? renderer.font.descriptor.scale
        let column = CGFloat(lastSnapshot?.cursor.x ?? 0), row = CGFloat(lastSnapshot?.cursor.y ?? 0)
        let cell = renderer.cellSize
        let x: CGFloat = (renderer.options.paddingX + column * cell.width) / scale
        let top: CGFloat = (renderer.options.paddingY + (row + 1) * cell.height) / scale
        let rect = NSRect(x: x, y: bounds.height - top, width: cell.width / scale, height: cell.height / scale)
        guard let window else { return rect }
        return window.convertToScreen(convert(rect, to: nil))
    }
}
