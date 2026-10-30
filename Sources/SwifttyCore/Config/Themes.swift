import Foundation

/// Theme files: Ghostty's format, a configuration file containing only
/// color keys. Looked up by name in the theme directories, then among the
/// built-ins; a name with a `/` is a path.
public enum Themes {
  /// Maximum UTF-8 bytes read from one theme file.
  public static let maxFileBytes = 64 * 1024
  /// Built-in themes, as theme-file text: Blackboard, forked for each
  /// appearance.
  public static let builtIn: [String: String] = [
    "Swiftty Dark": """
    background = #0C1021
    foreground = #F8F8F8
    cursor-color = #FFFFFF
    cursor-text = #0C1021
    selection-background = #253B76
    selection-foreground = #F8F8F8
    palette = 0=#0C1021
    palette = 1=#BF392A
    palette = 2=#61CE3C
    palette = 3=#FBDE2D
    palette = 4=#8DA6CE
    palette = 5=#FF6400
    palette = 6=#BECDE6
    palette = 7=#F8F8F8
    palette = 8=#7F90AA
    palette = 9=#D74E41
    palette = 10=#D8FA3C
    palette = 11=#FBDE2D
    palette = 12=#D5E0F3
    palette = 13=#FF6400
    palette = 14=#FFFFFF
    palette = 15=#FFFFFF
    """,
    "Swiftty Light": """
    background = #F8FAFD
    foreground = #1E2840
    cursor-color = #0C1021
    cursor-text = #F8FAFD
    selection-background = #C6D6EE
    selection-foreground = #1E2840
    palette = 0=#0C1021
    palette = 1=#B03028
    palette = 2=#2E7D1B
    palette = 3=#8F6F00
    palette = 4=#3D639C
    palette = 5=#BF4D00
    palette = 6=#35708E
    palette = 7=#5B6B88
    palette = 8=#5B6B88
    palette = 9=#922921
    palette = 10=#1F6410
    palette = 11=#705700
    palette = 12=#2A4E86
    palette = 13=#9E3F00
    palette = 14=#245B77
    palette = 15=#1E2840
    """,
  ]

  /// Built-in theme names and the files in `directories`, sorted.
  public static func available(in directories: [URL]) -> [String] {
    var names = Set(builtIn.keys)
    for directory in directories {
      let files =
        (try? FileManager.default.contentsOfDirectory(
          atPath: directory.path(percentEncoded: false)
        )) ?? []
      names.formUnion(files.filter { !$0.hasPrefix(".") })
    }
    return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  public static func colors(
    named name: String,
    searching directories: [URL]
  ) -> ColorSet? {
    guard let text = text(named: name, searching: directories) else {
      return nil
    }
    return parse(text)
  }

  static func text(named name: String, searching directories: [URL]) -> String?
  {
    guard !name.unicodeScalars.contains("\0") else { return nil }
    if name.unicodeScalars.contains("/") {
      return try? ConfigurationFile.read(
        URL(fileURLWithPath: (name as NSString).expandingTildeInPath),
        maxBytes: maxFileBytes
      )
    }
    for directory in directories {
      if let text = try? ConfigurationFile.read(
        directory.appendingPathComponent(name),
        maxBytes: maxFileBytes
      ) {
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
      guard scalars.first != "#", let eq = scalars.firstIndex(of: "=") else {
        continue
      }
      let key = String(scalars[..<eq]).trimmingCharacters(in: .whitespaces)
      let value = String(scalars[scalars.index(after: eq)...])
        .trimmingCharacters(in: .whitespaces)
      _ = colors.set(key, Configuration.unquote(value))
    }
    return colors
  }
}
