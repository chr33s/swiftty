import Darwin
import Dispatch
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
@testable import SwiftMuxService
import Synchronization
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct ServiceDisposalTests {
  enum Child: String, CaseIterable, Sendable {
    case cooperative, ignoring, descendant
  }

  private func reaped(_ pid: pid_t) -> Bool {
    var info = siginfo_t()
    return waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == -1
      && errno == ECHILD
  }

  private func cleanup(_ pid: pid_t, service: inout MuxService?) {
    // Release the owner before observing its exclusive shutdown reaper.
    // A waitable child is still service-owned; the fixture must not collect
    // it or signal a PID/group that the service could release concurrently.
    service = nil
    let deadline = ContinuousClock.now + .seconds(7)
    while !reaped(pid), ContinuousClock.now < deadline { usleep(10000) }
    #expect(reaped(pid))
  }

  @Test(arguments: Child.allCases)
  func releasingServiceRetiresItsProcesses(child: Child) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("service-disposal-" + UUID().uuidString)
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
        if sys.argv[3]=='descendant':
            subprocess.Popen([sys.executable,__file__,*sys.argv[1:],'child'])
            while not os.path.exists(sys.argv[2]): time.sleep(0.01)
        elif sys.argv[3]=='ignoring': signal.signal(signal.SIGHUP,signal.SIG_IGN)
        record(sys.argv[1])
    else:
        signal.signal(signal.SIGHUP,signal.SIG_IGN)
        record(sys.argv[2])
    print('READY',flush=True)
    time.sleep(8)
    """
    .write(to: script, atomically: true, encoding: .utf8)
    var service: MuxService? = try MuxService(
      configuration: MuxServiceConfiguration(launcherPath: launcherPath()),
    )
    defer { service = nil }
    weak var weakService = service
    let c = try await MuxConnection.connect(
      endpoint: #require(service).listenAnonymously(),
      frontend: .control,
    )
    var launch = shellLaunch()
    launch.command = [
      "/usr/bin/python3", "-u", script.path, leaderFile.path, childFile.path,
      child.rawValue,
    ]
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: launch))
      )
    else { throw MuxError(.invalidRequest, "creation reply") }
    let ready = ContinuousClock.now + .seconds(2)
    while !FileManager.default.fileExists(atPath: leaderFile.path),
      ContinuousClock.now < ready
    { try await Task.sleep(for: .milliseconds(10)) }
    let pid = try #require(
      pid_t(String(contentsOf: leaderFile, encoding: .utf8, ))
    )
    defer { cleanup(pid, service: &service) }
    let descendant =
      child == .descendant
      ? try #require(pid_t(String(contentsOf: childFile, encoding: .utf8, )))
      : nil
    weak var weakRuntime = await service?.runtime(ws.tabs[0].activePane)
    await c.close()
    let started = ContinuousClock.now
    service = nil
    let disposed = ContinuousClock.now + .seconds(1)
    while weakService != nil || weakRuntime != nil,
      ContinuousClock.now < disposed
    { try await Task.sleep(for: .milliseconds(10)) }
    #expect(weakService == nil)
    #expect(weakRuntime == nil)
    #expect(ContinuousClock.now - started < .seconds(1))
    let deadline = ContinuousClock.now + .seconds(7)
    while !reaped(pid) || descendant.map({ kill($0, 0) == 0 }) == true,
      ContinuousClock.now < deadline
    { try await Task.sleep(for: .milliseconds(10)) }
    #expect(reaped(pid))
    if let descendant {
      #expect(kill(descendant, 0) == -1)
      #expect(errno == ESRCH)
    }
    if child == .cooperative {
      #expect(ContinuousClock.now - started < .seconds(1))
    } else {
      #expect(ContinuousClock.now - started >= .seconds(5))
    }
  }

  private func waitForGate(_ gate: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
      DispatchQueue.global()
        .async {
          continuation.resume(
            returning: gate.wait(timeout: .now() + 1) == .success
          )
        }
    }
  }

  @Test
  func releasingServiceDuringLaunchRetiresLateChild() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("service-disposal-launch-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("launcher")
    let pidFile = directory.appendingPathComponent("pid")
    try """
    #!/usr/bin/python3
    import ctypes,os,signal,sys,time
    assert ctypes.CDLL(None).login_tty(3)==0
    signal.signal(signal.SIGHUP,signal.SIG_IGN)
    path=os.path.join(sys.argv[1],'pid')
    with open(path+'.tmp','w') as f: f.write(str(os.getpid()))
    os.replace(path+'.tmp',path)
    os.write(4,b'S exec 0\\n')
    os.close(4)
    time.sleep(8)
    """
    .write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: executable.path
    )
    let started = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    defer { proceed.signal() }
    var configuration = MuxServiceConfiguration(launcherPath: executable.path)
    configuration.beforeLaunch = {
      started.signal();
      _ = proceed.wait(timeout: .now() + 3)
    }
    var service: MuxService? = try MuxService(configuration: configuration)
    defer { service = nil }
    weak var weakService = service
    let replies = Mutex(0)
    var launch = shellLaunch()
    launch.command = ["/bin/true"]
    launch.workingDirectory = directory.path
    let request = NewWorkspaceRequest(launch: launch)
    service?
      .onQueue { current in
        current.newWorkspace(request) { _ in replies.withLock { $0 += 1 } }
      }
    #expect(await waitForGate(started))
    service = nil
    let disposed = ContinuousClock.now + .seconds(1)
    while weakService != nil, ContinuousClock.now < disposed {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(weakService == nil)
    #expect(!FileManager.default.fileExists(atPath: pidFile.path))
    let released = ContinuousClock.now
    proceed.signal()
    let ready = ContinuousClock.now + .seconds(2)
    while !FileManager.default.fileExists(atPath: pidFile.path),
      ContinuousClock.now < ready
    { try await Task.sleep(for: .milliseconds(10)) }
    let pid = try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8)))
    defer { cleanup(pid, service: &service) }
    let retired = ContinuousClock.now + .seconds(7)
    while !reaped(pid), ContinuousClock.now < retired {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(reaped(pid))
    #expect(ContinuousClock.now - released >= .seconds(5))
    #expect(replies.withLock { $0 } == 0)
  }
}
