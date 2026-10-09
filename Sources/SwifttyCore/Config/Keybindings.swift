/// Something a key binding does (Ghostty's keybind actions, for the ones
/// these frontends support).
public enum KeyAction: Hashable, Sendable {
    case copyToClipboard
    case pasteFromClipboard
    case increaseFontSize(Double)
    case decreaseFontSize(Double)
    case resetFontSize
    case selectAll
    case scrollToTop
    case scrollToBottom
    case scrollPageUp
    case scrollPageDown
    case scrollPageLines(Int)
    /// Previous (negative) or next prompt (OSC 133).
    case jumpToPrompt(Int)
    case startSearch
    case searchSelection
    case navigateSearch(next: Bool)
    case endSearch
    case clearScreen
    case reset
    /// Sends text to the application (`text:` takes Zig-style escapes).
    case text(String)
    /// Text escape sequences can also produce bytes outside UTF-8.
    case textBytes([UInt8])
    case csi(String)
    case esc(String)
    /// Swallows the key.
    case ignore

    /// Parses `name[:parameter]`.
    init?(parsing spec: Substring) {
        let parts = spec.unicodeScalars.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(parts[0]), parameter = parts.count > 1 ? String(parts[1]) : nil
        func number(_ fallback: Double) -> Double? {
            guard let parameter else { return fallback }
            guard let value = Double(parameter), value.isFinite else { return nil }
            return value
        }
        switch name {
        case "copy_to_clipboard": self = .copyToClipboard
        case "paste_from_clipboard": self = .pasteFromClipboard
        case "increase_font_size": guard let n = number(1) else { return nil }; self = .increaseFontSize(n)
        case "decrease_font_size": guard let n = number(1) else { return nil }; self = .decreaseFontSize(n)
        case "reset_font_size": self = .resetFontSize
        case "select_all": self = .selectAll
        case "scroll_to_top": self = .scrollToTop
        case "scroll_to_bottom": self = .scrollToBottom
        case "scroll_page_up": self = .scrollPageUp
        case "scroll_page_down": self = .scrollPageDown
        case "scroll_page_lines": guard let n = parameter.flatMap({ Int($0) }) else { return nil }; self = .scrollPageLines(n)
        case "jump_to_prompt": guard let n = parameter.flatMap({ Int($0) }) else { return nil }; self = .jumpToPrompt(n)
        case "start_search": self = .startSearch
        case "search_selection": self = .searchSelection
        case "navigate_search":
            switch parameter {
            case "next": self = .navigateSearch(next: true)
            case "previous": self = .navigateSearch(next: false)
            default: return nil
            }
        case "end_search": self = .endSearch
        case "clear_screen": self = .clearScreen
        case "reset": self = .reset
        case "text":
            guard let parameter, let bytes = Self.unescape(parameter) else { return nil }
            if let text = String(validating: bytes, as: UTF8.self) {
                self = .text(text)
            } else {
                self = .textBytes(bytes)
            }
        case "csi": guard let parameter else { return nil }; self = .csi(parameter)
        case "esc": guard let parameter else { return nil }; self = .esc(parameter)
        case "ignore": self = .ignore
        default: return nil
        }
    }

    /// Bytes for the actions that write to the application.
    public var bytes: [UInt8]? {
        switch self {
        case let .text(s): Array(s.utf8)
        case let .textBytes(bytes): bytes
        case let .csi(s): [0x1B, 0x5B] + Array(s.utf8)
        case let .esc(s): [0x1B] + Array(s.utf8)
        default: nil
        }
    }

    /// Zig string escapes, plus the existing `\e` shorthand for ESC.
    static func unescape(_ s: String) -> [UInt8]? {
        var out: [UInt8] = []
        var it = s.unicodeScalars.makeIterator()
        while let c = it.next() {
            guard c == "\\" else { out.append(contentsOf: String(c).utf8); continue }
            guard let e = it.next() else { return nil }
            switch e {
            case "n": out.append(0x0A)
            case "r": out.append(0x0D)
            case "t": out.append(0x09)
            case "e": out.append(0x1B)
            case "\\", "\"", "'": out.append(UInt8(e.value))
            case "x":
                guard let a = it.next(), let b = it.next(),
                      let high = UInt8(String(a), radix: 16), let low = UInt8(String(b), radix: 16) else { return nil }
                out.append(high * 16 + low)
            case "u":
                guard it.next() == "{" else { return nil }
                var value: UInt32 = 0, digits = 0
                var closed = false
                while let digit = it.next() {
                    if digit == "}" {
                        closed = true
                        break
                    }
                    guard let n = UInt32(String(digit), radix: 16) else { return nil }
                    value = value * 16 + n
                    guard value <= 0x10FFFF else { return nil }
                    digits += 1
                }
                guard closed, digits > 0, let scalar = Unicode.Scalar(value) else { return nil }
                out.append(contentsOf: String(scalar).utf8)
            default: return nil
            }
        }
        return out
    }
}

/// A key plus modifiers. Character keys are stored lowercased, so
/// `shift+a` and `A` with shift name the same trigger.
public struct KeyTrigger: Hashable, Sendable {
    public var key: Key
    public var modifiers: KeyModifiers

    public init(_ key: Key, modifiers: KeyModifiers = []) {
        if case let .character(c) = key, let lower = String(c).lowercased().unicodeScalars.first,
           String(c).lowercased().unicodeScalars.count == 1 {
            self.key = .character(lower)
        } else {
            self.key = key
        }
        self.modifiers = modifiers
    }

    /// Parses Ghostty's `mods+key`, e.g. `super+shift+arrow_up`, `ctrl+a`.
    init?(parsing spec: Substring) {
        var mods: KeyModifiers = []
        var keyName: Substring?
        for scalars in spec.unicodeScalars.split(separator: "+", omittingEmptySubsequences: false) {
            let part = Substring(String(scalars))
            switch part.lowercased() {
            case "shift": mods.insert(.shift)
            case "ctrl", "control": mods.insert(.control)
            case "alt", "opt", "option": mods.insert(.alt)
            case "super", "cmd", "command": mods.insert(.command)
            default:
                guard keyName == nil else { return nil }
                keyName = part
            }
        }
        guard let keyName, let key = Self.key(named: keyName) else { return nil }
        self.init(key, modifiers: mods)
    }

    static func key(named name: Substring) -> Key? {
        let named: [String: Key] = [
            "enter": .enter, "return": .enter, "tab": .tab, "backspace": .backspace, "escape": .escape,
            "arrow_up": .up, "up": .up, "arrow_down": .down, "down": .down,
            "arrow_left": .left, "left": .left, "arrow_right": .right, "right": .right,
            "home": .home, "end": .end, "page_up": .pageUp, "page_down": .pageDown,
            "insert": .insert, "delete": .delete,
            "space": .character(" "), "equal": .character("="), "plus": .character("+"),
            "minus": .character("-"), "comma": .character(","), "period": .character("."),
            "slash": .character("/"), "backslash": .character("\\"), "semicolon": .character(";"),
            "apostrophe": .character("'"), "grave_accent": .character("`"),
            "bracket_left": .character("["), "bracket_right": .character("]"),
            "zero": .character("0"), "one": .character("1"), "two": .character("2"), "three": .character("3"),
            "four": .character("4"), "five": .character("5"), "six": .character("6"), "seven": .character("7"),
            "eight": .character("8"), "nine": .character("9"),
        ]
        let lower = name.lowercased()
        if let key = named[lower] {
            return key
        }
        if lower.hasPrefix("f"), let n = Int(lower.dropFirst()), (1 ... 12).contains(n) {
            return .function(n)
        }
        // Lowercasing can expand a single scalar (e.g. İ) into several.
        // KeyTrigger.init normalizes only mappings representable by one key.
        let scalars = name.unicodeScalars
        return scalars.count == 1 ? .character(scalars.first!) : nil
    }
}

/// Trigger → action table, parsed from `keybind` lines.
public struct Keybindings: Sendable, Equatable {
    public private(set) var bindings: [KeyTrigger: KeyAction]
    private var unconsumed: Set<KeyTrigger> = []
    private var performable: Set<KeyTrigger> = []
    private var allSurfaces: Set<KeyTrigger> = []

    public struct Binding: Sendable {
        public let action: KeyAction
        public let consumesInput: Bool
        public let requiresPerformable: Bool
        public let appliesToAll: Bool
    }

    public init(_ bindings: [KeyTrigger: KeyAction] = [:]) {
        self.bindings = bindings
    }

    /// Ghostty's macOS defaults for the supported actions (`super` is Cmd).
    public static let defaults: Keybindings = {
        var b = Keybindings()
        let table: [(String, String)] = [
            ("super+c", "copy_to_clipboard"), ("super+v", "paste_from_clipboard"),
            ("super+equal", "increase_font_size:1"), ("super+plus", "increase_font_size:1"),
            ("super+minus", "decrease_font_size:1"), ("super+zero", "reset_font_size"),
            ("super+a", "select_all"), ("super+k", "clear_screen"),
            ("super+home", "scroll_to_top"), ("super+end", "scroll_to_bottom"),
            ("super+page_up", "scroll_page_up"), ("super+page_down", "scroll_page_down"),
            ("shift+page_up", "scroll_page_up"), ("shift+page_down", "scroll_page_down"),
            ("super+arrow_up", "jump_to_prompt:-1"), ("super+arrow_down", "jump_to_prompt:1"),
            ("super+f", "start_search"), ("super+e", "search_selection"),
            ("super+g", "navigate_search:next"), ("super+shift+g", "navigate_search:previous"),
        ]
        for (trigger, action) in table {
            _ = b.apply("\(trigger)=\(action)")
        }
        return b
    }()

    /// Applies one `keybind` value: `trigger=action`, `trigger=unbind`, or
    /// `clear`. Returns an error message when it cannot be used.
    public mutating func apply(_ value: String) -> String? {
        if value == "clear" {
            bindings = [:]
            unconsumed = []
            performable = []
            allSurfaces = []
            return nil
        }
        // The separator is the first "=" that is not itself the trigger's
        // key (`super+=`); actions may contain "=" (`text:A=1`).
        var separator: String.Index?
        let input = value.unicodeScalars
        var i = input.startIndex
        while i < input.endIndex {
            if input[i] == "=", i != input.startIndex, input[input.index(before: i)] != "+" {
                separator = i
                break
            }
            i = input.index(after: i)
        }
        guard let eq = separator else { return "expected trigger=action" }
        var trigger = Substring(String(input[..<eq]))
        let action = Substring(String(input[input.index(after: eq)...]))
        var consumesInput = true, all = false, requiresPerformable = false
        while let colon = trigger.unicodeScalars.firstIndex(of: ":") {
            switch trigger[..<colon] {
            case "all": all = true
            case "performable": requiresPerformable = true
            case "unconsumed": consumesInput = false
            default: return "unsupported binding prefix \(trigger[..<colon])"
            }
            trigger = trigger[trigger.unicodeScalars.index(after: colon)...]
        }
        if trigger.hasPrefix("global:") || trigger.contains(">") {
            return "global bindings and sequences are not supported"
        }
        guard let parsed = KeyTrigger(parsing: trigger) else { return "unknown trigger \(trigger)" }
        if action == "unbind" {
            bindings[parsed] = nil
            unconsumed.remove(parsed)
            performable.remove(parsed)
            allSurfaces.remove(parsed)
            return nil
        }
        guard let parsedAction = KeyAction(parsing: action) else { return "unknown action \(action)" }
        bindings[parsed] = parsedAction
        if all {
            allSurfaces.insert(parsed)
        } else {
            allSurfaces.remove(parsed)
        }
        if requiresPerformable, !all {
            performable.insert(parsed)
        } else {
            performable.remove(parsed)
        }
        if consumesInput || all {
            unconsumed.remove(parsed)
        } else {
            unconsumed.insert(parsed)
        }
        return nil
    }

    /// The action bound to `trigger`.
    public func action(for trigger: KeyTrigger) -> KeyAction? {
        bindings[trigger]
    }

    public func action(for event: KeyEvent) -> KeyAction? {
        binding(for: event)?.action
    }

    public func binding(for trigger: KeyTrigger) -> Binding? {
        bindings[trigger].map {
            Binding(
                action: $0, consumesInput: !unconsumed.contains(trigger),
                requiresPerformable: performable.contains(trigger), appliesToAll: allSurfaces.contains(trigger),
            )
        }
    }

    public func binding(for event: KeyEvent) -> Binding? {
        if let binding = binding(for: KeyTrigger(event.key, modifiers: event.modifiers)) {
            return binding
        }
        // Shifted punctuation arrives as its shifted character (`+` for
        // shift+`=`), so a binding written without shift still matches.
        if event.modifiers.contains(.shift), case let .character(c) = event.key, !c.properties.isAlphabetic {
            return binding(for: KeyTrigger(event.key, modifiers: event.modifiers.subtracting(.shift)))
        }
        return nil
    }

    /// A trigger bound to `action`, for showing it as a menu shortcut:
    /// the one with the fewest modifiers, ties broken deterministically.
    public func trigger(for action: KeyAction) -> KeyTrigger? {
        bindings.filter { $0.value == action && !performable.contains($0.key) }.keys.min { a, b in
            let ma = a.modifiers.rawValue.nonzeroBitCount, mb = b.modifiers.rawValue.nonzeroBitCount
            if ma != mb {
                return ma < mb
            }
            let ka = String(describing: a.key), kb = String(describing: b.key)
            return ka != kb ? ka < kb : a.modifiers.rawValue < b.modifiers.rawValue
        }
    }
}
