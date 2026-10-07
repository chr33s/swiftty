public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public var rawValue: UInt8
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let alt = KeyModifiers(rawValue: 1 << 1)
    public static let control = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)

    /// xterm modifier parameter (1 + shift/alt/ctrl bits).
    var xtermParameter: Int {
        1 + Int(rawValue & 0b111)
    }
}

public enum Key: Sendable, Hashable {
    /// A key producing `scalar` before modifiers are applied.
    case character(Unicode.Scalar)
    case enter, tab, backspace, escape
    case up, down, left, right
    case home, end, pageUp, pageDown, insert, delete
    case function(Int) // F1...F12
}

public struct KeyEvent: Sendable, Hashable {
    public enum Action: Sendable, Hashable { case press, `repeat`, release }

    public var key: Key
    public var modifiers: KeyModifiers
    /// Releases are only encoded under the kitty protocol's event types flag.
    public var action: Action
    /// Text the key produced, for the kitty protocol's associated text flag.
    public var text: String?
    /// For the kitty protocol's alternate keys flag: the key's character
    /// with shift applied, and the key at the same position on a US
    /// (PC-101) layout.
    public var shiftedKey: Unicode.Scalar?
    public var baseLayoutKey: Unicode.Scalar?

    public init(
        _ key: Key, modifiers: KeyModifiers = [], action: Action = .press, text: String? = nil,
        shiftedKey: Unicode.Scalar? = nil, baseLayoutKey: Unicode.Scalar? = nil,
    ) {
        self.key = key
        self.modifiers = modifiers
        self.action = action
        self.text = text
        self.shiftedKey = shiftedKey
        self.baseLayoutKey = baseLayoutKey
    }
}

public struct MouseEvent: Sendable, Hashable {
    public enum Action: Sendable { case press, release, motion }
    public enum Button: Sendable { case left, middle, right, none, wheelUp, wheelDown, wheelLeft, wheelRight }

    public var action: Action
    public var button: Button
    /// Zero-based cell coordinates.
    public var column: Int
    public var row: Int
    public var modifiers: KeyModifiers

    public init(_ action: Action, _ button: Button, column: Int, row: Int, modifiers: KeyModifiers = []) {
        self.action = action
        self.button = button
        self.column = column
        self.row = row
        self.modifiers = modifiers
    }
}

public enum TerminalInput: Sendable {
    /// Committed text (typed characters, IME output).
    case text(String)
    case key(KeyEvent)
    case paste(String)
    case mouse(MouseEvent)
    case focus(Bool)
    case bytes([UInt8])
}

/// Encodes input into the byte sequences applications expect, following
/// xterm conventions and the terminal's current modes.
public enum InputEncoder {
    /// Kitty encoding is activated by disambiguation or reporting all keys.
    /// Event types, alternate keys, and associated text only refine encoding.
    public static func isKittyKeyboardActive(_ flags: UInt8) -> Bool {
        flags & 0b1001 != 0
    }

    /// Appends the encoding of `input` to `out`. Returns false when the
    /// input has no encoding in the current modes (e.g. mouse with tracking off).
    /// - Parameter keyboardFlags: kitty keyboard protocol flags; bit 0
    ///   (disambiguate) switches ambiguous keys to `CSI … u`.
    @discardableResult
    public static func encode(_ input: TerminalInput, modes: Modes, keyboardFlags: UInt8 = 0, into out: inout [UInt8]) -> Bool {
        switch input {
        case let .text(s):
            out.append(contentsOf: s.utf8)
        case let .bytes(b):
            out.append(contentsOf: b)
        case let .key(event):
            // Kitty encoding needs "disambiguate" or "all keys"; other flags alone
            // only refine those.
            if isKittyKeyboardActive(keyboardFlags) {
                return encodeKittyKey(event, flags: keyboardFlags, modes: modes, into: &out)
            }
            guard event.action != .release else { return false }
            // A printable key's own text (shifted or composed) when no
            // Ctrl/Alt asks for a control encoding.
            if case .character = event.key, let text = event.text, !text.isEmpty,
               event.modifiers.isDisjoint(with: [.control, .alt]) {
                out.append(contentsOf: text.utf8)
                return true
            }
            return encodeKey(event, modes: modes, into: &out)
        case let .paste(s):
            if modes.contains(.bracketedPaste) {
                out.append(contentsOf: "\u{1B}[200~".utf8)
                // Strip ESC so the paste cannot terminate the bracket early.
                for b in s.utf8 where b != 0x1B {
                    out.append(b)
                }
                out.append(contentsOf: "\u{1B}[201~".utf8)
            } else {
                var previous: UInt8 = 0
                for b in s.utf8 {
                    if b == 0x0A {
                        if previous != 0x0D {
                            out.append(0x0D)
                        }
                    } else {
                        out.append(b)
                    }
                    previous = b
                }
            }
        case let .mouse(event):
            return encodeMouse(event, modes: modes, into: &out)
        case let .focus(focused):
            guard modes.contains(.focusEvents) else { return false }
            out.append(contentsOf: focused ? "\u{1B}[I".utf8 : "\u{1B}[O".utf8)
        }
        return true
    }

    // MARK: Keys

    static func encodeKey(_ event: KeyEvent, modes: Modes, into out: inout [UInt8]) -> Bool {
        let mods = event.modifiers.subtracting(.command)
        let alt = mods.contains(.alt)
        switch event.key {
        case let .character(scalar):
            var value = scalar.value
            // Meta without Ctrl sends ESC + the typed (shifted) text.
            if alt, !mods.contains(.control), let text = event.text, !text.isEmpty {
                out.append(0x1B)
                out.append(contentsOf: text.utf8)
                return true
            }
            if mods.contains(.control), let control = controlCode(value) {
                value = UInt32(control)
            }
            if alt {
                out.append(0x1B)
            }
            appendUTF8(value, &out)
        case .enter:
            if alt {
                out.append(0x1B)
            }
            out.append(0x0D)
            if modes.contains(.linefeedNewline) {
                out.append(0x0A)
            }
        case .tab:
            if mods.contains(.shift) {
                out.append(contentsOf: "\u{1B}[Z".utf8)
            } else {
                if alt {
                    out.append(0x1B)
                }; out.append(0x09)
            }
        case .backspace:
            if alt {
                out.append(0x1B)
            }
            out.append(mods.contains(.control) ? 0x08 : 0x7F)
        case .escape:
            if alt {
                out.append(0x1B)
            }
            out.append(0x1B)
        case .up: cursorKey(0x41, mods, modes, &out)
        case .down: cursorKey(0x42, mods, modes, &out)
        case .right: cursorKey(0x43, mods, modes, &out)
        case .left: cursorKey(0x44, mods, modes, &out)
        case .home: cursorKey(0x48, mods, modes, &out)
        case .end: cursorKey(0x46, mods, modes, &out)
        case .insert: tildeKey(2, mods, &out)
        case .delete: tildeKey(3, mods, &out)
        case .pageUp: tildeKey(5, mods, &out)
        case .pageDown: tildeKey(6, mods, &out)
        case let .function(n):
            switch n {
            case 1 ... 4: // SS3 P/Q/R/S, or CSI 1;m P with modifiers
                let final = UInt8(0x50 + n - 1)
                if mods.isEmpty {
                    out.append(contentsOf: [0x1B, 0x4F, final])
                } else {
                    appendCSI(out: &out, "1;\(mods.xtermParameter)", final)
                }
            case 5 ... 12:
                let codes = [15, 17, 18, 19, 20, 21, 23, 24]
                tildeKey(codes[n - 5], mods, &out)
            default:
                return false
            }
        }
        return true
    }

    /// Kitty keyboard protocol (progressive enhancement flags: 1
    /// disambiguate, 2 event types, 8 all keys as escape codes, 16
    /// associated text). Returns false when the event produces nothing.
    static func encodeKittyKey(_ event: KeyEvent, flags: UInt8, modes: Modes, into out: inout [UInt8]) -> Bool {
        let allKeys = flags & 8 != 0, eventTypes = flags & 2 != 0
        if event.action == .release, !eventTypes {
            return false
        }
        var mods = event.modifiers
        var bits = Int(mods.rawValue & 0b111) // shift, alt, ctrl
        if mods.contains(.command) {
            bits |= 8 // super
        }
        mods.remove(.command)
        // Event types are reported only when the application asked (flag 2).
        let event2 = !eventTypes ? 1 : event.action == .repeat ? 2 : event.action == .release ? 3 : 1

        // Functional keys keep their legacy final byte, gaining modifier and
        // event fields only when needed.
        let legacy: (number: Int, final: UInt8)? = switch event.key {
        case .up: (1, 0x41)
        case .down: (1, 0x42)
        case .right: (1, 0x43)
        case .left: (1, 0x44)
        case .home: (1, 0x48)
        case .end: (1, 0x46)
        case .insert: (2, 0x7E)
        case .delete: (3, 0x7E)
        case .pageUp: (5, 0x7E)
        case .pageDown: (6, 0x7E)
        case let .function(n):
            switch n {
            case 1: (1, 0x50)
            case 2: (1, 0x51)
            case 3: (13, 0x7E)
            case 4: (1, 0x53)
            case 5 ... 12: ([15, 17, 18, 19, 20, 21, 23, 24][n - 5], 0x7E)
            default: nil
            }
        default: nil
        }
        if let legacy {
            if bits == 0, event2 == 1 {
                return encodeKey(KeyEvent(event.key), modes: modes, into: &out)
            }
            let params = "\(legacy.number);\(1 + bits)" + (event2 != 1 ? ":\(event2)" : "")
            appendCSI(out: &out, params, legacy.final)
            return true
        }

        let code: UInt32
        var producesText = false
        switch event.key {
        case .escape: code = 27
        case .enter: code = 13
        case .tab: code = 9
        case .backspace: code = 127
        case let .character(scalar):
            code = String(scalar).lowercased().unicodeScalars.first?.value ?? scalar.value
            producesText = bits & ~1 == 0 // nothing but (possibly) shift
        default:
            return false
        }
        let plainControl = event.key == .enter || event.key == .tab || event.key == .backspace
        // Without "all keys", text and unmodified Enter/Tab/Backspace stay legacy
        // (and their releases are not reported).
        if !allKeys, producesText || (plainControl && bits == 0) {
            guard event.action != .release else { return false }
            if producesText, let text = event.text, !text.isEmpty {
                out.append(contentsOf: text.utf8)
                return true
            }
            return encodeKey(KeyEvent(event.key, modifiers: mods), modes: modes, into: &out)
        }
        var params = "\(code)"
        if flags & 4 != 0 {
            // Alternate keys: `code:shifted:base`, each part only when it adds information.
            let shifted = mods.contains(.shift) ? event.shiftedKey.map(\.value).flatMap { $0 != code ? $0 : nil } : nil
            let base = event.baseLayoutKey.map(\.value).flatMap { $0 != code ? $0 : nil }
            if let shifted {
                params += ":\(shifted)"
            }
            if let base {
                params += (shifted == nil ? "::" : ":") + "\(base)"
            }
        }
        if bits != 0 || event2 != 1 {
            params += ";\(1 + bits)" + (event2 != 1 ? ":\(event2)" : "")
        }
        if flags & 16 != 0, allKeys, event.action != .release, let text = event.text, !text.isEmpty,
           text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) {
            if bits == 0, event2 == 1 {
                params += ";1"
            }
            params += ";" + text.unicodeScalars.map { String($0.value) }.joined(separator: ":")
        }
        appendCSI(out: &out, params, 0x75)
        return true
    }

    /// Control-key mapping for printable keys (xterm/VT220 table).
    static func controlCode(_ value: UInt32) -> UInt8? {
        switch value {
        case 0x61 ... 0x7A: UInt8(value - 0x60) // a-z
        case 0x41 ... 0x5A: UInt8(value - 0x40) // A-Z
        case 0x40, 0x20, 0x32: 0x00 // @ space 2
        case 0x5B, 0x33: 0x1B // [ 3
        case 0x5C, 0x34: 0x1C // \ 4
        case 0x5D, 0x35: 0x1D // ] 5
        case 0x5E, 0x36: 0x1E // ^ 6
        case 0x5F, 0x2F, 0x37: 0x1F // _ / 7
        case 0x38, 0x3F: 0x7F // 8 ?
        default: nil
        }
    }

    private static func cursorKey(_ final: UInt8, _ mods: KeyModifiers, _ modes: Modes, _ out: inout [UInt8]) {
        if !mods.isEmpty {
            appendCSI(out: &out, "1;\(mods.xtermParameter)", final)
        } else if modes.contains(.cursorKeys) {
            out.append(contentsOf: [0x1B, 0x4F, final])
        } else {
            out.append(contentsOf: [0x1B, 0x5B, final])
        }
    }

    private static func tildeKey(_ code: Int, _ mods: KeyModifiers, _ out: inout [UInt8]) {
        appendCSI(out: &out, mods.isEmpty ? "\(code)" : "\(code);\(mods.xtermParameter)", 0x7E)
    }

    private static func appendCSI(out: inout [UInt8], _ params: String, _ final: UInt8) {
        out.append(0x1B)
        out.append(0x5B)
        out.append(contentsOf: params.utf8)
        out.append(final)
    }

    @inline(__always)
    static func appendUTF8(_ value: UInt32, _ out: inout [UInt8]) {
        switch value {
        case 0 ..< 0x80:
            out.append(UInt8(value))
        case 0x80 ..< 0x800:
            out.append(UInt8(0xC0 | value >> 6))
            out.append(UInt8(0x80 | value & 0x3F))
        case 0x800 ..< 0x10000:
            out.append(UInt8(0xE0 | value >> 12))
            out.append(UInt8(0x80 | value >> 6 & 0x3F))
            out.append(UInt8(0x80 | value & 0x3F))
        default:
            out.append(UInt8(0xF0 | value >> 18))
            out.append(UInt8(0x80 | value >> 12 & 0x3F))
            out.append(UInt8(0x80 | value >> 6 & 0x3F))
            out.append(UInt8(0x80 | value & 0x3F))
        }
    }

    // MARK: Mouse

    static func encodeMouse(_ event: MouseEvent, modes: Modes, into out: inout [UInt8]) -> Bool {
        let tracking = modes.intersection(Modes.mouseTracking)
        guard !tracking.isEmpty else { return false }
        let isWheel = [.wheelUp, .wheelDown, .wheelLeft, .wheelRight].contains(event.button)

        switch event.action {
        case .press: break
        case .release:
            guard !tracking.contains(.mouseX10), !isWheel else { return false }
        case .motion:
            if tracking.contains(.mouseAny) {
                break
            }
            guard tracking.contains(.mouseButton), event.button != .none else { return false }
        }

        var code = switch event.button {
        case .left: 0
        case .middle: 1
        case .right: 2
        case .none: 3
        case .wheelUp: 64
        case .wheelDown: 65
        case .wheelLeft: 66
        case .wheelRight: 67
        }
        let sgr = modes.contains(.mouseSGR)
        if event.action == .release, !sgr {
            code = 3
        }
        if event.action == .motion {
            code += 32
        }
        if !tracking.contains(.mouseX10) {
            if event.modifiers.contains(.shift) {
                code += 4
            }
            if event.modifiers.contains(.alt) {
                code += 8
            }
            if event.modifiers.contains(.control) {
                code += 16
            }
        }

        let x = max(0, event.column) + 1, y = max(0, event.row) + 1
        if sgr {
            appendCSI(out: &out, "<\(code);\(x);\(y)", event.action == .release ? 0x6D : 0x4D)
        } else if modes.contains(.mouseUTF8) {
            out.append(contentsOf: [0x1B, 0x5B, 0x4D])
            for v in [code + 32, x + 32, y + 32] {
                appendUTF8(UInt32(min(v, 2047)), &out)
            }
        } else {
            guard x + 32 <= 255, y + 32 <= 255 else { return false }
            out.append(contentsOf: [0x1B, 0x5B, 0x4D, UInt8(code + 32), UInt8(x + 32), UInt8(y + 32)])
        }
        return true
    }
}
