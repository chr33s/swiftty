import Dispatch
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
import SwiftMuxXPC
import Synchronization
import Testing

struct HandshakeCancellationTests {
  @Test
  func alreadyCanceledConnectionSendsNoHello() async throws {
    let peer = SilentHandshakePeer()
    defer { peer.close() }
    let pending = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await MuxConnection.connect(
        endpoint: peer.listener.endpoint,
        frontend: .native
      )
    }
    await #expect(throws: CancellationError.self) { try await pending.value }
    #expect(peer.hellos.withLock { $0 } == 0)
  }

  @Test
  func cancellationClosesAnAcceptedSilentHandshakePromptly() async throws {
    let peer = SilentHandshakePeer()
    defer { peer.close() }
    let pending = Task {
      try await MuxConnection.connect(
        endpoint: peer.listener.endpoint,
        frontend: .native
      )
    }
    defer { pending.cancel() }
    try await waitUntil { peer.hellos.withLock { $0 } == 1 }
    let started = ContinuousClock.now
    pending.cancel()
    await #expect(throws: CancellationError.self) { try await pending.value }
    #expect(ContinuousClock.now - started < .seconds(1))
    try await waitUntil { peer.closed.withLock { $0 } == 1 }
  }

  private func waitUntil(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !predicate() {
      guard ContinuousClock.now < deadline else { throw TimeoutError() }
      try await Task.sleep(for: .milliseconds(1))
    }
  }
}

private final class SilentHandshakePeer: Sendable {
  let queue = DispatchQueue(label: "silent-handshake-peer")
  let listener: SMXListener
  let hellos = Mutex(0)
  let closed = Mutex(0)
  private let channels = Mutex<[SMXChannel]>([])

  init() {
    listener = SMXListener(anonymousOn: queue)
    listener.activate(connectionQueue: queue) { [weak self] channel in
      guard let self else {
        channel.cancel();
        return
      }
      channels.withLock { $0.append(channel) }
      channel.activate { [weak self] event in
        guard let self else { return }
        switch event {
        case .closed: closed.withLock { $0 += 1 }
        case let .message(data):
          if case .hello = try? SMXCodec.decode(
            ClientMessage.self,
            from: data,
            limit: 1 << 20
          ) {
            hellos.withLock { $0 += 1 }
          }
        }
      }
    }
  }

  func close() {
    channels.withLock { $0 }.forEach { $0.cancel() }
    listener.cancel()
  }
}
