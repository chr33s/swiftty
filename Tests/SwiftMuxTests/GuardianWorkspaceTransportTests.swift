import Darwin
import Dispatch
import Foundation
import SwiftMuxClient
import SwiftMuxGuardian
import SwiftMuxProtocol
@testable import SwiftMuxService
import Synchronization
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct GuardianWorkspaceTransportTests {
  private static let program = #"""
    import os,sys,tty,fcntl,termios,struct
    tty.setraw(0)
    tag=sys.argv[1].encode()
    os.write(1,tag+b'READY\x1b[5n')
    reply=b''
    while len(reply)<4: reply+=os.read(0,4-len(reply))
    os.write(1,tag+(b'REPLIED' if reply==b'\x1b[0n' else b'BADREPLY'))
    value=os.read(0,1)
    rows,cols,_,_=struct.unpack('HHHH',fcntl.ioctl(0,termios.TIOCGWINSZ,b'\0'*8))
    os.write(1,tag+('%dx%d'% (cols,rows)).encode() if value==b'x' else b'BADINPUT')
    raise SystemExit(7)
    """#

  @Test
  func independentPanesKeepWireOrderAndProgressUnderParserBackpressure() throws
  {
    let fixture = try Workspace()
    defer { fixture.stop() }
    let a = fixture.makePane()
    let b = fixture.makePane()
    a.pause()
    try fixture.launch(a, tag: "A")
    try fixture.launch(b, tag: "B")
    let aPID = a.process.pid
    try eventually {
      b.runtime.screenLines().contains { $0.contains("BREPLIED") }
    }
    #expect(throws: MuxError.self) {
      try fixture.broker.makePane(
        id: PaneID(),
        queue: DispatchQueue(label: "overflow-pane"),
        limits: .standard
      )
    }
    b.runtime.resize(columns: 100, rows: 30)
    try eventually {
      b.runtime.queue.sync { b.runtime.geometryGeneration == 1 }
    }
    #expect(b.runtime.reserve(1))
    b.runtime.write(.text("x"), estimate: 1)
    #expect(b.finished.wait(timeout: .now() + 3) == .success)
    #expect(b.runtime.screenLines().contains { $0.contains("B100x30") })
    b.runtime.queue.sync { #expect(b.process.exitStatus == 7) }
    // More than two health periods: paused parsing is healthy queue progress.
    Thread.sleep(forTimeInterval: 2.3 * Workspace.progressTimeout)
    #expect(fixture.server.inventory().first?.available == true)
    #expect(kill(aPID, 0) == 0)
    #expect(a.runtime.screenLines().allSatisfy { !$0.contains("AREADY") })
    let retired = DispatchSemaphore(value: 0)
    fixture.broker.forget(b.runtime.id) { error in
      #expect(error == nil)
      retired.signal()
    }
    #expect(retired.wait(timeout: .now() + 3) == .success)
    let c = fixture.makePane()  // the forgotten route returned its slot
    let removed = DispatchSemaphore(value: 0)
    fixture.broker.forget(c.runtime.id) { error in
      #expect(error == nil);
      removed.signal()
    }
    #expect(removed.wait(timeout: .now() + 3) == .success)
    a.resume()
    try eventually {
      a.runtime.screenLines().contains { $0.contains("AREPLIED") }
    }
    #expect(a.runtime.reserve(1))
    a.runtime.write(.text("x"), estimate: 1)
    #expect(a.finished.wait(timeout: .now() + 3) == .success)
    #expect(a.runtime.screenLines().contains { $0.contains("A80x24") })
    #expect(a.process.pid == aPID)
    #expect(fixture.closed.wait(timeout: .now()) == .timedOut)
  }

  @Test
  func blockedPaneQueuePreventsFalseHealthWhileBothChildrenRemainOwned() throws
  {
    let fixture = try Workspace()
    defer { fixture.stop() }
    let a = fixture.makePane()
    let b = fixture.makePane()
    try fixture.launch(a, tag: "A")
    try fixture.launch(b, tag: "B")
    try eventually {
      a.runtime.screenLines().contains { $0.contains("AREPLIED") }
        && b.runtime.screenLines().contains { $0.contains("BREPLIED") }
    }
    a.runtime.queue.suspend()
    #expect(fixture.closed.wait(timeout: .now() + 5) == .success)
    #expect(fixture.server.inventory().first?.available == false)
    #expect(kill(a.process.pid, 0) == 0 && kill(b.process.pid, 0) == 0)
    a.runtime.queue.resume()
    a.runtime.queue.sync { #expect(!a.process.finished && !a.process.isOpen) }
    b.runtime.queue.sync { #expect(!b.process.finished && !b.process.isOpen) }
  }

  @Test
  func writerRevocationRefundsRejectedInputAndAllowsFreshCapability() throws {
    let fixture = try Workspace()
    defer { fixture.stop() }
    let pane = fixture.makePane()
    try fixture.launch(pane, tag: "W")
    try eventually {
      pane.runtime.screenLines().contains { $0.contains("WREPLIED") }
    }
    let revoked = DispatchSemaphore(value: 0)
    fixture.server.replaceGateway(UUID())
    fixture.broker.replaceWriter(nil) { error in
      #expect(error == nil);
      revoked.signal()
    }
    #expect(revoked.wait(timeout: .now() + 3) == .success)
    #expect(pane.runtime.reserve(1))
    pane.runtime.write(.text("b"), estimate: 1)
    pane.runtime.queue.sync {
      #expect(pane.runtime.outstandingInput.withLock { $0 } == 0)
    }
    let gateway = UUID()
    fixture.server.replaceGateway(gateway)
    let token = try fixture.server.grantWriter(
      workspace: fixture.id,
      gateway: gateway
    )
    let granted = DispatchSemaphore(value: 0)
    fixture.broker.replaceWriter(token) { error in
      #expect(error == nil);
      granted.signal()
    }
    #expect(granted.wait(timeout: .now() + 3) == .success)
    #expect(pane.runtime.reserve(1))
    pane.runtime.write(.text("x"), estimate: 1)
    #expect(pane.finished.wait(timeout: .now() + 3) == .success)
    #expect(pane.runtime.screenLines().contains { $0.contains("W80x24") })
  }

  @Test
  func rejectedLaunchCanRetireItsRouteWithoutLosingLiveOwnership() throws {
    let fixture = try Workspace()
    defer { fixture.stop() }
    let pane = fixture.makePane()
    let launcher = try PaneLauncher(
      launcherPath: launcherPath(),
      innerTerm: SMX.fallbackInnerTerm
    )
    let completed = DispatchSemaphore(value: 0)
    pane.runtime.queue.async {
      pane.runtime.launch(
        LaunchSpec(command: [String(repeating: "x", count: 1 << 20)]),
        launcher: launcher
      ) { result in
        if case let .failure(error) = result {
          #expect(error.code == .resourceLimit)
        } else {
          Issue.record("oversized launch was admitted")
        }
        completed.signal()
      }
    }
    #expect(completed.wait(timeout: .now() + 3) == .success)
    #expect(fixture.server.inventory().first?.panes.isEmpty == true)
    let retired = DispatchSemaphore(value: 0)
    fixture.broker.forget(pane.runtime.id) { error in
      #expect(error == nil);
      retired.signal()
    }
    #expect(retired.wait(timeout: .now() + 3) == .success)
    let active = fixture.makePane()
    try fixture.launch(active, tag: "LIVE")
    let refused = DispatchSemaphore(value: 0)
    fixture.broker.forget(active.runtime.id) { error in
      #expect(error?.code == .invalidRequest);
      refused.signal()
    }
    #expect(refused.wait(timeout: .now() + 3) == .success)
    #expect(kill(active.process.pid, 0) == 0)
    #expect(fixture.server.inventory().first?.panes.count == 1)
  }

  @Test
  func scopedServiceOwnsItsGraphAndUsesGuardianPanesWithoutLocalFallback()
    async throws
  {
    let fixture = try Workspace()
    defer { fixture.stop() }
    var configuration = MuxServiceConfiguration(
      launcherPath: try launcherPath()
    )
    configuration.workerWorkspace = fixture.id
    configuration.limits.maxPanes = 2
    configuration.paneProcessFactory = { id, workspace, queue, limits in
      guard workspace == fixture.id else {
        throw MuxError(.unauthorized, "wrong workspace")
      }
      return try fixture.broker.makePane(id: id, queue: queue, limits: limits)
    }
    let service = try MuxService(configuration: configuration)
    defer { retire(service) }
    let endpoint = service.listenAnonymously()
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      fixture.broker.publishServiceEndpoint(
        endpoint,
        instance: service.instance
      ) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
    let discovered = try #require(
      fixture.server.workerEndpoint(workspace: fixture.id)
    )
    let client = try await MuxConnection.connect(
      endpoint: discovered.endpoint,
      frontend: .native
    )
    #expect(await client.welcome?.server == discovered.instance)
    guard
      case let .created(workspace) = try await client.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      )
    else { throw MuxError(.invalidRequest, "missing workspace") }
    #expect(workspace.id == fixture.id)
    let pane = workspace.tabs[0].activePane
    try await client.attachAndShow(.id(workspace.id))
    try await client.send(.text("echo broker-$((40+2))\r"), to: pane)
    let frame = try await client.frame(of: pane) {
      $0.lines.contains("broker-42")
    }
    try FrameValidator.validate(frame)
    let firstPID = try #require(
      fixture.server.inventory().first?.panes.first?.pid
    )
    guard
      case let .layout(split) = try await client.execute(
        .split(pane: pane, axis: .leftRight, launch: shellLaunch())
      )
    else { throw MuxError(.invalidRequest, "missing split layout") }
    #expect(split.id == fixture.id)
    #expect(split.tabs[0].layout.panes.count == 2)
    #expect(fixture.server.inventory().first?.panes.count == 2)
    #expect(
      fixture.server.inventory().first?.panes.contains { $0.pid == firstPID }
        == true
    )
    await #expect(throws: MuxError.self) {
      try await client.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      )
    }
    #expect(await service.workspaces.count == 1)
    _ = try await client.execute(.endPane(split.tabs[0].activePane))
    let retirementDeadline = ContinuousClock.now + .seconds(5)
    while await service.paneCount != 1 {
      try #require(ContinuousClock.now < retirementDeadline)
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(fixture.server.inventory().first?.panes.count == 1)
    guard
      case let .layout(replacement) = try await client.execute(
        .split(pane: pane, axis: .leftRight, launch: shellLaunch())
      )
    else {
      throw MuxError(.invalidRequest, "retired pane slot was not returned")
    }
    #expect(replacement.tabs[0].layout.panes.count == 2)
    #expect(fixture.server.inventory().first?.panes.count == 2)
    _ = try await client.execute(.endWorkspace(.id(workspace.id)))
    await #expect(throws: MuxError.self) {
      try await client.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      )
    }
    await client.close()
  }

  @Test
  func rejectedAdapterConstructionDoesNotReserveHistoryOrLaunchLocally()
    async throws
  {
    var configuration = MuxServiceConfiguration(
      launcherPath: try launcherPath()
    )
    configuration.workerWorkspace = WorkspaceID()
    configuration.paneProcessFactory = { _, _, _, _ in
      throw MuxError(.resourceLimit, "broker has no capacity")
    }
    let service = try MuxService(configuration: configuration)
    defer { retire(service) }
    let client = try await MuxConnection.connect(
      endpoint: service.listenAnonymously(),
      frontend: .control
    )
    do {
      _ = try await client.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      )
      Issue.record(
        "failed adapter silently fell back to local process ownership"
      )
    } catch let error as MuxError { #expect(error.code == .resourceLimit) }
    #expect(await service.pendingLaunches == 0)
    #expect(await service.pendingHistoryBytes == 0)
    #expect(await service.panes.isEmpty)
    #expect(await service.workspaces.isEmpty)
    #expect(await !service.workerWorkspaceClaimed)
    await client.close()
  }

  @Test
  func scopedServiceRequiresAnExplicitProcessAdapter() throws {
    var configuration = MuxServiceConfiguration(
      launcherPath: try launcherPath()
    )
    configuration.workerWorkspace = WorkspaceID()
    #expect(throws: MuxError.self) {
      try MuxService(configuration: configuration)
    }
  }

  private func retire(_ service: MuxService) {
    let done = DispatchSemaphore(value: 0)
    service.prepareToExit { done.signal() }
    #expect(done.wait(timeout: .now() + 8) == .success)
  }

  private func eventually(_ predicate: () -> Bool) throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate() {
      guard ContinuousClock.now < deadline else {
        throw MuxError(.connectionLost, "workspace broker timed out")
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
  }

  private final class Pane: @unchecked Sendable {
    let runtime: PaneRuntime
    let process: GuardianPaneProcess
    let finished = DispatchSemaphore(value: 0)
    var savedConsumer: (() -> Bool)?
    init(runtime: PaneRuntime, process: GuardianPaneProcess) {
      self.runtime = runtime
      self.process = process
      runtime.onEvent = { [weak self] in
        if case .finished = $0 { self?.finished.signal() }
      }
    }
    func pause() {
      runtime.queue.sync {
        savedConsumer = process.canConsume;
        process.canConsume = { false }
      }
    }
    func resume() {
      runtime.queue.sync {
        process.canConsume = savedConsumer;
        savedConsumer = nil;
        process.flush()
      }
    }
  }

  private final class Workspace: @unchecked Sendable {
    /// Short enough that the health tests run quickly, long enough that a
    /// loaded CI runner's scheduling stalls (probes are answered within
    /// half of it) do not read as a dead worker.
    static let progressTimeout: TimeInterval = 1
    let server: GuardianServer
    let id = WorkspaceID()
    let broker: GuardianWorkspaceTransport
    let closed: DispatchSemaphore
    init() throws {
      server = try GuardianServer(
        launcherPath: launcherPath(),
        peerRequirement: nil,
        progressTimeout: Self.progressTimeout
      )
      let endpoint = server.listenAnonymously()
      let token = try server.provisionWorker(workspace: id, pid: getpid())
      let workspace = id
      let ready = DispatchSemaphore(value: 0)
      let ended = DispatchSemaphore(value: 0)
      closed = ended
      broker = try GuardianWorkspaceTransport(
        workspace: id,
        maxPanes: 2,
        connect: { queue, handlers in
          try GuardianWorkerConnection(
            channel: .connect(endpoint: endpoint, queue: queue),
            workspace: workspace,
            token: token,
            peerRequirement: nil,
            handlers: handlers
          )
        },
        ready: { ready.signal() },
        closed: { _ in ended.signal() }
      )
      #expect(ready.wait(timeout: .now() + 3) == .success)
      let gateway = UUID()
      server.replaceGateway(gateway)
      let writer = try server.grantWriter(workspace: id, gateway: gateway)
      let granted = DispatchSemaphore(value: 0)
      broker.replaceWriter(writer) { error in
        #expect(error == nil);
        granted.signal()
      }
      #expect(granted.wait(timeout: .now() + 3) == .success)
    }
    func makePane() -> Pane {
      let process = Mutex<GuardianPaneProcess?>(nil)
      let runtime = PaneRuntime(
        id: PaneID(),
        workspace: id,
        columns: 80,
        rows: 24,
        historyBytes: 0,
        limits: .standard,
        processFactory: { [self] id, _, queue, limits in
          let value = try! broker.makePane(id: id, queue: queue, limits: limits)
          process.withLock { $0 = value }
          return value
        }
      )
      return Pane(runtime: runtime, process: process.withLock { $0! })
    }
    func launch(_ pane: Pane, tag: String) throws {
      let launcher = try PaneLauncher(
        launcherPath: launcherPath(),
        innerTerm: SMX.fallbackInnerTerm
      )
      let done = DispatchSemaphore(value: 0)
      pane.runtime.queue.async {
        pane.runtime.launch(
          LaunchSpec(command: [
            "/usr/bin/python3", "-u", "-c",
            GuardianWorkspaceTransportTests.program, tag,
          ]),
          launcher: launcher
        ) { result in
          if case let .failure(error) = result { Issue.record(error) }
          done.signal()
        }
      }
      #expect(done.wait(timeout: .now() + 3) == .success)
    }
    func stop() {
      broker.close()
      let stopped = DispatchSemaphore(value: 0)
      server.shutdown { stopped.signal() }
      #expect(stopped.wait(timeout: .now() + 8) == .success)
    }
  }
}
