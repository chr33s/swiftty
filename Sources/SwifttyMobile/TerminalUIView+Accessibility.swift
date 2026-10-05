#if canImport(UIKit)
    import SwifttyCore
    import UIKit

    /// VoiceOver: the view is one text element whose lines are the visible
    /// rows, read line by line or as a page (`UIAccessibilityReadingContent`).
    /// The text comes from the last drawn snapshot and is kept only while
    /// VoiceOver runs.
    extension TerminalUIView: @MainActor UIAccessibilityReadingContent {
        public func accessibilityLineNumber(for point: CGPoint) -> Int {
            let row = geometry.cell(at: point).row
            let count = accessibilityScreen?.lines.count ?? 0
            return count == 0 ? NSNotFound : min(max(row, 0), count - 1)
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

        /// Three-finger swipes page through the scrollback: up shows what
        /// follows, down what came before.
        override public func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
            let rows = max(1, gridSize.rows - 1)
            switch direction {
            case .up: session.scrollViewport(by: -rows)
            case .down: session.scrollViewport(by: rows)
            default: return false
            }
            UIAccessibility.post(notification: .pageScrolled, argument: nil)
            return true
        }
    }
#endif
