import Foundation
import SwifttyCore

// Platform-neutral frontend behavior: what key-binding actions do to the
// viewport, OSC 22 pointer shapes, the blink phase, which links open, and
// click-to-move. Kept free of UIKit so it is testable on macOS.

// MARK: - Key-binding actions

public enum ActionDispatch {
    /// Viewport lines to scroll (positive into history) for scrolling
    /// actions, or nil for other actions.
    /// - Parameters:
    ///   - rows: visible rows;
    ///   - history: rows of scrollback above the screen.
    public static func viewportDelta(for action: KeyAction, rows: Int, history: Int) -> Int? {
        switch action {
        case .scrollToTop: history
        case .scrollToBottom: -history
        case .scrollPageUp: rows
        case .scrollPageDown: -rows
        // Ghostty's `scroll_page_lines:n` scrolls down for positive n.
        case let .scrollPageLines(n): -n
        default: nil
        }
    }

    /// Menu and discoverability-HUD title.
    public static func title(for action: KeyAction) -> String {
        switch action {
        case .copyToClipboard: "Copy"
        case .pasteFromClipboard: "Paste"
        case .increaseFontSize: "Bigger"
        case .decreaseFontSize: "Smaller"
        case .resetFontSize: "Reset Font Size"
        case .selectAll: "Select All"
        case .scrollToTop: "Scroll to Top"
        case .scrollToBottom: "Scroll to Bottom"
        case .scrollPageUp: "Page Up"
        case .scrollPageDown: "Page Down"
        case let .scrollPageLines(n): n < 0 ? "Scroll Up \(-n) Lines" : "Scroll Down \(n) Lines"
        case let .jumpToPrompt(n): n < 0 ? "Previous Prompt" : "Next Prompt"
        case .startSearch: "Find…"
        case .searchSelection: "Find Selection"
        case let .navigateSearch(next): next ? "Find Next" : "Find Previous"
        case .endSearch: "End Find"
        case .clearScreen: "Clear Screen"
        case .reset: "Reset Terminal"
        case .text, .csi, .esc: "Send Text"
        case .ignore: "Ignore"
        }
    }
}

// MARK: - Pointer shapes

/// OSC 22 pointer shapes (CSS cursor names) reduced to what iPadOS pointers
/// can show.
public enum PointerShape: Equatable, Sendable {
    case beam, link, system, crosshair, resizeHorizontal, resizeVertical, move, hidden

    /// Shape for a CSS cursor name; unknown names fall back to the I-beam.
    public init(cssName: String) {
        switch cssName.lowercased() {
        case "text", "vertical-text": self = .beam
        case "pointer", "hand", "alias", "copy", "context-menu", "help": self = .link
        case "default", "auto", "progress", "wait", "not-allowed", "no-drop", "zoom-in", "zoom-out": self = .system
        case "crosshair", "cell": self = .crosshair
        case "ew-resize", "col-resize", "e-resize", "w-resize": self = .resizeHorizontal
        case "ns-resize", "row-resize", "n-resize", "s-resize": self = .resizeVertical
        case "move", "all-scroll", "grab", "grabbing", "nesw-resize", "nwse-resize",
             "ne-resize", "nw-resize", "se-resize", "sw-resize": self = .move
        case "none": self = .hidden
        default: self = .beam
        }
    }

    /// The pointer for the current state: a link under the pointer wins,
    /// then the application's OSC 22 shape, then the system pointer while
    /// it tracks the mouse, else the I-beam.
    public static func resolve(applicationShape: String, overLink: Bool, tracking: Bool) -> PointerShape {
        if overLink {
            return .link
        }
        if !applicationShape.isEmpty {
            return PointerShape(cssName: applicationShape)
        }
        return tracking ? .system : .beam
    }
}

// MARK: - Blinking

/// Cursor and SGR 5 text blink phases. Both start visible, toggle on each
/// tick while they blink, and return to visible on input.
public struct BlinkState: Equatable, Sendable {
    public static let interval: TimeInterval = 0.6

    public private(set) var cursorVisible = true
    public private(set) var textVisible = true

    public init() {}

    /// Whether a timer is needed: something blinks and is being shown.
    public static func needsTimer(cursorBlinks: Bool, textBlinks: Bool, focused: Bool, background: Bool) -> Bool {
        !background && ((cursorBlinks && focused) || textBlinks)
    }

    public mutating func tick(cursorBlinks: Bool, textBlinks: Bool) {
        cursorVisible = cursorBlinks ? !cursorVisible : true
        textVisible = textBlinks ? !textVisible : true
    }

    /// Typing shows the cursor (and keeps it shown for a full phase).
    public mutating func reset() {
        cursorVisible = true
        textVisible = true
    }
}

// MARK: - Links

public enum LinkPolicy {
    /// Schemes opened with the system handler; others (file, javascript,
    /// custom app schemes) are ignored.
    public static let schemes: Set<String> = ["http", "https", "mailto", "ftp", "ssh"]

    public static func openableURL(_ string: String) -> URL? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), schemes.contains(scheme) else { return nil }
        // A scheme alone ("https:") goes nowhere.
        guard scheme == "mailto" || url.host?.isEmpty == false else { return nil }
        return url
    }

    /// The link's cells in snapshot rows, for underlining under the pointer.
    public static func span(of range: TerminalRange, firstVisibleRow: Int) -> HighlightSpan {
        HighlightSpan(
            startRow: range.start.row - firstVisibleRow, startColumn: range.start.column,
            endRow: range.end.row - firstVisibleRow, endColumn: range.end.column,
        )
    }
}

// MARK: - Click to move

public enum ClickToMove {
    /// Arrow presses moving the shell's cursor by `moves` characters
    /// (negative is left), as `promptCursorMoves(to:)` reports.
    public static func keys(_ moves: Int) -> [KeyEvent] {
        Array(repeating: KeyEvent(moves < 0 ? .left : .right), count: abs(moves))
    }
}

// MARK: - US layout

public extension KeyTranslator {
    /// The character of a key on the US (PC-101) layout by HID usage, for
    /// the kitty protocol's base-layout key.
    static func usLayoutKey(usage: Int) -> Unicode.Scalar? {
        switch usage {
        case 0x04 ... 0x1D: Unicode.Scalar(UInt32(0x61 + usage - 0x04))
        case 0x1E ... 0x26: Unicode.Scalar(UInt32(0x31 + usage - 0x1E))
        case 0x27: "0"
        case 0x2C: " "
        case 0x2D: "-"
        case 0x2E: "="
        case 0x2F: "["
        case 0x30: "]"
        case 0x31: "\\"
        case 0x33: ";"
        case 0x34: "'"
        case 0x35: "`"
        case 0x36: ","
        case 0x37: "."
        case 0x38: "/"
        default: nil
        }
    }
}
