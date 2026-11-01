import Darwin
import Foundation
@testable import SwifttyCore
import Testing

struct ConfigurationFileReaderTests {
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

  @Test
  func nonregularFilesAndInvalidURLsAreUnavailableWithoutOpeningAWritingPeer()
    throws
  {
    try withDirectory { directory in
      let fifo = directory.appendingPathComponent("fifo")
      #expect(mkfifo(fifo.path, 0o600) == 0)
      for file in [fifo, directory] {
        #expect(throws: ConfigurationFile.Failure.notRegular) {
          try ConfigurationFile.read(file, maxBytes: 100)
        }
        #expect(Themes.colors(named: file.path, searching: []) == nil)
        #expect(Configuration.load(from: file).diagnostics.count == 1)
      }
      let invalidURLs = [
        URL(string: "https://example.invalid/theme")!,
        URL(fileURLWithPath: fifo.path + "\0other"),
      ]
      for url in invalidURLs {
        #expect(throws: ConfigurationFile.Failure.invalidURL) {
          try ConfigurationFile.read(url, maxBytes: 100)
        }
      }
      let parent = directory.appendingPathComponent("parent")
      try Data().write(to: parent)
      let child = parent.appendingPathComponent("child")
      #expect(Configuration.load(from: child).diagnostics.count == 1)

    }
  }

  @Test
  func openedFileGrowthCannotExceedTheReadAllowance() throws {
    try withDirectory { directory in
      let file = directory.appendingPathComponent("growing")
      try Data(repeating: 0x20, count: 4096).write(to: file)
      let writer = try FileHandle(forWritingTo: file)
      defer { try? writer.close() }
      var readBytes = 0
      #expect(throws: ConfigurationFile.Failure.tooLarge) {
        try ConfigurationFile.read(file, maxBytes: 4096) { count in
          readBytes += count
          if readBytes == 4096 {
            _ = try? writer.seekToEnd()
            try? writer.write(contentsOf: Data(repeating: 0x20, count: 4096))
          }
        }
      }
      #expect(readBytes == 4097)
    }
  }

  @Test
  func pathReplacementDoesNotRedirectTheAlreadyOpenedFile() throws {
    try withDirectory { directory in
      let file = directory.appendingPathComponent("selected")
      let replacement = directory.appendingPathComponent("replacement")
      let original = String(repeating: "a", count: 8192)
      try Data(original.utf8).write(to: file)
      try Data("other".utf8).write(to: replacement)
      var renamed = false
      let text = try ConfigurationFile.read(file, maxBytes: 8192) { _ in
        if !renamed {
          #expect(rename(replacement.path, file.path) == 0)
          renamed = true
        }
      }
      #expect(text == original)
      #expect(try ConfigurationFile.read(file, maxBytes: 100) == "other")
    }
  }

  @Test
  func namedThemeFallbackAndSymlinkPrecedenceRemainIntact() throws {
    try withDirectory { directory in
      let first = directory.appendingPathComponent("first")
      let second = directory.appendingPathComponent("second")
      for url in [first, second] {
        try FileManager.default.createDirectory(
          at: url,
          withIntermediateDirectories: true
        )
      }
      let valid = second.appendingPathComponent("Night")
      try Data(##"{"background":"#123456"}"##.utf8).write(to: valid)
      let rejected = first.appendingPathComponent("Night")
      try Data(repeating: 0xFF, count: 1).write(to: rejected)
      #expect(
        Themes.colors(named: "Night", searching: [first, second])?.background
          == 0x123456
      )
      try FileManager.default.removeItem(at: rejected)
      try FileManager.default.createSymbolicLink(
        at: rejected,
        withDestinationURL: valid
      )
      #expect(
        Themes.colors(named: "Night", searching: [first, second])?.background
          == 0x123456
      )
      #expect(
        Themes.colors(named: rejected.path, searching: [])?.background
          == 0x123456
      )
      try Data(repeating: 0x20, count: Themes.maxFileBytes + 1)
        .write(to: first.appendingPathComponent("Swiftty Dark"))
      #expect(
        Themes.colors(named: "Swiftty Dark", searching: [first])?.background
          == 0x0C1021
      )
    }
  }

  @Test
  func emptyAndBOMTextMatchFoundationDecoding() throws {
    try withDirectory { directory in
      let file = directory.appendingPathComponent("literal%00 text")
      for data in [
        Data(),
        Data([0xEF, 0xBB, 0xBF]) + Data(##"{"background":"#123456"}"##.utf8),
      ] {
        try data.write(to: file)
        #expect(
          try ConfigurationFile.read(file, maxBytes: data.count)
            == String(contentsOf: file, encoding: .utf8)
        )
      }
    }
  }
}
