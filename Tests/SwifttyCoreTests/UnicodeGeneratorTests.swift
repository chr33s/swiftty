#if os(macOS)
import Foundation
import Testing
import TestSupport

struct UnicodeGeneratorTests {
  @Test(arguments: [5, 6, 7, 8])
  func `runtime accepts every grapheme block size selected by the generator`(
    shift: Int
  ) throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let blockSize = 1 << shift
    let bytes = (0 ..< blockSize * 2)
      .map { index in
        let alternate = index >= blockSize
        return UInt8((index % blockSize + (alternate ? 7 : 0)) % 18)
          | (alternate ? 0x60 : 0)
      }
    let escaped = bytes.map { "\\u{" + String($0, radix: 16) + "}" }.joined()
    let properties = directory.appendingPathComponent(
      "GraphemeBreakTables.swift"
    )
    try """
    enum GraphemeBreakTables {
        static let version = "fixture"
        static let shift = \(shift)
        static let stage1 = (0 ..< \(0x110000 >> shift)).map { UInt16($0 % 3 == 0 ? 1 : 0) }
        static let stage2: StaticString = "\(escaped)"
        static let stage2Count = \(bytes.count)
    }
    """
    .write(to: properties, atomically: true, encoding: .utf8)
    let main = directory.appendingPathComponent("main.swift")
    try """
    let grapheme = GraphemeBreak.tables
    let widths = UnicodeWidth.table
    let combined = ScalarInfoTable.shared
    for cp in UInt32(0) ..< 0x110000 {
        let alternate = Int(cp) / \(blockSize) % 3 == 0
        let expected = UInt8((Int(cp) % \(blockSize) + (alternate ? 7 : 0)) % 18)
            | (alternate ? 0x60 : 0)
        precondition(grapheme.props(cp) == expected)
        precondition(combined.lookup(cp) == expected & 0x1F | widths.lookup(cp) << 5)
    }
    for cp in [UInt32(0x110000), UInt32.max] {
        precondition(grapheme.props(cp) == 0x20)
        precondition(combined.lookup(cp) == 0x20)
    }
    """
    .write(to: main, atomically: true, encoding: .utf8)
    let sources = [
      "Sources/SwifttyCore/Unicode/Tables.swift",
      "Sources/SwifttyCore/Unicode/Width.swift",
      "Sources/SwifttyCore/Unicode/ScalarInfo.swift",
      "Sources/SwifttyCore/Terminal/GraphemeBreak.swift",
    ]
    .map { root.appendingPathComponent($0).path }
    let binary = directory.appendingPathComponent("runtime")
    let compilation = try run(
      URL(fileURLWithPath: "/usr/bin/env"),
      arguments: ["swiftc", "-O", "-whole-module-optimization"] + sources + [
        properties.path, main.path, "-o", binary.path,
      ],
      directory: directory,
    )
    try #require(
      compilation.status == 0,
      Comment(rawValue: escapedTestText(compilation.error))
    )
    let result = try run(binary, arguments: [], directory: directory)
    #expect(
      result.status == 0,
      Comment(rawValue: escapedTestText(result.error))
    )
  }

  @Test
  func
    `width generation uses matching UCD properties instead of runtime properties`()
    throws
  {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let binary = directory.appendingPathComponent("generator")
    let compilation = try run(
      URL(fileURLWithPath: "/usr/bin/env"),
      arguments: [
        "swiftc",
        root.appendingPathComponent("Scripts/gen-unicode-tables.swift").path,
        "-o", binary.path,
      ],
      directory: directory,
    )
    try #require(compilation.status == 0, Comment(rawValue: compilation.error))
    let inputs = [
      "EastAsianWidth.txt":
        "# EastAsianWidth-18.0.0.txt\n05C8 ; W\n10F000 ; N\n",
      "PropList.txt":
        "# PropList-18.0.0.txt\n0600 ; Prepended_Concatenation_Mark\n",
      "extracted/DerivedGeneralCategory.txt":
        "# DerivedGeneralCategory-18.0.0.txt\n05C8 ; Mn\n0600 ; Cf\n00AD ; Cf\n200B ; Cf\n",
      "emoji/emoji-data.txt":
        "# emoji-data.txt\n# Version: 18.0\n10F000 ; Emoji_Presentation\n",
    ]
    .mapValues { $0 + "# EOF\n" }
    for (path, text) in inputs {
      let url = directory.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try text.write(to: url, atomically: true, encoding: .utf8)
    }
    let arguments = [
      directory.appendingPathComponent("EastAsianWidth.txt").path
    ]
    let generated = try run(binary, arguments: arguments, directory: directory)
    try #require(generated.status == 0, Comment(rawValue: generated.error))
    let zero = try
      #require(
        generated.output
          .components(separatedBy: "static let zeroWidth: [UInt32] = [").last
      )
      .components(separatedBy: "]")[0]
    let wide = try
      #require(
        generated.output
          .components(separatedBy: "static let wide: [UInt32] = [").last
      )
      .components(separatedBy: "]")[0]
    #expect(zero.contains("0x005C8, 0x005C8"))
    #expect(zero.contains("0x0200B, 0x0200B"))
    #expect(!zero.contains("0x00600") && !zero.contains("0x000AD"))
    #expect(!wide.contains("0x005C8"))
    #expect(wide.contains("0x10F000, 0x10F000"))
    for (path, text) in inputs {
      let url = directory.appendingPathComponent(path)
      for invalid in [
        text.replacingOccurrences(of: "18.0", with: "17.0"),
        text.split(separator: "\n").filter { !$0.hasPrefix("#") }
          .joined(separator: "\n"),
        text.replacingOccurrences(of: "18.0", with: "18.x"),
      ] {
        try invalid.write(to: url, atomically: true, encoding: .utf8)
        let result = try run(binary, arguments: arguments, directory: directory)
        #expect(
          result.status == 1,
          Comment(rawValue: "\(path): \(result.error)")
        )
        #expect(result.output.isEmpty)
        #expect(result.error.contains("version"))
      }
      try text.replacingOccurrences(of: "# EOF\n", with: "")
        .write(to: url, atomically: true, encoding: .utf8)
      let truncated = try run(
        binary,
        arguments: arguments,
        directory: directory
      )
      #expect(
        truncated.status == 1,
        Comment(rawValue: "\(path): \(truncated.error)")
      )
      #expect(truncated.output.isEmpty && truncated.error.contains("EOF"))
      try text.write(to: url, atomically: true, encoding: .utf8)
    }
    for (path, record) in [
      "EastAsianWidth.txt": "05C7..05C8 ; N\n",
      "extracted/DerivedGeneralCategory.txt": "05C7..05C8 ; Ll\n",
    ] {
      let original = try #require(inputs[path])
      let url = directory.appendingPathComponent(path)
      try original.replacingOccurrences(of: "# EOF", with: record + "# EOF")
        .write(to: url, atomically: true, encoding: .utf8)
      let result = try run(binary, arguments: arguments, directory: directory)
      #expect(result.status == 1 && result.output.isEmpty)
      #expect(result.error.contains("overlap"), Comment(rawValue: result.error))
      try original.write(to: url, atomically: true, encoding: .utf8)
    }
  }

  @Test
  func `grapheme generation rejects inconsistent or missing input versions`()
    throws
  {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let binary = directory.appendingPathComponent("generator")
    let compilation = try run(
      URL(fileURLWithPath: "/usr/bin/env"),
      arguments: [
        "swiftc",
        root.appendingPathComponent("Scripts/gen-grapheme-tables.swift").path,
        "-o", binary.path,
      ],
      directory: directory,
    )
    try #require(compilation.status == 0, Comment(rawValue: compilation.error))
    let inputs = [
      "auxiliary/GraphemeBreakProperty.txt": "0041 ; Other\n",
      "auxiliary/GraphemeBreakTest.txt": "÷ 0041 ÷\n",
      "DerivedCoreProperties.txt": "0041 ; Default_Ignorable_Code_Point\n",
      "extracted/DerivedGeneralCategory.txt": "0041 ; Lu\n",
      "emoji/emoji-data.txt": "0041 ; Emoji\n",
      "emoji/emoji-variation-sequences.txt": "0023 FE0E ; text style;\n",
    ]
    .mapValues { $0 + "#EOF\n" }
    func header(_ path: String, version: String) -> String {
      let name = URL(fileURLWithPath: path).lastPathComponent
      return path.hasPrefix("emoji/")
        ? "# \(name)\n# Version: \(version)\n"
        : "# \(name.dropLast(4))-\(version).txt\n"
    }
    for version in ["17.0.0", "18.0.0"] {
      for (path, body) in inputs {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        // Emoji files also use a two-component release number.
        let release =
          path.hasPrefix("emoji/") ? String(version.dropLast(2)) : version
        try (header(path, version: release) + body)
          .write(to: url, atomically: true, encoding: .utf8)
      }
      for mode in [[], ["--test-data"]] {
        let result = try run(
          binary,
          arguments: [directory.path] + mode,
          directory: directory
        )
        #expect(result.status == 0, Comment(rawValue: result.error))
        #expect(result.output.contains("static let version = \"\(version)\""))
      }
    }
    for (path, body) in inputs {
      let url = directory.appendingPathComponent(path)
      let validHeader = header(path, version: "18.0.0")
      for invalidHeader in [
        header(path, version: "17.0.0"), "", header(path, version: "18.x.0"),
        validHeader + header(path, version: "17.0.0"),
      ] {
        try (invalidHeader + body)
          .write(to: url, atomically: true, encoding: .utf8)
        var modes: [[String]] = [[]]
        if path.hasSuffix("GraphemeBreakTest.txt") {
          modes = [["--test-data"]]
        } else if path.hasSuffix("GraphemeBreakProperty.txt") {
          modes.append(["--test-data"])
        }
        for mode in modes {
          let result = try run(
            binary,
            arguments: [directory.path] + mode,
            directory: directory
          )
          #expect(
            result.status == 1,
            Comment(rawValue: "\(path): \(result.error)")
          )
          #expect(result.output.isEmpty)
          #expect(result.error.contains("version"))
        }
      }
      try (validHeader + body).write(to: url, atomically: true, encoding: .utf8)
      try (validHeader + body.replacingOccurrences(of: "#EOF\n", with: ""))
        .write(to: url, atomically: true, encoding: .utf8)
      let mode = path.hasSuffix("GraphemeBreakTest.txt") ? ["--test-data"] : []
      let truncated = try run(
        binary,
        arguments: [directory.path] + mode,
        directory: directory
      )
      #expect(
        truncated.status == 1,
        Comment(rawValue: "\(path): \(truncated.error)")
      )
      #expect(truncated.output.isEmpty && truncated.error.contains("EOF"))
      try (validHeader + body).write(to: url, atomically: true, encoding: .utf8)
    }
    for (path, record) in [
      "auxiliary/GraphemeBreakProperty.txt": "0040..0041 ; Extend\n",
      "extracted/DerivedGeneralCategory.txt": "0040..0041 ; Mn\n",
      "DerivedCoreProperties.txt":
        "0041 ; InCB ; Linker\n0040..0041 ; InCB ; Consonant\n",
    ] {
      let original =
        try header(path, version: "18.0.0") + #require(inputs[path])
      let url = directory.appendingPathComponent(path)
      try original.replacingOccurrences(of: "#EOF", with: record + "#EOF")
        .write(to: url, atomically: true, encoding: .utf8)
      let modes: [[String]] =
        path.hasSuffix("GraphemeBreakProperty.txt")
        ? [[], ["--test-data"]] : [[]]
      for mode in modes {
        let result = try run(
          binary,
          arguments: [directory.path] + mode,
          directory: directory
        )
        #expect(result.status == 1 && result.output.isEmpty)
        #expect(
          result.error.contains("overlap"),
          Comment(rawValue: result.error)
        )
      }
      try original.write(to: url, atomically: true, encoding: .utf8)
    }
  }

  private func run(
    _ executable: URL,
    arguments: [String],
    directory: URL
  ) throws -> (status: Int32, output: String, error: String) {
    let outputURL = directory.appendingPathComponent("stdout")
    let errorURL = directory.appendingPathComponent("stderr")
    try Data().write(to: outputURL)
    try Data().write(to: errorURL)
    let output = try FileHandle(forWritingTo: outputURL)
    let error = try FileHandle(forWritingTo: errorURL)
    defer {
      try? output.close()
      try? error.close()
    }
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = error
    try process.run()
    process.waitUntilExit()
    return try (
      process.terminationStatus, String(contentsOf: outputURL, encoding: .utf8),
      String(contentsOf: errorURL, encoding: .utf8),
    )
  }
}
#endif
