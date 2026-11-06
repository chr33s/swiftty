/// Only the logical values read by this builtin cross the private process boundary.
/// Arguments have already expanded; a worker never reparses or launches another worker.
struct BuiltinWorkerContext: Codable, Equatable {
  let builtin: Builtin
  let variables: [String: [UInt8]]
  let exported: Set<String>
  let status: Int32
  let opaqueEnvironment: [[UInt8]]

  static func supports(_ builtin: Builtin) -> Bool {
    ![
      .jobs, .fg, .bg, .complete, .return, .set, .trap, .break, .continue,
      .read, .shift, .local,
    ]
    .contains(builtin)
  }

  init(builtin: Builtin, arguments: [[UInt8]], state: ShellState) {
    self.builtin = builtin
    var names: Set<String> = []
    switch builtin {
    case .exec: names = state.exported.union(["PATH"])
    case .cd: if arguments.count == 1 { names.insert("HOME") }
    case .export, .unset:
      for argument in arguments.dropFirst() {
        let name = argument.prefix { $0 != 61 }
        if let decoded = String(validating: name, as: UTF8.self) {
          names.insert(decoded)
        }
      }
    default: break
    }
    variables = state.variables.filter { names.contains($0.key) }
    exported = state.exported.intersection(names)
    status = state.status
    opaqueEnvironment = builtin == .exec ? state.opaqueEnvironment : []
  }

  func run(arguments: [[UInt8]]) throws -> Int32 {
    var state = ShellState(
      variables: variables,
      exported: exported,
      status: status
    )
    state.opaqueEnvironment = opaqueEnvironment
    var directory = try WorkingDirectory()
    switch BuiltinEvaluator()
      .run(
        builtin,
        arguments: Array(arguments.dropFirst()),
        state: &state,
        directory: &directory,
        io: BuiltinIO(output: 1, error: 2)
      )
    {
    case .continuing(let status), .exit(let status): return status
    }
  }
}
