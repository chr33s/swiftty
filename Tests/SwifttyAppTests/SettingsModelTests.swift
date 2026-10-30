import Foundation
@testable import Swiftty
import SwifttyCore
import Testing

/// spec.apple.md A01: the Settings window edits the same file and model.
@MainActor
struct SettingsModelTests {
  private func temporaryConfig(_ text: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let url = directory.appendingPathComponent("config")
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  @Test
  func `changes rewrite only their own key and reload`() throws {
    let url = try temporaryConfig(
      "keybind = super+k=clear_screen\nfont-size = 12\n"
    )
    defer { try? FileManager.default.removeItem(at: url) }
    var reloads = 0
    let model = SettingsModel(url: url, configuration: .load(from: url)) {
      reloads += 1
      return .load(from: url)
    }
    model.set("font-size", "18")
    model.set("cursor-style", SettingsModel.Cursor.hollowBlock.value)
    #expect(reloads == 2)
    #expect(model.fontSize == 18)
    #expect(model.cursor == .hollowBlock)
    #expect(model.overridden.isEmpty)
    #expect(model.error == nil)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(
      text
        == "keybind = super+k=clear_screen\nfont-size = 18\ncursor-style = block_hollow\n"
    )
  }

  @Test
  func `an include that overrides a saved value is reported`() throws {
    let url = try temporaryConfig("config-file = extra\n")
    defer { try? FileManager.default.removeItem(at: url) }
    try "font-size = 30\n"
      .write(
        to: url.deletingLastPathComponent().appendingPathComponent("extra"),
        atomically: true,
        encoding: .utf8
      )
    let model = SettingsModel(url: url, configuration: .load(from: url)) {
      .load(from: url)
    }
    model.set("font-size", "11")
    #expect(model.overridden == ["font-size"])
    #expect(model.fontSize == 30)
  }

  @Test
  func `a quoted value is not reported as overridden`() throws {
    let url = try temporaryConfig("")
    defer { try? FileManager.default.removeItem(at: url) }
    let model = SettingsModel(url: url, configuration: .load(from: url)) {
      .load(from: url)
    }
    model.set("font-family", "\"Fira Code\"")
    #expect(model.fontFamily == "Fira Code")
    #expect(model.overridden.isEmpty)
  }

  @Test
  func `invalid values are refused without touching the file`() throws {
    let url = try temporaryConfig("font-size = 12\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let model = SettingsModel(url: url, configuration: .load(from: url)) {
      .load(from: url)
    }
    model.set("font-size", "0")
    #expect(model.error != nil)
    #expect(try String(contentsOf: url, encoding: .utf8) == "font-size = 12\n")
  }
}
