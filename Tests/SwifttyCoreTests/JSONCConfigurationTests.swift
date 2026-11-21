import Foundation
import Testing
@testable import SwifttyCore

struct JSONCConfigurationTests {
  @Test
  func loadsAndBoundsTheMouseScrollMultiplier() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let url = directory.appendingPathComponent("config.jsonc")
    try #"{ "mouse_scroll_multiplier": 1 }"#
      .write(to: url, atomically: true, encoding: .utf8)
    let config = Configuration.load(from: url)
    #expect(config.diagnostics.isEmpty)
    #expect(config.mouseScrollMultiplier == 1)

    try #"{ "mouse_scroll_multiplier": 0 }"#
      .write(to: url, atomically: true, encoding: .utf8)
    let rejected = Configuration.load(from: url)
    #expect(!rejected.diagnostics.isEmpty)
    #expect(
      rejected.mouseScrollMultiplier
        == Configuration.defaultMouseScrollMultiplier
    )
  }

  @Test
  func loadsAndEditsJSONCWithoutLosingOtherSettings() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let url = directory.appendingPathComponent("config.jsonc")
    try """
    {
      // Spec example, including the workspace action.
      "font": {"family":"Menlo", "size":14, "line_height":1.15,},
      "window": {"opacity":0.92, "blur":false, "padding":12, "width":1000, "height":700},
      "terminal": {"shell":"/tmp/a shell's executable", "scrollback_limit":50000},
      "keybindings": [
        {"trigger":"cmd+k", "action":"clear_screen"},
        {"trigger":"cmd+t", "action":"new_tab"},
      ],
    }
    """
    .write(to: url, atomically: true, encoding: .utf8)
    let config = Configuration.load(from: url)
    #expect(config.diagnostics.isEmpty)
    #expect(config.fontSize == 14)
    #expect(abs(config.adjustCellHeight.fraction - 0.15) < 0.00001)
    #expect(config.backgroundBlur == 0)
    #expect(config.windowPaddingX == 12)
    #expect(config.windowWidth == 1000)
    #expect(config.windowHeight == 700)
    #expect(config.scrollbackLimitLines == 50_000)
    #expect(
      config.keybindings.trigger(for: .newTab) == KeyTrigger(parsing: "cmd+t")
    )
    #expect(
      config.sessionConfiguration().command?.last
        == "exec -l '/tmp/a shell'\\''s executable'"
    )
    try ConfigurationEditor.apply(
      [
        ("font-size", "18"), ("theme", "Swiftty Light"),
        ("copy-on-select", "true"), ("cursor-style", "bar"),
        ("cursor-style-blink", "false"), ("mouse-hide-while-typing", "true"),
      ],
      to: url
    )
    let saved = Configuration.load(from: url)
    #expect(saved.diagnostics.isEmpty)
    #expect(saved.fontSize == 18)
    #expect(saved.theme?.light == "Swiftty Light")
    #expect(saved.copyOnSelect)
    #expect(saved.mouseHideWhileTyping)
    #expect(saved.cursorStyle == .bar)
    #expect(saved.cursorStyleBlink == false)
    #expect(saved.windowWidth == 1000)
    #expect(saved.scrollbackLimitLines == 50_000)
    #expect(saved.keybindings == config.keybindings)
    try ConfigurationEditor.apply(
      [("font-size", nil), ("background-opacity", nil), ("theme", nil)],
      to: url
    )
    let reset = Configuration.load(from: url)
    #expect(reset.fontSize == 13)
    #expect(reset.backgroundOpacity == 0.95)
    #expect(reset.theme == nil)
    let before = try Data(contentsOf: url)
    #expect(throws: (any Error).self) {
      try ConfigurationEditor.apply([("font-size", "invalid")], to: url)
    }
    #expect(try Data(contentsOf: url) == before)
  }

  @Test
  func tabPositionLoadsSavesAndRejectsUnknownValues() throws {
    #expect(Configuration.parse("{}").tabPosition == .top)
    let left = Configuration.parse(#"{"window":{"tabs":"left"}}"#)
    #expect(left.diagnostics.isEmpty)
    #expect(left.tabPosition == .left)
    let bad = Configuration.parse(#"{"window":{"tabs":"right"}}"#)
    #expect(!bad.diagnostics.isEmpty)
    #expect(bad.tabPosition == .top)
    var config = Configuration()
    #expect(config.set("tab-position", "bottom") != nil)
    #expect(config.set("tab-position", "left") == nil)
    #expect(config.tabPosition == .left)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".jsonc"
    )
    defer { try? FileManager.default.removeItem(at: url) }
    try ConfigurationEditor.apply([("tab-position", "left")], to: url)
    #expect(Configuration.load(from: url).tabPosition == .left)
    try ConfigurationEditor.apply([("tab-position", "top")], to: url)
    #expect(Configuration.load(from: url).tabPosition == .top)
    // The default is left out of the file.
    #expect(!(try String(contentsOf: url, encoding: .utf8)).contains("tabs"))
  }

  @Test
  func invalidFileReportsOriginalPositionAndIsNotOverwritten() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".jsonc"
    )
    defer { try? FileManager.default.removeItem(at: url) }
    let source = "/* comment\nsecond line */\n{\"font\":{\"size\":\"large\"}}"
    try source.write(to: url, atomically: true, encoding: .utf8)
    let loaded = Configuration.load(from: url)
    #expect(loaded.diagnostics.first?.contains(":3:17:") == true)
    #expect(throws: (any Error).self) {
      try ConfigurationEditor.apply([("font-size", "18")], to: url)
    }
    #expect(try String(contentsOf: url, encoding: .utf8) == source)
  }
}
