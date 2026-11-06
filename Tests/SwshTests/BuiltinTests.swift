#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Testing
@testable import Swsh

@Suite
struct BuiltinTests {
  @Test
  func exportedStateAndUnset() throws {
    var state = ShellState(variables: ["local": [255], "keep": [42]])
    var directory = try WorkingDirectory()
    let sink = try OwnedFD.open(Array("/dev/null".utf8), flags: O_WRONLY)
    sink.withDescriptor { fd in
      let io = BuiltinIO(output: fd, error: fd)
      let evaluator = BuiltinEvaluator()
      #expect(
        evaluator.run(
          .export,
          arguments: [Array("local".utf8), Array("new=two words".utf8)],
          state: &state,
          directory: &directory,
          io: io
        ) == .continuing(0)
      )
      #expect(state.exported == ["local", "new"])
      #expect(state.variables["local"] == [255])
      #expect(state.variables["new"] == Array("two words".utf8))
      #expect(
        evaluator.run(
          .unset,
          arguments: [Array("local".utf8)],
          state: &state,
          directory: &directory,
          io: io
        ) == .continuing(0)
      )
      #expect(state.variables["local"] == nil)
      #expect(!state.exported.contains("local"))
      #expect(state.variables["keep"] == [42])
    }
  }

  @Test
  func invalidExportDoesNotPartiallyMutate() throws {
    var state = ShellState()
    var directory = try WorkingDirectory()
    let sink = try OwnedFD.open(Array("/dev/null".utf8), flags: O_WRONLY)
    sink.withDescriptor { fd in
      let result = BuiltinEvaluator()
        .run(
          .export,
          arguments: [Array("good=1".utf8), Array("bad-name=2".utf8)],
          state: &state,
          directory: &directory,
          io: BuiltinIO(output: fd, error: fd)
        )
      #expect(result == .continuing(2))
      #expect(state.variables.isEmpty)
      #expect(state.exported.isEmpty)
    }
  }

  @Test
  func exitIsControlFlow() throws {
    var state = ShellState(status: 42)
    var directory = try WorkingDirectory()
    let sink = try OwnedFD.open(Array("/dev/null".utf8), flags: O_WRONLY)
    sink.withDescriptor { fd in
      let io = BuiltinIO(output: fd, error: fd)
      let evaluator = BuiltinEvaluator()
      #expect(
        evaluator.run(
          .exit,
          arguments: [],
          state: &state,
          directory: &directory,
          io: io
        ) == .exit(42)
      )
      #expect(
        evaluator.run(
          .exit,
          arguments: [[49, 51, 48]],
          state: &state,
          directory: &directory,
          io: io
        ) == .exit(130)
      )
      #expect(
        evaluator.run(
          .exit,
          arguments: [[50, 53, 54]],
          state: &state,
          directory: &directory,
          io: io
        ) == .continuing(2)
      )
    }
  }
}
