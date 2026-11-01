import Foundation
import SwifttyConfig

extension Configuration {
  /// The selected JSONC file, or the default destination for a new file.
  public static var activeURL: URL {
    (try? ConfigDiscovery.resolve()) ?? defaultURL
  }

  public static func load() -> Configuration {
    do {
      if let url = try ConfigDiscovery.resolve() { return load(from: url) }
      return Configuration(jsonc: .default)
    } catch {
      var config = Configuration(jsonc: .default)
      config.diagnostics = [error.localizedDescription]
      return config
    }
  }

  /// Every explicitly selected file is JSONC, regardless of its extension.
  public static func load(from url: URL) -> Configuration {
    do {
      let text = try ConfigurationFile.read(url, maxBytes: maxFileBytes)
      return Configuration(jsonc: try ConfigLoader.decode(text, from: url))
    } catch {
      var config = Configuration(jsonc: .default)
      config.diagnostics = [
        (error as? ConfigError)?.message
          ?? "\(url.path): \(error.localizedDescription)"
      ]
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
    preferredShell = jsonc.terminal.preferredShell
    shellProfiles = jsonc.terminal.shellProfiles
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
    try ConfigLoader.generateTemplate(at: url)
  }
}
