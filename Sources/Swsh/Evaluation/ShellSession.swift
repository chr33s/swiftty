import Darwin
import Dispatch

/// One serial executor owns all process-global shell state and the sole evaluator.
/// Blocking command/terminal waits occupy this dedicated queue, not the cooperative
/// executor. Async cleanup retains the same isolation across every suspension.
actor ShellSession {
  nonisolated private let queue = DispatchSerialQueue(label: "swsh.session")
  nonisolated var unownedExecutor: UnownedSerialExecutor {
    queue.asUnownedSerialExecutor()
  }
  private var started = false
  private var status: Int32 = 0

  func run(
    options: [[UInt8]],
    executable: [UInt8],
    build: String,
    beforeCleanup: (@Sendable () -> Void)? = nil,
    terminalBeforeInstall: (@Sendable () throws -> Void)? = nil
  ) async -> Int32 {
    guard !started else { return 1 }
    started = true
    await execute(
      options: options,
      executable: executable,
      build: build,
      beforeCleanup: beforeCleanup,
      terminalBeforeInstall: terminalBeforeInstall
    )
    // Read after the awaited defer, so cleanup failure can override command status.
    return status
  }

  private func execute(
    options: [[UInt8]],
    executable: [UInt8],
    build: String,
    beforeCleanup: (@Sendable () -> Void)?,
    terminalBeforeInstall: (@Sendable () throws -> Void)?
  ) async {
    do {
      let interactive =
        options == [Array("-i".utf8)]
        || (options.isEmpty && isatty(STDIN_FILENO) != 0)
      let terminal =
        interactive
        ? try TerminalControl(beforeInstall: terminalBeforeInstall) : nil
      let supervisor: JobSupervisor
      do {
        supervisor = try JobSupervisor(
          executable: executable,
          build: build,
          terminal: terminal
        )
      } catch {
        try? terminal?.restoreForExit()
        throw error
      }
      defer {
        beforeCleanup?()
        await withTaskCancellationShield {
          let cleaned = await supervisor.shutdownAwaitingCleanup()
          if let requested = supervisor.shutdownRequested { status = requested }
          var restored = true
          do { try terminal?.restoreForExit() } catch {
            if supervisor.shutdownRequested != 128 + SIGHUP {
              ShellMain.diagnostic(error)
              restored = false
            }
          }
          if !cleaned || !restored {
            ShellMain.diagnostic(
              SystemFailure("incomplete session cleanup", code: ETIMEDOUT)
            )
            status = 1
          }
        }
      }
      do {
        let driver = try SessionDriver(supervisor: supervisor)
        if let terminal {
          status = try ShellMain.interact(driver: driver, terminal: terminal)
        } else {
          let source: [UInt8]
          if options.first == Array("-c".utf8) {
            guard options.count == 2 else {
              throw ShellDiagnostic(
                offset: 0,
                message: "usage: swsh [-i] | -c source | file"
              )
            }
            source = options[1]
          } else if options.count == 1 {
            let file = try OwnedFD.open(options[0], flags: O_RDONLY)
            source = try file.withDescriptor {
              try ShellMain.readSource($0, supervisor: supervisor)
            }
          } else if options.isEmpty {
            source = try ShellMain.readSource(
              STDIN_FILENO,
              supervisor: supervisor
            )
          } else {
            throw ShellDiagnostic(
              offset: 0,
              message: "usage: swsh [-i] | -c source | file"
            )
          }
          switch try driver.submit(ShellMain.parse(source)) {
          case .completed(let result), .exit(let result): status = result
          case .stopped: status = driver.state.status
          }
        }
      } catch {
        ShellMain.diagnostic(error)
        status = error is ShellDiagnostic ? 2 : 1
      }
      if let requested = supervisor.shutdownRequested { status = requested }
    } catch {
      ShellMain.diagnostic(error)
      status = error is ShellDiagnostic ? 2 : 1
    }
  }
}
