import CSwshSupport
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// One executable owns one session. Private workers bypass session initialization.
public enum ShellMain {
  #if !canImport(Darwin)
  /// Runs the shell and exits with its status. corelibs Dispatch parks an
  /// async `main` in a thread that unblocks every signal, which would discard
  /// an inherited signal mask. Here the main thread keeps its mask and only
  /// waits, while the session runs on its own executor.
  public static func runAndExit(arguments: [[UInt8]]) -> Never {
    Task.detached { exit(await run(arguments: arguments)) }
    while true { pause() }
  }
  #endif

  public static func run(arguments: [[UInt8]]) async -> Int32 {
    do {
      guard let path = swsh_executable_path() else {
        throw SystemFailure("locate shell executable")
      }
      let executable = Array(
        UnsafeRawBufferPointer(start: path, count: strlen(path))
      )
      free(path)
      let build = try LauncherPayload.buildIdentity(executable: executable)
      let options = Array(arguments.dropFirst())
      // Private entry selection precedes any session, startup, history or terminal setup.
      if options.first == Array("--swsh-external".utf8)
        || options.first == Array("--swsh-builtin".utf8)
        || options.first == Array("--swsh-descriptors".utf8)
        || options.first == Array("--swsh-source".utf8)
      {
        guard options.count == 2,
          let fd = Int32(String(decoding: options[1], as: UTF8.self)), fd >= 3
        else {
          throw ShellDiagnostic(
            offset: 0,
            message: "invalid private launcher invocation"
          )
        }
        return PrivateLauncher()
          .run(
            payloadDescriptor: fd,
            build: build,
            kind: options.first == Array("--swsh-source".utf8)
              ? .source
              : options.first == Array("--swsh-builtin".utf8)
                ? .builtin
                : (options.first == Array("--swsh-descriptors".utf8)
                  ? .descriptors : .external)
          )
      }
      if options == [Array("--version".utf8)] {
        try writeBytes(
          Array("swsh language 1 (development)\n".utf8),
          to: STDOUT_FILENO
        )
        return 0
      }
      return await ShellSession()
        .run(options: options, executable: executable, build: build)
    } catch {
      diagnostic(error)
      return error is ShellDiagnostic ? 2 : 1
    }
  }

  static func interact(
    driver: SessionDriver,
    terminal: TerminalControl
  ) throws -> Int32 {
    if let home = driver.state.variables["HOME"] {
      do {
        let file = try OwnedFD.open(
          home + Array("/.swshrc".utf8),
          flags: O_RDONLY
        )
        let source = try file.withDescriptor {
          try readSource($0, supervisor: driver.supervisor)
        }
        if case .exit(let status) = try driver.submit(parse(source)) {
          return status
        }
      } catch let error as SystemFailure where error.code == ENOENT {} catch {
        diagnostic(error);
        driver.state.status = error is ShellDiagnostic ? 2 : 1
      }
    }
    let history = HistoryStore(home: driver.state.variables["HOME"])
    let presentation = TerminalPresentation(
      terminal: terminal,
      enabled: driver.state.variables["SWSH_TERMINAL_METADATA"] != [48]
    )
    var source: [UInt8] = []
    while terminal.healthy {
      try driver.supervisor.poll(milliseconds: 0)
      if let status = driver.supervisor.shutdownRequested { return status }
      driver.supervisor.discardCompleted()
      if case .exit(let status) = try driver.runPendingTraps() { return status }
      if source.isEmpty { try presentation.prompt() }
      let editor = LineEditor(
        terminal: terminal,
        supervisor: driver.supervisor,
        history: history,
        state: driver.state,
        metadata: presentation.enabled,
        completion: { try driver.complete($0) }
      )
      switch try editor.read(prompt: source.isEmpty ? "swsh> " : "...> ") {
      case .cancelled:
        source = [];
        driver.state.status = 130;
        continue
      case .eof:
        if driver.supervisor.shutdownRequested == nil && !source.isEmpty {
          diagnostic(
            ShellDiagnostic(
              offset: source.count,
              message: "incomplete source at EOF"
            )
          )
          source = []
          driver.state.status = 2
          continue
        }
        return driver.supervisor.shutdownRequested ?? driver.state.status
      case .line(let line): source.append(contentsOf: line)
      }
      let program: Program
      switch Parser().parse(source) {
      case .incomplete:
        source.append(10);
        continue
      case .invalid(let error):
        diagnostic(error);
        driver.state.status = 2;
        source = [];
        continue
      case .complete(let parsed): program = parsed
      }
      history.append(source)
      source = []
      try terminal.commandMode()
      try presentation.command()
      var completed = true
      do {
        switch try driver.submit(program) {
        case .exit(let status): return status
        case .completed: break
        case .stopped: completed = false
        }
      } catch is LoopInterrupt { driver.state.status = 128 + SIGINT } catch {
        diagnostic(error)
        driver.state.status = error is ShellDiagnostic ? 2 : 1
      }
      if !terminal.healthy { return 1 }
      if completed { try presentation.finished(driver.state.status) }
    }
    return 1
  }

  static func parse(_ source: [UInt8]) throws -> Program {
    switch Parser().parse(source) {
    case .complete(let program): return program
    case .invalid(let error), .incomplete(let error): throw error
    }
  }

  static func readSource(
    _ descriptor: Int32,
    supervisor: JobSupervisor
  ) throws -> [UInt8] {
    var result: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
      try supervisor.poll(milliseconds: 0)
      if supervisor.shutdownRequested != nil {
        throw SystemFailure("source input interrupted", code: EINTR)
      }
      // Signal handlers may run on another thread, so EINTR cannot make an
      // indefinite read responsive. This driver is the sole source reader;
      // wait for readiness in bounded intervals before entering read.
      var input = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      let ready = systemPoll(&input, 1, 50)
      if ready < 0 && errno == EINTR { continue }
      guard ready >= 0 else { throw SystemFailure("wait for source input") }
      if ready == 0 { continue }
      let count = systemRead(descriptor, &buffer, buffer.count)
      if count < 0 && errno == EINTR { continue }
      guard count >= 0 else { throw SystemFailure("read source") }
      if count == 0 { return result }
      result.append(contentsOf: buffer.prefix(count))
    }
  }

  static func diagnostic(_ error: any Error) {
    let message: String
    if let diagnostic = error as? ShellDiagnostic {
      message = "byte \(diagnostic.offset): \(diagnostic.message)"
    } else {
      message = String(describing: error)
    }
    try? writeBytes(Array("swsh: \(message)\n".utf8), to: STDERR_FILENO)
  }
}
