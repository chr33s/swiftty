#if os(macOS) && !targetEnvironment(macCatalyst)
import Darwin
import Foundation
import SwifttyCore
import Synchronization
import TerminalSurface
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct LocalPTYTerminationTests {
  enum Disposal: CaseIterable, Sendable { case close, deinitialize }
  enum Child: String, CaseIterable, Sendable {
    case cooperative, ignoring, descendant
  }

  /// Observes without consuming the status: a zombie is not successful
  /// cleanup, and the fixture must not do the production reaper's work.
  private func reaped(_ pid: pid_t) -> Bool {
    var info = siginfo_t()
    let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
    return result == -1 && errno == ECHILD
  }

  @Test(arguments: Disposal.allCases, Child.allCases)
  func disposalTerminatesAndReapsActualChild(
    disposal: Disposal,
    child: Child,
  ) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pty-termination-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appendingPathComponent("pid")
    let program = #"""
      import os,sys,time,signal,subprocess
      def hangup(signum,frame):
          with open(sys.argv[1]+'.hup','w') as f: f.write('received')
          sys.exit(0)
      if sys.argv[2]=='descendant':
          subprocess.Popen([sys.executable,'-u','-c',sys.argv[3],sys.argv[1]+'.child'])
          while not os.path.exists(sys.argv[1]+'.child'): time.sleep(0.01)
      signal.signal(signal.SIGHUP,signal.SIG_IGN if sys.argv[2]=='ignoring' else hangup)
      with open(sys.argv[1],'w') as f: f.write(str(os.getpid()))
      os.write(1,b'READY')
      while True: time.sleep(1)
      """#
    var session: TerminalSession? = TerminalSession(columns: 20, rows: 4)
    // Install cleanup before readiness or PID requirements can throw.
    // Reading the current optional preserves the deinitialization case.
    defer { session?.stop() }
    let received = Mutex(0)
    session?.onProgramOutput = { bytes in
      received.withLock { $0 += bytes.count }
    }
    let backend =
      try disposal == .close ? LocalPTYBackend(session: #require(session)) : nil
    var configuration = SessionConfiguration()
    configuration.command = [
      "/usr/bin/python3", "-u", "-c", program, pidFile.path, child.rawValue,
      "import os,signal,sys,time; signal.signal(signal.SIGHUP,signal.SIG_IGN); "
        // Publish atomically: the parent proceeds once the file exists.
        + "open(sys.argv[1]+'.tmp','w').write(str(os.getpid())); "
        + "os.replace(sys.argv[1]+'.tmp',sys.argv[1]); time.sleep(8)",
    ]
    if let backend {
      try backend.start(configuration)
    } else {
      try session?.start(configuration)
    }
    #expect(await eventually { received.withLock { $0 } == 5 })
    let pid = try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8)))
    let descendant =
      child == .descendant
      ? try #require(
        pid_t(String(contentsOfFile: pidFile.path + ".child", encoding: .utf8, )
        )
      ) as pid_t : nil
    #expect(!reaped(pid))
    session?.withState { _ in }
    weak let weakSession = session
    let disposalStarted = ContinuousClock.now
    if let backend {
      await backend.close()
      #expect(backend.lifecycle == .closed)
      #expect(!backend.session.isRunning)
    } else {
      session = nil
      #expect(weakSession == nil)
    }
    #expect(ContinuousClock.now - disposalStarted < .seconds(1))
    // Allow the five-second host grace plus scheduling/reaping latency.
    #expect(await eventually(.seconds(7)) { reaped(pid) })
    if let descendant {
      #expect(await eventually { kill(descendant, 0) == -1 && errno == ESRCH })
    }
    if child != .ignoring {
      #expect(FileManager.default.fileExists(atPath: pidFile.path + ".hup"))
    }
    if child == .cooperative {
      #expect(ContinuousClock.now - disposalStarted < .seconds(1))
    } else {
      #expect(ContinuousClock.now - disposalStarted >= .seconds(5))
    }
  }
}
#endif
