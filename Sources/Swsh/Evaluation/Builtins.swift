import Darwin

enum EvaluationControl: Equatable {
  case continuing(Int32)
  case exit(Int32)
}

/// Explicit I/O avoids redirecting the host's standard descriptors for a builtin.
struct BuiltinIO {
  let output: Int32
  let error: Int32
}

struct BuiltinEvaluator {
  func run(
    _ builtin: Builtin,
    arguments: [[UInt8]],
    state: inout ShellState,
    directory: inout WorkingDirectory,
    io: BuiltinIO
  ) -> EvaluationControl {
    do {
      switch builtin {
      case .complete:
        guard let first = arguments.first else {
          throw UsageFailure(
            "complete: expected command and candidates, or --function command provider"
          )
        }
        if first == Array("--function".utf8) {
          guard arguments.count == 3,
            let command = String(validating: arguments[1], as: UTF8.self),
            let provider = String(validating: arguments[2], as: UTF8.self),
            state.functions[provider] != nil
          else {
            throw UsageFailure(
              "complete: expected an existing provider function"
            )
          }
          state.completionFunctions[command] = provider
          state.completions.removeValue(forKey: command)
        } else {
          guard let command = String(validating: first, as: UTF8.self),
            !command.isEmpty
          else { throw UsageFailure("complete: invalid command") }
          state.completions[command] = Array(arguments.dropFirst())
          state.completionFunctions.removeValue(forKey: command)
        }
      case .exec:
        return .continuing(
          ExecReplacement().run(arguments: arguments, state: state)
        )
      case .jobs, .fg, .bg, .return:
        throw UsageFailure("job actions require the session driver")
      case .colon, .true: return .continuing(0)
      case .false: return .continuing(1)
      case .exit:
        guard arguments.count <= 1 else {
          throw UsageFailure("exit: expected zero or one status")
        }
        guard let argument = arguments.first else { return .exit(state.status) }
        guard let number = Int32(String(decoding: argument, as: UTF8.self)),
          (0 ... 255).contains(number)
        else {
          throw UsageFailure(
            "exit: status must be an integer from 0 through 255"
          )
        }
        return .exit(number)
      case .pwd:
        guard arguments.isEmpty else {
          throw UsageFailure("pwd: no arguments supported")
        }
        try writeBytes(directory.physicalPath() + [10], to: io.output)
      case .cd:
        guard arguments.count <= 1 else {
          throw UsageFailure("cd: expected zero or one path")
        }
        guard let path = arguments.first ?? state.variables["HOME"] else {
          throw UsageFailure("cd: HOME is unset")
        }
        try directory.change(to: path)
      case .export:
        // Validate the entire request before mutating logical state.
        let entries = try arguments.map { argument -> (String, [UInt8]?) in
          let equal = argument.firstIndex(of: 61)
          let name = try variableName(
            equal.map { Array(argument[..<$0]) } ?? argument
          )
          return (name, equal.map { Array(argument[($0 + 1)...]) })
        }
        for (name, value) in entries {
          if let value { state.variables[name] = value }
          if state.variables[name] == nil { state.variables[name] = [] }
          state.exported.insert(name)
        }
      case .unset:
        let names = try arguments.map(variableName)
        for name in names {
          state.variables.removeValue(forKey: name)
          state.exported.remove(name)
        }
      }
      return .continuing(0)
    } catch {
      try? writeBytes(Array("swsh: \(error)\n".utf8), to: io.error)
      return .continuing(error is UsageFailure ? 2 : 1)
    }
  }

  private func variableName(_ bytes: [UInt8]) throws -> String {
    func initial(_ byte: UInt8) -> Bool {
      byte == 95 || (65 ... 90).contains(byte) || (97 ... 122).contains(byte)
    }
    guard let first = bytes.first, initial(first),
      bytes.dropFirst().allSatisfy({ initial($0) || (48 ... 57).contains($0) })
    else { throw UsageFailure("expected an ASCII variable name") }
    return String(decoding: bytes, as: UTF8.self)
  }
}

private struct UsageFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}
