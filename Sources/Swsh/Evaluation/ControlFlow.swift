#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The count is the number of enclosing loops still to leave or resume.
enum LoopControl: Error {
  case `break`(Int)
  case `continue`(Int)
}

/// Ctrl-C ended a loop in an interactive shell; the prompt returns with 130.
struct LoopInterrupt: Error, CustomStringConvertible {
  let description = "interrupted"
}

extension SessionDriver {
  /// A list whose status only selects a branch; `set -e` does not apply to it.
  private func test(_ condition: Program) throws -> SubmissionResult? {
    conditionDepth += 1
    defer { conditionDepth -= 1 }
    return try finished(submit(condition))
  }

  private func finished(_ result: SubmissionResult) -> SubmissionResult? {
    if case .completed = result { return nil }
    return result
  }

  func runConditional(
    _ branches: [Compound.Branch],
    otherwise: Program?
  ) throws -> SubmissionResult? {
    for branch in branches {
      if let result = try test(branch.condition) { return result }
      if state.status == 0 { return try finished(submit(branch.body)) }
    }
    if let otherwise { return try finished(submit(otherwise)) }
    state.status = 0
    return nil
  }

  func runLoop(
    until: Bool,
    condition: Program,
    body: Program
  ) throws -> SubmissionResult? {
    try iterate { status in
      if let result = try test(condition) { return result }
      guard (state.status == 0) != until else { return .completed(status) }
      return try finished(submit(body))
    }
  }

  func runForEach(
    _ name: String,
    words: [Word],
    body: Program
  ) throws -> SubmissionResult? {
    let expanded = try prepare(
      SimpleCommand(assignments: [], words: words, redirects: [])
    )
    var values = expanded.arguments.makeIterator()
    return try iterate { status in
      guard let value = values.next() else { return .completed(status) }
      state.assign([name: value])
      return try finished(submit(body))
    }
  }

  func runGroup(_ body: Program) throws -> SubmissionResult? {
    try finished(submit(body))
  }

  func runSelect(
    _ word: Word,
    clauses: [Compound.Clause]
  ) throws -> SubmissionResult? {
    let value = try Expander(state: state).scalar(resolve(word)).bytes
    for clause in clauses {
      for pattern in clause.patterns {
        // Only `*` and `?` written in the pattern match; values are literal.
        let expanded = try Expander(state: state).scalar(resolve(pattern))
        let matched = (expanded.pattern + [0])
          .withUnsafeBytes { pattern in
            (value + [0])
              .withUnsafeBytes { value in
                fnmatch(
                  pattern.baseAddress!.assumingMemoryBound(to: CChar.self),
                  value.baseAddress!.assumingMemoryBound(to: CChar.self),
                  0
                ) == 0
              }
          }
        guard matched else { continue }
        state.status = 0
        return try finished(submit(clause.body))
      }
    }
    state.status = 0
    return nil
  }

  /// `step` returns nil to continue, `.completed` to end the loop normally, or
  /// another result to leave the enclosing list. The loop reports its last body
  /// status, or 0 when the body never ran or ended with `break`/`continue`.
  private func iterate(
    _ step: (Int32) throws -> SubmissionResult?
  ) throws -> SubmissionResult? {
    // Only an interrupt that arrives while a loop runs may end it.
    if activeLoops == 0 { supervisor.clearInterrupt() }
    loopDepth += 1
    activeLoops += 1
    defer {
      loopDepth -= 1
      activeLoops -= 1
    }
    var status: Int32 = 0
    while true {
      do {
        let result = try step(status)
        // An interrupted condition, such as `read`, must not end the loop as
        // if it had merely failed.
        if let result, !supervisor.interruptRequested {
          guard case .completed(let last) = result else { return result }
          state.status = last
          return nil
        }
        status = state.status
      } catch LoopControl.break(let levels) {
        if levels > 1 { throw LoopControl.break(levels - 1) }
        state.status = 0
        return nil
      } catch LoopControl.continue(let levels) {
        if levels > 1 { throw LoopControl.continue(levels - 1) }
        status = 0
      }
      // A foreground child consumes Ctrl-C itself; the loop must still end.
      if supervisor.interruptRequested {
        guard supervisor.terminal != nil else { return .exit(128 + SIGINT) }
        throw LoopInterrupt()
      }
    }
  }
}

extension SessionDriver {
  static let trapSignals: [(String, Int32)] = [
    ("EXIT", 0), ("HUP", SIGHUP), ("INT", SIGINT), ("TERM", SIGTERM),
  ]

  /// `trap`, `trap source name...`, or `trap - name...`.
  func trap(_ arguments: [[UInt8]], io: BuiltinIO) throws {
    guard let action = arguments.first else {
      for (name, signal) in Self.trapSignals {
        guard let source = traps[signal] else { continue }
        let quoted = String(decoding: source, as: UTF8.self)
          .replacing("'", with: "'\\''")
        try writeBytes(
          Array("trap -- '\(quoted)' \(name)\n".utf8),
          to: io.output
        )
      }
      return
    }
    let signals = try arguments.dropFirst()
      .map { argument -> Int32 in
        var name = String(decoding: argument, as: UTF8.self)
        if name.hasPrefix("SIG") { name.removeFirst(3) }
        if name == "0" { return 0 }
        guard let signal = Self.trapSignals.first(where: { $0.0 == name })?.1
        else { throw usage("trap: expected EXIT, HUP, INT, or TERM") }
        return signal
      }
    guard !signals.isEmpty else {
      throw usage("trap: expected source or '-', then EXIT, HUP, INT, or TERM")
    }
    if action != [45] {
      // Reject source that could never run, before installing it.
      _ = try ShellMain.parse(action)
    }
    for signal in signals { traps[signal] = action == [45] ? nil : action }
    supervisor.trapped = Set(traps.keys)
  }

  /// Runs traps for signals received since the last command boundary.
  func runPendingTraps() throws -> SubmissionResult? {
    guard !runningTrap else { return nil }
    for signal in supervisor.takePendingSignals() {
      guard let source = traps[signal] else { continue }
      if let result = try runTrap(source) { return result }
    }
    return nil
  }

  /// A trap is not part of the interrupted function or loop, and `$?` is
  /// restored afterwards unless the trap exits the shell.
  private func runTrap(_ source: [UInt8]) throws -> SubmissionResult? {
    let saved = (state.status, functionDepth, loopDepth, conditionDepth)
    runningTrap = true
    functionDepth = 0
    loopDepth = 0
    conditionDepth = 0
    defer {
      runningTrap = false
      (functionDepth, loopDepth, conditionDepth) = (saved.1, saved.2, saved.3)
    }
    switch try submit(ShellMain.parse(source)) {
    case .completed:
      state.status = saved.0
      return nil
    case .exit(let status): return .exit(status)
    case .stopped(let job): return .stopped(job)
    }
  }

  /// Runs the EXIT trap once. It does not run when a signal ends the shell.
  func runExitTrap(_ status: Int32) -> Int32 {
    guard let source = traps.removeValue(forKey: 0),
      supervisor.shutdownRequested == nil
    else { return status }
    state.status = status
    do {
      if case .exit(let requested) = try runTrap(source) { return requested }
    } catch { ShellMain.diagnostic(error) }
    return status
  }
}

extension SessionDriver {
  static let maximumLineBytes = 1024 * 1024

  /// `read [-r] name...`: one line from standard input, without its newline.
  /// One name receives the line exactly; with several, fields are separated by
  /// spaces and tabs and the last name receives the rest. Status 1 means the
  /// input ended before a newline; what was read is still assigned.
  func read(_ arguments: [[UInt8]], io: BuiltinIO) throws -> SubmissionResult? {
    func report(_ message: String, status: Int32) -> SubmissionResult? {
      try? writeBytes(Array("swsh: read: \(message)\n".utf8), to: io.error)
      state.status = status
      return nil
    }
    var names = arguments[...]
    if names.first == Array("-r".utf8) { names.removeFirst() }
    func isName(_ bytes: [UInt8]) -> Bool {
      func initial(_ byte: UInt8) -> Bool {
        byte == 95 || (65 ... 90).contains(byte) || (97 ... 122).contains(byte)
      }
      guard let first = bytes.first, initial(first) else { return false }
      return bytes.allSatisfy { initial($0) || (48 ... 57).contains($0) }
    }
    guard !names.isEmpty, names.allSatisfy(isName) else {
      return report("expected one or more variable names", status: 2)
    }
    guard io.input >= 0 else {
      return report("standard input is closed", status: 1)
    }
    if activeLoops == 0 { supervisor.clearInterrupt() }
    var line: [UInt8] = []
    var ended = false
    var containsNUL = false
    var idle = true
    while true {
      // One byte per read leaves the rest of the input for later commands.
      if idle || line.count % 1024 == 0 {
        try supervisor.poll(milliseconds: 0)
        if let requested = supervisor.shutdownRequested {
          return .exit(requested)
        }
        if supervisor.interruptRequested {
          state.status = 128 + SIGINT
          return nil
        }
      }
      var input = pollfd(fd: io.input, events: Int16(POLLIN), revents: 0)
      let ready = systemPoll(&input, 1, 50)
      if ready < 0 && errno == EINTR { continue }
      guard ready >= 0 else {
        return report("wait for input failed (errno \(errno))", status: 1)
      }
      idle = ready == 0
      if idle { continue }
      var byte: UInt8 = 0
      let count = systemRead(io.input, &byte, 1)
      if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
      guard count >= 0 else {
        return report("input failed (errno \(errno))", status: 1)
      }
      if count == 0 {
        ended = true
        break
      }
      if byte == 10 { break }
      if byte == 0 { containsNUL = true }
      guard line.count < Self.maximumLineBytes else {
        return report("line exceeds 1 MiB", status: 2)
      }
      line.append(byte)
    }
    guard !containsNUL else { return report("NUL in input line", status: 2) }
    var values: [String: [UInt8]] = [:]
    var rest = line[...]
    func blank(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 }
    for (index, name) in names.enumerated() {
      let key = String(decoding: name, as: UTF8.self)
      if names.count == 1 {
        values[key] = line
      } else if index == names.count - 1 {
        rest = rest.drop(while: blank)
        while let last = rest.last, blank(last) { rest.removeLast() }
        values[key] = Array(rest)
      } else {
        rest = rest.drop(while: blank)
        let field = rest.prefix { !blank($0) }
        values[key] = Array(field)
        rest = rest.dropFirst(field.count)
      }
    }
    state.assign(values)
    state.status = ended ? 1 : 0
    return nil
  }
}
