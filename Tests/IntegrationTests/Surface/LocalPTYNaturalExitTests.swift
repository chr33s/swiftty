#if os(macOS) && !targetEnvironment(macCatalyst)
import Darwin
import Foundation
import SwifttyCore
import Synchronization
import Testing
import TestSupport

@Suite(.serialized, .timeLimit(.minutes(1)))
struct LocalPTYNaturalExitTests {
  private func reaped(_ pid: pid_t) -> Bool {
    let observation = reapObservation(pid)
    return observation.result == -1 && observation.error == ECHILD
  }

  private func reapObservation(
    _ pid: pid_t,
  ) -> (result: Int32, error: Int32, reportedPID: pid_t) {
    var info = siginfo_t()
    var result: Int32
    repeat {
      result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
    } while result < 0 && errno == EINTR
    return (result, result < 0 ? errno : 0, info.si_pid)
  }

  private func waitForRetirement(
    leader: pid_t,
    child: pid_t,
    deadline: ContinuousClock.Instant,
  ) async throws {
    // Descendant disappearance and leader collection are independent.
    // Observe both without taking over the session's reaping authority.
    while kill(child, 0) == 0 || !reaped(leader), ContinuousClock.now < deadline
    { try await Task.sleep(for: .milliseconds(10)) }
  }

  @Test
  func retirementWaitIncludesDelayedLeaderCollection() async throws {
    let leader = try PTYProcess.spawn(
      SessionConfiguration(command: ["/usr/bin/true"]),
      columns: 10,
      rows: 2,
    )
    var transferred = false
    defer {
      if !transferred { #expect(OwnedChildWait(leader.pid).terminate()) }
    }
    let child = try PTYProcess.spawn(
      SessionConfiguration(command: ["/usr/bin/true"]),
      columns: 10,
      rows: 2,
    )
    let childOwner = OwnedChildWait(child.pid)
    defer { #expect(childOwner.terminate()) }
    try #require(childOwner.collect() == 0)
    // The descendant has disappeared, but the leader still belongs to us.
    try #require(kill(child.pid, 0) == -1 && errno == ESRCH)
    try #require(!reaped(leader.pid))
    let pid = leader.pid
    let collector = Task.detached {
      try? await Task.sleep(for: .milliseconds(200))
      let owner = OwnedChildWait(pid)
      defer { #expect(owner.terminate()) }
      return owner.collect()
    }
    transferred = true
    let deadline = ContinuousClock.now + .seconds(3)
    // Always join the exclusive collector, even if the wait is cancelled.
    let waited: Void? = try? await waitForRetirement(
      leader: pid,
      child: child.pid,
      deadline: deadline,
    )
    #expect(waited != nil)
    #expect(reaped(pid))
    #expect(await collector.value == 0)
  }

  private func cleanup(session: TerminalSession, leader: pid_t, child: pid_t) {
    // The session owns signaling and collection, including failed tests.
    session.stop()
    let leaderDeadline = ContinuousClock.now + .seconds(7)
    while !reaped(leader), ContinuousClock.now < leaderDeadline {
      usleep(10000)
    }
    #expect(reaped(leader))
    // Only observe descendants. The fixture also exits after eight seconds
    // if a production regression prevents group cleanup.
    let deadline = ContinuousClock.now + .seconds(9)
    while kill(child, 0) == 0, ContinuousClock.now < deadline { usleep(10000) }
    #expect(kill(child, 0) == -1)
    #expect(errno == ESRCH)
  }

  @Test(arguments: [false, true])
  func naturalExitPreservesStatusAndRetiresDescendant(
    signaled: Bool,
  ) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pty-natural-exit-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = directory.appendingPathComponent("pane.py")
    let leaderFile = directory.appendingPathComponent("leader")
    let childFile = directory.appendingPathComponent("child")
    try """
    import os,signal,subprocess,sys,time
    def record(path):
        with open(path+'.tmp','w') as f: f.write(str(os.getpid()))
        os.replace(path+'.tmp',path)
    if len(sys.argv)==4:
        subprocess.Popen([sys.executable,__file__,*sys.argv[1:],'child'])
        while not os.path.exists(sys.argv[2]): time.sleep(0.01)
        record(sys.argv[1])
        print('FINAL',flush=True)
        if sys.argv[3]=='signal': os.kill(os.getpid(),signal.SIGTERM)
        sys.exit(7)
    signal.signal(signal.SIGHUP,signal.SIG_IGN)
    record(sys.argv[2])
    time.sleep(8)
    """
    .write(to: script, atomically: true, encoding: .utf8)
    let session = TerminalSession(columns: 20, rows: 4)
    let exits = Mutex<[Int32]>([])
    let output = Mutex<[UInt8]>([])
    session.onEvent = { event in
      if case let .exited(code) = event { exits.withLock { $0.append(code) } }
    }
    session.onProgramOutput = { bytes in
      output.withLock { $0.append(contentsOf: bytes) }
    }
    var configuration = SessionConfiguration()
    configuration.command = [
      "/usr/bin/python3", "-u", script.path, leaderFile.path, childFile.path,
      signaled ? "signal" : "normal",
    ]
    let started = ContinuousClock.now
    try session.start(configuration)
    defer { session.stop() }
    #expect(await eventually { !exits.withLock { $0 }.isEmpty })
    let leader = try #require(
      pid_t(String(contentsOf: leaderFile, encoding: .utf8, ))
    )
    let child = try #require(
      pid_t(String(contentsOf: childFile, encoding: .utf8, ))
    )
    defer { cleanup(session: session, leader: leader, child: child) }
    #expect(exits.withLock { $0 } == [signaled ? 143 : 7])
    #expect(!session.isRunning)
    #expect(
      String(decoding: output.withLock { $0 }, as: UTF8.self).contains("FINAL")
    )
    let observed = ContinuousClock.now
    // The host gives a shell five seconds to clean up before escalation.
    let deadline = observed + .seconds(7)
    try await waitForRetirement(
      leader: leader,
      child: child,
      deadline: deadline
    )
    #expect(kill(child, 0) == -1)
    #expect(errno == ESRCH)
    let observation = reapObservation(leader)
    #expect(
      observation.result == -1 && observation.error == ECHILD,
      Comment(
        rawValue: "leader \(leader): waitid \(observation.result), "
          + "errno \(observation.error), reported PID \(observation.reportedPID)"
      ),
    )
    #expect(ContinuousClock.now - started >= .seconds(5))
    #expect(exits.withLock { $0 }.count == 1)
  }
}
#endif
