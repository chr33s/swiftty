import Foundation
@testable import Swiftty
import SwifttyCore
import Testing

/// Settings edits and reloads the selected JSONC document.
@MainActor
struct SettingsModelTests {
  private func temporaryConfig(_ text: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let url = directory.appendingPathComponent("config.jsonc")
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  @Test
  func changesPreserveOtherSettingsAndReload() throws {
    let url = try temporaryConfig(
      ##"{"font":{"size":12},"keybindings":[{"trigger":"cmd+k","action":"clear_screen"}]}"##
    )
    defer {
      try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
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
    #expect(model.error == nil)
    #expect(
      Configuration.load(from: url).keybindings.trigger(for: .clearScreen)
        != nil
    )
  }

  @Test
  func fontNamesAreLiteralValues() throws {
    let url = try temporaryConfig("{}")
    defer {
      try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
    let model = SettingsModel(url: url, configuration: .load(from: url)) {
      .load(from: url)
    }
    model.set("font-family", "Fira Code")
    #expect(model.fontFamily == "Fira Code")
    #expect(model.error == nil)
  }

  @Test
  func invalidValuesAndLegacyFilesAreNotOverwritten() throws {
    for source in [##"{"font":{"size":12}}"##, "font-size = 12\n"] {
      let url = try temporaryConfig(source)
      defer {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
      }
      let model = SettingsModel(url: url, configuration: .load(from: url)) {
        .load(from: url)
      }
      model.set("font-size", "0")
      #expect(model.error != nil)
      #expect(try String(contentsOf: url, encoding: .utf8) == source)
    }
  }
}
