import Foundation
import SwifttyConfig

extension Configuration {
  /// JSONC discovery takes precedence; old Ghostty dotfiles remain a fallback.
  public static var activeURL: URL {
    (try? ConfigDiscovery.resolve())
      ?? (FileManager.default.fileExists(atPath: legacyURL.path)
        ? legacyURL : defaultURL)
  }

  static var legacyURL: URL {
    configHome.appendingPathComponent("swiftty/config")
  }

  public static func load() -> Configuration {
    do {
      if let url = try ConfigDiscovery.resolve() { return loadJSONC(from: url) }
      if FileManager.default.fileExists(atPath: legacyURL.path) {
        return load(from: legacyURL)
      }
      return Configuration(jsonc: .default)
    } catch {
      var config = Configuration(jsonc: .default)
      config.diagnostics = [error.localizedDescription]
      return config
    }
  }

  static func usesJSONC(_ url: URL) -> Bool {
    ["json", "jsonc"].contains(url.pathExtension.lowercased())
      || (CommandLine.arguments.contains("--config")
        && (try? ConfigDiscovery.resolve()) == url)
  }

  static func loadJSONC(from url: URL) -> Configuration {
    do {
      let text = try ConfigurationFile.read(url, maxBytes: maxFileBytes)
      return Configuration(jsonc: try ConfigLoader.decode(text, from: url))
    } catch {
      var config = Configuration(jsonc: .default)
      config.diagnostics = [error.localizedDescription]
      return config
    }
  }

  public init(jsonc: SwifttyConfig) {
    self.init()
    fontFamily = jsonc.font.family
    fontSize = jsonc.font.size
    adjustCellHeight.fraction = jsonc.font.lineHeight - 1
    backgroundOpacity = jsonc.window.opacity
    backgroundBlur = jsonc.window.blur ? 20 : 0
    windowWidth = jsonc.window.width
    windowHeight = jsonc.window.height
    windowPaddingX = jsonc.window.padding
    windowPaddingY = jsonc.window.padding
    scrollbackLimitLines = jsonc.terminal.scrollbackLimit
    if let shell = jsonc.terminal.shell {
      command =
        "shell:'" + shell.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    for (key, value) in [
      ("theme", jsonc.theme), ("cursor-style", jsonc.cursorStyle),
      ("cursor-style-blink", jsonc.cursorStyleBlink.map(String.init)),
    ] {
      if let value, let problem = set(key, value) {
        diagnostics.append("\(key): \(problem)")
      }
    }
    copyOnSelect = jsonc.copyOnSelect
    mouseHideWhileTyping = jsonc.mouseHideWhileTyping
    for binding in jsonc.keybindings {
      if let problem = keybindings.apply("\(binding.trigger)=\(binding.action)")
      {
        diagnostics.append("keybindings: \(problem)")
      }
    }
  }

  public static func createConfigurationTemplate(at url: URL) throws {
    if usesJSONC(url) {
      try ConfigLoader.generateTemplate(at: url)
    } else {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data("# swiftty configuration (Ghostty syntax)\n".utf8)
        .write(to: url, options: .withoutOverwriting)
    }
  }
}

extension ConfigurationEditor {
  static func applyJSONC(
    _ changes: [(key: String, value: String?)],
    to url: URL
  ) throws {
    var config: SwifttyConfig
    do {
      let source = try ConfigurationFile.read(
        url,
        maxBytes: Configuration.maxFileBytes
      )
      config = try ConfigLoader.decode(source, from: url)
    } catch CocoaError.fileReadNoSuchFile { config = .default }
    for (key, value) in changes {
      _ = try setting(key, to: value, in: "")
      let value = value.map(Configuration.unquote)
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
    try ConfigLoader.save(config, to: url)
  }
}
