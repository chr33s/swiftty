import Testing
@testable import Swsh

@Suite
struct ParserTests {
  @Test(arguments: [
    "echo '", "echo \"", "echo \\", "echo ${name", "echo |", "echo &&",
    "echo >",
  ])
  func continuation(source: String) {
    guard case .incomplete = Parser().parse(source) else {
      Issue.record("expected incomplete: \(source)");
      return
    }
  }

  @Test(arguments: [
    "echo `pwd`", "echo <<EOF", "| echo", "echo ;; pwd", "echo ${x:-y}",
  ])
  func unsupported(source: String) {
    guard case .invalid = Parser().parse(source) else {
      Issue.record("expected invalid: \(source)");
      return
    }
  }

  @Test
  func encoding() {
    #expect(
      Parser().parse([0xFF])
        == .invalid(
          ShellDiagnostic(offset: 0, message: "source is not valid UTF-8")
        )
    )
    #expect(
      Parser().parse([65, 0])
        == .invalid(ShellDiagnostic(offset: 1, message: "NUL in source"))
    )
  }

  @Test
  func structureAndSourceOwnership() throws {
    let source = "a | b && c || d; e & f\n# comment\ng"
    guard case .complete(let program) = Parser().parse(source) else {
      Issue.record("expected program");
      return
    }
    #expect(program.source == Array(source.utf8))
    #expect(program.commands.count == 6)
    #expect(program.commands[0].pipeline.count == 2)
    #expect(program.commands[1].condition == .success)
    #expect(program.commands[2].condition == .failure)
    #expect(program.commands[3].background)
  }

  @Test
  func quotingRetainsPatternProvenance() {
    guard
      case .complete(let program) = Parser()
        .parse("echo * '*' \"?\" $x ${x} ''")
    else {
      Issue.record("expected program");
      return
    }
    let words = program.commands[0].pipeline[0].words
    #expect(words[1].parts == [.wildcard(42)])
    #expect(words[2].parts == [.literal([]), .literal([42])])
    #expect(words[3].parts == [.literal([]), .literal([63])])
    #expect(words[4].parts == [.variable("x")])
    #expect(words[5].parts == [.variable("x")])
    #expect(words[6].parts == [.literal([])])
  }

  @Test
  func redirectOrderAndByteRanges() {
    guard case .complete(let program) = Parser().parse("é >out 2>&1 <in 3>>log")
    else {
      Issue.record("expected program");
      return
    }
    let command = program.commands[0].pipeline[0]
    #expect(command.words[0].range == 0 ..< 2)
    #expect(command.redirects.map(\.descriptor) == [1, 2, 0, 3])
    #expect(
      command.redirects.map(\.operation) == [
        .write, .duplicateOutput, .read, .append,
      ]
    )
  }
}
