import Foundation

/// Colors a theme or the configuration sets; nil leaves the color to the
/// layer below (built-in defaults, then the theme, then the configuration).
public struct ColorSet: Sendable, Equatable {
    public var foreground: UInt32?
    public var background: UInt32?
    public var cursor: UInt32?
    public var cursorText: UInt32?
    public var selectionForeground: UInt32?
    public var selectionBackground: UInt32?
    public var palette: [Int: UInt32] = [:]

    public init() {}

    /// Applies this layer on top of `base`.
    public func applied(to base: Palette) -> Palette {
        var p = base
        p.foreground = foreground ?? p.foreground
        p.background = background ?? p.background
        p.cursor = cursor ?? p.cursor
        p.cursorText = cursorText ?? p.cursorText
        p.selectionForeground = selectionForeground ?? p.selectionForeground
        p.selectionBackground = selectionBackground ?? p.selectionBackground
        for (i, rgb) in palette {
            p.colors[i] = rgb
        }
        return p
    }

    /// Handles a color key; returns nil when `key` is not one, or an error.
    mutating func set(_ key: String, _ value: String) -> String?? {
        func color() -> UInt32?? {
            value.isEmpty ? .some(nil) : Configuration.parseColor(value).map { .some($0) }
        }
        switch key {
        case "foreground", "background", "cursor-color", "cursor-text", "selection-foreground", "selection-background":
            guard let c = color() else { return .some("invalid color \(value)") }
            switch key {
            case "foreground": foreground = c
            case "background": background = c
            case "cursor-color": cursor = c
            case "cursor-text": cursorText = c
            case "selection-foreground": selectionForeground = c
            default: selectionBackground = c
            }
            return .some(nil)
        case "palette":
            guard let eq = value.firstIndex(of: "="), let i = Int(value[..<eq].trimmingCharacters(in: .whitespaces)),
                  (0 ..< 256).contains(i),
                  let rgb = Configuration.parseColor(value[value.index(after: eq)...].trimmingCharacters(in: .whitespaces))
            else { return .some("invalid palette entry \(value)") }
            palette[i] = rgb
            return .some(nil)
        default:
            return nil
        }
    }
}

/// A theme by name, or one per appearance (`light:A,dark:B`).
public struct ThemeSelection: Sendable, Equatable {
    public var light: String
    public var dark: String

    init(parsing value: String) {
        var light = value, dark = value
        for part in value.split(separator: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("light:") {
                light = String(trimmed.dropFirst(6))
            } else if trimmed.hasPrefix("dark:") {
                dark = String(trimmed.dropFirst(5))
            }
        }
        self.light = light
        self.dark = dark
    }

    public func name(for scheme: ColorScheme) -> String {
        scheme == .light ? light : dark
    }
}

/// Frontend settings in Ghostty's configuration syntax: `key = value`
/// lines, `#` comments, repeatable keys, an empty value restoring the
/// default, and `config-file` includes (`?path` when optional).
///
/// Only the keys these frontends implement are recognised; others are
/// reported in `diagnostics` and otherwise ignored, so a Ghostty config
/// file can be shared.
public struct Configuration: Sendable, Equatable {
    // Fonts.
    public var fontFamily = "Menlo"
    public var fontFamilyBold: String?
    public var fontFamilyItalic: String?
    public var fontFamilyBoldItalic: String?
    public var fontSize: Double = 13
    public var fontFeatures: [String] = []
    public var fontVariations: [String: Double] = [:]
    public var fontSyntheticBold = true
    public var fontSyntheticItalic = true
    /// Cell adjustments: a fraction (from `10%`) or points (from `2`).
    public var adjustCellWidth = CellAdjustment()
    public var adjustCellHeight = CellAdjustment()

    // Colors.
    public var theme: ThemeSelection?
    public var colors = ColorSet()
    public var backgroundOpacity = 1.0
    /// Blur radius behind a translucent background; 0 for none.
    public var backgroundBlur = 0
    public var minimumContrast = 1.0
    /// Metal post-processing shader file (see `MetalRenderer.setPostProcessShader`).
    public var customShader: String?

    // Cursor and mouse.
    public var cursorStyle: CursorStyle?
    public var cursorHollow = false
    public var cursorStyleBlink: Bool?
    public var cursorOpacity = 1.0
    public var cursorClickToMove = true
    public var copyOnSelect = false
    public var mouseHideWhileTyping = false
    public var linkURL = true

    // Session and window.
    public var scrollbackLimit = 10_000_000
    public var command: String?
    public var workingDirectory: String?
    public var windowPaddingX: Double = 4
    public var windowPaddingY: Double = 4

    public var keybindings = Keybindings.defaults

    /// Problems found while loading, as `file:line: message`.
    public var diagnostics: [String] = []

    public struct CellAdjustment: Sendable, Equatable {
        public var fraction: Double = 0
        public var points: Double = 0
    }

    public init() {}

    // MARK: Loading

    /// `$XDG_CONFIG_HOME/swiftty/config` (default `~/.config/swiftty/config`).
    public static var defaultURL: URL {
        configHome.appendingPathComponent("swiftty/config")
    }

    static var configHome: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config")
    }

    /// Where `theme` names are looked up, in order, before the built-ins.
    public var themeDirectories: [URL] = [
        Configuration.configHome.appendingPathComponent("swiftty/themes"),
        Configuration.configHome.appendingPathComponent("ghostty/themes"),
    ]

    /// Loads `url` (and its includes). A missing file yields the defaults.
    public static func load(from url: URL = defaultURL) -> Configuration {
        var config = Configuration()
        if FileManager.default.fileExists(atPath: url.path) {
            config.include(url, optional: false, depth: 0)
        }
        return config
    }

    /// Parses configuration text; relative includes resolve against `directory`.
    public static func parse(_ text: String, directory: URL? = nil) -> Configuration {
        var config = Configuration()
        config.apply(text, name: "config", directory: directory, depth: 0)
        return config
    }

    private mutating func include(_ url: URL, optional: Bool, depth: Int) {
        guard depth < 10 else {
            diagnostics.append("\(url.path): includes nested too deeply")
            return
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            if !optional {
                diagnostics.append("\(url.path): cannot read")
            }
            return
        }
        apply(text, name: url.path, directory: url.deletingLastPathComponent(), depth: depth)
    }

    /// Applies `text` on top of the current values.
    public mutating func apply(_ text: String, name: String = "config", directory: URL? = nil) {
        apply(text, name: name, directory: directory, depth: 0)
    }

    private mutating func apply(_ text: String, name: String, directory: URL?, depth: Int) {
        for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let eq = line.firstIndex(of: "=") else {
                diagnostics.append("\(name):\(i + 1): expected key = value")
                continue
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            if key == "config-file" {
                let optional = value.hasPrefix("?")
                let path = ((optional ? String(value.dropFirst()) : value) as NSString).expandingTildeInPath
                let url = path.hasPrefix("/") || directory == nil
                    ? URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                    : directory!.appendingPathComponent(path)
                include(url, optional: optional, depth: depth + 1)
                continue
            }
            if let error = set(key, value) {
                diagnostics.append("\(name):\(i + 1): \(key): \(error)")
            }
        }
    }

    /// Sets one key; returns an error message when it cannot be used.
    public mutating func set(_ key: String, _ value: String) -> String? {
        let defaults = Configuration()
        func bool(_ defaultValue: Bool = true) -> Bool? {
            switch value {
            case "": defaultValue
            case "true": true
            case "false": false
            default: nil
            }
        }
        func double(_ range: ClosedRange<Double>) -> Double? {
            Double(value).flatMap { range.contains($0) ? $0 : nil }
        }
        func invalid() -> String {
            "invalid value \(value)"
        }
        if let handled = colors.set(key, value) {
            return handled
        }
        if key.hasPrefix("font-") || key.hasPrefix("adjust-cell-") {
            return setFont(key, value)
        }
        switch key {
        case "theme": theme = value.isEmpty ? nil : ThemeSelection(parsing: value)
        case "background-opacity":
            guard let v = value.isEmpty ? 1 : double(0 ... 1) else { return invalid() }
            backgroundOpacity = v
        case "background-blur", "background-blur-radius":
            switch value {
            case "true": backgroundBlur = 20
            case "false", "": backgroundBlur = 0
            default:
                guard let v = Int(value), v >= 0 else { return invalid() }
                backgroundBlur = v
            }
        case "minimum-contrast":
            guard let v = value.isEmpty ? 1 : double(1 ... 21) else { return invalid() }
            minimumContrast = v
        case "custom-shader": customShader = value.isEmpty ? nil : (value as NSString).expandingTildeInPath
        case "cursor-style":
            switch value {
            case "block", "": (cursorStyle, cursorHollow) = (value.isEmpty ? nil : .block, false)
            case "bar": (cursorStyle, cursorHollow) = (.bar, false)
            case "underline": (cursorStyle, cursorHollow) = (.underline, false)
            case "block_hollow": (cursorStyle, cursorHollow) = (.block, true)
            default: return invalid()
            }
        case "cursor-style-blink":
            if value.isEmpty {
                cursorStyleBlink = nil
            } else {
                guard let b = bool() else { return invalid() }
                cursorStyleBlink = b
            }
        case "cursor-opacity":
            guard let v = value.isEmpty ? 1 : double(0 ... 1) else { return invalid() }
            cursorOpacity = v
        case "cursor-click-to-move": guard let b = bool(defaults.cursorClickToMove) else { return invalid() }; cursorClickToMove = b
        case "copy-on-select":
            switch value {
            case "": copyOnSelect = defaults.copyOnSelect
            case "true", "clipboard": copyOnSelect = true
            case "false": copyOnSelect = false
            default: return invalid()
            }
        case "mouse-hide-while-typing": guard let b = bool(defaults.mouseHideWhileTyping)
            else { return invalid() }; mouseHideWhileTyping = b
        case "link-url": guard let b = bool(defaults.linkURL) else { return invalid() }; linkURL = b
        case "scrollback-limit":
            guard let v = value.isEmpty ? defaults.scrollbackLimit : Int(value), v >= 0 else { return invalid() }
            scrollbackLimit = v
        case "command": command = value.isEmpty ? nil : value
        case "working-directory": workingDirectory = value.isEmpty ? nil : (value as NSString).expandingTildeInPath
        case "window-padding-x", "window-padding-y":
            // Ghostty allows "left,right"; the larger side is used for both.
            let parts = value.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard value.isEmpty || !parts.isEmpty else { return invalid() }
            let v = parts.max() ?? (key == "window-padding-x" ? defaults.windowPaddingX : defaults.windowPaddingY)
            if key == "window-padding-x" {
                windowPaddingX = v
            } else {
                windowPaddingY = v
            }
        case "keybind":
            if value.isEmpty {
                keybindings = .defaults
            } else if let error = keybindings.apply(value) {
                return error
            }
        default:
            return "unknown key"
        }
        return nil
    }

    /// The `font-*` and `adjust-cell-*` keys.
    private mutating func setFont(_ key: String, _ value: String) -> String? {
        let defaults = Configuration()
        func double(_ range: ClosedRange<Double>) -> Double? {
            Double(value).flatMap { range.contains($0) ? $0 : nil }
        }
        func invalid() -> String {
            "invalid value \(value)"
        }
        switch key {
        case "font-family": fontFamily = value.isEmpty ? defaults.fontFamily : value
        case "font-family-bold": fontFamilyBold = value.isEmpty ? nil : value
        case "font-family-italic": fontFamilyItalic = value.isEmpty ? nil : value
        case "font-family-bold-italic": fontFamilyBoldItalic = value.isEmpty ? nil : value
        case "font-size":
            guard let v = value.isEmpty ? defaults.fontSize : double(1 ... 200) else { return invalid() }
            fontSize = v
        case "font-feature":
            if value.isEmpty {
                fontFeatures = []
            } else {
                fontFeatures += value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
        case "font-variation":
            if value.isEmpty {
                fontVariations = [:]
            } else {
                guard let eq = value.firstIndex(of: "="), let v = Double(value[value.index(after: eq)...]) else { return invalid() }
                fontVariations[String(value[..<eq])] = v
            }
        case "font-synthetic-style":
            switch value {
            case "true", "": (fontSyntheticBold, fontSyntheticItalic) = (true, true)
            case "false": (fontSyntheticBold, fontSyntheticItalic) = (false, false)
            default:
                for part in value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                    switch part {
                    case "bold": fontSyntheticBold = true
                    case "no-bold": fontSyntheticBold = false
                    case "italic": fontSyntheticItalic = true
                    case "no-italic": fontSyntheticItalic = false
                    case "bold-italic", "no-bold-italic": break
                    default: return invalid()
                    }
                }
            }
        case "adjust-cell-width", "adjust-cell-height":
            var adjustment = CellAdjustment()
            if value.hasSuffix("%"), let v = Double(value.dropLast()) {
                adjustment.fraction = v / 100
            } else if let v = Double(value) {
                adjustment.points = v
            } else if !value.isEmpty {
                return invalid()
            }
            if key == "adjust-cell-width" {
                adjustCellWidth = adjustment
            } else {
                adjustCellHeight = adjustment
            }
        default:
            return "unknown key"
        }
        return nil
    }

    // MARK: Derived values

    /// The terminal palette for `scheme`: built-in defaults, then the
    /// theme, then colors set directly.
    public func palette(for scheme: ColorScheme = .dark) -> Palette {
        var palette = Palette.standard
        if let theme {
            palette = Themes.colors(named: theme.name(for: scheme), searching: themeDirectories)?.applied(to: palette) ?? palette
        }
        return colors.applied(to: palette)
    }

    /// Theme names that could not be found.
    public var missingThemes: [String] {
        guard let theme else { return [] }
        return Set([theme.light, theme.dark]).sorted().filter { Themes.colors(named: $0, searching: themeDirectories) == nil }
    }

    public func fontDescriptor(scale: CGFloat, size: Double? = nil) -> FontDescriptor {
        var d = FontDescriptor(family: fontFamily, size: CGFloat(size ?? fontSize), scale: scale)
        d.boldFamily = fontFamilyBold
        d.italicFamily = fontFamilyItalic
        d.boldItalicFamily = fontFamilyBoldItalic
        d.features = fontFeatures
        d.variations = fontVariations
        d.synthesizeBold = fontSyntheticBold
        d.synthesizeItalic = fontSyntheticItalic
        d.cellWidthAdjust = CGFloat(adjustCellWidth.fraction)
        d.cellHeightAdjust = CGFloat(adjustCellHeight.fraction)
        d.cellWidthOffset = CGFloat(adjustCellWidth.points)
        d.cellHeightOffset = CGFloat(adjustCellHeight.points)
        return d
    }

    /// Render settings; padding is in points, converted with `scale`.
    public func renderOptions(scale: CGFloat) -> RenderOptions {
        var o = RenderOptions()
        o.paddingX = CGFloat(windowPaddingX) * scale
        o.paddingY = CGFloat(windowPaddingY) * scale
        o.backgroundOpacity = backgroundOpacity
        o.minimumContrast = minimumContrast
        o.cursorStyle = cursorStyle
        o.hollowCursor = cursorHollow
        o.cursorOpacity = cursorOpacity
        return o
    }

    public func sessionConfiguration(scheme: ColorScheme = .dark) -> SessionConfiguration {
        var s = SessionConfiguration(workingDirectory: workingDirectory)
        if let command {
            s.command = Self.arguments(command)
        }
        s.scrollbackLimitBytes = scrollbackLimit
        s.palette = palette(for: scheme)
        return s
    }

    /// Splits a `command` value into arguments as a POSIX shell would:
    /// whitespace separates them, single quotes are literal, double quotes
    /// allow `\"`, `\\` and `\$`, and a backslash escapes the next character.
    public static func arguments(_ command: String) -> [String] {
        var args: [String] = []
        var current = ""
        var inArgument = false
        var quote: Character?
        var it = command.makeIterator()
        while let c = it.next() {
            switch (quote, c) {
            case ("'", "'"), ("\"", "\""):
                quote = nil
            case ("'", _):
                current.append(c)
            case ("\"", "\\"):
                if let next = it.next() {
                    if !"\"\\$`".contains(next) {
                        current.append("\\")
                    }
                    current.append(next)
                }
            case ("\"", _):
                current.append(c)
            case (nil, "'"), (nil, "\""):
                quote = c
                inArgument = true
            case (nil, "\\"):
                if let next = it.next() {
                    current.append(next)
                }
                inArgument = true
            case (nil, _) where c.isWhitespace:
                if inArgument {
                    args.append(current)
                    current = ""
                    inArgument = false
                }
            default:
                current.append(c)
                inArgument = true
            }
        }
        if inArgument {
            args.append(current)
        }
        return args
    }

    // MARK: Colors

    /// `#rrggbb`, `rrggbb`, `#rgb`, or a basic color name.
    public static func parseColor(_ value: String) -> UInt32? {
        let names: [String: UInt32] = [
            "black": 0x000000, "white": 0xFFFFFF, "red": 0xFF0000, "green": 0x00FF00, "blue": 0x0000FF,
            "yellow": 0xFFFF00, "cyan": 0x00FFFF, "magenta": 0xFF00FF, "gray": 0x808080, "grey": 0x808080,
        ]
        if let named = names[value.lowercased()] {
            return named
        }
        let hex = value.hasPrefix("#") ? value.dropFirst() : Substring(value)
        guard hex.allSatisfy(\.isHexDigit), let v = UInt32(hex, radix: 16) else { return nil }
        switch hex.count {
        case 6: return v
        case 3: return (v >> 8 & 0xF) * 0x110000 | (v >> 4 & 0xF) * 0x1100 | (v & 0xF) * 0x11
        default: return nil
        }
    }
}
