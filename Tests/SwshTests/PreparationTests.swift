import Testing
@testable import Swsh

@Suite
struct PreparationTests {
  private func prepare(
    _ source: String,
    state: ShellState = ShellState()
  ) throws -> PreparedCommand {
    guard case .complete(let program) = Parser().parse(source) else {
      throw ShellDiagnostic(offset: 0, message: "fixture parse failed")
    }
    return try Expander(state: state).prepare(program.commands[0].pipeline[0])
  }

  @Test
  func assignmentsAreSyntaxAndDoNotGlob() throws {
    let command = try prepare(
      "a='two words' b=* c=$a /bin/env",
      state: ShellState(variables: ["a": [120]])
    )
    #expect(
      command.assignments == [
        "a": Array("two words".utf8), "b": [42], "c": [120],
      ]
    )
    #expect(command.arguments == [Array("/bin/env".utf8)])
    #expect(try prepare("'a'=x").assignments.isEmpty)
    #expect(try prepare("a\\=x").assignments.isEmpty)
    #expect(try prepare("/bin/echo a=x").assignments.isEmpty)
    #expect(try prepare("a=").assignments == ["a": []])
  }

  @Test(arguments: Builtin.allCases)
  func builtinPrefixesRejected(builtin: Builtin) {
    #expect(throws: ShellDiagnostic.self) {
      try prepare("a=1 \(builtin.rawValue)")
    }
  }

  @Test
  func explicitPathsBypassBuiltinResolution() throws {
    #expect(try prepare("/bin/pwd").builtin == nil)
    #expect(try prepare("pwd").builtin == .pwd)
  }

  @Test
  func environmentOverlayDoesNotMutateState() throws {
    let state = ShellState(variables: ["A": [49], "B": [50]], exported: ["A"])
    #expect(
      try state.environment(overlay: ["A": [51], "C": [255]]) == [
        [65, 61, 51], [67, 61, 255],
      ]
    )
    #expect(state.variables == ["A": [49], "B": [50]])
    #expect(try state.environment() == [[65, 61, 49]])
    #expect(throws: ShellDiagnostic.self) {
      try state.environment(overlay: ["C": [0]])
    }
  }

  @Test
  func descriptorActionsRemainOrdered() throws {
    #expect(
      try prepare("a >out 2>&1 3<&- 4>>log").redirects == [
        .open(descriptor: 1, path: Array("out".utf8), mode: .write),
        .duplicate(descriptor: 2, source: 1), .close(descriptor: 3),
        .open(descriptor: 4, path: Array("log".utf8), mode: .append),
      ]
    )
    #expect(throws: ShellDiagnostic.self) { try prepare("a 2>&garbage") }
    #expect(throws: ShellDiagnostic.self) { try prepare("a 2>&2147483648") }
  }
}
