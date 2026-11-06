import CSwshSupport
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Used in the shell's serial ownership domain, never concurrently or on a cooperative executor.
/// This is the sole owner of child status and signaling for the process lifetime.
final class JobSupervisor {
  var inheritedWiring: [DarwinSpawn.Wiring] = []
  private let events: ChildEvents
  let terminal: TerminalControl?
  var propagateChildStops = false
  private var foreground: JobID?
  private(set) var editInterrupted = false
  /// Signals with a `trap`; they queue for the driver and never shut down.
  var trapped: Set<Int32> = []
  private var pendingSignals: [Int32] = []
  /// SIGINT arrived outside line editing and without a trap.
  private(set) var interruptRequested = false
  private var workerLeases = UniqueArray<WorkerLease?>()
  private var jobs: [JobID: JobRecord] = [:]
  private var nextID: UInt64 = 1
  private var cleanupFailed = false
  private(set) var shutdownRequested: Int32?
  let executable: [UInt8]
  let build: String
  private let cleanupNow: () -> ContinuousClock.Instant

  enum LaunchCheckpoint {
    case beforeSpawn(Int)
    case registered(Int, pid_t)
    case beforeRelease
  }
  // Internal deterministic fault seam; never configured by shell input or environment.
  private let launchCheckpoint: ((LaunchCheckpoint) throws -> Void)?

  init(
    executable: [UInt8],
    build: String,
    terminal: TerminalControl? = nil,
    launchCheckpoint: ((LaunchCheckpoint) throws -> Void)? = nil,
    cleanupNow: @escaping () -> ContinuousClock.Instant = { .now }
  ) throws {
    self.executable = executable
    self.build = build
    self.terminal = terminal
    self.cleanupNow = cleanupNow
    self.launchCheckpoint = launchCheckpoint
    events = try ChildEvents(inputDescriptor: terminal?.inputDescriptor)
  }

  func launch(
    _ commands: [PreparedCommand],
    state: ShellState,
    background: Bool = false,
    redirectReply: Int32? = nil,
    output: Int32? = nil
  ) throws -> JobID {
    let jobControl = terminal != nil && redirectReply == nil
    let id = JobID(value: nextID)
    nextID += 1
    jobs[id] = JobRecord(
      id: id,
      stages: commands.map { _ in .finished(.exited(127)) },
      setupSuspended: jobControl,
      background: background
    )
    jobs[id]!.pipefail = state.options.pipefail
    do {
      var owners = UniqueArray<OwnedFD?>()
      var pipes: [(read: Int32, write: Int32)] = []
      for _ in 1 ..< commands.count {
        let pipe = try OwnedFD.pipe()
        // Reserve standard descriptor slots even when the shell started with one closed.
        let read = try pipe.input.withDescriptor { try OwnedFD.duplicate($0) }
        let write = try pipe.output.withDescriptor { try OwnedFD.duplicate($0) }
        pipes.append((read.withDescriptor { $0 }, write.withDescriptor { $0 }))
        owners.append(.some(consume read))
        owners.append(.some(consume write))
      }
      for (index, command) in commands.enumerated() {
        defer {
          if index > 0 { owners[2 * (index - 1)] = nil }
          if index < pipes.count { owners[2 * index + 1] = nil }
        }
        try poll(milliseconds: 0)
        if shutdownRequested != nil {
          throw SystemFailure("launch interrupted by shutdown", code: EINTR)
        }
        guard let name = command.arguments.first else {
          throw SystemFailure("pipeline stage has no executable", code: EINVAL)
        }
        let path: [UInt8]
        var lookupFailure: Int32?
        if command.builtin != nil || command.source != nil {
          path = executable
        } else {
          switch ExecutableLookup()
            .resolve(name, state: state, overlay: command.assignments)
          {
          case .executable(let resolved): path = resolved
          case .failure(let status):
            if !command.redirects.isEmpty {
              path = executable
              lookupFailure = status
              break
            }
            jobs[id]!.stages[index] = .finished(.exited(status))
            try? writeBytes(
              Array("swsh: command lookup failed: ".utf8) + name + [10],
              to: STDERR_FILENO
            )
            continue
          }
        }
        var wiring = inheritedWiring
        if let output {
          wiring.append(.duplicate(source: output, destination: STDOUT_FILENO))
        }
        if index > 0 {
          wiring.append(
            .duplicate(source: pipes[index - 1].read, destination: STDIN_FILENO)
          )
        }
        if index < pipes.count {
          wiring.append(
            .duplicate(source: pipes[index].write, destination: STDOUT_FILENO)
          )
        }
        let environment =
          command.builtin == nil
          ? try state.environment(overlay: command.assignments) : []
        let group: DarwinSpawn.Group
        if jobControl {
          group =
            jobs[id]!.group.map { .suspendedMember($0) } ?? .suspendedLeader
        } else {
          group = .inherited
        }
        let pid: pid_t
        do {
          try launchCheckpoint?(.beforeSpawn(index))
          if command.redirects.isEmpty && command.builtin == nil
            && command.source == nil
          {
            pid = try DarwinSpawn()
              .launch(
                path: path,
                arguments: command.arguments,
                environment: environment,
                group: group,
                wiring: wiring
              )
          } else {
            func launchPrivate(lease: Int32? = nil) throws -> pid_t {
              return try PrivateLauncher()
                .launch(
                  command: command,
                  executable: executable,
                  target: path,
                  build: build,
                  environment: environment,
                  state: state,
                  group: group,
                  wiring: wiring,
                  pipeDescriptors: pipes.flatMap { [$0.read, $0.write] },
                  replySocket: redirectReply,
                  lookupFailure: lookupFailure,
                  supervisorPipe: lease
                )
            }
            if command.source != nil {
              let pipe = try OwnedFD.pipe()
              pid = try pipe.withEnds { input, output in
                guard
                  input.withDescriptor({ fcntl($0, F_SETFL, O_NONBLOCK) }) == 0
                else { throw SystemFailure("worker lease nonblocking") }
                let child = try launchPrivate(
                  lease: output.withDescriptor { $0 }
                )
                let lease = WorkerLease(pid: child, input: consume input)
                if let slot = (0 ..< workerLeases.count)
                  .first(where: { workerLeases[$0] == nil })
                {
                  workerLeases[slot] = consume lease
                } else {
                  workerLeases.append(.some(consume lease))
                }
                return child
              }
            } else {
              pid = try launchPrivate()
            }
          }
          // No suspension or event processing between spawn and registration.
          jobs[id]!.stages[index] = .running(pid)
          if jobControl && jobs[id]!.group == nil { jobs[id]!.group = pid }
        } catch let error as SystemFailure
          where error.operation == "posix_spawn"
          && [ENOENT, ENOTDIR, EACCES, ENOEXEC, EISDIR].contains(error.code)
        {
          jobs[id]!.stages[index] = .finished(
            .exited(error.code == ENOENT || error.code == ENOTDIR ? 127 : 126)
          )
          try? writeBytes(Array("swsh: \(error)\n".utf8), to: STDERR_FILENO)
        }
        if let pid = jobs[id]!.stages[index].pid {
          try launchCheckpoint?(.registered(index, pid))
        }
      }
      try launchCheckpoint?(.beforeRelease)
      try poll(milliseconds: 0)
      guard shutdownRequested == nil else {
        throw SystemFailure("launch interrupted by shutdown", code: EINTR)
      }
      if let group = jobs[id]!.group {
        if !background {
          try terminal!.give(to: group)
          foreground = id
        }
        markContinuing(id)
        guard kill(-group, SIGCONT) == 0 else {
          throw SystemFailure("release job group")
        }
      }
      jobs[id]!.setupSuspended = false
      jobs[id]!.assembling = false
      return id
      // owners close all parent pipe endpoints before the caller can wait.
    } catch {
      jobs[id]!.assembling = false
      let cleaned = cleanup(ids: [id])
      if !cleaned {
        cleanupFailed = true
        shutdownRequested = 1
      }
      throw error
    }
  }

  enum RedirectResult: ~Copyable {
    case ready(OwnedStandardIO)
    case failed(Int32)
    case shutdown(Int32)
  }

  func prepareRedirects(_ actions: [DescriptorAction]) throws -> RedirectResult
  {
    let channel = try OwnedFD.descriptorChannel()
    return try channel.withEnds {
      (input: consuming OwnedFD, output: consuming OwnedFD) in
      let command = PreparedCommand(
        assignments: [:],
        arguments: [Array(":".utf8)],
        redirects: actions
      )
      let id = try launch(
        [command],
        state: ShellState(),
        redirectReply: output.withDescriptor { $0 }
      )
      try output.close()
      switch try wait(for: id) {
      case .completed(let result):
        guard result.status == 0 else { return .failed(result.status) }
        return .ready(
          try input.withDescriptor { try OwnedFD.receiveStandardIO(from: $0) }
        )
      case .running: return .shutdown(shutdownRequested ?? 1)
      case .stopped:
        // Parent builtin setup inherits the shell's terminal-stop policy and is
        // not a user job. An external SIGSTOP cancels setup without applying state.
        if !cleanup(ids: [id]) {
          cleanupFailed = true;
          shutdownRequested = 1
        }
        return .failed(128 + SIGTSTP)
      }
    }
  }

  func wait(for id: JobID) throws -> JobRecord.Disposition {
    while true {
      try poll(milliseconds: 0)
      guard let job = jobs[id] else {
        throw SystemFailure("unknown job", code: EINVAL)
      }
      switch job.disposition {
      case .completed:
        if foreground == id {
          _ = try terminal?.reclaim(stopped: false)
          foreground = nil
        }
        // A foreground job owns the terminal, so Ctrl-C reaches it and not the
        // shell. Its death by SIGINT is the interrupt an enclosing loop sees.
        if !trapped.contains(SIGINT),
          job.stages.contains(.finished(.signaled(SIGINT)))
        {
          interruptRequested = true
        }
        jobs.removeValue(forKey: id)
        return job.disposition
      case .stopped:
        if propagateChildStops && shutdownRequested == nil {
          // A compound stage must remain a stopped job rather than exiting when
          // a child stops itself. The outer supervisor owns terminal handoff.
          guard kill(getpid(), SIGSTOP) == 0 else {
            throw SystemFailure("stop compound worker")
          }
          // The outer supervisor resumes the entire inherited process group.
          // A second SIGCONT here could consume a child's subsequent self-stop.
          markContinuing(id)
          continue
        }
        if foreground == id {
          jobs[id]!.savedModes = try terminal?.reclaim(stopped: true)
          foreground = nil
        }
        return .stopped
      case .running: break
      }
      if shutdownRequested != nil { return .running }
      try poll(milliseconds: 1000)
    }
  }

  @discardableResult
  func poll(milliseconds: Int, watchInput: Bool = false) throws -> Bool {
    let ready = try events.wait(
      milliseconds: milliseconds,
      watchInput: watchInput
    )
    for signal in ready.signals {
      if trapped.contains(signal) {
        if !pendingSignals.contains(signal) { pendingSignals.append(signal) }
        // A trapped signal at the prompt cancels the edit so its trap can run.
        if watchInput { editInterrupted = true }
        continue
      }
      if signal == SIGINT && !watchInput { interruptRequested = true }
      if signal == SIGHUP || signal == SIGTERM
        || (propagateChildStops && signal == SIGINT)
      {
        shutdownRequested = 128 + signal
      }
      if signal == SIGINT && watchInput { editInterrupted = true }
    }
    try drain()
    return ready.input
  }

  func clearEditInterrupt() { editInterrupted = false }

  func clearInterrupt() { interruptRequested = false }

  func takePendingSignals() -> [Int32] {
    defer { pendingSignals = [] }
    return pendingSignals
  }

  var hasLiveJobs: Bool {
    jobs.values.contains { $0.stages.contains { $0.pid != nil } }
  }

  func listing() -> [(JobID, JobRecord.Disposition)] {
    jobs.values.sorted { $0.id.value < $1.id.value }
      .map { ($0.id, $0.disposition) }
  }

  func discardCompleted() {
    for (id, disposition) in listing() {
      if case .completed = disposition, foreground != id {
        jobs.removeValue(forKey: id)
      }
    }
  }

  func selectJob(_ argument: [UInt8]?) throws -> JobID {
    try poll(milliseconds: 0)
    if let argument {
      let bytes = argument.first == 37 ? Array(argument.dropFirst()) : argument
      guard let number = UInt64(String(decoding: bytes, as: UTF8.self)) else {
        throw SystemFailure("invalid job ID", code: EINVAL)
      }
      let id = JobID(value: number)
      guard let job = jobs[id], job.stages.contains(where: { $0.pid != nil })
      else { throw SystemFailure("job is not live", code: ESRCH) }
      return id
    }
    guard
      let id = jobs.values.filter({ $0.stages.contains { $0.pid != nil } })
        .map(\.id).max(by: { $0.value < $1.value })
    else { throw SystemFailure("no current job", code: ESRCH) }
    return id
  }

  func resume(_ id: JobID, foreground requestedForeground: Bool) throws {
    guard let job = jobs[id], let group = job.group, let terminal else {
      throw SystemFailure("job control is unavailable", code: EINVAL)
    }
    if requestedForeground {
      try terminal.give(to: group, modes: job.savedModes)
      foreground = id
    }
    jobs[id]!.background = !requestedForeground
    markContinuing(id)
    guard kill(-group, SIGCONT) == 0 else {
      throw SystemFailure("continue job", code: errno)
    }
  }

  private func markContinuing(_ id: JobID) {
    for index in jobs[id]!.stages.indices {
      if let pid = jobs[id]!.stages[index].pid {
        jobs[id]!.stages[index] = .awaitingContinuation(pid)
      }
    }
  }

  func shutdown() -> Bool {
    // A missed abort deadline is terminal. Do not reset its clock and claim recovery.
    guard !cleanupFailed else { return false }
    let cleaned = cleanup(ids: Set(jobs.keys))
    if !cleaned { cleanupFailed = true }
    return cleaned
  }

  private func drain() throws {
    for id in Array(jobs.keys) {
      for index in jobs[id]!.stages.indices {
        guard let pid = jobs[id]!.stages[index].pid else { continue }
        while true {
          var status: Int32 = 0
          let result = waitpid(pid, &status, WNOHANG | WUNTRACED | WCONTINUED)
          if result == 0 { break }
          if result < 0 {
            if errno == EINTR { continue }
            throw SystemFailure("waitpid owned child")
          }
          switch swsh_wait_kind(status) {
          case 1:
            jobs[id]!.stages[index] = .finished(
              .exited(swsh_wait_value(status))
            )
          case 2:
            jobs[id]!.stages[index] = .finished(
              .signaled(swsh_wait_value(status))
            )
          case 3:
            if !jobs[id]!.setupSuspended {
              jobs[id]!.stages[index] = .stopped(pid, swsh_wait_value(status))
            }
          case 4: jobs[id]!.stages[index] = .running(pid)
          default: throw SystemFailure("unknown wait status", code: EINVAL)
          }
          if jobs[id]!.stages[index].pid == nil {
            for slot in 0 ..< workerLeases.count
            where workerLeases[slot]?.pid == pid { workerLeases[slot] = nil }
            break
          }
        }
      }
    }
  }

  private func signal(_ ids: Set<JobID>, _ signal: Int32) {
    for id in ids {
      guard let job = jobs[id] else { continue }
      let pids = job.stages.compactMap(\.pid)
      guard !pids.isEmpty else { continue }
      if job.setupSuspended {
        for pid in pids { _ = kill(pid, SIGKILL) }
      } else if signal == SIGKILL && pids.contains(where: protectsSupervisor) {
        // Reapers must survive escalation long enough to reap their own children.
        // Each nested supervisor applies the same deadline to its external leaves.
        for pid in pids where !protectsSupervisor(pid) { _ = kill(pid, signal) }
      } else if let group = job.group {
        _ = kill(-group, signal)
      } else {
        for pid in pids { _ = kill(pid, signal) }
      }
    }
  }

  private func protectsSupervisor(_ pid: pid_t) -> Bool {
    for slot in 0 ..< workerLeases.count where workerLeases[slot]?.pid == pid {
      return workerLeases[slot]?.isSupervising() ?? false
    }
    return false
  }

  /// Called in the session's shielded defer, on its serial executor. Sleeping
  /// yields that executor; the supervisor remains the sole owner of child status.
  func shutdownAwaitingCleanup() async -> Bool {
    guard !cleanupFailed else { return false }
    var operation = beginCleanup(ids: Set(jobs.keys))
    while true {
      if let result = advanceCleanup(&operation) {
        if !result { cleanupFailed = true }
        return result
      }
      do { try await Task.sleep(for: .milliseconds(50)) } catch {
        cleanupFailed = true
        return false
      }
    }
  }

  private struct CleanupOperation {
    let ids: Set<JobID>
    let start: ContinuousClock.Instant
    var escalated = false
  }

  private func beginCleanup(ids: Set<JobID>) -> CleanupOperation {
    let operation = CleanupOperation(ids: ids, start: cleanupNow())
    signal(ids, SIGHUP)
    signal(ids, SIGTERM)
    signal(ids, SIGCONT)
    return operation
  }

  /// nil means work remains. Both synchronous launch-abort and awaited session
  /// shutdown use this state machine and the same original monotonic deadline.
  private func advanceCleanup(_ operation: inout CleanupOperation) -> Bool? {
    do { try poll(milliseconds: 0) } catch { return false }
    let live = operation.ids.contains {
      jobs[$0]?.stages.contains { $0.pid != nil } == true
    }
    if !live {
      for id in operation.ids { jobs.removeValue(forKey: id) }
      return true
    }
    let elapsed = operation.start.duration(to: cleanupNow())
    if elapsed >= .seconds(5) { return false }
    if elapsed >= .seconds(2) && !operation.escalated {
      signal(operation.ids, SIGKILL)
      operation.escalated = true
    }
    return nil
  }

  private func cleanup(ids: Set<JobID>) -> Bool {
    var operation = beginCleanup(ids: ids)
    while true {
      if let result = advanceCleanup(&operation) { return result }
      do { try poll(milliseconds: 50) } catch { return false }
    }
  }
}

extension JobSupervisor {
  /// Drain concurrently with child progress. A bounded byte buffer prevents an
  /// expansion producer from exhausting the shell's memory or blocking a pipe.
  func capture(
    source: [UInt8],
    state: ShellState,
    timeout: Duration? = nil,
    functionArguments: [[UInt8]]? = nil
  ) throws -> [UInt8] {
    let pipe = try OwnedFD.pipe()
    return try pipe.withEnds { input, output in
      let fd = input.withDescriptor { $0 }
      guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
        throw SystemFailure("capture nonblocking")
      }
      let redirects: [DescriptorAction] =
        timeout == nil
        ? []
        : [
          .open(descriptor: 0, path: Array("/dev/null".utf8), mode: .read),
          .open(descriptor: 2, path: Array("/dev/null".utf8), mode: .write),
        ]
      let command = PreparedCommand(
        assignments: [:],
        arguments: [Array("(substitution)".utf8)],
        redirects: redirects,
        source: source,
        functionArguments: functionArguments
      )
      let id = try launch(
        [command],
        state: state,
        background: timeout != nil,
        output: output.withDescriptor { $0 }
      )
      try output.close()
      var finished = false
      defer {
        if !finished && !cleanup(ids: [id]) {
          cleanupFailed = true;
          shutdownRequested = 1
        }
        if foreground == id {
          do { _ = try terminal?.reclaim(stopped: false) } catch {
            shutdownRequested = 1
          }
          foreground = nil
        }
      }
      let deadline = timeout.map { ContinuousClock.now.advanced(by: $0) }
      var result: [UInt8] = []
      var buffer = [UInt8](repeating: 0, count: 16 * 1024)
      var eof = false
      while true {
        if let deadline, ContinuousClock.now >= deadline {
          throw SystemFailure("completion timeout", code: ETIMEDOUT)
        }
        try poll(milliseconds: 0)
        if shutdownRequested != nil {
          throw SystemFailure("capture interrupted", code: EINTR)
        }
        let count = systemRead(fd, &buffer, buffer.count)
        if count > 0 {
          guard result.count + count <= 1024 * 1024 else {
            throw ShellDiagnostic(
              offset: 0,
              message: "command substitution exceeds 1 MiB"
            )
          }
          result.append(contentsOf: buffer.prefix(count))
        } else if count == 0 {
          eof = true
        } else if errno != EAGAIN && errno != EINTR {
          throw SystemFailure("read substitution")
        }
        if let job = jobs[id] {
          switch job.disposition {
          case .stopped:
            throw ShellDiagnostic(
              offset: 0,
              message: "stopped command substitution aborted"
            )
          case .completed(let status):
            if eof {
              _ = try wait(for: id)
              finished = true
              guard status.status == 0 else {
                throw ShellDiagnostic(
                  offset: 0,
                  message:
                    "command substitution failed with status \(status.status)"
                )
              }
              return result
            }
          case .running: break
          }
        }
        if count <= 0 { try poll(milliseconds: 10) }
      }
    }
  }
}
