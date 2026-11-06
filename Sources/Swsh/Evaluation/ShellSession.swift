#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Dispatch

/// One serial executor owns all process-global shell state and the sole evaluator.
/// Blocking command/terminal waits occupy this dedicated queue, not the cooperative
/// executor. Async cleanup retains the same isolation across every suspension.
actor ShellSession {
  #if canImport(Darwin)
  nonisolated private let queue = DispatchSerialQueue(label: "swsh.session")
  #else
  nonisolated private let queue = SessionExecutor()
  #endif
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
        defer { status = driver.runExitTrap(status) }
        driver.state.variables["0"] = Array("swsh".utf8)
        driver.state.setArguments([])
        if let terminal {
          status = try ShellMain.interact(driver: driver, terminal: terminal)
        } else {
          let usage = ShellDiagnostic(
            offset: 0,
            message:
              "usage: swsh [-i] | -c source [name [argument...]] | file [argument...]"
          )
          let source: [UInt8]
          if options.first == Array("-c".utf8) {
            guard options.count >= 2 else { throw usage }
            source = options[1]
            // As in sh, the word after the source names the script as `$0`.
            if options.count > 2 { driver.state.variables["0"] = options[2] }
            driver.state.setArguments(Array(options.dropFirst(3)))
          } else if let path = options.first {
            guard path.first != 45 else { throw usage }
            let file = try OwnedFD.open(path, flags: O_RDONLY)
            source = try file.withDescriptor {
              try ShellMain.readSource($0, supervisor: supervisor)
            }
            driver.state.variables["0"] = path
            driver.state.setArguments(Array(options.dropFirst()))
          } else {
            source = try ShellMain.readSource(
              STDIN_FILENO,
              supervisor: supervisor
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

#if !canImport(Darwin)
/// corelibs Dispatch has no `DispatchSerialQueue`; this runs the session's
/// jobs on one serial queue instead.
final class SessionExecutor: SerialExecutor {
  private let queue = DispatchQueue(label: "swsh.session")
  func enqueue(_ job: consuming ExecutorJob) {
    let job = UnownedJob(job)
    queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
  }
  func asUnownedSerialExecutor() -> UnownedSerialExecutor {
    UnownedSerialExecutor(ordinary: self)
  }
}
#endif
