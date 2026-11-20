@testable import ScreenProtocol
import SessionCore
import Testing

struct SchedulerTests {
  let t0 = ContinuousClock.now

  @Test(arguments: [0, -1, Int.min])
  func nonpositiveCancellationRatesWaitForRetirement(rate: Int) {
    var scheduler = SnapshotScheduler(
      capturesPerSecond: 30,
      cancellationsPerSecond: rate
    )
    scheduler.markDirty()
    #expect(scheduler.next(now: t0) == .capture(cancel: nil))
    scheduler.started(stream: 1, revision: 1)
    scheduler.markDirty()
    #expect(scheduler.next(now: t0 + .seconds(1)) == .capture(cancel: nil))
    scheduler.started(stream: 2, revision: 2)
    scheduler.markDirty()
    #expect(scheduler.next(now: t0 + .seconds(2)) == .idle)
    #expect(scheduler.isDirty)
    #expect(scheduler.streams.map(\.id) == [1, 2])
    #expect(scheduler.acknowledged(revision: 1) == [1])
    #expect(scheduler.next(now: t0 + .seconds(2)) == .capture(cancel: nil))
  }

  @Test(arguments: [0, -1, Int.min])
  func nonpositiveCaptureRatesUseABoundedCadence(rate: Int) {
    var scheduler = SnapshotScheduler(capturesPerSecond: rate)
    #expect(scheduler.captureInterval == .seconds(1))
    scheduler.markDirty()
    #expect(scheduler.next(now: t0) == .capture(cancel: nil))
    scheduler.started(stream: 1, revision: 1)
    scheduler.markDirty()
    #expect(
      scheduler.next(now: t0 + .milliseconds(500))
        == .wait(until: t0 + .seconds(1))
    )
    #expect(scheduler.next(now: t0 + .seconds(1)) == .capture(cancel: nil))
  }

  @Test
  func `interactive changes use the faster cadence once`() {
    var s = SnapshotScheduler(
      capturesPerSecond: 30,
      interactiveCapturesPerSecond: 120
    )
    s.markDirty()
    #expect(s.next(now: t0) == .capture(cancel: nil))
    s.started(stream: 1, revision: 1)
    // Output waits out the 30 Hz cadence.
    s.markDirty()
    #expect(s.next(now: t0) == .wait(until: t0 + s.captureInterval))
    // A history-window move is due at the interactive cadence instead.
    s.markDirty(interactive: true)
    #expect(s.next(now: t0) == .wait(until: t0 + s.interactiveInterval))
    let t1 = t0 + s.interactiveInterval
    #expect(s.next(now: t1) == .capture(cancel: nil))
    s.started(stream: 2, revision: 2)
    #expect(!s.isInteractive)
    // Later output returns to the ordinary cadence.
    #expect(s.acknowledged(revision: 2) == [1, 2])
    s.markDirty()
    #expect(s.next(now: t1) == .wait(until: t1 + s.captureInterval))
  }

  @Test
  func `interactive cadence is never slower than output`() {
    let s = SnapshotScheduler(
      capturesPerSecond: 240,
      interactiveCapturesPerSecond: 10
    )
    #expect(s.interactiveInterval == s.captureInterval)
  }

  @Test
  func `protected snapshot survives continuous output`() {
    var s = SnapshotScheduler()
    var now = t0
    var nextID: UInt64 = 0
    var revision: UInt64 = 0
    var canceled: [UInt64] = []
    // A6: mutate faster than delivery for five seconds without any acks.
    for _ in 0 ..< 500 {
      s.markDirty()
      if case let .capture(cancel) = s.next(now: now) {
        if let cancel { canceled.append(cancel) }
        nextID += 1
        revision += 1
        s.started(stream: nextID, revision: revision)
      }
      #expect(s.streams.count <= 2)
      now += .milliseconds(10)
    }
    // Stream 1 is protected and never canceled.
    #expect(s.streams.first?.id == 1 && s.streams.first?.isProtected == true)
    #expect(!canceled.contains(1))
    // At most ten cancellations per second.
    #expect(canceled.count <= 10 * 5 + 10)
    // Acknowledging the protected frame promotes the newer survivor.
    let survivor = s.streams[1].id
    #expect(s.acknowledged(revision: 1) == [1])
    #expect(s.streams.map(\.id) == [survivor])
    #expect(s.streams[0].isProtected)
  }

  @Test
  func `capture cadence and stale acknowledgments`() {
    var s = SnapshotScheduler()
    s.markDirty()
    #expect(s.next(now: t0) == .capture(cancel: nil))
    s.started(stream: 1, revision: 1)
    s.markDirty()
    if case .wait = s.next(now: t0 + .milliseconds(5)) {
    } else {
      Issue.record("expected cadence wait")
    }
    #expect(s.next(now: t0 + .milliseconds(40)) == .capture(cancel: nil))
    s.started(stream: 2, revision: 2)
    #expect(s.acknowledged(revision: 2) == [1, 2])
    #expect(s.acknowledged(revision: 1) == [])
    #expect(s.next(now: t0 + .seconds(1)) == .idle)
  }

  @Test
  func `failure and reset resend current state`() {
    var s = SnapshotScheduler()
    s.markDirty()
    _ = s.next(now: t0)
    s.started(stream: 1, revision: 1)
    s.failed(stream: 1)
    #expect(s.isDirty && s.streams.isEmpty)
    s.reset()
    #expect(s.next(now: t0) == .capture(cancel: nil))
  }

  @Test
  func `remote store never regresses`() {
    let id = SessionID(bytes: Array(repeating: 7, count: 16))!
    var store = RemoteScreenStore(sessionID: id)
    #expect(
      store.install(sampleSnapshot(revision: 5, epoch: 1))
        == .installed(generation: 1)
    )
    #expect(store.install(sampleSnapshot(revision: 4, epoch: 1)) == .stale)
    #expect(store.install(sampleSnapshot(revision: 5, epoch: 1)) == .stale)
    store.fence(epoch: 2)
    #expect(store.install(sampleSnapshot(revision: 9, epoch: 1)) == .stale)
    // A newer attachment may resend the same revision.
    #expect(
      store.install(sampleSnapshot(revision: 5, epoch: 2))
        == .installed(generation: 3)
    )
    var bad = sampleSnapshot(revision: 6, epoch: 2)
    bad.cells[2][7] = ScreenCell("x", width: 2, style: 0)
    #expect(
      store.install(bad) == .rejected(.missingContinuation(row: 2, column: 7))
    )
    #expect(
      store.install(sampleSnapshot(revision: 7, epoch: 2, session: .random()))
        == .rejected(.wrongSession)
    )
  }

  @Test
  func `validation rejects malformed cells`() {
    var s = sampleSnapshot()
    s.cells[2][0] = ScreenCell("\u{1B}[2J", width: 1, style: 0)
    #expect(throws: SnapshotValidationError.controlCharacter(row: 2, column: 0))
    { try s.validate() }
    s = sampleSnapshot()
    s.cells[2][3] = .continuation
    #expect(
      throws: SnapshotValidationError.orphanContinuation(row: 2, column: 3)
    ) { try s.validate() }
    s = sampleSnapshot()
    s.cells[2][0].style = 5
    #expect(throws: SnapshotValidationError.styleIndex(row: 2, column: 0)) {
      try s.validate()
    }
    s = sampleSnapshot()
    s.cursor.row = 3
    #expect(throws: SnapshotValidationError.cursorOutOfRange) {
      try s.validate()
    }
    s = sampleSnapshot()
    s.cells[2][0].text = String(repeating: "\u{301}", count: 40)
    #expect(throws: SnapshotValidationError.graphemeTooLong(row: 2, column: 0))
    { try s.validate() }
  }
}
