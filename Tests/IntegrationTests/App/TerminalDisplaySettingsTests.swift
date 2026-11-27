import Foundation
@testable import RoamingApp
import SwifttyCore
import Testing

@Suite
struct TerminalDisplaySettingsTests {
  @Test
  func settingsClampAndDecodePartialPayloads() throws {
    let clamped = TerminalDisplaySettings(
      fontFamily: "   ",
      fontSize: 999,
      theme: "  ",
      backgroundOpacity: 0.01
    )
    #expect(clamped.fontFamily == Configuration().fontFamily)
    #expect(clamped.fontSize == Configuration.fontSizeRange.upperBound)
    #expect(clamped.theme == nil)
    #expect(clamped.backgroundOpacity == 0.1)

    let partial = try JSONDecoder()
      .decode(
        TerminalDisplaySettings.self,
        from: Data(#"{"copyOnSelect":true,"cursor":"hollowBlock"}"#.utf8)
      )
    #expect(partial.copyOnSelect)
    #expect(partial.cursor == .hollowBlock)
    #expect(partial.blink == .terminal)
    #expect(partial.fontFamily == Configuration().fontFamily)
  }

  @Test
  func settingsProduceMatchingConfiguration() {
    let custom = TerminalDisplaySettings(
      fontFamily: "Courier",
      fontSize: 16,
      theme: "Swiftty Dark",
      backgroundOpacity: 0.85,
      cursor: .hollowBlock,
      blink: .off,
      copyOnSelect: true
    )
    let config = custom.configuration()
    #expect(config.fontFamily == "Courier")
    #expect(config.fontSize == 16)
    #expect(config.theme?.configurationValue == "Swiftty Dark")
    #expect(config.backgroundOpacity == 0.85)
    #expect(config.cursorStyle == .block)
    #expect(config.cursorHollow == true)
    #expect(config.cursorStyleBlink == false)
    #expect(config.copyOnSelect == true)
  }

  @Test
  func settingsPersistPerDevice() throws {
    let suite = "terminal-display-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(TerminalDisplaySettings.load(from: defaults) == .default)
    let custom = TerminalDisplaySettings(
      fontFamily: "Monaco",
      fontSize: 15,
      theme: "Swiftty Light",
      backgroundOpacity: 0.9,
      cursor: .bar,
      blink: .on,
      copyOnSelect: true
    )
    custom.save(to: defaults)
    #expect(TerminalDisplaySettings.load(from: defaults) == custom)
  }

  @Test
  func availableFontsAndThemesArePopulated() {
    let fonts = TerminalDisplaySettings.availableMonospaceFontFamilies()
    #expect(fonts.contains("Menlo"))
    #expect(!fonts.contains("Helvetica"))
    let themes = TerminalDisplaySettings.availableThemes()
    #expect(themes.contains("Swiftty Dark"))
    #expect(themes.contains("Swiftty Light"))
  }
}
