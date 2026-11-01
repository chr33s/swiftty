import Foundation
import Testing
@testable import SwifttyConfig

struct ConfigTests {
  @Test
  func sanitizerPreservesBytesAndStrings() throws {
    let source =
      #"{"url":"https://github.com/a/*b*/", "quote":"\"//not a comment\"", /* 🦊é"#
      + "\r\ncomment */" + #" "items":[1,2, /* tail */],}"#
    let data = JSONCSanitizer.sanitize(source)
    #expect(data.count == source.utf8.count)
    let original = Array(source.utf8)
    for index in original.indices
    where original[index] == 10 || original[index] == 13 {
      #expect(data[index] == original[index])
    }
    let object = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    #expect(object["url"] as? String == "https://github.com/a/*b*/")
    #expect(object["quote"] as? String == "\"//not a comment\"")
    #expect(object["items"] as? [Int] == [1, 2])
  }

  @Test
  func defaultsAndTemplate() throws {
    #expect(try ConfigLoader.decode("{}") == .default)
    #expect(try ConfigLoader.decode(ConfigLoader.template) == .default)
    let config = try ConfigLoader.decode(
      #"{"font":{"size":14,},"window":{"blur":false},}"#
    )
    #expect(config.font.family == "Menlo")
    #expect(config.font.size == 14)
    #expect(!config.window.blur)
    #expect(config.terminal.scrollbackLimit == 10_000)
  }

  @Test
  func diagnosticBelowTwentyLineComment() throws {
    let source =
      "/*\n" + String(repeating: "🦊 comment\n", count: 20)
      + "*/\n{\n  \"font\": {\"size\": \"large\"}\n}"
    do {
      _ = try ConfigLoader.decode(source)
      Issue.record("Expected type mismatch")
    } catch let error as ConfigError {
      #expect(error.line == 24)
      #expect(error.column == 20)
      #expect(error.codingPath == ["font", "size"])
    }
  }

  @Test(arguments: [
    "{,}", "[, ]", "{\"font\":,}", "{\"font\":{,,}}", "{} /* unclosed",
    "{\"font\":{\"size\":01}}", "{\"font\":{\"size\":1.}}", "{} trailing",
    "{\"font\":{\"size\":null}}", "{\"font\":{\"size\":201}}",
    "{\"window\":{\"opacity\":2}}", "{\"font\":{\"line_height\":0}}",
    "{\"terminal\":{\"scrollback_limit\":-1}}", "{\"unknown\":true}",
    "{\"font\":{},\"font\":{}}", "{\"keybindings\":[{\"trigger\":\"cmd+k\"}]}",
    "{\"font\":{\"family\":\"bad\\q\"}}", "{\"font\":{\"family\":\"bad\n\"}}",
  ])
  func rejectsInvalidConfiguration(source: String) {
    #expect(throws: ConfigError.self) { try ConfigLoader.decode(source) }
  }

  @Test
  func sourcePositionsForSyntaxNullAndNestedArrays() throws {
    for (source, line, column, path) in [
      ("{\r\n  \"font\": {\"size\": null}\r\n}", 2, 20, ["font", "size"]),
      (
        "{\n  \"keybindings\": [{\"trigger\": true, \"action\": \"clear_screen\"}]\n}",
        2, 31, ["keybindings", "0", "trigger"]
      ), ("{/* 🦊 */\"font\" 1}", 1, 19, []),
    ] {
      do {
        _ = try ConfigLoader.decode(source)
        Issue.record("Expected failure")
      } catch let error as ConfigError {
        #expect(error.line == line)
        #expect(error.column == column)
        #expect(error.codingPath == path)
      }
    }
  }

  @Test
  func oversizedNumberHasSourcePosition() throws {
    do {
      _ = try ConfigLoader.decode("{\n  \"font\": {\"size\": 1e999}\n}")
      Issue.record("Expected unsupported number")
    } catch let error as ConfigError {
      #expect(error.line == 2)
      #expect(error.column == 20)
    }
  }

  @Test
  func unicodeEscapesAndBounds() throws {
    let config = try ConfigLoader.decode(#"{"font":{"family":"\uD83E\uDD8A"}}"#)
    #expect(config.font.family == "🦊")
    #expect(throws: ConfigError.self) {
      try ConfigLoader.decode(#"{"font":{"family":"\uDC00"}}"#)
    }
    #expect(throws: ConfigError.self) {
      try ConfigLoader.decode(#"{"font":{"family":"\uD800"}}"#)
    }
    #expect(throws: ConfigError.self) {
      try ConfigLoader.decode(
        String(repeating: "[", count: 129) + String(repeating: "]", count: 129)
      )
    }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString
    )
    defer { try? FileManager.default.removeItem(at: file) }
    try Data(repeating: 32, count: ConfigLoader.maxFileBytes + 1)
      .write(to: file)
    #expect(throws: ConfigError.self) { try ConfigLoader.load(from: file) }
    try Data([0xFF]).write(to: file)
    #expect(throws: ConfigError.self) { try ConfigLoader.load(from: file) }
    var huge = SwifttyConfig.default
    huge.font.family = String(repeating: "x", count: ConfigLoader.maxFileBytes)
    #expect(throws: ConfigError.self) { try ConfigLoader.save(huge, to: file) }
    #expect(try Data(contentsOf: file) == Data([0xFF]))
  }

  @Test
  func discoveryAndRoundTrip() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString
    )
    defer { try? FileManager.default.removeItem(at: home) }
    let env = ["XDG_CONFIG_HOME": home.appendingPathComponent("xdg").path]
    let primary = ConfigDiscovery.defaultURL(environment: env, home: home)
    let legacy = home.appendingPathComponent(".swiftty.jsonc")
    let fallback = home.appendingPathComponent(".config/swiftty/config.json")
    #expect(
      try ConfigDiscovery.load(arguments: [], environment: env, home: home)
        == .default
    )
    try ConfigLoader.save(.default, to: fallback)
    #expect(
      try ConfigDiscovery.resolve(arguments: [], environment: env, home: home)
        == fallback
    )
    try ConfigLoader.save(.default, to: legacy)
    #expect(
      try ConfigDiscovery.resolve(arguments: [], environment: env, home: home)
        == legacy
    )
    try ConfigLoader.generateTemplate(at: primary)
    #expect(throws: (any Error).self) {
      try ConfigLoader.generateTemplate(at: primary)
    }
    #expect(
      try ConfigDiscovery.resolve(arguments: [], environment: env, home: home)
        == primary
    )
    #expect(
      try ConfigDiscovery.resolve(
        arguments: ["--config", fallback.path],
        environment: env,
        home: home
      ) == fallback
    )
    #expect(throws: ConfigError.self) {
      try ConfigDiscovery.resolve(
        arguments: ["--config"],
        environment: env,
        home: home
      )
    }
    #expect(throws: (any Error).self) {
      try ConfigDiscovery.load(
        arguments: ["--config", home.appendingPathComponent("missing").path],
        environment: env,
        home: home
      )
    }
    var config = try ConfigLoader.load(from: primary)
    config.window.width = 1024
    config.window.height = 768
    config.font.size = 17
    config.window.blur = false
    config.theme = "Swiftty Light"
    config.copyOnSelect = true
    config.keybindings = [.init(trigger: "cmd+t", action: "new_tab")]
    try ConfigLoader.save(config, to: primary)
    #expect(try ConfigLoader.load(from: primary) == config)
    let saved = try Data(contentsOf: primary)
    #expect(try JSONSerialization.jsonObject(with: saved) is [String: Any])
    #expect(String(decoding: saved, as: UTF8.self).contains("line_height"))
    let symlink = home.appendingPathComponent("linked.jsonc")
    try FileManager.default.createSymbolicLink(
      at: symlink,
      withDestinationURL: primary
    )
    #expect(try ConfigLoader.load(from: symlink) == config)
    config.font.size = 18
    try ConfigLoader.save(config, to: symlink)
    #expect(try ConfigLoader.load(from: primary) == config)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path)
        == primary.path
    )
  }
}
