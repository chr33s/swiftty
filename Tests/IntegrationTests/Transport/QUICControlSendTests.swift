#if os(macOS)
@testable import AppleTransport
import Dispatch
import Network
import ScreenProtocol
import SessionCore
import Synchronization
import Testing

@Suite(.serialized)
struct QUICControlSendTests {
  @Test
  func lateHandshakeSuccessCannotBeatADelayedTimeoutCallback() async {
    let latch = OneShot()
    let expired = AsyncStream<Void>.makeStream()
    let delayed = AsyncStream<Void>.makeStream()
    defer {
      expired.continuation.finish()
      delayed.continuation.finish()
    }
    let reply = Task {
      for await _ in expired.stream { break }
      latch.resolve(nil)
    }
    defer { reply.cancel() }
    await #expect(throws: RSTTransportError.handshake("timed out")) {
      try await latch.wait(
        timeout: .milliseconds(20),
        beforeTimeoutForTesting: {
          expired.continuation.yield(())
          for await _ in delayed.stream { break }
        },
        begin: {},
      )
    }
    await reply.value
  }

  @Test(arguments: [Duration.zero, .milliseconds(-1)])
  func expiredHandshakeBudgetDoesNotBeginWork(_ timeout: Duration) async {
    let latch = OneShot()
    let began = Mutex(false)
    await #expect(throws: RSTTransportError.handshake("timed out")) {
      try await latch.wait(timeout: timeout) {
        began.withLock { $0 = true }
        latch.resolve(nil)
      }
    }
    #expect(!began.withLock { $0 })
  }

  @Test(arguments: [false, true])
  func cancelledHandshakeWaitDoesNotBeginWork(_ resolved: Bool) async {
    let latch = OneShot()
    if resolved { latch.resolve(nil) }
    let began = Mutex(false)
    await Task {
      withUnsafeCurrentTask { $0?.cancel() }
      await #expect(throws: RSTTransportError.canceled) {
        try await latch.wait(timeout: .seconds(2)) {
          began.withLock { $0 = true }
        }
      }
    }
    .value
    #expect(!began.withLock { $0 })
  }

  @Test
  func handshakeSuccessCannotOverrideCancellationBeforeReturn() async {
    let latch = OneShot()
    _ = await Task {
      await #expect(throws: RSTTransportError.canceled) {
        try await latch.wait(timeout: .seconds(2)) {
          latch.resolve(nil)
          withUnsafeCurrentTask { $0?.cancel() }
        }
      }
    }
    .value
  }

  private func connection() -> QUICRSTConnection {
    let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 9)
    let group = NWConnectionGroup(
      with: NWMultiplexGroup(to: endpoint),
      using: NWParameters(quic: NWProtocolQUIC.Options(alpn: ["rst/1"]))
    )
    return QUICRSTConnection(
      role: .server,
      group: group,
      queue: DispatchQueue(label: "control-send-test")
    )
  }

  private func eventually(_ condition: () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + .seconds(1)
    while !condition() {
      if ContinuousClock.now >= deadline { return false }
      try await Task.sleep(for: .milliseconds(1))
    }
    return true
  }

  @Test
  func controlReadinessWaitersHaveReusableFiniteCapacity() async throws {
    let server = connection()
    defer { server.close() }
    let sends = (0 ..< QUICRSTConnection.maxPendingControlSends)
      .map { id in
        Task {
          await #expect(throws: id == 0 ? RSTTransportError.canceled : .closed)
          { try await server.sendControl([]) }
        }
      }
    defer { sends.forEach { $0.cancel() } }
    try #require(
      try await eventually {
        server.pendingControlSendsForTesting == sends.count
      }
    )
    let overflowFinished = Mutex(false)
    let overflow = Task {
      defer { overflowFinished.withLock { $0 = true } }
      await #expect(throws: RSTTransportError.resourceLimit) {
        try await server.sendControl([1])
      }
    }
    defer { overflow.cancel() }
    #expect(try await eventually { overflowFinished.withLock { $0 } })
    sends[0].cancel()
    _ = await sends[0].value
    #expect(server.pendingControlSendsForTesting == sends.count - 1)
    let replacement = Task {
      await #expect(throws: RSTTransportError.closed) {
        try await server.sendControl([2])
      }
    }
    defer { replacement.cancel() }
    try #require(
      try await eventually {
        server.pendingControlSendsForTesting == sends.count
      }
    )
    server.close()
    for send in sends { _ = await send.value }
    _ = await replacement.value
    await overflow.value
    #expect(server.pendingControlSendsForTesting == 0)
  }

  @Test(arguments: [false, true])
  func nativeWritesKeepTheirCreditUntilCompletion(_ close: Bool) async throws {
    let server = connection()
    defer { server.close() }
    server.setClientControl(
      NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
    )
    let callbacks = Mutex<[@Sendable (NWError?) -> Void]>([])
    let write: QUICRSTConnection.ControlWrite = { _, bytes, completed in
      #expect(bytes.count == 1)
      callbacks.withLock { $0.append(completed) }
    }
    let sends = (0 ..< QUICRSTConnection.maxPendingControlSends)
      .map { _ in
        Task {
          await #expect(throws: close ? RSTTransportError.closed : .canceled) {
            try await server.sendControl([1], write: write)
          }
        }
      }
    defer { sends.forEach { $0.cancel() } }
    try #require(
      try await eventually { callbacks.withLock { $0.count } == sends.count }
    )
    await #expect(throws: RSTTransportError.resourceLimit) {
      try await server.sendControl([2], write: write)
    }
    if close {
      server.close()
      #expect(!server.hasControlStreamForTesting)
      server.setClientControl(
        NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
      )
      #expect(!server.hasControlStreamForTesting)
    } else {
      sends.forEach { $0.cancel() }
    }
    for send in sends { _ = await send.value }
    #expect(server.pendingControlSendsForTesting == (close ? 0 : sends.count))
    if !close {
      await #expect(throws: RSTTransportError.resourceLimit) {
        try await server.sendControl([2], write: write)
      }
    }
    let completions = callbacks.withLock { $0 }
    for completed in completions { completed(nil) }
    // A late/duplicate callback cannot resume a caller twice.
    completions.first?(nil)
    #expect(server.pendingControlSendsForTesting == 0)
    if !close {
      try await server.sendControl(
        [3],
        write: { _, _, completed in completed(nil) }
      )
      #expect(server.pendingControlSendsForTesting == 0)
    }
  }

  @Test
  func oversizedControlRecordIsRefusedBeforeCopyOrWrite() async throws {
    let server = connection()
    defer { server.close() }
    server.setClientControl(
      NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
    )
    let limit = RSTLimits.maxControlRecordBytes + 4
    let sizes = Mutex<[Int]>([])
    let write: QUICRSTConnection.ControlWrite = { _, bytes, completed in
      sizes.withLock { $0.append(bytes.count) }
      completed(nil)
    }
    await #expect(throws: RSTTransportError.resourceLimit) {
      try await server.sendControl(
        [UInt8](repeating: 0, count: limit + 1),
        write: write
      )
    }
    #expect(sizes.withLock { $0.isEmpty })
    #expect(server.pendingControlSendsForTesting == 0)
    try await server.sendControl(
      [UInt8](repeating: 0, count: limit),
      write: write
    )
    #expect(sizes.withLock { $0 } == [limit])
    #expect(server.pendingControlSendsForTesting == 0)
  }

  @Test(arguments: [false, true])
  func readinessResumesWaitingWritesAndCompletionReturnsCapacity(
    _ fail: Bool
  ) async throws {
    let server = connection()
    defer { server.close() }
    let written = Mutex(false)
    let send = Task {
      do {
        try await server.sendControl(
          [1],
          write: { _, bytes, completed in
            #expect(Array(bytes) == [1])
            written.withLock { $0 = true }
            completed(fail ? .posix(.ECONNRESET) : nil)
          }
        )
        #expect(!fail)
      } catch {
        #expect(fail)
        #expect(error as? NWError == .posix(.ECONNRESET))
      }
    }
    defer { send.cancel() }
    try #require(
      try await eventually { server.pendingControlSendsForTesting == 1 }
    )
    #expect(!written.withLock { $0 })
    server.setClientControl(
      NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
    )
    await send.value
    #expect(written.withLock { $0 })
    #expect(server.pendingControlSendsForTesting == 0)
  }

  @Test
  func cancellationCannotLetLaterWritesOvertakeQueuedWork() async throws {
    let server = connection()
    server.setClientControl(
      NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
    )
    let release = DispatchSemaphore(value: 0)
    defer {
      release.signal();
      server.close()
    }
    let submitted = Mutex<[UInt8]>([])
    let write: QUICRSTConnection.ControlWrite = { _, bytes, completed in
      let byte = bytes[0]
      submitted.withLock { $0.append(byte) }
      if byte == 1 { release.wait() }
      completed(nil)
    }
    let first = Task {
      await #expect(throws: RSTTransportError.canceled) {
        try await server.sendControl([1], write: write)
      }
    }
    defer { first.cancel() }
    try #require(try await eventually { submitted.withLock { $0 } == [1] })
    first.cancel()
    _ = await first.value
    let second = Task { try await server.sendControl([2], write: write) }
    defer { second.cancel() }
    try #require(
      try await eventually { server.pendingControlSendsForTesting == 2 }
    )
    #expect(submitted.withLock { $0 } == [1])
    release.signal()
    try await second.value
    #expect(submitted.withLock { $0 } == [1, 2])
    #expect(server.pendingControlSendsForTesting == 0)
  }

  @Test
  func canceledControlWaiterReturnsWithoutClosingTheConnection() async throws {
    let server = connection()
    defer { server.close() }
    let finished = Mutex(false)
    let send = Task {
      defer { finished.withLock { $0 = true } }
      await #expect(throws: RSTTransportError.canceled) {
        try await server.sendControl([1])
      }
    }
    defer { send.cancel() }
    try #require(
      try await eventually { server.pendingControlSendsForTesting == 1 }
    )
    send.cancel()
    #expect(try await eventually { finished.withLock { $0 } })
    #expect(server.pendingControlSendsForTesting == 0)
    #expect(!server.isClosed)
    server.close()
    await send.value
  }
}
#endif
