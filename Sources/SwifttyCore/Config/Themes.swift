import Foundation
import SwifttyConfig

/// JSONC color themes, looked up by filename in the theme directories, then
/// among the built-ins. A name containing `/` is an explicit path.
public enum Themes {
  /// Maximum UTF-8 bytes read from one theme file.
  public static let maxFileBytes = 64 * 1024
  /// Built-in themes, as theme-file text: Blackboard, forked for each
  /// appearance.
  public static let builtIn: [String: String] = [
    "Swiftty Dark": """
    {
      "background": "#0C1021",
      "foreground": "#F8F8F8",
      "cursor": "#FFFFFF",
      "cursor_text": "#0C1021",
      "selection_background": "#253B76",
      "selection_foreground": "#F8F8F8",
      "palette": {
        "0": "#0C1021",
        "1": "#BF392A",
        "2": "#61CE3C",
        "3": "#FBDE2D",
        "4": "#8DA6CE",
        "5": "#FF6400",
        "6": "#BECDE6",
        "7": "#F8F8F8",
        "8": "#7F90AA",
        "9": "#D74E41",
        "10": "#D8FA3C",
        "11": "#FBDE2D",
        "12": "#D5E0F3",
        "13": "#FF6400",
        "14": "#FFFFFF",
        "15": "#FFFFFF"
      }
    }
    """,
    "Swiftty Light": """
    {
      "background": "#F8FAFD",
      "foreground": "#1E2840",
      "cursor": "#0C1021",
      "cursor_text": "#F8FAFD",
      "selection_background": "#C6D6EE",
      "selection_foreground": "#1E2840",
      "palette": {
        "0": "#0C1021",
        "1": "#B03028",
        "2": "#2E7D1B",
        "3": "#8F6F00",
        "4": "#3D639C",
        "5": "#BF4D00",
        "6": "#35708E",
        "7": "#5B6B88",
        "8": "#5B6B88",
        "9": "#922921",
        "10": "#1F6410",
        "11": "#705700",
        "12": "#2A4E86",
        "13": "#9E3F00",
        "14": "#245B77",
        "15": "#1E2840"
      }
    }
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
      names.formUnion(
        files.filter {
          !$0.hasPrefix(".")
            && ["jsonc", "json"]
              .contains(URL(fileURLWithPath: $0).pathExtension)
        }
      )
    }
    return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  public static func colors(
    named name: String,
    searching directories: [URL]
  ) -> ColorSet? {
    guard !name.contains("\0") else { return nil }
    if name.unicodeScalars.contains("/") {
      return read(URL(fileURLWithPath: (name as NSString).expandingTildeInPath))
    }
    for directory in directories {
      if let colors = read(directory.appendingPathComponent(name)) {
        return colors
      }
    }
    return builtIn[name].flatMap(decode)
  }

  private static func read(_ url: URL) -> ColorSet? {
    guard let text = try? ConfigurationFile.read(url, maxBytes: maxFileBytes)
    else { return nil }
    return decode(text)
  }

  /// Invalid JSONC or invalid colors produce no overrides.
  public static func parse(_ text: String) -> ColorSet {
    decode(text) ?? ColorSet()
  }

  private static func decode(_ text: String) -> ColorSet? {
    guard let data = try? JSONCParser.parse(text),
      let object = try? JSONSerialization.jsonObject(with: data)
        as? [String: Any]
    else { return nil }
    let keys = [
      "foreground": "foreground", "background": "background",
      "cursor": "cursor-color", "cursor_text": "cursor-text",
      "selection_foreground": "selection-foreground",
      "selection_background": "selection-background",
    ]
    var colors = ColorSet()
    for (key, value) in object {
      if key == "palette" {
        guard let palette = value as? [String: String] else { return nil }
        for (index, color) in palette {
          guard let number = Int(index), (0 ..< 256).contains(number),
            let rgb = Configuration.parseColor(color)
          else { return nil }
          colors.palette[number] = rgb
        }
      } else {
        guard let name = keys[key], let value = value as? String,
          let result = colors.set(name, value), result == nil
        else { return nil }
      }
    }
    return colors
  }
}
