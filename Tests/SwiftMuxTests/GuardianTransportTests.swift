import Darwin
import Dispatch
import Foundation
import SwiftMuxGuardian
import SwiftMuxProtocol
import SwiftMuxXPC
import Synchronization
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct GuardianTransportTests {
  @Test
  func
    pasteCancellationUsesGuardianWriteStateAndReleasesDeferredReplyCreditOnce()
    throws
  {
    let fixture = try Fixture()
    defer { fixture.stop() }
    let pane = PaneID()
    let program = #"""
      import os,tty
      tty.setraw(0)
      expected=b'\x1b[200~\x1b[201~\x1b[200~ABC\x1b[201~R'
      os.write(1,b'READY')
      data=b''
      while len(data)<len(expected): data+=os.read(0,len(expected)-len(data))
      os.write(1,b'MATCH' if data==expected else b'WRONG')
      os._exit(0)
      """#
    _ = try fixture.command(
      1,
      .spawn(
        pane: pane,
        launch: LaunchSpec(command: ["/usr/bin/python3", "-c", program]),
        columns: 80,
        rows: 24
      )
    )
    #expect(try fixture.output(pane, count: 5) == Data("READY".utf8))
    let handle = fixture.handle(pane)
    let gateway = UUID()
    fixture.server.replaceGateway(gateway)
    let writer = try fixture.server.grantWriter(
      workspace: fixture.workspace,
      gateway: gateway
    )
    #expect(
      try fixture.command(
        2,
        .beginPaste(pane: handle, writer: writer, id: 1, bracketed: true)
      ) == .admitted(bytes: 12)
    )
    let empty = GuardianCommand.cancelPaste(
      pane: handle,
      writer: writer,
      id: 1,
      discardDeferredInput: false
    )
    #expect(try fixture.command(3, empty) == .pasteCancelled(wrote: false))
    #expect(try fixture.command(3, empty) == .pasteCancelled(wrote: false))
    #expect(
      try fixture.command(
        4,
        .beginPaste(pane: handle, writer: writer, id: 2, bracketed: true)
      ) == .admitted(bytes: 12)
    )
    #expect(
      try fixture.command(
        5,
        .appendPaste(pane: handle, writer: writer, id: 2, text: "ABC")
      ) == .admitted(bytes: 3)
    )
    #expect(
      try fixture.command(6, .reply(pane: handle, bytes: Data("R".utf8))) == .ok
    )
    let partial = GuardianCommand.cancelPaste(
      pane: handle,
      writer: writer,
      id: 2,
      discardDeferredInput: false
    )
    #expect(try fixture.command(7, partial) == .pasteCancelled(wrote: true))
    #expect(try fixture.command(7, partial) == .pasteCancelled(wrote: true))
    #expect(try fixture.output(pane, count: 5) == Data("MATCH".utf8))
    let lifecycle = try fixture.peer.next {
      switch $0 {
      case .exiting, .exited: true;
      default: false
      }
    }
    if case .exiting = lifecycle {
    } else {
      Issue.record("missing early exit notification")
    }
    _ = try fixture.peer.next { if case .exited = $0 { true } else { false } }
    var inputReleased = 0
    var replyReleased = 0
    while let event = try? fixture.peer.next(
      timeout: .milliseconds(20),
      where: {
        switch $0 {
        case .inputReleased, .replyReleased: true;
        default: false
        }
      }
    ) {
      switch event {
      case let .inputReleased(_, bytes): inputReleased += bytes
      case let .replyReleased(_, bytes): replyReleased += bytes
      default: break
      }
    }
    #expect(inputReleased == 27)
    #expect(replyReleased == 1)
  }

  @Test
  func commandLargerThanDedupBudgetIsRefusedInsteadOfRetriedForever() throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    try fixture.peer.send(
      .command(
        authority: fixture.authority,
        sequence: 1,
        body: .spawn(
          pane: PaneID(),
          launch: LaunchSpec(command: [
            "/usr/bin/true",
            String(repeating: "x", count: GuardianWire.commandRecordLimit),
          ]),
          columns: 80,
          rows: 24
        )
      )
    )
    #expect(try fixture.peer.closed())
    #expect(fixture.server.inventory().first?.panes.isEmpty == true)
  }

  @Test
  func stalledWorkerIsFencedDespiteCommandTrafficAndRetainsItsChild() throws {
    let server = try GuardianServer(
      launcherPath: launcherPath(),
      peerRequirement: nil,
      progressTimeout: 1
    )
    let fixture = try Fixture(
      server: server,
      endpoint: server.listenAnonymously()
    )
    defer { fixture.stop() }
    let pane = PaneID()
    let result = try fixture.command(
      1,
      .spawn(
        pane: pane,
        launch: LaunchSpec(command: ["/bin/sleep", "60"]),
        columns: 80,
        rows: 24
      )
    )
    guard case let .spawned(pid, _, _) = result else {
      throw Failure.unexpected
    }
    let handle = fixture.handle(pane)
    // Commands keep arriving on the connection, but the worker never proves
    // that its pane queues progressed through the requested health barrier.
    var sequence: UInt64 = 2
    let start = ContinuousClock.now
    while server.inventory().first?.available == true {
      try fixture.peer.send(
        .command(
          authority: fixture.authority,
          sequence: sequence,
          body: .resize(pane: handle, columns: 80, rows: 24)
        )
      )
      sequence += 1
      Thread.sleep(forTimeInterval: 0.025)
      guard start.duration(to: .now) < .seconds(3) else {
        throw Failure.timeout
      }
    }
    #expect(try fixture.peer.closed())
    #expect(kill(pid, 0) == 0)
    server.endWorkspace(fixture.workspace)
    try eventually { server.inventory().first?.panes.first?.finished == true }
  }

  @Test
  func progressRemainsHealthyUnderOutputBackpressureButOldProbeCannotRenewIt()
    throws
  {
    let server = try GuardianServer(
      launcherPath: launcherPath(),
      peerRequirement: nil,
      progressTimeout: 1
    )
    let fixture = try Fixture(
      server: server,
      endpoint: server.listenAnonymously()
    )
    defer { fixture.stop() }
    _ = try fixture.command(
      1,
      .spawn(
        pane: PaneID(),
        launch: LaunchSpec(command: ["/usr/bin/yes"]),
        columns: 80,
        rows: 24
      )
    )
    var oldProbe: UUID?
    let start = ContinuousClock.now
    // Output is deliberately never acknowledged. Control probes still pass
    // while the child and transport are backpressured at their bounded limits.
    for _ in 0 ..< 4 {
      let event = try fixture.peer.next {
        if case .probe = $0 { true } else { false }
      }
      guard case let .probe(probe) = event else { throw Failure.unexpected }
      if oldProbe == nil { oldProbe = probe }
      try fixture.peer.send(
        .progress(authority: fixture.authority, probe: probe)
      )
    }
    #expect(start.duration(to: .now) > .seconds(1))
    #expect(server.inventory().first?.available == true)
    try fixture.peer.send(
      .progress(authority: fixture.authority, probe: oldProbe!)
    )
    #expect(try fixture.peer.closed())
    #expect(server.inventory().first?.available == false)
  }

  @Test
  func retriesDoNotSpawnOrWriteTwiceAndRevokedWritersCannotInject() throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    let pane = PaneID()
    let program = """
      import os,tty
      tty.setraw(0)
      os.write(1,b'READY')
      for _ in range(2): os.write(1,os.read(0,1))
      os._exit(0)
      """
    let spawn = GuardianCommand.spawn(
      pane: pane,
      launch: LaunchSpec(command: ["/usr/bin/python3", "-c", program]),
      columns: 80,
      rows: 24
    )
    let first = try fixture.command(1, spawn)
    #expect(try fixture.command(1, spawn) == first)
    #expect(fixture.server.inventory().first?.panes.count == 1)
    #expect(try fixture.output(pane, count: 5) == Data("READY".utf8))
    let gateway = UUID()
    fixture.server.replaceGateway(gateway)
    let oldWriter = try fixture.server.grantWriter(
      workspace: fixture.workspace,
      gateway: gateway
    )
    let writer = try fixture.server.grantWriter(
      workspace: fixture.workspace,
      gateway: gateway
    )
    #expect(
      try fixture.command(
        2,
        .input(
          pane: fixture.handle(pane),
          writer: oldWriter,
          bytes: Data("X".utf8)
        )
      ) == .rejected(MuxError(.staleAttachment, "writer capability revoked"))
    )
    let input = GuardianCommand.input(
      pane: fixture.handle(pane),
      writer: writer,
      bytes: Data("A".utf8)
    )
    #expect(try fixture.command(3, input) == .admitted(bytes: 1))
    #expect(try fixture.command(3, input) == .admitted(bytes: 1))
    #expect(
      try fixture.command(
        4,
        .input(
          pane: fixture.handle(pane),
          writer: writer,
          bytes: Data("B".utf8)
        )
      ) == .admitted(bytes: 1)
    )
    #expect(try fixture.output(pane, count: 2) == Data("AB".utf8))
    let event = try fixture.peer.next {
      if case .exited = $0 { true } else { false }
    }
    if case let .exited(id, status, _) = event {
      #expect(id.pane == pane && status == 0)
    } else {
      Issue.record("missing final status")
    }
  }

  @Test
  func workerLossRetainsChildAndSupervisorEndReapsIt() throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    let pane = PaneID()
    let reply = try fixture.command(
      1,
      .spawn(
        pane: pane,
        launch: LaunchSpec(command: ["/bin/sleep", "60"]),
        columns: 80,
        rows: 24
      )
    )
    guard case let .spawned(pid, _, _) = reply else { throw Failure.unexpected }
    fixture.peer.channel.cancel()
    try eventually { fixture.server.inventory().first?.available == false }
    #expect(kill(pid, 0) == 0)
    #expect(fixture.server.inventory().first?.panes.first?.pid == pid)
    fixture.server.endWorkspace(fixture.workspace)
    try eventually {
      fixture.server.inventory().first?.panes.first?.finished == true
    }
    var status: Int32 = 0
    #expect(waitpid(pid, &status, WNOHANG) == -1)
    #expect(errno == ECHILD)
  }

  @Test
  func outputCreditBoundsTransportAndAcknowledgementResumesExactStream() throws
  {
    let fixture = try Fixture()
    defer { fixture.stop() }
    let pane = PaneID()
    let program = """
      import os,tty,time
      tty.setraw(0)
      data=b'z'*(2*1024*1024)
      while data: data=data[os.write(1,data):]
      time.sleep(30)
      """
    _ = try fixture.command(
      1,
      .spawn(
        pane: pane,
        launch: LaunchSpec(command: ["/usr/bin/python3", "-c", program]),
        columns: 80,
        rows: 24
      )
    )
    var count = 0
    var last: UInt64 = 0
    // No acknowledgements: output must stop within the per-pane byte and
    // record windows, although the real child has another MiB to write.
    while let event = try? fixture.peer.next(
      timeout: .seconds(1),
      where: { if case .output = $0 { true } else { false } }
    ) {
      if case let .output(_, sequence, bytes) = event {
        count += bytes.count
        last = sequence
        #expect(bytes.allSatisfy { $0 == 0x7A })
        #expect(count <= 1 << 20)
        #expect(sequence <= UInt64(GuardianWire.outputRecordLimit))
      }
    }
    #expect(count > 0 && count <= 1 << 20)
    try fixture.peer.send(
      .outputAck(
        authority: fixture.authority,
        pane: fixture.handle(pane),
        through: last
      )
    )
    let remaining = try fixture.output(pane, count: (2 << 20) - count)
    #expect(remaining.allSatisfy { $0 == 0x7A })
  }

  @Test
  func wrongPIDAndStaleAuthorityAreRejected() throws {
    let server = try GuardianServer(
      launcherPath: launcherPath(),
      peerRequirement: nil
    )
    defer { stop(server) }
    let endpoint = server.listenAnonymously()
    let workspace = WorkspaceID()
    let token = try server.provisionWorker(
      workspace: workspace,
      pid: getpid() + 1
    )
    let peer = Peer(endpoint)
    try peer.send(
      .hello(version: GuardianWire.version, workspace: workspace, token: token)
    )
    #expect(try peer.closed())
    #expect(server.inventory().first?.available == false)

    let fixture = try Fixture()
    defer { fixture.stop() }
    var stale = fixture.authority
    stale.generation += 1
    try fixture.peer.send(
      .command(
        authority: stale,
        sequence: 1,
        body: .spawn(
          pane: PaneID(),
          launch: LaunchSpec(command: ["/bin/sleep", "60"]),
          columns: 80,
          rows: 24
        )
      )
    )
    #expect(try fixture.peer.closed())
    #expect(fixture.server.inventory().first?.panes.isEmpty == true)
  }

  @Test
  func fullCommandWindowBackpressuresWithoutExecutingAndRetiredRetriesFail()
    throws
  {
    let fixture = try Fixture()
    defer { fixture.stop() }
    let pane = PaneID()
    let result = try fixture.command(
      1,
      .spawn(
        pane: pane,
        launch: LaunchSpec(command: ["/bin/sleep", "60"]),
        columns: 80,
        rows: 24
      )
    )
    guard case let .spawned(pid, _, _) = result else {
      throw Failure.unexpected
    }
    let handle = fixture.handle(pane)
    for sequence in 2 ... UInt64(GuardianWire.commandWindow) {
      #expect(
        try fixture.command(
          sequence,
          .resize(pane: handle, columns: 80, rows: 24)
        ) == .resized(outputThrough: 0)
      )
    }
    let next = UInt64(GuardianWire.commandWindow + 1)
    let rejected = try fixture.command(next, .end(pane: handle))
    if case let .rejected(error) = rejected {
      #expect(error.code == .resourceLimit)
    } else {
      Issue.record("full result window admitted termination")
    }
    #expect(kill(pid, 0) == 0)
    try fixture.peer.send(
      .retire(authority: fixture.authority, through: next - 1)
    )
    #expect(try fixture.command(next, .end(pane: handle)) == .ok)
    _ = try fixture.peer.next { if case .exited = $0 { true } else { false } }
    try fixture.peer.send(
      .command(
        authority: fixture.authority,
        sequence: 1,
        body: .end(pane: handle)
      )
    )
    #expect(try fixture.peer.closed())
  }

  @Test
  func processIncarnationPreventsOldHandleFromEndingReusedPaneID() throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    let pane = PaneID()
    _ = try fixture.command(
      1,
      .spawn(
        pane: pane,
        launch: LaunchSpec(command: ["/usr/bin/true"]),
        columns: 80,
        rows: 24
      )
    )
    let old = fixture.handle(pane)
    _ = try fixture.peer.next { if case .exited = $0 { true } else { false } }
    #expect(try fixture.command(2, .forget(pane: old)) == .ok)
    let result = try fixture.command(
      3,
      .spawn(
        pane: pane,
        launch: LaunchSpec(command: ["/bin/sleep", "60"]),
        columns: 80,
        rows: 24
      )
    )
    guard case let .spawned(pid, incarnation, _) = result else {
      throw Failure.unexpected
    }
    #expect(incarnation != old.process)
    if case .rejected = try fixture.command(4, .end(pane: old)) {
    } else {
      Issue.record("old process handle admitted")
    }
    #expect(kill(pid, 0) == 0)
  }

  @Test
  func slowLaunchDoesNotBlockOtherWorkspacesAndLostWorkerRetainsLateChild()
    throws
  {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("guardian-launch-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let gate = directory.appendingPathComponent("release")
    let entered = directory.appendingPathComponent("entered")
    let wrapper = directory.appendingPathComponent("launcher")
    let real = try launcherPath().replacingOccurrences(of: "'", with: "'\"'\"'")
    try """
    #!/bin/sh
    if [ -n "$GUARDIAN_TEST_GATE" ]; then
      printf entered > "$GUARDIAN_TEST_ENTERED"
      while [ ! -e "$GUARDIAN_TEST_GATE" ]; do /bin/sleep 0.01; done
    fi
    exec '\(real)' "$@"
    """
    .write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: wrapper.path
    )
    let server = try GuardianServer(
      launcherPath: wrapper.path,
      peerRequirement: nil
    )
    defer {
      try? Data().write(to: gate)
      stop(server)
      try? FileManager.default.removeItem(at: directory)
    }
    let endpoint = server.listenAnonymously()
    let slow = try Fixture(server: server, endpoint: endpoint)
    let fast = try Fixture(server: server, endpoint: endpoint)
    let command = GuardianCommand.spawn(
      pane: PaneID(),
      launch: LaunchSpec(
        command: ["/bin/sleep", "60"],
        environment: [
          "GUARDIAN_TEST_GATE": gate.path,
          "GUARDIAN_TEST_ENTERED": entered.path,
        ]
      ),
      columns: 80,
      rows: 24
    )
    try slow.peer.send(
      .command(authority: slow.authority, sequence: 1, body: command)
    )
    try eventually { FileManager.default.fileExists(atPath: entered.path) }
    let start = ContinuousClock.now
    let other = try fast.command(
      1,
      .spawn(
        pane: PaneID(),
        launch: LaunchSpec(command: ["/bin/sleep", "60"]),
        columns: 80,
        rows: 24
      )
    )
    if case .spawned = other {
    } else {
      Issue.record("other workspace did not launch")
    }
    #expect(start.duration(to: .now) < .seconds(2))
    #expect(!FileManager.default.fileExists(atPath: gate.path))
    slow.peer.channel.cancel()
    try eventually {
      server.inventory().first { $0.authority.workspace == slow.workspace }?
        .available == false
    }
    try Data().write(to: gate)
    try eventually {
      server.inventory().first { $0.authority.workspace == slow.workspace }?
        .panes.count == 1
    }
    let retained = try #require(
      server.inventory().first { $0.authority.workspace == slow.workspace }?
        .panes.first
    )
    #expect(kill(retained.pid, 0) == 0)
    server.endWorkspace(slow.workspace)
    try eventually {
      server.inventory().first { $0.authority.workspace == slow.workspace }?
        .panes.first?
        .finished == true
    }
  }

  private enum Failure: Error { case timeout, unexpected, closed }

  private final class Peer: Sendable {
    let channel: SMXChannel
    private let received = Mutex<[GuardianEvent]>([])
    private let ended = Mutex(false)
    private let wake = DispatchSemaphore(value: 0)

    init(_ endpoint: SMXEndpoint) {
      channel = SMXChannel.connect(
        endpoint: endpoint,
        queue: DispatchQueue(label: "guardian-test-peer")
      )
      channel.activate(recordLimit: { GuardianWire.recordLimit }) {
        [weak self] event in
        guard let self else { return }
        switch event {
        case let .message(bytes):
          if let value = try? JSONDecoder()
            .decode(GuardianEvent.self, from: bytes)
          {
            self.received.withLock { $0.append(value) }
          }
        case .closed: self.ended.withLock { $0 = true }
        }
        self.wake.signal()
      }
    }
    deinit { channel.cancel() }
    func send(_ request: GuardianRequest) throws {
      channel.send(try JSONEncoder().encode(request))
    }
    func next(
      timeout: Duration = .seconds(7),
      where predicate: (GuardianEvent) -> Bool
    ) throws -> GuardianEvent {
      let deadline = ContinuousClock.now + timeout
      repeat {
        if let event = received.withLock({ values -> GuardianEvent? in
          guard let index = values.firstIndex(where: predicate) else {
            return nil
          }
          return values.remove(at: index)
        }) {
          return event
        }
        if ended.withLock({ $0 }) { throw Failure.closed }
        _ = wake.wait(timeout: .now() + .milliseconds(10))
      } while ContinuousClock.now < deadline
      throw Failure.timeout
    }
    func closed() throws -> Bool {
      try GuardianTransportTests.eventually { self.ended.withLock { $0 } }
      return true
    }
  }

  private struct Fixture {
    let server: GuardianServer
    let workspace: WorkspaceID
    let peer: Peer
    let authority: GuardianAuthority
    init() throws {
      let server = try GuardianServer(
        launcherPath: launcherPath(),
        peerRequirement: nil
      )
      try self.init(server: server, endpoint: server.listenAnonymously())
    }
    init(server: GuardianServer, endpoint: SMXEndpoint) throws {
      self.server = server
      workspace = WorkspaceID()
      let token = try server.provisionWorker(
        workspace: workspace,
        pid: getpid()
      )
      peer = Peer(endpoint)
      do {
        try peer.send(
          .hello(
            version: GuardianWire.version,
            workspace: workspace,
            token: token
          )
        )
        let welcome = try peer.next {
          if case .welcome = $0 { true } else { false }
        }
        guard case let .welcome(value) = welcome else {
          throw Failure.unexpected
        }
        authority = value
      } catch {
        GuardianTransportTests.stop(server)
        throw error
      }
    }
    func command(
      _ sequence: UInt64,
      _ body: GuardianCommand
    ) throws -> GuardianResult {
      try peer.send(
        .command(authority: authority, sequence: sequence, body: body)
      )
      let event = try peer.next {
        switch $0 {
        case let .result(id, _), let .retry(id): id == sequence
        default: false
        }
      }
      if case .retry = event {
        return .rejected(MuxError(.resourceLimit, "not admitted"))
      }
      guard case let .result(_, result) = event else {
        throw Failure.unexpected
      }
      return result
    }
    func handle(_ id: PaneID) -> GuardianPaneHandle {
      let pane = server.inventory().first!.panes.first { $0.pane == id }!
      return GuardianPaneHandle(pane: id, process: pane.process)
    }
    func output(_ pane: PaneID, count: Int) throws -> Data {
      var bytes = Data()
      while bytes.count < count {
        let event = try peer.next {
          if case let .output(id, _, _) = $0 { id.pane == pane } else { false }
        }
        guard case let .output(_, sequence, data) = event else {
          throw Failure.unexpected
        }
        bytes.append(data)
        try peer.send(
          .outputAck(
            authority: authority,
            pane: handle(pane),
            through: sequence
          )
        )
      }
      return bytes
    }
    func stop() { GuardianTransportTests.stop(server) }
  }

  private static func eventually(_ predicate: () -> Bool) throws {
    let deadline = ContinuousClock.now + .seconds(7)
    repeat {
      if predicate() { return }
      Thread.sleep(forTimeInterval: 0.01)
    } while ContinuousClock.now < deadline
    throw Failure.timeout
  }

  private func eventually(_ predicate: () -> Bool) throws {
    try Self.eventually(predicate)
  }
  private func stop(_ server: GuardianServer) { Self.stop(server) }
  private static func stop(_ server: GuardianServer) {
    let done = DispatchSemaphore(value: 0)
    server.shutdown { done.signal() }
    #expect(done.wait(timeout: .now() + 8) == .success)
  }
}
