#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Dispatch
import Foundation
import Synchronization
@testable import Swsh

/// Invoked only by the isolated PTY fixture, never in the shared test runner.
func runAsyncSessionProbe(_ mode: String) throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString
  )
  try FileManager.default.createDirectory(
    at: root,
    withIntermediateDirectories: false
  )
  defer { try? FileManager.default.removeItem(at: root) }
  let helper = root.appendingPathComponent("child.py")
  let pidFile = root.appendingPathComponent("pid")
  let completedFile = root.appendingPathComponent("completed")
  let observer = mode == "cancel-observer"
  let failRestoration = mode == "cancel-cleanup-restore-failure"
  let restoring = Mutex(false)
  try """
  import os,signal,sys,time
  if sys.argv[3]=='cleanup':
      signal.signal(signal.SIGHUP,signal.SIG_IGN)
      signal.signal(signal.SIGTERM,signal.SIG_IGN)
  with open(sys.argv[1]+'.tmp','w') as f: f.write(str(os.getpid()))
  os.replace(sys.argv[1]+'.tmp',sys.argv[1])
  time.sleep(0.3 if sys.argv[3]=='observer' else 60)
  with open(sys.argv[2],'w') as f: f.write('completed')
  """
  .write(to: helper, atomically: true, encoding: .utf8)
  let child =
    "/usr/bin/python3 '\(helper.path)' '\(pidFile.path)' '\(completedFile.path)' \(observer ? "observer" : "cleanup")"
  let source =
    observer
    ? "\(child); exit 23"
    : """
    \(child) &
    /bin/sh -c 'while [ ! -f "$1" ]; do sleep 0.01; done; stty -echo' probe '\(pidFile.path)'
    exit 23
    """
  try source.write(
    to: root.appendingPathComponent(".swshrc"),
    atomically: true,
    encoding: .utf8
  )
  setenv("HOME", root.path, 1)
  var original = termios()
  guard tcgetattr(STDIN_FILENO, &original) == 0 else {
    throw SystemFailure("probe terminal modes")
  }
  let binary = probeShellURL()
  let executable = Array(binary.path.utf8)
  let build = try LauncherPayload.buildIdentity(executable: executable)
  let session = ShellSession()
  let cleanupStarted = DispatchSemaphore(value: 0)
  let releaseCleanup = DispatchSemaphore(value: 0)
  let done = DispatchSemaphore(value: 0)
  let result = Mutex<Int32?>(nil)
  let task = Task {
    let status = await session.run(
      options: [Array("-i".utf8)],
      executable: executable,
      build: build,
      beforeCleanup: {
        restoring.withLock { $0 = true }
        cleanupStarted.signal()
        if !observer { _ = releaseCleanup.wait(timeout: .now() + 3) }
      },
      terminalBeforeInstall: {
        if failRestoration && restoring.withLock({ $0 }) {
          throw SystemFailure("injected final terminal restoration", code: EIO)
        }
      }

    )
    result.withLock { $0 = status }
    done.signal()
  }
  var finished = false
  defer {
    releaseCleanup.signal()
    if !finished {
      task.cancel();
      _ = done.wait(timeout: .now() + 6)
    }
  }
  if observer {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !FileManager.default.fileExists(atPath: pidFile.path),
      ContinuousClock.now < deadline
    { usleep(1_000) }
    guard FileManager.default.fileExists(atPath: pidFile.path) else {
      throw SystemFailure("observer child not ready", code: ETIMEDOUT)
    }
    task.cancel()
  } else {
    guard cleanupStarted.wait(timeout: .now() + 3) == .success else {
      throw SystemFailure("cleanup not reached", code: ETIMEDOUT)
    }
    var editing = termios()
    guard tcgetattr(STDIN_FILENO, &editing) == 0,
      editing.c_lflag & tcflag_t(ECHO) == 0
    else {
      throw SystemFailure(
        "probe did not leave terminal modes to restore",
        code: EINVAL
      )
    }
    if mode == "cancel-before-cleanup" { task.cancel() }
    releaseCleanup.signal()
    if mode != "cancel-before-cleanup" {
      usleep(100_000);
      task.cancel()
    }
    // Cleanup suspends without admitting a second evaluator into the session.
    let rejected = DispatchSemaphore(value: 0)
    let secondResult = Mutex<Int32?>(nil)
    Task {
      let status = await session.run(
        options: [Array("-c".utf8), Array(":".utf8)],
        executable: executable,
        build: build
      )
      secondResult.withLock { $0 = status }
      rejected.signal()
    }
    guard rejected.wait(timeout: .now() + 1) == .success,
      secondResult.withLock({ $0 }) == 1
    else {
      throw SystemFailure(
        "cleanup admitted another evaluator or blocked its executor",
        code: EINVAL
      )
    }
    guard result.withLock({ $0 }) == nil else {
      throw SystemFailure(
        "cancelled cleanup returned before escalation",
        code: EINVAL
      )
    }
  }
  let cleanupWait = ContinuousClock.now
  guard done.wait(timeout: .now() + 6) == .success else {
    throw SystemFailure("awaited cleanup did not finish", code: ETIMEDOUT)
  }
  finished = true
  guard result.withLock({ $0 }) == (failRestoration ? 1 : 23) else {
    throw SystemFailure("cleanup lost requested status", code: EINVAL)
  }
  if !observer && cleanupWait.duration(to: .now) < .seconds(1) {
    throw SystemFailure("cleanup skipped its grace period", code: EINVAL)
  }
  guard FileManager.default.fileExists(atPath: completedFile.path) == observer
  else {
    throw SystemFailure(
      "observer cancellation signaled a job or cleanup failed to terminate it",
      code: EINVAL
    )
  }
  let pid = try String(contentsOf: pidFile, encoding: .utf8)
    .withCString { strtol($0, nil, 10) }
  var status: Int32 = 0
  guard waitpid(pid_t(pid), &status, WNOHANG) == -1, errno == ECHILD else {
    throw SystemFailure("cleanup left an unreaped child", code: EINVAL)
  }
  if failRestoration {
    // The failed session reports failure instead of claiming restoration.
    // Only the isolated test host repairs its terminal after checking the result.
    guard tcsetattr(STDIN_FILENO, TCSANOW, &original) == 0 else {
      throw SystemFailure("repair probe terminal")
    }
    return
  }
  var restored = termios()
  guard tcgetattr(STDIN_FILENO, &restored) == 0,
    restored.c_lflag == original.c_lflag, restored.c_iflag == original.c_iflag,
    restored.c_oflag == original.c_oflag, restored.c_cflag == original.c_cflag,
    tcgetpgrp(STDIN_FILENO) == getpgrp()
  else {
    throw SystemFailure(
      "cleanup did not restore terminal ownership and modes",
      code: EINVAL
    )
  }
}
