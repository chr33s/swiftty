#if os(macOS)
import Dispatch
import ScreenProtocol
import SessionCore
import Synchronization

/// Ordered, bounded writer for one connection's control stream. Callers
/// on any queue enqueue without waiting; a single drain task forwards
/// records under the transport's flow control. A peer that stops reading
/// long enough to exceed the byte bound loses its connection instead of
/// growing an unbounded queue.
final class ControlSender: Sendable {
  private struct State {
    var queue: [[UInt8]] = []
    var head = 0
    var bytes = 0
    var draining = false
    var closeWhenDrained = false
    var flushLimitArmed = false
    var closed = false
  }

  static let byteLimit = 1 << 20
  /// How long a flush may wait on one send before the transport is closed.
  /// The QUIC graceful-close bound starts only after `close` is called.
  static let flushCloseLimit: Duration = .milliseconds(500)

  private let state = Mutex(State())
  private let connection: any RSTConnection
  private let flushCloseLimit: Duration

  init(
    connection: any RSTConnection,
    flushCloseLimit: Duration = ControlSender.flushCloseLimit
  ) {
    self.connection = connection
    self.flushCloseLimit = flushCloseLimit
  }

  var isClosed: Bool { state.withLock { $0.closed || $0.closeWhenDrained } }

  func send(_ message: ControlMessage) {
    guard let record = try? ControlRecord.encode(message) else { return }
    enum Next { case none, drain, overflow }
    let next = state.withLock { s -> Next in
      guard !s.closed, !s.closeWhenDrained else { return .none }
      guard s.bytes + record.count <= Self.byteLimit else {
        s.closed = true
        s.queue = []
        s.head = 0
        s.bytes = 0
        return .overflow
      }
      s.queue.append(record)
      s.bytes += record.count
      if s.draining { return .none }
      s.draining = true
      return .drain
    }
    switch next {
    case .none: break
    case .overflow: connection.close()
    case .drain: Task { [self] in await drain() }
    }
  }

  /// Closes the connection once every queued record has been sent.
  func closeAfterFlush() {
    enum Action { case none, close, limit }
    let action = state.withLock { s -> Action in
      guard !s.closed else { return .none }
      if s.draining {
        s.closeWhenDrained = true
        if s.flushLimitArmed { return .none }
        s.flushLimitArmed = true
        return .limit
      }
      s.closed = true
      return .close
    }
    switch action {
    case .none: break
    case .close: connection.close()
    case .limit: armFlushLimit()
    }
  }

  /// A send that never completes must not postpone the requested close.
  private func armFlushLimit() {
    let limit = flushCloseLimit
    Task { [self] in
      try? await Task.sleep(for: limit)
      let abandon = state.withLock { s -> Bool in
        guard !s.closed, s.closeWhenDrained else { return false }
        s.closed = true
        s.closeWhenDrained = false
        s.draining = false
        s.queue.removeAll()
        s.head = 0
        s.bytes = 0
        return true
      }
      if abandon { connection.close() }
    }
  }

  /// Closes immediately, discarding unsent records. Idempotent.
  func close() {
    state.withLock { s in
      s.closed = true
      s.queue = []
      s.head = 0
      s.bytes = 0
    }
    connection.close()
  }

  private func drain() async {
    while true {
      enum Step {
        case send([UInt8])
        case finish, closeConnection
      }
      let step = state.withLock { s -> Step in
        if s.closed {
          s.draining = false
          return .finish
        }
        guard s.head < s.queue.count else {
          s.queue = []
          s.head = 0
          s.draining = false
          if s.closeWhenDrained {
            s.closed = true
            return .closeConnection
          }
          return .finish
        }
        let record = s.queue[s.head]
        s.head += 1
        s.bytes -= record.count
        if s.head > 64, s.head * 2 > s.queue.count {
          s.queue.removeFirst(s.head)
          s.head = 0
        }
        return .send(record)
      }
      switch step {
      case .finish: return
      case .closeConnection:
        connection.close()
        return
      case let .send(record):
        do { try await connection.sendControl(record) } catch {
          close()
          return
        }
      }
    }
  }
}
#endif
