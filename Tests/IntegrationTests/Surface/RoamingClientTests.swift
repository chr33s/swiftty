import Foundation
@testable import ScreenProtocol
import SessionCore
import Synchronization
import SwifttyCore
import Testing

@testable import TerminalSurface

struct RoamingClientTests {
  @Test
  func fakeHostReleasesClosedConnectionsAcrossReattachments() async throws {
    let f = try RoamingFixture()
    defer { Task { await f.client.close() } }
    try #require(try await f.startActive())
    for count in 2 ... 4 {
      await f.host.severCurrent()
      try #require(await eventually { await f.host.attachCount == count })
      try #require(await f.waitFor(.active))
    }
    #expect(await eventually { await f.host.links.count == 1 })
    await f.client.close()
    #expect(await eventually { await f.host.links.isEmpty })
    #expect(await f.host.currentEpoch == nil)
  }

  @Test
  func fakeHostDoesNotRetainItselfThroughAnAcceptedConnection() async throws {
    var host: FakeHost? = try FakeHost()
    weak let observed = host
    let (client, server) = InMemoryRSTConnection.pair()
    defer { client.close() }
    await host?.accept(server)
    host = nil
    #expect(await eventually { observed == nil })
    #expect(await eventually { client.isClosed })
  }

  @Test(arguments: [UInt64(2), UInt64.max])
  func futureInputAcknowledgmentPreservesInputForReattachment(
    _ sequence: UInt64
  ) async throws {
    let f = try RoamingFixture()
    defer {
      Task {
        await f.client.close();
        await f.connector.release()
      }
    }
    try #require(try await f.startActive())
    let epoch = try #require(await f.host.currentEpoch)
    await f.host.blackHoleCurrent()
    await f.connector.block()
    #expect(await f.client.submit(.text("retained")) == .accepted(sequence: 1))
    let bytes = try ControlRecord.encode(
      .inputAck(epoch: epoch, sequence: sequence)
    )
    let callback = await f.client.handleControlForTesting(bytes)
    #expect(callback.closed)
    #expect(await f.client.status.lastFailure == .protocolViolation)
    #expect(await f.client.status.pendingInputCount == 1)
    await f.host.severCurrent()
    await f.connector.release()
    try #require(await eventually { await f.host.attachCount == 2 })
    try #require(await f.waitFor(.active))
    #expect(await eventually { await f.client.status.pendingInputCount == 0 })
    #expect(await f.host.applied == [1])
    #expect(await eventually { f.sink.lastLine == "retained" })
    let retry = await f.host.received.filter { $0.epoch == epoch + 1 }
    #expect(retry.count == 1)
    #expect(retry.first?.sequence == 1)
    #expect(retry.first?.operation == .committedText("retained"))
    await f.client.close()
  }

  @Test
  func zeroAndDuplicateInputAcknowledgmentsRemainValid() async throws {
    let f = try RoamingFixture()
    defer { Task { await f.client.close() } }
    try #require(try await f.startActive())
    let epoch = try #require(await f.host.currentEpoch)
    await f.host.set(withholdAcks: true)
    #expect(await f.client.submit(.text("first")) == .accepted(sequence: 1))
    try #require(await eventually { await f.host.applied == [1] })
    _ = await f.client.handleControlForTesting(
      try ControlRecord.encode(.inputAck(epoch: epoch, sequence: 0))
    )
    #expect(await f.client.status.pendingInputCount == 1)
    for _ in 0 ..< 2 {
      let callback = await f.client.handleControlForTesting(
        try ControlRecord.encode(.inputAck(epoch: epoch, sequence: 1))
      )
      #expect(!callback.closed)
      #expect(await f.client.state == .active)
      #expect(await f.client.status.pendingInputCount == 0)
    }
    await f.host.set(withholdAcks: false)
    #expect(await f.client.submit(.text("next")) == .accepted(sequence: 2))
    #expect(await eventually { await f.client.status.pendingInputCount == 0 })
    #expect(await f.host.applied == [1, 2])
    #expect(await eventually { f.sink.lastLine == "firstnext" })
    await f.client.close()
  }

  @Test(arguments: [UInt64.max - 1, UInt64.max])
  func resizeRevisionBoundaryDoesNotCrashClient(_ revision: UInt64) async throws
  {
    let f = try RoamingFixture()
    defer { Task { await f.client.close() } }
    await f.host.set(resizeRevision: revision)
    try #require(try await f.startActive())
    await f.client.proposeGrid(columns: 30, rows: 5)
    let expectedResizes: [InputOperation]
    if revision < UInt64.max {
      #expect(await eventually { f.sink.last?.columns == 30 })
      expectedResizes = [
        .resize(columns: 30, rows: 5, resizeRevision: UInt64.max)
      ]
      await f.client.proposeGrid(columns: 40, rows: 6)
    } else {
      expectedResizes = []
    }
    #expect(await f.client.state == .active)
    #expect(await f.client.status.lastFailure == .resizeUnavailable)
    #expect(f.sink.last?.columns == (revision < UInt64.max ? 30 : 20))
    #expect(f.sink.last?.rows == (revision < UInt64.max ? 5 : 4))
    #expect(await f.client.status.pendingInputCount == 0)
    let sequence: UInt64 = revision < UInt64.max ? 2 : 1
    #expect(
      await f.client.submit(.text("usable")) == .accepted(sequence: sequence)
    )
    #expect(await eventually { await f.host.text == "usable" })
    #expect(await eventually { f.sink.lastLine == "usable" })
    #expect(await f.host.resizes == expectedResizes)
    await f.client.close()
  }

  private final class RefusingSink: PresentationSink {
    let accepting = Mutex(false)
    let attempts = Mutex(0)
    let accepted = RecordingSink()

    func install(_ frame: PresentationFrame) -> Bool {
      attempts.withLock { $0 += 1 }
      guard accepting.withLock({ $0 }) else { return false }
      return accepted.install(frame)
    }
  }

  @Test
  func rejectedFirstFrameDoesNotActivateOrAcknowledgeAndCanBeRetried()
    async throws
  {
    let host = try FakeHost()
    await host.set(sendSnapshotOnAttach: false)
    let clock = TestClock()
    let sink = RefusingSink()
    let client = RoamingClient(
      bootstrapper: FakeBootstrapper(host: host),
      connector: FakeConnector(host: host),
      sink: sink,
      configuration: testConfiguration(),
      timing: clock.timing
    )
    defer { Task { await client.close() } }
    try await client.start(.create(GridSize(columns: 20, rows: 4)))
    try #require(await eventually { await host.attachCount == 1 })
    let epoch = try #require(await host.currentEpoch)
    await host.sendScreen(epoch: epoch, revision: 1, text: "accepted")
    try #require(await eventually { sink.attempts.withLock { $0 } == 1 })
    let status = await client.status
    #expect(status.state == .attaching)
    #expect(status.screenRevision == nil)
    #expect(status.lastScreenAt == nil)
    #expect(status.lastFailure == .snapshotRejected)
    #expect(
      await client.submit(.text("blocked")) == .refused(.notActive(.attaching))
    )
    #expect(await host.screenAckCount == 0)
    sink.accepting.withLock { $0 = true }
    await host.sendScreen(epoch: epoch, revision: 1, text: "accepted")
    #expect(await eventually { await client.state == .active })
    #expect(sink.accepted.lastLine == "accepted")
    #expect(sink.accepted.count == 1)
    #expect(await client.status.screenRevision == 1)
    #expect(await client.status.lastFailure == nil)
    #expect(await eventually { await host.screenAckCount == 1 })
    await client.close()
  }

  private final class CloseDelayGate: Sendable {
    let waiters = Mutex<[CheckedContinuation<Void, Never>]>([])
    var count: Int { waiters.withLock { $0.count } }
    func sleep() async {
      await withCheckedContinuation { continuation in
        waiters.withLock { $0.append(continuation) }
      }
    }
    func releaseFirst() {
      let waiter = waiters.withLock { $0.isEmpty ? nil : $0.removeFirst() }
      waiter?.resume()
    }
    func releaseAll() {
      let pending = waiters.withLock { s in
        defer { s = [] }
        return s
      }
      for waiter in pending { waiter.resume() }
    }
  }

  @Test
  func `an obsolete close timer cannot release a later detach`() async throws {
    let host = try FakeHost()
    let clock = TestClock()
    let gate = CloseDelayGate()
    defer { gate.releaseAll() }
    var timing = clock.timing
    let regularSleep = timing.sleep
    timing.sleep = { duration in
      if duration == .seconds(3) {
        // Hold a timer completion across cancellation, as if its callback
        // had already been queued when the old detach was acknowledged.
        await gate.sleep()
      } else {
        try await regularSleep(duration)
      }
    }
    let client = RoamingClient(
      bootstrapper: FakeBootstrapper(host: host),
      connector: FakeConnector(host: host),
      configuration: testConfiguration(),
      timing: timing
    )
    try await client.start(.create(GridSize(columns: 20, rows: 4)))
    try #require(await eventually { await client.state == .active })
    await client.enterBackground()
    try #require(await eventually { gate.count == 1 })
    await client.enterForeground()
    try #require(await eventually { await client.state == .active })
    await host.blackHoleCurrent()
    let finished = Mutex(false)
    Task {
      await client.enterBackground()
      finished.withLock { $0 = true }
    }
    try #require(await eventually { gate.count == 2 })
    gate.releaseFirst()
    #expect(
      !(await eventually(.milliseconds(100)) { finished.withLock { $0 } })
    )
    gate.releaseFirst()
    #expect(await eventually { finished.withLock { $0 } })
    #expect(await client.state == .backgroundDetached)
    await client.close()
  }

  @Test(arguments: [RoamingCloseMode.detach, .terminate])
  func `close during background detach completes both callers`(
    mode: RoamingCloseMode
  ) async throws {
    let f = try RoamingFixture()
    try #require(try await f.startActive())
    await f.host.blackHoleCurrent()
    let backgroundFinished = Mutex(false)
    Task {
      await f.client.enterBackground()
      backgroundFinished.withLock { $0 = true }
    }
    try #require(await f.waitFor(.backgroundDetached))
    await f.client.close(mode)
    #expect(
      await eventually(.seconds(1)) { backgroundFinished.withLock { $0 } }
    )
    #expect(await f.client.state == .userClosed)
  }

  @Test
  func `attach then first complete snapshot makes the client active`()
    async throws
  {
    let f = try RoamingFixture()
    try await f.client.start(.create(GridSize(columns: 20, rows: 4)))
    #expect(await f.waitFor(.active))
    let status = await f.client.status
    #expect(status.sessionID == f.host.sessionID)
    #expect(status.screenRevision == 1)
    #expect(status.title == "host")
    #expect(status.lastScreenAt != nil)
    #expect(f.sink.count == 1)
    #expect(await f.host.attachCount == 1)
    #expect(
      f.bootstrapper.requests.withLock { $0.map(\.operation) } == [.create]
    )
    await f.client.close()
  }

  @Test
  func `input is acknowledged and leaves the pending queue`() async throws {
    let f = try RoamingFixture()
    #expect(try await f.startActive())
    #expect(await f.client.submit(.text("ls")) == .accepted(sequence: 1))
    #expect(
      await f.client.submit(.key(SemanticKey(.enter))) == .accepted(sequence: 2)
    )
    #expect(await eventually { await f.client.status.pendingInputCount == 0 })
    #expect(await f.host.applied == [1, 2])
    #expect(await f.host.text == "ls")
    #expect(await eventually { f.sink.lastLine == "ls" })
    await f.client.close()
  }

  @Test
  func
    `severed connection retries unacknowledged input once under the new epoch`()
    async throws
  {
    let f = try RoamingFixture()
    #expect(try await f.startActive())
    // Applied but unacknowledged (1, 2) and lost in transit (3, 4).
    await f.host.set(withholdAcks: true, dropInputsAfter: .some(2))
    for (i, s) in ["a", "b", "c", "d"].enumerated() {
      #expect(
        await f.client.submit(.text(s)) == .accepted(sequence: UInt64(i + 1))
      )
    }
    #expect(await eventually { await f.host.received.count == 4 })
    #expect(await f.host.applied == [1, 2])
    #expect(await f.client.status.pendingInputCount == 4)

    await f.host.set(withholdAcks: false, dropInputsAfter: .some(nil))
    await f.host.severCurrent()
    #expect(await eventually { await f.host.attachCount == 2 })
    #expect(await f.waitFor(.active))
    #expect(await eventually { await f.client.status.pendingInputCount == 0 })

    // A3 oracle: each operation applied exactly once, in order.
    #expect(await f.host.applied == [1, 2, 3, 4])
    #expect(await f.host.text == "abcd")
    // Retries carry their original sequence numbers and the new epoch.
    let retried = await f.host.received.filter { $0.epoch == 2 }
    #expect(retried.map(\.sequence) == [3, 4])
    #expect(
      retried.map(\.operation) == [.committedText("c"), .committedText("d")]
    )
    #expect(await eventually { f.sink.lastLine == "abcd" })
    await f.client.close()
  }

  @Test
  func `input is refused while reconnecting and never queued`() async throws {
    let f = try RoamingFixture()
    #expect(try await f.startActive())
    await f.connector.block()
    await f.host.severCurrent()
    #expect(await eventually { await f.client.state == .attaching })
    let result = await f.client.submit(.text("lost"))
    #expect(result == .refused(.notActive(.attaching)))
    #expect(await f.client.status.refusedInputCount == 1)
    #expect(await f.client.status.pendingInputCount == 0)

    await f.connector.release()
    #expect(await f.waitFor(.active))
    #expect(await f.host.received.isEmpty)
    #expect(await f.host.text == "")
    await f.client.close()
  }

  @Test(arguments: [false, true])
  func futureEpochSnapshotsCannotFenceTheAttachedScreen(
    _ beforeAttached: Bool
  ) async throws {
    let f = try RoamingFixture()
    defer { Task { await f.client.close() } }
    try #require(try await f.startActive())
    if beforeAttached {
      await f.host.set(sendSnapshotOnAttach: false, withholdAttached: true)
      await f.host.severCurrent()
      try #require(await eventually { await f.host.attachCount == 2 })
    }
    let epoch = try #require(await f.host.currentEpoch)
    let connection = try #require(await f.connector.currentConnection)
    let installs = f.sink.count
    let revision = await f.client.status.screenRevision
    await f.host.sendScreen(epoch: UInt64.max, revision: 1000, text: "foreign")
    try #require(await eventually { connection.pendingDeliveryCount == 0 })
    if beforeAttached {
      await f.host.releaseAttached()
      try #require(await eventually { connection.pendingDeliveryCount == 0 })
    }
    #expect(await f.client.status.lastFailure == .snapshotRejected)
    #expect(f.sink.count == installs)
    #expect(await f.client.status.screenRevision == revision)
    await f.host.sendScreen()
    try #require(await f.waitFor(.active))
    #expect(await eventually { f.sink.lastLine == "" })
    #expect(await f.client.submit(.text("usable")) == .accepted(sequence: 1))
    #expect(await eventually { await f.client.status.pendingInputCount == 0 })
    #expect(await eventually { f.sink.lastLine == "usable" })
    #expect(await f.host.applied == [1])
    #expect(await f.host.currentEpoch == epoch)
    #expect(await f.host.attachCount == (beforeAttached ? 2 : 1))
    #expect(await f.client.status.screenRevision == 3)
    #expect(!f.sink.frames.withLock { $0.contains { $0.line(0) == "foreign" } })
    await f.client.close()
  }

  @Test(arguments: [false, true])
  func wrongSessionSnapshotCannotReplaceAnEarlyValidFrame(
    _ wrongFirst: Bool
  ) async throws {
    let f = try RoamingFixture()
    defer { Task { await f.client.close() } }
    try #require(try await f.startActive())
    await f.host.set(sendSnapshotOnAttach: false, withholdAttached: true)
    await f.host.severCurrent()
    try #require(await eventually { await f.host.attachCount == 2 })
    let epoch = try #require(await f.host.currentEpoch)
    let connection = try #require(await f.connector.currentConnection)
    if wrongFirst {
      try await f.host.sendUnansweredScreen(
        epoch: epoch,
        revision: 1000,
        wrongSession: true
      )
    }
    await f.host.sendScreen(epoch: epoch, revision: 3, text: "valid")
    if !wrongFirst {
      try await f.host.sendUnansweredScreen(
        epoch: epoch,
        revision: 1000,
        wrongSession: true
      )
    }
    try #require(await eventually { connection.pendingDeliveryCount == 0 })
    #expect(await f.client.status.lastFailure == .snapshotRejected)
    #expect(await f.client.state == .attaching)
    await f.host.releaseAttached()
    try #require(await f.waitFor(.active))
    #expect(f.sink.lastLine == "valid")
    #expect(await f.client.status.screenRevision == 3)
    #expect(await f.host.attachCount == 2)
    await f.host.sendScreen(epoch: epoch, revision: 4, text: "continued")
    #expect(await eventually { f.sink.lastLine == "continued" })
    #expect(await f.client.status.screenRevision == 4)
    await f.client.close()
  }

  @Test(arguments: ["revision", "epoch", "duplicate"], [false, true])
  func snapshotsBeforeAttachedRetainTheNewestScreen(
    _ stale: String,
    _ newestFirst: Bool
  ) async throws {
    let f = try RoamingFixture()
    defer { Task { await f.client.close() } }
    try #require(try await f.startActive())
    await f.host.set(sendSnapshotOnAttach: false, withholdAttached: true)
    await f.host.severCurrent()
    try #require(await eventually { await f.host.attachCount == 2 })
    let epoch = try #require(await f.host.currentEpoch)
    let staleEpoch = stale == "epoch" ? epoch - 1 : epoch
    let staleRevision: UInt64 =
      stale == "epoch" ? 1000 : (stale == "revision" ? 2 : 3)
    if !newestFirst {
      await f.host.sendScreen(
        epoch: staleEpoch,
        revision: staleRevision,
        text: "old"
      )
    }
    await f.host.sendScreen(epoch: epoch, revision: 3, text: "new")
    if newestFirst {
      await f.host.sendScreen(
        epoch: staleEpoch,
        revision: staleRevision,
        text: "old"
      )
    }
    await f.host.releaseAttached()
    #expect(await f.waitFor(.active))
    let expectedLine = stale == "duplicate" && !newestFirst ? "old" : "new"
    #expect(f.sink.lastLine == expectedLine)
    #expect(await f.client.status.screenRevision == 3)
    await f.client.close()
  }

  @Test
  func `stale and older epoch snapshots never regress the display`()
    async throws
  {
    let f = try RoamingFixture()
    #expect(try await f.startActive())
    #expect(await f.client.submit(.text("new")) == .accepted(sequence: 1))
    #expect(await eventually { f.sink.lastLine == "new" })
    let revision = await f.client.status.screenRevision
    let installs = f.sink.count

    // Older revision on the current epoch.
    await f.host.sendScreen(epoch: 1, revision: 1, text: "old")
    // Reattach, then a frame from the fenced epoch.
    await f.host.severCurrent()
    #expect(await eventually { await f.host.attachCount == 2 })
    #expect(await f.waitFor(.active))
    let afterReattach = f.sink.count
    await f.host.sendScreen(epoch: 1, revision: 1000, text: "fenced")
    // A marker frame proves the stale ones were processed first.
    await f.host.sendScreen()
    #expect(await eventually { f.sink.count == afterReattach + 1 })

    let lines = f.sink.frames.withLock { $0.map { $0.line(0) } }
    #expect(!lines.contains("old"))
    #expect(!lines.contains("fenced"))
    #expect(f.sink.lastLine == "new")
    #expect(installs == 2)
    #expect((await f.client.status.screenRevision ?? 0) > (revision ?? 0))
    await f.client.close()
  }

  @Test
  func `reconnect attempts run one at a time with backoff`() async throws {
    let f = try RoamingFixture()
    #expect(try await f.startActive())
    await f.connector.fail(next: 3)
    await f.host.severCurrent()
    #expect(await f.waitFor(.reconnecting))
    // Nudges must not start parallel attempts.
    for _ in 0 ..< 5 { await f.client.wake() }
    #expect(await eventually { await f.client.state == .active })
    #expect(await f.connector.maxInFlight == 1)
    #expect(await f.connector.connectCount == 5)
    #expect(Array(f.clock.backoffSleeps.prefix(4)) == [0.5, 1, 2, 4])
    // Three straight failures ask SSH whether the session still exists.
    #expect(
      f.bootstrapper.requests.withLock { $0.map(\.operation) } == [
        .create, .resume,
      ]
    )
    #expect(await f.client.status.reconnectAttempt == 0)
    await f.client.close()
  }

  @Test
  func `expired token renews credentials through SSH resume`() async throws {
    let f = try RoamingFixture()
    #expect(try await f.startActive())
    let writer = await f.host.writer
    let oldToken = await f.host.token
    f.clock.advanceWallClock(by: 9 * 3600)
    await f.host.severCurrent()
    #expect(await eventually { await f.host.attachCount == 2 })
    #expect(await f.waitFor(.active))

    let requests = f.bootstrapper.requests.withLock { $0 }
    #expect(requests.map(\.operation) == [.create, .resume])
    #expect(requests.last?.sessionID == f.host.sessionID)
    #expect(requests.last?.writerID == writer)
    #expect(await f.host.token != oldToken)
    // Same writer: the input sequence continues.
    #expect(await f.client.submit(.text("x")) == .accepted(sequence: 1))
    #expect(await eventually { await f.host.applied == [1] })
    await f.client.close()
  }

  @Test
  func `unknown session ends as session lost without replay`() async throws {
    let f = try RoamingFixture()
    #expect(try await f.startActive())
    await f.host.set(dropInputsAfter: .some(0))
    #expect(
      await f.client.submit(.text("rm -rf build")) == .accepted(sequence: 1)
    )
    #expect(await eventually { await f.host.received.count == 1 })
    // The helper restarted: the session no longer exists.
    await f.host.set(sessionGone: true)
    await f.host.severCurrent()
    #expect(await f.waitFor(.sessionLost))

    let status = await f.client.status
    #expect(status.pendingInputCount == 1)
    #expect(await f.host.received.count == 1)
    #expect(await f.host.applied.isEmpty)
    #expect(await f.client.submit(.text("y")) == .refused(.closed))
  }

  @Test
  func `authenticated unknown session from SSH ends as session lost`()
    async throws
  {
    let f = try RoamingFixture()
    #expect(try await f.startActive())
    await f.connector.fail(next: 100)
    await f.host.set(sessionGone: true)
    await f.host.severCurrent()
    // Unreachable attempts escalate to SSH, which answers authoritatively.
    #expect(await f.waitFor(.sessionLost))
    #expect(f.bootstrapper.requests.withLock { $0.last?.operation } == .resume)
  }

  @Test
  func `session exit is reported through status and lifecycle`() async throws {
    let clock = TestClock()
    let host = try FakeHost()
    let backend = RoamingScreenBackend(
      bootstrapper: FakeBootstrapper(host: host),
      connector: FakeConnector(host: host),
      configuration: testConfiguration(),
      timing: clock.timing
    )
    let changes = Mutex<[SurfaceLifecycle]>([])
    backend.onLifecycleChange = { change in
      changes.withLock { $0.append(change) }
    }
    let invalidations = Mutex(0)
    backend.onInvalidate = { invalidations.withLock { $0 += 1 } }

    try await backend.start(.create(GridSize(columns: 20, rows: 4)))
    #expect(await eventually { backend.lifecycle == .active })
    #expect(backend.capabilities == .roaming)
    #expect(backend.currentFrame()?.frame.title == "host")
    #expect(invalidations.withLock { $0 } == 1)

    await host.exit(status: 3)
    #expect(await eventually { backend.lifecycle == .exited(3) })
    #expect(await backend.client.status.exitStatus == 3)
    #expect(await backend.submit(.text("x")) == .refused(.closed))
    #expect(changes.withLock { $0 } == [.active, .exited(3)])
  }

  @Test
  func
    `background detach then foreground waits for a full screen before input`()
    async throws
  {
    let f = try RoamingFixture()
    #expect(try await f.startActive())
    await f.client.enterBackground()
    #expect(await f.client.state == .backgroundDetached)
    #expect(await f.host.detachCount == 1)
    #expect(
      await f.client.submit(.text("bg"))
        == .refused(.notActive(.backgroundDetached))
    )

    await f.host.set(sendSnapshotOnAttach: false)
    await f.client.enterForeground()
    #expect(await eventually { await f.host.attachCount == 2 })
    #expect(await eventually { await f.host.currentEpoch == 2 })
    #expect(await f.client.state == .attaching)
    #expect(
      await f.client.submit(.text("early")) == .refused(.notActive(.attaching))
    )

    await f.host.sendScreen()
    #expect(await f.waitFor(.active))
    #expect(await f.client.submit(.text("ok")) == .accepted(sequence: 1))
    #expect(await eventually { await f.host.text == "ok" })
    await f.client.close()
  }

  @Test
  func `grid proposals become ordered resize operations`() async throws {
    let f = try RoamingFixture()
    #expect(try await f.startActive())
    await f.client.proposeGrid(columns: 30, rows: 5)
    #expect(await eventually { f.sink.last?.columns == 30 })
    await f.client.proposeGrid(columns: 40, rows: 6)
    #expect(await eventually { f.sink.last?.columns == 40 })
    // Unchanged proposals send nothing.
    await f.client.proposeGrid(columns: 40, rows: 6)
    #expect(
      await f.host.resizes == [
        .resize(columns: 30, rows: 5, resizeRevision: 1),
        .resize(columns: 40, rows: 6, resizeRevision: 2),
      ]
    )
    #expect(f.sink.last?.rows == 6)
    await f.client.close()
  }

  @Test
  func `resume requests the configured grid instead of adopting the grant`()
    async throws
  {
    // The view proposed 30x5 while signing in; the session is 20x4.
    let f = try RoamingFixture(initialGrid: GridSize(columns: 30, rows: 5))
    try await f.client.start(.resume(f.host.sessionID))
    #expect(await f.waitFor(.active))
    let requested = f.bootstrapper.requests.withLock { $0.first?.initialGrid }
    #expect(requested == GridSize(columns: 30, rows: 5))
    #expect(await eventually { f.sink.last?.columns == 30 })
    #expect(
      await f.host.resizes == [.resize(columns: 30, rows: 5, resizeRevision: 1)]
    )
    await f.client.close()
  }

  @Test
  func `reattaching re-requests the grid after another client resized`()
    async throws
  {
    let f = try RoamingFixture()
    #expect(try await f.startActive())
    await f.client.proposeGrid(columns: 30, rows: 5)
    #expect(await eventually { f.sink.last?.columns == 30 })

    await f.client.enterBackground()
    // Another client takes over and resizes the session.
    await f.host.resizeExternally(columns: 50, rows: 10)
    await f.client.enterForeground()
    #expect(await f.waitFor(.active))
    #expect(await eventually { f.sink.last?.columns == 30 })
    #expect(f.sink.last?.rows == 5)
    #expect(
      await f.host.resizes == [
        .resize(columns: 30, rows: 5, resizeRevision: 1),
        .resize(columns: 30, rows: 5, resizeRevision: 3),
      ]
    )
    await f.client.close()
  }

  @Test
  func `unanswered input marks the connection stale and recovers`() async throws
  {
    let f = try RoamingFixture()
    let states = Mutex<[ClientConnectionState]>([])
    await f.client.setStatusHandler { status in
      states.withLock { if $0.last != status.state { $0.append(status.state) } }
    }
    #expect(try await f.startActive())
    await f.host.blackHoleCurrent()
    #expect(await f.client.submit(.text("z")) == .accepted(sequence: 1))
    #expect(await eventually { await f.host.attachCount == 2 })
    #expect(await f.waitFor(.active))
    #expect(await eventually { await f.client.status.pendingInputCount == 0 })
    #expect(await f.host.applied == [1])
    let seen = states.withLock { $0 }
    #expect(seen.contains(.suspect))
    #expect(seen.contains(.reconnecting))
    await f.client.close()
  }

  @Test
  func `explicit terminate closes the session`() async throws {
    let f = try RoamingFixture()
    #expect(try await f.startActive())
    await f.client.close(.terminate)
    #expect(await f.client.state == .userClosed)
    #expect(await f.host.terminateCount == 1)
    #expect(await f.client.submit(.text("x")) == .refused(.closed))
  }

  @Test
  func `status carries no secrets`() async throws {
    let f = try RoamingFixture()
    #expect(try await f.startActive())
    let text = String(describing: await f.client.status)
    let token = await f.host.token
    #expect(!text.contains(Data(token.bytes).base64EncodedString()))
    #expect(!text.contains(hexString(token.bytes)))
    await f.client.close()
  }

  @Test
  func `input whose record cannot fit is refused rather than stalling`() {
    // Control characters escape to six bytes each in JSON.
    let controls = String(repeating: "\u{01}", count: RSTLimits.maxPasteBytes)
    #expect((try? InputOperation.paste(controls).validate()) != nil)
    #expect(!RoamingClient.fitsControlRecord(.paste(controls)))
    #expect(
      RoamingClient.fitsControlRecord(
        .paste(String(repeating: "x", count: 32_000))
      )
    )
    #expect(RoamingClient.fitsControlRecord(.key(SemanticKey(.enter))))
  }
}
