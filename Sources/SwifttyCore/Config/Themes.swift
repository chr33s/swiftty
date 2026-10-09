import Foundation

/// Theme files: Ghostty's format, a configuration file containing only
/// color keys. Looked up by name in the theme directories, then among the
/// built-ins; a name with a `/` is a path.
public enum Themes {
    /// Built-in themes, as theme-file text.
    public static let builtIn: [String: String] = [
        "Swiftty Dark": """
        background = #282c34
        foreground = #ffffff
        cursor-color = #ffffff
        """,
        "Swiftty Light": """
        background = #fafafa
        foreground = #383a42
        cursor-color = #383a42
        selection-background = #c8d6f0
        palette = 0=#383a42
        palette = 1=#e45649
        palette = 2=#50a14f
        palette = 3=#c18401
        palette = 4=#4078f2
        palette = 5=#a626a4
        palette = 6=#0184bc
        palette = 7=#a0a1a7
        palette = 8=#696c77
        palette = 9=#e45649
        palette = 10=#50a14f
        palette = 11=#c18401
        palette = 12=#4078f2
        palette = 13=#a626a4
        palette = 14=#0184bc
        palette = 15=#fafafa
        """,
    ]

    public static func colors(named name: String, searching directories: [URL]) -> ColorSet? {
        guard let text = text(named: name, searching: directories) else { return nil }
        return parse(text)
    }

    static func text(named name: String, searching directories: [URL]) -> String? {
        if name.unicodeScalars.contains("/") {
            return try? String(contentsOfFile: (name as NSString).expandingTildeInPath, encoding: .utf8)
        }
        for directory in directories {
            if let text = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) {
                return text
            }
        }
        return builtIn[name]
    }

    /// The color keys of a theme file; anything else is ignored.
    public static func parse(_ text: String) -> ColorSet {
        var colors = ColorSet()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let scalars = line.unicodeScalars
            guard scalars.first != "#", let eq = scalars.firstIndex(of: "=") else { continue }
            let key = String(scalars[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(scalars[scalars.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            _ = colors.set(key, Configuration.unquote(value))
        }
        return colors
    }
}
