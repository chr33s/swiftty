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
    case csi(String)
    case esc(String)
    /// Swallows the key.
    case ignore

    /// Parses `name[:parameter]`.
    init?(parsing spec: Substring) {
        let parts = spec.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let name = parts[0], parameter = parts.count > 1 ? String(parts[1]) : nil
        func number(_ fallback: Double) -> Double? {
            parameter.map { Double($0) } ?? fallback
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
        case "text": guard let parameter else { return nil }; self = .text(Self.unescape(parameter))
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
        case let .csi(s): [0x1B, 0x5B] + Array(s.utf8)
        case let .esc(s): [0x1B] + Array(s.utf8)
        default: nil
        }
    }

    /// `\n`, `\r`, `\t`, `\\`, `\e` and `\x..` escapes.
    static func unescape(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var it = s.unicodeScalars.makeIterator()
        while let c = it.next() {
            guard c == "\\", let e = it.next() else { out.append(c); continue }
            switch e {
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "t": out.append("\t")
            case "e": out.append("\u{1B}")
            case "x":
                if let a = it.next(), let b = it.next(), let v = UInt32(String([Character(a), Character(b)]), radix: 16),
                   let scalar = Unicode.Scalar(v) {
                    out.append(scalar)
                }
            default: out.append(e)
            }
        }
        return String(out)
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
        for part in spec.split(separator: "+", omittingEmptySubsequences: false) {
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
        let scalars = lower.unicodeScalars
        return scalars.count == 1 ? .character(scalars.first!) : nil
    }
}

/// Trigger → action table, parsed from `keybind` lines.
public struct Keybindings: Sendable, Equatable {
    public private(set) var bindings: [KeyTrigger: KeyAction]

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
            return nil
        }
        // The separator is the first "=" that is not itself the trigger's
        // key (`super+=`); actions may contain "=" (`text:A=1`).
        var separator: String.Index?
        var i = value.startIndex
        while i < value.endIndex {
            if value[i] == "=", i != value.startIndex, value[value.index(before: i)] != "+" {
                separator = i
                break
            }
            i = value.index(after: i)
        }
        guard let eq = separator else { return "expected trigger=action" }
        var trigger = value[..<eq]
        let action = value[value.index(after: eq)...]
        // Prefixes that change scope; all bindings here are surface-local.
        for prefix in ["all:", "performable:", "unconsumed:"] where trigger.hasPrefix(prefix) {
            trigger = trigger.dropFirst(prefix.count)
        }
        if trigger.hasPrefix("global:") || trigger.contains(">") {
            return "global bindings and sequences are not supported"
        }
        guard let parsed = KeyTrigger(parsing: trigger) else { return "unknown trigger \(trigger)" }
        if action == "unbind" {
            bindings[parsed] = nil
            return nil
        }
        guard let parsedAction = KeyAction(parsing: action) else { return "unknown action \(action)" }
        bindings[parsed] = parsedAction
        return nil
    }

    /// The action bound to `trigger`.
    public func action(for trigger: KeyTrigger) -> KeyAction? {
        bindings[trigger]
    }

    public func action(for event: KeyEvent) -> KeyAction? {
        if let action = bindings[KeyTrigger(event.key, modifiers: event.modifiers)] {
            return action
        }
        // Shifted punctuation arrives as its shifted character (`+` for
        // shift+`=`), so a binding written without shift still matches.
        if event.modifiers.contains(.shift), case let .character(c) = event.key, !c.properties.isAlphabetic {
            return bindings[KeyTrigger(event.key, modifiers: event.modifiers.subtracting(.shift))]
        }
        return nil
    }

    /// A trigger bound to `action`, for showing it as a menu shortcut:
    /// the one with the fewest modifiers, ties broken deterministically.
    public func trigger(for action: KeyAction) -> KeyTrigger? {
        bindings.filter { $0.value == action }.keys.min { a, b in
            let ma = a.modifiers.rawValue.nonzeroBitCount, mb = b.modifiers.rawValue.nonzeroBitCount
            return ma != mb ? ma < mb : String(describing: a.key) < String(describing: b.key)
        }
    }
}
