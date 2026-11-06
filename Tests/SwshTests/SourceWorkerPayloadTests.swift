#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Testing
@testable import Swsh

struct SourceWorkerPayloadTests {
  private func payload(
    state: ShellState = ShellState(),
    arguments: [[UInt8]]? = nil,
    source: [UInt8] = Array("true".utf8)
  ) -> LauncherPayload {
    var payload = LauncherPayload(
      build: "source-test",
      executable: Array("/swsh".utf8),
      arguments: [Array("(source)".utf8)],
      environment: [],
      redirects: []
    )
    payload.kind = .source
    payload.sourceContext = SourceWorkerContext(
      source: source,
      state: state,
      functionArguments: arguments
    )
    return payload
  }

  @Test
  func sourceSnapshotRoundTripPreservesBytesAndDefinitions() throws {
    var state = ShellState(
      variables: ["value": [255, 42]],
      exported: ["value"],
      status: 7
    )
    state.functions["f"] = Array("return 3".utf8)
    state.completions["echo"] = [Array("two words".utf8)]
    state.completionFunctions["cat"] = "f"
    state.executionDepth = 127
    let expected = payload(state: state, arguments: [[254], []])
    let file = try expected.write()
    try file.withDescriptor { fd in
      let decoded = try LauncherPayload.read(
        descriptor: fd,
        build: "source-test"
      )
      #expect(decoded == expected)
    }
  }

  @Test(arguments: [
    "missing-context", "wrong-kind", "nul-source", "invalid-utf8",
    "nul-argument", "nul-variable", "nul-environment", "invalid-function",
    "negative-depth", "depth-limit", "past-limit", "builtin-context",
    "invalid-supervisor-descriptor",
  ])
  func invalidSourceContextRejected(_ fault: String) throws {
    var state = ShellState()
    var source = Array("true".utf8)
    var arguments: [[UInt8]]? = nil
    switch fault {
    case "nul-source": source = [0]
    case "invalid-utf8": source = [255]
    case "nul-argument": arguments = [[0]]
    case "nul-variable": state.variables["x"] = [0]
    case "nul-environment": state.opaqueEnvironment = [[65, 61, 0]]
    case "invalid-function": state.functions["f"] = [255]
    case "negative-depth": state.executionDepth = -1
    case "depth-limit": state.executionDepth = 128
    case "past-limit": state.executionDepth = 129
    default: break
    }
    var invalid = payload(state: state, arguments: arguments, source: source)
    if fault == "missing-context" { invalid.sourceContext = nil }
    if fault == "invalid-supervisor-descriptor" {
      invalid.supervisorDescriptor = 1
    }
    if fault == "wrong-kind" { invalid.kind = .external }
    if fault == "builtin-context" {
      invalid.builtinContext = BuiltinWorkerContext(
        builtin: .true,
        arguments: [[116]],
        state: state
      )
    }
    let file = try invalid.write()
    _ = file.withDescriptor { fd in
      #expect(throws: SystemFailure.self) {
        try LauncherPayload.read(descriptor: fd, build: "source-test")
      }
    }
  }

  @Test
  func oversizedSnapshotFailsBeforeCreatingWorker() throws {
    let state = ShellState(variables: [
      "large": [UInt8](repeating: 120, count: 3 * 1024 * 1024)
    ])
    do {
      _ = try payload(state: state).write()
      Issue.record("oversized snapshot was accepted")
    } catch let error as SystemFailure { #expect(error.code == E2BIG) }
  }

  @Test
  func sourceBuildIdentityAndTruncationAreChecked() throws {
    let file = try payload().write()
    file.withDescriptor { fd in
      #expect(throws: SystemFailure.self) {
        try LauncherPayload.read(descriptor: fd, build: "wrong")
      }
      #expect(lseek(fd, 0, SEEK_SET) == 0)
      #expect(ftruncate(fd, 20) == 0)
      #expect(throws: SystemFailure.self) {
        try LauncherPayload.read(descriptor: fd, build: "source-test")
      }
    }
  }
}

struct WorkerLeaseTests {
  @Test
  func leaseRequiresAnnouncementAndEndsOnClose() throws {
    let pipe = try OwnedFD.pipe()
    try pipe.withEnds { input, output in
      #expect(input.withDescriptor { fcntl($0, F_SETFL, O_NONBLOCK) } == 0)
      var lease = WorkerLease(pid: 123, input: consume input)
      let initial = lease.isSupervising()
      #expect(!initial)
      try output.withDescriptor { try writeBytes([1], to: $0) }
      let announced = lease.isSupervising()
      let retained = lease.isSupervising()
      #expect(announced)
      #expect(retained)
      try output.close()
      let closed = lease.isSupervising()
      #expect(!closed)
    }
  }

  @Test
  func nestingLimitRejectedBeforeRuntimeInitialization() {
    var state = ShellState()
    state.executionDepth = 128
    let context = SourceWorkerContext(source: Array("true".utf8), state: state)
    #expect(throws: ShellDiagnostic.self) {
      try context.run(executable: [47], build: "unused")
    }
  }
}
