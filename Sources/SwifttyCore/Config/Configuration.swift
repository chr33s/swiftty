import Foundation

/// Colors a theme or the configuration sets; nil leaves the color to the
/// layer below (built-in defaults, then the theme, then the configuration).
public struct ColorSet: Sendable, Equatable {
  public var foreground: UInt32?
  public var background: UInt32?
  public var cursor: UInt32?
  public var cursorText: UInt32?
  public var selectionForeground: UInt32?
  public var selectionBackground: UInt32?
  /// Indexed color overrides (0...255); other indices are ignored on application.
  public var palette: [Int: UInt32] = [:]

  public init() {}

  /// Applies this layer on top of `base`.
  public func applied(to base: Palette) -> Palette {
    var p = base
    p.foreground = foreground ?? p.foreground
    p.background = background ?? p.background
    p.cursor = cursor ?? p.cursor
    p.cursorText = cursorText ?? p.cursorText
    p.selectionForeground = selectionForeground ?? p.selectionForeground
    p.selectionBackground = selectionBackground ?? p.selectionBackground
    for (i, rgb) in palette where (0 ..< 256).contains(i) { p.colors[i] = rgb }
    return p
  }

  /// Handles a color key; returns nil when `key` is not one, or an error.
  mutating func set(_ key: String, _ value: String) -> String?? {
    func color() -> UInt32?? {
      value.isEmpty
        ? .some(nil) : Configuration.parseColor(value).map { .some($0) }
    }
    switch key {
    case "foreground", "background", "cursor-color", "cursor-text",
      "selection-foreground", "selection-background":
      guard let c = color() else { return .some("invalid color \(value)") }
      switch key {
      case "foreground": foreground = c
      case "background": background = c
      case "cursor-color": cursor = c
      case "cursor-text": cursorText = c
      case "selection-foreground": selectionForeground = c
      default: selectionBackground = c
      }
      return .some(nil)
    case "palette":
      if value.isEmpty {
        palette = [:]
        return .some(nil)
      }
      guard let eq = value.firstIndex(of: "="),
        let i = Int(value[..<eq].trimmingCharacters(in: .whitespaces)),
        (0 ..< 256).contains(i),
        let rgb = Configuration.parseColor(
          value[value.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        )
      else { return .some("invalid palette entry \(value)") }
      palette[i] = rgb
      return .some(nil)
    default: return nil
    }
  }
}

/// A theme by name, or one per appearance (`light:A,dark:B`).
public struct ThemeSelection: Sendable, Equatable {
  public var light: String
  public var dark: String

  /// The built-in themes, following the appearance.
  public static let `default` = ThemeSelection(
    light: "Swiftty Light",
    dark: "Swiftty Dark"
  )

  public init(light: String, dark: String) {
    self.light = light
    self.dark = dark
  }

  init?(parsing value: String) {
    let value = value.trimmingCharacters(in: .whitespaces)
    guard !value.isEmpty else { return nil }
    guard
      value.unicodeScalars.contains(where: { ",:=".unicodeScalars.contains($0) }
      )
    else {
      light = value
      dark = value
      return
    }
    guard let fields = Self.fields(value) else { return nil }
    var light: String?
    var dark: String?
    for field in fields {
      let scalars = field.unicodeScalars
      guard let colon = scalars.firstIndex(of: ":") else { return nil }
      let key = String(scalars[..<colon]).trimmingCharacters(in: .whitespaces)
      var name = String(scalars[scalars.index(after: colon)...])
        .trimmingCharacters(in: .whitespaces)
      if name.hasPrefix("\""), name.hasSuffix("\""),
        name.unicodeScalars.count >= 2
      {
        guard let decoded = Self.quotedName(name) else { return nil }
        name = decoded
      }
      switch key {
      case "light": light = name
      case "dark": dark = name
      default: return nil
      }
    }
    guard let light, let dark else { return nil }
    self.light = light
    self.dark = dark
  }

  private static func quotedName(_ value: String) -> String? {
    let content = String(value.unicodeScalars.dropFirst().dropLast())
    var escaped = false
    for scalar in content.unicodeScalars {
      if escaped {
        escaped = false
      } else if scalar == "\\" {
        escaped = true
      } else if scalar == "\"" {
        return nil
      }
    }
    guard let bytes = KeyAction.unescape(content) else { return nil }
    return String(validating: bytes, as: UTF8.self)
  }

  /// Commas inside double quotes belong to the theme name.
  private static func fields(_ value: String) -> [String]? {
    var fields: [String] = []
    var field = ""
    var quoted = false
    var escaped = false
    for scalar in value.unicodeScalars {
      if escaped {
        escaped = false
      } else if scalar == "\\" {
        escaped = true
      } else if scalar == "\"" {
        quoted.toggle()
      } else if scalar == ",", !quoted {
        guard KeyAction.unescape(field) != nil else { return nil }
        fields.append(field)
        field = ""
        continue
      }
      field.unicodeScalars.append(scalar)
    }
    guard !quoted, !escaped, KeyAction.unescape(field) != nil else {
      return nil
    }
    if !field.isEmpty { fields.append(field) }
    return fields
  }

  /// The `theme` value that selects this, as the Settings window writes it.
  public var configurationValue: String {
    func field(_ name: String) -> String {
      let special = ",:=\"\\".unicodeScalars
      guard name.unicodeScalars.contains(where: special.contains) else {
        return name
      }
      let escaped = name.replacing("\\", with: "\\\\")
        .replacing("\"", with: "\\\"")
      return "\"\(escaped)\""
    }
    if light == dark, field(light) == light { return light }
    return "light:\(field(light)),dark:\(field(dark))"
  }

  public func name(for scheme: ColorScheme) -> String {
    scheme == .light ? light : dark
  }
}

/// Frontend settings in Ghostty's configuration syntax: `key = value`
/// lines, `#` comments, repeatable keys, an empty value restoring the
/// default, and `config-file` includes (`?path` when optional).
///
/// Only the keys these frontends implement are recognised; others are
/// reported in `diagnostics` and otherwise ignored, so a Ghostty config
/// file can be shared.
public struct Configuration: Sendable, Equatable {
  /// File-loading budgets, shared across a root file and its include queue.
  public static let maxFileBytes = 1024 * 1024
  public static let maxLoadedBytes = 4 * 1024 * 1024
  public static let maxLoadedFiles = 128
  /// Fonts.
  /// Supported point sizes for configuration and interactive zoom.
  public static let fontSizeRange: ClosedRange<Double> = 1 ... 200
  /// Bounds a programmatic point size; NaN uses the default 13 pt.
  public static func boundedFontSize(_ size: Double) -> Double {
    guard !size.isNaN else { return Configuration().fontSize }
    return min(max(size, fontSizeRange.lowerBound), fontSizeRange.upperBound)
  }

  /// Ghostty's `macos-icon` values.
  static let ghosttyIcons: Set = [
    "official", "blueprint", "chalkboard", "microchip", "glass", "holographic",
    "paper", "retro", "xray", "custom", "custom-style",
  ]

  public var fontFamily = "Menlo"
  public var fontFamilyBold: String?
  public var fontFamilyItalic: String?
  public var fontFamilyBoldItalic: String?
  public var fontSize: Double = 13
  public var fontFeatures: [String] = []
  public var fontVariations: [String: Double] = [:]
  public var fontSyntheticBold = true
  public var fontSyntheticItalic = true
  public var fontSyntheticBoldItalic = true
  /// Named faces (Ghostty's `font-style`, `font-style-bold` etc.).
  public var fontStyle = FaceStyle.default
  public var fontStyleBold = FaceStyle.default
  public var fontStyleItalic = FaceStyle.default
  public var fontStyleBoldItalic = FaceStyle.default
  /// Cell adjustments: a fraction (from `10%`) or points (from `2`).
  public var adjustCellWidth = CellAdjustment()
  public var adjustCellHeight = CellAdjustment()

  /// nil uses `ThemeSelection.default`.
  public var theme: ThemeSelection?
  public var colors = ColorSet()
  public var backgroundOpacity = 0.5
  /// Glass behind a translucent background; zero disables it.
  public var backgroundBlur = 20
  public var minimumContrast = 1.0
  /// Metal post-processing shader file (see `MetalRenderer.setPostProcessShader`).
  public var customShader: String?

  public var cursorStyle: CursorStyle?
  public var cursorHollow = false
  public var cursorStyleBlink: Bool?
  public var cursorOpacity = 1.0
  public var cursorClickToMove = true
  /// DECRQCRA replies (`rectangle-checksum-report`). Off by default: a
  /// program could checksum one cell at a time and read the screen back.
  public var rectangleChecksumReport = false
  public var copyOnSelect = false
  public var mouseHideWhileTyping = false
  public var linkURL = true

  /// History cell budget in bytes (`scrollback-limit`, canonically
  /// `scrollback-limit-bytes`); zero disables history.
  public var scrollbackLimit = 10_000_000
  /// Finite cap on history rows (`scrollback-limit-lines`); zero disables
  /// history.
  public var scrollbackLimitLines = 100_000
  /// Compress idle history where supported (`scrollback-compression`).
  public var scrollbackCompression = true
  /// Ghostty command syntax: shell expansion by default, or `direct:` arguments.
  public var command: String?
  public var workingDirectory: String?
  public var windowPaddingX: Double = 4
  public var windowPaddingY: Double = 4

  public var keybindings = Keybindings.defaults

  /// Problems found while loading, as `file:line: message`.
  public var diagnostics: [String] = []

  /// System display preferences applied by `accommodating(_:)`; never read
  /// from a file.
  public var accommodations = DisplayAccommodations()

  public struct CellAdjustment: Sendable, Equatable {
    public var fraction: Double = 0
    public var points: Double = 0
  }

  public init() {}

  // MARK: Loading

  /// `$XDG_CONFIG_HOME/swiftty/config` (default `~/.config/swiftty/config`).
  public static var defaultURL: URL {
    configHome.appendingPathComponent("swiftty/config")
  }

  static var configHome: URL {
    if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"],
      !xdg.isEmpty
    {
      return URL(fileURLWithPath: xdg)
    }
    return URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent(".config")
  }

  /// Where `theme` names are looked up, in order, before the built-ins.
  public var themeDirectories: [URL] = [
    Configuration.configHome.appendingPathComponent("swiftty/themes"),
    Configuration.configHome.appendingPathComponent("ghostty/themes"),
  ]

  /// Loads `url` (and its includes). A missing file yields the defaults.
  public static func load(from url: URL = defaultURL) -> Configuration {
    var config = Configuration()
    var includes = Includes()
    _ = includes.enqueue(url, optional: true)
    config.loadIncludes(&includes)
    return config
  }

  /// Parses configuration text; relative includes resolve against `directory`.
  public static func parse(
    _ text: String,
    directory: URL? = nil
  ) -> Configuration {
    var config = Configuration()
    config.apply(text, directory: directory)
    return config
  }

  /// A queue shared by all files in one load. Clearing it drops only
  /// pending includes; already applied settings remain in the configuration.
  private struct Includes {
    var files: [(url: URL, optional: Bool)] = []
    var next = 0
    var processed = 0
    var bytesRead = 0
    var reportedFileLimit = false

    mutating func enqueue(_ url: URL, optional: Bool) -> Bool {
      guard processed + files.count - next < Configuration.maxLoadedFiles else {
        return false
      }
      files.append((url, optional))
      return true
    }

    mutating func pop() -> (url: URL, optional: Bool)? {
      guard next < files.count else { return nil }
      defer {
        next += 1
        processed += 1
      }
      return files[next]
    }

    mutating func clear() {
      files.removeAll(keepingCapacity: true)
      next = 0
    }
  }

  private mutating func loadIncludes(_ includes: inout Includes) {
    var loaded: Set<URL> = []
    while let file = includes.pop() {
      guard ConfigurationFile.path(for: file.url) != nil else {
        include(file.url, optional: file.optional, includes: &includes)
        continue
      }
      let canonicalURL = file.url.standardizedFileURL.resolvingSymlinksInPath()
      guard loaded.insert(canonicalURL).inserted else {
        diagnostics.append("\(file.url.path): include cycle")
        continue
      }
      include(file.url, optional: file.optional, includes: &includes)
    }
  }

  private mutating func include(
    _ url: URL,
    optional: Bool,
    includes: inout Includes
  ) {
    let text: String
    let limit = min(
      Self.maxFileBytes,
      max(0, Self.maxLoadedBytes - includes.bytesRead)
    )
    do {
      text = try ConfigurationFile.read(url, maxBytes: limit) {
        includes.bytesRead += $0
      }
    } catch {
      if case ConfigurationFile.Failure.tooLarge = error {
        let reason =
          limit < Self.maxFileBytes
          ? "configuration byte budget exceeded (\(Self.maxLoadedBytes) bytes)"
          : "file exceeds \(Self.maxFileBytes) bytes"
        diagnostics.append("\(url.path): \(reason)")
        return
      }
      let missing =
        (error as? CocoaError)
        .map { $0.code == .fileReadNoSuchFile || $0.code == .fileNoSuchFile }
        ?? false
      if !optional || !missing {
        diagnostics.append("\(url.path): cannot read")
      }
      return
    }
    apply(
      text,
      name: url.path,
      directory: url.deletingLastPathComponent(),
      includes: &includes
    )
  }

  /// Applies `text` on top of the current values.
  public mutating func apply(
    _ text: String,
    name: String = "config",
    directory: URL? = nil
  ) {
    var includes = Includes()
    apply(text, name: name, directory: directory, includes: &includes)
    loadIncludes(&includes)
  }

  private mutating func apply(
    _ text: String,
    name: String,
    directory: URL?,
    includes: inout Includes
  ) {
    for (i, raw)
      in text.split(
        omittingEmptySubsequences: false,
        whereSeparator: \.isNewline
      )
      .enumerated()
    {
      let line = raw.trimmingCharacters(in: .whitespaces)
      let scalars = line.unicodeScalars
      guard !line.isEmpty, scalars.first != "#" else { continue }
      guard let eq = scalars.firstIndex(of: "=") else {
        diagnostics.append("\(name):\(i + 1): expected key = value")
        continue
      }
      let key = String(scalars[..<eq]).trimmingCharacters(in: .whitespaces)
      let rawValue = String(scalars[scalars.index(after: eq)...])
        .trimmingCharacters(in: .whitespaces)
      var value: String =
        if key == "font-feature", rawValue.hasPrefix("\""),
          let closingQuote = rawValue.dropFirst().firstIndex(of: "\""),
          closingQuote != rawValue.index(before: rawValue.endIndex)
        {
          // CSS feature lists quote each tag rather than the whole value.
          rawValue
        } else { Self.unquote(rawValue) }
      if key == "config-file" {
        if value.isEmpty {
          includes.clear()
          continue
        }
        let optional =
          !rawValue.hasPrefix("\"") && value.unicodeScalars.first == "?"
        let path = optional ? String(value.unicodeScalars.dropFirst()) : value
        let url = Self.fileURL(path, directory: directory)
        if !includes.enqueue(url, optional: optional),
          !includes.reportedFileLimit
        {
          includes.reportedFileLimit = true
          diagnostics.append(
            "\(name):\(i + 1): configuration file limit \(Self.maxLoadedFiles) exceeded"
          )
        }
        continue
      }
      if key == "custom-shader", !value.isEmpty, let directory {
        value = Self.fileURL(value, directory: directory).path
      }
      if let error = set(key, value) {
        diagnostics.append("\(name):\(i + 1): \(key): \(error)")
      }
    }
  }

  private static func fileURL(_ path: String, directory: URL?) -> URL {
    let expanded = (path as NSString).expandingTildeInPath
    if expanded.unicodeScalars.first != "/", let directory {
      return directory.appendingPathComponent(expanded)
    }
    return URL(fileURLWithPath: expanded)
  }

  /// Quoted values use the same syntax in configuration and theme files.
  static func unquote(_ value: String) -> String {
    let scalars = value.unicodeScalars
    if scalars.first == "\"", scalars.last == "\"", scalars.count >= 2 {
      return String(scalars.dropFirst().dropLast())
    }
    return value
  }

  /// Sets one key; returns an error message when it cannot be used.
  public mutating func set(_ key: String, _ value: String) -> String? {
    let defaults = Configuration()
    func bool(_ defaultValue: Bool = true) -> Bool? {
      switch value {
      case "": defaultValue
      case "true": true
      case "false": false
      default: nil
      }
    }
    func double(_ range: ClosedRange<Double>) -> Double? {
      Double(value).flatMap { range.contains($0) ? $0 : nil }
    }
    func invalid() -> String { "invalid value \(value)" }
    if let handled = colors.set(key, value) { return handled }
    if key.hasPrefix("font-") || key.hasPrefix("adjust-cell-") {
      return setFont(key, value)
    }
    switch key {
    case "theme":
      if value.isEmpty {
        theme = nil
      } else {
        guard let selection = ThemeSelection(parsing: value) else {
          return invalid()
        }
        theme = selection
      }
    case "background-opacity":
      guard let v = value.isEmpty ? 1 : double(0 ... 1) else {
        return invalid()
      }
      backgroundOpacity = v
    case "background-blur", "background-blur-radius":
      switch value {
      case "true": backgroundBlur = 20
      case "false", "": backgroundBlur = 0
      default:
        guard let v = Int(value), v >= 0 else { return invalid() }
        backgroundBlur = v
      }
    case "minimum-contrast":
      guard let v = value.isEmpty ? 1 : double(1 ... 21) else {
        return invalid()
      }
      minimumContrast = v
    case "custom-shader":
      customShader =
        value.isEmpty ? nil : (value as NSString).expandingTildeInPath
    case "cursor-style":
      switch value {
      case "block", "":
        (cursorStyle, cursorHollow) = (value.isEmpty ? nil : .block, false)
      case "bar": (cursorStyle, cursorHollow) = (.bar, false)
      case "underline": (cursorStyle, cursorHollow) = (.underline, false)
      case "block_hollow": (cursorStyle, cursorHollow) = (.block, true)
      default: return invalid()
      }
    case "cursor-style-blink":
      if value.isEmpty {
        cursorStyleBlink = nil
      } else {
        guard let b = bool() else { return invalid() }
        cursorStyleBlink = b
      }
    case "cursor-opacity":
      guard let v = value.isEmpty ? 1 : double(0 ... 1) else {
        return invalid()
      }
      cursorOpacity = v
    case "cursor-click-to-move":
      guard let b = bool(defaults.cursorClickToMove) else { return invalid() };
      cursorClickToMove = b
    case "rectangle-checksum-report":
      guard let b = bool(defaults.rectangleChecksumReport) else {
        return invalid()
      }
      rectangleChecksumReport = b
    case "copy-on-select":
      switch value {
      case "": copyOnSelect = defaults.copyOnSelect
      case "true", "clipboard": copyOnSelect = true
      case "false": copyOnSelect = false
      default: return invalid()
      }
    case "mouse-hide-while-typing":
      guard let b = bool(defaults.mouseHideWhileTyping) else {
        return invalid()
      };
      mouseHideWhileTyping = b
    case "link-url":
      guard let b = bool(defaults.linkURL) else { return invalid() };
      linkURL = b
    case "scrollback-limit", "scrollback-limit-bytes", "scrollback-limit-lines",
      "scrollback-compression":
      return setScrollback(key, value)
    case "command": command = value.isEmpty ? nil : value
    case "working-directory":
      guard !value.utf8.contains(0) else { return invalid() }
      workingDirectory =
        value.isEmpty ? nil : (value as NSString).expandingTildeInPath
    case "window-padding-x", "window-padding-y": return setPadding(key, value)
    case "macos-icon":
      // Accepted so a shared Ghostty config loads cleanly; Swiftty has
      // one icon.
      guard value.isEmpty || Self.ghosttyIcons.contains(value) else {
        return invalid()
      }
    case "keybind":
      if value.isEmpty {
        keybindings = .defaults
      } else if let error = keybindings.apply(value) {
        return error
      }
    default: return "unknown key"
    }
    return nil
  }

  /// `scrollback-limit` and `scrollback-limit-bytes` share one field; the
  /// last valid assignment wins. Limits are finite and nonnegative.
  private mutating func setScrollback(_ key: String, _ value: String) -> String?
  {
    let defaults = Configuration()
    func invalid() -> String { "invalid value \(value)" }
    func count(_ defaultValue: Int) -> Int? {
      guard let v = value.isEmpty ? defaultValue : Int(value), v >= 0 else {
        return nil
      }
      return v
    }
    switch key {
    case "scrollback-limit-lines":
      guard let v = count(defaults.scrollbackLimitLines) else {
        return invalid()
      }
      scrollbackLimitLines = v
    case "scrollback-compression":
      switch value {
      case "": scrollbackCompression = defaults.scrollbackCompression
      case "true": scrollbackCompression = true
      case "false": scrollbackCompression = false
      default: return invalid()
      }
    default:
      guard let v = count(defaults.scrollbackLimit) else { return invalid() }
      scrollbackLimit = v
    }
    return nil
  }

  private mutating func setPadding(_ key: String, _ value: String) -> String? {
    let defaults = Configuration()
    func invalid() -> String { "invalid value \(value)" }
    // Ghostty allows "left,right"; the larger side is used for both.
    let v: Double
    if value.isEmpty {
      v =
        key == "window-padding-x"
        ? defaults.windowPaddingX : defaults.windowPaddingY
    } else {
      let parts = value.split(separator: ",", omittingEmptySubsequences: false)
      let numbers = parts.compactMap {
        Double($0.trimmingCharacters(in: .whitespaces))
      }
      guard (1 ... 2).contains(parts.count), numbers.count == parts.count,
        numbers.allSatisfy({ $0.isFinite && $0 >= 0 })
      else { return invalid() }
      v = numbers.max()!
    }
    if key == "window-padding-x" {
      windowPaddingX = v
    } else {
      windowPaddingY = v
    }
    return nil
  }

  /// The `font-*` and `adjust-cell-*` keys.
  private mutating func setFont(_ key: String, _ value: String) -> String? {
    let defaults = Configuration()
    func double(_ range: ClosedRange<Double>) -> Double? {
      Double(value).flatMap { range.contains($0) ? $0 : nil }
    }
    func invalid() -> String { "invalid value \(value)" }
    switch key {
    case "font-family": fontFamily = value.isEmpty ? defaults.fontFamily : value
    case "font-family-bold": fontFamilyBold = value.isEmpty ? nil : value
    case "font-family-italic": fontFamilyItalic = value.isEmpty ? nil : value
    case "font-family-bold-italic":
      fontFamilyBoldItalic = value.isEmpty ? nil : value
    case "font-style", "font-style-bold", "font-style-italic",
      "font-style-bold-italic":
      let style: FaceStyle
      switch value {
      case "", "default": style = .default
      // The regular face cannot be disabled.
      case "false" where key == "font-style": return invalid()
      case "false": style = .disabled
      default: style = .named(value)
      }
      switch key {
      case "font-style": fontStyle = style
      case "font-style-bold": fontStyleBold = style
      case "font-style-italic": fontStyleItalic = style
      default: fontStyleBoldItalic = style
      }
    case "font-size":
      guard
        let v = value.isEmpty ? defaults.fontSize : double(Self.fontSizeRange)
      else { return invalid() }
      fontSize = v
    case "font-feature":
      if value.isEmpty {
        fontFeatures = []
      } else {
        fontFeatures += value.split(separator: ",")
          .map { $0.trimmingCharacters(in: .whitespaces) }
      }
    case "font-variation":
      if value.isEmpty {
        fontVariations = [:]
      } else {
        guard let eq = value.firstIndex(of: "=") else { return invalid() }
        let whitespace = CharacterSet(charactersIn: " \t")
        let tag = value[..<eq].trimmingCharacters(in: whitespace)
        guard tag.utf8.count == 4,
          tag.utf8.allSatisfy({ (0x20 ... 0x7E).contains($0) }),
          let v = Double(
            value[value.index(after: eq)...].trimmingCharacters(in: whitespace)
          ), v.isFinite
        else { return invalid() }
        fontVariations[tag] = v
      }
    case "font-synthetic-style":
      switch value {
      case "true", "":
        (fontSyntheticBold, fontSyntheticItalic, fontSyntheticBoldItalic) = (
          true, true, true
        )
      case "false":
        (fontSyntheticBold, fontSyntheticItalic, fontSyntheticBoldItalic) = (
          false, false, false
        )
      default:
        var bold = fontSyntheticBold
        var italic = fontSyntheticItalic
        var boldItalic = fontSyntheticBoldItalic
        for part
          in value.split(separator: ",", omittingEmptySubsequences: false)
          .map({ $0.trimmingCharacters(in: .whitespaces) })
        {
          switch part {
          case "bold": bold = true
          case "no-bold": bold = false
          case "italic": italic = true
          case "no-italic": italic = false
          case "bold-italic": boldItalic = true
          case "no-bold-italic": boldItalic = false
          default: return invalid()
          }
        }
        (fontSyntheticBold, fontSyntheticItalic, fontSyntheticBoldItalic) = (
          bold, italic, boldItalic
        )
      }
    case "adjust-cell-width", "adjust-cell-height":
      var adjustment = CellAdjustment()
      if value.hasSuffix("%"), let v = Double(value.dropLast()), v.isFinite {
        adjustment.fraction = v / 100
      } else if let v = Double(value), v.isFinite {
        adjustment.points = v
      } else if !value.isEmpty {
        return invalid()
      }
      if key == "adjust-cell-width" {
        adjustCellWidth = adjustment
      } else {
        adjustCellHeight = adjustment
      }
    default: return "unknown key"
    }
    return nil
  }

  // MARK: Derived values

  /// The terminal palette for `scheme`: built-in defaults, then the
  /// theme (the default theme when unset), then colors set directly.
  public func palette(for scheme: ColorScheme = .dark) -> Palette {
    var palette = Palette.standard
    palette =
      Themes.colors(
        named: (theme ?? .default).name(for: scheme),
        searching: themeDirectories
      )?
      .applied(to: palette) ?? palette
    return colors.applied(to: palette)
  }

  /// Theme names that could not be loaded (missing, unreadable or invalid).
  /// Everything to report about this configuration, one line each.
  public var problems: [String] {
    diagnostics + missingThemes.map { "theme unavailable: \($0)" }
      + missingFontStyles.map { "font style unavailable: \($0)" }
  }

  public var missingThemes: [String] {
    guard let theme else { return [] }
    return Set([theme.light, theme.dark]).sorted()
      .filter { Themes.colors(named: $0, searching: themeDirectories) == nil }
  }

  /// Configured face styles missing from their families, which fall
  /// back to the default face.
  public var missingFontStyles: [String] {
    let resolver = FontFaceResolver(descriptor: fontDescriptor(scale: 1))
    let styles = [
      (fontStyle, nil), (fontStyleBold, fontFamilyBold),
      (fontStyleItalic, fontFamilyItalic),
      (fontStyleBoldItalic, fontFamilyBoldItalic),
    ]
    var missing: [String] = []
    for (style, family) in styles {
      guard case .named(let name) = style,
        let font = resolver.named(family ?? fontFamily),
        resolver.face(name, in: font) == nil
      else { continue }
      let entry = "\(name) (\(family ?? fontFamily))"
      if !missing.contains(entry) { missing.append(entry) }
    }
    return missing
  }

  public func fontDescriptor(
    scale: CGFloat,
    size: Double? = nil
  ) -> FontDescriptor {
    var d = FontDescriptor(
      family: fontFamily,
      size: CGFloat(Self.boundedFontSize(size ?? fontSize)),
      scale: scale
    )
    d.boldFamily = fontFamilyBold
    d.italicFamily = fontFamilyItalic
    d.boldItalicFamily = fontFamilyBoldItalic
    d.regularStyle = fontStyle
    d.boldStyle = fontStyleBold
    d.italicStyle = fontStyleItalic
    d.boldItalicStyle = fontStyleBoldItalic
    d.features = fontFeatures
    d.variations = fontVariations
    d.synthesizeBold = fontSyntheticBold
    d.synthesizeItalic = fontSyntheticItalic
    d.synthesizeBoldItalic = fontSyntheticBoldItalic
    d.cellWidthAdjust = CGFloat(adjustCellWidth.fraction)
    d.cellHeightAdjust = CGFloat(adjustCellHeight.fraction)
    d.cellWidthOffset = CGFloat(adjustCellWidth.points)
    d.cellHeightOffset = CGFloat(adjustCellHeight.points)
    return d
  }

  /// Render settings; padding is in points, converted with `scale`.
  public func renderOptions(scale: CGFloat) -> RenderOptions {
    var o = RenderOptions()
    o.paddingX = CGFloat(windowPaddingX) * scale
    o.paddingY = CGFloat(windowPaddingY) * scale
    o.backgroundOpacity = backgroundOpacity
    o.minimumContrast = minimumContrast
    o.cursorStyle = cursorStyle
    o.hollowCursor = cursorHollow
    o.cursorOpacity = cursorOpacity
    o.reducesMotion = accommodations.reduceMotion
    return o
  }

  public func sessionConfiguration(
    scheme: ColorScheme = .dark
  ) -> SessionConfiguration {
    #if os(macOS)
    let defaultsToHome = !SessionConfiguration.isCommandLineLaunch
    #else
    let defaultsToHome = false
    #endif
    var s = SessionConfiguration(
      workingDirectory: resolvedWorkingDirectory(defaultsToHome: defaultsToHome)
    )
    if let command { s.command = Self.commandArguments(command) }
    s.scrollbackLimitBytes = scrollbackLimit
    s.scrollbackLimitRows = scrollbackLimitLines
    s.scrollbackCompression = scrollbackCompression
    s.palette = palette(for: scheme)
    s.rectangleChecksumsEnabled = rectangleChecksumReport
    return s
  }

  func resolvedWorkingDirectory(defaultsToHome: Bool) -> String? {
    switch workingDirectory {
    case "home": NSHomeDirectory()
    case "inherit": nil
    case nil: defaultsToHome ? NSHomeDirectory() : nil
    default: workingDirectory
    }
  }

  private static func commandArguments(_ command: String) -> [String] {
    let spaces = CharacterSet(charactersIn: " ")
    var shell = command.trimmingCharacters(in: spaces)
    let scalars = shell.unicodeScalars
    if let colon = scalars.firstIndex(of: ":") {
      let prefix = String(scalars[..<colon])
      let value = String(scalars[scalars.index(after: colon)...])
        .trimmingCharacters(in: spaces)
      switch prefix {
      case "direct":
        return value.unicodeScalars
          .split(separator: " ", omittingEmptySubsequences: false)
          .map(String.init)
      case "shell": shell = value
      default: break
      }
    }
    // Match Ghostty's macOS expansion wrapper: skip profile and rc files, and
    // replace the intermediate shell with the configured login command.
    return ["/bin/bash", "--noprofile", "--norc", "-c", "exec -l " + shell]
  }

  /// Splits a `command` value using shell quoting, without expansions:
  /// whitespace separates them, single quotes are literal, double quotes
  /// allow `\"`, `\\` and `\$`, and a backslash escapes the next scalar.
  /// Backslash-newline continuations are removed outside single quotes.
  public static func arguments(_ command: String) -> [String] {
    var args: [String] = []
    var current = ""
    var inArgument = false
    var quote: Unicode.Scalar?
    var it = command.unicodeScalars.makeIterator()
    while let c = it.next() {
      switch (quote, c) {
      case ("'", "'"), ("\"", "\""): quote = nil
      case ("'", _): current.unicodeScalars.append(c)
      case ("\"", "\\"):
        if let next = it.next() {
          if next == "\n" { continue }
          if !"\"\\$`".unicodeScalars.contains(next) { current.append("\\") }
          current.unicodeScalars.append(next)
        }
      case ("\"", _): current.unicodeScalars.append(c)
      case (nil, "'"), (nil, "\""):
        quote = c
        inArgument = true
      case (nil, "\\"):
        if let next = it.next() {
          if next == "\n" { continue }
          current.unicodeScalars.append(next)
        }
        inArgument = true
      case (nil, _) where c.properties.isWhitespace:
        if inArgument {
          args.append(current)
          current = ""
          inArgument = false
        }
      default:
        current.unicodeScalars.append(c)
        inArgument = true
      }
    }
    if inArgument { args.append(current) }
    return args
  }

  // MARK: Colors

  /// `#rrggbb`, `rrggbb`, `#rgb`, or a basic color name.
  public static func parseColor(_ value: String) -> UInt32? {
    let names: [String: UInt32] = [
      "black": 0x000000, "white": 0xFFFFFF, "red": 0xFF0000, "green": 0x00FF00,
      "blue": 0x0000FF, "yellow": 0xFFFF00, "cyan": 0x00FFFF,
      "magenta": 0xFF00FF, "gray": 0x808080, "grey": 0x808080,
    ]
    if let named = names[value.lowercased()] { return named }
    let hex = value.hasPrefix("#") ? value.dropFirst() : Substring(value)
    guard hex.allSatisfy(\.isHexDigit), let v = UInt32(hex, radix: 16) else {
      return nil
    }
    switch hex.count {
    case 6: return v
    case 3:
      return (v >> 8 & 0xF) * 0x110000 | (v >> 4 & 0xF) * 0x1100 | (v & 0xF)
        * 0x11
    default: return nil
    }
  }
}
