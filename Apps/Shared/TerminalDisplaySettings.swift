import Foundation
import SwifttyCore

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Terminal font, appearance, cursor, and selection preferences for the
/// roaming client apps (iOS, iPadOS, visionOS, tvOS, Catalyst).
/// Non-sensitive; stored per device in `UserDefaults`.
public struct TerminalDisplaySettings: Hashable, Sendable, Codable {
  public enum Cursor: String, CaseIterable, Identifiable, Hashable, Sendable,
    Codable
  {
    case terminal, block, bar, underline, hollowBlock
    public var id: Self { self }

    public var title: LocalizedStringResource {
      switch self {
      case .terminal: .localized("Set by Program")
      case .block: .localized("Block")
      case .bar: .localized("Bar")
      case .underline: .localized("Underline")
      case .hollowBlock: .localized("Hollow Block")
      }
    }
  }

  public enum Blink: String, CaseIterable, Identifiable, Hashable, Sendable,
    Codable
  {
    case terminal, on, off
    public var id: Self { self }

    public var title: LocalizedStringResource {
      switch self {
      case .terminal: .localized("Set by Program")
      case .on: .localized("On")
      case .off: .localized("Off")
      }
    }
  }

  public static let opacityRange: ClosedRange<Double> = 0.1 ... 1.0
  /// Size choices for platforms without `Stepper` (tvOS).
  public static let pickerFontSizes: [Double] = [
    10, 11, 12, 13, 14, 15, 16, 18, 20, 24, 28, 32,
  ]
  /// Opacity choices for platforms without `Slider` (tvOS).
  public static let pickerOpacities: [Double] = [
    0.5, 0.7, 0.8, 0.9, 0.95, 1.0,
  ]

  public var fontFamily: String
  public var fontSize: Double
  /// Theme name, or `nil` for the built-in system appearance default.
  public var theme: String?
  public var backgroundOpacity: Double
  public var cursor: Cursor
  public var blink: Blink
  public var copyOnSelect: Bool

  public init(
    fontFamily: String = Configuration().fontFamily,
    fontSize: Double = Configuration().fontSize,
    theme: String? = nil,
    backgroundOpacity: Double = Configuration().backgroundOpacity,
    cursor: Cursor = .terminal,
    blink: Blink = .terminal,
    copyOnSelect: Bool = false
  ) {
    let trimmedFamily = fontFamily.trimmingCharacters(in: .whitespaces)
    self.fontFamily =
      trimmedFamily.isEmpty ? Configuration().fontFamily : trimmedFamily
    self.fontSize = Configuration.boundedFontSize(fontSize)
    let trimmedTheme = theme?.trimmingCharacters(in: .whitespaces)
    self.theme = (trimmedTheme?.isEmpty == true) ? nil : trimmedTheme
    self.backgroundOpacity = min(
      max(backgroundOpacity, Self.opacityRange.lowerBound),
      Self.opacityRange.upperBound
    )
    self.cursor = cursor
    self.blink = blink
    self.copyOnSelect = copyOnSelect
  }

  public static let `default` = TerminalDisplaySettings()

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = Self.default
    self.init(
      fontFamily: try c.decodeIfPresent(String.self, forKey: .fontFamily)
        ?? d.fontFamily,
      fontSize: try c.decodeIfPresent(Double.self, forKey: .fontSize)
        ?? d.fontSize,
      theme: try c.decodeIfPresent(String.self, forKey: .theme),
      backgroundOpacity: try c.decodeIfPresent(
        Double.self,
        forKey: .backgroundOpacity
      ) ?? d.backgroundOpacity,
      cursor: try c.decodeIfPresent(Cursor.self, forKey: .cursor) ?? d.cursor,
      blink: try c.decodeIfPresent(Blink.self, forKey: .blink) ?? d.blink,
      copyOnSelect: try c.decodeIfPresent(Bool.self, forKey: .copyOnSelect)
        ?? d.copyOnSelect
    )
  }

  /// Builds a `SwifttyCore.Configuration` reflecting these settings.
  public func configuration() -> Configuration {
    var config = Configuration()
    config.fontFamily = fontFamily
    config.fontSize = Configuration.boundedFontSize(fontSize)
    if let theme {
      _ = config.set("theme", theme)
    } else {
      config.theme = nil
    }
    config.backgroundOpacity = min(
      max(backgroundOpacity, Self.opacityRange.lowerBound),
      Self.opacityRange.upperBound
    )
    switch cursor {
    case .terminal:
      config.cursorStyle = nil
      config.cursorHollow = false
    case .block:
      config.cursorStyle = .block
      config.cursorHollow = false
    case .bar:
      config.cursorStyle = .bar
      config.cursorHollow = false
    case .underline:
      config.cursorStyle = .underline
      config.cursorHollow = false
    case .hollowBlock:
      config.cursorStyle = .block
      config.cursorHollow = true
    }
    switch blink {
    case .terminal: config.cursorStyleBlink = nil
    case .on: config.cursorStyleBlink = true
    case .off: config.cursorStyleBlink = false
    }
    config.copyOnSelect = copyOnSelect
    return config
  }

  /// Installed fixed-pitch font families suitable for terminal rendering.
  public static func availableMonospaceFontFamilies() -> [String] {
    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    let manager = NSFontManager.shared
    return manager.availableFontFamilies
      .filter { family in
        guard !family.hasPrefix("."),
          let members = manager.availableMembers(ofFontFamily: family)
        else { return false }
        return members.contains { member in
          guard member.count > 3, let traits = (member[3] as? NSNumber)?.uintValue
          else { return false }
          return NSFontTraitMask(rawValue: traits).contains(.fixedPitchFontMask)
        }
      }
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    #elseif canImport(UIKit)
    return UIFont.familyNames
      .filter { family in
        guard !family.hasPrefix(".") else { return false }
        return UIFont.fontNames(forFamilyName: family).contains { name in
          UIFont(name: name, size: 12)?
            .fontDescriptor.symbolicTraits.contains(.traitMonoSpace) == true
        }
      }
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    #else
    return [Configuration().fontFamily]
    #endif
  }

  /// Built-in and any discovered theme names.
  public static func availableThemes() -> [String] {
    Themes.available(in: Configuration().themeDirectories)
  }

  // MARK: Persistence

  static let defaultsKey = "terminal.display.v1"

  static func load(from defaults: UserDefaults) -> Self {
    guard let data = defaults.data(forKey: defaultsKey),
      let settings = try? JSONDecoder().decode(Self.self, from: data)
    else { return .default }
    return settings
  }

  func save(to defaults: UserDefaults) {
    if let data = try? JSONEncoder().encode(self) {
      defaults.set(data, forKey: Self.defaultsKey)
    }
  }
}

#if canImport(SwiftUI)
import SwiftUI

/// Settings → Terminal: font, theme, opacity, cursor, and selection options.
struct TerminalSettingsView: View {
  @Bindable
  var model: RoamingAppModel
  @State
  private var fontFamilies: [String] = []
  @State
  private var themes: [String] = []

  var body: some View {
    Form {
      Section(.localized("Font")) {
        Picker(
          .localized("Family"),
          selection: $model.terminalSettings.fontFamily
        ) {
          if !fontFamilies.contains(model.terminalSettings.fontFamily) {
            Text(verbatim: model.terminalSettings.fontFamily)
              .tag(model.terminalSettings.fontFamily)
          }
          ForEach(fontFamilies, id: \.self) { family in
            Text(verbatim: family).tag(family)
          }
        }
        .accessibilityIdentifier("terminal.fontFamily")
        #if !os(tvOS)
        Stepper(
          value: $model.terminalSettings.fontSize,
          in: Configuration.fontSizeRange,
          step: 1
        ) {
          LabeledContent(
            .localized("Size"),
            value: "\(Self.number(model.terminalSettings.fontSize)) pt"
          )
        }
        .accessibilityIdentifier("terminal.fontSize")
        #else
        Picker(
          .localized("Size"),
          selection: $model.terminalSettings.fontSize
        ) {
          if !TerminalDisplaySettings.pickerFontSizes.contains(
            model.terminalSettings.fontSize
          ) {
            Text(
              verbatim: "\(Self.number(model.terminalSettings.fontSize)) pt"
            )
            .tag(model.terminalSettings.fontSize)
          }
          ForEach(TerminalDisplaySettings.pickerFontSizes, id: \.self) { size in
            Text(verbatim: "\(Self.number(size)) pt").tag(size)
          }
        }
        .accessibilityIdentifier("terminal.fontSize")
        #endif
      }
      .listRowBackground(Color.clear)

      Section(.localized("Appearance")) {
        Picker(
          .localized("Theme"),
          selection: Binding(
            get: { model.terminalSettings.theme ?? "" },
            set: { model.terminalSettings.theme = $0.isEmpty ? nil : $0 }
          )
        ) {
          Text("Default", bundle: #bundle).tag("")
          if let theme = model.terminalSettings.theme, !themes.contains(theme) {
            Text(verbatim: theme).tag(theme)
          }
          ForEach(themes, id: \.self) { theme in
            Text(verbatim: theme).tag(theme)
          }
        }
        .accessibilityIdentifier("terminal.theme")
        #if !os(tvOS)
        LabeledContent(.localized("Background Opacity")) {
          Slider(
            value: $model.terminalSettings.backgroundOpacity,
            in: TerminalDisplaySettings.opacityRange
          )
          .accessibilityValue(
            "\(Int((model.terminalSettings.backgroundOpacity * 100).rounded())) percent"
          )
        }
        .accessibilityIdentifier("terminal.opacity")
        #else
        Picker(
          .localized("Background Opacity"),
          selection: $model.terminalSettings.backgroundOpacity
        ) {
          if !TerminalDisplaySettings.pickerOpacities.contains(
            model.terminalSettings.backgroundOpacity
          ) {
            Text(
              verbatim:
                "\(Int((model.terminalSettings.backgroundOpacity * 100).rounded()))%"
            )
            .tag(model.terminalSettings.backgroundOpacity)
          }
          ForEach(TerminalDisplaySettings.pickerOpacities, id: \.self) { value in
            Text(verbatim: "\(Int((value * 100).rounded()))%").tag(value)
          }
        }
        .accessibilityIdentifier("terminal.opacity")
        #endif
      }
      .listRowBackground(Color.clear)

      Section(.localized("Cursor")) {
        Picker(
          .localized("Style"),
          selection: $model.terminalSettings.cursor
        ) {
          ForEach(TerminalDisplaySettings.Cursor.allCases) { cursor in
            Text(cursor.title).tag(cursor)
          }
        }
        .accessibilityIdentifier("terminal.cursorStyle")
        Picker(
          .localized("Blink"),
          selection: $model.terminalSettings.blink
        ) {
          ForEach(TerminalDisplaySettings.Blink.allCases) { blink in
            Text(blink.title).tag(blink)
          }
        }
        .accessibilityIdentifier("terminal.cursorBlink")
      }
      .listRowBackground(Color.clear)

      Section(.localized("Selection")) {
        Toggle(
          .localized("Copy on Select"),
          isOn: $model.terminalSettings.copyOnSelect
        )
        .accessibilityIdentifier("terminal.copyOnSelect")
      }
      .listRowBackground(Color.clear)

      Section {
        Button(.localized("Reset to Defaults"), role: .destructive) {
          model.terminalSettings = .default
        }
        .disabled(model.terminalSettings == .default)
        .accessibilityIdentifier("terminal.reset")
      }
      .listRowBackground(Color.clear)
    }
    .glassListBackground()
    .navigationTitle(.localized("Terminal"))
    .onAppear {
      if fontFamilies.isEmpty {
        fontFamilies = TerminalDisplaySettings.availableMonospaceFontFamilies()
      }
      if themes.isEmpty {
        themes = TerminalDisplaySettings.availableThemes()
      }
    }
  }

  private static func number(_ value: Double) -> String {
    let rounded = (value * 100).rounded() / 100
    return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
  }
}
#endif
