import Darwin

/// Exact source and a value snapshot cross the private file handoff. No expansion
/// has run for this body; the worker evaluates it once in its inherited job group.
struct SourceWorkerContext: Codable, Equatable {
  let source: [UInt8]
  let state: ShellState
  var functionArguments: [[UInt8]]? = nil

  func run(
    executable: [UInt8],
    build: String,
    supervisorDescriptor: Int32? = nil
  ) throws -> Int32 {
    guard state.executionDepth < 128 else {
      throw ShellDiagnostic(offset: 0, message: "worker nesting limit exceeded")
    }
    let supervisor = try JobSupervisor(executable: executable, build: build)
    supervisor.propagateChildStops = true
    if let supervisorDescriptor {
      try writeBytes([1], to: supervisorDescriptor)
    }
    var status: Int32 = 1
    do {
      let driver = try SessionDriver(supervisor: supervisor)
      driver.state = state
      driver.state.executionDepth += 1
      let result: SubmissionResult
      if let arguments = functionArguments {
        result =
          try driver.callFunction(source, arguments: arguments)
          ?? .completed(driver.state.status)
      } else {
        result = try driver.submit(ShellMain.parse(source))
      }
      switch result {
      case .completed(let result), .exit(let result): status = result
      case .stopped: status = 1
      }
    } catch {
      ShellMain.diagnostic(error)
      status = error is ShellDiagnostic ? 2 : 1
    }
    // This private synchronous entry runs outside the cooperative executor.
    if !supervisor.shutdown() { return 1 }
    return status
  }
}
