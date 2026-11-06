#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

enum EvaluationControl: Equatable {
  case continuing(Int32)
  case exit(Int32)
}

/// Explicit I/O avoids redirecting the host's standard descriptors for a builtin.
struct BuiltinIO {
  let output: Int32
  let error: Int32
  var input: Int32 = STDIN_FILENO
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
      case .jobs, .fg, .bg, .return, .trap, .break, .continue, .read, .local:
        throw UsageFailure("\(builtin.rawValue) requires the session driver")
      case .set:
        guard !arguments.isEmpty else {
          let lines = ShellOptions.names.map {
            "set \(state.options[$0] == true ? "-" : "+")o \($0)\n"
          }
          try writeBytes(Array(lines.joined().utf8), to: io.output)
          break
        }
        // Validate the entire request before changing any policy.
        var options = state.options
        var index = 0
        while index < arguments.count {
          let argument = String(decoding: arguments[index], as: UTF8.self)
          index += 1
          guard argument.count >= 2, let sign = argument.first,
            sign == "-" || sign == "+"
          else {
            throw UsageFailure(
              "set: expected -e, -u, or -o name; use + to disable"
            )
          }
          for flag in argument.dropFirst() {
            switch flag {
            case "e": options.errexit = sign == "-"
            case "u": options.nounset = sign == "-"
            case "o":
              guard flag == argument.last, index < arguments.count,
                case let name = String(
                  decoding: arguments[index],
                  as: UTF8.self
                ), options[name] != nil
              else {
                throw UsageFailure(
                  "set: -o expects errexit, nounset, or pipefail"
                )
              }
              options[name] = sign == "-"
              index += 1
            default: throw UsageFailure("set: unsupported option -\(flag)")
            }
          }
        }
        state.options = options
      case .shift:
        let parameters = state.arrays["@"] ?? []
        let count =
          arguments.first.map { Int(String(decoding: $0, as: UTF8.self)) } ?? 1
        guard arguments.count <= 1, let count, count >= 0,
          count <= parameters.count
        else {
          throw UsageFailure(
            "shift: expected a count from 0 through \(parameters.count)"
          )
        }
        state.setArguments(Array(parameters.dropFirst(count)))
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
        if let (name, _) = entries.first(where: { state.arrays[$0.0] != nil }) {
          throw UsageFailure("export: \(name) is a list")
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
          state.arrays.removeValue(forKey: name)
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
