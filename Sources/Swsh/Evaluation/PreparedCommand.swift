#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import CSwshSupport

/// Pipeline stages are prepared before launch. The driver resolves effectful
/// substitutions in separately supervised jobs before pure scalar/path expansion.
struct PreparedCommand: Equatable, Sendable {
  let assignments: [String: [UInt8]]
  let arguments: [[UInt8]]
  let redirects: [DescriptorAction]
  var source: [UInt8]? = nil
  var functionArguments: [[UInt8]]? = nil
  /// List, element, and append assignments of a standalone assignment command.
  var updates: [VariableUpdate] = []

  var builtin: Builtin? { arguments.first.flatMap(Builtin.init(bytes:)) }
}

enum VariableUpdate: Equatable, Sendable {
  case append(String, [UInt8])
  case list(String, [[UInt8]], append: Bool)
  case element(String, Int64, [UInt8])
}

enum DescriptorAction: Equatable, Codable, Sendable {
  static let maximumHeredocBytes = 1024 * 1024

  case open(descriptor: Int32, path: [UInt8], mode: OpenMode)
  /// A heredoc body, delivered as an unlinked private file.
  case data(descriptor: Int32, bytes: [UInt8])
  case duplicate(descriptor: Int32, source: Int32)
  case close(descriptor: Int32)

  enum OpenMode: String, Codable, Sendable { case read, write, append }
}

extension Expander {
  func prepare(_ command: SimpleCommand) throws -> PreparedCommand {
    var assignments: [String: [UInt8]] = [:]
    // Every RHS sees the pre-command state. Assignments commit together.
    var updates: [VariableUpdate] = []
    for assignment in command.assignments {
      let name = assignment.name
      if let elements = assignment.elements {
        updates.append(
          .list(name, try elements.flatMap(paths), append: assignment.append)
        )
      } else if let index = assignment.index {
        updates.append(
          .element(
            name,
            try integer(index, in: assignment.value),
            try scalar(assignment.value).bytes
          )
        )
      } else if assignment.append {
        updates.append(.append(name, try scalar(assignment.value).bytes))
      } else {
        assignments[name] = try scalar(assignment.value).bytes
      }
    }
    let arguments = try command.words.flatMap(paths)
    guard updates.isEmpty || arguments.isEmpty else {
      throw ShellDiagnostic(
        offset: command.assignments[0].value.range.lowerBound,
        message:
          "list, element, and append assignments require a standalone assignment"
      )
    }
    if !updates.isEmpty {
      var next = state
      next.assign(assignments)
      try next.apply(updates)
    }
    let redirects = try command.redirects.map { redirect -> DescriptorAction in
      if redirect.operation == .heredoc {
        let body = try scalar(redirect.target).bytes
        guard body.count <= DescriptorAction.maximumHeredocBytes else {
          throw ShellDiagnostic(
            offset: redirect.target.range.lowerBound,
            message: "heredoc exceeds 1 MiB"
          )
        }
        return .data(descriptor: redirect.descriptor, bytes: body)
      }
      let target = try redirectPath(redirect.target)
      switch redirect.operation {
      case .read:
        return .open(descriptor: redirect.descriptor, path: target, mode: .read)
      case .write:
        return .open(
          descriptor: redirect.descriptor,
          path: target,
          mode: .write
        )
      case .append:
        return .open(
          descriptor: redirect.descriptor,
          path: target,
          mode: .append
        )
      case .heredoc: preconditionFailure("heredoc handled above")
      case .duplicateInput, .duplicateOutput:
        if target == [45] { return .close(descriptor: redirect.descriptor) }
        guard !target.isEmpty, target.allSatisfy({ (48 ... 57).contains($0) }),
          let source = Int32(String(decoding: target, as: UTF8.self))
        else {
          throw ShellDiagnostic(
            offset: redirect.target.range.lowerBound,
            message: "expected descriptor number or '-'"
          )
        }
        return .duplicate(descriptor: redirect.descriptor, source: source)
      }
    }
    let prepared = PreparedCommand(
      assignments: assignments,
      arguments: arguments,
      redirects: redirects,
      updates: updates
    )
    if prepared.builtin != nil && !command.assignments.isEmpty {
      throw ShellDiagnostic(
        offset: command.assignments[0].value.range.lowerBound,
        message: "prefix assignments to builtins are not supported"
      )
    }
    return prepared
  }
}

enum Builtin: String, CaseIterable, Codable, Sendable {
  case cd, pwd, export, unset, exit, jobs, fg, bg, exec, complete, `return`
  case set, trap, `break`, `continue`, read, shift, local
  case colon = ":"
  case `true`, `false`

  init?(bytes: [UInt8]) {
    guard let name = String(validating: bytes, as: UTF8.self),
      !bytes.contains(47)
    else { return nil }
    self.init(rawValue: name)
  }
}

extension ShellState {
  mutating func assign(_ assignments: [String: [UInt8]]) {
    variables.merge(assignments) { _, new in new }
    for name in assignments.keys { arrays.removeValue(forKey: name) }
  }

  /// Applies every update or none, in source order.
  mutating func apply(_ updates: [VariableUpdate]) throws {
    func failure(_ message: String) -> ShellDiagnostic {
      ShellDiagnostic(offset: 0, message: message)
    }
    var next = self
    for update in updates {
      switch update {
      case .append(let name, let bytes):
        guard next.arrays[name] == nil else {
          throw failure("\(name) is a list; append with \(name)+=(words)")
        }
        next.variables[name, default: []] += bytes
      case .list(let name, let values, let append):
        guard !next.exported.contains(name) else {
          throw failure("\(name) is exported; a list cannot be exported")
        }
        if append {
          guard next.variables[name] == nil else {
            throw failure("\(name) is not a list")
          }
          next.arrays[name, default: []] += values
        } else {
          next.variables.removeValue(forKey: name)
          next.arrays[name] = values
        }
        guard next.arrays[name]!.count <= 65536 else {
          throw failure("\(name): a list holds at most 65536 elements")
        }
      case .element(let name, let index, let bytes):
        guard var values = next.arrays[name] else {
          throw failure("\(name) is not a list")
        }
        guard index >= 0, index <= Int64(values.count), index < 65536 else {
          throw failure("\(name)[\(index)]: index out of range")
        }
        if index == Int64(values.count) {
          values.append(bytes)
        } else {
          values[Int(index)] = bytes
        }
        next.arrays[name] = values
      }
    }
    self = next
  }

  func environment(overlay: [String: [UInt8]] = [:]) throws -> [[UInt8]] {
    var values = variables.filter { exported.contains($0.key) }
    values.merge(overlay) { _, new in new }
    let entries = try values.keys.sorted()
      .map { name in
        let key = Array(name.utf8)
        let value = values[name]!
        guard !key.isEmpty, !key.contains(0), !key.contains(61),
          !value.contains(0)
        else {
          throw ShellDiagnostic(offset: 0, message: "invalid environment entry")
        }
        return key + [61] + value
      }
    return entries + opaqueEnvironment
  }

  static func inherited() -> ShellState {
    var state = ShellState()
    state.processID = getpid()
    var cursor = swsh_environment()!
    while let entry = cursor.pointee {
      let bytes = Array(
        UnsafeRawBufferPointer(start: entry, count: strlen(entry))
      )
      if let equal = bytes.firstIndex(of: 61),
        let name = String(validating: bytes[..<equal], as: UTF8.self)
      {
        state.variables[name] = Array(bytes[(equal + 1)...])
        state.exported.insert(name)
      } else {
        state.opaqueEnvironment.append(bytes)
      }
      cursor += 1
    }
    return state
  }
}
