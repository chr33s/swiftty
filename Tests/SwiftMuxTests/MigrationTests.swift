import Darwin
import Foundation
import SwiftMuxClient
import SwiftMuxGateway
@testable import SwiftMuxGuardian
import SwiftMuxProtocol
import SwiftMuxService
import SwiftMuxXPC
import Synchronization
import Testing

/// Planned replacement (spec.durability.md §7, MR1 and MR3–MR8): a real
/// guardian, an old and a candidate worker host and a gateway runtime.
/// MR2 (engine equivalence at any cut) is `CheckpointTests`.
@Suite(.serialized, .timeLimit(.minutes(3)))
struct MigrationTests {
  typealias Event = GuardianWorkerConnection.MigrationEvent
  /// Sees each migration event a host receives; `forward` delivers it.
  typealias Fault =
    @Sendable (Event, @escaping @Sendable (Event) -> Void) -> Void

  final class Rig: @unchecked Sendable {
    let workspace = WorkspaceID()
    let guardian: GuardianServer
    let endpoint: SMXEndpoint
    let control: GuardianGatewayServer
    let controlEndpoint: SMXEndpoint
    private let lock = NSLock()
    private var hosts: [WorkspaceWorkerHost] = []
    let retired = Mutex(false)
    /// Exit notices each host received: `exiting`, `exited`.
    let oldExits = Mutex((0, 0))
    let candidateExits = Mutex((0, 0))

    init(
      frozenTimeout: TimeInterval = 2,
      preparationTimeout: TimeInterval = 30,
      // Ample by default so admission never depends on the test host.
      memory: MigrationMemory = MigrationMemory(
        available: { .max },
        footprint: { _ in 0 }
      )
    ) throws {
      guardian = try GuardianServer(
        launcherPath: launcherPath(),
        peerRequirement: nil,
        migrationPreparationTimeout: preparationTimeout,
        migrationFrozenTimeout: frozenTimeout,
        migrationMemory: memory
      )
      endpoint = guardian.listenAnonymously()
      control = GuardianGatewayServer(guardian: guardian, peerRequirement: nil)
      controlEndpoint = control.listenAnonymously()
    }

    var old: WorkspaceWorkerHost { lock.withLock { hosts[0] } }
    /// The most recently admitted candidate host.
    var latestCandidate: WorkspaceWorkerHost? {
      lock.withLock { hosts.count > 1 ? hosts.last : nil }
    }

    @discardableResult
    func host(
      token: UUID,
      candidate: UUID? = nil,
      fault: Fault? = nil
    ) throws -> WorkspaceWorkerHost {
      let endpoint = endpoint
      let workspace = workspace
      let host = try WorkspaceWorkerHost(
        workspace: workspace,
        launcherPath: launcherPath(),
        peerRequirement: nil,
        connect: { queue, handlers in
          var handlers = handlers
          if let fault, let original = handlers.migration {
            handlers.migration = { event in fault(event, original) }
          }
          let isCandidate = candidate != nil
          let exiting = handlers.exiting
          let exited = handlers.exited
          handlers.exiting = { [self] handle in
            countExit(isCandidate, exited: false)
            exiting(handle)
          }
          handlers.exited = { [self] handle, status, forced in
            countExit(isCandidate, exited: true)
            exited(handle, status, forced)
          }
          return try GuardianWorkerConnection(
            channel: .connect(endpoint: endpoint, queue: queue),
            workspace: workspace,
            token: token,
            peerRequirement: nil,
            expectedGuardianPID: getpid(),
            candidateTransaction: candidate,
            handlers: handlers
          )
        },
        ready: { _ in },
        unavailable: { _ in },
        candidate: candidate,
        retired: { [self] in retired.withLock { $0 = true } }
      )
      lock.withLock { hosts.append(host) }
      return host
    }

    func countExit(_ candidate: Bool, exited: Bool) {
      func bump(_ value: inout (Int, Int)) {
        if exited { value.1 += 1 } else { value.0 += 1 }
      }
      if candidate {
        candidateExits.withLock { bump(&$0) }
      } else {
        oldExits.withLock { bump(&$0) }
      }
    }

    /// A `started` callback that admits one candidate host.
    func candidate(
      fault: Fault? = nil
    ) -> @Sendable (GuardianMigrationStatus) async throws -> Void {
      { [self] status in
        let token = try guardian.provisionMigrationCandidate(
          transaction: status.transaction,
          pid: getpid()
        )
        try host(token: token, candidate: status.transaction, fault: fault)
      }
    }

    var available: Bool { guardian.inventory().first?.available == true }

    func close() {
      for host in lock.withLock({ hosts }) { host.close() }
      control.close()
      let stopped = DispatchSemaphore(value: 0)
      guardian.shutdown { stopped.signal() }
      _ = stopped.wait(timeout: .now() + 8)
    }
  }

  struct Started {
    var runtime: GatewayRuntime
    var supervisor: GatewaySupervisor
    var client: MuxConnection
    var pane: PaneID
    var shell: Int32
  }

  private static func waitUntil(
    _ what: String = "condition",
    timeout: Duration = .seconds(15),
    _ condition: @Sendable () async throws -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(try await condition()) {
      guard ContinuousClock.now < deadline else {
        throw MuxError(.connectionLost, "timed out waiting for \(what)")
      }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  private static let columns = 40
  private static let rows = 250

  /// A running workspace with one shell, attached as controller.
  private static func start(
    _ rig: Rig,
    oldFault: Fault? = nil,
    remainOnExit: Bool = false,
    rows: Int = rows
  ) async throws -> Started {
    let token = try rig.guardian.provisionWorker(
      workspace: rig.workspace,
      pid: getpid()
    )
    try rig.host(token: token, fault: oldFault)
    let endpoint = rig.controlEndpoint
    let supervisor = try await GatewaySupervisor.connect(
      peerRequirement: nil,
      expectedGuardianPID: getpid(),
      channel: { .connect(endpoint: endpoint, queue: $0) }
    )
    let runtime = try await GatewayRuntime.start(
      supervisor: supervisor,
      peerRequirement: nil,
      pollInterval: .milliseconds(20)
    )
    try await waitUntil("empty worker") {
      await runtime.records.first?.state == .empty
    }
    let authority = try #require(rig.guardian.inventory().first?.authority)
    let bootstrap = try await supervisor.connectWorker(
      authority,
      peerRequirement: nil,
      frontend: .native
    )
    _ = try await bootstrap.execute(
      .newWorkspace(
        NewWorkspaceRequest(
          name: "moving",
          columns: columns,
          rows: rows,
          launch: shellLaunch(),
          remainOnExit: remainOnExit
        )
      )
    )
    await bootstrap.close()
    let client = try await attach(runtime, rig.workspace)
    let pane = try await show(client, rig.workspace, rows: rows)
    try await client.send(
      .text("export MARK=kept-$((40+2)); echo pid-$$-ready\r"),
      to: pane
    )
    let frame = try await client.frame(of: pane) {
      $0.lines.contains { $0.contains("-ready") && $0.hasPrefix("pid-") }
    }
    let line = try #require(
      frame.lines.first { $0.hasPrefix("pid-") && $0.contains("-ready") }
    )
    let pid = try #require(Int32(line.split(separator: "-")[1]))
    return Started(
      runtime: runtime,
      supervisor: supervisor,
      client: client,
      pane: pane,
      shell: pid
    )
  }

  private static func show(
    _ client: MuxConnection,
    _ workspace: WorkspaceID,
    rows: Int = rows
  ) async throws -> PaneID {
    try await client.attachAndShow(.id(workspace), columns: columns, rows: rows)
      .tabs[0].activePane
  }

  private static func attach(
    _ runtime: GatewayRuntime,
    _ workspace: WorkspaceID,
    capabilities: ClientCapabilities = .supported
  ) async throws -> MuxConnection {
    do {
      try await waitUntil("available workspace") {
        await runtime.records.contains {
          if case .available = $0.state { true } else { false }
        }
      }
    } catch {
      let states = await runtime.records.map { String(describing: $0.state) }
      throw MuxError(.connectionLost, "no available workspace: \(states)")
    }
    let route = try await runtime.nativeEndpoint(
      for: .id(workspace),
      role: .controller
    )
    return try await MuxConnection.connect(
      endpoint: route,
      frontend: .native,
      capabilities: capabilities
    )
  }

  /// After any outcome that leaves a worker, input and state still work.
  private static func expectUsable(
    _ rig: Rig,
    _ started: Started,
    tag: String
  ) async throws {
    let next = try await attach(started.runtime, rig.workspace)
    _ = try await show(next, rig.workspace)
    try await next.send(.text("echo \(tag)-$MARK-$$\r"), to: started.pane)
    _ = try await next.frame(of: started.pane) {
      $0.lines.contains("\(tag)-kept-42-\(started.shell)")
    }
    await next.close()
  }

  // MARK: Release

  @Test
  func releaseKeepsTheShellItsStateAndItsScreen() async throws {
    let rig = try Rig()
    defer { rig.close() }
    let started = try await Self.start(rig)
    let before = try #require(rig.guardian.inventory().first?.authority)
    let status = try await started.runtime.migrateWorkspace(
      .id(rig.workspace),
      started: rig.candidate()
    )
    #expect(
      status.outcome == .released,
      "\(String(describing: status.failure))"
    )
    #expect(status.frozenMilliseconds.map { $0 < 2000 } == true)
    try await Self.waitUntil("old worker retired") {
      rig.retired.withLock { $0 }
    }
    await started.client.close()
    // Same shell, same variables, same screen, under a newer generation.
    let after = try #require(rig.guardian.inventory().first)
    #expect(after.panes.first?.pid == started.shell)
    #expect(after.authority.generation > before.generation)
    #expect(kill(started.shell, 0) == 0)
    let next = try await Self.attach(started.runtime, rig.workspace)
    #expect(try await Self.show(next, rig.workspace) == started.pane)
    _ = try await next.frame(of: started.pane) {
      $0.lines.contains { $0.hasPrefix("pid-\(started.shell)-ready") }
    }
    await next.close()
    try await Self.expectUsable(rig, started, tag: "after")
    // MR5: the driver read and retired the outcome; the window is free.
    await #expect(throws: MuxError.self) {
      _ = try await started.supervisor.migrationStatus(status.transaction)
    }
    await started.runtime.close()
  }

  /// MR1: output keeps flowing and input keeps being typed across the cut.
  /// Every line the shell wrote appears once, in order; every write the
  /// worker acknowledged appears once, in order; nothing refused appears.
  @Test
  func replacementUnderInteractiveLoad() async throws {
    let rig = try Rig()
    defer { rig.close() }
    let started = try await Self.start(rig)
    let pane = started.pane
    try await started.client.send(
      .text(
        "stty -echo; (i=1; while [ $i -le 100 ]; do echo out-$i; "
          + "i=$((i+1)); sleep 0.01; done; echo load-done) & cat\r"
      ),
      to: pane
    )
    _ = try await started.client.frame(of: pane) { $0.lines.contains("out-3") }
    struct Typing: Sendable {
      var accepted: [Int] = []
      var ambiguous: [Int] = []
    }
    let typing = Mutex(Typing())
    let stop = Mutex(false)
    let runtime = started.runtime
    let workspace = rig.workspace
    let typist = Task {
      var client: MuxConnection? = started.client
      var n = 1
      while !stop.withLock({ $0 }), n <= 100 {
        if client == nil {
          client = try? await Self.attach(runtime, workspace)
          if let client { _ = try? await Self.show(client, workspace) }
          if client == nil { continue }
        }
        do {
          try await client!.send(.text("in-\(n)\r"), to: pane)
          typing.withLock { $0.accepted.append(n) }
          n += 1
        } catch let error as MuxError
          where error.code == .quiescing || error.code == .notAttached
          || error.code == .staleAttachment
        {
          // Refused, never written: the same line is typed again.
          if error.code != .quiescing {
            await client?.close()
            client = nil
          }
        } catch {
          // The ack was lost with the connection: never resubmitted.
          typing.withLock { $0.ambiguous.append(n) }
          n += 1
          await client?.close()
          client = nil
        }
        try? await Task.sleep(for: .milliseconds(20))
      }
      await client?.close()
    }
    try await Task.sleep(for: .milliseconds(150))
    let status = try await runtime.migrateWorkspace(
      .id(rig.workspace),
      started: rig.candidate()
    )
    #expect(
      status.outcome == .released,
      "\(String(describing: status.failure))"
    )
    try await Task.sleep(for: .milliseconds(300))
    stop.withLock { $0 = true }
    await typist.value
    let viewer = try await Self.attach(runtime, rig.workspace)
    _ = try await Self.show(viewer, rig.workspace)
    let frame = try await viewer.frame(of: pane) {
      $0.lines.contains("load-done")
    }
    let lines = frame.lines.map { $0.trimmingCharacters(in: .whitespaces) }
    let outs = lines.compactMap { line -> Int? in
      line.hasPrefix("out-") ? Int(line.dropFirst(4)) : nil
    }
    #expect(outs == Array(1 ... 100), "output lost, duplicated or reordered")
    let ins = lines.compactMap { line -> Int? in
      line.hasPrefix("in-") ? Int(line.dropFirst(3)) : nil
    }
    let typed = typing.withLock { $0 }
    #expect(!typed.accepted.isEmpty)
    #expect(ins == ins.sorted(), "input reordered")
    #expect(Set(ins).count == ins.count, "input resubmitted")
    #expect(Set(typed.accepted).isSubset(of: Set(ins)), "accepted input lost")
    #expect(
      Set(ins).isSubset(of: Set(typed.accepted + typed.ambiguous)),
      "refused input written"
    )
    #expect(kill(started.shell, 0) == 0)
    await viewer.close()
    await runtime.close()
  }

  /// MR3: input the guardian has accepted but not yet written stays with the
  /// guardian across the cut: written once, after release, not resubmitted.
  @Test(arguments: [false, true])
  func pendingWritesCrossTheCutOnce(migrating: Bool) async throws {
    let rig = try Rig()
    defer { rig.close() }
    let started = try await Self.start(rig)
    let pane = started.pane
    // Far more than the tty input queue holds while nothing reads it.
    let lines = 80
    let line = String(repeating: "x", count: 100) + "\r"
    let total = lines * 101
    try await started.client.send(
      .text("stty -echo; sleep 2; head -n \(lines) | wc -c; stty echo\r"),
      to: pane
    )
    try await Task.sleep(for: .milliseconds(200))
    for _ in 0 ..< lines / 80 {
      try await started.client.send(
        .text(String(repeating: line, count: 80)),
        to: pane
      )
    }
    // The terminal holds only part of it; the guardian holds the rest.
    try await Self.waitUntil("guardian backlog") {
      rig.guardian.pendingInputBytesForTesting(rig.workspace) > 0
    }
    if migrating {
      let status = try await started.runtime.migrateWorkspace(
        .id(rig.workspace),
        started: rig.candidate()
      )
      #expect(
        status.outcome == .released,
        "\(String(describing: status.failure))"
      )
    }
    await started.client.close()
    let viewer = try await Self.attach(started.runtime, rig.workspace)
    _ = try await Self.show(viewer, rig.workspace)
    _ = try await viewer.frame(of: pane) {
      $0.lines.contains {
        $0.trimmingCharacters(in: .whitespaces) == "\(total)"
      }
    }
    await viewer.close()
    await started.runtime.close()
  }

  /// MR3: a paste open at the cut is never resubmitted. Clients re-attach to
  /// the candidate, so paste bytes still unwritten at release are cancelled
  /// as on any detach; whatever reached the terminal appears once,
  /// contiguous and in order, and ordinary input works afterwards. The
  /// control keeps its attachment and receives every line.
  @Test(arguments: [false, true])
  func anOpenPasteAtTheCutIsNeverResubmitted(migrating: Bool) async throws {
    let rig = try Rig()
    defer { rig.close() }
    let started = try await Self.start(rig)
    let pane = started.pane
    let file = NSTemporaryDirectory() + "migration-paste-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: file) }
    try await started.client.send(
      // The writer backs up while nothing reads, so the paste is open at
      // the cut.
      .text("stty -echo; sleep 1; cat > \(file)\r"),
      to: pane
    )
    try await Task.sleep(for: .milliseconds(200))
    let count = 1_500
    let text =
      (0 ..< count)
      .map { String(format: "p%05d-", $0) + String(repeating: "y", count: 90) }
      .joined(separator: "\r") + "\r"
    let client = started.client
    let pasting = Task { try await client.paste(text, to: pane) }
    try await Task.sleep(for: .milliseconds(20))
    if migrating {
      let status = try await started.runtime.migrateWorkspace(
        .id(rig.workspace),
        started: rig.candidate()
      )
      #expect(
        status.outcome == .released,
        "\(String(describing: status.failure))"
      )
    }
    let state = try? await pasting.value
    let next: MuxConnection
    if migrating {
      await client.close()
      next = try await Self.attach(started.runtime, rig.workspace)
      _ = try await Self.show(next, rig.workspace)
    } else {
      next = client
    }
    // End cat at a line start, then summarize: lines written, defects.
    try await next.send(.text("\r\u{4}"), to: pane)
    try await next.send(
      .text(
        "stty echo; awk 'NF==0{next} {if(short)bad++; n=substr($0,2,5)+0; "
          + "if(n!=want)bad++; want=n+1; short=(length($0)!=97)} "
          + "END{printf \"paste=%d:%d\\n\", want, bad}' \(file)\r"
      ),
      to: pane
    )
    let frame = try await next.frame(of: pane) {
      $0.lines.contains { $0.contains("paste=") }
    }
    let line = try #require(frame.lines.first { $0.contains("paste=") })
    let summary = line[line.range(of: "paste=")!.upperBound...]
    let fields = summary.split(separator: ":")
      .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    #expect(fields.count == 2 && fields[1] == 0, "\(summary)")
    #expect(fields.first.map { $0 > 0 } == true, "\(summary)")
    if !migrating {
      #expect(state == .completed)
      #expect(fields.first == count, "\(summary)")
    }
    try await next.send(.text("echo typed-$MARK\r"), to: pane)
    _ = try await next.frame(of: pane) { $0.lines.contains("typed-kept-42") }
    await next.close()
    await started.runtime.close()
  }

  /// The spec's preferred path (§6): a frontend that stays connected
  /// continues on the candidate. The gateway relay resumes its lease, so
  /// its open paste and queued input are written in full, and it keeps
  /// typing on the same connection and server instance.
  @Test
  func aLiveFrontendContinuesOnTheCandidate() async throws {
    let rig = try Rig()
    defer { rig.close() }
    let started = try await Self.start(rig)
    let client = started.client
    let pane = started.pane
    let server = await client.welcome?.server
    let file = NSTemporaryDirectory() + "migration-live-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: file) }
    try await client.send(
      .text("stty -echo; sleep 1; cat > \(file)\r"),
      to: pane
    )
    try await Task.sleep(for: .milliseconds(200))
    let count = 1_500
    let text =
      (0 ..< count)
      .map { String(format: "p%05d-", $0) + String(repeating: "y", count: 90) }
      .joined(separator: "\r") + "\r"
    let state = try await client.paste(text, to: pane)
    #expect(state == .completed)
    #expect(rig.guardian.pendingInputBytesForTesting(rig.workspace) > 0)
    let status = try await started.runtime.migrateWorkspace(
      .id(rig.workspace),
      started: rig.candidate()
    )
    #expect(
      status.outcome == .released,
      "\(String(describing: status.failure))"
    )
    /// Input refused while the relay moves is never written; send again.
    func type(_ text: String) async throws {
      let deadline = ContinuousClock.now + .seconds(10)
      while true {
        do {
          try await client.send(.text(text), to: pane)
          return
        } catch let error as MuxError
          where error.code == .quiescing && ContinuousClock.now < deadline
        { try await Task.sleep(for: .milliseconds(20)) }
      }
    }
    try await type("\r\u{4}")
    try await type(
      "stty echo; awk 'NF==0{next} {if(short)bad++; n=substr($0,2,5)+0; "
        + "if(n!=want)bad++; want=n+1; short=(length($0)!=97)} "
        + "END{printf \"paste=%d:%d\\n\", want, bad}' \(file)\r"
    )
    let frame = try await client.frame(of: pane) {
      $0.lines.contains { $0.contains("paste=") }
    }
    let line = try #require(frame.lines.first { $0.contains("paste=") })
    #expect(line.hasSuffix("paste=\(count):0"), "\(line)")
    try await type("echo same-$MARK-$$\r")
    _ = try await client.frame(of: pane) {
      $0.lines.contains("same-kept-42-\(started.shell)")
    }
    #expect(await client.welcome?.server == server)
    #expect(rig.retired.withLock { $0 })
    await client.close()
    await started.runtime.close()
  }

  // MARK: Candidate failure (MR4)

  @Test
  func candidateLossBeforeReleaseResumesTheOldWorker() async throws {
    let rig = try Rig()
    defer { rig.close() }
    let started = try await Self.start(rig)
    let status = try await started.runtime.migrateWorkspace(
      .id(rig.workspace),
      started: { [rig] status in
        let token = try rig.guardian.provisionMigrationCandidate(
          transaction: status.transaction,
          pid: getpid()
        )
        let host = try rig.host(token: token, candidate: status.transaction)
        _ = Task {
          while !(try rig.guardian.migrationStatusForTesting(status.transaction)
            .candidateConnected)
          { try await Task.sleep(for: .milliseconds(5)) }
          host.close()
        }
      }
    )
    #expect(status.outcome == .resumed)
    #expect(!rig.retired.withLock { $0 })
    #expect(kill(started.shell, 0) == 0)
    await started.client.close()
    try await Self.expectUsable(rig, started, tag: "resumed")
    await started.runtime.close()
  }

  /// The riskiest point: assigned, gates still closed, candidate gone.
  @Test
  func candidateCrashAfterAssignmentBeforeReleaseResumes() async throws {
    let rig = try Rig()
    defer { rig.close() }
    let started = try await Self.start(rig)
    let doomed = Mutex<WorkspaceWorkerHost?>(nil)
    let status = try await started.runtime.migrateWorkspace(
      .id(rig.workspace),
      started: { [rig] status in
        let token = try rig.guardian.provisionMigrationCandidate(
          transaction: status.transaction,
          pid: getpid()
        )
        let host = try rig.host(token: token, candidate: status.transaction) {
          event,
          forward in
          if case .activate = event {
            DispatchQueue.global().async { doomed.withLock { $0 }?.close() }
            return
          }
          forward(event)
        }
        doomed.withLock { $0 = host }
      }
    )
    #expect(status.outcome == .resumed)
    #expect(!rig.retired.withLock { $0 })
    await started.client.close()
    try await Self.expectUsable(rig, started, tag: "unassigned")
    await started.runtime.close()
  }

  @Test
  func candidateHangWhileFrozenAbortsAtTheDeadline() async throws {
    let rig = try Rig(frozenTimeout: 0.5)
    defer { rig.close() }
    let started = try await Self.start(rig)
    let begun = ContinuousClock.now
    let status = try await started.runtime.migrateWorkspace(
      .id(rig.workspace),
      started: rig.candidate { event, forward in
        if case .importChunk = event { return }  // Never imports.
        forward(event)
      }
    )
    #expect(status.outcome == .resumed)
    #expect(status.failure?.message.contains("deadline") == true)
    // One deadline, not extended by the hang.
    #expect(ContinuousClock.now - begun < .seconds(3))
    await started.client.close()
    try await Self.expectUsable(rig, started, tag: "hung")
    await started.runtime.close()
  }

  @Test
  func aCandidateThatNeverConnectsTimesOutInPreparation() async throws {
    let rig = try Rig(preparationTimeout: 0.3)
    defer { rig.close() }
    let started = try await Self.start(rig)
    let before = try #require(rig.guardian.inventory().first?.authority)
    let status = try await started.runtime.migrateWorkspace(
      .id(rig.workspace),
      started: { _ in }
    )
    #expect(status.outcome == .resumed)
    #expect(status.failure?.message.contains("preparation") == true)
    // Never frozen: the old worker keeps its authority and its clients.
    #expect(rig.guardian.inventory().first?.authority == before)
    try await started.client.send(.text("echo prep-$MARK\r"), to: started.pane)
    _ = try await started.client.frame(of: started.pane) {
      $0.lines.contains("prep-kept-42")
    }
    await started.client.close()
    await started.runtime.close()
  }

  @Test
  func anExpiredFrozenDeadlineAbortsWithoutRelease() async throws {
    // Shorter than any transfer: release must be refused even if the timer
    // is delivered late.
    let rig = try Rig(frozenTimeout: 0.0001)
    defer { rig.close() }
    let started = try await Self.start(rig)
    let status = try await started.runtime.migrateWorkspace(
      .id(rig.workspace),
      started: rig.candidate()
    )
    #expect(status.outcome == .resumed)
    #expect(status.failure?.message.contains("deadline") == true)
    #expect(!rig.retired.withLock { $0 })
    #expect(kill(started.shell, 0) == 0)
    await started.client.close()
    try await Self.expectUsable(rig, started, tag: "still")
    await started.runtime.close()
  }

  /// After release there is no rollback: a lost candidate leaves the
  /// workspace unavailable with its processes retained.
  @Test
  func candidateLossAfterReleaseLeavesProcessesRetained() async throws {
    let rig = try Rig()
    defer { rig.close() }
    let started = try await Self.start(rig)
    let candidate = Mutex<WorkspaceWorkerHost?>(nil)
    let status = try await started.runtime.migrateWorkspace(
      .id(rig.workspace),
      started: { [rig] status in
        let token = try rig.guardian.provisionMigrationCandidate(
          transaction: status.transaction,
          pid: getpid()
        )
        let host = try rig.host(token: token, candidate: status.transaction)
        candidate.withLock { $0 = host }
      }
    )
    #expect(status.outcome == .released)
    try await Self.waitUntil("candidate published") { rig.available }
    candidate.withLock { $0 }?.close()
    try await Self.waitUntil("unavailable") { !rig.available }
    #expect(rig.guardian.inventory().first?.panes.first?.pid == started.shell)
    #expect(kill(started.shell, 0) == 0)
    await started.client.close()
    await started.runtime.close()
  }

  // MARK: Gateway and transitions (MR5)

  /// A gateway that disappears during the cut invalidates it: the guardian
  /// aborts on its own and retains the outcome for the next gateway.
  @Test
  func gatewayLossDuringTheCutAbortsAndRetainsTheOutcome() async throws {
    let rig = try Rig()
    defer { rig.close() }
    let started = try await Self.start(rig)
    let authority = try #require(rig.guardian.inventory().first?.authority)
    let begun = try await started.supervisor.beginMigration(authority)
    // One transaction at a time.
    await #expect(throws: MuxError.self) {
      _ = try await started.supervisor.beginMigration(authority)
    }
    try await rig.candidate()(begun)
    try await Self.waitUntil("candidate admitted") {
      try rig.guardian.migrationStatusForTesting(begun.transaction)
        .candidateConnected
    }
    _ = try await started.supervisor.freezeMigration(begun.transaction)
    // The gateway disappears mid-cut; the guardian decides alone.
    await started.client.close()
    await started.runtime.close()
    await started.supervisor.close()
    try await Self.waitUntil("finished") {
      try rig.guardian.migrationStatusForTesting(begun.transaction).phase
        == .finished
    }
    let (supervisor, runtime) = try await Self.replacementGateway(rig)
    let queried = try await supervisor.migrationStatus(begun.transaction)
    #expect(
      queried.outcome == .resumed,
      "\(String(describing: queried.failure))"
    )
    #expect(queried.failure?.message.contains("gateway") == true)
    #expect(!rig.retired.withLock { $0 })
    // Replayed transitions report the retained outcome unchanged.
    #expect(try await supervisor.freezeMigration(begun.transaction) == queried)
    #expect(try await supervisor.cancelMigration(begun.transaction) == queried)
    // Acknowledgement retires it exactly once.
    #expect(
      try await supervisor.acknowledgeMigration(begun.transaction) == queried
    )
    await #expect(throws: MuxError.self) {
      _ = try await supervisor.acknowledgeMigration(begun.transaction)
    }
    var moved = started
    moved.runtime = runtime
    moved.supervisor = supervisor
    try await Self.expectUsable(rig, moved, tag: "orphaned")
    await runtime.close()
  }

  /// After release the candidate owns the workspace whether or not the
  /// gateway that drove it survives; a replacement gateway discovers it.
  @Test
  func gatewayLossAfterReleaseKeepsTheCandidate() async throws {
    let rig = try Rig()
    defer { rig.close() }
    let started = try await Self.start(rig)
    let status = try await started.runtime.migrateWorkspace(
      .id(rig.workspace),
      started: rig.candidate()
    )
    #expect(status.outcome == .released)
    await started.client.close()
    await started.runtime.close()
    await started.supervisor.close()
    let (supervisor, runtime) = try await Self.replacementGateway(rig)
    var moved = started
    moved.runtime = runtime
    moved.supervisor = supervisor
    try await Self.expectUsable(rig, moved, tag: "rediscovered")
    #expect(rig.retired.withLock { $0 })
    await runtime.close()
  }

  /// Rollback is acknowledged, never assumed: an old worker that does not
  /// confirm resumption within 500 ms leaves the workspace unavailable.
  @Test
  func anUnacknowledgedResumptionIsUnavailable() async throws {
    let rig = try Rig(frozenTimeout: 0.3)
    defer { rig.close() }
    let started = try await Self.start(rig) { event, forward in
      if case .aborted = event { return }  // Never resumes.
      forward(event)
    }
    let status = try await started.runtime.migrateWorkspace(
      .id(rig.workspace),
      started: rig.candidate { event, forward in
        if case .importChunk = event { return }  // Forces the deadline.
        forward(event)
      }
    )
    #expect(status.outcome == .unavailable)
    #expect(!rig.available)
    #expect(kill(started.shell, 0) == 0)
    await started.client.close()
    await started.runtime.close()
  }

  private static func replacementGateway(
    _ rig: Rig
  ) async throws -> (GatewaySupervisor, GatewayRuntime) {
    let endpoint = rig.controlEndpoint
    let supervisor = try await GatewaySupervisor.connect(
      peerRequirement: nil,
      expectedGuardianPID: getpid(),
      channel: { .connect(endpoint: endpoint, queue: $0) }
    )
    let runtime = try await GatewayRuntime.start(
      supervisor: supervisor,
      peerRequirement: nil,
      pollInterval: .milliseconds(20)
    )
    return (supervisor, runtime)
  }

  // MARK: Races (MR6)

  @Test
  func endBeforeReleaseWinsAndReopensNothing() async throws {
    let rig = try Rig()
    defer { rig.close() }
    let started = try await Self.start(rig)
    let workspace = rig.workspace
    let status = try await started.runtime.migrateWorkspace(
      .id(rig.workspace),
      started: rig.candidate { [rig] event, forward in
        if case .importChunk = event {
          rig.guardian.endWorkspace(workspace)
          return
        }
        forward(event)
      }
    )
    #expect(status.outcome == .ended)
    #expect(!rig.retired.withLock { $0 })
    try await Self.waitUntil("shell ended") { kill(started.shell, 0) != 0 }
    await started.client.close()
    await started.runtime.close()
  }

  /// A child that exits while frozen is reported once, to the owner the
  /// release selected.
  @Test
  func aChildExitWhileFrozenReachesTheCandidateOnce() async throws {
    let rig = try Rig()
    defer { rig.close() }
    let started = try await Self.start(rig)
    let shell = started.shell
    // Serial, so delayed chunks keep their order.
    let delay = DispatchQueue(label: "migration.test.delay")
    let status = try await started.runtime.migrateWorkspace(
      .id(rig.workspace),
      started: rig.candidate { event, forward in
        if case .importChunk = event {
          kill(shell, SIGKILL)
          delay.asyncAfter(deadline: .now() + 0.3) { forward(event) }
          return
        }
        delay.async { forward(event) }
      }
    )
    #expect(
      status.outcome == .released,
      "\(String(describing: status.failure))"
    )
    // The candidate closes the exited pane, which ends the workspace.
    try await Self.waitUntil("pane exit delivered") {
      rig.guardian.inventory().first.map { $0.panes.isEmpty } ?? true
    }
    // Held through the cut, then delivered once, to the new owner only.
    #expect(rig.candidateExits.withLock { $0 } == (1, 1))
    #expect(rig.oldExits.withLock { $0 } == (0, 0))
    await started.client.close()
    await started.runtime.close()
  }

  // MARK: Refusal (MR7)

  @Test(arguments: ["corrupt", "schema", "oversized"])
  func aBadCheckpointIsRefusedAndTheOldWorkerResumes(kind: String) async throws
  {
    let rig = try Rig()
    defer { rig.close() }
    let started = try await Self.start(rig)
    let status = try await started.runtime.migrateWorkspace(
      .id(rig.workspace),
      started: rig.candidate { event, forward in
        guard case let .importChunk(id, offset, total, bytes) = event else {
          return forward(event)
        }
        switch kind {
        case "corrupt":
          var bytes = bytes
          bytes[bytes.count / 2] ^= 0x5A
          forward(.importChunk(id, offset: offset, total: total, bytes: bytes))
        case "schema":
          var object =
            (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
            ?? [:]
          object["format"] = 99
          let data =
            (try? JSONSerialization.data(withJSONObject: object)) ?? bytes
          forward(.importChunk(id, offset: 0, total: data.count, bytes: data))
        default:
          forward(
            .importChunk(
              id,
              offset: offset,
              total: GuardianMigrationWire.checkpointLimit + 1,
              bytes: bytes
            )
          )
        }
      }
    )
    #expect(status.outcome == .resumed, "\(kind)")
    #expect(!rig.retired.withLock { $0 })
    await started.client.close()
    try await Self.expectUsable(rig, started, tag: kind)
    await started.runtime.close()
  }

  /// MR7: preparation admits the transaction only with room for a second
  /// worker and the checkpoint; refusal starts nothing.
  @Test
  func insufficientMemoryRefusesBeforeAnythingStarts() async throws {
    let rig = try Rig(
      memory: MigrationMemory(
        available: { 32 << 20 },
        footprint: { _ in 200 << 20 }
      )
    )
    defer { rig.close() }
    let started = try await Self.start(rig)
    let before = try #require(rig.guardian.inventory().first?.authority)
    let launched = Mutex(false)
    do {
      _ = try await started.runtime.migrateWorkspace(
        .id(rig.workspace),
        started: { _ in launched.withLock { $0 = true } }
      )
      Issue.record("migration began without memory")
    } catch let error as MuxError {
      #expect(error.code == .resourceLimit)
      #expect(error.message.contains("memory"), "\(error)")
    }
    #expect(!launched.withLock { $0 })
    #expect(rig.guardian.inventory().first?.authority == before)
    try await started.client.send(.text("echo roomy-$MARK\r"), to: started.pane)
    _ = try await started.client.frame(of: started.pane) {
      $0.lines.contains("roomy-kept-42")
    }
    #expect(
      MigrationMemory.system.available() > 0
        && MigrationMemory.system.footprint(getpid()) > 0
    )
    await started.client.close()
    await started.runtime.close()
  }

  /// MR3: replies the program does not read fill the writer and stall the
  /// parser, so no cut can form: the transaction aborts by its deadline
  /// rather than deadlocking, and the old worker carries on.
  @Test
  func aReplyPressureStallAtTheCutAbortsByTheDeadline() async throws {
    let rig = try Rig(frozenTimeout: 0.5)
    defer { rig.close() }
    let started = try await Self.start(rig, rows: 12)
    let pane = started.pane
    try await started.client.send(
      .text(
        "sh -c 'echo flooder-$$-up; stty raw -echo; i=0; "
          + "while [ $i -lt 20000 ]; do printf \"\\033[c\"; i=$((i+1)); done; "
          + "exec sleep 60'\r"
      ),
      to: pane
    )
    let frame = try await started.client.frame(of: pane) {
      $0.lines.contains { $0.hasPrefix("flooder-") && $0.hasSuffix("-up") }
    }
    let line = try #require(
      frame.lines.first { $0.hasPrefix("flooder-") && $0.hasSuffix("-up") }
    )
    let flooder = try #require(Int32(line.split(separator: "-")[1]))
    defer { kill(flooder, SIGKILL) }
    // Let the reply backlog build.
    try await Self.waitUntil("reply pressure") {
      rig.guardian.pendingReplyBytesForTesting(rig.workspace) > 0
    }
    let begun = ContinuousClock.now
    let status = try await started.runtime.migrateWorkspace(
      .id(rig.workspace),
      started: rig.candidate()
    )
    #expect(ContinuousClock.now - begun < .seconds(3))
    #expect(status.outcome == .resumed, "\(String(describing: status.failure))")
    // The old worker still owns and serves the workspace under backpressure.
    #expect(rig.available)
    #expect(!rig.retired.withLock { $0 })
    await started.client.close()
    let next = try await Self.attach(started.runtime, rig.workspace)
    #expect(try await Self.show(next, rig.workspace, rows: 12) == pane)
    kill(flooder, SIGKILL)
    await next.close()
    await started.runtime.close()
  }

  /// MR6: a clipboard read the app never answers is settled at the cut by
  /// the existing busy answer, written once, and never answered again.
  @Test
  func pendingClipboardRequestsAreAnsweredOnceAtTheCut() async throws {
    let rig = try Rig()
    defer { rig.close() }
    let started = try await Self.start(rig)
    await started.client.close()
    let pane = started.pane
    let app = try await Self.attach(
      started.runtime,
      rig.workspace,
      capabilities: ClientCapabilities.supported.union(.clipboardRequests)
    )
    _ = try await Self.show(app, rig.workspace)
    try await app.send(
      .text(
        "stty raw -echo; printf '\\033]5522;type=read:id=r1;dGV4dC9wbGFpbg==\\007'; exec cat -v\r"
      ),
      to: pane
    )
    let deadline = ContinuousClock.now + .seconds(10)
    var asked: MuxClipboardRead?
    while asked == nil, ContinuousClock.now < deadline {
      if case let .clipboardRead(request) = try await app.nextEvent(
        timeout: .seconds(1)
      ) {
        asked = request
      }
    }
    let request = try #require(asked, "the app was never asked")
    // The app holds the request; the workspace moves anyway.
    let status = try await started.runtime.migrateWorkspace(
      .id(rig.workspace),
      started: rig.candidate()
    )
    #expect(
      status.outcome == .released,
      "\(String(describing: status.failure))"
    )
    await app.close()
    let next = try await Self.attach(
      started.runtime,
      rig.workspace,
      capabilities: ClientCapabilities.supported.union(.clipboardRequests)
    )
    _ = try await Self.show(next, rig.workspace)
    _ = try await next.frame(of: pane) {
      $0.lines.joined().contains("type=read:status=EBUSY:id=r1")
    }
    // A late answer for the settled token has no effect.
    _ = try? await next.execute(
      .clipboardReadResult(
        pane: pane,
        token: request.token,
        .success(
          available: ["text/plain"],
          contents: [
            MuxClipboardContent(mime: "text/plain", data: Data("x".utf8))
          ],
          remember: false
        )
      )
    )
    try await next.send(.text("after"), to: pane)
    let later = try await next.frame(of: pane) {
      $0.lines.joined().contains("after")
    }
    let text = later.lines.joined()
    // One answer; the request itself also appears in the echoed command.
    #expect(text.components(separatedBy: "status=").count == 2, "\(text)")
    #expect(!text.contains("status=DATA"), "\(text)")
    await next.close()
    await started.runtime.close()
  }

  /// After an update selects a new worker build, live workspaces still on
  /// older builds move one at a time (§5.2, UA4 with Capability B).
  @Test
  func anUpdateUpgradesLiveWorkspacesThroughPlannedReplacement() async throws {
    let rig = try Rig()
    defer { rig.close() }
    let started = try await Self.start(rig)
    let results = await started.runtime.upgradeWorkspaces(
      to: "two",
      started: rig.candidate()
    )
    #expect(results.count == 1)
    #expect((try? results[rig.workspace]?.get()) == .released)
    try await Self.waitUntil("old worker retired") {
      rig.retired.withLock { $0 }
    }
    await started.client.close()
    try await Self.expectUsable(rig, started, tag: "upgraded")
    await started.runtime.close()
  }

  // MARK: Model suite access

  static func startForModel(
    _ rig: Rig,
    oldFault: Fault?
  ) async throws -> Started { try await start(rig, oldFault: oldFault) }

  static func expectUsableForModel(
    _ rig: Rig,
    _ started: Started,
    tag: String
  ) async throws { try await expectUsable(rig, started, tag: tag) }

  static func waitFor(
    _ what: String,
    _ condition: @Sendable () async throws -> Bool
  ) async throws { try await waitUntil(what, condition) }

  // MARK: Review regressions

  /// Input refused while a relay moves is never written; send again.
  private static func type(
    _ client: MuxConnection,
    _ text: String,
    to pane: PaneID
  ) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while true {
      do {
        try await client.send(.text(text), to: pane)
        return
      } catch let error as MuxError
        where error.code == .quiescing && ContinuousClock.now < deadline
      { try await Task.sleep(for: .milliseconds(20)) }
    }
  }

  /// One progress loop per owner: the old worker's pending probe must not
  /// start a second loop on the candidate (which would end it).
  @Test
  func theCandidateKeepsOneProgressLoopAfterRelease() async throws {
    let rig = try Rig()
    defer { rig.close() }
    let started = try await Self.start(rig)
    let status = try await started.runtime.migrateWorkspace(
      .id(rig.workspace),
      started: rig.candidate()
    )
    #expect(status.outcome == .released)
    // One loop probes about once a second; two would roughly double it.
    let before = rig.guardian.probesIssuedForTesting(rig.workspace)
    try await Task.sleep(for: .seconds(4))
    let issued = rig.guardian.probesIssuedForTesting(rig.workspace) - before
    #expect(issued <= 5, "\(issued) probes in 4 s")
    #expect(
      rig.available,
      "\(String(describing: rig.guardian.inventory().first?.lossReason))"
    )
    try await Self.type(started.client, "echo probed-$MARK\r", to: started.pane)
    _ = try await started.client.frame(of: started.pane) {
      $0.lines.contains("probed-kept-42")
    }
    await started.client.close()
    await started.runtime.close()
  }

  /// An aborted replacement re-pins the route under the fresh authority; a
  /// connected frontend keeps its connection to the same worker.
  @Test
  func aFrontendStaysConnectedThroughAnAbort() async throws {
    let rig = try Rig(frozenTimeout: 0.4)
    defer { rig.close() }
    let started = try await Self.start(rig)
    let status = try await started.runtime.migrateWorkspace(
      .id(rig.workspace),
      started: rig.candidate { event, forward in
        if case .importChunk = event { return }
        forward(event)
      }
    )
    #expect(status.outcome == .resumed)
    // Discovery reconciles routes; the relay must survive it.
    try await Task.sleep(for: .milliseconds(500))
    try await Self.type(
      started.client,
      "echo through-$MARK\r",
      to: started.pane
    )
    _ = try await started.client.frame(of: started.pane) {
      $0.lines.contains("through-kept-42")
    }
    await started.client.close()
    await started.runtime.close()
  }

  /// A child that exits while frozen keeps its final output: the drain
  /// waits for the paused consumer instead of closing the PTY.
  @Test
  func finalOutputOfAChildThatExitsWhileFrozenIsKept() async throws {
    let rig = try Rig(frozenTimeout: 3)
    defer { rig.close() }
    let started = try await Self.start(rig, remainOnExit: true)
    let delay = DispatchQueue(label: "migration.test.final-output")
    try await started.client.send(
      .text("exec sh -c 'sleep 0.4; echo final-$((40+3)); exit 3'\r"),
      to: started.pane
    )
    let status = try await started.runtime.migrateWorkspace(
      .id(rig.workspace),
      started: rig.candidate { event, forward in
        // Hold the cut past the child's exit and the 1 s drain bound.
        if case .importChunk = event {
          delay.asyncAfter(deadline: .now() + 1.8) { forward(event) }
          return
        }
        delay.async { forward(event) }
      }
    )
    #expect(
      status.outcome == .released,
      "\(String(describing: status.failure))"
    )
    await started.client.close()
    let next = try await Self.attach(started.runtime, rig.workspace)
    _ = try await Self.show(next, rig.workspace)
    _ = try await next.frame(of: started.pane) { $0.lines.contains("final-43") }
    await next.close()
    await started.runtime.close()
  }

  /// Cleanup of an exited, retained pane (lease release cancels its input)
  /// is not a transport failure.
  @Test
  func cleanupOfAnExitedPaneKeepsTheWorker() async throws {
    let rig = try Rig()
    defer { rig.close() }
    let started = try await Self.start(rig, remainOnExit: true)
    try await started.client.send(.text("exit 7\r"), to: started.pane)
    try await Self.waitUntil("pane exit") {
      rig.guardian.inventory().first?.panes.first?.finished == true
    }
    // Releasing the lease cancels the pane's input.
    await started.client.close()
    try await Task.sleep(for: .milliseconds(500))
    #expect(
      rig.available,
      "\(String(describing: rig.guardian.inventory().first?.lossReason))"
    )
    let next = try await Self.attach(started.runtime, rig.workspace)
    _ = try await Self.show(next, rig.workspace)
    await next.close()
    #expect(rig.available)
    await started.runtime.close()
  }

  /// A post-update upgrade started before discovery finishes still moves
  /// the workspace.
  @Test
  func anUpgradeStartedBeforeDiscoveryStillMovesWorkspaces() async throws {
    let rig = try Rig()
    defer { rig.close() }
    let started = try await Self.start(rig)
    await started.client.close()
    await started.runtime.close()
    await started.supervisor.close()
    let (_, runtime) = try await Self.replacementGateway(rig)
    // Immediately: discovery is still opening the workspace.
    let results = await runtime.upgradeWorkspaces(
      to: "two",
      started: rig.candidate()
    )
    #expect((try? results[rig.workspace]?.get()) == .released)
    await runtime.close()
  }

  /// Installer maintenance refuses new workspaces at the gateway.
  @Test
  func maintenanceRefusesCreation() async throws {
    let rig = try Rig()
    defer { rig.close() }
    let started = try await Self.start(rig)
    await started.runtime.setMaintenance(true)
    await #expect(throws: MuxError.self) {
      _ = try await started.runtime.createWorkspace(
        WorkspaceID(),
        request: NewWorkspaceRequest(launch: shellLaunch())
      )
    }
    await started.runtime.setMaintenance(false)
    await started.client.close()
    await started.runtime.close()
  }

  // MARK: Old-worker death (MR8)

  @Test
  func oldWorkerDeathWhileFrozenPromotesNothing() async throws {
    let rig = try Rig()
    defer { rig.close() }
    let started = try await Self.start(rig)
    let old = rig.old
    let status = try await started.runtime.migrateWorkspace(
      .id(rig.workspace),
      started: rig.candidate { event, forward in
        if case .importChunk = event {
          DispatchQueue.global().async { old.close() }
          return
        }
        forward(event)
      }
    )
    #expect(status.outcome == .unavailable)
    #expect(!rig.available)
    // No unsupported recovery: the shell is retained, not adopted or ended.
    #expect(rig.guardian.inventory().first?.panes.first?.pid == started.shell)
    #expect(kill(started.shell, 0) == 0)
    await started.client.close()
    await started.runtime.close()
  }
}
