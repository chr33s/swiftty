import Darwin
import CSwshSupport

/// Pipeline stages are prepared before launch. The driver resolves effectful
/// substitutions in separately supervised jobs before pure scalar/path expansion.
struct PreparedCommand: Equatable, Sendable {
  let assignments: [String: [UInt8]]
  let arguments: [[UInt8]]
  let redirects: [DescriptorAction]
  var source: [UInt8]? = nil
  var functionArguments: [[UInt8]]? = nil

  var builtin: Builtin? { arguments.first.flatMap(Builtin.init(bytes:)) }
}

enum DescriptorAction: Equatable, Codable, Sendable {
  case open(descriptor: Int32, path: [UInt8], mode: OpenMode)
  case duplicate(descriptor: Int32, source: Int32)
  case close(descriptor: Int32)

  enum OpenMode: String, Codable, Sendable { case read, write, append }
}

extension Expander {
  func prepare(_ command: SimpleCommand) throws -> PreparedCommand {
    var assignments: [String: [UInt8]] = [:]
    // Every RHS sees the pre-command state. Assignments commit together.
    for assignment in command.assignments {
      assignments[assignment.name] = try scalar(assignment.value).bytes
    }
    let arguments = try command.words.flatMap(paths)
    let redirects = try command.redirects.map { redirect -> DescriptorAction in
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
      redirects: redirects
    )
    if prepared.builtin != nil && !assignments.isEmpty {
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
