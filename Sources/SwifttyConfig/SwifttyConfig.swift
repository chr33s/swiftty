import Foundation

public struct SwifttyConfig: Codable, Equatable, Sendable {
  public static let schemaURL =
    "https://raw.githubusercontent.com/chr33s/swiftty/main/schema.json"
  public var schema: String?
  public var font: FontConfig
  public var window: WindowConfig
  public var terminal: TerminalConfig
  public var keybindings: [KeybindingConfig]
  public var theme: String?
  public var copyOnSelect: Bool
  public var mouseHideWhileTyping: Bool
  public var cursorStyle: String?
  public var cursorStyleBlink: Bool?
  public static let `default` = Self()
  public init(
    schema: String? = Self.schemaURL,
    font: FontConfig = .default,
    window: WindowConfig = .default,
    terminal: TerminalConfig = .default,
    keybindings: [KeybindingConfig] = [],
    theme: String? = nil,
    copyOnSelect: Bool = false,
    mouseHideWhileTyping: Bool = false,
    cursorStyle: String? = nil,
    cursorStyleBlink: Bool? = nil
  ) {
    self.schema = schema
    self.font = font
    self.window = window
    self.terminal = terminal
    self.keybindings = keybindings
    self.theme = theme
    self.copyOnSelect = copyOnSelect
    self.mouseHideWhileTyping = mouseHideWhileTyping
    self.cursorStyle = cursorStyle
    self.cursorStyleBlink = cursorStyleBlink
  }
  enum CodingKeys: String, CodingKey {
    case schema = "$schema"
    case font
    case window
    case terminal
    case keybindings
    case theme
    case copyOnSelect = "copy_on_select"
    case mouseHideWhileTyping = "mouse_hide_while_typing"
    case cursorStyle = "cursor_style"
    case cursorStyleBlink = "cursor_style_blink"
  }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    schema =
      values.contains(.schema)
      ? try values.decodeIfPresent(String.self, forKey: .schema)
      : Self.schemaURL
    font =
      values.contains(.font)
      ? try values.decode(FontConfig.self, forKey: .font) : .default
    window =
      values.contains(.window)
      ? try values.decode(WindowConfig.self, forKey: .window) : .default
    terminal =
      values.contains(.terminal)
      ? try values.decode(TerminalConfig.self, forKey: .terminal) : .default
    keybindings =
      values.contains(.keybindings)
      ? try values.decode([KeybindingConfig].self, forKey: .keybindings) : []
    theme = try values.decodeIfPresent(String.self, forKey: .theme)
    copyOnSelect =
      values.contains(.copyOnSelect)
      ? try values.decode(Bool.self, forKey: .copyOnSelect) : false
    mouseHideWhileTyping =
      values.contains(.mouseHideWhileTyping)
      ? try values.decode(Bool.self, forKey: .mouseHideWhileTyping) : false
    cursorStyle = try values.decodeIfPresent(String.self, forKey: .cursorStyle)
    cursorStyleBlink = try values.decodeIfPresent(
      Bool.self,
      forKey: .cursorStyleBlink
    )
  }
}

public struct FontConfig: Codable, Equatable, Sendable {
  public var family: String
  public var size: Double
  public var lineHeight: Double
  public static let `default` = Self()
  public init(
    family: String = "Menlo",
    size: Double = 13,
    lineHeight: Double = 1.2
  ) {
    self.family = family
    self.size = size
    self.lineHeight = lineHeight
  }
  enum CodingKeys: String, CodingKey {
    case family
    case size
    case lineHeight = "line_height"
  }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    family =
      values.contains(.family)
      ? try values.decode(String.self, forKey: .family) : "Menlo"
    size =
      values.contains(.size)
      ? try values.decode(Double.self, forKey: .size) : 13
    lineHeight =
      values.contains(.lineHeight)
      ? try values.decode(Double.self, forKey: .lineHeight) : 1.2
  }
}

public struct WindowConfig: Codable, Equatable, Sendable {
  public var opacity: Double
  public var blur: Bool
  public var padding: Double
  public var width: Double?
  public var height: Double?
  public static let `default` = Self()
  public init(
    opacity: Double = 0.95,
    blur: Bool = true,
    padding: Double = 8,
    width: Double? = nil,
    height: Double? = nil
  ) {
    self.opacity = opacity
    self.blur = blur
    self.padding = padding
    self.width = width
    self.height = height
  }
  enum CodingKeys: String, CodingKey {
    case opacity
    case blur
    case padding
    case width
    case height
  }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    opacity =
      values.contains(.opacity)
      ? try values.decode(Double.self, forKey: .opacity) : 0.95
    blur =
      values.contains(.blur)
      ? try values.decode(Bool.self, forKey: .blur) : true
    width = try values.decodeIfPresent(Double.self, forKey: .width)
    height = try values.decodeIfPresent(Double.self, forKey: .height)
    padding =
      values.contains(.padding)
      ? try values.decode(Double.self, forKey: .padding) : 8
  }
}

public struct TerminalConfig: Codable, Equatable, Sendable {
  public var shell: String?
  public var scrollbackLimit: Int
  public static let `default` = Self()
  public init(shell: String? = nil, scrollbackLimit: Int = 10_000) {
    self.shell = shell
    self.scrollbackLimit = scrollbackLimit
  }
  enum CodingKeys: String, CodingKey {
    case shell
    case scrollbackLimit = "scrollback_limit"
  }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    shell = try values.decodeIfPresent(String.self, forKey: .shell)
    scrollbackLimit =
      values.contains(.scrollbackLimit)
      ? try values.decode(Int.self, forKey: .scrollbackLimit) : 10_000
  }
}

public struct KeybindingConfig: Codable, Equatable, Sendable {
  public var trigger: String
  public var action: String
  public init(trigger: String, action: String) {
    self.trigger = trigger
    self.action = action
  }
}
