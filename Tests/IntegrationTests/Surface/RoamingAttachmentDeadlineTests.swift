import Foundation
@testable import ScreenProtocol
import SessionCore
import Synchronization
import SwifttyCore
@testable import RoamingKit
@testable import TerminalSurface
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct RoamingAttachmentDeadlineTests {
  @Test(arguments: [0, 1, 2, 3, 4, 5])
  func onlyValidatedControlTrafficRestoresLiveness(_ kind: Int) async throws {
    let host = try FakeHost()
    let connector = FakeConnector(host: host)
    let clock = Clock()
    let client = RoamingClient(
      bootstrapper: FakeBootstrapper(host: host),
      connector: connector,
      configuration: RoamingClientConfiguration(
        livenessTick: .milliseconds(20),
        backoffJitter: 0
      ),
      timing: clock.timing
    )
    defer {
      Task {
        await client.close();
        await connector.release()
      }
    }
    try await client.start(.create(GridSize(columns: 20, rows: 4)))
    try #require(await eventually { await client.state == .active })
    let epoch = try #require(await host.currentEpoch)
    await host.blackHoleCurrent()
    await connector.block()
    #expect(await client.submit(.text("unanswered")) == .accepted(sequence: 1))
    clock.advance(.seconds(3))
    try #require(await eventually { await client.state == .suspect })
    let bytes: [UInt8]
    switch kind {
    case 0: bytes = [0]
    case 1:
      bytes = try ControlRecord.encode(.pong(epoch: epoch, nonce: UInt64.max))
    case 2: bytes = try ControlRecord.encode(.ping(epoch: epoch + 1, nonce: 0))
    case 3:
      bytes = try ControlRecord.encode(.inputAck(epoch: epoch + 1, sequence: 1))
    case 4: bytes = try ControlRecord.encode(.ping(epoch: epoch, nonce: 0))
    default:
      bytes = try ControlRecord.encode(.inputAck(epoch: epoch, sequence: 1))
    }
    _ = await client.handleControlForTesting(bytes)
    if kind < 4 {
      #expect(await client.state == .suspect)
      #expect(await client.status.pendingInputCount == 1)
      clock.advance(.seconds(3))
      #expect(await eventually { await client.state == .reconnecting })
    } else {
      #expect(await client.state == .active)
      #expect(await client.status.pendingInputCount == (kind == 5 ? 0 : 1))
    }
    #expect(await host.attachCount == 1)
    await client.close()
    await connector.release()
  }

  private final class ConditionalSink: PresentationSink {
    let accepts = Mutex(true)
    func install(_: PresentationFrame) -> Bool { accepts.withLock { $0 } }
  }

  @Test(arguments: [
    "malformed", "session", "epoch", "revision", "presentation", "accepted",
  ])
  func onlyAcceptedSnapshotsRestoreLiveness(_ kind: String) async throws {
    let host = try FakeHost()
    let connector = FakeConnector(host: host)
    let clock = Clock()
    let sink = ConditionalSink()
    let client = RoamingClient(
      bootstrapper: FakeBootstrapper(host: host),
      connector: connector,
      sink: sink,
      configuration: RoamingClientConfiguration(
        livenessTick: .milliseconds(20),
        backoffJitter: 0
      ),
      timing: clock.timing
    )
    defer {
      Task {
        await client.close();
        await connector.release()
      }
    }
    try await client.start(.create(GridSize(columns: 20, rows: 4)))
    try #require(await eventually { await client.state == .active })
    let epoch = try #require(await host.currentEpoch)
    let revision = try #require(await client.status.screenRevision)
    let connection = try #require(await connector.currentConnection)
    await host.blackHoleCurrent()
    await connector.block()
    #expect(await client.submit(.text("unanswered")) == .accepted(sequence: 1))
    clock.advance(.seconds(3))
    try #require(await eventually { await client.state == .suspect })
    if kind == "presentation" { sink.accepts.withLock { $0 = false } }
    try await host.sendUnansweredScreen(
      epoch: kind == "epoch" ? epoch - 1 : epoch,
      revision: kind == "revision" ? revision : revision + 1,
      malformed: kind == "malformed",
      wrongSession: kind == "session"
    )
    try #require(await eventually { connection.pendingDeliveryCount == 0 })
    #expect(await client.status.pendingInputCount == 1)
    if kind == "accepted" {
      #expect(await client.state == .active)
      #expect(await client.status.screenRevision == revision + 1)
    } else {
      #expect(await client.state == .suspect)
      #expect(await client.status.screenRevision == revision)
      clock.advance(.seconds(3))
      #expect(await eventually { await client.state == .reconnecting })
    }
    await client.close()
    await connector.release()
  }

  private final class AdvancingSink: PresentationSink {
    let clock: Clock
    let elapsed: Int
    let accepts: Bool
    let attempts = Mutex(0)

    init(clock: Clock, elapsed: Int, accepts: Bool) {
      self.clock = clock
      self.elapsed = elapsed
      self.accepts = accepts
    }

    func install(_: PresentationFrame) -> Bool {
      clock.advance(.seconds(elapsed))
      attempts.withLock { $0 += 1 }
      return accepts
    }
  }

  @Test(arguments: [9, 10, 11], [false, true])
  func presentationTimeConsumesTheAbsoluteAttachmentDeadline(
    _ elapsed: Int,
    _ accepts: Bool
  ) async throws {
    let host = try FakeHost()
    await host.set(sendSnapshotOnAttach: false)
    let connector = HeldConnector(host: host)
    let clock = Clock()
    let sink = AdvancingSink(clock: clock, elapsed: elapsed, accepts: accepts)
    let client = RoamingClient(
      bootstrapper: FakeBootstrapper(host: host),
      connector: connector,
      sink: sink,
      configuration: RoamingClientConfiguration(
        attachTimeout: .seconds(10),
        livenessTick: .seconds(30),
        backoffJitter: 0
      ),
      timing: clock.timing
    )
    defer {
      Task {
        await client.close();
        await connector.release()
      }
    }
    try await client.start(.create(GridSize(columns: 20, rows: 4)))
    try #require(await eventually { await connector.entered })
    await connector.release()
    try #require(await eventually { await host.attachCount == 1 })
    await host.sendScreen()
    try #require(await eventually { sink.attempts.withLock { $0 } == 1 })
    if elapsed < 10, accepts {
      #expect(await client.state == .active)
      #expect(await client.status.lastScreenAt != nil)
      #expect(await eventually { await host.screenAckCount == 1 })
      #expect(!(await connector.returnedClosed))
    } else {
      let failure: RoamingFailure =
        elapsed >= 10 ? .attachTimedOut : .snapshotRejected
      #expect(await eventually { await client.status.lastFailure == failure })
      #expect(await client.state != .active)
      #expect(await client.status.screenRevision == nil)
      #expect(await client.status.lastScreenAt == nil)
      #expect(await host.screenAckCount == 0)
      #expect(await connector.returnedClosed == (elapsed >= 10))
    }
    await client.close()
    await connector.release()
  }

  @Test(arguments: [9, 10, 11])
  func firstScreenMustArriveBeforeTheAbsoluteAttachDeadline(
    _ elapsed: Int
  ) async throws {
    let host = try FakeHost()
    await host.set(sendSnapshotOnAttach: false)
    let connector = HeldConnector(host: host)
    let clock = Clock()
    let sink = RecordingSink()
    let client = RoamingClient(
      bootstrapper: FakeBootstrapper(host: host),
      connector: connector,
      sink: sink,
      configuration: RoamingClientConfiguration(
        attachTimeout: .seconds(10),
        livenessTick: .seconds(30),
        backoffJitter: 0,
      ),
      timing: clock.timing,
    )
    try await client.start(.create(GridSize(columns: 20, rows: 4)))
    try #require(await eventually { await connector.entered })
    await connector.release()
    try #require(await eventually { await host.attachCount == 1 })
    clock.advance(.seconds(elapsed))
    await host.sendScreen()
    try #require(
      await eventually {
        let state = await client.state
        let failure = await client.status.lastFailure
        return state == .active || failure == .attachTimedOut
      }
    )
    if elapsed < 10 {
      #expect(await client.state == .active)
      #expect(sink.count > 0)
      #expect(!(await connector.returnedClosed))
    } else {
      #expect(await client.state != .active)
      #expect(await client.status.lastFailure == .attachTimedOut)
      #expect(sink.count == 0)
      #expect(await connector.returnedClosed)
    }
    await client.close()
    await connector.release()
  }

  @Test(arguments: [false, true])
  func attachmentFailureClosesTheConnectionBeforeResumingItsWaiter(
    _ malformed: Bool
  ) async throws {
    let host = try FakeHost()
    await host.set(sendSnapshotOnAttach: false)
    let connector = HeldConnector(host: host)
    let client = RoamingClient(
      bootstrapper: FakeBootstrapper(host: host),
      connector: connector,
      configuration: RoamingClientConfiguration(attachTimeout: .seconds(10)),
    )
    try await client.start(.create(GridSize(columns: 20, rows: 4)))
    try #require(await eventually { await connector.entered })
    await connector.release()
    try #require(await eventually { await host.attachCount == 1 })
    let bytes =
      malformed
      ? [0, 16, 0, 0] : try ControlRecord.encode(.error(.init(.expired)))
    let callback = await client.handleControlForTesting(bytes)
    #expect(callback.waiting)
    #expect(
      callback.closed,
      "attach failure must fence the connection in the callback's actor turn"
    )
    let failure: RoamingFailure =
      malformed ? .protocolViolation : .attachRejected(.expired)
    #expect(await eventually { await client.status.lastFailure == failure })
    await client.close()
  }

  private actor HeldConnector: RSTConnector {
    let host: FakeHost
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    private(set) var cancelled = false
    private(set) var returned: InMemoryRSTConnection?

    init(host: FakeHost) { self.host = host }

    func connect(to _: BootstrapGrant) async throws -> any RSTConnection {
      entered = true
      await withCheckedContinuation { waiter = $0 }
      cancelled = Task.isCancelled
      let (client, server) = InMemoryRSTConnection.pair()
      await host.accept(server)
      returned = client
      return client
    }

    func release() {
      let pending = waiter
      waiter = nil
      pending?.resume()
    }

    var returnedClosed: Bool { returned?.isClosed == true }
  }

  private final class Clock: Sendable {
    private let instant = Mutex(ContinuousClock.now)
    let sleeps = Mutex<[Duration]>([])

    var timing: SurfaceTiming {
      SurfaceTiming(
        now: { self.instant.withLock { $0 } },
        wallClock: { Date().timeIntervalSince1970 },
        sleep: { duration in
          self.sleeps.withLock { $0.append(duration) }
          try await Task.sleep(for: duration)
        },
      )
    }

    func advance(_ duration: Duration) { instant.withLock { $0 += duration } }
  }

  /// spec.roaming.md §9: an attempt whose handshake finished but that
  /// hears no `Attached` ends after the progress wait, not `attachTimeout`,
  /// and the first such retry starts without a backoff delay. Over shaped
  /// QUIC, Network sometimes held a new connection's first stream data
  /// until it closed, which cost a whole 15 s attach timeout.
  @Test(arguments: [false, true])
  func anAttemptWithoutAttachedIsRetriedAfterTheProgressWait(
    keepsStalling: Bool
  ) async throws {
    let host = try FakeHost()
    await host.set(withholdAttached: true)
    let connector = FakeConnector(host: host)
    let clock = Clock()
    let client = RoamingClient(
      bootstrapper: FakeBootstrapper(host: host),
      connector: connector,
      configuration: RoamingClientConfiguration(
        attachTimeout: .seconds(10),
        livenessTick: .seconds(30),
        backoffJitter: 0,
        attachProgressMinimum: .milliseconds(200)
      ),
      timing: clock.timing
    )
    try await client.start(.create(GridSize(columns: 20, rows: 4)))
    try #require(await eventually { await host.attachCount == 1 })
    if !keepsStalling { await host.set(withholdAttached: false) }
    #expect(await eventually(.seconds(2)) { await connector.connectCount == 2 })
    #expect(clock.sleeps.withLock { $0.contains(.milliseconds(200)) })
    // The first stalled attempt is retried at once, not after a backoff.
    #expect(!clock.sleeps.withLock { $0.contains(.milliseconds(500)) })
    if keepsStalling {
      // A second stall in a row backs off as any failed attempt does.
      #expect(
        await eventually(.seconds(3)) { await connector.connectCount == 3 }
      )
      #expect(clock.sleeps.withLock { $0.contains(.milliseconds(500)) })
      #expect(await client.status.lastFailure == .attachTimedOut)
    } else {
      #expect(await eventually { await client.state == .active })
    }
    await client.close()
  }

  @Test(arguments: [false, true])
  func blockedConnectIsBoundedAndLateConnectionIsClosed(
    cancel: Bool,
  ) async throws {
    let host = try FakeHost()
    let connector = HeldConnector(host: host)
    let client = RoamingClient(
      bootstrapper: FakeBootstrapper(host: host),
      connector: connector,
      configuration: RoamingClientConfiguration(
        attachTimeout: .milliseconds(50),
        livenessTick: .seconds(5),
        backoffJitter: 0,
      ),
    )
    try await client.start(.create(GridSize(columns: 20, rows: 4)))
    try #require(await eventually { await connector.entered })
    if cancel {
      await client.close()
    } else {
      #expect(
        await eventually(.milliseconds(200)) {
          await client.status.lastFailure == .attachTimedOut
        }
      )
    }
    await connector.release()
    #expect(
      await eventually(.milliseconds(100)) { await connector.returnedClosed }
    )
    #expect(await connector.cancelled)
    if cancel { #expect(await client.state == .userClosed) }
    await client.close()
  }

  @Test(arguments: [8, 10])
  func connectTimeConsumesTheFirstScreenDeadline(elapsed: Int) async throws {
    let host = try FakeHost()
    await host.set(sendSnapshotOnAttach: false)
    let connector = HeldConnector(host: host)
    let clock = Clock()
    let client = RoamingClient(
      bootstrapper: FakeBootstrapper(host: host),
      connector: connector,
      configuration: RoamingClientConfiguration(
        attachTimeout: .seconds(10),
        livenessTick: .seconds(30),
      ),
      timing: clock.timing,
    )
    try await client.start(.create(GridSize(columns: 20, rows: 4)))
    try #require(await eventually { await connector.entered })
    clock.advance(.seconds(elapsed))
    await connector.release()
    if elapsed == 8 {
      try #require(await eventually { await host.attachCount == 1 })
      #expect(
        await eventually(.milliseconds(100)) {
          clock.sleeps.withLock { $0.contains(.seconds(2)) }
        }
      )
      #expect(await client.state == .attaching)
      #expect(
        await eventually(.seconds(3)) {
          await client.status.lastFailure == .attachTimedOut
        }
      )
      #expect(await connector.returnedClosed)
    } else {
      #expect(
        await eventually(.milliseconds(100)) {
          await client.status.lastFailure == .attachTimedOut
        }
      )
      #expect(await connector.returnedClosed)
      #expect(await host.attachCount == 0)
    }
    await client.close()
  }
}
