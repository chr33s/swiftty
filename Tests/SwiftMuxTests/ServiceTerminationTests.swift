import Darwin
import Dispatch
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
@testable import SwiftMuxService
import Synchronization
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct ServiceTerminationTests {
  @Test
  func paneCloseAllowsShellOwnedCleanupBeyondTwoSeconds() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString
    )
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let marker = root.appendingPathComponent("ready")
    var launch = shellLaunch()
    launch.command = [
      "/usr/bin/python3", "-c",
      """
      import os,signal,sys,time
      stopped=False
      def stop(signum,frame):
          global stopped
          signal.signal(signal.SIGHUP,signal.SIG_IGN)
          stopped=True
      signal.signal(signal.SIGHUP,stop)
      with open(sys.argv[1],'w') as f: f.write('ready')
      while not stopped: time.sleep(0.01)
      time.sleep(3)
      sys.exit(23)
      """, marker.path,
    ]
    guard
      case let .created(workspace) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: launch))
      )
    else { throw MuxError(.invalidRequest, "unexpected reply") }
    let pane = workspace.tabs[0].activePane
    try await c.attachAndShow(.id(workspace.id))
    try await c.execute(.newTab(name: nil, launch: shellLaunch()))
    let ready = ContinuousClock.now + .seconds(3)
    while !FileManager.default.fileExists(atPath: marker.path),
      ContinuousClock.now < ready
    { try await Task.sleep(for: .milliseconds(10)) }
    try #require(FileManager.default.fileExists(atPath: marker.path))
    let started = ContinuousClock.now
    try await c.execute(.endPane(pane))
    let result = try await withTimeout(.seconds(8)) {
      while let event = try await c.nextEvent() {
        if case let .paneExited(id, status, forced) = event, id == pane {
          return (status, forced)
        }
      }
      throw MuxError(.connectionLost, "closed before cleanup")
    }
    #expect(result.0 == 23)
    #expect(!result.1)
    #expect(ContinuousClock.now - started >= .seconds(3))
    try await c.execute(.endAllWorkspaces)
    await c.close()
  }

  private func retire(
    _ service: MuxService,
    finished: Bool,
    done: DispatchSemaphore,
    ready: @escaping @Sendable () -> Void,
  ) {
    if !finished {
      service.prepareToExit(ready)
      #expect(done.wait(timeout: .now() + 8) == .success)
    }
  }

  private func wait(
    _ semaphore: DispatchSemaphore,
    seconds: Double = 8,
  ) async -> Bool {
    await withCheckedContinuation { continuation in
      DispatchQueue.global()
        .async {
          continuation.resume(
            returning: semaphore.wait(timeout: .now() + seconds) == .success
          )
        }
    }
  }

  @Test
  func exitWaitsForIgnoringPaneAndCannotReopenAdmission() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("service-termination-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
    )
    let pidFile = directory.appendingPathComponent("pid")
    let h = try Harness()
    let done = DispatchSemaphore(value: 0)
    let finished = Mutex(false)
    let ready: @Sendable () -> Void = {
      finished.withLock { $0 = true };
      done.signal()
    }
    defer {
      retire(
        h.service,
        finished: finished.withLock { $0 },
        done: done,
        ready: ready,
      )
      try? FileManager.default.removeItem(at: directory)
    }
    let c = try await h.connect(.control)
    var launch = shellLaunch()
    launch.command = [
      "/usr/bin/python3", "-u", "-c",
      """
      import os,signal,sys,time
      signal.signal(signal.SIGHUP,signal.SIG_IGN)
      with open(sys.argv[1]+'.tmp','w') as f: f.write(str(os.getpid()))
      os.replace(sys.argv[1]+'.tmp',sys.argv[1])
      time.sleep(60)
      """, pidFile.path,
    ]
    _ = try await c.execute(.newWorkspace(NewWorkspaceRequest(launch: launch)))
    let deadline = ContinuousClock.now + .seconds(2)
    while !FileManager.default.fileExists(atPath: pidFile.path),
      ContinuousClock.now < deadline
    { try await Task.sleep(for: .milliseconds(10)) }
    let pid = try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8)))
    let started = ContinuousClock.now
    h.service.prepareToExit(ready)
    let duplicate = Mutex(false)
    h.service.prepareToExit { duplicate.withLock { $0 = true } }
    #expect(await h.service.exitRequested)
    do {
      _ = try await c.execute(.quiesce(false))
      Issue.record("shutdown admission reopened")
    } catch let error as MuxError { #expect(error.code == .quiescing) }
    #expect(await wait(done))
    #expect(ContinuousClock.now - started >= .seconds(5))
    #expect(!duplicate.withLock { $0 })
    #expect(await h.service.isEmpty)
    var info = siginfo_t()
    #expect(waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == -1)
    #expect(errno == ECHILD)
    // An open control client does not prevent the process barrier completing.
    guard case let .status(status) = try await c.execute(.status) else {
      throw MuxError(.invalidRequest, "unexpected status")
    }
    #expect(status.panes == 0)
    await c.close()
  }

  /// A natural leader exit must drain output and retire its remaining
  /// group even if descendants close their PTY descriptors themselves.
  @Test(arguments: [false, true])
  func naturalExitRetiresDescendantsAndPreservesStatus(
    closesPTY: Bool
  ) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("service-natural-exit-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
    )
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
        print('leader-final',flush=True)
        sys.exit(7)
    signal.signal(signal.SIGHUP,signal.SIG_IGN)
    time.sleep(0.2)
    print('descendant-final',flush=True)
    if sys.argv[3]=='close':
        for fd in (0,1,2): os.close(fd)
    record(sys.argv[2])
    while True: time.sleep(30)
    """
    .write(to: script, atomically: true, encoding: .utf8)
    let h = try Harness()
    let done = DispatchSemaphore(value: 0)
    let finished = Mutex(false)
    let ready: @Sendable () -> Void = {
      finished.withLock { $0 = true };
      done.signal()
    }
    defer {
      retire(
        h.service,
        finished: finished.withLock { $0 },
        done: done,
        ready: ready,
      )
      try? FileManager.default.removeItem(at: directory)
    }
    let c = try await h.connect()
    var launch = shellLaunch()
    launch.command = [
      "/usr/bin/python3", "-u", script.path, leaderFile.path, childFile.path,
      closesPTY ? "close" : "retain",
    ]
    let started = ContinuousClock.now
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: launch, remainOnExit: true))
      )
    else { throw MuxError(.invalidRequest, "unexpected reply") }
    let pane = ws.tabs[0].activePane
    try await c.attachAndShow(.id(ws.id))
    _ = try await c.frame(of: pane) {
      $0.lines.contains("descendant-final") && $0.lines.contains("leader-final")
    }
    let exit = try await withTimeout(.seconds(9)) {
      while let event = try await c.nextEvent() {
        if case let .paneExited(id, status, forced) = event, id == pane {
          return (status, forced)
        }
      }
      throw MuxError(.connectionLost, "closed before exit")
    }
    #expect(exit.0 == 7)
    #expect(exit.1)
    #expect(ContinuousClock.now - started >= .seconds(3))
    let leader = try #require(
      pid_t(String(contentsOf: leaderFile, encoding: .utf8))
    )
    let child = try #require(
      pid_t(String(contentsOf: childFile, encoding: .utf8))
    )
    var info = siginfo_t()
    #expect(
      waitid(P_PID, id_t(leader), &info, WEXITED | WNOHANG | WNOWAIT) == -1
    )
    #expect(errno == ECHILD)
    let retired = ContinuousClock.now + .seconds(1)
    while kill(child, 0) == 0, ContinuousClock.now < retired {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(kill(child, 0) == -1)
    #expect(errno == ESRCH)
    await c.close()
  }

  @Test
  func exitWaitsForAdmittedLaunchAndItsLateChild() async throws {
    let started = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    let finished = Mutex(false)
    var configuration = try MuxServiceConfiguration(
      launcherPath: launcherPath()
    )
    configuration.beforeLaunch = {
      started.signal();
      _ = proceed.wait(timeout: .now() + 3)
    }
    let service = try MuxService(configuration: configuration)
    let ready: @Sendable () -> Void = {
      finished.withLock { $0 = true };
      done.signal()
    }
    defer {
      proceed.signal()
      retire(
        service,
        finished: finished.withLock { $0 },
        done: done,
        ready: ready,
      )
    }
    let c = try await MuxConnection.connect(
      endpoint: service.listenAnonymously(),
      frontend: .control,
    )
    var launch = shellLaunch()
    launch.command = ["/bin/sh", "-c", "exec sleep 60"]
    let creating = Task {
      try await c.execute(.newWorkspace(NewWorkspaceRequest(launch: launch)))
    }
    #expect(await wait(started))
    service.prepareToExit(ready)
    #expect(await service.exitRequested)
    #expect(!finished.withLock { $0 })
    #expect(await !(service.isEmpty))
    proceed.signal()
    do {
      _ = try await creating.value
      Issue.record("admitted launch joined the graph after shutdown")
    } catch let error as MuxError { #expect(error.code == .quiescing) }
    #expect(await wait(done))
    #expect(await service.isEmpty)
    await c.close()
  }
}
