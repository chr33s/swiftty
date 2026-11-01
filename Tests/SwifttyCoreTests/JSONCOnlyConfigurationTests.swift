import Foundation
@testable import SwifttyCore
import Testing

struct JSONCOnlyConfigurationTests {
  @Test
  func filenamesDoNotSelectALegacyParserOrWriter() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    for filename in ["config", "custom.conf", "config.json", "config.jsonc"] {
      let file = directory.appendingPathComponent(filename)
      try Configuration.createConfigurationTemplate(at: file)
      #expect(Configuration.load(from: file).diagnostics.isEmpty)
      try ConfigurationEditor.apply([("font-size", "19")], to: file)
      #expect(Configuration.load(from: file).fontSize == 19)
      let legacy = "# legacy\nfont-size = 99\n"
      try Data(legacy.utf8).write(to: file)
      #expect(!Configuration.load(from: file).diagnostics.isEmpty)
      #expect(Configuration.load(from: file).fontSize == 13)
      #expect(throws: (any Error).self) {
        try ConfigurationEditor.apply([("font-size", "20")], to: file)
      }
      #expect(try String(contentsOf: file, encoding: .utf8) == legacy)
    }
    #expect(!Configuration.parse("font-size = 99").diagnostics.isEmpty)
  }

  @Test
  func themesUseJSONCAndRejectLegacyColors() throws {
    let source =
      ##"{/* theme */"background":"#123456","foreground":"white","palette":{"2":"#abcdef",},}"##
    let colors = Themes.parse(source)
    #expect(colors.background == 0x123456)
    #expect(colors.foreground == 0xFFFFFF)
    #expect(colors.palette[2] == 0xABCDEF)
    #expect(Themes.parse("background=#123456") == ColorSet())
    for invalid in [
      ##"{"background":"not-a-color"}"##, ##"{"palette":{"256":"#123456"}}"##,
      "{\"unknown\":true}",
    ] { #expect(Themes.parse(invalid) == ColorSet()) }
    #expect(
      !Configuration().themeDirectories
        .contains { $0.path.contains("/ghostty/") }
    )
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Swiftty Dark")
    try Data("background=#123456".utf8).write(to: file)
    #expect(
      Themes.colors(named: "Swiftty Dark", searching: [directory])?.background
        == Themes.colors(named: "Swiftty Dark", searching: [])?.background
    )
    #expect(Themes.colors(named: file.path, searching: []) == nil)
  }
}
