import Foundation
import SwifttyConfig

/// JSONC color themes, looked up by filename in the theme directories, then
/// among the built-ins. A name containing `/` is an explicit path.
public enum Themes {
  /// Maximum UTF-8 bytes read from one theme file.
  public static let maxFileBytes = 64 * 1024
  /// Portable fallbacks for the native Apple light and dark palettes.
  /// On macOS the built-ins resolve semantic AppKit colors at runtime.
  public static let builtIn: [String: String] = [
    "Swiftty Dark": """
    {
      "background": "#1E1E1E",
      "foreground": "#FFFFFF",
      "cursor": "#FFFFFF",
      "cursor_text": "#1E1E1E",
      "selection_background": "#3F638B",
      "selection_foreground": "#FFFFFF",
      "palette": {
        "0": "#1C1C1E",
        "1": "#FF453A",
        "2": "#32D74B",
        "3": "#FFD60A",
        "4": "#0A84FF",
        "5": "#BF5AF2",
        "6": "#64D2FF",
        "7": "#D1D1D6",
        "8": "#8E8E93",
        "9": "#FF6961",
        "10": "#6EE787",
        "11": "#FFE570",
        "12": "#70B7FF",
        "13": "#DA8FFF",
        "14": "#9DE4FF",
        "15": "#FFFFFF"
      }
    }
    """,
    "Swiftty Light": """
    {
      "background": "#FFFFFF",
      "foreground": "#000000",
      "cursor": "#000000",
      "cursor_text": "#FFFFFF",
      "selection_background": "#B3D7FF",
      "selection_foreground": "#000000",
      "palette": {
        "0": "#1C1C1E",
        "1": "#FF3B30",
        "2": "#28CD41",
        "3": "#FFCC00",
        "4": "#007AFF",
        "5": "#AF52DE",
        "6": "#55BEF0",
        "7": "#C7C7CC",
        "8": "#8E8E93",
        "9": "#FF6259",
        "10": "#4CD964",
        "11": "#FFD60A",
        "12": "#409CFF",
        "13": "#BF5AF2",
        "14": "#70D7FF",
        "15": "#FFFFFF"
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
    #if os(macOS)
    if let colors = NativeTheme.colors(named: name) { return colors }
    #endif
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
