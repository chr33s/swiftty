import Foundation
import ScreenProtocol
import SessionCore
import SwiftMuxExport
import SwiftMuxProtocol
import SwifttyEngine

/// The direct-client RST/1 state machine (spec §8, §9): the single
/// serialized owner of one roaming session's attachment, input queue and
/// screen store.
///
///     idle -> sshBootstrap -> attaching -> active
///     active -> suspect -> reconnecting -> attaching -> active
///     active -> backgroundDetached -> attaching -> active
///     any -> sessionExited / sessionLost / userClosed
///
/// Input is accepted only while `active`, which requires a complete
/// current snapshot of the present attachment. Refused input is reported,
/// never queued offline or echoed. Submitted operations survive warm
/// reconnects and are retried with their original sequence numbers under
/// the new epoch; they are never replayed into a different session.
///
/// Bearer tokens stay in this actor's memory and are never logged or
/// exposed through `status`.
public actor RoamingClient {
  typealias Instant = ContinuousClock.Instant

  struct DecodedScreen: Sendable {
    var snapshot: ScreenSnapshot
    var frame: PresentationFrame
    /// The shared-model frame it came from (`paneFrames`): a delta base.
    var paneFrame: PaneFrame? = nil
  }

  /// One decoded screen stream: a complete screen, or a delta that needs
  /// a retained base first.
  enum DecodedRecord: Sendable {
    case screen(DecodedScreen)
    case delta(FrameDelta, RSTFrameHeader)
  }

  /// Copy failures (spec.roaming.md §7.5).
  public struct CopyError: Error, Equatable, Sendable {
    public var code: RSTErrorCode
    public init(_ code: RSTErrorCode) { self.code = code }
  }

  /// Layout action failures (spec.roaming.md §7.6).
  public struct LayoutError: Error, Equatable, Sendable {
    public var code: RSTErrorCode
    public init(_ code: RSTErrorCode) { self.code = code }
  }

  enum AttachOutcome: Sendable {
    case active
    /// The connect failed; carries the transport's reason.
    case unreachable(String)
    case closed
    case timedOut
    /// Connected, but `Attached` did not arrive within the progress wait.
    case stalled
    case rejected(RSTErrorCode)
    case protocolViolation
    case cancelled
  }

  enum RefreshOutcome { case granted, retry, stop }

  let bootstrapper: any RemoteBootstrapper
  let connector: any RSTConnector
  let sink: (any PresentationSink)?
  let configuration: RoamingClientConfiguration
  let timing: SurfaceTiming

  // Session.
  private var lifecycle = ClientLifecycle()
  private var grant: BootstrapGrant?
  private var limits: NegotiatedLimits {
    grant?.limits.effective ?? NegotiatedLimits()
  }
  private var queue: ClientInputQueue?
  private var store: RemoteScreenStore?
  private var needsFreshGrant = false
  private var exitStatus: Int32?

  // Connection; every handler is scoped to `connectionGeneration`.
  private var connection: (any RSTConnection)?
  private var connectionGeneration: UInt64 = 0
  private var reader = ControlRecordReader()
  private var epoch: UInt64?
  /// What the attached host accepts beyond plain RST/1.
  private var hostFeatures: RSTFeatures = []
  /// What both sides listed for this attachment.
  private var agreedFeatures: RSTFeatures {
    hostFeatures.agreed(with: RSTFeatures.supported)
  }
  /// Recently installed shared-model frames: the bases a delta may name
  /// (at most 16, for 2 seconds; §7.4).
  private var frameBases: [(frame: PaneFrame, at: Instant)] = []
  static let retainedFrameBases = 16
  static let frameBaseLifetime: Duration = .seconds(2)
  /// Deltas applied and full screens requested (tests, diagnostics).
  package private(set) var deltaStatistics = (applied: 0, requestedFull: 0)
  /// The copy in flight: its request, epoch, received text and waiter.
  private var copy:
    (
      id: UInt64, epoch: UInt64, text: String, next: UInt64,
      waiter: CheckedContinuation<String, any Error>
    )?
  private var nextCopyID: UInt64 = 1
  /// The attached workspace's tabs and panes (`layoutControl`).
  private var layout: RemoteLayout?
  /// Layout actions awaiting their `LayoutResult`, by request.
  private var layoutWaiters: [UInt64: CheckedContinuation<Void, any Error>] =
    [:]
  private var nextLayoutID: UInt64 = 1
  /// Unanswered layout actions one attachment may have.
  static let maxPendingLayoutActions = 8
  private var earlySnapshot: DecodedScreen?
  private var outbox: [[UInt8]] = []
  private var pumpGeneration: UInt64?

  // Attachment attempts: at most one at a time.
  private var connectTask: Task<Void, Never>?
  private var connectTaskID: UInt64 = 0
  private var attachDeadline: Instant?
  private let bootstrapOperations = ProviderOperationSlot()
  private let connectorOperations = ProviderOperationSlot()
  private var bootstrapAttempt: DeadlineOperation<BootstrapResponse>?
  private var attachWaiter: CheckedContinuation<AttachOutcome, Never>?
  private var attachTimeoutTask: Task<Void, Never>?
  /// Ends an attempt that hears no `Attached` soon after its handshake.
  private var attachProgressTask: Task<Void, Never>?
  private var backoff: ReconnectBackoff
  private var random = SystemRandomNumberGenerator()
  private var failedAttempts = 0

  // Liveness.
  private var liveness = LivenessPolicy()
  private var livenessTask: Task<Void, Never>?
  private var lastHeardAt: Instant
  private var lastSentAt: Instant
  private var inputAwaitingSince: Instant?
  private var probeSentAt: Instant?
  private var ping: (nonce: UInt64, sentAt: Instant)?
  private var nextNonce: UInt64 = 1

  // Input and grid.
  private var resendFrom: UInt64?
  private var resizeRevision: UInt64 = 0
  private var desiredGrid: GridSize?
  private var gridProposed = false
  /// The grid last requested within the current attachment; cleared on
  /// every new attachment so the host's actual grid is compared again.
  private var requestedGrid: GridSize?

  // Detach / terminate.
  private var closeWaiters: [CheckedContinuation<Void, Never>] = []
  private var closeWaitGeneration: UInt64 = 0
  private var closeTimeoutTask: Task<Void, Never>?

  // Status.
  private var currentStatus = RoamingStatus()
  private var statusHandler: (@Sendable (RoamingStatus) -> Void)?
  private var lastFailure: RoamingFailure?
  private var lastFailureDetail: String?
  private var lastScreenAt: Date?
  private var refusedInputCount = 0

  public init(
    bootstrapper: any RemoteBootstrapper,
    connector: any RSTConnector,
    sink: (any PresentationSink)? = nil,
    configuration: RoamingClientConfiguration = .init(),
    timing: SurfaceTiming = .system
  ) {
    self.bootstrapper = bootstrapper
    self.connector = connector
    self.sink = sink
    self.configuration = configuration
    self.timing = timing
    backoff = ReconnectBackoff(jitter: configuration.backoffJitter)
    // The view's latest grid: a resume asks for it rather than adopting
    // whatever grid the session last had.
    if configuration.initialGrid.isValid {
      desiredGrid = configuration.initialGrid
    }
    let now = timing.now()
    lastHeardAt = now
    lastSentAt = now
  }

  // MARK: Public interface

  /// Current status: no secrets, safe for UI and the companion bridge.
  public var status: RoamingStatus { currentStatus }

  public var state: ClientConnectionState { lifecycle.state }

  /// Called on this actor after every status change. Must not block.
  public func setStatusHandler(_ handler: (@Sendable (RoamingStatus) -> Void)?)
  {
    statusHandler = handler
    handler?(currentStatus)
  }

  /// Bootstraps through SSH (`create`, or `resume` after a cold launch)
  /// and begins attaching. Returns once credentials were granted; the
  /// attachment proceeds in the background and becomes `active` after the
  /// first complete screen. May be called again after a failed bootstrap.
  public func start(_ target: RoamingTarget) async throws(RoamingClientError) {
    let state = lifecycle.state
    guard bootstrapAttempt == nil,
      state == .idle || (state == .sshBootstrap && grant == nil)
    else { throw .invalidState(state) }
    move(to: .sshBootstrap)
    let request: BootstrapRequest
    switch target {
    case let .create(grid):
      let initial = gridProposed ? desiredGrid ?? grid : grid
      desiredGrid = initial
      request = BootstrapRequest(operation: .create, initialGrid: initial)
    case let .resume(id):
      request = BootstrapRequest(
        operation: .resume,
        sessionID: id,
        initialGrid: desiredGrid
      )
    case let .reveal(id, revealed):
      request = BootstrapRequest(
        operation: .resume,
        sessionID: id,
        initialGrid: desiredGrid,
        target: revealed
      )
    }
    let attempt = DeadlineOperation<BootstrapResponse>()
    bootstrapAttempt = attempt
    defer { if bootstrapAttempt === attempt { bootstrapAttempt = nil } }
    let bootstrapper = bootstrapper
    let operations = bootstrapOperations
    let response: BootstrapResponse
    do {
      response = try await attempt.run(timing: timing) {
        try await operations.run { try await bootstrapper.bootstrap(request) }
      }
    } catch {
      guard bootstrapAttempt === attempt, !Task.isCancelled,
        lifecycle.state == .sshBootstrap, grant == nil,
        !(error is CancellationError)
      else { throw .cancelled }
      if error is ProviderOperationError {
        throw .invalidState(lifecycle.state)
      }
      let failure = Self.failure(for: error)
      noteFailure(failure)
      throw Self.clientError(for: failure)
    }
    guard bootstrapAttempt === attempt, !Task.isCancelled,
      lifecycle.state == .sshBootstrap, grant == nil
    else { throw .cancelled }
    switch response {
    case let .granted(granted):
      guard Self.isUsable(granted),
        target.sessionID.map({ $0 == granted.sessionID }) ?? true
      else {
        noteFailure(.protocolViolation)
        throw .protocolViolation
      }
      grant = granted
      queue = ClientInputQueue(
        writerID: granted.writerID,
        byteLimit: limits.maxPendingInputBytes
      )
      store = RemoteScreenStore(sessionID: granted.sessionID)
      if desiredGrid == nil { desiredGrid = granted.initialGrid }
      constrainDesiredGrid()
      publish()
    case .failure(.unknownSession):
      enterFinal(.sessionLost)
      throw .sessionLost
    case .failure(.sessionExited):
      enterFinal(.sessionExited)
      throw .sessionExited
    case let .failure(code):
      noteFailure(.bootstrapRejected(code))
      throw .rejected(code)
    case .sessions, .terminated, .metadata:
      noteFailure(.protocolViolation)
      throw .protocolViolation
    }
    startLiveness()
    ensureConnecting(delayFirst: false)
  }

  /// Submits semantic input. Accepted only while `active`.
  @discardableResult
  public func submit(_ input: SurfaceInput) -> SurfaceInputResult {
    let state = lifecycle.state
    guard state == .active, var queue, let epoch, connection != nil else {
      refusedInputCount += 1
      publish()
      return .refused(state.isTerminal ? .closed : .notActive(state))
    }
    // The record must fit RST/1's control record limit once encoded
    // (escaped control characters grow a paste): an operation that could
    // never be sent would stall every later sequence behind it.
    guard let operation = Self.operation(input.operation, for: hostFeatures),
      limits.permits(operation),
      Self.fitsControlRecord(operation, limit: limits.maxControlRecordBytes)
    else { return .refused(.invalid) }
    let entry: ClientInputQueue.Entry
    do { entry = try queue.enqueue(operation) } catch .full {
      return .refused(.backpressure)
    } catch { return .refused(.invalid) }
    self.queue = queue
    sendInput(entry, epoch: epoch)
    publish()
    return .accepted(sequence: entry.sequence)
  }

  /// `operation` as a host with `features` accepts it: keypad keys become
  /// the keys they type without `keypadKeys`. Nil when nothing matches.
  static func operation(
    _ operation: InputOperation,
    for features: RSTFeatures
  ) -> InputOperation? {
    guard !features.contains(.keypadKeys), case var .key(key) = operation,
      case let .keypad(keypad) = key.name
    else { return operation }
    guard let main = KeypadKey(rawValue: keypad.rawValue)?.mainKey,
      let name = SemanticKeyName(main)
    else { return nil }
    key.name = name
    return .key(key)
  }

  /// Whether `operation` encodes within the control record limit at the
  /// largest epoch and sequence numbers.
  static func fitsControlRecord(
    _ operation: InputOperation,
    limit: Int = RSTLimits.maxControlRecordBytes
  ) -> Bool {
    let probe = ControlMessage.input(
      .init(attachmentEpoch: .max, sequence: .max, operation: operation)
    )
    return (try? ControlRecord.encode(probe, limit: limit)) != nil
  }

  /// Moves this client's own window through the host's history by
  /// `lines` (positive reveals older output). A no-op unless attached to
  /// a host that advertises `historyViewport`; the host clamps the
  /// window and returns it to live output on input.
  public func scrollViewport(by lines: Int) {
    guard lines != 0, let epoch, hostFeatures.contains(.historyViewport) else {
      return
    }
    let bound = Int(ControlMessage.maxViewportLines)
    send(.viewport(epoch: epoch, lines: Int64(min(max(lines, -bound), bound))))
  }

  public var supportsHistoryViewport: Bool {
    epoch != nil && hostFeatures.contains(.historyViewport)
  }

  /// Requests a grid from local view geometry. Sent as a `.resize`
  /// operation with an increasing resize revision once active; the
  /// displayed grid changes only with the host's snapshots.
  public func proposeGrid(columns: Int, rows: Int) {
    let grid = GridSize(columns: columns, rows: rows)
    guard grid.isValid else { return }
    desiredGrid = grid
    constrainDesiredGrid()
    gridProposed = true
    maybeSendGrid()
    publish()
  }

  private func constrainDesiredGrid() {
    guard let desiredGrid else { return }
    self.desiredGrid = GridSize(
      columns: min(desiredGrid.columns, limits.maxColumns),
      rows: min(desiredGrid.rows, limits.maxRows)
    )
  }

  /// Scene backgrounded or unavailable: stop input, attempt a bounded
  /// detach, then stop networking (spec §9).
  public func enterBackground() async {
    let state = lifecycle.state
    guard !state.isTerminal, state != .idle, state != .backgroundDetached else {
      return
    }
    cancelConnecting()
    let gen = connectionGeneration
    let attachedEpoch = connection != nil ? epoch : nil
    if !move(to: .backgroundDetached) {
      // sshBootstrap cannot detach; stop networking and resume later.
      dropConnection()
      publish()
      return
    }
    if let attachedEpoch {
      send(.detach(epoch: attachedEpoch))
      await waitForClose()
    }
    if connectionGeneration == gen { dropConnection() }
    publish()
  }

  /// Scene foregrounded: reconnect as needed; input waits for a complete
  /// current screen.
  public func enterForeground() {
    switch lifecycle.state {
    case .backgroundDetached:
      if needsFreshGrant || tokenExpired {
        move(to: .sshBootstrap)
      } else {
        move(to: .attaching)
      }
      ensureConnecting(delayFirst: false)
    case .sshBootstrap, .reconnecting, .attaching:
      if grant != nil { ensureConnecting(delayFirst: false) }
    case .active, .suspect: sendProbe()
    default: break
    }
    publish()
  }

  /// Recovery from system sleep; also a user-initiated retry.
  public func wake() { enterForeground() }

  /// A network path change: probe the connection. Not evidence that it
  /// failed (spec §9).
  public func pathChanged() {
    switch lifecycle.state {
    case .active: sendProbe()
    case .reconnecting: backoff.reset()
    default: break
    }
    publish()
  }

  /// Explicit close: `Detach` keeps the host shell, `Terminate` destroys
  /// it. Bounded by `detachDeadline`. Idempotent.
  public func close(_ mode: RoamingCloseMode = .detach) async {
    let state = lifecycle.state
    guard state != .userClosed else { return }
    cancelConnecting()
    if state.isTerminal {
      dropConnection()
      stopLiveness()
      return
    }
    let gen = connectionGeneration
    let attachedEpoch = connection != nil ? epoch : nil
    let sessionID = grant?.sessionID
    move(to: .userClosed)
    stopLiveness()
    if let attachedEpoch {
      send(
        mode == .detach
          ? .detach(epoch: attachedEpoch) : .terminate(epoch: attachedEpoch)
      )
      await waitForClose()
    } else if mode == .terminate, let sessionID {
      await terminateThroughSSH(sessionID)
    }
    if connectionGeneration == gen { dropConnection() }
    publish()
  }

  // MARK: Connecting

  private var wantsConnection: Bool {
    switch lifecycle.state {
    case .sshBootstrap, .attaching, .reconnecting: grant != nil
    default: false
    }
  }

  private var tokenExpired: Bool {
    guard let grant else { return false }
    let margin = Double(configuration.tokenRefreshMargin.components.seconds)
    return timing.wallClock() >= grant.tokenExpiresAt - margin
  }

  private func ensureConnecting(delayFirst: Bool) {
    guard connectTask == nil, wantsConnection else { return }
    connectTaskID &+= 1
    let id = connectTaskID
    connectTask = Task {
      await self.connectLoop(delayFirst: delayFirst, id: id)
    }
  }

  private func cancelConnecting() {
    bootstrapAttempt?.cancel()
    bootstrapAttempt = nil
    connectTask?.cancel()
    connectTask = nil
    connectTaskID &+= 1
    finishAttach(.cancelled)
  }

  private func connectLoop(delayFirst: Bool, id: UInt64) async {
    defer { if connectTaskID == id { connectTask = nil } }
    var delay = delayFirst
    // A stalled attempt proved the path usable: retry once at once.
    var retriedStall = false
    while !Task.isCancelled, connectTaskID == id, wantsConnection {
      if delay {
        let seconds = backoff.nextDelay(using: &random)
        publish()
        do {
          try await timing.sleep(.milliseconds(Int64(seconds * 1000)))
        } catch { return }
        guard !Task.isCancelled, connectTaskID == id, wantsConnection else {
          return
        }
      }
      delay = true
      if needsFreshGrant || tokenExpired {
        switch await refreshGrant(id: id) {
        case .granted: break
        case .retry: continue
        case .stop: return
        }
        guard !Task.isCancelled, connectTaskID == id, wantsConnection else {
          return
        }
      }
      guard let grant else { return }
      let outcome = await attachOnce(grant)
      guard connectTaskID == id else { return }
      switch outcome {
      case .active, .cancelled: return
      case let .rejected(code):
        dropConnection()
        switch code {
        case .unknownSession, .wrongInstance:
          enterFinal(.sessionLost)
          return
        case .sessionExited:
          enterFinal(.sessionExited)
          return
        case .expired, .unauthorized: needsFreshGrant = true
        default: break
        }
        attemptFailed(.attachRejected(code))
      // SSH already granted this attachment: only the QUIC route failed.
      case let .unreachable(reason):
        attemptFailed(.endpointUnreachable, detail: reason)
      case .closed: attemptFailed(.connectionLost)
      case .timedOut: attemptFailed(.attachTimedOut)
      case .stalled:
        attemptFailed(
          .attachTimedOut,
          detail: "no Attached after the handshake"
        )
        if !retriedStall {
          retriedStall = true
          delay = false
        }
      case .protocolViolation: attemptFailed(.protocolViolation)
      }
    }
  }

  private func attemptFailed(_ failure: RoamingFailure, detail: String? = nil) {
    dropConnection()
    failedAttempts += 1
    // Repeated failures may mean the helper restarted: ask SSH, which
    // distinguishes "unreachable" from "session no longer exists".
    if failedAttempts % 3 == 0 { needsFreshGrant = true }
    noteFailure(failure, detail: detail)
    move(to: .reconnecting)
  }

  /// One connect + `Attach` + first current snapshot.
  private func attachOnce(_ grant: BootstrapGrant) async -> AttachOutcome {
    move(to: .attaching)
    guard lifecycle.state == .attaching else { return .cancelled }
    let gen = connectionGeneration
    let timing = timing
    let deadline = timing.now() + configuration.attachTimeout
    let connector = connector
    let operations = connectorOperations
    let connectStarted = timing.now()
    let conn: any RSTConnection
    do {
      conn = try await DeadlineOperation<any RSTConnection>(discard: {
        $0.close()
      })
      .run(timeout: configuration.attachTimeout, timing: timing) {
        try await operations.run { try await connector.connect(to: grant) }
      }
    } catch is CancellationError {
      return .cancelled
    } catch DeadlineOperationError.timedOut {
      return .timedOut
    } catch ProviderOperationError.busy { return .timedOut } catch {
      return .unreachable(Self.reason(error))
    }
    guard !Task.isCancelled, lifecycle.state == .attaching,
      connectionGeneration == gen
    else {
      conn.close()
      return .cancelled
    }
    let connected = timing.now()
    let timeout = deadline - connected
    guard timeout > .zero else {
      conn.close()
      return .timedOut
    }
    // Several handshake round trips without `Attached`: this connection
    // is not carrying data, though its handshake proved the path usable.
    // A handshake slowed by loss overstates the round trip, so the wait is
    // also capped at a third of the attach timeout.
    let minimum = configuration.attachProgressMinimum
    let progress = min(
      max(minimum, (connected - connectStarted) * 4),
      max(minimum, configuration.attachTimeout / 3)
    )
    adopt(conn)
    // The connector returns only after the authenticated handshake, so
    // the capability is sent to the pinned peer only.
    send(
      .attach(
        .init(
          sessionID: grant.sessionID,
          serverInstanceID: grant.serverInstanceID,
          writerID: queue?.writerID ?? grant.writerID,
          applicationToken: grant.applicationToken,
          features: .supported
        )
      )
    )
    let attachGen = connectionGeneration
    return await withCheckedContinuation { continuation in
      attachWaiter = continuation
      attachDeadline = deadline
      attachTimeoutTask = Task { [weak self] in
        do { try await timing.sleep(timeout) } catch { return }
        await self?.attachTimedOut(generation: attachGen)
      }
      if progress < timeout {
        attachProgressTask = Task { [weak self] in
          do { try await timing.sleep(progress) } catch { return }
          await self?.attachStalled(generation: attachGen)
        }
      }
    }
  }

  private func attachTimedOut(generation: UInt64) {
    guard generation == connectionGeneration else { return }
    finishAttach(.timedOut)
  }

  private func attachStalled(generation: UInt64) {
    guard generation == connectionGeneration, epoch == nil else { return }
    finishAttach(.stalled)
  }

  private func finishAttach(_ outcome: AttachOutcome) {
    attachTimeoutTask?.cancel()
    attachTimeoutTask = nil
    attachProgressTask?.cancel()
    attachProgressTask = nil
    attachDeadline = nil
    guard let waiter = attachWaiter else { return }
    attachWaiter = nil
    switch outcome {
    case .active, .cancelled: break
    default:
      // Fence queued callbacks before the failed attempt's worker resumes.
      // Cancellation leaves teardown to its explicit detach/close operation.
      dropConnection()
    }
    waiter.resume(returning: outcome)
  }

  private func expireAttachmentIfNeeded() -> Bool {
    guard attachWaiter != nil, let attachDeadline,
      timing.now() >= attachDeadline
    else { return false }
    finishAttach(.timedOut)
    return true
  }

  /// Fresh credentials through SSH `resume`, keeping the writer identity
  /// while this process still holds its input queue.
  private func refreshGrant(id: UInt64) async -> RefreshOutcome {
    guard connectTaskID == id, !Task.isCancelled, wantsConnection,
      bootstrapAttempt == nil, let sessionID = grant?.sessionID
    else { return .stop }
    move(to: .sshBootstrap)
    let request = BootstrapRequest(
      operation: .resume,
      sessionID: sessionID,
      writerID: queue?.writerID,
      initialGrid: desiredGrid
    )
    let attempt = DeadlineOperation<BootstrapResponse>()
    bootstrapAttempt = attempt
    defer { if bootstrapAttempt === attempt { bootstrapAttempt = nil } }
    let bootstrapper = bootstrapper
    let operations = bootstrapOperations
    let response: BootstrapResponse
    do {
      response = try await attempt.run(timing: timing) {
        try await operations.run { try await bootstrapper.bootstrap(request) }
      }
    } catch {
      guard connectTaskID == id, bootstrapAttempt === attempt,
        !Task.isCancelled, wantsConnection, !(error is CancellationError)
      else { return .stop }
      if error is ProviderOperationError { return .retry }
      let failure = Self.failure(for: error)
      noteFailure(failure)
      switch failure {
      // A changed host key, failed login or unreadable key blocks
      // automatic retries.
      case .hostKeyRejected, .authenticationFailed, .credentialUnavailable:
        return .stop
      default: return .retry
      }
    }
    guard connectTaskID == id, bootstrapAttempt === attempt, !Task.isCancelled,
      wantsConnection
    else { return .stop }
    switch response {
    case let .granted(granted):
      guard Self.isUsable(granted), granted.sessionID == sessionID else {
        noteFailure(.protocolViolation)
        return .retry
      }
      if var queue, granted.writerID != queue.writerID {
        let abandoned = queue.entries.count
        queue.resetWriter(granted.writerID)
        self.queue = queue
        if abandoned > 0 {
          noteFailure(.pendingInputAbandoned(count: abandoned))
        }
      }
      grant = granted
      queue?.updateByteLimit(limits.maxPendingInputBytes)
      constrainDesiredGrid()
      needsFreshGrant = false
      return .granted
    case .failure(.unknownSession):
      enterFinal(.sessionLost)
      return .stop
    case .failure(.sessionExited):
      enterFinal(.sessionExited)
      return .stop
    case let .failure(code):
      noteFailure(.bootstrapRejected(code))
      return .retry
    case .sessions, .terminated, .metadata:
      noteFailure(.protocolViolation)
      return .retry
    }
  }

  private func terminateThroughSSH(_ sessionID: SessionID) async {
    // Cleanup has separate capacity so a stalled refresh cannot block termination.
    let bootstrapper = bootstrapper
    let timing = timing
    _ = try? await DeadlineOperation<Void>()
      .run(timeout: configuration.detachDeadline, timing: timing) {
        _ = try? await bootstrapper.bootstrap(
          BootstrapRequest(operation: .terminate, sessionID: sessionID)
        )
      }
  }

  // MARK: Connection plumbing

  private func adopt(_ conn: any RSTConnection) {
    connectionGeneration &+= 1
    let gen = connectionGeneration
    connection = conn
    let limits = limits
    reader = ControlRecordReader(limit: limits.maxControlRecordBytes)
    outbox = []
    pumpGeneration = nil
    epoch = nil
    earlySnapshot = nil
    ping = nil
    probeSentAt = nil
    inputAwaitingSince = nil
    resendFrom = nil
    let now = timing.now()
    lastHeardAt = now
    lastSentAt = now
    conn.start(
      RSTConnectionHandler(
        onControl: { [weak self] bytes in
          await self?.handleControl(bytes, generation: gen)
        },
        onSnapshot: { [weak self] bytes in
          // Decode, validate and map off the actor and the UI executor.
          switch Self.decodeRecord(bytes, limits: limits) {
          case let .screen(decoded)?:
            await self?.handleSnapshot(decoded, generation: gen)
          case let .delta(delta, header)?:
            // The base is looked up on the actor; applying, validating and
            // mapping run here, off it, as for complete screens.
            let base = await self?.deltaBase(for: delta)
            let decoded = base.flatMap { base in
              (try? FrameDeltaApplier.apply(
                delta,
                to: base,
                limits: SnapshotFrame.frameLimits
              ))
              .flatMap { Self.screen($0, header: header) }
            }
            await self?
              .handleDelta(
                delta,
                header: header,
                decoded: decoded,
                generation: gen
              )
          case nil: await self?.handleSnapshot(nil, generation: gen)
          }
        },
        onClosed: { [weak self] _ in
          Task { await self?.connectionClosed(generation: gen) }
        }
      )
    )
  }

  private func dropConnection() {
    if let connection {
      connectionGeneration &+= 1
      connection.close()
    }
    frameBases = []
    failCopy(CopyError(.staleEpoch))
    failLayoutActions(LayoutError(.staleEpoch))
    connection = nil
    outbox = []
    pumpGeneration = nil
    epoch = nil
    earlySnapshot = nil
    ping = nil
    probeSentAt = nil
    inputAwaitingSince = nil
    resumeCloseWaiters()
  }

  private func connectionClosed(generation: UInt64) {
    guard generation == connectionGeneration else { return }
    if attachWaiter != nil {
      finishAttach(.closed)
      return
    }
    resumeCloseWaiters()
    switch lifecycle.state {
    case .active, .suspect: reconnect(after: .connectionLost)
    default: dropConnection()
    }
    publish()
  }

  private func reconnect(after failure: RoamingFailure) {
    dropConnection()
    noteFailure(failure)
    move(to: .reconnecting)
    ensureConnecting(delayFirst: true)
  }

  /// Bounded, ordered control-record output: one pump per connection.
  private func send(_ message: ControlMessage) {
    guard let conn = connection else { return }
    guard
      let record = try? ControlRecord.encode(
        message,
        limit: limits.maxControlRecordBytes
      )
    else {
      connectionFailed(.protocolViolation)
      return
    }
    guard outbox.count < configuration.maxOutboundRecords else {
      connectionFailed(.connectionLost)
      return
    }
    outbox.append(record)
    lastSentAt = timing.now()
    let gen = connectionGeneration
    guard pumpGeneration != gen else { return }
    pumpGeneration = gen
    Task { await self.pump(conn, generation: gen) }
  }

  private func pump(_ conn: any RSTConnection, generation gen: UInt64) async {
    while gen == connectionGeneration, !outbox.isEmpty {
      let record = outbox.removeFirst()
      do { try await conn.sendControl(record) } catch {
        if pumpGeneration == gen { pumpGeneration = nil }
        connectionClosed(generation: gen)
        return
      }
    }
    if pumpGeneration == gen { pumpGeneration = nil }
  }

  private func connectionFailed(_ failure: RoamingFailure) {
    if attachWaiter != nil {
      finishAttach(failure == .protocolViolation ? .protocolViolation : .closed)
    } else if lifecycle.state == .active || lifecycle.state == .suspect {
      reconnect(after: failure)
    } else {
      dropConnection()
    }
  }

  // MARK: Receiving

  /// Observes teardown in the same actor turn as a control callback.
  func handleControlForTesting(
    _ bytes: [UInt8]
  ) -> (waiting: Bool, closed: Bool) {
    let waiting = attachWaiter != nil
    let current = connection
    handleControl(bytes, generation: connectionGeneration)
    return (waiting, current?.isClosed == true)
  }

  private func handleControl(_ bytes: [UInt8], generation: UInt64) {
    guard generation == connectionGeneration else { return }
    let messages: [ControlMessage]
    do { messages = try reader.append(bytes) } catch {
      connectionFailed(.protocolViolation)
      publish()
      return
    }
    for message in messages {
      guard generation == connectionGeneration else { break }
      handle(message)
    }
    publish()
  }

  private func heard() {
    lastHeardAt = timing.now()
    if lifecycle.state == .suspect, epoch != nil {
      probeSentAt = nil
      move(to: .active)
    }
  }

  private func handle(_ message: ControlMessage) {
    switch message {
    case let .attached(attached): handleAttached(attached)
    case let .inputAck(e, sequence):
      guard e == epoch, var queue else { return }
      guard sequence < queue.nextSequence else {
        connectionFailed(.protocolViolation)
        return
      }
      heard()
      queue.acknowledge(through: sequence)
      self.queue = queue
      inputAwaitingSince = queue.isEmpty ? nil : timing.now()
      if resendFrom != nil { resendRefused() }
      maybeSendGrid()
    case let .pong(e, nonce):
      guard e == epoch, let ping, ping.nonce == nonce else { return }
      heard()
      liveness.sample(timing.now() - ping.sentAt)
      self.ping = nil
      probeSentAt = nil
    case let .ping(e, nonce):
      guard e == epoch else { return }
      heard()
      send(.pong(epoch: e, nonce: nonce))
    case let .sessionExited(e, status, _):
      guard e == epoch else { return }
      heard()
      exitStatus = status
      // Keep the connection: the final screen may still arrive.
      enterFinal(.sessionExited, keepConnection: true)
    case let .detached(e), let .terminated(e):
      guard e == epoch else { return }
      heard()
      resumeCloseWaiters()
    case let .error(error):
      heard()
      handleError(error)
    case let .copyChunk(e, id, index, text):
      guard e == epoch else { return }
      heard()
      guard var current = copy, current.id == id, current.epoch == e,
        current.next == index,
        current.text.utf8.count + text.utf8.count <= ControlMessage.maxCopyBytes
      else {
        failCopy(CopyError(.malformed))
        return
      }
      // Release the stored copy first, so the append mutates a uniquely
      // referenced buffer instead of copying the whole text per chunk.
      copy = nil
      current.text += text
      current.next += 1
      copy = current
    case let .copyResult(e, id, total, error):
      guard e == epoch else { return }
      heard()
      guard let current = copy, current.id == id else { return }
      copy = nil
      if let error {
        current.waiter.resume(throwing: CopyError(error))
      } else if total == UInt64(current.text.utf8.count) {
        current.waiter.resume(returning: current.text)
      } else {
        current.waiter.resume(throwing: CopyError(.malformed))
      }
    case let .layout(e, next):
      guard e == epoch else { return }
      heard()
      guard agreedFeatures.contains(.layoutControl) else {
        connectionFailed(.protocolViolation)
        return
      }
      guard next != layout else { return }
      layout = next
      publish()
    case let .layoutResult(e, id, error):
      guard e == epoch else { return }
      heard()
      guard let waiter = layoutWaiters.removeValue(forKey: id) else { return }
      if let error {
        waiter.resume(throwing: LayoutError(error))
      } else {
        waiter.resume()
      }
    case .attach, .input, .screenAck, .detach, .terminate, .viewport,
      .requestFullScreen, .copySelection, .layoutAction:
      // Client-to-server messages are never valid from the host.
      connectionFailed(.protocolViolation)
    }
  }

  private func handleAttached(_ attached: ControlMessage.Attached) {
    guard !expireAttachmentIfNeeded() else { return }
    guard attachWaiter != nil, epoch == nil, var queue, var store else {
      connectionFailed(.protocolViolation)
      return
    }
    guard attached.writerID == queue.writerID,
      attached.lastFullyAppliedInputSequence < queue.nextSequence
    else {
      finishAttach(.protocolViolation)
      return
    }
    epoch = attached.attachmentEpoch
    attachProgressTask?.cancel()
    attachProgressTask = nil
    hostFeatures = attached.features
    frameBases = []
    failCopy(CopyError(.staleEpoch))
    failLayoutActions(LayoutError(.staleEpoch))
    // A host without `layoutControl` sends none; an older layout would
    // offer stale tabs and panes.
    if !hostFeatures.agreed(with: RSTFeatures.supported)
      .contains(.layoutControl)
    {
      layout = nil
    }
    heard()
    store.fence(epoch: attached.attachmentEpoch)
    self.store = store
    resizeRevision = max(resizeRevision, attached.resizeRevision)
    // Retry what the host has not applied: original identifiers, new
    // epoch. Admitted partial operations continue at the host.
    let retry = queue.reconcile(
      serverApplied: attached.lastFullyAppliedInputSequence
    )
    self.queue = queue
    guard
      retry.allSatisfy({
        limits.permits($0.operation)
          && Self.fitsControlRecord(
            $0.operation,
            limit: limits.maxControlRecordBytes
          )
      })
    else {
      finishAttach(.protocolViolation)
      return
    }
    // Another client may have resized the session since our last
    // request: compare with this attachment's screen, except for a
    // resize that is being retried.
    requestedGrid = nil
    for entry in retry {
      if case let .resize(columns, rows, _) = entry.operation {
        requestedGrid = GridSize(columns: columns, rows: rows)
      }
    }
    for entry in retry { sendInput(entry, epoch: attached.attachmentEpoch) }
    if let early = earlySnapshot {
      earlySnapshot = nil
      install(early)
    }
  }

  private func handleError(_ error: ControlMessage.RSTError) {
    if attachWaiter != nil {
      finishAttach(.rejected(error.code))
      return
    }
    switch error.code {
    case .inputBackpressure, .inputGap:
      let from = error.sequence ?? queue?.entries.first?.sequence
      if let from { resendFrom = min(resendFrom ?? from, from) }
    case .unknownSession, .wrongInstance: enterFinal(.sessionLost)
    case .sessionExited: enterFinal(.sessionExited, keepConnection: true)
    case .expired, .unauthorized:
      needsFreshGrant = true
      reconnect(after: .attachRejected(error.code))
    default:
      // Reattachment reconciles input from the host's ledger.
      reconnect(after: .attachRejected(error.code))
    }
  }

  private func handleSnapshot(_ decoded: DecodedScreen?, generation: UInt64) {
    guard generation == connectionGeneration else { return }
    guard !expireAttachmentIfNeeded() else {
      publish()
      return
    }
    guard let decoded, decoded.snapshot.sessionID == store?.sessionID else {
      noteFailure(.snapshotRejected)
      publish()
      return
    }
    if epoch == nil {
      // Snapshot stream overtook `Attached`; keep only the newest.
      if let earlySnapshot {
        let incoming = decoded.snapshot
        let retained = earlySnapshot.snapshot
        guard
          incoming.attachmentEpoch > retained.attachmentEpoch
            || (incoming.attachmentEpoch == retained.attachmentEpoch
              && incoming.screenRevision > retained.screenRevision)
        else { return }
      }
      earlySnapshot = decoded
      return
    }
    install(decoded)
    publish()
  }

  private func install(_ decoded: DecodedScreen) {
    guard !expireAttachmentIfNeeded() else { return }
    guard var store, let epoch else { return }
    // A future epoch has no attachment on this connection. Reject before
    // it can fence the store or reach presentation.
    guard decoded.snapshot.attachmentEpoch <= epoch else {
      noteFailure(.snapshotRejected)
      return
    }
    switch store.install(decoded.snapshot) {
    case .installed:
      // Commit only after the configured presentation owner accepts the
      // frame, so refusal neither acknowledges it nor fences a same-revision
      // retry. A headless client owns the validated screen in its store.
      let accepted = sink?.install(decoded.frame) ?? true
      // A synchronous presentation owner can consume the remaining budget.
      // Enforce the same absolute deadline before committing readiness.
      guard !expireAttachmentIfNeeded() else { return }
      guard accepted else {
        noteFailure(.snapshotRejected)
        return
      }
      self.store = store
      if let frame = decoded.paneFrame { retainBase(frame) }
      if decoded.snapshot.attachmentEpoch == epoch { heard() }
      send(
        .screenAck(
          epoch: epoch,
          screenRevision: decoded.snapshot.screenRevision
        )
      )
      resizeRevision = max(resizeRevision, decoded.snapshot.resizeRevision)
      lastScreenAt = Date(timeIntervalSince1970: timing.wallClock())
      if attachWaiter != nil, decoded.snapshot.attachmentEpoch == epoch {
        // A complete current screen: input may resume.
        move(to: .active)
        backoff.reset()
        failedAttempts = 0
        lastFailure = nil
        lastFailureDetail = nil
        finishAttach(.active)
        maybeSendGrid()
      }
    case .stale: break
    case .rejected: noteFailure(.snapshotRejected)
    }
  }

  /// Any screen record: legacy snapshots and complete frames are mapped
  /// here, off the actor; a delta is applied on the actor to its base.
  nonisolated static func decodeRecord(
    _ bytes: [UInt8],
    limits: NegotiatedLimits = NegotiatedLimits()
  ) -> DecodedRecord? {
    guard let record = try? SnapshotFrame.decodeRecord(bytes, limits: limits)
    else { return nil }
    switch record {
    case let .snapshot(snapshot):
      return .screen(
        DecodedScreen(
          snapshot: snapshot,
          frame: PresentationMapper.map(snapshot)
        )
      )
    case let .frame(frame, header):
      return screen(frame, header: header).map { .screen($0) }
    case let .delta(delta, header): return .delta(delta, header)
    }
  }

  nonisolated static func screen(
    _ frame: PaneFrame,
    header: RSTFrameHeader
  ) -> DecodedScreen? {
    guard let snapshot = try? FrameScreenMapper.snapshot(frame, header: header)
    else { return nil }
    var presentation = PresentationMapper.map(snapshot)
    presentation.rowKeys = frame.rowKeys
    return DecodedScreen(
      snapshot: snapshot,
      frame: presentation,
      paneFrame: frame
    )
  }

  // MARK: Deltas (spec.roaming.md §7.4)

  private func retainBase(_ frame: PaneFrame) {
    let now = timing.now()
    frameBases.removeAll {
      $0.frame.identity.revision == frame.identity.revision
        || now - $0.at > Self.frameBaseLifetime
    }
    frameBases.append((frame, now))
    if frameBases.count > Self.retainedFrameBases {
      frameBases.removeFirst(frameBases.count - Self.retainedFrameBases)
    }
  }

  /// The retained frame `delta` names. The newest base is kept however
  /// old it is: the host bases each delta on the last acknowledged screen,
  /// which after an idle pause is older than the retention window.
  private func deltaBase(for delta: FrameDelta) -> PaneFrame? {
    let now = timing.now()
    guard
      let index = frameBases.lastIndex(where: {
        $0.frame.identity.revision == delta.baseRevision
      })
    else { return nil }
    let entry = frameBases[index]
    guard
      index == frameBases.count - 1 || now - entry.at <= Self.frameBaseLifetime
    else { return nil }
    return entry.frame
  }

  private func handleDelta(
    _ delta: FrameDelta,
    header: RSTFrameHeader,
    decoded: DecodedScreen?,
    generation: UInt64
  ) {
    guard generation == connectionGeneration else { return }
    guard agreedFeatures.contains(.screenDeltas), let epoch,
      header.sessionID == store?.sessionID
    else {
      noteFailure(.snapshotRejected)
      publish()
      return
    }
    // Only an attachment's current screens are bases; an older epoch's
    // delta is stale like its snapshots.
    guard header.attachmentEpoch == epoch else { return }
    if let decoded {
      deltaStatistics.applied += 1
      install(decoded)
    } else {
      // No partial screen. The request retires the delta's stream (both
      // in-flight slots would otherwise stay held) without the host
      // adopting it as a base, as a `ScreenAck` would.
      deltaStatistics.requestedFull += 1
      send(
        .requestFullScreen(epoch: epoch, screenRevision: header.screenRevision)
      )
    }
    publish()
  }

  // MARK: Copy (spec.roaming.md §7.5)

  /// The newest installed screen in the shared frame model, from which a
  /// selection takes its addresses and row versions.
  public var currentPaneFrame: PaneFrame? { frameBases.last?.frame }

  /// Copies a selection's text from the host's grid. Fails with
  /// `selectionChanged`, `historyUnavailable`, `limitExceeded` or `busy`;
  /// a reattachment cancels it and no partial text is returned.
  public func copySelection(
    _ request: CopySelectionRequest
  ) async throws -> String {
    guard agreedFeatures.contains(.copySelection), let epoch,
      request.screenRowVersions.count <= ControlMessage.maxCopyScreenRows
    else { throw CopyError(.unsupported) }
    guard copy == nil else { throw CopyError(.busy) }
    let ordered =
      (request.start.address.row, request.start.column) <= (
        request.end.address.row, request.end.column
      ) ? (request.start, request.end) : (request.end, request.start)
    guard ordered.0.address.row >= 0, ordered.0.column >= 0,
      ordered.1.column >= 0
    else { throw CopyError(.malformed) }
    let id = nextCopyID
    nextCopyID &+= 1
    let message = ControlMessage.CopySelection(
      attachmentEpoch: epoch,
      requestID: id,
      generation: ordered.0.address.generation,
      alternateScreen: ordered.0.address.alternateScreen,
      startRow: UInt64(ordered.0.address.row),
      startColumn: UInt64(ordered.0.column),
      endRow: UInt64(ordered.1.address.row),
      endColumn: UInt64(ordered.1.column),
      unit: request.unit,
      screenRowVersions: request.screenRowVersions.map {
        [UInt64(max($0.address.row, 0)), $0.version]
      }
    )
    return try await withCheckedThrowingContinuation { waiter in
      copy = (id, epoch, "", 0, waiter)
      send(.copySelection(message))
    }
  }

  /// Copies a presentation selection (in host addresses) that reaches
  /// beyond the shown frame: `TerminalSession.remoteCopyHandler`.
  public func copySelection(
    _ selection: PresentationSelection
  ) async throws -> String {
    try await copySelection(CopySelectionRequest(selection))
  }

  /// Whether the attached host takes `LayoutAction` (§7.6).
  public var supportsLayoutControl: Bool {
    epoch != nil && agreedFeatures.contains(.layoutControl)
  }

  /// Asks the host to change the workspace layout; returns once applied.
  /// The new layout and screen follow as for a change made on the Mac.
  /// Throws `LayoutError`: `unsupported` without `layoutControl` or while
  /// not attached, `busy` with too many unanswered, `staleEpoch` when a
  /// reattachment cancels it, or the host's refusal.
  public func layout(_ action: LayoutAction) async throws {
    guard action.isValid else { throw LayoutError(.inputInvalid) }
    guard let epoch, agreedFeatures.contains(.layoutControl) else {
      throw LayoutError(.unsupported)
    }
    guard layoutWaiters.count < Self.maxPendingLayoutActions else {
      throw LayoutError(.busy)
    }
    let id = nextLayoutID
    nextLayoutID &+= 1
    try await withCheckedThrowingContinuation { waiter in
      layoutWaiters[id] = waiter
      send(.layoutAction(epoch: epoch, requestID: id, action))
    }
  }

  private func failLayoutActions(_ error: LayoutError) {
    let waiters = layoutWaiters
    layoutWaiters = [:]
    for waiter in waiters.values { waiter.resume(throwing: error) }
  }

  private func failCopy(_ error: CopyError) {
    guard let current = copy else { return }
    copy = nil
    current.waiter.resume(throwing: error)
  }

  nonisolated static func decode(
    _ bytes: [UInt8],
    limits: NegotiatedLimits = NegotiatedLimits()
  ) -> DecodedScreen? {
    guard let snapshot = try? SnapshotFrame.decode(bytes, limits: limits) else {
      return nil
    }
    return DecodedScreen(
      snapshot: snapshot,
      frame: PresentationMapper.map(snapshot)
    )
  }

  // MARK: Input

  private func sendInput(_ entry: ClientInputQueue.Entry, epoch: UInt64) {
    send(
      .input(
        .init(
          attachmentEpoch: epoch,
          sequence: entry.sequence,
          // A retry may reach an older host than the one that queued it.
          operation: Self.operation(entry.operation, for: hostFeatures)
            ?? entry.operation
        )
      )
    )
    if inputAwaitingSince == nil { inputAwaitingSince = timing.now() }
  }

  /// Resends from the refused sequence once the host made progress.
  private func resendRefused() {
    guard let from = resendFrom, let epoch, let queue else { return }
    resendFrom = nil
    for entry in queue.entries where entry.sequence >= from {
      sendInput(entry, epoch: epoch)
    }
  }

  private func maybeSendGrid() {
    guard lifecycle.state == .active, let desired = desiredGrid, let epoch,
      var queue, let screen = store?.current, screen.attachmentEpoch == epoch
    else { return }
    let reference =
      requestedGrid ?? GridSize(columns: screen.columns, rows: screen.rows)
    guard desired != reference else { return }
    let (revision, overflow) = max(resizeRevision, screen.resizeRevision)
      .addingReportingOverflow(1)
    guard !overflow else {
      noteFailure(.resizeUnavailable)
      return
    }
    let operation = InputOperation.resize(
      columns: desired.columns,
      rows: desired.rows,
      resizeRevision: revision
    )
    guard Self.fitsControlRecord(operation, limit: limits.maxControlRecordBytes)
    else { return }
    // When full, retried after the next acknowledgment.
    guard let entry = try? queue.enqueue(operation) else { return }
    self.queue = queue
    resizeRevision = revision
    requestedGrid = desired
    sendInput(entry, epoch: epoch)
  }

  // MARK: Liveness

  private func startLiveness() {
    guard livenessTask == nil else { return }
    let tick = configuration.livenessTick
    let timing = timing
    livenessTask = Task { [weak self] in
      while true {
        do { try await timing.sleep(tick) } catch { return }
        guard let self, await self.tick() else { return }
      }
    }
  }

  private func stopLiveness() {
    livenessTask?.cancel()
    livenessTask = nil
  }

  /// Heartbeats and staleness (spec §9). Returns false once finished.
  private func tick() -> Bool {
    let state = lifecycle.state
    if state.isTerminal { return false }
    guard connection != nil, epoch != nil else { return true }
    let now = timing.now()
    let timeout = liveness.staleTimeout
    switch state {
    case .active:
      let start = [inputAwaitingSince, probeSentAt].compactMap { $0 }.min()
      if let start,
        liveness.isStale(awaitingResponseFor: now - max(start, lastHeardAt))
      {
        noteFailure(.stale)
        move(to: .suspect)
        sendProbe()
      } else if ping == nil,
        now - max(lastSentAt, lastHeardAt) >= configuration.heartbeatInterval
      {
        sendPing()
      } else if let from = resendFrom, queue?.entries.first?.sequence == from {
        // Nothing earlier is pending at the host: resend now.
        resendRefused()
      }
    case .suspect:
      if let sent = probeSentAt, now - sent > timeout {
        reconnect(after: .stale)
      } else if probeSentAt == nil {
        sendProbe()
      }
    default: break
    }
    publish()
    return true
  }

  private func sendPing() {
    guard let epoch else { return }
    let nonce = nextNonce
    nextNonce &+= 1
    ping = (nonce, timing.now())
    send(.ping(epoch: epoch, nonce: nonce))
  }

  /// A ping whose response is awaited for staleness.
  private func sendProbe() {
    guard epoch != nil, connection != nil else { return }
    probeSentAt = timing.now()
    sendPing()
  }

  // MARK: Closing

  private func waitForClose() async {
    let deadline = configuration.detachDeadline
    let timing = timing
    await withCheckedContinuation { continuation in
      closeWaiters.append(continuation)
      // Background detach and explicit close can overlap across this
      // suspension. They share the same connection and earliest deadline.
      guard closeTimeoutTask == nil else { return }
      closeWaitGeneration &+= 1
      let generation = closeWaitGeneration
      closeTimeoutTask = Task { [weak self] in
        do { try await timing.sleep(deadline) } catch { return }
        await self?.closeTimedOut(generation: generation)
      }
    }
  }

  private func closeTimedOut(generation: UInt64) {
    guard generation == closeWaitGeneration else { return }
    resumeCloseWaiters()
  }

  private func resumeCloseWaiters() {
    closeWaitGeneration &+= 1
    closeTimeoutTask?.cancel()
    closeTimeoutTask = nil
    let waiters = closeWaiters
    closeWaiters = []
    for waiter in waiters { waiter.resume() }
  }

  private func enterFinal(
    _ state: ClientConnectionState,
    keepConnection: Bool = false
  ) {
    cancelConnecting()
    if !keepConnection { dropConnection() }
    move(to: state)
    stopLiveness()
    publish()
  }

  // MARK: State and status

  @discardableResult
  private func move(to next: ClientConnectionState) -> Bool {
    do { try lifecycle.transition(to: next) } catch { return false }
    publish()
    return true
  }

  private func noteFailure(_ failure: RoamingFailure, detail: String? = nil) {
    lastFailure = failure
    lastFailureDetail = detail
    publish()
  }

  /// A connect error as one bounded line: what the network or TLS stack
  /// said, so an unreachable endpoint is distinguishable from a refused
  /// handshake or a certificate mismatch.
  public static func reason(_ error: any Error) -> String {
    let text: String =
      switch error as? RSTTransportError {
      case let .handshake(message)?: message
      case .pinMismatch?: "the Mac's certificate does not match the grant"
      case .resourceLimit?: "the grant's limits are invalid"
      case let other?: String(describing: other)
      case nil: String(describing: error)
      }
    let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
    return String((line.isEmpty ? "unknown error" : line).prefix(200))
  }

  private func publish() {
    let next = RoamingStatus(
      state: lifecycle.state,
      sessionID: grant?.sessionID,
      lastScreenAt: lastScreenAt,
      screenRevision: store?.current?.screenRevision,
      pendingInputCount: queue?.entries.count ?? 0,
      refusedInputCount: refusedInputCount,
      title: store?.current?.title ?? "",
      exitStatus: exitStatus,
      lastFailure: lastFailure,
      lastFailureDetail: lastFailureDetail,
      reconnectAttempt: backoff.attempt,
      roamingEndpoint: grant?.endpoint,
      layout: layout
    )
    guard next != currentStatus else { return }
    currentStatus = next
    statusHandler?(next)
  }

  private static func isUsable(_ grant: BootstrapGrant) -> Bool {
    guard grant.protocol == RSTLimits.protocolName, grant.limits.isValid,
      grant.limits.effective.contains(grant.initialGrid)
    else { return false }
    let attach = ControlMessage.attach(
      .init(
        sessionID: grant.sessionID,
        serverInstanceID: grant.serverInstanceID,
        writerID: grant.writerID,
        applicationToken: grant.applicationToken
      )
    )
    return
      (try? ControlRecord.encode(
        attach,
        limit: grant.limits.effective.maxControlRecordBytes
      )) != nil
  }

  private static func failure(for error: any Error) -> RoamingFailure {
    switch error as? RemoteBootstrapError {
    case .hostKeyRejected: .hostKeyRejected
    case .authenticationFailed: .authenticationFailed
    case .credentialUnavailable: .credentialUnavailable
    case .protocolViolation: .protocolViolation
    case .unreachable, nil: .unreachable
    }
  }

  private static func clientError(
    for failure: RoamingFailure
  ) -> RoamingClientError {
    switch failure {
    case .hostKeyRejected: .hostKeyRejected
    case .authenticationFailed: .authenticationFailed
    case .credentialUnavailable: .credentialUnavailable
    case .protocolViolation: .protocolViolation
    default: .unreachable
    }
  }
}

extension RoamingTarget {
  var sessionID: SessionID? {
    switch self {
    case let .resume(id), let .reveal(id, _): id
    case .create: nil
    }
  }
}
