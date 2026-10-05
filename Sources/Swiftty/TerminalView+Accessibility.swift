import AppKit
import SwifttyCore

/// VoiceOver: the view is a read-only text area holding the visible
/// screen, with the insertion point at the terminal cursor.
extension TerminalView {
    private var accessibilityText: AccessibilityText? {
        lastSnapshot.map(AccessibilityText.init)
    }

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .textArea
    }

    override func accessibilityRoleDescription() -> String? {
        "terminal"
    }

    override func accessibilityLabel() -> String? {
        window?.title ?? "Terminal"
    }

    override func accessibilityValue() -> Any? {
        accessibilityText?.string ?? ""
    }

    override func accessibilityNumberOfCharacters() -> Int {
        accessibilityText?.string.utf16.count ?? 0
    }

    override func accessibilityVisibleCharacterRange() -> NSRange {
        NSRange(location: 0, length: accessibilityNumberOfCharacters())
    }

    override func accessibilitySelectedTextRange() -> NSRange {
        NSRange(location: accessibilityText?.cursorOffset ?? 0, length: 0)
    }

    override func accessibilitySelectedText() -> String? {
        session.withState { $0.selectionText } ?? ""
    }

    override func accessibilityInsertionPointLineNumber() -> Int {
        accessibilityText?.cursorLine ?? 0
    }

    override func accessibilityLine(for index: Int) -> Int {
        accessibilityText?.line(forOffset: index) ?? 0
    }

    override func accessibilityRange(forLine line: Int) -> NSRange {
        guard let text = accessibilityText, line >= 0, line < text.lineRanges.count else { return NSRange(location: 0, length: 0) }
        return text.lineRanges[line]
    }

    override func accessibilityString(for range: NSRange) -> String? {
        guard let string = accessibilityText?.string else { return nil }
        let ns = string as NSString
        guard range.location >= 0, NSMaxRange(range) <= ns.length else { return nil }
        return ns.substring(with: range)
    }

    /// Screen rectangle of the rows `range` touches.
    override func accessibilityFrame(for range: NSRange) -> NSRect {
        guard let text = accessibilityText, let window else { return .zero }
        let first = text.line(forOffset: range.location)
        let last = text.line(forOffset: max(range.location, NSMaxRange(range) - 1))
        let scale = window.backingScaleFactor
        let cell = renderer.cellSize
        let top = (renderer.options.paddingY + CGFloat(first) * cell.height) / scale
        let height = CGFloat(last - first + 1) * cell.height / scale
        let rect = NSRect(x: renderer.options.paddingX / scale, y: bounds.height - top - height, width: bounds.width, height: height)
        return window.convertToScreen(convert(rect, to: nil))
    }
}
