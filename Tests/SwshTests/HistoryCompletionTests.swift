import Foundation
import Testing
@testable import Swsh

struct HistoryCompletionTests {
  @Test
  func historyReloadLimitsAndDamagedRecords() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let home = Array(root.path.utf8)
    let path = root.appendingPathComponent(".swsh_history")
    try Data("\"first\"\ninvalid\n\"unfinished\n\"last\"\n".utf8)
      .write(to: path)
    #expect(
      HistoryStore(home: home).entries == [
        Array("first".utf8), Array("last".utf8),
      ]
    )
    let store = HistoryStore(home: home)
    store.append(Array("multi\nline".utf8))
    store.append(Array("multi\nline".utf8))
    #expect(HistoryStore(home: home).entries.last == Array("multi\nline".utf8))
    #expect(HistoryStore(home: home).entries.count == 3)
    let records = (0 ..< 1005).map { "\"entry-\($0)\"\n" }.joined()
    try Data(records.utf8).write(to: path)
    #expect(HistoryStore(home: home).entries.count == 1000)
    #expect(HistoryStore(home: home).entries.first == Array("entry-5".utf8))
    let full = HistoryStore(home: home)
    full.append(Array("newest".utf8))
    #expect(full.entries.count == 1000)
    #expect(HistoryStore(home: home).entries.first == Array("entry-6".utf8))
    let large = HistoryStore(home: home)
    for i in 0 ..< 20 {
      large.append(
        Array((String(i) + String(repeating: "x", count: 60_000)).utf8)
      )
    }
    #expect(try Data(contentsOf: path).count <= 1024 * 1024)
    #expect(large.entries.count < 20)
    let reloaded = HistoryStore(home: home)
    #expect(reloaded.entries.count < 20)
    #expect(reloaded.entries.last?.starts(with: Array("19".utf8)) == true)
  }

  @Test
  func duplicatePathEntriesDoNotMakeCompletionAmbiguous() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let name =
      "swshcompletion"
      + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let file = root.appendingPathComponent(name)
    try Data().write(to: file)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: file.path
    )
    let state = ShellState(variables: [
      "PATH": Array((root.path + ":" + root.path).utf8)
    ])
    let prefix = String(name.dropLast(4))
    #expect(
      Completion(state: state).suffix(for: Array(prefix.utf8))
        == Array((name.suffix(4) + " ").utf8)
    )
  }

  @Test
  func completionEscapesSyntaxAndPreservesUnicodeBoundaries() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["space name;$*", "unicode-中", "unicode-丮", ".hidden"] {
      try Data().write(to: root.appendingPathComponent(name))
    }
    let completion = Completion(state: ShellState())
    func suffix(_ leaf: String) -> String? {
      completion.suffix(for: Array(("cat " + root.path + "/" + leaf).utf8))
        .map { String(decoding: $0, as: UTF8.self) }
    }
    #expect(suffix("space") == "\\ name\\;\\$\\* ")
    #expect(suffix("unicode") == "-")
    #expect(suffix(".h") == "idden ")
    let hiddenRoot = root.appendingPathComponent("only-hidden")
    try FileManager.default.createDirectory(
      at: hiddenRoot,
      withIntermediateDirectories: false
    )
    try Data().write(to: hiddenRoot.appendingPathComponent(".hidden"))
    #expect(
      completion.suffix(for: Array(("cat " + hiddenRoot.path + "/").utf8))
        == nil
    )
  }
}
