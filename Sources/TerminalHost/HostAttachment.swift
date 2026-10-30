#if os(macOS)
import Dispatch
import ScreenProtocol
import SessionCore
import Synchronization

/// The RST/1 protocol handler for one authenticated connection (spec
/// §5.3, §7). Before a valid `Attach` every message is rejected and the
/// connection is closed (fail closed). After attaching, messages go to
/// the session's owner queue in order; a later attachment fences this one.
///
/// Never logs tokens, input or terminal contents.
///
/// Sendable: `phase` and `reader` are Mutex-guarded; the epoch, writer,
/// scheduler and viewport fields are touched only on the queue of the one
/// session it attaches to. The connection and sender are Sendable references
/// held for the attachment's lifetime.
final class HostAttachment: @unchecked Sendable {
  private enum Phase {
    case awaitingAttach
    case attached(RoamingSession)
    case closed
  }

  let connection: any RSTConnection
  private let registry: SessionRegistry
  private let sender: ControlSender
  private let phase = Mutex(Phase.awaitingAttach)
  private let reader = Mutex(ControlRecordReader())

  // Owned by the attached session's queue.
  var epoch: UInt64 = 0
  var writerID: WriterID?
  var isCurrent = true
  var scheduler = SnapshotScheduler(
    capturesPerSecond: RSTLimits.maxCapturesPerSecond,
    cancellationsPerSecond: RSTLimits.maxCancellationsPerSecond
  )
  var nextStreamID: UInt64 = 0
  var highestSubmittedScreenRevision: UInt64 = 0
  var timerArmed = false
  var exitNoticeSent = false
  /// Absolute top row of this attachment's history window (`Viewport`),
  /// or nil to follow live output. Never moves the host's own view.
  var historyTop: Int?
  /// `Viewport` movement received while a move is resolving on the pane,
  /// applied next rather than dropped (a swipe sends many in a row).
  var pendingViewportLines = 0
  var viewportMoveInFlight = false

  init(connection: any RSTConnection, registry: SessionRegistry) {
    self.connection = connection
    self.registry = registry
    sender = ControlSender(connection: connection)
  }

  func start() {
    connection.start(
      RSTConnectionHandler(
        onControl: { [self] bytes in await receive(bytes) },
        onClosed: { [self] _ in connectionClosed() }
      )
    )
  }

  func send(_ message: ControlMessage) { sender.send(message) }

  func closeAfterFlush() {
    phase.withLock { $0 = .closed }
    sender.closeAfterFlush()
  }

  /// Sends a typed error, then closes.
  func fail(_ code: RSTErrorCode, sequence: UInt64? = nil) {
    phase.withLock { $0 = .closed }
    sender.send(.error(.init(code, sequence: sequence)))
    sender.closeAfterFlush()
  }

  /// A newer attachment replaced this one (called on the session queue).
  func fence() {
    isCurrent = false
    phase.withLock { $0 = .closed }
    sender.close()
  }

  private func receive(_ bytes: [UInt8]) async {
    let messages: [ControlMessage]
    do {
      messages = try reader.withLock { reader throws(FramingError) in
        try reader.append(bytes)
      }
    } catch {
      fail(.malformed)
      return
    }
    for message in messages {
      let current = phase.withLock { $0 }
      switch current {
      case .closed: return
      case .awaitingAttach:
        guard case let .attach(request) = message else {
          fail(.notAttached)
          return
        }
        switch await registry.attach(request, attachment: self) {
        case let .success(session):
          let attached = phase.withLock { p -> Bool in
            guard case .awaitingAttach = p else { return false }
            p = .attached(session)
            return true
          }
          if !attached { session.detach(self) }
        case let .failure(code):
          fail(code)
          return
        }
      case let .attached(session): await session.receive(message, from: self)
      }
    }
  }

  private func connectionClosed() {
    let previous = phase.withLock { p -> Phase in
      defer { p = .closed }
      return p
    }
    sender.close()
    if case let .attached(session) = previous { session.detach(self) }
  }
}

/// Attachment result carrying a typed wire error code.
enum AttachOutcome<Value: Sendable>: Sendable {
  case success(Value)
  case failure(RSTErrorCode)
}
#endif
