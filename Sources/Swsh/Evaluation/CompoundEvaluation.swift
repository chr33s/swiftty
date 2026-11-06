#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

struct FunctionReturn: Error { let status: Int32 }

/// A name's state from before `local` took it over.
struct SavedVariable {
  let value: [UInt8]?
  let list: [[UInt8]]?
  let exported: Bool
}

extension ShellState {
  mutating func setArguments(_ arguments: [[UInt8]]) {
    for i in 1 ... 9 {
      // Parameters past the last argument are unset, not empty.
      variables[String(i)] = i <= arguments.count ? arguments[i - 1] : nil
    }
    variables["#"] = Array(String(arguments.count).utf8)
    // `$@`. The name cannot be written in source, so it cannot be assigned.
    arrays["@"] = arguments
  }
}

extension SessionDriver {
  func callFunctionCommand(
    _ command: PreparedCommand,
    body: [UInt8]
  ) throws -> SubmissionResult? {
    try withParentRedirects(command.redirects) {
      try callFunction(body, arguments: Array(command.arguments.dropFirst()))
    }
  }

  /// Runs `body` in the current shell with scoped standard I/O. Descriptors
  /// arrive by supervised handoff; the shell's own descriptors never change.
  func withParentRedirects(
    _ redirects: [DescriptorAction],
    _ body: () throws -> SubmissionResult?
  ) throws -> SubmissionResult? {
    if redirects.isEmpty { return try body() }
    guard
      redirects.allSatisfy({ action in
        switch action {
        case .open(let fd, _, _), .duplicate(let fd, _), .close(let fd),
          .data(let fd, _):
          return fd <= 2
        }
      })
    else {
      throw ShellDiagnostic(
        offset: 0,
        message: "parent redirects support descriptors 0, 1, and 2"
      )
    }
    switch try supervisor.prepareRedirects(redirects) {
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
      return try body()
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
    let savedList = state.arrays["@"]
    let outerLoops = loopDepth
    functionDepth += 1
    // `break` and `continue` never cross a function boundary.
    loopDepth = 0
    localScopes.append([:])
    state.setArguments(arguments)
    defer {
      for (name, saved) in localScopes.removeLast() {
        state.variables[name] = saved.value
        state.arrays[name] = saved.list
        if saved.exported {
          state.exported.insert(name)
        } else {
          state.exported.remove(name)
        }
      }
      functionDepth -= 1
      loopDepth = outerLoops
      for (name, value) in zip(names, saved) { state.variables[name] = value }
      state.arrays["@"] = savedList
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

  /// `local name[=value]...`: the function's caller gets each name back as it
  /// was. A name without a value starts unset.
  func local(_ arguments: [[UInt8]]) throws {
    guard !localScopes.isEmpty else { throw usage("local requires a function") }
    func initial(_ byte: UInt8) -> Bool {
      byte == 95 || (65 ... 90).contains(byte) || (97 ... 122).contains(byte)
    }
    // Validate the entire request before changing any variable.
    let entries = try arguments.map { argument -> (String, [UInt8]?) in
      let split = argument.firstIndex(of: 61) ?? argument.endIndex
      let name = argument[..<split]
      guard let first = name.first, initial(first),
        name.allSatisfy({ initial($0) || (48 ... 57).contains($0) })
      else { throw usage("local: expected name[=value]...") }
      return (
        String(decoding: name, as: UTF8.self),
        split == argument.endIndex ? nil : Array(argument[(split + 1)...])
      )
    }
    guard !entries.isEmpty else {
      throw usage("local: expected name[=value]...")
    }
    for (name, value) in entries {
      if localScopes[localScopes.count - 1][name] == nil {
        localScopes[localScopes.count - 1][name] = SavedVariable(
          value: state.variables[name],
          list: state.arrays[name],
          exported: state.exported.contains(name)
        )
      }
      if let value {
        state.assign([name: value])
      } else {
        state.variables.removeValue(forKey: name)
        state.arrays.removeValue(forKey: name)
        state.exported.remove(name)
      }
    }
  }

  /// Arithmetic in the current shell, where an expression may assign.
  func integer(_ source: [UInt8], in word: Word) throws -> Int64 {
    try Expander.integer(
      source,
      in: word,
      current: { Expander(state: self.state) },
      store: { name, index, value in
        let bytes = Array(String(value).utf8)
        if let index {
          try self.state.apply([.element(name, index, bytes)])
        } else {
          guard self.state.arrays[name] == nil else {
            throw self.usage("\(name) is a list; assign \(name)[index]")
          }
          self.state.assign([name: bytes])
        }
      }
    )
  }

  /// Whether expanding these parts can assign a variable.
  static func mutates(_ parts: [Word.Part]) -> Bool {
    parts.contains { part in
      switch part {
      case .arithmetic(let source), .element(_, let source):
        return (try? Arithmetic.parse(source))?.mutates ?? false
      case .parameter(_, let operation, _, let operand):
        return operation == .assign || mutates(operand)
      default: return false
      }
    }
  }

  /// Runs the effects of a word once, in source order: command substitutions,
  /// arithmetic, and `${name=word}` assignments. Operands that are not selected
  /// do not run. With `snapshot`, every value is read here as well, so a read
  /// written before an assignment sees the earlier value.
  func resolve(_ word: Word, snapshot: Bool? = nil) throws -> Word {
    // A list is a whole word, so such a word has no other value to read.
    let snapshot =
      (snapshot ?? Self.mutates(word.parts))
      && !word.parts.contains { if case .list = $0 { true } else { false } }
    func read(_ part: Word.Part) throws -> Word.Part {
      guard snapshot else { return part }
      return .literal(
        try Expander(state: state)
          .scalar(Word(range: word.range, parts: [part])).bytes
      )
    }
    func number(_ source: [UInt8]) throws -> [UInt8] {
      Array(String(try integer(source, in: word)).utf8)
    }
    func resolve(_ parts: [Word.Part]) throws -> [Word.Part] {
      try parts.map { part in
        switch part {
        case .substitution(let source):
          var bytes = try supervisor.capture(source: source, state: state)
          while bytes.last == 10 { bytes.removeLast() }
          return .literal(bytes)
        case .arithmetic(let source): return .literal(try number(source))
        case .element(let name, let source):
          return try read(.element(name, try number(source)))
        case .parameter(let name, let operation, let colon, let operand):
          let expander = Expander(state: state)
          let kept = try expander.usable(name, colon: colon, in: word) != nil
          guard kept == (operation == .alternate) else {
            return try read(.parameter(name, operation, colon: colon, []))
          }
          let selected = try resolve(operand)
          guard operation == .assign else {
            return try read(.parameter(name, operation, colon: colon, selected))
          }
          state.assign([
            name: try Expander(state: state)
              .scalar(Word(range: word.range, parts: selected)).bytes
          ])
          return try read(.variable(name))
        case .variable, .count, .length, .status, .processID:
          return try read(part)
        case .literal, .wildcard, .bracket, .list: return part
        }
      }
    }
    return Word(range: word.range, parts: try resolve(word.parts))
  }

  func prepare(_ command: SimpleCommand) throws -> PreparedCommand {
    let words =
      command.assignments.flatMap { [$0.value] + ($0.elements ?? []) }
      + command.words + command.redirects.map(\.target)
    let snapshot =
      words.contains { Self.mutates($0.parts) }
      || command.assignments.contains {
        $0.index.map { Self.mutates([.arithmetic($0)]) } ?? false
      }
    let expand = { (word: Word) in try self.resolve(word, snapshot: snapshot) }
    if case .function = command.compound {
      throw ShellDiagnostic(
        offset: 0,
        message: "function definitions require a standalone command"
      )
    }
    let before = state
    do {
      let expanded = SimpleCommand(
        assignments: try command.assignments.map { assignment in
          let index = try assignment.index.map {
            Array(String(try integer($0, in: assignment.value)).utf8)
          }
          let value = try expand(assignment.value)
          let elements = try assignment.elements?.map(expand)
          return Assignment(
            name: assignment.name,
            value: value,
            elements: elements,
            index: index,
            append: assignment.append
          )
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
      if let source = command.compound?.workerSource {
        guard prepared.updates.isEmpty else {
          throw ShellDiagnostic(
            offset: 0,
            message: "assignments cannot prefix a compound command"
          )
        }
        prepared = PreparedCommand(
          assignments: prepared.assignments,
          arguments: [Array("(compound)".utf8)],
          redirects: prepared.redirects,
          source: source
        )
      }
      return prepared
    } catch {
      if command.words.isEmpty, command.compound == nil { state = before }
      throw error
    }
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
