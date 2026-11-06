#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

enum SubmissionResult {
  case completed(Int32)
  case stopped(JobID)
  case exit(Int32)
}

/// Exactly one synchronous FIFO driver mutates this session's language state.
final class SessionDriver {
  var state = ShellState.inherited()
  var functionDepth = 0
  /// Enclosing `if`/`while`/`until` conditions, where `set -e` does not apply.
  var conditionDepth = 0
  /// Enclosing loops in the current function, for `break` and `continue`.
  var loopDepth = 0
  /// Every running loop, across function calls.
  var activeLoops = 0
  /// Trap source by signal number; 0 is EXIT. Workers start without traps.
  var traps: [Int32: [UInt8]] = [:]
  var runningTrap = false
  /// One entry per running function: what each `local` name held before.
  var localScopes: [[String: SavedVariable]] = []
  var builtinIO = BuiltinIO(output: STDOUT_FILENO, error: STDERR_FILENO)
  private var directory: WorkingDirectory
  let supervisor: JobSupervisor

  init(supervisor: JobSupervisor) throws {
    self.supervisor = supervisor
    directory = try WorkingDirectory()
  }

  func submit(_ program: Program) throws -> SubmissionResult {
    for (index, entry) in program.commands.enumerated() {
      try supervisor.poll(milliseconds: 0)
      supervisor.discardCompleted()
      if let requested = supervisor.shutdownRequested {
        return .exit(requested)
      }
      if let result = try runPendingTraps() { return result }
      if entry.condition == .success && state.status != 0 { continue }
      if entry.condition == .failure && state.status == 0 { continue }
      if let result = try run(entry) { return result }
      if entry.negated {
        state.status = state.status == 0 ? 1 : 0
      } else if state.options.errexit, state.status != 0, conditionDepth == 0,
        !entry.background
      {
        // Every operand of an AND-OR list except the last is a condition.
        let following = program.commands.dropFirst(index + 1).first
        if following.map({ $0.condition == .always }) ?? true {
          return .exit(state.status)
        }
      }
    }
    return .completed(state.status)
  }

  /// Runs one selected list entry. nil means the list continues.
  private func run(_ entry: CommandListEntry) throws -> SubmissionResult? {
    if entry.pipeline.count == 1, !entry.background,
      entry.pipeline[0].assignments.isEmpty,
      // Other descriptors need a worker's own descriptor namespace.
      entry.pipeline[0].redirects.allSatisfy({ $0.descriptor <= 2 }),
      let compound = entry.pipeline[0].compound, compound.runsInParent
    {
      let redirects = try prepare(
        SimpleCommand(
          assignments: [],
          words: [],
          redirects: entry.pipeline[0].redirects
        )
      )
      .redirects
      return try withParentRedirects(redirects) {
        switch compound {
        case .conditional(let branches, let otherwise, _):
          return try runConditional(branches, otherwise: otherwise)
        case .loop(let until, let condition, let body, _):
          return try runLoop(until: until, condition: condition, body: body)
        case .forEach(let name, let words, let body, _):
          return try runForEach(name, words: words, body: body)
        case .group(let body, _): return try runGroup(body)
        case .select(let word, let clauses, _):
          return try runSelect(word, clauses: clauses)
        case .function, .subshell: return nil
        }
      }
    }
    if entry.pipeline.count == 1,
      case .function(let name, let body) = entry.pipeline[0].compound
    {
      guard !entry.background, entry.pipeline[0].redirects.isEmpty,
        Builtin(rawValue: name) == nil
      else {
        throw usage(
          "function definitions cannot be redirected, backgrounded, or replace builtins"
        )
      }
      state.functions[name] = body
      state.status = 0
      return nil
    }
    let commands = try entry.pipeline.map { try prepare($0) }
    for command in commands {
      if let name = command.arguments.first.flatMap({
        String(validating: $0, as: UTF8.self)
      }), state.functions[name] != nil, !command.assignments.isEmpty {
        throw usage("prefix assignments to functions are not supported")
      }
    }
    if commands.count == 1, let command = commands.first, !entry.background,
      command.source == nil,
      let name = command.arguments.first.flatMap({
        String(validating: $0, as: UTF8.self)
      }), let body = state.functions[name]
    {
      if let result = try callFunctionCommand(command, body: body) {
        return result
      }
      return nil
    }
    if commands.contains(where: { $0.builtin == .exec && !$0.redirects.isEmpty }
    ) {
      throw usage("exec supports inherited descriptors only")
    }
    if commands.count == 1, let command = commands.first, !entry.background,
      (command.arguments.isEmpty || command.builtin != nil)
        && command.source == nil
    {
      if command.redirects.isEmpty {
        if let result = try runParentCommand(command, io: builtinIO) {
          return result
        }
      } else {
        switch try supervisor.prepareRedirects(command.redirects) {
        case .ready(let descriptors):
          if let result = try runParentCommand(
            command,
            io: descriptors.builtinIO
          ) {
            return result
          }
        case .failed(let status): state.status = status
        case .shutdown(let status): return .exit(status)
        }
      }
      return nil
    }
    guard
      commands.allSatisfy({
        !$0.arguments.isEmpty
          && ($0.builtin.map(BuiltinWorkerContext.supports) ?? true)
      })
    else {
      throw usage(
        "job-control builtins and assignment-only commands cannot be worker stages"
      )
    }
    let workers = commands.map { command -> PreparedCommand in
      guard command.source == nil,
        let name = command.arguments.first.flatMap({
          String(validating: $0, as: UTF8.self)
        }), let body = state.functions[name]
      else { return command }
      var worker = command
      worker.source = body
      worker.functionArguments = Array(command.arguments.dropFirst())
      return worker
    }
    let id = try supervisor.launch(
      workers,
      state: state,
      background: entry.background
    )
    if entry.background {
      state.status = 0
      try supervisor.terminal?.write(Array("[\(id.value)] scheduled\r\n".utf8))
      return nil
    }
    return try wait(id)
  }

  private func runParentCommand(
    _ command: PreparedCommand,
    io: BuiltinIO
  ) throws -> SubmissionResult? {
    guard let builtin = command.builtin else {
      var next = state
      next.assign(command.assignments)
      try next.apply(command.updates)
      state = next
      state.status = 0
      return nil
    }
    if builtin == .break || builtin == .continue {
      guard command.arguments.count <= 2,
        let levels = command.arguments.count == 1
          ? 1 : Int(String(decoding: command.arguments[1], as: UTF8.self)),
        levels >= 1, levels <= loopDepth
      else {
        throw usage(
          loopDepth == 0
            ? "\(builtin.rawValue) requires an enclosing loop"
            : "\(builtin.rawValue) expects a loop count from 1 through \(loopDepth)"
        )
      }
      throw builtin == .break
        ? LoopControl.break(levels) : LoopControl.continue(levels)
    }
    if builtin == .read {
      return try read(Array(command.arguments.dropFirst()), io: io)
    }
    if builtin == .local {
      try local(Array(command.arguments.dropFirst()))
      state.status = 0
      return nil
    }
    if builtin == .trap {
      do {
        try trap(Array(command.arguments.dropFirst()), io: io)
        state.status = 0
      } catch let error as ShellDiagnostic {
        try? writeBytes(Array("swsh: \(error.message)\n".utf8), to: io.error)
        state.status = 2
      }
      return nil
    }
    if builtin == .return {
      guard functionDepth > 0, command.arguments.count <= 2 else {
        throw usage("return requires a function and at most one status")
      }
      let status =
        command.arguments.count == 1
        ? state.status
        : Int32(String(decoding: command.arguments[1], as: UTF8.self))
      guard let status, (0 ... 255).contains(status) else {
        throw usage("return: expected status 0 through 255")
      }
      throw FunctionReturn(status: status)
    }
    if builtin == .exec {
      guard supervisor.inheritedWiring.isEmpty else {
        throw usage("exec inside a redirected function is not supported")
      }
      guard !supervisor.hasLiveJobs else {
        throw usage("exec requires all owned jobs to finish first")
      }
      try supervisor.terminal?.commandMode()
    }
    if [.jobs, .fg, .bg].contains(builtin) {
      do {
        return try jobAction(
          builtin,
          arguments: Array(command.arguments.dropFirst()),
          io: io
        )
      } catch {
        if supervisor.terminal?.healthy == false { throw error }
        try? writeBytes(Array("swsh: \(error)\n".utf8), to: io.error)
        state.status = error is ShellDiagnostic ? 2 : 1
        return nil
      }
    }
    switch BuiltinEvaluator()
      .run(
        builtin,
        arguments: Array(command.arguments.dropFirst()),
        state: &state,
        directory: &directory,
        io: io
      )
    {
    case .continuing(let status):
      state.status = status;
      return nil
    case .exit(let status): return .exit(status)
    }
  }

  private func jobAction(
    _ builtin: Builtin,
    arguments: [[UInt8]],
    io: BuiltinIO
  ) throws -> SubmissionResult? {
    guard supervisor.terminal != nil else {
      throw usage("interactive job control is unavailable")
    }
    if builtin == .jobs {
      guard arguments.isEmpty else { throw usage("jobs accepts no arguments") }
      for (id, disposition) in supervisor.listing() {
        let label: String
        switch disposition {
        case .running: label = "running"
        case .stopped: label = "stopped"
        case .completed(let result): label = "done (\(result.status))"
        }
        try writeBytes(Array("[\(id.value)] \(label)\n".utf8), to: io.output)
      }
      state.status = 0
      return nil
    }
    guard arguments.count <= 1 else {
      throw usage("fg/bg accepts one optional job ID")
    }
    let id = try supervisor.selectJob(arguments.first)
    try supervisor.resume(id, foreground: builtin == .fg)
    if builtin == .fg { return try wait(id) }
    state.status = 0
    return nil
  }

  private func wait(_ id: JobID) throws -> SubmissionResult? {
    switch try supervisor.wait(for: id) {
    case .completed(let result):
      state.status = result.status;
      return nil
    case .stopped:
      try supervisor.terminal?.write(Array("[\(id.value)] stopped\r\n".utf8))
      return .stopped(id)
    case .running: return .exit(supervisor.shutdownRequested ?? 1)
    }
  }

  func usage(_ message: String) -> ShellDiagnostic {
    ShellDiagnostic(offset: 0, message: message)
  }
}
