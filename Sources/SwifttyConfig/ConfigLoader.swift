import Foundation

public struct ConfigError: LocalizedError, Equatable, Sendable {
  public let url: URL
  public let line: Int
  /// One-based UTF-8 byte column in the original source (tabs count as one).
  public let column: Int
  public let codingPath: [String]
  public let detail: String
  public var message: String {
    let path =
      codingPath.isEmpty ? "" : " [\(codingPath.joined(separator: "."))]"
    return "\(url.path):\(line):\(column):\(path) \(detail)"
  }
  public var errorDescription: String? { message }

  init(
    url: URL,
    source: String,
    offset: Int,
    path: [String] = [],
    detail: String
  ) {
    self.url = url
    codingPath = path
    self.detail = detail
    let bytes = Array(source.utf8)
    var line = 1
    var column = 1
    for index in 0 ..< min(offset, bytes.count) {
      if bytes[index] == 13 {
        line += 1
        column = 1
      } else if bytes[index] == 10 {
        if index == 0 || bytes[index - 1] != 13 { line += 1 }
        column = 1
      } else {
        column += 1
      }
    }
    self.line = line
    self.column = column
  }
}

public enum ConfigLoader {
  public static let maxFileBytes = JSONCParser.maxFileBytes

  public static func load(from url: URL) throws -> SwifttyConfig {
    let source = try JSONCParser.readSource(from: url)
    return try decode(source, from: url)
  }

  public static func decode(
    _ source: String,
    from url: URL = URL(fileURLWithPath: "config.jsonc")
  ) throws -> SwifttyConfig {
    let document = try JSONCDocument(source, from: url)
    let data = document.data
    let index = document.index
    func diagnostic(_ path: [String], _ message: String) -> ConfigError {
      ConfigError(
        url: url,
        source: source,
        offset: index.offset(for: path),
        path: path,
        detail: message
      )
    }
    let config: SwifttyConfig
    do {
      config = try JSONDecoder().decode(SwifttyConfig.self, from: data)
    } catch let error as DecodingError {
      let context: DecodingError.Context
      var missing: String?
      switch error {
      case .dataCorrupted(let c), .typeMismatch(_, let c),
        .valueNotFound(_, let c):
        context = c
      case .keyNotFound(let key, let c):
        context = c
        missing = key.stringValue
      @unknown default: throw error
      }
      var path = context.codingPath.map {
        $0.intValue.map(String.init) ?? $0.stringValue
      }
      if let missing { path.append(missing) }
      throw diagnostic(path, context.debugDescription)
    }
    // Reject unknown keys, including spelling mistakes, consistently with schema.json.
    let allowed: [String: Set<String>] = [
      "": [
        "$schema", "font", "window", "terminal", "keybindings", "theme",
        "copy_on_select", "mouse_hide_while_typing", "cursor_style",
        "cursor_style_blink",
      ], "font": ["family", "size", "line_height"],
      "window": ["opacity", "blur", "padding", "width", "height"],
      "terminal": ["shell", "scrollback_limit"],
      "keybinding": ["trigger", "action"],
    ]
    for path in index.positions.keys.sorted(by: {
      index.offset(for: $0) < index.offset(for: $1)
    }) where !path.isEmpty {
      let parent = path.dropLast()
      let group =
        parent.isEmpty
        ? ""
        : parent.count == 1
          ? parent.first!
          : parent.count == 2 && parent.first == "keybindings"
            ? "keybinding" : nil
      if let group, let keys = allowed[group], !keys.contains(path.last!) {
        throw diagnostic(path, "Unknown configuration key '\(path.last!)'")
      }
    }
    let checks: [([String], Bool, String)] = [
      (
        ["font", "family"], !config.font.family.isEmpty,
        "Font family must not be empty"
      ),
      (
        ["font", "size"], (1 ... 200).contains(config.font.size),
        "Font size must be between 1 and 200"
      ),
      (
        ["font", "line_height"],
        config.font.lineHeight.isFinite && config.font.lineHeight > 0,
        "Line height must be positive"
      ),
      (
        ["window", "opacity"], (0 ... 1).contains(config.window.opacity),
        "Opacity must be between 0 and 1"
      ),
      (
        ["window", "padding"],
        config.window.padding.isFinite && config.window.padding >= 0,
        "Padding must be nonnegative"
      ),
      (
        ["terminal", "scrollback_limit"], config.terminal.scrollbackLimit >= 0,
        "Scrollback limit must be nonnegative"
      ),
      (
        ["terminal", "shell"],
        config.terminal.shell.map { !$0.isEmpty && !$0.contains("\0") } ?? true,
        "Shell must be a nonempty executable path"
      ),
      (
        ["cursor_style"],
        config.cursorStyle.map {
          ["block", "bar", "underline", "block_hollow"].contains($0)
        } ?? true, "Invalid cursor style"
      ),
    ]
    for (key, value) in [
      ("width", config.window.width), ("height", config.window.height),
    ] {
      if let value, !value.isFinite || value <= 0 {
        throw diagnostic(["window", key], "Window dimension must be positive")
      }
    }
    for (path, valid, message) in checks where !valid {
      throw diagnostic(path, message)
    }
    for (i, binding) in config.keybindings.enumerated() {
      for (key, value) in [
        ("trigger", binding.trigger), ("action", binding.action),
      ] where value.isEmpty {
        throw diagnostic(
          ["keybindings", String(i), key],
          "Keybinding \(key) must not be empty"
        )
      }
    }
    return config
  }

  /// Emits canonical JSON (also valid JSONC). Comments are intentionally not retained.
  public static func encode(_ config: SwifttyConfig) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [
      .prettyPrinted, .sortedKeys, .withoutEscapingSlashes,
    ]
    var data = try encoder.encode(config)
    _ = try decode(String(decoding: data, as: UTF8.self))
    data.append(10)
    guard data.count <= maxFileBytes else {
      throw ConfigError(
        url: URL(fileURLWithPath: "config.jsonc"),
        source: "",
        offset: 0,
        detail: "Encoded configuration exceeds \(maxFileBytes) bytes"
      )
    }
    return data
  }

  public static func save(_ config: SwifttyConfig, to url: URL) throws {
    let data = try encode(config)
    let target = url.resolvingSymlinksInPath()
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: target, options: .atomic)
  }

  public static let template = """
    {
      "$schema": "https://raw.githubusercontent.com/chr33s/swiftty/main/schema.json",
      // Omitted settings use internal defaults.
      "font": { "family": "Menlo", "size": 13, "line_height": 1.2, },
      /* Window styling and compositor blur */
      "window": { "opacity": 0.95, "blur": true, "padding": 8, },
      "terminal": { "shell": null, "scrollback_limit": 10000, },
      "keybindings": [],
    }
    """ + "\n"

  /// Explicit, opt-in creation; never replaces an existing file.
  public static func generateTemplate(at url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(template.utf8).write(to: url, options: .withoutOverwriting)
  }
}
