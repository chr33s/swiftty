import Dispatch
@testable import SwifttyCore
@testable import SwifttyEngine
import Synchronization
import Testing

/// A manual clock: deadlines fire only when the test advances time.
final class FakeMaintenanceClock: ScrollbackMaintenanceClock, Sendable {
  private struct State {
    var now: UInt64 = 1_000_000_000
    var deadline: UInt64?
    var handler: (@Sendable () -> Void)?
    var arms = 0
  }
  private let state = Mutex(State())

  var now: UInt64 { state.withLock { $0.now } }
  var deadline: UInt64? { state.withLock { $0.deadline } }
  var arms: Int { state.withLock { $0.arms } }

  func arm(_ deadline: UInt64, _ handler: @escaping @Sendable () -> Void) {
    state.withLock {
      $0.deadline = deadline
      $0.handler = handler
      $0.arms += 1
    }
  }

  func disarm() {
    state.withLock {
      $0.deadline = nil
      $0.handler = nil
    }
  }

  /// Moves time forward, firing an armed deadline that has passed.
  func advance(by nanoseconds: UInt64) {
    let handler = state.withLock { s -> (@Sendable () -> Void)? in
      s.now += nanoseconds
      guard let deadline = s.deadline, deadline <= s.now else { return nil }
      s.deadline = nil
      defer { s.handler = nil }
      return s.handler
    }
    handler?()
  }
}

/// Answers each step synchronously with scripted results.
final class FakeMaintenanceOwner: ScrollbackMaintenanceOwner, Sendable {
  let name: String
  private let script = Mutex<[ScrollbackMaintenanceResult]>([])
  let generations = Mutex<[UInt64]>([])

  init(_ name: String) { self.name = name }

  func results(_ results: [ScrollbackMaintenanceResult]) {
    script.withLock { $0 = results }
  }

  func performScrollbackMaintenance(
    generation: UInt64,
    completion: @escaping @Sendable (ScrollbackMaintenanceReport) -> Void
  ) {
    generations.withLock { $0.append(generation) }
    let result = script.withLock { $0.isEmpty ? .idle : $0.removeFirst() }
    completion(ScrollbackMaintenanceReport(result: result))
  }

  func releaseScrollbackWorkspace() {}
}

/// Shares one log between several owners to observe interleaving.
final class SharedLogOwner: ScrollbackMaintenanceOwner, Sendable {
  let name: String
  let log: SharedLog
  private let remaining: Mutex<Int>

  init(_ name: String, log: SharedLog, steps: Int) {
    self.name = name
    self.log = log
    remaining = Mutex(steps)
  }

  func performScrollbackMaintenance(
    generation: UInt64,
    completion: @escaping @Sendable (ScrollbackMaintenanceReport) -> Void
  ) {
    log.entries.withLock { $0.append(name) }
    let more = remaining.withLock {
      $0 -= 1
      return $0 > 0
    }
    completion(ScrollbackMaintenanceReport(result: more ? .pending : .idle))
  }

  func releaseScrollbackWorkspace() {}
}

final class SharedLog: Sendable { let entries = Mutex<[String]>([]) }

/// A fake clock whose first `disarm` pauses after it is called, so a
/// test can run another thread's activity in that window.
final class PausingDisarmClock: ScrollbackMaintenanceClock, Sendable {
  let inner = FakeMaintenanceClock()
  let entered = DispatchSemaphore(value: 0)
  let proceed = DispatchSemaphore(value: 0)
  private let paused = Mutex(false)

  var now: UInt64 { inner.now }

  func arm(_ deadline: UInt64, _ handler: @escaping @Sendable () -> Void) {
    inner.arm(deadline, handler)
  }

  func disarm() {
    let first = paused.withLock { p -> Bool in
      defer { p = true }
      return !p
    }
    if first {
      entered.signal()
      _ = proceed.wait(timeout: .now() + 2)
    }
    inner.disarm()
  }
}

struct ScrollbackMaintenanceTests {
  func coordinator(
    _ clock: FakeMaintenanceClock
  ) -> ScrollbackMaintenanceCoordinator {
    ScrollbackMaintenanceCoordinator(
      clock: clock,
      idleDelay: 250_000_000,
      stepDelay: 1_000_000,
      observesMemoryPressure: false
    )
  }

  /// A disarm decided on one thread must not cancel a deadline another
  /// thread armed after it: the timer stays armed while work is pending.
  @Test
  func `a concurrent disarm cannot cancel a newer deadline`() {
    let clock = PausingDisarmClock()
    let coordinator = ScrollbackMaintenanceCoordinator(
      clock: clock,
      idleDelay: 250_000_000,
      stepDelay: 1_000_000,
      observesMemoryPressure: false
    )
    let first = FakeMaintenanceOwner("a")
    let second = FakeMaintenanceOwner("b")
    let leaving = coordinator.register(first)
    let staying = coordinator.register(second)
    leaving.noteActivity(generation: 1)
    #expect(coordinator.isTimerArmed)
    let group = DispatchGroup()
    // The only pending owner leaves: its thread disarms (and pauses).
    DispatchQueue.global().async(group: group) { leaving.cancel() }
    #expect(clock.entered.wait(timeout: .now() + 2) == .success)
    // Meanwhile another owner's activity arms a new deadline.
    DispatchQueue.global()
      .async(group: group) { staying.noteActivity(generation: 2) }
    usleep(100_000)
    clock.proceed.signal()
    #expect(group.wait(timeout: .now() + 2) == .success)
    #expect(coordinator.isTimerArmed)
    #expect(clock.inner.deadline != nil)
    clock.inner.advance(by: 250_000_000)
    #expect(second.generations.withLock { $0 } == [2])
  }

  @Test
  func `work waits for the idle delay after activity`() {
    let clock = FakeMaintenanceClock()
    let coordinator = coordinator(clock)
    let owner = FakeMaintenanceOwner("a")
    let registration = coordinator.register(owner)
    registration.noteActivity(generation: 7)
    #expect(owner.generations.withLock { $0 }.isEmpty)
    #expect(clock.deadline == clock.now + 250_000_000)
    clock.advance(by: 249_000_000)
    #expect(owner.generations.withLock { $0 }.isEmpty)
    clock.advance(by: 1_000_000)
    #expect(owner.generations.withLock { $0 } == [7])
    // An idle result stops the timer: no perpetual polling.
    #expect(!coordinator.isTimerArmed)
    #expect(clock.deadline == nil)
    clock.advance(by: 10_000_000_000)
    #expect(owner.generations.withLock { $0 } == [7])
  }

  @Test
  func `pending steps run one at a time at least a step delay apart`() {
    let clock = FakeMaintenanceClock()
    let coordinator = coordinator(clock)
    let owner = FakeMaintenanceOwner("a")
    owner.results([ScrollbackMaintenanceResult.pending, .pending, .idle])
    let registration = coordinator.register(owner)
    registration.noteActivity(generation: 1)
    clock.advance(by: 250_000_000)
    #expect(owner.generations.withLock { $0.count } == 1)
    clock.advance(by: 500_000)
    #expect(owner.generations.withLock { $0.count } == 1)
    clock.advance(by: 500_000)
    #expect(owner.generations.withLock { $0.count } == 2)
    clock.advance(by: 1_000_000)
    #expect(owner.generations.withLock { $0.count } == 3)
    clock.advance(by: 1_000_000_000)
    #expect(owner.generations.withLock { $0.count } == 3)
    #expect(coordinator.counters.steps == 3)
    #expect(!coordinator.isTimerArmed)
  }

  @Test
  func `owners are served round-robin`() {
    let clock = FakeMaintenanceClock()
    let coordinator = coordinator(clock)
    let log = SharedLog()
    let a = SharedLogOwner("a", log: log, steps: 3)
    let b = SharedLogOwner("b", log: log, steps: 3)
    let ra = coordinator.register(a)
    let rb = coordinator.register(b)
    ra.noteActivity(generation: 0)
    rb.noteActivity(generation: 0)
    clock.advance(by: 250_000_000)
    for _ in 0 ..< 10 { clock.advance(by: 1_000_000) }
    #expect(log.entries.withLock { $0 } == ["a", "b", "a", "b", "a", "b"])
    _ = (ra, rb)
  }

  @Test
  func `activity postpones work but a read request does not`() {
    let clock = FakeMaintenanceClock()
    let coordinator = coordinator(clock)
    let owner = FakeMaintenanceOwner("a")
    let registration = coordinator.register(owner)
    registration.noteActivity(generation: 0)
    clock.advance(by: 200_000_000)
    registration.noteActivity(generation: 0)
    clock.advance(by: 200_000_000)
    #expect(owner.generations.withLock { $0 }.isEmpty)
    // Frequent cosmetic reads must not postpone pending work forever.
    for _ in 0 ..< 10 {
      registration.requestMaintenance(generation: 0)
      clock.advance(by: 10_000_000)
    }
    #expect(owner.generations.withLock { $0.count } == 1)
  }

  @Test
  func `torn-down owners are dropped and stop the timer`() {
    let clock = FakeMaintenanceClock()
    let coordinator = coordinator(clock)
    var owner: FakeMaintenanceOwner? = FakeMaintenanceOwner("a")
    let registration = coordinator.register(owner!)
    registration.noteActivity(generation: 0)
    owner = nil
    clock.advance(by: 250_000_000)
    #expect(coordinator.ownerCount == 0)
    #expect(!coordinator.isTimerArmed)
    registration.cancel()
  }

  @Test
  func `cancelled registrations become inert`() {
    let clock = FakeMaintenanceClock()
    let coordinator = coordinator(clock)
    let owner = FakeMaintenanceOwner("a")
    let registration = coordinator.register(owner)
    registration.noteActivity(generation: 0)
    registration.cancel()
    #expect(!coordinator.isTimerArmed)
    clock.advance(by: 1_000_000_000)
    #expect(owner.generations.withLock { $0 }.isEmpty)
    registration.noteActivity(generation: 1)
    clock.advance(by: 1_000_000_000)
    #expect(owner.generations.withLock { $0 }.isEmpty)
  }

  @Test
  func `client steps run on the owner queue and skip stale storage`() async {
    let clock = FakeMaintenanceClock()
    let coordinator = coordinator(clock)
    let queue = DispatchQueue(label: "test.owner")
    let ran = Mutex<[UInt64]>([])
    let client = ScrollbackMaintenanceClient(
      queue: queue,
      coordinator: coordinator,
      step: { generation in
        dispatchPrecondition(condition: .onQueue(queue))
        ran.withLock { $0.append(generation) }
        return .idle
      },
      release: {}
    )
    client.noteActivity(generation: 42)
    clock.advance(by: 250_000_000)
    queue.sync {}
    #expect(ran.withLock { $0 } == [42])
    client.cancel()
    #expect(coordinator.ownerCount == 0)
  }

  @Test
  func `direct sessions compress idle history without publishing`() async throws
  {
    let session = TerminalSession(columns: 80, rows: 24)
    let updates = Mutex(0)
    session.onUpdate = { updates.withLock { $0 += 1 } }
    #expect(session.scrollbackCompression.effective)
    session.feed(Array(scrollbackCorpus(lines: 3_000, columns: 80).utf8))
    let published = updates.withLock { $0 }
    let lines = session.withState { state in
      (0 ..< state.scrollbackCount).map { state.scrollbackText($0) }
    }
    var compressed = 0
    for _ in 0 ..< 200 where compressed == 0 {
      try await Task.sleep(for: .milliseconds(25))
      compressed = session.scrollbackStatistics.compressedUnits
    }
    #expect(compressed > 0)
    #expect(updates.withLock { $0 } == published)
    let after = session.withState { state in
      (0 ..< state.scrollbackCount).map { state.scrollbackText($0) }
    }
    #expect(after == lines)
    session.setScrollbackCompression(false)
    #expect(!session.scrollbackCompression.effective)
  }
}
