import Dispatch
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
import SwiftMuxXPC
import Synchronization
import Testing

struct EventDeadlineTests {
  @Test(arguments: [false, true])
  func alreadyCanceledConsumerPreservesBufferedEvent(timed: Bool) async throws {
    let peer = EventPeer(initialEvent: .detached(reason: "buffered event"))
    defer { peer.close() }
    let connection = try await MuxConnection.connect(
      endpoint: peer.listener.endpoint,
      frontend: .native
    )
    let canceled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      if timed { return try await connection.nextEvent(timeout: .seconds(1)) }
      return try await connection.nextEvent()
    }
    do {
      await #expect(throws: CancellationError.self) { try await canceled.value }
      guard
        case let .detached(reason)? = try await connection.nextEvent(
          timeout: .milliseconds(200)
        )
      else {
        Issue.record("Canceled consumer removed the buffered event")
        await connection.close()
        return
      }
      #expect(reason == "buffered event")
      await connection.close()
    } catch {
      await connection.close()
      throw error
    }
  }

  @Test
  func delayedCancellationDoesNotCancelTheNextConsumer() async throws {
    let peer = EventPeer()
    defer { peer.close() }
    let connection = try await MuxConnection.connect(
      endpoint: peer.listener.endpoint,
      frontend: .native
    )
    let delayed = Mutex<(@Sendable () -> Void)?>(nil)
    let first = Task {
      try await connection.nextEvent(scheduleCancellation: { cleanup in
        delayed.withLock { $0 = cleanup }
      })
    }
    do {
      try await waitForConsumer(connection)
      first.cancel()
      let cleanup = try #require(delayed.withLock { $0 })
      try peer.send(.detached(reason: "first"))
      guard case let .detached(reason)? = try await first.value else {
        Issue.record("First consumer did not receive the event")
        await connection.close()
        return
      }
      #expect(reason == "first")
      let second = Task { try await connection.nextEvent(timeout: .seconds(2)) }
      try await waitForConsumer(connection)
      // The event resumed the old consumer before its queued cancellation
      // ran. Replaying that cleanup must leave the new waiter untouched.
      connection.queue.async(execute: cleanup)
      // A queue barrier ensures cleanup has run before sending the event.
      await withCheckedContinuation { continuation in
        connection.queue.async { continuation.resume() }
      }
      try peer.send(.detached(reason: "second"))
      guard case let .detached(nextReason)? = try await second.value else {
        Issue.record("Next consumer did not receive the event")
        await connection.close()
        return
      }
      #expect(nextReason == "second")
      await connection.close()
    } catch {
      await connection.close()
      throw error
    }
  }

  private func waitForConsumer(_ connection: MuxConnection) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !(await connection.hasEventWaiterForTesting) {
      guard ContinuousClock.now < deadline else { throw TimeoutError() }
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  @Test
  func timeoutLeavesConnectionAndNextConsumerUsable() async throws {
    let harness = try Harness()
    let connection = try await harness.connect()
    do {
      for _ in 0 ..< 3 {
        let started = ContinuousClock.now
        do {
          _ = try await connection.nextEvent(timeout: .milliseconds(20))
          Issue.record("Quiet connection returned an event")
        } catch let error as MuxConnection.EventWaitError {
          #expect(error == .timedOut)
        }
        #expect(ContinuousClock.now - started < .seconds(1))
        guard case .status = try await connection.execute(.status) else {
          Issue.record("Connection stopped serving requests after timeout")
          break
        }
      }
      let next = Task { try await connection.nextEvent(timeout: .seconds(5)) }
      await connection.close()
      #expect(try await next.value == nil)
    } catch {
      await connection.close()
      throw error
    }
  }

  @Test
  func cancellationRetiresTimedConsumerWithoutClosingConnection() async throws {
    let harness = try Harness()
    let connection = try await harness.connect()
    do {
      let waiting = Task {
        try await connection.nextEvent(timeout: .seconds(30))
      }
      try await Task.sleep(for: .milliseconds(20))
      waiting.cancel()
      do {
        _ = try await waiting.value
        Issue.record("Canceled consumer returned normally")
      } catch { #expect(error is CancellationError) }
      guard case .status = try await connection.execute(.status) else {
        Issue.record("Connection stopped serving requests after cancellation")
        await connection.close()
        return
      }
      await connection.close()
      #expect(try await connection.nextEvent(timeout: .seconds(1)) == nil)
    } catch {
      await connection.close()
      throw error
    }
  }
}

private final class EventPeer: Sendable {
  let queue = DispatchQueue(label: "event-consumer-peer")
  let listener: SMXListener
  private let channels = Mutex<[SMXChannel]>([])

  init(initialEvent: MuxEvent? = nil) {
    listener = SMXListener(anonymousOn: queue)
    listener.activate(connectionQueue: queue) { [self] channel in
      channels.withLock { $0.append(channel) }
      channel.activate { event in
        guard case let .message(data) = event,
          case .hello = try? SMXCodec.decode(
            ClientMessage.self,
            from: data,
            limit: 1 << 20
          )
        else { return }
        // An initial event precedes welcome on this channel, so it is
        // buffered before connect returns without a timing-based sleep.
        var messages: [ServerMessage] = initialEvent.map { [.event($0)] } ?? []
        messages.append(
          .welcome(
            Welcome(
              protocolVersion: SMX.protocolVersion,
              build: SMX.build,
              server: ServerInstanceID(),
              acceptedProfile: nil,
              limits: .standard,
              innerTerm: "xterm-256color"
            )
          )
        )
        for message in messages {
          if let encoded = try? SMXCodec.encode(message, limit: 1 << 20) {
            channel.send(encoded)
          }
        }
      }
    }
  }

  func send(_ event: MuxEvent) throws {
    let data = try SMXCodec.encode(ServerMessage.event(event), limit: 1 << 20)
    channels.withLock { $0 }.forEach { $0.send(data) }
  }

  func close() {
    channels.withLock { $0 }.forEach { $0.cancel() }
    listener.cancel()
  }
}
