import Foundation
import Testing
@testable import Swsh

@Suite
struct ExpansionTests {
  @Test
  func authoredPatternsAndRedirectCardinality() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    for name in ["z", "a", "*"] {
      try Data().write(to: directory.appendingPathComponent(name))
    }
    let prefix = Array((directory.path + "/").utf8)
    let pattern = Word(
      range: 0 ..< 1,
      parts: [.literal(prefix), .wildcard(42)]
    )
    let expander = Expander(state: ShellState())
    #expect(
      try expander.paths(pattern)
        == ["*", "a", "z"].map { prefix + Array($0.utf8) }
    )
    #expect(throws: ShellDiagnostic.self) { try expander.redirectPath(pattern) }
    let missing = Word(
      range: 0 ..< 1,
      parts: [.literal(prefix + Array("missing".utf8)), .wildcard(63)]
    )
    #expect(throws: ShellDiagnostic.self) { try expander.paths(missing) }
    let literal = Word(
      range: 0 ..< 1,
      parts: [.literal(prefix), .variable("name")]
    )
    #expect(
      try Expander(state: ShellState(variables: ["name": [42]]))
        .redirectPath(literal) == prefix + [42]
    )
  }

  @Test(arguments: [
    [], Array("two words".utf8), Array("*?[]\\".utf8), [0xFF, 0xFE],
  ])
  func scalarIsOneBytePreservingArgument(value: [UInt8]) throws {
    guard case .complete(let program) = Parser().parse("$value") else {
      Issue.record("parse failed");
      return
    }
    let word = program.commands[0].pipeline[0].words[0]
    let expander = Expander(state: ShellState(variables: ["value": value]))
    #expect(try expander.paths(word) == [value])
  }

  @Test
  func unsetAndStatus() throws {
    guard case .complete(let program) = Parser().parse("$unset \"$?\"") else {
      Issue.record("parse failed");
      return
    }
    let words = program.commands[0].pipeline[0].words
    let expander = Expander(state: ShellState(status: 130))
    #expect(try expander.paths(words[0]) == [[]])
    #expect(try expander.paths(words[1]) == [Array("130".utf8)])
  }

  @Test
  func nulRejectedAtBoundary() throws {
    let word = Word(range: 0 ..< 2, parts: [.variable("x")])
    #expect(throws: ShellDiagnostic.self) {
      try Expander(state: ShellState(variables: ["x": [0]])).paths(word)
    }
  }
}
