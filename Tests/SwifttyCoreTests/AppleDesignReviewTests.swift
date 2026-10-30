import Foundation
@testable import SwifttyCore
import Testing

/// spec.apple.md A01: the Settings window's in-place key edits.
struct ConfigurationEditorTests {
  @Test
  func `replaces the last line and drops earlier overridden ones`() throws {
    let text = """
      # mine
      font-size = 12
      keybind = super+k=clear_screen
      font-size = 14
      unknown-key = kept

      """
    let edited = try ConfigurationEditor.setting(
      "font-size",
      to: "16",
      in: text
    )
    #expect(
      edited == """
        # mine
        keybind = super+k=clear_screen
        font-size = 16
        unknown-key = kept

        """
    )
    #expect(Configuration.parse(edited).fontSize == 16)
  }

  @Test
  func `appends a missing key and removes one restored to its default`() throws
  {
    let appended = try ConfigurationEditor.setting(
      "copy-on-select",
      to: "true",
      in: "# comment\n"
    )
    #expect(appended == "# comment\ncopy-on-select = true\n")
    let removed = try ConfigurationEditor.setting(
      "copy-on-select",
      to: nil,
      in: appended
    )
    #expect(removed == "# comment\n")
  }

  @Test
  func `comments mentioning the key are not edited`() throws {
    let edited = try ConfigurationEditor.setting(
      "font-size",
      to: "9",
      in: "# font-size = 99\n"
    )
    #expect(edited == "# font-size = 99\nfont-size = 9\n")
  }

  @Test
  func `line endings are kept`() throws {
    let crlf = try ConfigurationEditor.setting(
      "font-size",
      to: "10",
      in: "# a\r\nfont-size = 12\r\nkeybind = super+k=clear_screen\r\n"
    )
    #expect(
      crlf == "# a\r\nfont-size = 10\r\nkeybind = super+k=clear_screen\r\n"
    )
    let appended = try ConfigurationEditor.setting(
      "copy-on-select",
      to: "true",
      in: "# a\r\n"
    )
    #expect(appended == "# a\r\ncopy-on-select = true\r\n")
  }

  @Test
  func `quoted values validate as the loader reads them`() throws {
    let edited = try ConfigurationEditor.setting(
      "font-size",
      to: "\"14\"",
      in: ""
    )
    #expect(Configuration.parse(edited).fontSize == 14)
  }

  @Test
  func `invalid values and repeatable keys are refused`() {
    #expect(throws: ConfigurationEditor.Failure.self) {
      try ConfigurationEditor.setting("font-size", to: "huge", in: "")
    }
    #expect(throws: ConfigurationEditor.Failure.notEditable("keybind")) {
      try ConfigurationEditor.setting("keybind", to: "a=ignore", in: "")
    }
    #expect(throws: ConfigurationEditor.Failure.self) {
      try ConfigurationEditor.setting(
        "font-family",
        to: "A\nfont-size=1",
        in: ""
      )
    }
  }

  @Test
  func `apply writes through a symlink and keeps it a link`() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("dotfile")
    let link = directory.appendingPathComponent("config")
    try "keybind = super+k=clear_screen\n"
      .write(to: target, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: link,
      withDestinationURL: target
    )
    try ConfigurationEditor.apply([("font-size", "15")], to: link)
    let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
    #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
    let text = try String(contentsOf: target, encoding: .utf8)
    #expect(text == "keybind = super+k=clear_screen\nfont-size = 15\n")
  }

  @Test
  func `apply creates a missing file`() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString
    )
    let url = root.appendingPathComponent("swiftty/config")
    defer { try? FileManager.default.removeItem(at: root) }
    try ConfigurationEditor.apply([("theme", "Swiftty Dark")], to: url)
    #expect(Configuration.load(from: url).theme?.dark == "Swiftty Dark")
  }

  @Test(arguments: [
    ThemeSelection(light: "Solarized", dark: "Solarized"),
    ThemeSelection(light: "A", dark: "B"),
    ThemeSelection(light: "Odd, Name", dark: "Quote\"d\\x"),
  ])
  func `theme values round-trip`(_ theme: ThemeSelection) {
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
