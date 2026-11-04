import Testing
@testable import Swsh

@Suite
struct BuiltinWorkerTests {
  @Test
  func execContextCarriesChildEnvironmentAndLocalSearchPath() {
    var state = ShellState(
      variables: ["PATH": [47, 120], "exported": [255], "private": [121]],
      exported: ["exported"]
    )
    state.opaqueEnvironment = [[255, 61, 120]]
    let context = BuiltinWorkerContext(
      builtin: .exec,
      arguments: [Array("exec".utf8), Array("program".utf8)],
      state: state
    )
    #expect(context.variables == ["PATH": [47, 120], "exported": [255]])
    #expect(context.exported == ["exported"])
    #expect(context.opaqueEnvironment == [[255, 61, 120]])
  }

  @Test
  func contextIncludesOnlyValuesReadByTheBuiltin() {
    let state = ShellState(
      variables: ["HOME": [47, 255], "private": [120], "exported": [121]],
      exported: ["exported"],
      status: 23
    )
    let cd = BuiltinWorkerContext(
      builtin: .cd,
      arguments: [Array("cd".utf8)],
      state: state
    )
    #expect(cd.variables == ["HOME": [47, 255]])
    #expect(cd.exported.isEmpty)
    let explicit = BuiltinWorkerContext(
      builtin: .cd,
      arguments: [Array("cd".utf8), [47]],
      state: state
    )
    #expect(explicit.variables.isEmpty)
    let export = BuiltinWorkerContext(
      builtin: .export,
      arguments: [Array("export".utf8), Array("exported".utf8)],
      state: state
    )
    #expect(export.variables == ["exported": [121]])
    #expect(export.exported == ["exported"])
    let exit = BuiltinWorkerContext(
      builtin: .exit,
      arguments: [Array("exit".utf8)],
      state: state
    )
    #expect(exit.status == 23)
    #expect(exit.variables.isEmpty)
  }

  @Test
  func builtinPayloadRoundTripAndKindValidation() throws {
    let arguments = [Array("exit".utf8)]
    let context = BuiltinWorkerContext(
      builtin: .exit,
      arguments: arguments,
      state: ShellState(status: 23)
    )
    var payload = LauncherPayload(
      build: "worker-test",
      executable: [47, 120],
      arguments: arguments,
      environment: [],
      redirects: []
    )
    payload.kind = .builtin
    payload.builtinContext = context
    let file = try payload.write()
    let decoded = try file.withDescriptor {
      try LauncherPayload.read(descriptor: $0, build: "worker-test")
    }
    #expect(decoded == payload)

    payload.kind = .external
    let wrong = try payload.write()
    _ = wrong.withDescriptor { fd in
      #expect(throws: SystemFailure.self) {
        try LauncherPayload.read(descriptor: fd, build: "worker-test")
      }
    }
  }

  @Test
  func unsupportedJobActionsCannotEnterAWorker() throws {
    var payload = LauncherPayload(
      build: "worker-test",
      executable: [47, 120],
      arguments: [Array("fg".utf8)],
      environment: [],
      redirects: []
    )
    payload.kind = .builtin
    payload.builtinContext = BuiltinWorkerContext(
      builtin: .fg,
      arguments: payload.arguments,
      state: ShellState()
    )
    let file = try payload.write()
    _ = file.withDescriptor { fd in
      #expect(throws: SystemFailure.self) {
        try LauncherPayload.read(descriptor: fd, build: "worker-test")
      }
    }
  }
}
