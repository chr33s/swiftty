import ScreenProtocol
import Synchronization

/// Serializes `RSTConnectionHandler` callbacks for one connection.
///
/// A single drain task delivers events in order; each handler call finishes
/// before the next starts. Control bytes carry a completion the transport
/// uses to issue its next read, so a slow `onControl` applies backpressure
/// instead of queueing. Complete snapshots hold their QUIC stream credit
/// until delivered, which bounds their count. Preserve every admitted
/// payload: stream arrival order does not say which revision is newest.
final class EventMailbox: Sendable {
  enum Event: Sendable {
    case control([UInt8], done: @Sendable () -> Void)
    case snapshot([UInt8], done: @Sendable () -> Void)
    case closed((any Error)?)
  }

  private struct State {
    var handler: RSTConnectionHandler?
    var started = false
    var events: [Event] = []
    var draining = false
    var closePosted = false
  }

  private let state = Mutex(State())
  var hasHandler: Bool { state.withLock { $0.handler != nil } }

  var queuedSnapshotsForTesting: Int {
    state.withLock {
      $0.events.count { if case .snapshot = $0 { true } else { false } }
    }
  }

  /// Installs the handler and starts delivery. Only the first call counts;
  /// later calls return false.
  @discardableResult
  func start(_ handler: RSTConnectionHandler) -> Bool {
    let installed = state.withLock { s -> Bool in
      guard !s.started else { return false }
      s.started = true
      s.handler = handler
      return true
    }
    if installed { pump() }
    return installed
  }

  /// Queues an event. Events after `.closed` are dropped, but their
  /// completion still runs so no reader waits forever.
  func post(_ event: Event) {
    let dropped = state.withLock { s -> Bool in
      if s.closePosted { return true }
      if case .closed = event { s.closePosted = true }
      s.events.append(event)
      return false
    }
    if dropped { Self.complete(event) }
    pump()
  }

  private static func complete(_ event: Event) {
    switch event {
    case let .control(_, done), let .snapshot(_, done): done()
    case .closed: break
    }
  }

  private func pump() {
    let begin = state.withLock { s -> Bool in
      guard s.handler != nil, !s.draining, !s.events.isEmpty else {
        return false
      }
      s.draining = true
      return true
    }
    guard begin else { return }
    Task.detached { [self] in await drain() }
  }

  private func drain() async {
    while true {
      let next = state.withLock { s -> (Event, RSTConnectionHandler)? in
        guard let handler = s.handler, !s.events.isEmpty else {
          s.draining = false
          return nil
        }
        return (s.events.removeFirst(), handler)
      }
      guard let (event, handler) = next else { return }
      switch event {
      case let .control(bytes, done):
        await handler.onControl(bytes)
        done()
      case let .snapshot(bytes, done):
        await handler.onSnapshot(bytes)
        done()
      case let .closed(error):
        handler.onClosed(error)
        // Keep callback captures until ordered closure, then release them
        // outside the lock; their deinitializers may reenter the mailbox.
        let retired = state.withLock { s in
          let retired = s.handler
          s.handler = nil
          return retired
        }
        withExtendedLifetime(retired) {}
      }
    }
  }
}
