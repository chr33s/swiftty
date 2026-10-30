import Dispatch
import SessionCore
import Synchronization

/// Events from an authenticated RST/1 connection. Delivery is serialized
/// per handler. Network control reads wait for `onControl` to return;
/// in-memory delivery uses a finite window and refuses sends when full.
/// A slow consumer therefore cannot grow an unbounded delivery queue.
public struct RSTConnectionHandler: Sendable {
  /// Raw control-stream bytes in order (feed a `ControlRecordReader`).
  public var onControl: @Sendable ([UInt8]) async -> Void
  /// One complete snapshot stream payload (client side), already bounded
  /// by the snapshot limits. Incomplete streams never arrive. A superseded
  /// stream can still finish, so clients must reject stale screen revisions.
  public var onSnapshot: @Sendable ([UInt8]) async -> Void
  /// The connection ended; nil for an orderly close.
  public var onClosed: @Sendable ((any Error)?) -> Void

  public init(
    onControl: @escaping @Sendable ([UInt8]) async -> Void,
    onSnapshot: @escaping @Sendable ([UInt8]) async -> Void = { _ in },
    onClosed: @escaping @Sendable ((any Error)?) -> Void
  ) {
    self.onControl = onControl
    self.onSnapshot = onSnapshot
    self.onClosed = onClosed
  }
}

public enum RSTTransportError: Error, Equatable, Sendable {
  case closed
  case canceled
  case snapshotTooLarge
  case resourceLimit
  case notStarted
  case handshake(String)
  case pinMismatch
}

/// One RST/1 connection: a bidirectional control stream plus
/// server-initiated unidirectional snapshot streams (spec §7.1). The QUIC
/// implementation lives in AppleTransport; tests use `InMemoryRSTConnection`.
public protocol RSTConnection: AnyObject, Sendable {
  /// Synchronized transport closure, visible before ordered `onClosed`
  /// delivery when an earlier control handler is still awaiting work.
  var isClosed: Bool { get }
  /// Starts event delivery. Call once.
  func start(_ handler: RSTConnectionHandler)
  /// Writes a control record; returns once the transport accepted it
  /// under its flow control.
  func sendControl(_ record: [UInt8]) async throws
  /// Server: sends one snapshot payload on a new stream followed by FIN.
  /// Throws `RSTTransportError.canceled` if canceled first.
  func sendSnapshot(_ payload: [UInt8], stream id: UInt64) async throws
  /// Server: abandons a superseded snapshot. Bytes already accepted by the
  /// transport may still arrive as a complete payload at the client.
  func cancelSnapshot(stream id: UInt64)
  /// Closes the connection and all streams. Idempotent.
  func close()
}

/// Accepts authenticated RST/1 connections (server side).
public protocol RSTListener: AnyObject, Sendable {
  var port: UInt16 { get }
  func start(
    onConnection: @escaping @Sendable (any RSTConnection) -> Void
  ) async throws
  func stop()
}

/// An in-process connection pair with fault injection, for host/client
/// tests without a network. Delivery has a finite record and byte window;
/// sends fail with `resourceLimit` when full, allowing the caller to retry
/// after delivery advances. There is no internal queue of waiting senders.
///
/// Sendable: mutable delivery state lives in the `state` Mutex and handlers
/// run on the serial `delivery` queue. `peer` (weak) and `retainedPeer` are
/// set once in `pair` before either end is returned; the client keeps the
/// server alive.
public final class InMemoryRSTConnection: RSTConnection, @unchecked Sendable {
  static let maxPreCanceledSnapshots = 64
  static let maxHeldSnapshots = 8
  static let maxPendingEvents = 256
  static let maxPendingBytes =
    2 * (RSTLimits.maxSnapshotEncodedBytes + SnapshotFrame.headerLength)

  private final class ReceiverIdentity: Sendable {}

  private final class DeliveryScope: Sendable {
    let receiver: ReceiverIdentity
    private let active = Mutex(true)

    init(receiver: ReceiverIdentity) { self.receiver = receiver }

    func permits(_ receiver: ReceiverIdentity) -> Bool {
      self.receiver === receiver && active.withLock { $0 }
    }

    func end() { active.withLock { $0 = false } }
  }

  @TaskLocal
  private static var receivingScope: DeliveryScope?

  var pendingDeliveryCount: Int {
    state.withLock { $0.pendingEvents + ($0.reentrantPending ? 1 : 0) }
  }
  var pendingDeliveryBytes: Int {
    state.withLock { $0.pendingBytes + $0.reentrantBytes }
  }

  var heldSnapshotCount: Int { state.withLock { $0.heldSnapshots.count } }

  var preCanceledSnapshotCount: Int { state.withLock { $0.canceled.count } }

  private final class SnapshotAttempt: Sendable {
    private let canceled = Mutex(false)
    var isCanceled: Bool { canceled.withLock { $0 } }
    func cancel() { canceled.withLock { $0 = true } }
  }

  private struct HeldSnapshot {
    let attempt: SnapshotAttempt
    let continuation: CheckedContinuation<Void, any Error>
  }

  private struct State {
    var handler: RSTConnectionHandler?
    var started = false
    var backlog: [(Event, Admission?)] = []
    var pendingEvents = 0
    var pendingBytes = 0
    var reentrantPending = false
    var reentrantBytes = 0
    var closed = false
    var heldSnapshots: [UInt64: HeldSnapshot] = [:]
    var holdSnapshots = false
    var heldSnapshotGeneration: UInt64 = 0
    // Only recent IDs can race registration. Evict the oldest marker
    // rather than clearing all recent cancellations when the cap is reached.
    var canceled: [UInt64] = []

    mutating func takeCancellation(_ id: UInt64) -> Bool {
      guard let index = canceled.firstIndex(of: id) else { return false }
      canceled.remove(at: index)
      return true
    }
  }

  private struct Admission: Sendable {
    let bytes: Int
    let reentrant: Bool
  }

  private enum Event: Sendable {
    case control([UInt8])
    case snapshot([UInt8])
    case closed((any Error)?)
  }

  private let state = Mutex(State())
  private let deliveryIdentity = ReceiverIdentity()
  private weak var peer: InMemoryRSTConnection?
  private let delivery: DispatchQueue
  private let deliveryEventLimit: Int
  /// Strong reference for the server side of a pair kept by the client.
  private var retainedPeer: InMemoryRSTConnection?

  private init(label: String, deliveryEventLimit: Int) {
    self.deliveryEventLimit = deliveryEventLimit
    delivery = DispatchQueue(label: "rst.inmemory.\(label)")
  }

  /// Returns `(client, server)`.
  public static func pair() -> (
    client: InMemoryRSTConnection, server: InMemoryRSTConnection
  ) { pair(deliveryEventLimit: maxPendingEvents) }

  /// A finite larger window for the handler-handoff stress fixture.
  /// The production byte limit still applies.
  static func pair(
    deliveryEventLimit: Int
  ) -> (client: InMemoryRSTConnection, server: InMemoryRSTConnection) {
    precondition((1 ... 20_000).contains(deliveryEventLimit))
    let client = InMemoryRSTConnection(
      label: "client",
      deliveryEventLimit: deliveryEventLimit
    )
    let server = InMemoryRSTConnection(
      label: "server",
      deliveryEventLimit: deliveryEventLimit
    )
    client.peer = server
    server.peer = client
    client.retainedPeer = server
    return (client, server)
  }

  public var isClosed: Bool { state.withLock { $0.closed } }

  /// Fault-injection progress, without payload contents.
  var heldSnapshotGeneration: UInt64 {
    state.withLock { $0.heldSnapshotGeneration }
  }

  public func start(_ handler: RSTConnectionHandler) {
    state.withLock { s in
      guard !s.started else { return }
      s.started = true
      s.handler = handler
      // Queue the entire backlog before concurrent arrivals can see the
      // installed handler. Delivery itself runs outside the state lock.
      for (event, admission) in s.backlog {
        deliver(event, to: handler, admission: admission)
      }
      s.backlog = []
    }
  }

  private func enqueue(_ event: Event, bytes: Int) throws {
    try state.withLock { s in
      guard !s.closed else { throw RSTTransportError.closed }
      guard bytes <= Self.maxPendingBytes else {
        throw RSTTransportError.resourceLimit
      }
      let admission: Admission
      if s.pendingEvents < deliveryEventLimit,
        bytes <= Self.maxPendingBytes - s.pendingBytes
      {
        s.pendingEvents += 1
        s.pendingBytes += bytes
        admission = Admission(bytes: bytes, reentrant: false)
      } else if Self.receivingScope?.permits(deliveryIdentity) == true,
        !s.reentrantPending
      {
        // One bounded slot lets a callback send into its own receiver even
        // when ordinary producers filled the delivery window.
        s.reentrantPending = true
        s.reentrantBytes = bytes
        admission = Admission(bytes: bytes, reentrant: true)
      } else {
        throw RSTTransportError.resourceLimit
      }
      enqueue(event, admission: admission, in: &s)
    }
  }

  /// Admission and submission share the lock so closure cannot overtake
  /// accepted events. The close event uses no delivery credit.
  private func enqueue(
    _ event: Event,
    admission: Admission? = nil,
    in state: inout State
  ) {
    if let handler = state.handler {
      deliver(event, to: handler, admission: admission)
    } else {
      state.backlog.append((event, admission))
    }
  }

  private func release(_ admission: Admission?, scope: DeliveryScope) {
    state.withLock { s in
      // Expiration and credit return share admission's lock. Inherited
      // scopes cannot grant a child extra credit after this callback ends.
      scope.end()
      guard let admission else { return }
      if admission.reentrant {
        s.reentrantPending = false
        s.reentrantBytes = 0
      } else {
        s.pendingEvents -= 1
        s.pendingBytes -= admission.bytes
      }
    }
  }

  private func deliver(
    _ event: Event,
    to handler: RSTConnectionHandler,
    admission: Admission?
  ) {
    // A serial queue plus a blocking wait keeps accepted events ordered.
    // Credit remains occupied until the callback actually returns.
    delivery.async {
      let done = DispatchSemaphore(value: 0)
      Task {
        let scope = DeliveryScope(receiver: self.deliveryIdentity)
        await Self.$receivingScope.withValue(scope) {
          switch event {
          case let .control(bytes): await handler.onControl(bytes)
          case let .snapshot(bytes): await handler.onSnapshot(bytes)
          case let .closed(error): handler.onClosed(error)
          }
        }
        self.release(admission, scope: scope)
        if case .closed = event {
          // Release callback captures after ordered closure. Transfer the
          // handler out of the lock so captured objects may reenter us on deinit.
          let retired = self.state.withLock { s in
            let retired = s.handler
            s.handler = nil
            return retired
          }
          withExtendedLifetime(retired) {}
        }
        done.signal()
      }
      done.wait()
    }
  }

  public func sendControl(_ record: [UInt8]) async throws {
    guard !state.withLock({ $0.closed }), let peer else {
      throw RSTTransportError.closed
    }
    try peer.enqueue(.control(record), bytes: record.count)
  }

  public func sendSnapshot(_ payload: [UInt8], stream id: UInt64) async throws {
    guard
      payload.count <= SnapshotFrame.headerLength
        + RSTLimits.maxSnapshotEncodedBytes
    else { throw RSTTransportError.snapshotTooLarge }
    let attempt = SnapshotAttempt()
    try await withTaskCancellationHandler {
      guard !Task.isCancelled, !attempt.isCanceled else {
        throw RSTTransportError.canceled
      }
      let hold = state.withLock { s -> Bool in s.holdSnapshots && !s.closed }
      if hold {
        try await withCheckedThrowingContinuation { continuation in
          let (error, previous) = state.withLock {
            s -> (RSTTransportError?, HeldSnapshot?) in
            if attempt.isCanceled || s.takeCancellation(id) || s.closed {
              return (.canceled, nil)
            }
            guard
              s.heldSnapshots[id] != nil
                || s.heldSnapshots.count < Self.maxHeldSnapshots
            else { return (.resourceLimit, nil) }
            s.heldSnapshotGeneration &+= 1
            let entry = HeldSnapshot(
              attempt: attempt,
              continuation: continuation
            )
            return (nil, s.heldSnapshots.updateValue(entry, forKey: id))
          }
          if let error { continuation.resume(throwing: error) }
          previous?.continuation.resume(throwing: RSTTransportError.canceled)
        }
      }
      let canceled = state.withLock { s in
        attempt.isCanceled || s.takeCancellation(id) || s.closed
      }
      guard !canceled, let peer else { throw RSTTransportError.canceled }
      try peer.enqueue(.snapshot(payload), bytes: payload.count)
    } onCancel: {
      attempt.cancel()
      // Task cancellation belongs to this send, so it must neither
      // cancel a replacement with the same ID nor pre-cancel a later send.
      let held = self.state.withLock { s -> HeldSnapshot? in
        guard s.heldSnapshots[id]?.attempt === attempt else { return nil }
        return s.heldSnapshots.removeValue(forKey: id)
      }
      held?.continuation.resume(throwing: RSTTransportError.canceled)
    }
  }

  public func cancelSnapshot(stream id: UInt64) {
    let held = state.withLock { s -> CheckedContinuation<Void, any Error>? in
      if let c = s.heldSnapshots.removeValue(forKey: id) {
        return c.continuation
      }
      guard !s.closed, !s.canceled.contains(id) else { return nil }
      if s.canceled.count == Self.maxPreCanceledSnapshots {
        s.canceled.removeFirst()
      }
      s.canceled.append(id)
      return nil
    }
    held?.resume(throwing: RSTTransportError.canceled)
  }

  /// Test control: hold outgoing snapshots until `releaseSnapshots()`.
  /// At most eight distinct sends are held; additional sends fail with
  /// `resourceLimit`. Replacing an existing ID still cancels its older send.
  public func setHoldSnapshots(_ hold: Bool) {
    state.withLock { $0.holdSnapshots = hold }
  }

  public func releaseSnapshots() {
    let held = state.withLock { s in
      defer { s.heldSnapshots = [:] }
      return s.heldSnapshots.values.map { $0.continuation }
    }
    for c in held { c.resume() }
  }

  public func close() { closeLocally(error: nil, notifyPeer: true) }

  /// Simulates abrupt path loss: both ends observe an error.
  public func sever() {
    closeLocally(error: RSTTransportError.closed, notifyPeer: true)
  }

  private func closeLocally(error: (any Error)?, notifyPeer: Bool) {
    let held = state.withLock { s -> [CheckedContinuation<Void, any Error>]? in
      guard !s.closed else { return nil }
      s.closed = true
      let held = s.heldSnapshots.values.map { $0.continuation }
      s.heldSnapshots = [:]
      s.canceled.removeAll()
      enqueue(.closed(error), in: &s)
      return held
    }
    guard let held else { return }
    for c in held { c.resume(throwing: RSTTransportError.closed) }
    if notifyPeer { peer?.closeLocally(error: error, notifyPeer: false) }
  }
}
