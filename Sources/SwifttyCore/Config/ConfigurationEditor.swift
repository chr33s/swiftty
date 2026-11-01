import Foundation
import SwifttyConfig

/// Settings edits update the JSONC model and atomically save canonical JSON.
public enum ConfigurationEditor {
  public enum Failure: Error, Equatable, CustomStringConvertible {
    case notEditable(String)
    case invalidValue(key: String, message: String)
    public var description: String {
      switch self {
      case let .notEditable(key): "\(key) cannot be edited here"
      case let .invalidValue(key, message): "\(key): \(message)"
      }
    }
  }

  public static let editableKeys: Set<String> = [
    "font-family", "font-size", "theme", "background-opacity", "cursor-style",
    "cursor-style-blink", "copy-on-select", "mouse-hide-while-typing",
  ]

  /// Values are literal control values, not quoted configuration expressions.
  /// nil restores the corresponding JSONC default.
  private static func update(
    _ key: String,
    to value: String?,
    in config: inout SwifttyConfig
  ) throws {
    guard editableKeys.contains(key) else { throw Failure.notEditable(key) }
    if let value {
      var probe = Configuration()
      if let message = probe.set(key, value) {
        throw Failure.invalidValue(key: key, message: message)
      }
    }
    switch key {
    case "font-family":
      config.font.family =
        value.flatMap { $0.isEmpty ? nil : $0 } ?? FontConfig.default.family
    case "font-size":
      config.font.size = value.flatMap(Double.init) ?? FontConfig.default.size
    case "theme": config.theme = value.flatMap { $0.isEmpty ? nil : $0 }
    case "background-opacity":
      config.window.opacity =
        value.flatMap(Double.init) ?? WindowConfig.default.opacity
    case "cursor-style":
      config.cursorStyle = value.flatMap { $0.isEmpty ? nil : $0 }
    case "cursor-style-blink":
      config.cursorStyleBlink = value.flatMap(Bool.init)
    case "copy-on-select":
      config.copyOnSelect = value.flatMap(Bool.init) ?? false
    case "mouse-hide-while-typing":
      config.mouseHideWhileTyping = value.flatMap(Bool.init) ?? false
    default: throw Failure.notEditable(key)
    }
  }

  public static func setting(
    _ key: String,
    to value: String?,
    in text: String
  ) throws -> String {
    var config = try ConfigLoader.decode(text)
    try update(key, to: value, in: &config)
    return String(decoding: try ConfigLoader.encode(config), as: UTF8.self)
  }

  /// Reads and validates the existing file before writing through its symlink.
  /// A missing file is created; malformed existing files are never overwritten.
  public static func apply(
    _ changes: [(key: String, value: String?)],
    to url: URL
  ) throws {
    var config: SwifttyConfig
    do {
      config = try ConfigLoader.decode(
        ConfigurationFile.read(url, maxBytes: Configuration.maxFileBytes),
        from: url
      )
    } catch CocoaError.fileReadNoSuchFile { config = .default }
    for (key, value) in changes { try update(key, to: value, in: &config) }
    try ConfigLoader.save(config, to: url)
  }
}
