import Foundation

/// Sets individual keys of a configuration file in place, for the native
/// Settings window (spec.apple.md A01). The file stays authoritative:
/// comments, includes, key bindings and keys these frontends do not know
/// are kept byte for byte, and only the edited key's lines change.
///
/// Only keys one line sets completely can be edited; repeatable keys
/// (`keybind`, `palette`, `config-file`, …) stay in the file.
public enum ConfigurationEditor {
  public enum Failure: Error, Equatable, CustomStringConvertible {
    case notEditable(String)
    case invalidValue(key: String, message: String)
    case unreadable(String)

    public var description: String {
      switch self {
      case let .notEditable(key): "\(key) cannot be edited here"
      case let .invalidValue(key, message): "\(key): \(message)"
      case let .unreadable(reason): reason
      }
    }
  }

  public static let editableKeys: Set<String> = [
    "font-family", "font-size", "theme", "background-opacity", "cursor-style",
    "cursor-style-blink", "copy-on-select", "mouse-hide-while-typing",
  ]

  /// `text` with `key` set to `value`; nil removes the key, so the default
  /// (or an included file) applies. The last line setting the key is
  /// replaced and earlier ones, already overridden, are removed; without
  /// one the line is appended.
  public static func setting(
    _ key: String,
    to value: String?,
    in text: String
  ) throws(Failure) -> String {
    guard editableKeys.contains(key) else { throw .notEditable(key) }
    if let value {
      guard !value.contains(where: \.isNewline) else {
        throw .invalidValue(key: key, message: "must be one line")
      }
      // Validated as the loader reads the line (quotes removed).
      let probe = Configuration.parse("\(key) = \(value)")
      if let diagnostic = probe.diagnostics.first {
        let message = diagnostic.split(separator: ": ", maxSplits: 2).last
        throw .invalidValue(key: key, message: message.map(String.init) ?? "")
      }
    }
    // Keep the file's own line endings (CRLF from a synced dotfiles repo).
    let separator =
      text.contains("\r\n")
      ? "\r\n" : text.contains("\r") && !text.contains("\n") ? "\r" : "\n"
    var lines = text.components(separatedBy: separator)
    let matches = lines.indices.filter { Self.key(of: lines[$0]) == key }
    let replacement = value.map { "\(key) = \($0)" }
    if let last = matches.last, let replacement {
      lines[last] = replacement
      for index in matches.dropLast().reversed() { lines.remove(at: index) }
    } else {
      for index in matches.reversed() { lines.remove(at: index) }
      if let replacement {
        // Keep a final newline after the appended line.
        if lines.last == "" { lines.removeLast() }
        lines.append(replacement)
        lines.append("")
      }
    }
    return lines.joined(separator: separator)
  }

  /// Applies `changes` to the file at `url` (created when missing): read
  /// with the loader's bounds, validated, then written atomically to the
  /// symlink's target so a linked dotfile stays linked.
  public static func apply(
    _ changes: [(key: String, value: String?)],
    to url: URL
  ) throws {
    let target = url.resolvingSymlinksInPath()
    var text: String
    do {
      text = try ConfigurationFile.read(
        target,
        maxBytes: Configuration.maxFileBytes
      )
    } catch CocoaError.fileReadNoSuchFile {
      text = "# swiftty configuration (Ghostty syntax)\n"
      try FileManager.default.createDirectory(
        at: target.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
    } catch {
      throw Failure.unreadable("the configuration file could not be read")
    }
    for change in changes {
      text = try setting(change.key, to: change.value, in: text)
    }
    try Data(text.utf8).write(to: target, options: .atomic)
  }

  /// The key a line sets, as the loader reads it.
  static func key(of line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.unicodeScalars.first != "#",
      let eq = trimmed.firstIndex(of: "=")
    else { return nil }
    return trimmed[..<eq].trimmingCharacters(in: .whitespaces)
  }
}
