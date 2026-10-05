import CoreGraphics
import Foundation
import SwifttyCore

// Platform-neutral input logic for the UIKit frontend: key translation,
// sticky modifiers, scroll physics and selection math. Kept free of UIKit
// so it is testable on macOS without a window server.

// MARK: - Hardware keys

/// Translates hardware key presses (USB HID usages, as `UIKey.keyCode`
/// reports them) into terminal key events.
public enum KeyTranslator {
    /// USB HID keyboard usages (`UIKeyboardHIDUsage` raw values).
    public enum Usage {
        public static let returnOrEnter = 0x28
        public static let escape = 0x29
        public static let backspace = 0x2A
        public static let tab = 0x2B
        public static let f1 = 0x3A // ... F12 = 0x45
        public static let insert = 0x49
        public static let home = 0x4A
        public static let pageUp = 0x4B
        public static let deleteForward = 0x4C
        public static let end = 0x4D
        public static let pageDown = 0x4E
        public static let right = 0x4F
        public static let left = 0x50
        public static let down = 0x51
        public static let up = 0x52
        public static let keypadEnter = 0x58
        public static let leftControl = 0xE0 // ... right GUI = 0xE7
    }

    static let specialKeys: [Int: Key] = {
        var keys: [Int: Key] = [
            Usage.returnOrEnter: .enter, Usage.keypadEnter: .enter, Usage.tab: .tab,
            Usage.backspace: .backspace, Usage.escape: .escape,
            Usage.left: .left, Usage.right: .right, Usage.down: .down, Usage.up: .up,
            Usage.home: .home, Usage.end: .end, Usage.pageUp: .pageUp, Usage.pageDown: .pageDown,
            Usage.deleteForward: .delete, Usage.insert: .insert,
        ]
        for n in 1 ... 12 {
            keys[Usage.f1 + n - 1] = .function(n)
        }
        return keys
    }()

    /// Whether `usage` is a modifier key on its own (Ctrl, Shift, Alt, Cmd).
    public static func isModifier(_ usage: Int) -> Bool {
        (Usage.leftControl ... Usage.leftControl + 7).contains(usage)
    }

    /// The key event for a press the terminal encodes itself (specials,
    /// control combinations), or nil for text, which goes through the
    /// text input system.
    /// - Parameters:
    ///   - charactersIgnoringModifiers: the key's base characters;
    ///   - characters: what the key typed with its modifiers, for the
    ///     shifted key the kitty protocol reports.
    public static func keyEvent(
        usage: Int, modifiers: KeyModifiers, charactersIgnoringModifiers: String, characters: String = "",
        action: KeyEvent.Action = .press,
    ) -> KeyEvent? {
        // Command combinations belong to the app (copy, paste, font size).
        guard !modifiers.contains(.command) else { return nil }
        if let key = specialKeys[usage] {
            return KeyEvent(key, modifiers: modifiers, action: action)
        }
        guard modifiers.contains(.control) else { return nil }
        return identity(
            usage: usage,
            modifiers: modifiers.subtracting(.shift),
            base: charactersIgnoringModifiers,
            characters: characters,
            action: action,
        )
    }

    /// The key identity of any press, for key bindings and for reporting
    /// its release (releases are only encoded under the kitty protocol's
    /// event-types flag); nil for modifier keys alone.
    public static func identity(
        usage: Int, modifiers: KeyModifiers, base: String, characters: String = "", action: KeyEvent.Action = .press,
    ) -> KeyEvent? {
        guard !isModifier(usage) else { return nil }
        if let key = specialKeys[usage] {
            return KeyEvent(key, modifiers: modifiers, action: action)
        }
        guard let scalar = base.unicodeScalars.first else { return nil }
        let key = lowercased(scalar)
        var shifted: Unicode.Scalar?
        if modifiers.contains(.shift) {
            if let typed = characters.unicodeScalars.first, typed.value >= 0x20, typed != key {
                shifted = typed
            } else if ("a" ... "z").contains(key) {
                shifted = Unicode.Scalar(key.value - 0x20)
            }
        }
        return KeyEvent(
            .character(key),
            modifiers: modifiers,
            action: action,
            shiftedKey: shifted,
            baseLayoutKey: usLayoutKey(usage: usage),
        )
    }

    public static func releaseEvent(usage: Int, modifiers: KeyModifiers, charactersIgnoringModifiers: String) -> KeyEvent? {
        identity(usage: usage, modifiers: modifiers, base: charactersIgnoringModifiers, action: .release)
    }

    /// Input for committed text (software keyboard, hardware text keys,
    /// accessory symbols) with `modifiers` held, such as a sticky Ctrl.
    public static func inputs(forText text: String, modifiers: KeyModifiers) -> [TerminalInput] {
        if modifiers.isEmpty {
            // The software keyboard's return key inserts a newline.
            switch text {
            case "\n", "\r": return [.key(KeyEvent(.enter))]
            case "\t": return [.key(KeyEvent(.tab))]
            case "": return []
            default: return [.text(text)]
            }
        }
        return text.unicodeScalars.map { scalar in
            switch scalar {
            case "\n", "\r": .key(KeyEvent(.enter, modifiers: modifiers))
            case "\t": .key(KeyEvent(.tab, modifiers: modifiers))
            // Ctrl-C and Ctrl-Shift-C mean the same to a terminal.
            case _ where modifiers.contains(.control): .key(KeyEvent(.character(lowercased(scalar)), modifiers: modifiers))
            default: .key(KeyEvent(.character(scalar), modifiers: modifiers, text: String(scalar)))
            }
        }
    }

    private static func lowercased(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        ("A" ... "Z").contains(scalar) ? Unicode.Scalar(scalar.value + 0x20)! : scalar
    }
}

// MARK: - Sticky modifiers

/// Ctrl and Alt toggles on the accessory bar: one tap applies the modifier
/// to the next key, a second tap locks it, a third releases it.
public struct StickyModifiers: Equatable, Sendable {
    public enum State: Equatable, Sendable { case off, latched, locked }

    public private(set) var control = State.off
    public private(set) var alt = State.off

    public init() {}

    public func state(of modifier: KeyModifiers) -> State {
        modifier == .control ? control : modifier == .alt ? alt : .off
    }

    public mutating func tap(_ modifier: KeyModifiers) {
        func next(_ s: State) -> State {
            switch s {
            case .off: .latched
            case .latched: .locked
            case .locked: .off
            }
        }
        if modifier == .control {
            control = next(control)
        } else if modifier == .alt {
            alt = next(alt)
        }
    }

    /// Modifiers currently applied to keys.
    public var active: KeyModifiers {
        var mods: KeyModifiers = []
        if control != .off {
            mods.insert(.control)
        }
        if alt != .off {
            mods.insert(.alt)
        }
        return mods
    }

    /// Returns the active modifiers for one key and releases latched ones.
    public mutating func consume() -> KeyModifiers {
        let mods = active
        if control == .latched {
            control = .off
        }
        if alt == .latched {
            alt = .off
        }
        return mods
    }

    public mutating func reset() {
        self = StickyModifiers()
    }
}

/// Keys on the input accessory bar.
public enum AccessoryKey: Hashable, Sendable {
    case escape, control, alt, tab
    case left, down, up, right
    case symbol(String)

    public static let standard: [AccessoryKey] = [.escape, .control, .alt, .tab, .left, .down, .up, .right]
        + ["|", "~", "/", "-", "_", "\\", "`", "*", "&", "$", "<", ">", "{", "}", "[", "]"].map(AccessoryKey.symbol)

    public var title: String {
        switch self {
        case .escape: "esc"
        case .control: "ctrl"
        case .alt: "alt"
        case .tab: "tab"
        case .left: "←"
        case .down: "↓"
        case .up: "↑"
        case .right: "→"
        case let .symbol(s): s
        }
    }

    /// The sticky modifier this key toggles.
    public var modifier: KeyModifiers? {
        switch self {
        case .control: .control
        case .alt: .alt
        default: nil
        }
    }

    /// Input for a tap with `modifiers` applied; empty for modifier toggles.
    public func inputs(modifiers: KeyModifiers) -> [TerminalInput] {
        let key: Key
        switch self {
        case .control, .alt: return []
        case let .symbol(s): return KeyTranslator.inputs(forText: s, modifiers: modifiers)
        case .escape: key = .escape
        case .tab: key = .tab
        case .left: key = .left
        case .down: key = .down
        case .up: key = .up
        case .right: key = .right
        }
        return [.key(KeyEvent(key, modifiers: modifiers))]
    }
}

// MARK: - Scrolling

/// Turns fractional scroll distances into whole lines, carrying the rest.
public struct ScrollAccumulator: Sendable {
    public private(set) var remainder: CGFloat = 0

    public init() {}

    /// Adds `lines` (positive scrolls back into history) and returns the
    /// whole lines to scroll now.
    public mutating func add(_ lines: CGFloat) -> Int {
        remainder += lines
        let whole = Int(remainder)
        remainder -= CGFloat(whole)
        return whole
    }

    public mutating func reset() {
        remainder = 0
    }
}

/// Exponentially decaying fling, matching `UIScrollView`'s normal
/// deceleration rate.
public struct ScrollMomentum: Sendable {
    /// Velocity retained per millisecond.
    public static let decelerationRate: CGFloat = 0.998
    /// Below this speed (lines per second) the fling stops.
    public static let minimumVelocity: CGFloat = 2

    /// Lines per second; positive scrolls back into history.
    public private(set) var velocity: CGFloat = 0

    public init(velocity: CGFloat = 0) {
        self.velocity = abs(velocity) < Self.minimumVelocity ? 0 : velocity
    }

    public var isActive: Bool {
        velocity != 0
    }

    /// Advances by `dt` seconds and returns the distance travelled, in lines.
    public mutating func step(_ dt: CFTimeInterval) -> CGFloat {
        guard isActive, dt > 0 else { return 0 }
        // v(t) = v0·r^(1000t), so the distance is v0·(r^(1000dt) − 1) / (1000·ln r).
        let k = 1000 * log(Self.decelerationRate)
        let decay = exp(k * CGFloat(dt))
        let distance = velocity * (decay - 1) / k
        velocity *= decay
        if abs(velocity) < Self.minimumVelocity {
            velocity = 0
        }
        return distance
    }

    public mutating func stop() {
        velocity = 0
    }
}

/// How a scroll of whole lines reaches the terminal.
public enum ScrollRouting: Equatable, Sendable {
    /// The application tracks the mouse: wheel events.
    case wheel
    /// Alternate screen with alternate scroll mode: arrow keys.
    case arrows
    /// Move the viewport through scrollback.
    case viewport

    public init(modes: Modes) {
        if !modes.isDisjoint(with: Modes.mouseTracking) {
            self = .wheel
        } else if modes.contains(.alternateScreen), modes.contains(.alternateScroll) {
            self = .arrows
        } else {
            self = .viewport
        }
    }
}

// MARK: - Geometry and selection

/// Maps view points to grid cells.
public struct GridGeometry: Equatable, Sendable {
    /// Points to pixels.
    public var scale: CGFloat
    /// Grid inset in pixels.
    public var padding: CGPoint
    /// Cell size in pixels.
    public var cellSize: CGSize

    public init(scale: CGFloat, padding: CGPoint, cellSize: CGSize) {
        self.scale = scale
        self.padding = padding
        self.cellSize = cellSize
    }

    /// Cell under `point` (view points, top-left origin); may lie outside the grid.
    public func cell(at point: CGPoint) -> (column: Int, row: Int) {
        let x = (point.x * scale - padding.x) / cellSize.width
        let y = (point.y * scale - padding.y) / cellSize.height
        return (Int(x.rounded(.down)), Int(y.rounded(.down)))
    }

    /// Rect of a cell in view points.
    public func rect(column: Int, row: Int) -> CGRect {
        CGRect(
            x: (padding.x + CGFloat(column) * cellSize.width) / scale,
            y: (padding.y + CGFloat(row) * cellSize.height) / scale,
            width: cellSize.width / scale, height: cellSize.height / scale,
        )
    }

    /// Height of one line in points.
    public var lineHeight: CGFloat {
        cellSize.height / scale
    }
}

public enum SelectionMath {
    /// Selection from the span a gesture started on to the span now under
    /// the finger, keeping the whole starting unit (a word stays selected
    /// when dragging backwards).
    public static func extend(
        origin: (start: TerminalPoint, end: TerminalPoint),
        to span: (start: TerminalPoint, end: TerminalPoint),
        rectangle: Bool = false,
    ) -> Selection {
        span.start < origin.start
            ? Selection(anchor: origin.end, head: span.start, rectangle: rectangle)
            : Selection(anchor: origin.start, head: span.end, rectangle: rectangle)
    }

    /// Viewport lines to scroll when dragging past the top (+1, into
    /// history) or bottom (−1) of `rows` visible rows.
    public static func edgeScroll(row: Int, rows: Int) -> Int {
        row < 0 ? 1 : row >= rows ? -1 : 0
    }
}
