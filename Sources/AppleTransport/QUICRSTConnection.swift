import Foundation
import Network
import ScreenProtocol
import SessionCore
import Synchronization

/// Connection-viability and better-path signals for the client state
/// machine (spec §9). These are hints, combined there with application
/// acknowledgments and foreground state; neither proves the peer is gone.
public protocol RSTPathEvents: AnyObject, Sendable {
  /// Called with the control stream's viability (false: no usable path).
  var onViabilityChange: (@Sendable (Bool) -> Void)? { get set }
  /// Called when a better path is (or is no longer) available; QUIC may
  /// migrate on its own, otherwise the client may reconnect.
  var onBetterPath: (@Sendable (Bool) -> Void)? { get set }
}

/// Always-on, bounded lifecycle trace with monotonic timestamps. Keeps the
/// first `headCapacity` events, which carry setup ordering, and a ring of the
/// latest `tailCapacity`; the rendering reports how many fell in between.
/// Events are short strings recorded only at stream and connection
/// transitions, never per received chunk.
struct LifecycleLog: Sendable {
  static let headCapacity = 32
  static let tailCapacity = 224
  static let maxDetail = 320

  private var head: [(time: UInt64, detail: String)] = []
  private var tail: [(time: UInt64, detail: String)] = []
  private var next = 0
  private(set) var total = 0

  static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

  mutating func append(_ detail: String, at time: UInt64 = Self.now()) {
    total += 1
    let entry = (time: time, detail: String(detail.prefix(Self.maxDetail)))
    if head.count < Self.headCapacity {
      head.append(entry)
    } else if tail.count < Self.tailCapacity {
      tail.append(entry)
    } else {
      tail[next] = entry
      next = (next + 1) % Self.tailCapacity
    }
  }

  /// Events oldest first, as microseconds since `origin`.
  func render(since origin: UInt64) -> String {
    func line(_ entry: (time: UInt64, detail: String)) -> String {
      let micros = entry.time >= origin ? (entry.time - origin) / 1000 : 0
      return "+\(micros)us \(entry.detail)"
    }
    let ordered = Array(tail[next...]) + Array(tail[..<next])
    var lines = head.map(line)
    let dropped = total - head.count - tail.count
    if dropped > 0 { lines.append("... \(dropped) events dropped ...") }
    lines += ordered.map(line)
    return "[" + lines.joined(separator: "; ") + "]"
  }
}

/// One RST/1 connection over a Network framework QUIC connection group
/// (spec §7.1): the first client-initiated bidirectional stream carries
/// control records; each snapshot travels on its own server-initiated
/// unidirectional stream, one payload then FIN.
public final class QUICRSTConnection: RSTConnection, RSTPathEvents {
  enum Role: Sendable { case client, server }

  /// Orders one native write against cancellation without retaining a payload
  /// in an extra queue. Network's send call is nonblocking; its completion
  /// only uses the connection state lock, never this admission lock.
  private final class SnapshotWriteAdmission: Sendable {
    private enum Phase: Sendable {
      case waiting, started
      case cancelled(submitted: Bool)
    }

    private let phase = Mutex(Phase.waiting)

    func perform(_ write: () -> Void) {
      phase.withLock { phase in
        guard case .waiting = phase else { return }
        phase = .started
        write()
      }
    }

    /// Closes admission. True when `perform` already submitted the native send.
    func cancel() -> Bool {
      phase.withLock { phase in
        switch phase {
        case .waiting:
          phase = .cancelled(submitted: false)
          return false
        case .started:
          phase = .cancelled(submitted: true)
          return true
        case let .cancelled(submitted): return submitted
        }
      }
    }
  }

  private struct OutboundSnapshot {
    var stream: NWConnection
    /// The native write carries FIN with the payload. Only a test writer
    /// may send them separately.
    let writeIncludesFIN: Bool
    let writeAdmission = SnapshotWriteAdmission()
    var continuation: CheckedContinuation<Void, any Error>?
    var sent = false
    /// Finish queued bytes once the native send completion runs. Resetting
    /// these streams can abort the whole connection group on macOS 27.
    var finishAfterSend = false
  }

  private struct ControlSend {
    var waiter: CheckedContinuation<NWConnection, any Error>?
    var completion: CheckedContinuation<Void, any Error>?
    var writing = false
  }

  private struct SnapshotReadProgress {
    var callbacks = 0
    var bytes = 0
    var pending = false
    var complete = false
  }

  private struct State {
    var control: NWConnection?
    var controlSends: [UUID: ControlSend] = [:]
    var startedControlReads = false
    var closed = false
    var termination: String?
    var nativeTermination: String?
    var outbound: [UInt64: OutboundSnapshot] = [:]
    /// Includes cancelled callers while their native writes are outstanding.
    var admittedSnapshotSends: Set<UUID> = []
    var outboundOrder: [UInt64] = []
    /// Superseded streams whose native send is still outstanding.
    var parkedFinishes:
      [ObjectIdentifier: (stream: NWConnection, writeIncludesFIN: Bool)] = [:]
    /// Superseded streams finished with FIN, oldest first, awaiting cancel.
    var retiring: [NWConnection] = []
    var retireCheckScheduled = false
    /// Server snapshot streams started so far (server side).
    var openedSnapshotStreams = 0
    var preCanceled: [UInt64] = []
    var inbound: [ObjectIdentifier: NWConnection] = [:]
    var snapshotReads: [ObjectIdentifier: SnapshotReadProgress] = [:]
    var lifecycle = LifecycleLog()
    /// Last retirement wait recorded, so the 100 ms recheck logs only changes.
    var lastRetireWait: (released: Int?, opened: Int)?
    var beforeInboundStartForTesting: (@Sendable () -> Void)?
    var inboundActionForTesting: (@Sendable () -> InboundTestAction)?
    /// Client: inbound streams whose stream credit is still to be returned,
    /// each exactly once however it ends.
    var owedCredit: Set<ObjectIdentifier> = []
    /// Client: owed streams whose snapshot awaits delivery; delivery returns
    /// their credit, so undelivered snapshots stay bounded by the limit.
    var deliveringSnapshots: Set<ObjectIdentifier> = []
    var beforeSnapshotReadForTesting: SnapshotReadGate?
    /// Server snapshot streams released so far (client side).
    var releasedSnapshotStreams = 0
    var onViabilityChange: (@Sendable (Bool) -> Void)?
    var onBetterPath: (@Sendable (Bool) -> Void)?
    var onTerminated: (@Sendable () -> Void)?

    mutating func takeControlWaiters() -> [CheckedContinuation<
      NWConnection, any Error
    >] {
      var waiters: [CheckedContinuation<NWConnection, any Error>] = []
      for id in Array(controlSends.keys) {
        if let waiter = controlSends[id]?.waiter {
          waiters.append(waiter)
          controlSends[id]?.waiter = nil
        }
      }
      return waiters
    }

    mutating func takePreCancellation(_ id: UInt64) -> Bool {
      guard let index = preCanceled.firstIndex(of: id) else { return false }
      preCanceled.remove(at: index)
      return true
    }
  }

  /// Completed-but-unretired outbound streams a later cancellation may retire;
  /// also the bound on superseded streams awaiting retirement.
  static let maxTrackedOutbound = 8
  static let maxPendingControlSends = 32

  var hasControlStreamForTesting: Bool { state.withLock { $0.control != nil } }

  var pendingControlSendsForTesting: Int {
    state.withLock { $0.controlSends.count }
  }
  static let maxPendingSnapshotSends = 8

  var admittedSnapshotSendsForTesting: Int {
    state.withLock { $0.admittedSnapshotSends.count }
  }

  var snapshotDeliveryCountsForTesting: (queued: Int, released: Int) {
    queue.sync {
      (
        mailbox.queuedSnapshotsForTesting,
        state.withLock { $0.releasedSnapshotStreams }
      )
    }
  }
  static let maxPreCanceledSnapshots = 64

  /// Monotonic origin for lifecycle timestamps.
  private let createdAt = LifecycleLog.now()
  /// QUIC flow-control and idle settings, for diagnostics.
  let settings: String

  var preCanceledSnapshotCount: Int { state.withLock { $0.preCanceled.count } }
  static let streamRejectedCode: UInt64 = 0x11

  let role: Role
  let group: NWConnectionGroup
  let queue: DispatchQueue
  private let state = Mutex(State())
  private let traceSnapshotReads = Atomic(false)
  private let controlWrites = DispatchQueue(label: "rst.quic.control-writes")
  private let mailbox: EventMailbox
  private let limits: NegotiatedLimits

  init(
    role: Role,
    group: NWConnectionGroup,
    queue: DispatchQueue,
    limits: NegotiatedLimits = NegotiatedLimits(),
    settings: String = "unknown"
  ) {
    self.role = role
    self.group = group
    self.queue = queue
    self.limits = limits.effective
    self.settings = settings
    self.mailbox = EventMailbox()
  }

  deinit {
    // A dropped connection must not keep its QUIC connection alive until
    // the idle timeout.
    group.cancel()
  }

  // MARK: Path events

  public var onViabilityChange: (@Sendable (Bool) -> Void)? {
    get { state.withLock { $0.onViabilityChange } }
    set {
      let previous = state.withLock { s in
        let previous = s.onViabilityChange
        s.onViabilityChange = newValue
        return previous
      }
      withExtendedLifetime(previous) {}
    }
  }

  public var onBetterPath: (@Sendable (Bool) -> Void)? {
    get { state.withLock { $0.onBetterPath } }
    set {
      let previous = state.withLock { s in
        let previous = s.onBetterPath
        s.onBetterPath = newValue
        return previous
      }
      withExtendedLifetime(previous) {}
    }
  }

  public var negotiatedALPN: String? {
    (group.metadata(definition: NWProtocolQUIC.definition)
      as? NWProtocolQUIC.Metadata)?
      .negotiatedALPN
  }

  /// Internal hook for the listener's connection accounting.
  func setOnTerminated(_ body: @escaping @Sendable () -> Void) {
    let previous = state.withLock { s in
      let previous = s.onTerminated
      s.onTerminated = body
      return previous
    }
    withExtendedLifetime(previous) {}
  }

  // MARK: Group wiring

  /// Installs inbound-stream and group-state handlers. Call before the
  /// group starts (server) or right after creating it (client).
  func attachGroupHandlers() {
    group.newConnectionHandler = { [weak self] stream in
      guard let self else {
        stream.cancel()
        return
      }
      self.adopt(inbound: stream)
    }
  }

  /// Group state after `ready` (the connector/listener owns the handshake
  /// phase).
  func groupStateChanged(_ newState: NWConnectionGroup.State) {
    record("group state \(newState)")
    switch newState {
    case let .failed(error): terminate(error: error, source: "group failed")
    case .cancelled: terminate(error: nil, source: "group cancelled")
    default: break
    }
  }

  enum InboundTestAction: Sendable { case admit, refuse, cancelBeforeReady }

  private func adopt(inbound stream: NWConnection) {
    traceStream(stream, event: "adopt")
    let id = ObjectIdentifier(stream)
    stream.stateUpdateHandler = { [weak self, weak stream] newState in
      guard let self else { return }
      if let stream { self.traceStream(stream, event: "state \(newState)") }
      switch newState {
      case .ready: if let stream { self.classify(inbound: stream) }
      case .failed, .cancelled:
        if let stream { self.forget(inbound: stream) }
        // A stream that ends unread (failed before `.ready`, rejected by
        // `classify`, or reset mid-read) still used one of the peer's streams.
        self.settleCredit(id, unlessDelivering: true)
      default: break
      }
    }
    let action = state.withLock { $0.inboundActionForTesting }?() ?? .admit
    let accepted = state.withLock { s -> Bool in
      if role == .client { s.owedCredit.insert(id) }
      guard !s.closed, s.inbound.count < 16, action != .refuse else {
        s.lifecycle.append(
          "inbound refused,closed=\(s.closed),inbound=\(s.inbound.count)"
        )
        return false
      }
      s.inbound[ObjectIdentifier(stream)] = stream
      return true
    }
    guard accepted else {
      // Never started, so no state change will return its credit.
      reject(stream)
      settleCredit(id, unlessDelivering: false)
      return
    }
    let beforeStart = state.withLock { $0.beforeInboundStartForTesting }
    beforeStart?()
    stream.start(queue: queue)
    if action == .cancelBeforeReady { stream.cancel() }
  }

  /// Returns an owed inbound stream's credit once.
  private func settleCredit(_ id: ObjectIdentifier, unlessDelivering: Bool) {
    let owed = state.withLock { s -> Bool in
      if unlessDelivering, s.deliveringSnapshots.contains(id) { return false }
      s.deliveringSnapshots.remove(id)
      return s.owedCredit.remove(id) != nil
    }
    if owed { releaseSnapshotCredit() }
  }

  func setInboundActionForTesting(
    _ body: (@Sendable () -> InboundTestAction)?
  ) {
    let previous = state.withLock { s in
      let previous = s.inboundActionForTesting
      s.inboundActionForTesting = body
      return previous
    }
    withExtendedLifetime(previous) {}
  }

  func setBeforeInboundStartForTesting(_ body: (@Sendable () -> Void)?) {
    let previous = state.withLock { s in
      let previous = s.beforeInboundStartForTesting
      s.beforeInboundStartForTesting = body
      return previous
    }
    withExtendedLifetime(previous) {}
  }

  /// Records a stream transition in the always-on lifecycle log, with the
  /// native stream ID and any application error code the peer sent. Call
  /// outside the state lock; reads Network metadata.
  private func traceStream(
    _ stream: NWConnection,
    event: @autoclosure () -> String
  ) {
    let time = LifecycleLog.now()
    let metadata =
      stream.metadata(definition: NWProtocolQUIC.definition)
      as? NWProtocolQUIC.Metadata
    let detail =
      "\(event()),object=\(ObjectIdentifier(stream)),"
      + "id=\(String(describing: metadata?.streamIdentifier)),"
      + "streamError=\(String(describing: metadata?.streamApplicationErrorCode))"
    state.withLock { $0.lifecycle.append(detail, at: time) }
  }

  /// Records a connection-level transition. Call outside the state lock.
  private func record(_ event: String) {
    let time = LifecycleLog.now()
    state.withLock { $0.lifecycle.append(event, at: time) }
  }

  private func forget(inbound stream: NWConnection) {
    state.withLock {
      _ = $0.inbound.removeValue(forKey: ObjectIdentifier(stream))
      $0.snapshotReads.removeValue(forKey: ObjectIdentifier(stream))
    }
  }

  /// Defers the native reset until this queue turn finishes. Setting the
  /// stream error or cancelling inside a receive or state callback aborts
  /// the connection group with EINVAL.
  private func reject(_ stream: NWConnection) {
    queue.async { self.finishReject(stream) }
  }

  private func finishReject(_ stream: NWConnection) {
    if case .ready = stream.state,
      let metadata = stream.metadata(definition: NWProtocolQUIC.definition)
        as? NWProtocolQUIC.Metadata
    {
      metadata.streamApplicationErrorCode = Self.streamRejectedCode
    }
    stream.cancel()
  }

  /// RFC 9000 §2.1: the low two bits of a stream ID give initiator (bit 0,
  /// 1 = server) and directionality (bit 1, 1 = unidirectional).
  private func classify(inbound stream: NWConnection) {
    guard
      let metadata = stream.metadata(definition: NWProtocolQUIC.definition)
        as? NWProtocolQUIC.Metadata
    else {
      forget(inbound: stream)
      reject(stream)
      return
    }
    let kind = metadata.streamIdentifier & 0x3
    if role == .client {
      let id = ObjectIdentifier(stream)
      if kind & 0x2 == 0 {
        // Bidirectional: not a unidirectional stream's credit.
        _ = state.withLock { $0.owedCredit.remove(id) }
      }
    }
    switch role {
    case .server where kind == 0:
      // First client bidirectional stream becomes the control stream.
      let waiters = state.withLock {
        s -> [CheckedContinuation<NWConnection, any Error>]? in
        guard s.control == nil, !s.closed else { return nil }
        s.inbound.removeValue(forKey: ObjectIdentifier(stream))
        s.control = stream
        return s.takeControlWaiters()
      }
      guard let waiters else {
        forget(inbound: stream)
        reject(stream)
        return
      }
      installControlHandlers(stream)
      for waiter in waiters { waiter.resume(returning: stream) }
      startControlReadsIfReady()
    case .client where kind == 3:
      readSnapshot(
        from: stream,
        into: SnapshotStreamAccumulator(limits: limits)
      )
    default:
      forget(inbound: stream)
      reject(stream)
    }
  }

  /// Client: adopts the locally opened control stream.
  func setClientControl(_ stream: NWConnection) {
    let waiters = state.withLock {
      s -> [CheckedContinuation<NWConnection, any Error>]? in
      guard !s.closed, s.control == nil else { return nil }
      s.control = stream
      return s.takeControlWaiters()
    }
    guard let waiters else {
      stream.cancel();
      return
    }
    installControlHandlers(stream)
    for waiter in waiters { waiter.resume(returning: stream) }
  }

  private func installControlHandlers(_ stream: NWConnection) {
    stream.stateUpdateHandler = { [weak self, weak stream] newState in
      switch newState {
      case .failed, .cancelled: break
      default:
        if let stream {
          self?.traceStream(stream, event: "control \(newState)")
        }
      }
      switch newState {
      case let .failed(error):
        if let stream {
          self?.traceStream(stream, event: "control failed \(error)")
        }
        self?.terminate(error: error, source: "control failed")
      case .cancelled:
        if let stream { self?.traceStream(stream, event: "control cancelled") }
        self?.terminate(error: nil, source: "control cancelled")
      default: break
      }
    }
    stream.viabilityUpdateHandler = { [weak self] viable in
      self?.record("control viable=\(viable)")
      self?.onViabilityChange?(viable)
    }
    stream.betterPathUpdateHandler = { [weak self] better in
      self?.onBetterPath?(better)
    }
  }

  // MARK: RSTConnection

  public var isClosed: Bool { state.withLock { $0.closed } }

  public func start(_ handler: RSTConnectionHandler) {
    guard mailbox.start(handler) else { return }
    startControlReadsIfReady()
  }

  private func startControlReadsIfReady() {
    guard mailbox.hasHandler else { return }
    let stream = state.withLock { s -> NWConnection? in
      guard let control = s.control, !s.startedControlReads, !s.closed else {
        return nil
      }
      s.startedControlReads = true
      return control
    }
    if let stream { receiveControl(stream) }
  }

  /// One read at a time; the next is issued only after `onControl` for
  /// these bytes returns.
  private func receiveControl(_ stream: NWConnection) {
    stream.receive(
      minimumIncompleteLength: 1,
      maximumLength: RSTLimits.maxControlRecordBytes
    ) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let data, !data.isEmpty {
        let bytes = [UInt8](data)
        let more = error == nil && !isComplete
        self.mailbox.post(
          .control(
            bytes,
            done: { [weak self] in if more { self?.receiveControl(stream) } }
          )
        )
      } else if error == nil, !isComplete {
        self.receiveControl(stream)
      }
      if let error {
        self.traceStream(stream, event: "control receive failed \(error)")
        self.terminate(error: error, source: "control receive failed")
      } else if isComplete {
        // Peer finished the control stream: orderly end of connection.
        self.traceStream(stream, event: "control EOF")
        self.terminate(error: nil, source: "control EOF")
      }
    }
  }

  /// Admits at most 32 control sends, each bounded to one encoded record.
  /// Cancellation returns promptly; an accepted write keeps its credit until
  /// Network finishes processing it and may still reach the peer.
  public func sendControl(_ record: [UInt8]) async throws {
    try await sendControl(record, write: nil)
  }

  /// Test seam for a Network write whose contentProcessed callback is delayed.
  typealias ControlWrite =
    @Sendable (NWConnection, Data, @escaping @Sendable (NWError?) -> Void) ->
    Void

  func sendControl(_ record: [UInt8], write: ControlWrite?) async throws {
    guard record.count <= RSTLimits.maxControlRecordBytes + 4 else {
      throw RSTTransportError.resourceLimit
    }
    guard !Task.isCancelled else { throw RSTTransportError.canceled }
    let id = UUID()
    try state.withLock { s in
      guard !s.closed else { throw RSTTransportError.closed }
      guard s.controlSends.count < Self.maxPendingControlSends else {
        throw RSTTransportError.resourceLimit
      }
      s.controlSends[id] = ControlSend()
    }
    defer {
      state.withLock { s in
        if s.controlSends[id]?.writing == false {
          s.controlSends.removeValue(forKey: id)
        }
      }
    }
    try await withTaskCancellationHandler {
      let stream = try await controlStream(send: id)
      guard !Task.isCancelled else { throw RSTTransportError.canceled }
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        let completed: @Sendable (NWError?) -> Void = { [weak self] error in
          self?.finishControlSend(id, error: error)
        }
        let error = state.withLock { s -> RSTTransportError? in
          guard !s.closed else { return .closed }
          guard s.controlSends[id] != nil else { return .canceled }
          s.controlSends[id]?.writing = true
          s.controlSends[id]?.completion = continuation
          // Publish in admission order before cancellation can resume the
          // caller and allow its next write to overtake this accepted record.
          controlWrites.async {
            if let write {
              write(stream, Data(record), completed)
            } else {
              stream.send(
                content: Data(record),
                completion: .contentProcessed(completed)
              )
            }
          }
          return nil
        }
        if let error { continuation.resume(throwing: error) }
      }
    } onCancel: { [weak self] in
      self?.cancelControlSend(id)
    }
  }

  private func controlStream(send id: UUID) async throws -> NWConnection {
    // Server before the client's first control stream arrived.
    try await withCheckedThrowingContinuation { continuation in
      let immediate = state.withLock { s -> Result<NWConnection, any Error>? in
        if s.closed { return .failure(RSTTransportError.closed) }
        guard s.controlSends[id] != nil else {
          return .failure(RSTTransportError.canceled)
        }
        if let control = s.control { return .success(control) }
        s.controlSends[id]?.waiter = continuation
        return nil
      }
      if let immediate { continuation.resume(with: immediate) }
    }
  }

  private func cancelControlSend(_ id: UUID) {
    let canceled = state.withLock { s -> ControlSend? in
      guard let entry = s.controlSends[id] else { return nil }
      if entry.writing {
        // The shared stream's accepted bytes cannot be individually reset.
        // Keep their credit until Network's completion, even if the caller leaves.
        s.controlSends[id]?.completion = nil
      } else {
        s.controlSends.removeValue(forKey: id)
      }
      return entry
    }
    canceled?.waiter?.resume(throwing: RSTTransportError.canceled)
    canceled?.completion?.resume(throwing: RSTTransportError.canceled)
  }

  private func finishControlSend(_ id: UUID, error: NWError?) {
    let entry = state.withLock { $0.controlSends.removeValue(forKey: id) }
    if let error {
      entry?.completion?.resume(throwing: error)
    } else {
      entry?.completion?.resume()
    }
  }

  /// Admits at most eight unfinished sends, including stream creation and
  /// native writes whose callers cancelled; more fail with `resourceLimit`.
  /// Completed stream history is bounded separately.
  public func sendSnapshot(_ payload: [UInt8], stream id: UInt64) async throws {
    try await sendSnapshot(payload, stream: id, beforeRegistration: nil)
  }

  /// Test seam for cancellation while Network creates a stream.
  func sendSnapshot(
    _ payload: [UInt8],
    stream id: UInt64,
    beforeRegistration: (@Sendable () -> Void)?,
    beforeStreamCreation: (@Sendable () async -> Void)? = nil,
    afterRegistration: (@Sendable () -> Void)? = nil,
    beforeWrite: (@Sendable () -> Void)? = nil,
    write: ControlWrite? = nil
  ) async throws {
    guard role == .server else { throw RSTTransportError.notStarted }
    guard payload.count <= SnapshotStreamAccumulator.hardLimit else {
      throw RSTTransportError.snapshotTooLarge
    }
    guard !Task.isCancelled else { throw RSTTransportError.canceled }
    let admissionID = UUID()
    let canceled = try state.withLock { s -> Bool in
      if s.closed { throw RSTTransportError.closed }
      if s.takePreCancellation(id) {
        s.lifecycle.append("snapshot \(id) pre-canceled")
        return true
      }
      guard s.admittedSnapshotSends.count < Self.maxPendingSnapshotSends else {
        s.lifecycle.append("snapshot \(id) refused,admission full")
        throw RSTTransportError.resourceLimit
      }
      s.admittedSnapshotSends.insert(admissionID)
      s.lifecycle.append(
        "snapshot \(id) admitted,bytes=\(payload.count),"
          + "slots=\(s.admittedSnapshotSends.count)"
      )
      return false
    }
    if canceled { throw RSTTransportError.canceled }
    // Once submitted, the native completion owns this reservation, even if
    // cancellation or replacement resumes the caller before that completion.
    var submitted = false
    defer {
      if !submitted {
        state.withLock { s in
          s.admittedSnapshotSends.remove(admissionID)
          s.lifecycle.append(
            "snapshot \(id) slot released unsubmitted,"
              + "slots=\(s.admittedSnapshotSends.count)"
          )
        }
      }
    }
    await beforeStreamCreation?()
    guard !Task.isCancelled else { throw RSTTransportError.canceled }
    guard !state.withLock({ $0.closed }) else { throw RSTTransportError.closed }
    guard
      let stream = NWConnection(
        from: group,
        using: QUICOptions.unidirectionalStream()
      )
    else {
      record("snapshot \(id) stream creation failed,group=\(group.state)")
      throw RSTTransportError.closed
    }

    beforeRegistration?()

    stream.stateUpdateHandler = { [weak self, weak stream] newState in
      guard let stream else { return }
      self?
        .traceStream(stream, event: "outbound state \(newState),snapshot=\(id)")
      switch newState {
      case let .failed(error):
        self?.finishOutbound(id: id, stream: stream, error: error)
      case .cancelled:
        self?
          .finishOutbound(
            id: id,
            stream: stream,
            error: RSTTransportError.canceled
          )
      default: break
      }
    }
    let previous: OutboundSnapshot?
    do {
      previous = try state.withLock { s in
        guard !s.closed else { throw RSTTransportError.closed }
        guard !s.takePreCancellation(id) else {
          throw RSTTransportError.canceled
        }
        let previous = s.outbound.updateValue(
          OutboundSnapshot(stream: stream, writeIncludesFIN: write == nil),
          forKey: id
        )
        // Publish pending retirement in the same transition that supersedes
        // the old stream. Its send callback may run as soon as this lock opens.
        if let previous, !previous.sent {
          s.parkedFinishes[ObjectIdentifier(previous.stream)] = (
            previous.stream, previous.writeIncludesFIN
          )
        }
        s.outboundOrder.removeAll { $0 == id }
        s.outboundOrder.append(id)
        s.openedSnapshotStreams += 1
        s.lifecycle.append(
          "snapshot \(id) registered,object=\(ObjectIdentifier(stream)),"
            + "opened=\(s.openedSnapshotStreams),"
            + "superseded=\(previous.map { "\(ObjectIdentifier($0.stream)),sent=\($0.sent)" } ?? "none")"
        )
        return previous
      }
    } catch {
      stream.cancel()
      throw error
    }
    afterRegistration?()
    if let previous {
      finishSupersededSnapshot(previous)
      previous.continuation?.resume(throwing: RSTTransportError.canceled)
    }
    stream.start(queue: queue)

    do {
      try await awaitSnapshotWrite(
        payload,
        id: id,
        stream: stream,
        admissionID: admissionID,
        submitted: &submitted,
        beforeWrite: beforeWrite,
        write: write
      )
      record("snapshot \(id) send returned")
    } catch {
      record("snapshot \(id) send threw \(error)")
      throw error
    }
  }

  private func awaitSnapshotWrite(
    _ payload: [UInt8],
    id: UInt64,
    stream: NWConnection,
    admissionID: UUID,
    submitted: inout Bool,
    beforeWrite: (@Sendable () -> Void)?,
    write: ControlWrite?
  ) async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        let admission = state.withLock { s -> SnapshotWriteAdmission? in
          // A cancellation that already claimed this stream (finishAfterSend)
          // drops any continuation stored after its decision, so refuse here.
          guard let entry = s.outbound[id], entry.stream === stream,
            !entry.finishAfterSend
          else { return nil }
          s.outbound[id]?.continuation = continuation
          return entry.writeAdmission
        }
        guard let admission else {
          continuation.resume(throwing: RSTTransportError.canceled)
          return
        }
        beforeWrite?()
        let completed: @Sendable (NWError?) -> Void = {
          [weak self, weak stream] error in
          guard let self else { return }
          self.state.withLock { s in
            s.admittedSnapshotSends.remove(admissionID)
            s.lifecycle.append(
              "snapshot \(id) slot released by completion,"
                + "slots=\(s.admittedSnapshotSends.count)"
            )
          }
          guard let stream else { return }
          self.sendCompleted(id: id, stream: stream, error: error)
        }
        let bytes = Data(payload)
        admission.perform {
          submitted = true
          traceStream(
            stream,
            event: "outbound write,snapshot=\(id),bytes=\(payload.count)"
          )
          if let write {
            write(stream, bytes, completed)
          } else {
            stream.send(
              content: bytes,
              contentContext: .finalMessage,
              isComplete: true,
              completion: .contentProcessed(completed)
            )
          }
        }
      }
    } onCancel: { [weak self] in
      self?.cancelSnapshot(stream: id, matching: stream)
    }
  }

  var pendingSnapshotSendsForTesting: Int {
    state.withLock { $0.outbound.values.count { $0.continuation != nil } }
  }

  var parkedSnapshotFinishesForTesting: Int {
    state.withLock { $0.parkedFinishes.count }
  }

  func snapshotStreamForTesting(_ id: UInt64) -> NWConnection? {
    state.withLock { $0.outbound[id]?.stream }
  }

  func enableSnapshotReadDiagnosticsForTesting() {
    traceSnapshotReads.store(true, ordering: .relaxed)
  }

  var snapshotReadBytesForTesting: [Int] {
    state.withLock { $0.snapshotReads.values.map(\.bytes) }
  }

  /// Captures application bookkeeping and native stream state before a
  /// stalled test cancels its send. Read Network properties outside our lock.
  var snapshotDiagnosticsForTesting: String {
    let snapshot = state.withLock { $0 }
    let outbound = snapshot.outbound.sorted { $0.key < $1.key }
      .map { id, entry in
        let metadata =
          entry.stream.metadata(definition: NWProtocolQUIC.definition)
          as? NWProtocolQUIC.Metadata
        return
          "\(id):\(entry.stream.state),nativeID=\(String(describing: metadata?.streamIdentifier)),"
          + "sent=\(entry.sent),waiting=\(entry.continuation != nil),"
          + "finishing=\(entry.finishAfterSend)"
      }
    let inbound = snapshot.inbound
      .map { id, stream in
        let metadata =
          stream.metadata(definition: NWProtocolQUIC.definition)
          as? NWProtocolQUIC.Metadata
        let progress = snapshot.snapshotReads[id]
        return
          "\(stream.state),nativeID=\(String(describing: metadata?.streamIdentifier)),"
          + "read=\(String(describing: progress))"
      }
      .sorted()
    let control = snapshot.control.map { String(describing: $0.state) } ?? "nil"
    let metadata =
      snapshot.control?.metadata(definition: NWProtocolQUIC.definition)
      as? NWProtocolQUIC.Metadata
    let groupMetadata =
      group.metadata(definition: NWProtocolQUIC.definition)
      as? NWProtocolQUIC.Metadata
    let now = LifecycleLog.now()
    return "closed=\(snapshot.closed),group=\(group.state),control=\(control),"
      + "termination=\(snapshot.termination ?? "none"),"
      + "nativeTermination=\(snapshot.nativeTermination ?? "none"),"
      + "admitted=\(snapshot.admittedSnapshotSends.count),outbound=\(outbound),"
      + "parked=\(snapshot.parkedFinishes.count),"
      + "preCanceled=\(snapshot.preCanceled),"
      + "retiring=\(snapshot.retiring.count),"
      + "retireCheckScheduled=\(snapshot.retireCheckScheduled),"
      + "opened=\(snapshot.openedSnapshotStreams),"
      + "inbound=\(inbound),released=\(snapshot.releasedSnapshotStreams),"
      + "localMaxStreams=\(String(describing: metadata?.localMaxStreamsUnidirectional)),"
      + "remoteMaxStreams=\(String(describing: metadata?.remoteMaxStreamsUnidirectional)),"
      + "remoteIdleTimeoutMs=\(String(describing: groupMetadata?.remoteIdleTimeout)),"
      + "settings=[\(settings),snapshotStreamWindow=\(QUICOptions.snapshotStreamWindow),"
      + "concurrentSnapshotStreams=\(QUICOptions.concurrentSnapshotStreams)],"
      + "age=\((now - createdAt) / 1000)us,"
      + "lifecycle(\(snapshot.lifecycle.total))="
      + snapshot.lifecycle.render(since: createdAt)
  }

  private func sendCompleted(id: UInt64, stream: NWConnection, error: NWError?)
  {
    traceStream(
      stream,
      event: "outbound sent,snapshot=\(id),error=\(String(describing: error))"
    )
    var canceled = false
    let (continuation, evicted, finishIncludesFIN) = state.withLock {
      s -> (CheckedContinuation<Void, any Error>?, [NWConnection], Bool?) in
      let parked = s.parkedFinishes.removeValue(
        forKey: ObjectIdentifier(stream)
      )
      guard var entry = s.outbound[id], entry.stream === stream else {
        return (nil, [], parked?.writeIncludesFIN)
      }
      let c = entry.continuation
      entry.continuation = nil
      if entry.finishAfterSend {
        s.outbound.removeValue(forKey: id)
        s.outboundOrder.removeAll { $0 == id }
        // Cancellation resumed its waiter; never strand a later one.
        canceled = true
        return (c, Self.evictSentSnapshots(&s), entry.writeIncludesFIN)
      }
      entry.sent = true
      s.outbound[id] = entry
      return (c, Self.evictSentSnapshots(&s), parked?.writeIncludesFIN)
    }
    // Leave the native send completion before finishing a superseded stream.
    if let finishIncludesFIN {
      finishSnapshotStream(stream, finQueued: finishIncludesFIN && error == nil)
    }
    for stream in evicted { queue.async { stream.cancel() } }
    if canceled {
      continuation?.resume(throwing: RSTTransportError.canceled)
    } else if let error {
      continuation?.resume(throwing: error)
    } else {
      continuation?.resume()
    }
  }

  private func finishOutbound(
    id: UInt64,
    stream: NWConnection,
    error: any Error
  ) {
    let removed = state.withLock { s -> OutboundSnapshot? in
      guard let entry = s.outbound[id], entry.stream === stream else {
        return nil
      }
      s.outbound.removeValue(forKey: id)
      s.outboundOrder.removeAll { $0 == id }
      return entry
    }
    _ = removed?.writeAdmission.cancel()
    if let stream = removed?.stream { queue.async { stream.cancel() } }
    removed?.continuation?.resume(throwing: error)
  }

  /// Abandons a superseded snapshot and cancels its application waiter.
  /// Bytes already handed to Network finish with FIN and may arrive whole;
  /// the client rejects stale revisions and discards truncated payloads. A
  /// snapshot abandoned before its write ends as an empty stream.
  ///
  /// Do not reset an accepted native send: macOS 27 can reject a late
  /// MAX_STREAM_DATA update for the closed stream with STREAM_STATE_ERROR,
  /// terminating the whole connection, including the control stream. Wait
  /// for native send completion, queue FIN, and defer cancelling the stream
  /// (see `finishSnapshotStream`).
  public func cancelSnapshot(stream id: UInt64) {
    cancelSnapshot(stream: id, matching: nil)
  }

  /// Test seam: `afterDecisionForTesting` runs after a cancellation claims a
  /// stream whose write may not have started, before it closes write admission.
  func cancelSnapshot(
    stream id: UInt64,
    matching stream: NWConnection?,
    afterDecisionForTesting: (@Sendable () -> Void)? = nil
  ) {
    guard role == .server else { return }
    let decision = state.withLock { s -> SnapshotCancellation in
      if let stream, s.outbound[id]?.stream !== stream { return .absent }
      guard var entry = s.outbound[id] else {
        s.lifecycle.append("cancel \(id) untracked,closed=\(s.closed)")
        if !s.closed, !s.preCanceled.contains(id) {
          // Keep recent registration races without flushing unrelated
          // cancellations when the history reaches its capacity.
          if s.preCanceled.count == Self.maxPreCanceledSnapshots {
            s.preCanceled.removeFirst()
          }
          s.preCanceled.append(id)
        }
        return .absent
      }
      s.lifecycle.append(
        "cancel \(id) object=\(ObjectIdentifier(entry.stream)),"
          + "sent=\(entry.sent),finishing=\(entry.finishAfterSend),"
          + "waiting=\(entry.continuation != nil)"
      )
      if entry.finishAfterSend { return .absent }
      let continuation = entry.continuation
      entry.continuation = nil
      if entry.sent {
        s.outbound.removeValue(forKey: id)
        s.outboundOrder.removeAll { $0 == id }
        return .now(entry.stream, entry.writeIncludesFIN, continuation)
      }
      entry.finishAfterSend = true
      s.outbound[id] = entry
      return .afterSend(entry.writeAdmission, id, entry.stream, continuation)
    }
    switch decision {
    case .absent: return
    case let .now(stream, writeIncludesFIN, continuation):
      continuation?.resume(throwing: RSTTransportError.canceled)
      finishSnapshotStream(stream, finQueued: writeIncludesFIN)
    case let .afterSend(admission, id, stream, continuation):
      continuation?.resume(throwing: RSTTransportError.canceled)
      afterDecisionForTesting?()
      guard !admission.cancel() else { return }
      let pending = state.withLock {
        s -> (NWConnection, CheckedContinuation<Void, any Error>?)? in
        guard let entry = s.outbound[id], entry.stream === stream,
          entry.finishAfterSend, !entry.sent
        else { return nil }
        s.outbound.removeValue(forKey: id)
        s.outboundOrder.removeAll { $0 == id }
        return (stream, entry.continuation)
      }
      pending?.1?.resume(throwing: RSTTransportError.canceled)
      // No native write was submitted, so FIN has not been queued.
      if let pending { finishSnapshotStream(pending.0, finQueued: false) }
    }
  }

  private enum SnapshotCancellation {
    case absent
    case now(NWConnection, Bool, CheckedContinuation<Void, any Error>?)
    case afterSend(
      SnapshotWriteAdmission,
      UInt64,
      NWConnection,
      CheckedContinuation<Void, any Error>?
    )
  }

  private static func evictSentSnapshots(_ state: inout State) -> [NWConnection]
  {
    var evicted: [NWConnection] = []
    while state.outboundOrder.count > Self.maxTrackedOutbound,
      let oldest = state.outboundOrder.first(where: {
        state.outbound[$0]?.sent == true
      })
    {
      state.outboundOrder.removeAll { $0 == oldest }
      if let entry = state.outbound.removeValue(forKey: oldest) {
        state.lifecycle.append(
          "snapshot \(oldest) evicted,object=\(ObjectIdentifier(entry.stream))"
        )
        evicted.append(entry.stream)
      }
    }
    return evicted
  }

  /// Finishes a superseded stream with FIN after the current Network callback
  /// returns, and retires its connection wrapper later.
  ///
  /// Network reports no peer acknowledgment, and cancelling a stream the peer
  /// is still reading can abort the group. So the stream waits in `retiring`
  /// until the peer has released every stream opened so far,
  /// `maxTrackedOutbound` newer streams retire, or the connection closes.
  private func finishSnapshotStream(_ stream: NWConnection, finQueued: Bool) {
    queue.async { [weak self] in
      guard let self else {
        stream.cancel()
        return
      }
      // The application no longer tracks this stream or needs its callbacks.
      stream.stateUpdateHandler = nil
      if !finQueued {
        stream.send(
          content: nil,
          contentContext: .finalMessage,
          isComplete: true,
          completion: .idempotent
        )
      }
      self.traceStream(stream, event: "outbound finish,queued=\(finQueued)")
      let (expired, check) = self.state.withLock {
        s -> ([NWConnection], Bool) in
        guard !s.closed else { return ([stream], false) }
        s.retiring.append(stream)
        let overflow = max(0, s.retiring.count - Self.maxTrackedOutbound)
        defer { s.retiring.removeFirst(overflow) }
        return (Array(s.retiring.prefix(overflow)), !s.retireCheckScheduled)
      }
      self.retire(expired)
      if check { self.retireReleasedStreams() }
    }
  }

  /// Cancels every retiring stream once the peer has released all snapshot
  /// streams opened so far. The client raises its unidirectional stream limit
  /// by one for each stream it has finished reading (`releaseSnapshotCredit`);
  /// Network offers no per-stream signal, so check again shortly until then.
  /// Runs on `queue`, the only place streams join `retiring`.
  private func retireReleasedStreams() {
    let (control, opened) = state.withLock {
      ($0.control, $0.openedSnapshotStreams)
    }
    let metadata =
      control?.metadata(definition: NWProtocolQUIC.definition)
      as? NWProtocolQUIC.Metadata
    let released = metadata.map {
      Int($0.remoteMaxStreamsUnidirectional)
        - QUICOptions.concurrentSnapshotStreams
    }
    let (expired, recheck) = state.withLock { s -> ([NWConnection], Bool) in
      s.retireCheckScheduled = false
      if s.lastRetireWait?.released != released
        || s.lastRetireWait?.opened != opened
      {
        s.lastRetireWait = (released, opened)
        s.lifecycle.append(
          "retire check,released=\(String(describing: released)),"
            + "opened=\(opened),retiring=\(s.retiring.count)"
        )
      }
      if let released, released >= opened {
        defer { s.retiring.removeAll() }
        return (s.retiring, false)
      }
      guard !s.closed, !s.retiring.isEmpty else { return ([], false) }
      s.retireCheckScheduled = true
      return ([], true)
    }
    retire(expired)
    if recheck {
      queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
        self?.retireReleasedStreams()
      }
    }
  }

  private func retire(_ streams: [NWConnection]) {
    for stream in streams {
      stream.cancel()
      traceStream(stream, event: "outbound retire")
    }
  }

  /// The previous snapshot id was replaced. Finish it when no native send
  /// is outstanding; otherwise wait for that send's completion.
  private func finishSupersededSnapshot(_ previous: OutboundSnapshot) {
    let submitted = previous.writeAdmission.cancel()
    if previous.sent {
      finishSnapshotStream(
        previous.stream,
        finQueued: previous.writeIncludesFIN
      )
    } else if !submitted {
      // No callback will arrive for an unsubmitted write. Claim the parked
      // stream unless termination already retired it; its FIN is still owed.
      let parked = state.withLock {
        $0.parkedFinishes.removeValue(forKey: ObjectIdentifier(previous.stream))
      }
      if let parked { finishSnapshotStream(parked.stream, finQueued: false) }
    }
  }

  /// Test hook: opens a server unidirectional stream and writes `bytes`
  /// verbatim, with or without FIN, bypassing every sender-side check.
  /// Returns the stream so a test can reset it.
  func sendRawStreamForTesting(
    _ bytes: [UInt8],
    finish: Bool
  ) async throws -> NWConnection {
    guard
      let stream = NWConnection(
        from: group,
        using: QUICOptions.unidirectionalStream()
      )
    else { throw RSTTransportError.closed }
    state.withLock { $0.openedSnapshotStreams += 1 }
    stream.start(queue: queue)
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      stream.send(
        content: Data(bytes),
        contentContext: finish ? .finalMessage : .defaultMessage,
        isComplete: finish,
        completion: .contentProcessed { error in
          if let error {
            continuation.resume(throwing: error)
          } else {
            continuation.resume()
          }
        }
      )
    }
    return stream
  }

  // MARK: Inbound snapshots (client)

  typealias SnapshotReadGate =
    @Sendable (Int, @escaping @Sendable () -> Void) -> Bool

  /// Defers one stream's read without blocking the connection's callback queue.
  func setBeforeSnapshotReadForTesting(_ gate: SnapshotReadGate?) {
    let previous = state.withLock { s in
      let previous = s.beforeSnapshotReadForTesting
      s.beforeSnapshotReadForTesting = gate
      return previous
    }
    if gate != nil { traceSnapshotReads.store(true, ordering: .relaxed) }
    withExtendedLifetime(previous) {}
  }

  private func readSnapshot(
    from stream: NWConnection,
    into accumulator: SnapshotStreamAccumulator
  ) {
    if traceSnapshotReads.load(ordering: .relaxed),
      let gate = state.withLock({ $0.beforeSnapshotReadForTesting }),
      gate(
        accumulator.bytes.count,
        { [weak self] in
          self?.queue
            .async { [weak self] in
              self?.receiveSnapshot(from: stream, into: accumulator)
            }
        }
      )
    {
      return
    }
    receiveSnapshot(from: stream, into: accumulator)
  }

  private func receiveSnapshot(
    from stream: NWConnection,
    into accumulator: SnapshotStreamAccumulator
  ) {
    state.withLock { s in
      let id = ObjectIdentifier(stream)
      guard s.inbound[id] != nil else { return }
      s.snapshotReads[id, default: SnapshotReadProgress()].pending = true
    }
    stream.receive(
      minimumIncompleteLength: 1,
      maximumLength: accumulator.nextReadLimit
    ) { [weak self] data, _, isComplete, error in
      guard let self else {
        stream.cancel()
        return
      }
      // Every chunk only when tracing; otherwise the first and the last.
      if self.traceSnapshotReads.load(ordering: .relaxed) || isComplete
        || error != nil || accumulator.bytes.isEmpty
      {
        self.traceStream(
          stream,
          event: "receive complete=\(isComplete),bytes=\(data?.count ?? 0),"
            + "total=\(accumulator.bytes.count + (data?.count ?? 0)),"
            + "error=\(String(describing: error))"
        )
      }
      self.state.withLock { s in
        let id = ObjectIdentifier(stream)
        guard s.inbound[id] != nil else { return }
        var progress = s.snapshotReads[id] ?? SnapshotReadProgress()
        progress.callbacks += 1
        progress.bytes += data?.count ?? 0
        progress.pending = false
        progress.complete = isComplete
        s.snapshotReads[id] = progress
      }
      var accumulator = accumulator
      if error != nil {
        // Reset or failed: discard whatever arrived. The stream is already
        // terminated by the peer, so only release it locally. Do that on
        // the next queue turn; cancelling inside this callback aborts the group.
        self.releaseInbound(stream, reject: false)
        return
      }
      if let data, !data.isEmpty {
        do { try accumulator.append(data) } catch {
          self.releaseInbound(stream, reject: true)
          return
        }
      }
      guard isComplete else {
        self.readSnapshot(from: stream, into: accumulator)
        return
      }
      // The server ends a snapshot abandoned before its write as an empty
      // stream. Release it without rejecting it.
      if accumulator.bytes.isEmpty {
        self.releaseInbound(stream, reject: false)
        return
      }
      guard let payload = try? accumulator.finish() else {
        self.releaseInbound(stream, reject: true)
        return
      }
      // Keep the stream (and its stream credit) until delivered, so
      // undelivered snapshots stay bounded by the QUIC stream limit.
      _ = self.state.withLock {
        $0.deliveringSnapshots.insert(ObjectIdentifier(stream))
      }
      self.mailbox.post(
        .snapshot(
          payload,
          done: { [weak self] in
            guard let self else {
              stream.cancel()
              return
            }
            self.releaseInbound(stream, reject: false)
          }
        )
      )
    }
  }

  /// QUIC `MAX_STREAMS` is a cumulative count, and Network framework does
  /// not raise it as streams close: without this the server could open
  /// only `concurrentSnapshotStreams` snapshots per connection. Each
  /// released stream extends the limit by one.
  /// The test hook holds an older update after its limit check, verifying
  /// that Network preserves the larger limit when another return wins.
  func releaseSnapshotCredit(
    beforeUpdateForTesting: (@Sendable () -> Void)? = nil
  ) {
    let (control, released) = state.withLock { s -> (NWConnection?, Int) in
      s.releasedSnapshotStreams += 1
      return (s.control, s.releasedSnapshotStreams)
    }
    guard let control,
      let metadata = control.metadata(definition: NWProtocolQUIC.definition)
        as? NWProtocolQUIC.Metadata
    else { return }
    let limit = released + QUICOptions.concurrentSnapshotStreams
    let current = metadata.localMaxStreamsUnidirectional
    record("credit released=\(released),limit=\(limit),local=\(current)")
    if current < limit {
      beforeUpdateForTesting?()
      metadata.localMaxStreamsUnidirectional = limit
    }
  }

  private func releaseInbound(_ stream: NWConnection, reject: Bool) {
    queue.async { [weak self] in
      guard let self else {
        stream.cancel()
        return
      }
      self.traceStream(stream, event: "inbound release,reject=\(reject)")
      if reject {
        self.discard(stream)
      } else {
        self.forget(inbound: stream)
        stream.cancel()
      }
      self.settleCredit(ObjectIdentifier(stream), unlessDelivering: false)
    }
  }

  private func discard(_ stream: NWConnection) {
    forget(inbound: stream)
    finishReject(stream)
  }

  // MARK: Lifecycle

  /// Grace period for an orderly close to reach the peer before the
  /// connection group is canceled.
  static let closeGrace: DispatchTimeInterval = .milliseconds(500)

  /// Orderly close: finishes the control stream (FIN) so the peer sees an
  /// explicit end, then cancels the group once that FIN was handed to
  /// QUIC (bounded by `closeGrace`). Canceling the group alone does not
  /// reliably notify the peer before its idle timeout.
  public func close() {
    terminate(error: nil, graceful: true, source: "local close")
  }

  /// Idempotent teardown: fails waiters and pending sends, cancels the
  /// group (and with it every stream), and delivers `onClosed` once.
  func terminate(
    error: (any Error)?,
    graceful: Bool = false,
    source: String = "external"
  ) {
    let snapshot = state.withLock { s -> State? in
      guard !s.closed else { return nil }
      s.closed = true
      s.termination =
        source + ": " + String(String(describing: error).prefix(256))
      s.lifecycle.append("terminate \(s.termination ?? "")")
      let copy = s
      s.control = nil
      s.controlSends = [:]
      s.outbound = [:]
      s.outboundOrder = []
      s.parkedFinishes.removeAll()
      s.retiring.removeAll()
      s.preCanceled.removeAll()
      s.inbound = [:]
      s.snapshotReads = [:]
      s.beforeInboundStartForTesting = nil
      s.beforeSnapshotReadForTesting = nil
      s.onViabilityChange = nil
      s.onBetterPath = nil
      s.onTerminated = nil
      return copy
    }
    guard let snapshot else { return }
    // Inspect retained native objects outside our lock and before cancelling
    // them. Later callbacks must not replace the first termination record.
    let metadata =
      group.metadata(definition: NWProtocolQUIC.definition)
      as? NWProtocolQUIC.Metadata
    let controlMetadata =
      snapshot.control?.metadata(definition: NWProtocolQUIC.definition)
      as? NWProtocolQUIC.Metadata
    let applicationError = metadata?.applicationError
    let groupState = String(String(describing: group.state).prefix(128))
    let controlState = String(
      String(describing: snapshot.control?.state).prefix(128)
    )
    let native =
      "group=\(groupState),control=\(controlState),"
      + "nativeApplicationCode=\(String(describing: applicationError?.code)),"
      + "nativeReason=\(String((applicationError?.reason ?? "none").prefix(256))),"
      + "nativeControlApplicationCode=\(String(describing: controlMetadata?.applicationError.code)),"
      + "nativeControlStreamCode=\(String(describing: controlMetadata?.streamApplicationErrorCode))"
    state.withLock { s in
      s.nativeTermination = native
      s.lifecycle.append("terminate native \(native)")
    }
    for entry in snapshot.controlSends.values {
      entry.waiter?.resume(throwing: RSTTransportError.closed)
      entry.completion?.resume(throwing: RSTTransportError.closed)
    }
    for entry in snapshot.outbound.values {
      _ = entry.writeAdmission.cancel()
      entry.continuation?.resume(throwing: RSTTransportError.closed)
    }
    for parked in snapshot.parkedFinishes.values { parked.stream.cancel() }
    for stream in snapshot.retiring { stream.cancel() }
    if graceful, let control = snapshot.control, case .ready = control.state {
      let group = self.group
      control.send(
        content: nil,
        contentContext: .finalMessage,
        isComplete: true,
        completion: .contentProcessed { [queue] _ in
          // Let the FIN leave before the group (and the stream) goes.
          queue.asyncAfter(deadline: .now() + .milliseconds(50)) {
            group.cancel()
          }
        }
      )
      queue.asyncAfter(deadline: .now() + Self.closeGrace) { group.cancel() }
    } else {
      group.cancel()
    }
    mailbox.post(.closed(error))
    snapshot.onTerminated?()
  }
}
