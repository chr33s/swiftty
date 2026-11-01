import Darwin

struct FunctionReturn: Error { let status: Int32 }

extension ShellState {
  mutating func setArguments(_ arguments: [[UInt8]]) {
    for i in 1 ... 9 {
      variables[String(i)] = i <= arguments.count ? arguments[i - 1] : []
    }
    variables["#"] = Array(String(arguments.count).utf8)
  }
}

extension SessionDriver {
  func callFunctionCommand(
    _ command: PreparedCommand,
    body: [UInt8]
  ) throws -> SubmissionResult? {
    if command.redirects.isEmpty {
      return try callFunction(
        body,
        arguments: Array(command.arguments.dropFirst())
      )
    }
    guard
      command.redirects.allSatisfy({ action in
        switch action {
        case .open(let fd, _, _), .duplicate(let fd, _), .close(let fd):
          return fd <= 2
        }
      })
    else {
      throw ShellDiagnostic(
        offset: 0,
        message: "parent function redirects support descriptors 0, 1, and 2"
      )
    }
    switch try supervisor.prepareRedirects(command.redirects) {
    case .failed(let status):
      state.status = status;
      return nil
    case .shutdown(let status): return .exit(status)
    case .ready(let descriptors):
      let previousIO = builtinIO
      let previousWiring = supervisor.inheritedWiring
      defer {
        builtinIO = previousIO;
        supervisor.inheritedWiring = previousWiring
      }
      builtinIO = descriptors.builtinIO
      let descriptorsBySlot: [Int32] = [
        descriptors.input?.withDescriptor { $0 } ?? -1,
        descriptors.output?.withDescriptor { $0 } ?? -1,
        descriptors.error?.withDescriptor { $0 } ?? -1,
      ]
      supervisor.inheritedWiring = descriptorsBySlot.enumerated()
        .map { index, fd -> DarwinSpawn.Wiring in
          fd < 0
            ? .close(Int32(index))
            : .duplicate(source: fd, destination: Int32(index))
        }
      return try callFunction(
        body,
        arguments: Array(command.arguments.dropFirst())
      )
    }
  }

  func callFunction(
    _ source: [UInt8],
    arguments: [[UInt8]]
  ) throws -> SubmissionResult? {
    guard functionDepth < 16 else {
      throw ShellDiagnostic(
        offset: 0,
        message: "function recursion limit exceeded"
      )
    }
    let names = (1 ... 9).map(String.init) + ["#"]
    let saved = names.map { state.variables[$0] }
    functionDepth += 1
    state.setArguments(arguments)
    defer {
      functionDepth -= 1
      for (name, value) in zip(names, saved) { state.variables[name] = value }
    }
    do {
      switch try submit(ShellMain.parse(source)) {
      case .completed: return nil
      case .exit(let status): return .exit(status)
      case .stopped(let job): return .stopped(job)
      }
    } catch let result as FunctionReturn {
      state.status = result.status;
      return nil
    }
  }

  func prepare(_ command: SimpleCommand) throws -> PreparedCommand {
    func expand(_ word: Word) throws -> Word {
      Word(
        range: word.range,
        parts: try word.parts.map { part in
          if case .substitution(let source) = part {
            var bytes = try supervisor.capture(source: source, state: state)
            while bytes.last == 10 { bytes.removeLast() }
            return .literal(bytes)
          }
          return part
        }
      )
    }
    if case .function = command.compound {
      throw ShellDiagnostic(
        offset: 0,
        message: "function definitions require a standalone command"
      )
    }
    let expanded = SimpleCommand(
      assignments: try command.assignments.map {
        Assignment(name: $0.name, value: try expand($0.value))
      },
      words: try command.words.map(expand),
      redirects: try command.redirects.map {
        Redirect(
          descriptor: $0.descriptor,
          operation: $0.operation,
          target: try expand($0.target)
        )
      }
    )
    var prepared = try Expander(state: state).prepare(expanded)
    if case .subshell(let source) = command.compound {
      prepared = PreparedCommand(
        assignments: prepared.assignments,
        arguments: [Array("(subshell)".utf8)],
        redirects: prepared.redirects,
        source: source
      )
    }
    return prepared
  }
}

extension SessionDriver {
  func complete(_ source: [UInt8]) throws -> [UInt8]? {
    guard !source.contains(where: { [39, 34, 92, 36].contains($0) }) else {
      return nil
    }
    let command = String(
      decoding: source.prefix { $0 != 32 && $0 != 9 },
      as: UTF8.self
    )
    guard let provider = state.completionFunctions[command],
      let body = state.functions[provider],
      source.contains(32) || source.contains(9)
    else { return Completion(state: state).suffix(for: source) }
    let token = Array(
      source.reversed().prefix { $0 != 32 && $0 != 9 }.reversed()
    )
    do {
      let output = try supervisor.capture(
        source: body,
        state: state,
        timeout: .seconds(1),
        functionArguments: [token, source]
      )
      return Completion(state: state)
        .suffix(
          for: source,
          candidates: output.split(separator: 10).map(Array.init)
        )
    } catch {
      // A failed provider offers no candidates and never changes command status.
      return nil
    }
  }
}
