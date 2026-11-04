import Darwin
import Foundation
import SwifttyCore
import Synchronization
import Testing

/// Upper bound for a child process to reach an expected state. Tests run in
/// parallel, so a short bound fails under load; waits end once the state holds.
private let processWait: Duration = .seconds(30)

private final class ShellShutdownBundle: NSObject {}

struct ShellShutdownTests {
  @Test
  func stopAllowsCleanupBeyondTwoSeconds() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let pidFile = root.appendingPathComponent("pid")
    let done = root.appendingPathComponent("done")
    let session = TerminalSession(columns: 40, rows: 4)
    try session.start(
      SessionConfiguration(command: [
        "/usr/bin/python3", "-c",
        """
        import os,signal,sys,time
        stopped=False
        def stop(signum, frame):
            global stopped
            signal.signal(signal.SIGHUP,signal.SIG_IGN)
            stopped=True
        signal.signal(signal.SIGHUP,stop)
        with open(sys.argv[1]+'.tmp','w') as f: f.write(str(os.getpid()))
        os.replace(sys.argv[1]+'.tmp',sys.argv[1])
        while not stopped: time.sleep(0.01)
        time.sleep(3)
        with open(sys.argv[2],'w') as f: f.write('cleaned')
        """, pidFile.path, done.path,
      ])
    )
    defer { session.stop() }
    let pid = try #require(
      try await waitForPublishedPID(pidFile, deadline: .now + processWait)
    )
    let started = ContinuousClock.now
    session.stop()
    // Repeated close must not start another grace period or another reaper.
    session.stop()
    let deadline = ContinuousClock.now + processWait
    while kill(pid, 0) == 0, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try String(contentsOf: done, encoding: .utf8) == "cleaned")
    #expect(ContinuousClock.now - started >= .seconds(3))
    #expect(kill(pid, 0) == -1)
    var info = siginfo_t()
    #expect(waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == -1)
    #expect(errno == ECHILD)
  }

  @Test(arguments: [false, true])
  func nativeShellStopReapsRunningAndStoppedJobs(_ stopped: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = Bundle(for: ShellShutdownBundle.self).bundleURL
      .deletingLastPathComponent().appendingPathComponent("swsh")
    try #require(FileManager.default.isExecutableFile(atPath: binary.path))
    let helper = root.appendingPathComponent("job.py")
    let pidFile = root.appendingPathComponent("pid")
    try """
    import os,signal,sys,time
    signal.signal(signal.SIGHUP,signal.SIG_IGN)
    signal.signal(signal.SIGTERM,signal.SIG_IGN)
    with open(sys.argv[1]+'.parent','w') as f: f.write(str(os.getppid()))
    with open(sys.argv[1]+'.tmp','w') as f: f.write(str(os.getpid()))
    os.replace(sys.argv[1]+'.tmp',sys.argv[1])
    if sys.argv[2]=='stop': os.kill(os.getpid(),signal.SIGSTOP)
    time.sleep(60)
    """
    .write(to: helper, atomically: true, encoding: .utf8)
    let session = TerminalSession(columns: 80, rows: 24)
    let output = Mutex("")
    session.onProgramOutput = { bytes in
      output.withLock { $0 += String(decoding: bytes, as: UTF8.self) }
    }
    try session.start(
      SessionConfiguration(
        command: [binary.path, "-i"],
        environment: ["HOME": root.path]
      )
    )
    defer { session.stop() }
    let promptDeadline = ContinuousClock.now + processWait
    while !output.withLock({ $0.contains("swsh> ") }),
      ContinuousClock.now < promptDeadline
    { try await Task.sleep(for: .milliseconds(10)) }
    try #require(
      output.withLock { $0.contains("swsh> ") },
      "\(output.withLock { $0 })"
    )
    session.send(
      .text(
        "/usr/bin/python3 '\(helper.path)' '\(pidFile.path)' \(stopped ? "stop" : "run")\n"
      )
    )
    let pid = try #require(
      try await waitForPublishedPID(pidFile, deadline: .now + processWait),
      "\(output.withLock { $0 })"
    )
    let shellPID = try #require(
      pid_t(String(contentsOfFile: pidFile.path + ".parent", encoding: .utf8))
    )
    if stopped {
      let deadline = ContinuousClock.now + processWait
      while !output.withLock({ $0.contains("] stopped") }),
        ContinuousClock.now < deadline
      { try await Task.sleep(for: .milliseconds(10)) }
      try #require(output.withLock { $0.contains("] stopped") })
    }
    let started = ContinuousClock.now
    session.stop()
    let deadline = ContinuousClock.now + .seconds(5)
    while kill(pid, 0) == 0, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(kill(pid, 0) == -1)
    #expect(errno == ESRCH)
    #expect(ContinuousClock.now - started >= .seconds(2))
    #expect(ContinuousClock.now - started < .seconds(5))
    while kill(shellPID, 0) == 0, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    var info = siginfo_t()
    #expect(
      waitid(P_PID, id_t(shellPID), &info, WEXITED | WNOHANG | WNOWAIT) == -1
    )
    #expect(errno == ECHILD)
  }
}

private func waitForPublishedPID(
  _ file: URL,
  deadline: ContinuousClock.Instant
) async throws -> pid_t? {
  while ContinuousClock.now < deadline {
    if let text = try? String(contentsOf: file, encoding: .utf8),
      let pid = pid_t(text)
    {
      return pid
    }
    try await Task.sleep(for: .milliseconds(10))
  }
  return nil
}
