import Foundation
@testable import SwifttyCore
import Testing

/// Settings edits are JSONC-only, including files without an extension.
struct ConfigurationEditorTests {
  @Test
  func settingsPreserveOtherFieldsAndRestoreDefaults() throws {
    let source =
      ##"{/* comment */"font":{"size":12},"keybindings":[{"trigger":"cmd+k","action":"clear_screen"}],}"##
    let edited = try ConfigurationEditor.setting(
      "font-size",
      to: "16",
      in: source
    )
    #expect(Configuration.parse(edited).fontSize == 16)
    #expect(
      Configuration.parse(edited).keybindings.trigger(for: .clearScreen) != nil
    )
    #expect(!edited.contains("/*"))
    let reset = try ConfigurationEditor.setting(
      "font-size",
      to: nil,
      in: edited
    )
    #expect(Configuration.parse(reset).fontSize == 13)
  }

  @Test
  func invalidInputAndLegacyDocumentsAreRejected() {
    #expect(throws: (any Error).self) {
      try ConfigurationEditor.setting("font-size", to: "huge", in: "{}")
    }
    #expect(throws: ConfigurationEditor.Failure.notEditable("keybind")) {
      try ConfigurationEditor.setting("keybind", to: "a=ignore", in: "{}")
    }
    #expect(throws: (any Error).self) {
      try ConfigurationEditor.setting(
        "font-size",
        to: "14",
        in: "font-size = 12"
      )
    }
    #expect(throws: (any Error).self) {
      try ConfigurationEditor.setting("font-size", to: "\"14\"", in: "{}")
    }
  }

  @Test
  func stringValuesAreLiteralJSONData() throws {
    let name = "Quoted \"Font\"\nfont-size=1"
    let edited = try ConfigurationEditor.setting(
      "font-family",
      to: name,
      in: "{}"
    )
    let config = Configuration.parse(edited)
    #expect(config.fontFamily == name)
    #expect(config.fontSize == 13)
    #expect(config.diagnostics.isEmpty)
  }

  @Test
  func applyCreatesMissingFilesAndKeepsSymlinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("dotfile")
    let link = root.appendingPathComponent("config.jsonc")
    try ConfigurationEditor.apply([("theme", "Swiftty Dark")], to: target)
    try FileManager.default.createSymbolicLink(
      at: link,
      withDestinationURL: target
    )
    try ConfigurationEditor.apply([("font-size", "15")], to: link)
    #expect(
      try FileManager.default.attributesOfItem(atPath: link.path)[.type]
        as? FileAttributeType == .typeSymbolicLink
    )
    #expect(Configuration.load(from: target).fontSize == 15)
    #expect(Configuration.load(from: target).theme?.dark == "Swiftty Dark")
  }

  @Test(arguments: [
    ThemeSelection(light: "Solarized", dark: "Solarized"),
    ThemeSelection(light: "A", dark: "B"),
    ThemeSelection(light: "Odd, Name", dark: "Quote\"d\\x"),
  ])
  func themeValuesRoundTrip(_ theme: ThemeSelection) {
    #expect(ThemeSelection(parsing: theme.configurationValue) == theme)
  }
}

/// spec.apple.md A05: system display preferences change presentation only.
struct DisplayAccommodationTests {
  @Test
  func `accommodations only make presentation more conservative`() {
    var c = Configuration()
    c.backgroundOpacity = 0.6
    c.backgroundBlur = 20
    c.minimumContrast = 7
    let presented = c.accommodating(
      DisplayAccommodations(reduceTransparency: true, increaseContrast: true)
    )
    #expect(presented.backgroundOpacity == 1)
    #expect(presented.backgroundBlur == 0)
    #expect(presented.minimumContrast == 7)
    c.minimumContrast = 1
    #expect(
      c.accommodating(DisplayAccommodations(increaseContrast: true))
        .minimumContrast == DisplayAccommodations.increasedMinimumContrast
    )
    #expect(c.accommodating(DisplayAccommodations()).backgroundOpacity == 0.6)
  }

  @Test
  func `reduce motion reaches the render options`() {
    let c = Configuration()
      .accommodating(DisplayAccommodations(reduceMotion: true))
    #expect(c.renderOptions(scale: 2).reducesMotion)
    #expect(!Configuration().renderOptions(scale: 2).reducesMotion)
  }
}
