#if canImport(UIKit)
    import SwifttyCore
    import UIKit

    /// A separate reading element lets the terminal remain accessible while
    /// its native find controls are exposed by the containing view.
    @MainActor
    final class TerminalAccessibilityElement: UIAccessibilityElement, UIAccessibilityReadingContent {
        private weak var terminal: TerminalUIView?

        init(terminal: TerminalUIView) {
            self.terminal = terminal
            super.init(accessibilityContainer: terminal)
            isAccessibilityElement = true
        }

        override var accessibilityLabel: String? {
            get { terminal?.accessibilityLabel }
            set {}
        }

        override var accessibilityValue: String? {
            get {
                // UITextInput's default value describes composition, rather
                // than the terminal's visible output. Read our own snapshot.
                guard let text = terminal?.accessibilityScreen, text.lines.indices.contains(text.cursorLine) else { return nil }
                return text.lines[text.cursorLine]
            }
            set {}
        }

        override var accessibilityTraits: UIAccessibilityTraits {
            get { terminal?.accessibilityTraits ?? [] }
            set {}
        }

        override var accessibilityFrame: CGRect {
            get {
                guard let terminal else { return .zero }
                return UIAccessibility.convertToScreenCoordinates(terminal.bounds, in: terminal)
            }
            set {}
        }

        func accessibilityLineNumber(for point: CGPoint) -> Int {
            terminal?.accessibilityLineNumber(for: point) ?? NSNotFound
        }

        func accessibilityContent(forLineNumber lineNumber: Int) -> String? {
            terminal?.accessibilityContent(forLineNumber: lineNumber)
        }

        func accessibilityFrame(forLineNumber lineNumber: Int) -> CGRect {
            terminal?.accessibilityFrame(forLineNumber: lineNumber) ?? .zero
        }

        func accessibilityPageContent() -> String? {
            terminal?.accessibilityPageContent()
        }

        override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
            terminal?.accessibilityScroll(direction) ?? false
        }

        override func accessibilityActivate() -> Bool {
            terminal?.becomeFirstResponder() ?? false
        }
    }

    /// VoiceOver reads visible rows line by line or as a page.
    /// The text comes from the last drawn snapshot and is kept only while
    /// VoiceOver runs.
    extension TerminalUIView: @MainActor UIAccessibilityReadingContent {
        func updateAccessibilityElements() {
            accessibilityElements = isSearchVisible ? [searchBar, accessibilityTerminal] : [accessibilityTerminal]
        }

        public func accessibilityLineNumber(for point: CGPoint) -> Int {
            guard point.x.isFinite, point.y.isFinite, bounds.contains(point) else { return NSNotFound }
            let cell = geometry.cell(at: point)
            guard cell.column >= 0, cell.column < gridSize.columns,
                  let lines = accessibilityScreen?.lines, lines.indices.contains(cell.row) else { return NSNotFound }
            return cell.row
        }

        public func accessibilityContent(forLineNumber lineNumber: Int) -> String? {
            guard let lines = accessibilityScreen?.lines, lines.indices.contains(lineNumber) else { return nil }
            return lines[lineNumber]
        }

        public func accessibilityFrame(forLineNumber lineNumber: Int) -> CGRect {
            guard let lines = accessibilityScreen?.lines, lines.indices.contains(lineNumber) else { return .zero }
            var rect = geometry.rect(column: 0, row: lineNumber)
            rect.size.width = geometry.rect(column: gridSize.columns, row: 0).minX - rect.minX
            return UIAccessibility.convertToScreenCoordinates(rect, in: self)
        }

        public func accessibilityPageContent() -> String? {
            accessibilityScreen?.string
        }

        /// Three-finger swipes and continuous-reading page commands navigate
        /// scrollback: up/next show what follows, down/previous what came before.
        override public func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
            let sign: Int
            switch direction {
            case .up, .next: sign = -1
            case .down, .previous: sign = 1
            default: return false
            }
            stopMomentum()
            let moved = session.mutate { state in
                let previous = state.viewportOffset
                state.scrollViewport(by: sign * max(1, state.rows - 1))
                return state.viewportOffset != previous
            }
            guard moved else { return false }
            // Page content must be available when VoiceOver receives the
            // notification, even before the next drawing frame.
            let text = AccessibilityText(session.snapshot())
            accessibilityScreen = text
            UIAccessibility.post(notification: .pageScrolled, argument: nil)
            return true
        }
    }
#endif
