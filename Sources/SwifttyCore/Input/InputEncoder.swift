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
    public var key: Key
    public var modifiers: KeyModifiers

    public init(_ key: Key, modifiers: KeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
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
    /// Appends the encoding of `input` to `out`. Returns false when the
    /// input has no encoding in the current modes (e.g. mouse with tracking off).
    @discardableResult
    public static func encode(_ input: TerminalInput, modes: Modes, into out: inout [UInt8]) -> Bool {
        switch input {
        case let .text(s):
            out.append(contentsOf: s.utf8)
        case let .bytes(b):
            out.append(contentsOf: b)
        case let .key(event):
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
