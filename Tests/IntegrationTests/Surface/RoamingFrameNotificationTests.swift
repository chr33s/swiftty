import Dispatch
import ScreenProtocol
import SessionCore
import SwifttyCore
import Synchronization
import TerminalSurface
import Testing

@Suite(.timeLimit(.minutes(1)))
struct RoamingFrameNotificationTests {
  private final class Sink: PresentationSink {
    let armed = Mutex(false)
    let holding = Mutex(false)
    let release = DispatchSemaphore(value: 0)
    let accepts: Bool

    init(accepts: Bool = true) { self.accepts = accepts }

    func install(_: PresentationFrame) -> Bool {
      let hold = armed.withLock { value in
        let hold = value
        value = false
        return hold
      }
      if hold {
        holding.withLock { $0 = true }
        _ = release.wait(timeout: .now() + 5)
        holding.withLock { $0 = false }
      }
      return accepts
    }
  }

  private func backend(
    host: FakeHost,
    sink: (any PresentationSink)? = nil,
  ) -> RoamingScreenBackend {
    let clock = TestClock()
    return RoamingScreenBackend(
      bootstrapper: FakeBootstrapper(host: host),
      connector: FakeConnector(host: host),
      sink: sink,
      configuration: testConfiguration(),
      timing: clock.timing,
    )
  }

  @Test(arguments: [false, true])
  func presentationInputBindingCannotFollowAReplacementAttachment(
    bounded: Bool
  ) async throws {
    let oldHost = try FakeHost()
    let newHost = try FakeHost()
    let display = TerminalSession(presentationColumns: 20, rows: 4)
    let old = backend(host: oldHost, sink: display)
    try await old.start(.create(GridSize(columns: 20, rows: 4)))
    try #require(await eventually { old.lifecycle == .active })
    old.bindInput(to: display)
    let retiredCallback = try #require(display.semanticInputHandler)
    display.send(.text("old"))
    try #require(await eventually { await oldHost.applied == [1] })
    old.stopInput()
    await old.close()

    let replacement = backend(host: newHost, sink: display)
    try await replacement.start(.create(GridSize(columns: 20, rows: 4)))
    try #require(await eventually { replacement.lifecycle == .active })
    // Input accepted before rebinding must retain the old attachment even
    // when the presentation queue has not yet invoked its callback.
    display.semanticInputHandler = retiredCallback
    let gate = DispatchSemaphore(value: 0)
    display.queue.async { gate.wait() }
    defer { gate.signal() }
    if bounded {
      #expect(display.submitViewInput(.text("queued for retired attachment")))
    } else {
      display.send(.text("queued for retired attachment"))
    }
    replacement.bindInput(to: display)
    gate.signal()
    // A callback already captured on the session queue remains bound to the
    // retired pump. It cannot read a mutable slot pointing at the new client.
    retiredCallback(.text("must not reach the replacement"))
    display.send(.text("new"))
    try #require(await eventually { await newHost.applied == [1] })
    await replacement.close()
    display.send(.text("closed"))
    _ = display.snapshot()
    #expect(await oldHost.applied == [1])
    #expect(await newHost.applied == [1])
    display.semanticInputHandler = nil
  }

  @Test
  func closingBackendReleasesClientEvenWhileDisplayRetainsItsInputCallback()
    async throws
  {
    let host = try FakeHost()
    let display = TerminalSession(presentationColumns: 20, rows: 4)
    var attachment: RoamingScreenBackend? = backend(host: host, sink: display)
    try await attachment?.start(.create(GridSize(columns: 20, rows: 4)))
    attachment?.bindInput(to: display)
    let released: @Sendable () -> Bool = { [weak client = attachment?.client] in
      client == nil
    }
    defer { display.semanticInputHandler = nil }
    await attachment?.close()
    attachment = nil
    #expect(await eventually { released() })
  }

  @Test
  func lateHandlerReceivesCachedFrameWithoutAnotherSnapshot() async throws {
    let host = try FakeHost()
    let backend = backend(host: host)
    try await backend.start(.create(GridSize(columns: 20, rows: 4)))
    #expect(await eventually { backend.lifecycle == .active })
    let calls = Mutex(0)
    let titles = Mutex<[String?]>([])
    backend.onInvalidate = { [weak backend] in
      let title = backend?.currentFrame()?.frame.title
      titles.withLock { $0.append(title) }
      calls.withLock { $0 += 1 }
    }
    #expect(calls.withLock { $0 } == 1)
    #expect(titles.withLock { $0 } == ["host"])
    #expect(backend.currentFrame()?.frame.title == "host")
    await backend.close()
  }

  @Test
  func replacementGetsOwnCoalescedNotification() async throws {
    let host = try FakeHost()
    let sink = RecordingSink()
    let backend = backend(host: host, sink: sink)
    let old = Mutex(0)
    let current = Mutex(0)
    backend.onInvalidate = { old.withLock { $0 += 1 } }
    try await backend.start(.create(GridSize(columns: 20, rows: 4)))
    #expect(await eventually { backend.lifecycle == .active })
    #expect(old.withLock { $0 } == 1)
    backend.onInvalidate = { current.withLock { $0 += 1 } }
    #expect(current.withLock { $0 } == 1)
    for _ in 0 ..< 5 { await host.sendScreen() }
    #expect(await eventually { sink.count == 6 })
    _ = await backend.client.status
    #expect(current.withLock { $0 } == 1)
    #expect(old.withLock { $0 } == 1)
    _ = backend.currentFrame()
    await host.sendScreen()
    #expect(await eventually { current.withLock { $0 } == 2 })
    backend.onInvalidate = nil
    backend.onInvalidate = { current.withLock { $0 += 1 } }
    #expect(current.withLock { $0 } == 3)
    await backend.close()
  }

  @Test(arguments: [false, true])
  func forwardingDelayCannotNotifyConsumedOrRetiredHandler(
    consume: Bool,
  ) async throws {
    let host = try FakeHost()
    let sink = Sink()
    defer { sink.release.signal() }
    let backend = backend(host: host, sink: sink)
    try await backend.start(.create(GridSize(columns: 20, rows: 4)))
    #expect(await eventually { backend.lifecycle == .active })
    let old = Mutex(0)
    let current = Mutex(0)
    backend.onInvalidate = { old.withLock { $0 += 1 } }
    _ = backend.currentFrame()
    let before = old.withLock { $0 }
    sink.armed.withLock { $0 = true }
    let send = Task { await host.sendScreen() }
    #expect(await eventually { sink.holding.withLock { $0 } })
    if consume {
      #expect(backend.currentFrame()?.frame.title == "host")
    } else {
      backend.onInvalidate = { current.withLock { $0 += 1 } }
      #expect(current.withLock { $0 } == 1)
    }
    sink.release.signal()
    await send.value
    _ = await backend.client.status
    #expect(old.withLock { $0 } == before)
    #expect(current.withLock { $0 } == (consume ? 0 : 1))
    await backend.close()
  }

  @Test
  func refusedForwardingStillLeavesOwnedFrameAvailable() async throws {
    let host = try FakeHost()
    let backend = backend(host: host, sink: Sink(accepts: false))
    try await backend.start(.create(GridSize(columns: 20, rows: 4)))
    #expect(await eventually { backend.lifecycle == .active })
    #expect(backend.currentFrame()?.frame.title == "host")
    await backend.close()
  }
}
