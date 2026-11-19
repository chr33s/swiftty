import Dispatch
import Foundation
import SwiftMuxProtocol
import SwiftMuxXPC

extension Duration {
  fileprivate var dispatchDeadline: DispatchTime {
    let remaining = max(.zero, self)
    // Stay below Dispatch's signed nanosecond conversion, including rounding.
    guard remaining <= .seconds(Int64.max / 1_000_000_000 - 1) else {
      return .distantFuture
    }
    let (seconds, attoseconds) = remaining.components
    return .now() + TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
  }
}

/// The single concrete connection to the SwiftMux service.
///
/// Exactly one bounded event consumer (`nextEvent`). Frames are delivered
/// one per pane at a time: the service sends the next only after this
/// connection acknowledges the previous, which happens when the consumer
/// takes it. Nothing is replayed after connection loss.
/// Input and paste admission shares 256 job slots and four MiB of payload
/// charges, retained through dispatch, pane queues and wire acknowledgments.
/// Each input record has a five-second acknowledgment deadline. Missing one
/// fails the channel and releases its lease; transmitted input is not replayed.
/// Commands share 64 slots and four MiB of payload charges through dispatch
/// and wire replies. Cancelling a
/// caller or ending its wait does not refund a transmitted command slot.
public actor MuxConnection {
  public nonisolated let queue: DispatchSerialQueue
  public nonisolated var unownedExecutor: UnownedSerialExecutor {
    queue.asUnownedSerialExecutor()
  }

  private let channel: SMXChannel
  private nonisolated let inputAdmission = MuxInputAdmission()
  private nonisolated let commandAdmission = MuxCommandAdmission()
  public static let maxPendingCommands = MuxCommandAdmission.maxJobs
  private var commandAdmissions: [UInt64: MuxCommandAdmission.Reservation] = [:]
  /// Outstanding `switchWorkspace` requests; their success voids Ready.
  private var switchRequests: Set<UInt64> = []

  package var pendingCommandCountForTesting: Int { commandAdmissions.count }
  private var requestTimeoutDeadlines: [UInt64: ContinuousClock.Instant] = [:]
  private var requestTimeoutTimer: DispatchSourceTimer?
  private var requestTimeoutWake: ContinuousClock.Instant?
  package var pendingCommandTimeoutCountForTesting: Int {
    requestTimeoutDeadlines.count
  }
  /// Delays timer delivery without changing recorded deadlines, so native
  /// tests can exercise replies handled before an overdue timer callback.
  package func delayRequestTimeoutDeliveryForTesting() {
    requestTimeoutTimer?.schedule(deadline: .distantFuture)
  }
  // Begin/cancel control records are additionally bounded by the 256 job
  // reservations; closing an envelope must not require ordinary ACK credit.
  private static let maxInputAcknowledgments = 2048
  private var inputAcknowledgmentTimeout: Duration = .seconds(5)
  private var inputAcknowledgmentDeadlines: [UInt64: ContinuousClock.Instant] =
    [:]
  private var inputAcknowledgmentTimer: DispatchSourceTimer?
  private var inputAcknowledgmentWake: ContinuousClock.Instant?

  package func setInputAcknowledgmentTimeout(_ timeout: Duration) {
    precondition(timeout > .zero)
    inputAcknowledgmentTimeout = timeout
  }
  /// Preserves ACK deadlines while delaying the owned timer's delivery.
  package func delayInputAcknowledgmentDeliveryForTesting() {
    inputAcknowledgmentTimer?.schedule(deadline: .distantFuture)
  }
  public private(set) var welcome: Welcome?
  public private(set) var attachment: AttachmentID?
  /// Installed owned frames. A stale revision never replaces a newer one.
  public private(set) var installation = FrameInstallation()
  /// Nil until the service has seen an installed frame for every required
  /// visible pane. The attach reply does not set this.
  public private(set) var readiness: ReadyNotice?
  /// When set, frames are installed but not acknowledged, so the service
  /// must not report Ready.
  package var suppressesFrameAcknowledgement = false

  /// Tests withhold frame credit without dropping the connection.
  package func setSuppressesFrameAcknowledgement(_ suppress: Bool) {
    suppressesFrameAcknowledgement = suppress
  }
  private let capabilities: ClientCapabilities
  private var nextRequest: UInt64 = 1
  private var nextInput: UInt64 = 1
  private var nextPaste: UInt64 = 1
  private var requests: [UInt64: CheckedContinuation<MuxReply, any Error>] = [:]
  private var inputs: [UInt64: (MuxError?) -> Void] = [:]
  private struct InputWaiter {
    let id: UUID
    let continuation: CheckedContinuation<Void, any Error>
    let admission: MuxInputAdmission.Reservation?
  }

  private var inputWaiters: [UInt64: InputWaiter] = [:]
  private var callbacks: [UInt64: (Result<MuxReply, MuxError>) -> Void] = [:]
  private var handshake: CheckedContinuation<Welcome, any Error>?
  private var handshakeDeadline: ContinuousClock.Instant?
  private var events: [MuxEvent] = []
  private var eventHead = 0
  private struct EventWaiter {
    let id: UUID
    let continuation: CheckedContinuation<MuxEvent?, any Error>
  }

  private var waiter: EventWaiter?
  private var closedError: MuxError?
  private var isClosed = false
  private var closedDeliberately = false
  private var channelCancelled = false
  /// Panes with a paste envelope open, each with the pastes (and the
  /// input enqueued after them) waiting for it to close: one paste per
  /// pane at a time, in call order.
  private var pasting: [PaneID: [PaneJob]] = [:]
  private struct ActivePaste {
    let id: UInt64
    let beginSequence: UInt64
    let completion: (Result<PasteState, any Error>) -> Void
    var task: Task<Void, Never>?
  }

  private var activePastes: [PaneID: ActivePaste] = [:]
  /// The service's refusal of a paste's begin record, by paste id.
  private var pasteRefusals: [UInt64: MuxError] = [:]

  package var pendingPasteCountForTesting: Int {
    activePastes.count
      + pasting.values.reduce(0) { count, jobs in
        count
          + jobs.filter { if case .paste = $0 { true } else { false } }.count
      }
  }

  private enum PaneJob {
    case input(MuxInput, rejected: (@Sendable (MuxError) -> Void)?)
    case paste(
      UInt64,
      String,
      completion: (Result<PasteState, any Error>) -> Void
    )
  }

  /// Non-frame events held for the consumer before the connection fails.
  public static let maxBufferedEvents = 4096

  private init(
    channel: SMXChannel,
    queue: DispatchSerialQueue,
    capabilities: ClientCapabilities
  ) {
    self.channel = channel
    self.queue = queue
    self.capabilities = Self.negotiable(capabilities)
  }

  /// `SWMUX_FRAME_CODEC=json` keeps frames in JSON for debugging.
  static func negotiable(
    _ capabilities: ClientCapabilities
  ) -> ClientCapabilities {
    var capabilities = capabilities
    if ProcessInfo.processInfo.environment["SWMUX_FRAME_CODEC"] == "json" {
      capabilities.remove(.binaryFrames)
    }
    return capabilities
  }

  /// Recently delivered frames per pane: the bases a delta may name
  /// (spec.multiplexer.md §4, "Frame deltas").
  private var deltaBases: [PaneID: [PaneFrame]] = [:]
  static let retainedDeltaBases = 4
  /// Deltas applied and full frames requested (tests, diagnostics).
  package private(set) var deltaStatistics = (applied: 0, requestedFull: 0)

  private func retainBase(_ frame: PaneFrame) {
    guard capabilities.contains(.frameDeltas), frame.rowVersions != nil else {
      return
    }
    var list = deltaBases[frame.identity.pane, default: []]
    list.removeAll { $0.identity.revision == frame.identity.revision }
    list.append(frame)
    if list.count > Self.retainedDeltaBases {
      list.removeFirst(list.count - Self.retainedDeltaBases)
    }
    deltaBases[frame.identity.pane] = list
  }

  /// The complete frame `delta` describes, or nil after asking for one:
  /// the delta is acknowledged (its credit is released) and the service
  /// is told to forget its base.
  private func resolve(_ delta: FrameDelta) -> PaneFrame? {
    let limits = welcome?.limits ?? .standard
    if let base = deltaBases[delta.identity.pane]?
      .last(where: { $0.identity.revision == delta.baseRevision }),
      let frame = try? FrameDeltaApplier.apply(delta, to: base, limits: limits)
    {
      deltaStatistics.applied += 1
      return frame
    }
    deltaStatistics.requestedFull += 1
    if !suppressesFrameAcknowledgement { acknowledgeFrame(delta.identity) }
    transmit(
      .requestFullFrame(
        pane: delta.identity.pane,
        attachment: delta.identity.attachment
      )
    )
    return nil
  }

  isolated deinit {
    inputAcknowledgmentTimer?.cancel()
    requestTimeoutTimer?.cancel()
  }

  /// Connects to the launchd service and performs the handshake.
  public static func connect(
    machService name: String = ProcessInfo.processInfo.environment[
      "SWMUX_SERVICE"
    ] ?? SMX.defaultMachService,
    frontend: FrontendKind,
    terminalProfile: String? = nil,
    capabilities: ClientCapabilities = .supported
  ) async throws -> MuxConnection {
    try Task.checkCancellation()
    let queue = DispatchSerialQueue(
      label: "swiftmux.client",
      qos: .userInitiated
    )
    let channel = SMXChannel.connect(machService: name, queue: queue)
    return try await start(
      channel,
      queue,
      frontend,
      terminalProfile,
      capabilities: capabilities
    )
  }

  /// Connects to an in-process anonymous listener (tests).
  public static func connect(
    endpoint: SMXEndpoint,
    frontend: FrontendKind,
    terminalProfile: String? = nil,
    capabilities: ClientCapabilities = .supported
  ) async throws -> MuxConnection {
    try await connect(
      endpoint: endpoint,
      frontend: frontend,
      terminalProfile: terminalProfile,
      capabilities: capabilities,
      beforeHandshakeTimeoutForTesting: nil
    )
  }

  package static func connect(
    endpoint: SMXEndpoint,
    frontend: FrontendKind,
    terminalProfile: String? = nil,
    capabilities: ClientCapabilities = .supported,
    beforeHandshakeTimeoutForTesting: (@Sendable () async -> Void)?,
    beforeReturnForTesting: (@Sendable (MuxConnection) async throws -> Void)? =
      nil
  ) async throws -> MuxConnection {
    try Task.checkCancellation()
    let queue = DispatchSerialQueue(
      label: "swiftmux.client",
      qos: .userInitiated
    )
    let channel = SMXChannel.connect(endpoint: endpoint, queue: queue)
    return try await start(
      channel,
      queue,
      frontend,
      terminalProfile,
      capabilities: capabilities,
      beforeHandshakeTimeoutForTesting: beforeHandshakeTimeoutForTesting,
      beforeReturnForTesting: beforeReturnForTesting
    )
  }

  private static func start(
    _ channel: SMXChannel,
    _ queue: DispatchSerialQueue,
    _ frontend: FrontendKind,
    _ profile: String?,
    capabilities: ClientCapabilities = .supported,
    beforeHandshakeTimeoutForTesting: (@Sendable () async -> Void)? = nil,
    beforeReturnForTesting: (@Sendable (MuxConnection) async throws -> Void)? =
      nil
  ) async throws -> MuxConnection {
    let connection = MuxConnection(
      channel: channel,
      queue: queue,
      capabilities: capabilities
    )
    do {
      try await connection.open(
        Hello(
          frontend: frontend,
          terminalProfile: profile,
          capabilities: capabilities
        ),
        beforeHandshakeTimeoutForTesting: beforeHandshakeTimeoutForTesting
      )
      try await beforeReturnForTesting?(connection)
      try await connection.checkOpen()
      try Task.checkCancellation()
      return connection
    } catch {
      await connection.close()
      throw error
    }
  }

  package func checkOpen() throws {
    guard !isClosed else { throw closedError ?? MuxError(.connectionLost) }
  }

  private func open(
    _ hello: Hello,
    beforeHandshakeTimeoutForTesting: (@Sendable () async -> Void)?
  ) async throws {
    try Task.checkCancellation()
    let deadline = ContinuousClock.now + .seconds(Self.handshakeTimeout)
    handshakeDeadline = deadline
    defer { handshakeDeadline = nil }
    channel.activate(
      recordLimit: { [weak self] in
        self?
          .assumeIsolated {
            SMXCodec.serverRecordLimit($0.welcome?.limits ?? .standard)
          } ?? SMXCodec.serverRecordLimit(.standard)
      },
      { [weak self] event in self?.assumeIsolated { $0.receive(event) } }
    )
    // A peer the service refuses (for example, a different signing team)
    // gets no reply; fail the handshake instead of waiting forever.
    let timeout = queue
    timeout.asyncAfter(
      deadline: (deadline - ContinuousClock.now).dispatchDeadline
    ) { [weak self] in
      if let beforeHandshakeTimeoutForTesting {
        Task { [weak self] in
          await beforeHandshakeTimeoutForTesting()
          await self?.expireHandshake()
        }
      } else {
        self?.assumeIsolated { $0.expireHandshake() }
      }
    }
    let queue = queue
    let welcome = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        handshake = continuation
        transmit(.hello(hello))
      }
    } onCancel: {
      queue.async { [weak self] in
        self?
          .assumeIsolated { connection in
            guard let handshake = connection.handshake else { return }
            connection.handshake = nil
            handshake.resume(throwing: CancellationError())
            connection.close()
          }
      }
    }
    guard SMX.compatibleVersions.contains(welcome.protocolVersion) else {
      throw MuxError(
        .incompatibleVersion,
        "service speaks SMX/\(welcome.protocolVersion)"
      )
    }
    if hello.frontend == .terminal {
      guard hello.terminalProfile == SMX.terminalProfile,
        welcome.acceptedProfile == hello.terminalProfile
      else {
        throw MuxError(
          .invalidRequest,
          "service did not accept the supported terminal profile"
        )
      }
    }
    try welcome.limits.validateForClient()
    guard ContinuousClock.now < deadline else {
      let error = Self.handshakeTimeoutError
      fail(error)
      throw error
    }
    self.welcome = welcome
  }

  public static let handshakeTimeout: TimeInterval = 5

  private static var handshakeTimeoutError: MuxError {
    MuxError(
      .connectionLost,
      "the service did not answer; it may be signed by a different team or not running"
    )
  }

  private func expireHandshake() {
    guard handshake != nil else { return }
    fail(Self.handshakeTimeoutError)
  }

  // MARK: Receiving

  private func receive(_ event: SMXChannel.Event) {
    switch event {
    case let .closed(reason): fail(MuxError(.connectionLost, reason))
    case let .message(data) where SMXB.isRecord(data):
      let record: SMXB.Record
      do {
        record = try SMXB.decode(data, limits: welcome?.limits ?? .standard)
      } catch {
        fail(error)
        return
      }
      guard case .mux = record.envelope else {
        return fail(MuxError(.invalidRequest, "frame record envelope"))
      }
      switch record.payload {
      case let .frame(frame): dispatch(.event(.frame(frame)))
      case let .delta(delta): dispatch(.event(.frameDelta(delta)))
      }
    case let .message(data):
      let message: ServerMessage
      do {
        message = try SMXCodec.decode(
          ServerMessage.self,
          from: data,
          limit: SMXCodec.serverRecordLimit(welcome?.limits ?? .standard)
        )
      } catch {
        fail(error)
        return
      }
      dispatch(message)
    }
  }

  private func dispatch(_ message: ServerMessage) {
    switch message {
    case let .welcome(w):
      // A late reply must not win just because timeout delivery is delayed.
      if let deadline = handshakeDeadline, ContinuousClock.now >= deadline {
        expireHandshake()
        return
      }
      handshake?.resume(returning: w)
      handshake = nil
    case let .rejected(error):
      if let handshake {
        handshake.resume(throwing: error)
        self.handshake = nil
      } else {
        fail(error)
      }
    case let .reply(id, result):
      // Wire admission outlives a cancelled/timed-out caller, but retires
      // with the first reply. Unknown or duplicate replies cannot mutate
      // the attachment or retire input belonging to the current lease.
      guard commandAdmissions.removeValue(forKey: id) != nil else { return }
      // The new workspace's panes get their own Ready.
      if switchRequests.remove(id) != nil, case .success = result {
        readiness = nil
      }
      // Timer delivery can lag behind a reply. The caller's wait expires
      // at its recorded deadline regardless of callback ordering.
      if let deadline = requestTimeoutDeadlines[id],
        ContinuousClock.now >= deadline
      {
        abandon(id, MuxError(.connectionLost, "no reply in time"))
      }
      removeRequestTimeout(id)
      if case let .success(.attached(attachment, snapshot)) = result {
        // Only a fresh attachment starts a new sequence. Repeating a
        // lease ID must not reuse acknowledged or outstanding input IDs.
        if self.attachment != attachment {
          failPendingInputs(MuxError(.notAttached))
          nextInput = 1
          // Frames and Ready of an earlier attachment do not gate this one.
          readiness = nil
        }
        self.attachment = attachment
        installation.retain(attachment: attachment)
        installation.retain(panes: Set(snapshot.panes.map(\.id)))
      }
      if let callback = callbacks.removeValue(forKey: id) {
        switch result {
        case let .success(reply): callback(.success(reply))
        case let .failure(error): callback(.failure(error))
        }
        return
      }
      guard let c = requests.removeValue(forKey: id) else { return }
      switch result {
      case let .success(reply): c.resume(returning: reply)
      case let .failure(error): c.resume(throwing: error)
      }
    case let .inputAck(sequence, error):
      // Delivery can precede an overdue timer callback. Its wake is a
      // lower bound on all live deadlines; inspect current ownership
      // before an ACK can retire an expired record or complete a waiter.
      if let wake = inputAcknowledgmentWake, ContinuousClock.now >= wake {
        checkInputAcknowledgments()
        guard !isClosed else { return }
      }
      inputAcknowledgmentDeadlines.removeValue(forKey: sequence)
      if inputAcknowledgmentDeadlines.isEmpty { clearInputAcknowledgments() }
      if let waiter = inputWaiters.removeValue(forKey: sequence) {
        if let error {
          waiter.continuation.resume(throwing: error)
        } else {
          waiter.continuation.resume()
        }
      }
      inputs.removeValue(forKey: sequence)?(error)
    case let .event(event):
      switch event {
      case let .ready(notice):
        // Attach itself is not Ready. Only this notice is.
        guard notice.attachment == attachment, notice.server == welcome?.server
        else { return }
        readiness = notice
      case let .layout(snapshot):
        installation.retain(panes: Set(snapshot.panes.map(\.id)))
        let shown = Set(snapshot.panes.map(\.id))
        deltaBases = deltaBases.filter { shown.contains($0.key) }
      case let .frameDelta(delta):
        if let frame = resolve(delta) { dispatch(.event(.frame(frame))) }
        return
      case let .frame(frame):
        retainBase(frame)
        guard
          installation.install(
            frame,
            server: welcome?.server,
            attachment: attachment
          )
        else {
          // A stale frame is not shown. Acknowledge it unless the caller
          // is deliberately holding credit.
          if !suppressesFrameAcknowledgement {
            acknowledgeFrame(frame.identity)
          }
          return
        }
      default: break
      }
      if case .detached = event {
        attachment = nil
        readiness = nil
        installation = FrameInstallation()
        deltaBases = [:]
        failPendingInputs(MuxError(.notAttached))
      }
      deliver(event)
    }
  }

  private func deliver(_ event: MuxEvent) {
    if let waiter {
      self.waiter = nil
      take(event)
      waiter.continuation.resume(returning: event)
      return
    }
    guard events.count - eventHead < Self.maxBufferedEvents else {
      fail(MuxError(.resourceLimit, "event consumer is not keeping up"))
      return
    }
    events.append(event)
  }

  /// Acknowledges a frame or inbox update once the consumer has it.
  private func take(_ event: MuxEvent) {
    switch event {
    case let .frame(frame):
      guard !suppressesFrameAcknowledgement else { return }
      acknowledgeFrame(frame.identity)
    case let .inbox(update): transmit(.inboxAck(revision: update.revision))
    default: break
    }
  }

  /// Ends the connection with `error` and cancels the channel, so the
  /// service releases any lease it holds.
  private func fail(_ error: MuxError) {
    cancelChannel()
    guard !isClosed else { return }
    isClosed = true
    closedError = error
    attachment = nil
    handshake?.resume(throwing: error)
    handshake = nil
    failPending(error)
    if let waiter {
      self.waiter = nil
      waiter.continuation.resume(throwing: error)
    }
  }

  private func failPending(_ error: MuxError) {
    clearRequestTimeouts()
    commandAdmissions = [:]
    switchRequests = []
    for c in requests.values { c.resume(throwing: error) }
    requests = [:]
    for c in callbacks.values { c(.failure(error)) }
    callbacks = [:]
    failPendingInputs(error)
  }

  private func failPendingInputs(_ error: MuxError) {
    clearInputAcknowledgments()
    for waiter in inputWaiters.values {
      waiter.continuation.resume(throwing: error)
    }
    inputWaiters = [:]
    for c in inputs.values { c(error) }
    inputs = [:]
    let queued = pasting.values.flatMap { $0 }
    let active = Array(activePastes.values)
    pasting = [:]
    activePastes = [:]
    pasteRefusals = [:]
    for paste in active {
      paste.task?.cancel()
      paste.completion(.failure(error))
    }
    rejectPaneJobs(queued, error: error)
  }

  private func rejectPaneJobs(_ jobs: [PaneJob], error: MuxError) {
    for job in jobs {
      switch job {
      case let .input(_, rejected): rejected?(error)
      case let .paste(_, _, completion): completion(.failure(error))
      }
    }
  }

  private func cancelChannel() {
    guard !channelCancelled else { return }
    channelCancelled = true
    channel.cancel()
  }

  // MARK: Public API

  /// The next event, or nil after a deliberate `close`.
  public func nextEvent() async throws -> MuxEvent? {
    let queue = queue
    return try await nextEvent(scheduleCancellation: {
      queue.async(execute: $0)
    })
  }

  package var hasEventWaiterForTesting: Bool { waiter != nil }

  /// Allows a test to delay cancellation cleanup until after event delivery.
  /// The scheduler must execute the cleanup on this connection's queue.
  package func nextEvent(
    scheduleCancellation:
      @escaping @Sendable (@escaping @Sendable () -> Void) -> Void
  ) async throws -> MuxEvent? {
    try Task.checkCancellation()
    if eventHead < events.count {
      let event = events[eventHead]
      eventHead += 1
      if eventHead == events.count {
        events.removeAll(keepingCapacity: true)
        eventHead = 0
      }
      take(event)
      return event
    }
    if isClosed {
      if closedDeliberately { return nil }
      throw closedError ?? MuxError(.connectionLost)
    }
    precondition(waiter == nil, "MuxConnection supports one event consumer")
    let id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        waiter = EventWaiter(id: id, continuation: $0)
      }
    } onCancel: {
      // The event may already have resumed this wait. Its delayed cleanup
      // must not cancel a subsequent consumer.
      scheduleCancellation { [weak self] in
        self?
          .assumeIsolated { connection in
            guard let waiter = connection.waiter, waiter.id == id else {
              return
            }
            connection.waiter = nil
            waiter.continuation.resume(throwing: CancellationError())
          }
      }
    }
  }

  public enum EventWaitError: Error, Equatable { case timedOut }

  /// Waits for an event within a finite duration. Timeout cancels only this
  /// consumer; the connection and later events remain available.
  public func nextEvent(timeout: Duration) async throws -> MuxEvent? {
    try Task.checkCancellation()
    guard timeout > .zero else { throw EventWaitError.timedOut }
    return try await withThrowingTaskGroup(of: MuxEvent?.self) { group in
      group.addTask { try await self.nextEvent() }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw EventWaitError.timedOut
      }
      defer { group.cancelAll() }
      guard let event = try await group.next() else {
        throw CancellationError()
      }
      return event
    }
  }

  /// Executes a command. Acknowledgement means the operation committed.
  /// Cancelling the calling task, or `timeout` passing, stops waiting
  /// (a late reply cannot complete the caller); the command may still commit.
  /// Explicit wait deadlines share one timer and retire with the wait.
  @discardableResult
  public func execute(
    _ command: MuxCommand,
    timeout: Duration? = nil
  ) async throws -> MuxReply {
    try Task.checkCancellation()
    if let closedError { throw closedError }
    let admission = try commandAdmission.reserve(command)
    let id = nextRequest
    nextRequest += 1
    let queue = queue
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        commandAdmissions[id] = admission
        requests[id] = continuation
        if let timeout { trackRequestTimeout(id, timeout: timeout) }
        if let error = request(id, command) { abandon(id, error) }
      }
    } onCancel: {
      // Runs after the continuation is registered: the actor's executor
      // is this queue.
      queue.async { [weak self] in
        self?.assumeIsolated { $0.abandon(id, CancellationError()) }
      }
    }
  }

  /// Resumes a pending request with `error`, at most once.
  private func abandon(_ id: UInt64, _ error: any Error) {
    removeRequestTimeout(id)
    requests.removeValue(forKey: id)?.resume(throwing: error)
  }

  /// A role the connection did not negotiate is refused, never widened.
  private func wire(_ command: MuxCommand) throws(MuxError) -> MuxCommand {
    if case let .attach(request) = command, request.role == .observer,
      !capabilities.contains(.observers)
    {
      throw MuxError(
        .invalidRequest,
        "observer attach needs the observers capability"
      )
    }
    return command
  }

  /// Re-runs the shipped frame gate (tests). An older or foreign frame
  /// does not replace the installed one.
  package func install(_ frame: PaneFrame) -> Bool {
    installation.install(frame, server: welcome?.server, attachment: attachment)
  }

  /// Releases one frame's credit. Tests call it to release a frame without
  /// taking the buffered event.
  package func acknowledgeFrame(_ identity: FrameIdentity) {
    transmit(
      .frameAck(
        pane: identity.pane,
        revision: identity.revision,
        attachment: identity.attachment
      )
    )
  }

  /// Sends one request. A request too large to encode is refused alone;
  /// the connection stays up.
  private func request(_ id: UInt64, _ command: MuxCommand) -> MuxError? {
    do {
      channel.send(try encode(.request(id: id, command: wire(command))))
      if case .switchWorkspace = command { switchRequests.insert(id) }
      return nil
    } catch {
      commandAdmissions.removeValue(forKey: id)
      return error
    }
  }

  /// Sends semantic input; returns once admitted to the pane's writer.
  /// Text is streamed in bounded records under the original attachment.
  /// Cancellation or failure stops the suffix; transmitted input may still
  /// be admitted.
  public func send(_ input: MuxInput, to pane: PaneID) async throws {
    try Task.checkCancellation()
    if let closedError { throw closedError }
    guard let sendingAttachment = attachment else {
      throw MuxError(.notAttached)
    }
    let admission = try inputAdmission.reserve(MuxInputAdmission.bytes(input))
    if case let .text(text) = input, text.utf8.count > textChunkBytes {
      for chunk in MuxTextChunks(text, maxBytes: textChunkBytes) {
        guard attachment == sendingAttachment else {
          throw MuxError(.notAttached)
        }
        try await submit(pane, .input(.text(chunk)), admission: admission)
      }
    } else {
      try await submit(pane, .input(input), admission: admission)
    }
  }

  /// Sends input without waiting for admission. Errors are dropped; the
  /// caller keeps order because records are sent in call order.
  public func post(_ input: MuxInput, to pane: PaneID) {
    guard attachment != nil, closedError == nil else { return }
    guard
      let admission = try? inputAdmission.reserve(
        MuxInputAdmission.bytes(input)
      )
    else { return }
    let rejected = Self.retainAdmission(admission, rejected: nil)
    if let queued = pasting[pane], !queued.isEmpty {
      pasting[pane]?.append(.input(input, rejected: rejected))
      return
    }
    transmitInput(input, to: pane, rejected: rejected)
  }

  private nonisolated static func retainAdmission(
    _ admission: MuxInputAdmission.Reservation,
    rejected: (@Sendable (MuxError) -> Void)?
  ) -> @Sendable (MuxError) -> Void {
    { error in
      withExtendedLifetime(admission) { if let rejected { rejected(error) } }
    }
  }

  /// Sends input records; text longer than a paste chunk is split on
  /// scalar boundaries so each record stays within the record limit.
  private func transmitInput(
    _ input: MuxInput,
    to pane: PaneID,
    rejected: (@Sendable (MuxError) -> Void)?
  ) {
    guard let attachment, closedError == nil else {
      rejected?(closedError ?? MuxError(.notAttached))
      return
    }
    let parts: [MuxInput]
    let maxBytes = textChunkBytes
    let available =
      Self.maxInputAcknowledgments - inputAcknowledgmentDeadlines.count
    if case let .text(text) = input, text.utf8.count > maxBytes {
      let bytes = text.utf8.count
      let unit = max(maxBytes, 4)
      // Bound chunk-array construction even for a peer proposing tiny chunks.
      let minimumRecords = bytes / unit + (bytes % unit == 0 ? 0 : 1)
      guard minimumRecords <= available else {
        rejected?(
          MuxError(.resourceLimit, "client input acknowledgment buffer is full")
        )
        return
      }
      parts = Self.chunks(text, maxBytes: maxBytes).map { .text($0) }
    } else {
      parts = [input]
    }
    guard parts.count <= available else {
      rejected?(
        MuxError(.resourceLimit, "client input acknowledgment buffer is full")
      )
      return
    }
    for part in parts {
      guard closedError == nil else { return }
      let sequence = nextInput
      nextInput += 1
      if let rejected { inputs[sequence] = { if let e = $0 { rejected(e) } } }
      transmit(
        .input(
          InputRecord(
            sequence: sequence,
            attachment: attachment,
            pane: pane,
            payload: .input(part)
          )
        )
      )
    }
  }

  /// Sends one record with a caller-chosen sequence and waits for its
  /// acknowledgement (ledger tests); does not advance `nextInput`.
  /// A supplied cancellation scheduler must execute cleanup on `queue`.
  package func submit(
    raw record: InputRecord,
    scheduleCancellation: (
      @Sendable (@escaping @Sendable () -> Void) -> Void
    )? = nil
  ) async throws {
    try await submit(record, scheduleCancellation: scheduleCancellation)
  }

  private func submit(
    _ pane: PaneID,
    _ payload: InputPayload,
    admission: MuxInputAdmission.Reservation? = nil
  ) async throws {
    try Task.checkCancellation()
    if let closedError { throw closedError }
    guard let attachment else { throw MuxError(.notAttached) }
    let sequence = nextInput
    try await submit(
      InputRecord(
        sequence: sequence,
        attachment: attachment,
        pane: pane,
        payload: payload
      ),
      advancingSequence: true,
      admission: admission
    )
  }

  private func submit(
    _ record: InputRecord,
    advancingSequence: Bool = false,
    admission: MuxInputAdmission.Reservation? = nil,
    scheduleCancellation: (
      @Sendable (@escaping @Sendable () -> Void) -> Void
    )? = nil
  ) async throws {
    try Task.checkCancellation()
    if let closedError { throw closedError }
    guard inputAcknowledgmentDeadlines.count < Self.maxInputAcknowledgments
    else {
      throw MuxError(
        .resourceLimit,
        "client input acknowledgment buffer is full"
      )
    }
    // Reserve a sequence only after the final pre-transmission check:
    // an unsent cancelled input must not leave a gap in the ledger.
    if advancingSequence { nextInput += 1 }
    let id = UUID()
    let sequence = record.sequence
    let queue = queue
    let scheduleCleanup = scheduleCancellation ?? { queue.async(execute: $0) }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        inputWaiters[sequence] = InputWaiter(
          id: id,
          continuation: continuation,
          admission: admission
        )
        transmit(.input(record))
      }
    } onCancel: {
      // The serial executor registers the waiter before this cleanup runs.
      // An ACK or lease change may retire it and reuse its sequence first.
      scheduleCleanup { [weak self] in
        self?
          .assumeIsolated { connection in
            guard let waiter = connection.inputWaiters[sequence],
              waiter.id == id
            else { return }
            connection.inputWaiters.removeValue(forKey: sequence)
            let admission = waiter.admission
            // Stop the caller's wait while retaining this wire record's
            // slot and charge until ACK, lease loss or channel failure.
            connection.inputs[sequence] = { _ in
              withExtendedLifetime(admission) {}
            }
            waiter.continuation.resume(throwing: CancellationError())
          }
      }
    }
  }

  // MARK: Ordered, non-awaiting submission
  //
  // Calls made in order from one thread reach the service in that order:
  // each hops onto this connection's serial queue synchronously in
  // FIFO order before transmitting.

  /// Sends input; admission errors go to `rejected`, if given.
  /// A local budget refusal invokes `rejected` immediately on the caller.
  public nonisolated func enqueue(
    _ input: MuxInput,
    to pane: PaneID,
    rejected: (@Sendable (MuxError) -> Void)? = nil
  ) {
    let admission: MuxInputAdmission.Reservation
    do {
      admission = try inputAdmission.reserve(MuxInputAdmission.bytes(input))
    } catch {
      rejected?(error);
      return
    }
    let rejected = Self.retainAdmission(admission, rejected: rejected)
    queue.async {
      self.assumeIsolated { connection in
        if connection.closedError == nil, let queued = connection.pasting[pane],
          !queued.isEmpty
        {
          // After a paste still waiting for its turn.
          connection.pasting[pane]?.append(.input(input, rejected: rejected))
          return
        }
        connection.transmitInput(input, to: pane, rejected: rejected)
      }
    }
  }

  /// Executes a command in call order; `completion` runs on this
  /// connection's queue. A local admission refusal runs on the caller.
  public nonisolated func enqueue(
    _ command: MuxCommand,
    completion: (@Sendable (Result<MuxReply, MuxError>) -> Void)? = nil
  ) {
    let admission: MuxCommandAdmission.Reservation
    do { admission = try commandAdmission.reserve(command) } catch {
      completion?(.failure(error));
      return
    }
    queue.async {
      self.assumeIsolated { connection in
        if let error = connection.closedError {
          completion?(.failure(error))
          return
        }
        let id = connection.nextRequest
        connection.nextRequest += 1
        connection.commandAdmissions[id] = admission
        connection.callbacks[id] = { completion?($0) }
        if let error = connection.request(id, command) {
          connection.callbacks.removeValue(forKey: id)?(.failure(error))
        }
      }
    }
  }

  /// Starts a paste in call order: its begin record precedes any later
  /// enqueued input, which the service defers until the envelope closes.
  /// A paste to a pane with one still open waits for it to close (and
  /// input enqueued after the waiting paste waits too).
  /// A local budget refusal invokes `completion` immediately on the caller.
  public nonisolated func enqueuePaste(
    _ text: String,
    to pane: PaneID,
    completion: (@Sendable (Result<PasteState, MuxError>) -> Void)? = nil
  ) {
    let admission: MuxInputAdmission.Reservation
    do { admission = try inputAdmission.reserve(text.utf8.count) } catch {
      completion?(.failure(error));
      return
    }
    queue.async {
      self.assumeIsolated { connection in
        let id = connection.nextPaste
        connection.nextPaste += 1
        connection.schedulePaste(text, to: pane, id: id) { result in
          withExtendedLifetime(admission) {
            if let completion {
              completion(
                result.mapError { $0 as? MuxError ?? MuxError(.connectionLost) }
              )
            }
          }
        }
      }
    }
  }

  private func schedulePaste(
    _ text: String,
    to pane: PaneID,
    id: UInt64,
    completion: @escaping (Result<PasteState, any Error>) -> Void
  ) {
    let limits = welcome?.limits ?? .standard
    guard attachment != nil, closedError == nil else {
      completion(.failure(closedError ?? MuxError(.notAttached)))
      return
    }
    guard text.utf8.count <= limits.maxPasteBytes else {
      completion(
        .failure(
          MuxError(
            .resourceLimit,
            "paste exceeds \(limits.maxPasteBytes) bytes"
          )
        )
      )
      return
    }
    if pasting[pane] != nil {
      pasting[pane]?.append(.paste(id, text, completion: completion))
      return
    }
    beginPaste(text, to: pane, id: id, completion: completion)
  }

  /// Sends the begin record and the body; the pane's next queued paste
  /// starts once this one's envelope is closed.
  private func beginPaste(
    _ text: String,
    to pane: PaneID,
    id: UInt64,
    completion: @escaping (Result<PasteState, any Error>) -> Void
  ) {
    guard let attachment, closedError == nil else {
      completion(.failure(closedError ?? MuxError(.notAttached)))
      return
    }
    pasting[pane] = []
    let sequence = nextInput
    nextInput += 1
    activePastes[pane] = ActivePaste(
      id: id,
      beginSequence: sequence,
      completion: completion
    )
    inputs[sequence] = { [weak self] error in
      if let error { self?.assumeIsolated { $0.pasteRefusals[id] = error } }
    }
    transmit(
      .input(
        InputRecord(
          sequence: sequence,
          attachment: attachment,
          pane: pane,
          payload: .pasteBegin(id: id)
        )
      )
    )
    // Encoding failure may have retired this operation synchronously.
    guard activePastes[pane]?.id == id else { return }
    activePastes[pane]?.task = Task {
      let result = await self.pasteBody(id: id, text: text, pane: pane)
      self.pasteFinished(
        pane,
        id: id,
        result: result.mapError { $0 as any Error }
      )
    }
  }

  /// Sends what waited behind the pane's paste, up to its next paste.
  private func pasteFinished(
    _ pane: PaneID,
    id: UInt64,
    result: Result<PasteState, any Error>
  ) {
    guard let active = activePastes[pane], active.id == id else { return }
    activePastes.removeValue(forKey: pane)
    if inputs[active.beginSequence] != nil {
      // An end/cancel ACK cannot stand in for a missing begin ACK. Keep
      // that wire record's reservation even after retiring the caller.
      let completion = active.completion
      inputs[active.beginSequence] = { _ in withExtendedLifetime(completion) {}
      }
    }
    pasteRefusals.removeValue(forKey: id)
    defer { active.completion(result) }
    var queued = pasting.removeValue(forKey: pane) ?? []
    while !queued.isEmpty {
      // A preceding input can fail encoding and close the connection.
      // These jobs are local to this drain, outside failPendingInputs.
      if let error = closedError {
        rejectPaneJobs(queued, error: error)
        return
      }
      switch queued.removeFirst() {
      case let .input(input, rejected):
        transmitInput(input, to: pane, rejected: rejected)
      case let .paste(id, text, completion):
        beginPaste(text, to: pane, id: id, completion: completion)
        if pasting[pane] != nil {
          pasting[pane] = queued
        } else {
          rejectPaneJobs(queued, error: closedError ?? MuxError(.notAttached))
        }
        return
      }
    }
  }

  private func pasteBody(
    id: UInt64,
    text: String,
    pane: PaneID
  ) async -> Result<PasteState, MuxError> {
    guard activePastes[pane]?.id == id else {
      return .failure(closedError ?? MuxError(.notAttached))
    }
    var sent = 0
    for chunk in MuxTextChunks(text, maxBytes: textChunkBytes) {
      var attempts = 0
      while true {
        guard activePastes[pane]?.id == id else {
          return .failure(closedError ?? MuxError(.notAttached))
        }
        do {
          try await submit(pane, .pasteChunk(id: id, text: chunk))
          break
        } catch let error as MuxError
          where error.code == .resourceLimit
          && error.message.contains("buffer is full")
          && attempts < pasteRetry.attempts
        {
          attempts += 1
          try? await Task.sleep(for: pasteRetry.delay)
        } catch let error as MuxError where error.code == .notAttached {
          return .failure(pasteRefusals.removeValue(forKey: id) ?? error)
        } catch {
          if let refused = pasteRefusals.removeValue(forKey: id) {
            // The service never opened this envelope.
            return .failure(refused)
          }
          // Close the envelope on the service: an open paste would keep
          // deferring this pane's later input and refuse a new paste.
          if activePastes[pane]?.id == id { transmitPasteCancel(pane, id: id) }
          return .success(sent > 0 ? .partial : .aborted)
        }
      }
      sent += chunk.utf8.count
    }
    guard activePastes[pane]?.id == id else {
      return .failure(closedError ?? MuxError(.notAttached))
    }
    do { try await submit(pane, .pasteEnd(id: id)) } catch {
      transmitPasteCancel(pane, id: id)
      return .failure(
        pasteRefusals.removeValue(forKey: id) ?? error as? MuxError
          ?? MuxError(.connectionLost)
      )
    }
    return .success(.completed)
  }

  /// How long a paste waits for writer credit before giving up.
  private var pasteRetry: (attempts: Int, delay: Duration) = (
    200, .milliseconds(25)
  )

  /// Shortens the paste retry budget (tests).
  package func setPasteRetry(attempts: Int, delay: Duration) {
    pasteRetry = (attempts, delay)
  }

  /// Pastes in bounded chunks admitted under writer credit, waiting while
  /// the pane's writer is full. Never replays after connection loss.
  /// Cancellation withdraws queued work or cancels the open envelope;
  /// bytes already written to the program cannot be rolled back.
  public func paste(_ text: String, to pane: PaneID) async throws -> PasteState
  {
    try Task.checkCancellation()
    let limits = welcome?.limits ?? .standard
    guard text.utf8.count <= limits.maxPasteBytes else {
      throw MuxError(
        .resourceLimit,
        "paste exceeds \(limits.maxPasteBytes) bytes"
      )
    }
    if let closedError { throw closedError }
    guard attachment != nil else { throw MuxError(.notAttached) }
    let admission = try inputAdmission.reserve(text.utf8.count)
    let id = nextPaste
    nextPaste += 1
    let queue = queue
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        schedulePaste(text, to: pane, id: id) { result in
          withExtendedLifetime(admission) { continuation.resume(with: result) }
        }
      }
    } onCancel: {
      queue.async { [weak self] in
        self?.assumeIsolated { $0.cancelPaste(pane, id: id) }
      }
    }
  }

  private func cancelPaste(_ pane: PaneID, id: UInt64) {
    if let active = activePastes[pane], active.id == id {
      active.task?.cancel()
      transmitPasteCancel(pane, id: id)
      pasteFinished(pane, id: id, result: .failure(CancellationError()))
      return
    }
    guard
      let index = pasting[pane]?
        .firstIndex(where: {
          if case let .paste(queuedID, _, _) = $0 { return queuedID == id }
          return false
        }), case let .paste(_, _, completion) = pasting[pane]?.remove(at: index)
    else { return }
    completion(.failure(CancellationError()))
  }

  private func transmitPasteCancel(_ pane: PaneID, id: UInt64) {
    guard let active = activePastes[pane], active.id == id, let attachment,
      closedError == nil
    else { return }
    let sequence = nextInput
    nextInput += 1
    let completion = active.completion
    // Keep the job charge through the cancel ACK without invoking its
    // already-retired completion again. Control records must close an
    // envelope even when ordinary ACK slots are full.
    inputs[sequence] = { _ in withExtendedLifetime(completion) {} }
    transmit(
      .input(
        InputRecord(
          sequence: sequence,
          attachment: attachment,
          pane: pane,
          payload: .pasteCancel(id: id)
        )
      )
    )
  }

  /// A control byte can occupy six JSON bytes. Leave room for the fixed
  /// input envelope, including maximum-width sequence and paste IDs, and
  /// keep ordinary chunks at the standard size even if a peer allows more.
  private var textChunkBytes: Int {
    let limits = welcome?.limits ?? .standard
    let recordBytes = SMXCodec.clientRecordLimit(limits)
    let encodedBudget = recordBytes > 1024 ? (recordBytes - 1024) / 6 : 1
    return max(
      1,
      min(
        limits.maxPasteChunkBytes,
        MuxLimits.standard.maxPasteChunkBytes,
        encodedBudget
      )
    )
  }

  /// Splits on scalar boundaries so each chunk is valid UTF-8.
  package static func chunks(_ text: String, maxBytes: Int) -> [String] {
    Array(MuxTextChunks(text, maxBytes: maxBytes))
  }

  /// Releases the attachment, bounded in time; panes keep running. A
  /// service that does not answer in time gets the connection closed
  /// if the attachment being detached is still current.
  public func detach() async {
    guard let detaching = attachment, closedError == nil else { return }
    do { try await execute(.detach, timeout: detachTimeout) } catch {
      if attachment == detaching { close() }
      return
    }
    guard attachment == detaching else { return }
    // Unattached, no frame installs; Ready of the released lease does
    // not describe a later attachment.
    attachment = nil
    readiness = nil
    installation = FrameInstallation()
    failPendingInputs(MuxError(.notAttached))
  }

  /// How long `detach` waits for the service.
  private var detachTimeout: Duration = .seconds(2)

  /// Shortens the detach bound (tests).
  package func setDetachTimeout(_ timeout: Duration) { detachTimeout = timeout }

  /// Closes the connection. An attached lease is released by the service.
  /// Also cancels the channel of a connection that already failed.
  public func close() {
    cancelChannel()
    guard !isClosed else { return }
    isClosed = true
    closedDeliberately = true
    let error = MuxError(.connectionLost, "closed")
    closedError = error
    attachment = nil
    failPending(error)
    if let waiter {
      self.waiter = nil
      waiter.continuation.resume(returning: nil)
    }
  }

  /// Sends one record. One that cannot be encoded would leave a gap in
  /// the input sequence, so it fails the connection (cancelling the
  /// channel, which releases its lease).
  private func transmit(_ message: ClientMessage) {
    if case let .input(record) = message {
      trackInputAcknowledgment(record.sequence)
    }
    do { channel.send(try encode(message)) } catch { fail(error) }
  }

  private func trackInputAcknowledgment(_ sequence: UInt64) {
    let deadline = ContinuousClock.now + inputAcknowledgmentTimeout
    inputAcknowledgmentDeadlines[sequence] = deadline
    if inputAcknowledgmentTimer == nil {
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.setEventHandler { [weak self] in
        self?.assumeIsolated { $0.checkInputAcknowledgments() }
      }
      inputAcknowledgmentTimer = timer
      timer.resume()
    }
    if let wake = inputAcknowledgmentWake, wake <= deadline { return }
    scheduleInputAcknowledgments(at: deadline)
  }

  private func scheduleInputAcknowledgments(
    at deadline: ContinuousClock.Instant
  ) {
    inputAcknowledgmentWake = deadline
    let remaining = max(.zero, deadline - ContinuousClock.now)
    inputAcknowledgmentTimer?.schedule(deadline: remaining.dispatchDeadline)
  }

  private func checkInputAcknowledgments() {
    // A queued callback from a retired timer must inspect current ownership,
    // including a fresh attachment that reused the old sequence number.
    guard let deadline = inputAcknowledgmentDeadlines.values.min() else {
      clearInputAcknowledgments()
      return
    }
    if ContinuousClock.now >= deadline {
      fail(MuxError(.connectionLost, "input acknowledgment timed out"))
    } else {
      scheduleInputAcknowledgments(at: deadline)
    }
  }

  private func clearInputAcknowledgments() {
    inputAcknowledgmentDeadlines = [:]
    inputAcknowledgmentTimer?.setEventHandler {}
    inputAcknowledgmentTimer?.cancel()
    inputAcknowledgmentTimer = nil
    inputAcknowledgmentWake = nil
  }

  private func trackRequestTimeout(_ id: UInt64, timeout: Duration) {
    let deadline = ContinuousClock.now + timeout
    requestTimeoutDeadlines[id] = deadline
    if requestTimeoutTimer == nil {
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.setEventHandler { [weak self] in
        self?.assumeIsolated { $0.checkRequestTimeouts() }
      }
      requestTimeoutTimer = timer
      timer.resume()
    }
    if let wake = requestTimeoutWake, wake <= deadline { return }
    scheduleRequestTimeouts(at: deadline)
  }

  private func scheduleRequestTimeouts(at deadline: ContinuousClock.Instant) {
    requestTimeoutWake = deadline
    requestTimeoutTimer?
      .schedule(deadline: (deadline - ContinuousClock.now).dispatchDeadline)
  }

  private func removeRequestTimeout(_ id: UInt64) {
    guard let removed = requestTimeoutDeadlines.removeValue(forKey: id) else {
      return
    }
    guard let earliest = requestTimeoutDeadlines.values.min() else {
      clearRequestTimeouts()
      return
    }
    if requestTimeoutWake == removed { scheduleRequestTimeouts(at: earliest) }
  }

  private func checkRequestTimeouts() {
    // A retired source may already have queued a callback. Inspect only
    // current deadlines; request IDs are never reused by this connection.
    let now = ContinuousClock.now
    let expired = requestTimeoutDeadlines.filter { $0.value <= now }.map(\.key)
    for id in expired {
      abandon(id, MuxError(.connectionLost, "no reply in time"))
    }
    guard let earliest = requestTimeoutDeadlines.values.min() else {
      clearRequestTimeouts()
      return
    }
    scheduleRequestTimeouts(at: earliest)
  }

  private func clearRequestTimeouts() {
    requestTimeoutDeadlines = [:]
    requestTimeoutTimer?.setEventHandler {}
    requestTimeoutTimer?.cancel()
    requestTimeoutTimer = nil
    requestTimeoutWake = nil
  }

  private func encode(_ message: ClientMessage) throws(MuxError) -> Data {
    try SMXCodec.encode(
      message,
      limit: SMXCodec.clientRecordLimit(welcome?.limits ?? .standard)
    )
  }
}
