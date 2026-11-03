import Darwin
import Dispatch
import Foundation
import SwiftMuxGuardian
import SwiftMuxProtocol
import Synchronization
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct GuardianSupervisionTests {
  @Test
  func ownedWorkerReceivesPrivateBootstrapAndNaturalExitIsReaped() throws {
    let server = try makeServer()
    defer { stop(server) }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString
    )
    defer { try? FileManager.default.removeItem(at: file) }
    let fd = open("/dev/null", O_RDONLY)
    #expect(fd >= 0)
    defer { Darwin.close(fd) }
    let inherited = fcntl(fd, F_DUPFD, 100)
    #expect(inherited >= 100)
    defer { Darwin.close(inherited) }
    let workspace = WorkspaceID()
    let program = """
      import os,json,sys
      data=b''
      while True:
        chunk=os.read(3,1024)
        if not chunk: break
        data+=chunk
      os.close(3)
      config=json.loads(data)
      assert config['guardianPID']==os.getppid()
      assert config['workspace']==sys.argv[2]
      assert config['build']=='fixture-build'
      assert config['token'] not in ' '.join(sys.argv)
      assert os.getpgrp()==os.getpid()
      try: os.fstat(int(sys.argv[3]))
      except OSError: pass
      else: raise Exception('descriptor leaked')
      with open(sys.argv[1],'w') as f: json.dump({'pid':os.getpid(),'parent':os.getppid()},f)
      sys.exit(23)
      """
    let worker = try launch(
      server,
      workspace,
      executable: "/usr/bin/python3",
      arguments: [
        "-c", program, file.path, workspace.description, String(inherited),
      ]
    )
    try eventually { server.inventory().first?.worker?.finished == true }
    let status = try #require(server.inventory().first?.worker)
    #expect(status.pid == worker.pid)
    #expect(status.build == "fixture-build")
    #expect(status.status == 23 << 8)
    #expect(server.inventory().first?.available == false)
    let evidence = try JSONDecoder()
      .decode([String: Int32].self, from: Data(contentsOf: file))
    #expect(evidence["parent"] == getpid())
    #expect(evidence["pid"] == worker.pid)
    assertReaped(worker.pid)
    server.endWorkspace(workspace)
    // queue.sync in forget orders after the asynchronous End.
    try server.forgetWorkspace(workspace)
    #expect(server.inventory().isEmpty)
  }

  @Test
  func unresponsiveUnadmittedWorkerIsKilledAndCapacityRequiresExplicitEnd()
    throws
  {
    var limits = MuxLimits.standard
    limits.maxPanes = 1
    let server = try makeServer(limits: limits)
    defer { stop(server) }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString
    )
    defer { try? FileManager.default.removeItem(at: file) }
    let workspace = WorkspaceID()
    let program = """
      import os,signal,time,sys
      signal.signal(signal.SIGTERM,signal.SIG_IGN)
      while os.read(3,1024): pass
      os.close(3)
      open(sys.argv[1],'w').close()
      time.sleep(60)
      """
    let worker = try launch(
      server,
      workspace,
      executable: "/usr/bin/python3",
      arguments: ["-c", program, file.path]
    )
    try eventually { FileManager.default.fileExists(atPath: file.path) }
    #expect(server.inventory().first?.available == false)
    #expect(server.inventory().first?.starting == true)
    #expect(throws: MuxError.self) { try server.forgetWorkspace(workspace) }
    // No hello ever arrives. The guardian's five-second admission deadline
    // fences this child, and its bounded escalation defeats ignored SIGTERM.
    try eventually { server.inventory().first?.worker?.finished == true }
    #expect(server.inventory().first?.worker?.status == SIGKILL)
    #expect(server.inventory().first?.starting == false)
    assertReaped(worker.pid)
    #expect(throws: MuxError.self) {
      _ = try launch(
        server,
        WorkspaceID(),
        executable: "/bin/sleep",
        arguments: ["60"]
      )
    }
    server.endWorkspace(workspace)
    try server.forgetWorkspace(workspace)
    let next = WorkspaceID()
    _ = try launch(server, next, executable: "/bin/sleep", arguments: ["60"])
    server.endWorkspace(next)
    try eventually { server.inventory().first?.worker?.finished == true }
    try server.forgetWorkspace(next)
    #expect(server.inventory().isEmpty)
  }

  @Test
  func failedLaunchReleasesReservationAndShutdownCollectsPendingWorker() throws
  {
    let server = try makeServer()
    defer { stop(server) }
    let workspace = WorkspaceID()
    #expect(throws: MuxError.self) {
      _ = try launch(
        server,
        workspace,
        executable: "/nonexistent/swiftty-worker",
        arguments: []
      )
    }
    #expect(server.inventory().isEmpty)
    let outcome = Mutex<Result<GuardianWorkerInventory, MuxError>?>(nil)
    let launched = DispatchSemaphore(value: 0)
    server.launchWorker(
      workspace: workspace,
      executable: "/bin/sleep",
      arguments: ["60"],
      build: "fixture-build",
      machService: "com.chr33s.swiftty.test.unregistered"
    ) { result in
      outcome.withLock { $0 = result }
      launched.signal()
    }
    server.endWorkspace(workspace)
    stop(server)
    #expect(launched.wait(timeout: .now() + 1) == .success)
    #expect(outcome.withLock { $0 != nil })
    let worker = try #require(server.inventory().first?.worker)
    #expect(worker.finished)
    assertReaped(worker.pid)
  }

  @Test
  func workerSignatureIsCheckedBeforeSpawn() throws {
    let server = try GuardianServer(
      launcherPath: launcherPath(),
      peerRequirement: "identifier \"definitely.not.the.worker\""
    )
    defer { stop(server) }
    do {
      _ = try launch(
        server,
        WorkspaceID(),
        executable: "/bin/sleep",
        arguments: ["60"]
      )
      Issue.record("signature mismatch was accepted")
    } catch let error as MuxError { #expect(error.code == .unauthorized) }
    #expect(server.inventory().isEmpty)
  }

  private func makeServer(
    limits: MuxLimits = .standard
  ) throws -> GuardianServer {
    try GuardianServer(
      launcherPath: launcherPath(),
      limits: limits,
      peerRequirement: nil
    )
  }

  private func launch(
    _ server: GuardianServer,
    _ workspace: WorkspaceID,
    executable: String,
    arguments: [String]
  ) throws -> GuardianWorkerInventory {
    let outcome = Mutex<Result<GuardianWorkerInventory, MuxError>?>(nil)
    let done = DispatchSemaphore(value: 0)
    server.launchWorker(
      workspace: workspace,
      executable: executable,
      arguments: arguments,
      build: "fixture-build",
      machService: "com.chr33s.swiftty.test.unregistered"
    ) { result in
      outcome.withLock { $0 = result }
      done.signal()
    }
    #expect(done.wait(timeout: .now() + 5) == .success)
    return try #require(outcome.withLock { $0 }).get()
  }

  private func assertReaped(_ pid: Int32) {
    var status: Int32 = 0
    #expect(waitpid(pid, &status, WNOHANG) == -1)
    #expect(errno == ECHILD)
  }

  private func eventually(_ predicate: () -> Bool) throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !predicate() {
      guard ContinuousClock.now < deadline else {
        throw MuxError(.connectionLost, "supervision test timed out")
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
  }

  private func stop(_ server: GuardianServer) {
    let done = DispatchSemaphore(value: 0)
    server.shutdown { done.signal() }
    #expect(done.wait(timeout: .now() + 8) == .success)
  }
}
