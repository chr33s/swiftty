import Foundation
@testable import SwifttyCore
import Testing

struct ConfigurationFileBoundsTests {
  private func withDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
  }

  private func padded(_ text: String, to bytes: Int) -> Data {
    var data = Data(text.utf8)
    data.append(Data(repeating: 0x20, count: bytes - data.count))
    return data
  }

  @Test
  func themeLimitAcceptsBoundaryAndRejectsOneExcessByte() throws {
    try withDirectory { directory in
      let file = directory.appendingPathComponent("Night")
      try padded(##"{"background":"#123456"}"##, to: Themes.maxFileBytes)
        .write(to: file)
      #expect(
        Themes.colors(named: file.path, searching: [])?.background == 0x123456
      )
      try padded(##"{"background":"#123456"}"##, to: Themes.maxFileBytes + 1)
        .write(to: file)
      #expect(Themes.colors(named: file.path, searching: []) == nil)
      #expect(Themes.colors(named: "Night", searching: [directory]) == nil)
    }
  }

  @Test
  func configurationLimitAcceptsBoundaryAndRejectsOneExcessByte() throws {
    try withDirectory { directory in
      let file = directory.appendingPathComponent("config.jsonc")
      try padded(##"{"font":{"size":22}}"##, to: Configuration.maxFileBytes)
        .write(to: file)
      #expect(Configuration.load(from: file).fontSize == 22)
      #expect(Configuration.load(from: file).diagnostics.isEmpty)
      try padded(##"{"font":{"size":22}}"##, to: Configuration.maxFileBytes + 1)
        .write(to: file)
      let loaded = Configuration.load(from: file)
      #expect(loaded.fontSize == 13)
      #expect(loaded.diagnostics.count == 1)
    }
  }

  @Test
  func includesAreRejectedWithoutReadingOtherFiles() throws {
    try withDirectory { directory in
      let other = directory.appendingPathComponent("other")
      try Data(##"{"font":{"size":22}}"##.utf8).write(to: other)
      let file = directory.appendingPathComponent("config")
      for source in ["config-file=other", ##"{"config-file":"other"}"##] {
        try Data(source.utf8).write(to: file)
        let config = Configuration.load(from: file)
        #expect(config.fontSize == 13)
        #expect(config.diagnostics.count == 1)
      }
    }
  }
}
