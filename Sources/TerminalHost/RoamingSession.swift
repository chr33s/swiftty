#if os(macOS)
import Dispatch
import Foundation
import ScreenProtocol
import SessionCore
import SwiftMuxProtocol
import SwiftMuxService
import SwifttyEngine
import Synchronization

/// One roaming session: an RST/1 view of a SwiftMux workspace (spec.inbox.md
/// §1). The SwiftMux service owns the shell, PTY and terminal;
/// this owns only the RST side: the writer and its input ledger, the
/// attachment epoch, and snapshot scheduling for the workspace's active
/// pane.
///
/// Each RST attachment takes the workspace's interactive lease through an
/// in-process SMX client, so the native app and remote clients share one
/// single-writer rule. Detaching releases the lease; the shell keeps
/// running. Never logs tokens, input or terminal contents.
///
/// Sendable: ledger, attachment, lease and revision state are confined to
/// the serial owner `queue`; `status` lives in the `statusBox` Mutex;
/// `onTerminateRequested` is set once by the registry before publication.
/// No unsafe storage.
public final class RoamingSession: @unchecked Sendable {
  public enum State: String, Sendable, Hashable {
    case reserved, attached, detached, exited, terminated
  }

  /// Thread-safe summary for the registry and diagnostics.
  public struct Status: Sendable {
    public var state: State
    public var columns: Int
    public var rows: Int
    public var exitStatus: Int32?
    public var everAttached: Bool
    public var lastActivity: ContinuousClock.Instant
    /// Seconds since 1970 of `lastActivity`.
    public var lastActivityWall: Double
    public var exitedAt: ContinuousClock.Instant?
    /// An RST attachment currently holds the workspace lease.
    public var isAttached = false
    /// Every pane of the workspace has exited (from the last layout seen).
    public var allPanesExited = false
  }

  /// Revision high-water marks that a replacement session for the same
  /// workspace must start above, so a warm client's screen store (which
  /// never accepts an older epoch or revision) keeps installing screens.
  public struct Floor: Sendable, Equatable {
    public var epoch: UInt64 = 0
    public var screenRevision: UInt64 = 0
    public var resizeRevision: UInt64 = 0
    public init() {}
  }

  /// Bounded-resource and progress counters (never terminal contents).
  public struct Diagnostics: Sendable, Equatable {
    public var lastAppliedInput: UInt64
    public var pendingInputOperations: Int
    public var resizeRevision: UInt64
    public var screenRevision: UInt64
    public var attachmentEpoch: UInt64
    public var writerFailed: Bool
    public var activePane: PaneID?
  }

  public let id: SessionID
  public var workspace: WorkspaceID { id.workspace }
  let queue: DispatchQueue
  private let service: MuxService
  private let statusBox: Mutex<Status>
  private let snapshotEncoder: @Sendable (ScreenSnapshot) throws -> [UInt8]
  private let encodeQueue = DispatchQueue(
    label: "swiftmux.roaming.snapshot-encode",
    qos: .utility
  )

  /// Called (on the owner queue) when an attached client asks to
  /// terminate; the registry revokes credentials and ends the workspace.
  var onTerminateRequested: (@Sendable (SessionID) -> Void)?

  // MARK: Owner-queue state

  /// Revocation is visible to the service without entering the owner queue.
  /// Commands admitted before revocation may finish; later ones are refused.
  private final class LeaseAdmission: Sendable {
    private let active = Mutex(true)
    private let connection: any RSTConnection

    init(connection: any RSTConnection) { self.connection = connection }

    var isAllowed: Bool { active.withLock { $0 } && !connection.isClosed }

    func revoke() { active.withLock { $0 = false } }
  }

  private var leaseAdmission: LeaseAdmission?
  private var authorizationToken: ApplicationToken?
  private var ledger: HostInputLedger
  private var attachment: HostAttachment? {
    didSet {
      guard oldValue !== attachment else { return }
      pendingSnapshotEncodes.removeAll()
      for send in snapshotSends.values { send.task.cancel() }
    }
  }
  private struct SnapshotEncoding: Sendable {
    let snapshot: ScreenSnapshot
    let stream: UInt64
    let attachment: HostAttachment
  }
  private struct SnapshotSend {
    let stream: UInt64
    let attachment: HostAttachment
    let task: Task<Void, Never>
  }
  /// One encoder plus its sends share two active work slots. A task retains
  /// its slot until its send returns, even after cancellation or fencing.
  private var encodingSnapshot = false
  private var snapshotSends: [UUID: SnapshotSend] = [:]
  /// At most the current attachment's two scheduler-owned captures wait here.
  /// Replacement removes stale captures before another worker can start them.
  private var pendingSnapshotEncodes: [SnapshotEncoding] = []
  private var mux: MuxLocalSession?
  /// The SMX attachment of `mux`'s lease.
  private var muxAttachment: AttachmentID?
  /// Called once the previous lease is fully released.
  private var afterClose: [() -> Void] = []
  private var closing = false
  private var awaitingServiceClose = false
  private var inputInFlight = false
  /// Increments per attach; only the newest may acquire the lease.
  private var attachGeneration: UInt64 = 0
  /// A refused operation waits for its backoff before resubmission.
  private var retryScheduled = false
  private var epoch: UInt64 = 0
  private var resizeRevision: UInt64 = 0
  private var screenRevision: UInt64 = 0
  private var geometryGeneration: UInt64 = 0
  private var layoutRevision: UInt64 = 0
  private var activePane: PaneID?
  private var exitStatus: Int32?
  private var terminated = false
  private var writerFailed = false
  private var columns: Int
  private var rows: Int
  /// From the attaching credential: a lease held by another frontend may
  /// be taken over (bootstrap `takeover`). Owner queue only.
  private var allowTakeover = false
  /// From the attaching credential: the pane to focus once the lease is
  /// held, and the exact lease generation a takeover may displace.
  private var target: ResumeTarget?

  init(
    id: SessionID,
    service: MuxService,
    grid: GridSize,
    floor: Floor = Floor(),
    pendingInputLimit: Int = RSTLimits.maxPendingInputBytes,
    snapshotEncoder: @escaping @Sendable (ScreenSnapshot) throws -> [UInt8] = {
      try SnapshotFrame.encode($0)
    }
  ) {
    epoch = floor.epoch
    screenRevision = floor.screenRevision
    resizeRevision = floor.resizeRevision
    self.id = id
    self.service = service
    self.snapshotEncoder = snapshotEncoder
    columns = grid.columns
    rows = grid.rows
    ledger = HostInputLedger(byteLimit: pendingInputLimit)
    queue = DispatchQueue(label: "swiftmux.roaming", qos: .userInitiated)
    let now = ContinuousClock.now
    statusBox = Mutex(
      Status(
        state: .reserved,
        columns: grid.columns,
        rows: grid.rows,
        exitStatus: nil,
        everAttached: false,
        lastActivity: now,
        lastActivityWall: Date().timeIntervalSince1970,
        exitedAt: nil
      )
    )
  }

  // MARK: Public surface

  public var status: Status { statusBox.withLock { $0 } }

  var attachmentAttemptGeneration: UInt64 { queue.sync { attachGeneration } }

  /// Whether an attachment is waiting for its service lease.
  var isAcquiringLease: Bool {
    queue.sync { mux != nil && muxAttachment == nil }
  }

  public var diagnostics: Diagnostics {
    queue.sync {
      Diagnostics(
        lastAppliedInput: ledger.lastApplied,
        pendingInputOperations: ledger.admitted.count,
        resizeRevision: resizeRevision,
        screenRevision: screenRevision,
        attachmentEpoch: epoch,
        writerFailed: writerFailed,
        activePane: activePane
      )
    }
  }

  /// Where a replacement session must start (see `Floor`).
  public var floor: Floor { queue.sync { floorOnQueue() } }

  private func floorOnQueue() -> Floor {
    var floor = Floor()
    floor.epoch = epoch
    floor.screenRevision = screenRevision
    floor.resizeRevision = resizeRevision
    return floor
  }

  /// Checks retention and closes remote admission on the same owner turn,
  /// so a pending lease cannot advance beyond the retired revision floor.
  func retire(
    when shouldRetire: (Status) -> Bool
  ) -> (status: Status, floor: Floor)? {
    queue.sync {
      let status = statusBox.withLock { $0 }
      guard shouldRetire(status) else { return nil }
      endAuthorizationOnQueue()
      return (status, floorOnQueue())
    }
  }

  /// The writer currently authorized for input, if any.
  public var writerID: WriterID? { queue.sync { ledger.writerID } }

  /// Installs `writer` for subsequent input (bootstrap create/resume). A
  /// different writer may take over only when no admitted operation is
  /// incomplete. Terminated sessions refuse authorization.
  public func authorize(writer: WriterID) throws(HostInputLedger.Rejection) {
    guard try authorize(writer: writer, token: nil) else { throw .wrongWriter }
  }

  /// Returns false when the workspace's remote authorization has ended.
  @discardableResult
  func authorize(
    writer: WriterID,
    token: ApplicationToken?
  ) throws(HostInputLedger.Rejection) -> Bool {
    let result: Result<Bool, HostInputLedger.Rejection> = queue.sync {
      guard !terminated else { return .success(false) }
      do throws(HostInputLedger.Rejection) {
        if ledger.writerID != writer, !inputInFlight {
          // Operations here are written whole or not at all, and none is
          // with the pane now: the old writer's unsent input is dropped,
          // never replayed for the new one.
          ledger.abandonUnsent()
        }
        try ledger.authorize(writer)
        revokeLeaseAdmission()
        authorizationToken = token
        return .success(true)
      } catch { return .failure(error) }
    }
    return try result.get()
  }

  /// An owned export of the active pane's screen (diagnostics and tests).
  public func currentSnapshot() async -> ScreenSnapshot? {
    let (pane, stamp) = queue.sync { (activePane, stamp(epoch: epoch)) }
    guard let pane else { return nil }
    return await withCheckedContinuation { continuation in
      service.inspect(
        pane: pane,
        { ScreenExporter.export($0, stamp: stamp) },
        completion: { continuation.resume(returning: $0) }
      )
    }
  }

  private func endAuthorizationOnQueue() {
    guard !terminated else { return }
    revokeLeaseAdmission()
    terminated = true
    authorizationToken = nil
    statusBox.withLock {
      $0.state = .terminated
      $0.isAttached = false
    }
    if let a = attachment {
      a.isCurrent = false
      a.closeAfterFlush()
    }
    attachment = nil
    closeMux {}
  }

  // MARK: Attachment entry points (from HostAttachment)

  func attach(
    _ attachment: HostAttachment,
    writer: WriterID,
    token: ApplicationToken? = nil,
    expiresAt: ContinuousClock.Instant? = nil,
    takeover: Bool = false,
    target: ResumeTarget? = nil
  ) async -> AttachOutcome<UInt64> {
    await withCheckedContinuation { continuation in
      queue.async { [self] in
        // Owner-queue state: read by `acquireLease` on this queue.
        allowTakeover = takeover || target?.expectedLease != nil
        self.target = target
        attachOnQueue(
          attachment,
          writer: writer,
          token: token,
          expiresAt: expiresAt
        ) { continuation.resume(returning: $0) }
      }
    }
  }

  func receive(_ message: ControlMessage, from attachment: HostAttachment) async
  {
    await withCheckedContinuation { continuation in
      queue.async { [self] in
        handle(message, from: attachment)
        continuation.resume()
      }
    }
  }

  func detach(_ attachment: HostAttachment) {
    queue.async { [self] in detachOnQueue(attachment) }
  }

  // MARK: Attach (owner queue)

  private func attachOnQueue(
    _ a: HostAttachment,
    writer: WriterID,
    token: ApplicationToken?,
    expiresAt: ContinuousClock.Instant?,
    completion: @escaping (AttachOutcome<UInt64>) -> Void
  ) {
    guard !terminated else { return completion(.failure(.unknownSession)) }
    guard !a.connection.isClosed else {
      return completion(.failure(.notAttached))
    }
    guard ledger.writerID == writer, let token,
      authorizationToken?.matches(token) == true
    else { return completion(.failure(.unauthorized)) }
    if let expiresAt, ContinuousClock.now >= expiresAt {
      return completion(.failure(.expired))
    }
    revokeLeaseAdmission()
    // Fence: the previous connection closes and its later input is
    // rejected because it is no longer the current attachment. Its lease
    // is released (after any in-flight input) before this one asks.
    if let previous = attachment, previous !== a {
      previous.fence()
      attachment = nil
    }
    // Only the newest attach may acquire: one queued behind an earlier
    // close is superseded and fails instead of orphaning a lease.
    attachGeneration &+= 1
    let generation = attachGeneration
    closeMux { [self] in
      guard generation == attachGeneration else {
        return completion(.failure(.staleEpoch))
      }
      acquireLease(
        a,
        writer: writer,
        token: token,
        expiresAt: expiresAt,
        generation: generation,
        completion: completion
      )
    }
  }

  private func acquireLease(
    _ a: HostAttachment,
    writer: WriterID,
    token: ApplicationToken,
    expiresAt: ContinuousClock.Instant?,
    generation: UInt64,
    completion: @escaping (AttachOutcome<UInt64>) -> Void
  ) {
    guard !terminated else { return completion(.failure(.unknownSession)) }
    guard !a.connection.isClosed else {
      return completion(.failure(.notAttached))
    }
    guard ledger.writerID == writer, authorizationToken?.matches(token) == true
    else { return completion(.failure(.unauthorized)) }
    if let expiresAt, ContinuousClock.now >= expiresAt {
      return completion(.failure(.expired))
    }
    let admission = LeaseAdmission(connection: a.connection)
    leaseAdmission = admission
    let session = MuxLocalSession(queue: queue)
    // Fails this attach without touching a newer one's client.
    let failAttach = { [self] (code: RSTErrorCode) in
      admission.revoke()
      if mux === session { closeMux {} } else { session.close() }
      completion(.failure(terminated ? .unknownSession : code))
    }
    let refusal = { [self] () -> RSTErrorCode? in
      if terminated { return .unknownSession }
      if mux !== session || generation != attachGeneration {
        return .staleEpoch
      }
      if a.connection.isClosed { return .notAttached }
      if ledger.writerID != writer || authorizationToken?.matches(token) != true
      {
        return .unauthorized
      }
      if let expiresAt, ContinuousClock.now >= expiresAt { return .expired }
      return nil
    }
    let leaseGranted = {
      [self] (attachment: AttachmentID, ws: WorkspaceSnapshot) in
      if let code = refusal() { return failAttach(code) }
      self.leaseGranted(
        a,
        writer: writer,
        attachment: attachment,
        ws,
        completion
      )
    }
    session.onEvent = { [weak self, weak session] event in
      guard let self, let session, self.mux === session else { return }
      self.muxEvent(event)
    }
    session.onPaneChanged = { [weak self, weak session] pane in
      guard let self, let session, self.mux === session else { return }
      if pane == self.activePane { self.contentChanged() }
    }
    session.onClosed = { [weak self, weak session] _ in
      guard let self, let session, self.mux === session else { return }
      self.leaseLost(reason: .internalError)
    }
    if let stale = mux {
      // Never two in-process clients for one session.
      mux = nil
      muxAttachment = nil
      stale.close()
    }
    mux = session
    session.connect(to: service, frontend: .native, remote: true)
    let target = WorkspaceSelector.id(workspace)
    session.request(
      .attach(AttachRequest(target)),
      expiresAt: expiresAt,
      isAdmitted: { admission.isAllowed },
      { [self] result in
        if let code = refusal() { return failAttach(code) }
        switch result {
        case let .success(.attached(attachment, ws)):
          leaseGranted(attachment, ws)
        case let .failure(error)
        where error.code == .leaseHeld && allowTakeover:
          // Explicitly requested at bootstrap: name the lease being
          // displaced so a newer holder is never taken over by accident.
          session.request(
            .listWorkspaces,
            expiresAt: expiresAt,
            isAdmitted: { admission.isAllowed },
            { [self] list in
              if let code = refusal() { return failAttach(code) }
              guard case let .success(.workspaces(summaries)) = list,
                let summary = summaries.first(where: { $0.id == workspace })
              else { return failAttach(.unknownSession) }
              // A link names the lease the user agreed to displace; a plain
              // takeover names the one just listed.
              let expected =
                self.target?.expectedLease ?? summary.leaseGeneration
              session.request(
                .takeover(target, expectedLease: expected),
                expiresAt: expiresAt,
                isAdmitted: { admission.isAllowed },
                { result in
                  if let code = refusal() { return failAttach(code) }
                  guard case let .success(.attached(attachment, ws)) = result
                  else { return failAttach(.writerBusy) }
                  leaseGranted(attachment, ws)
                }
              )
            }
          )
        case let .failure(error): failAttach(Self.code(error))
        case .success: failAttach(.internalError)
        }
      }
    )
  }

  private static func code(_ error: MuxError) -> RSTErrorCode {
    switch error.code {
    case .leaseHeld, .alreadyAttached: .writerBusy
    case .notFound: .unknownSession
    case .quiescing: .limitExceeded
    default: .internalError
    }
  }

  private func leaseGranted(
    _ a: HostAttachment,
    writer: WriterID,
    attachment smx: AttachmentID,
    _ ws: WorkspaceSnapshot,
    _ completion: (AttachOutcome<UInt64>) -> Void
  ) {
    muxAttachment = smx
    mux?.resetInput()
    apply(ws)
    if let pane = target?.pane, pane != activePane,
      ws.panes.contains(where: { $0.id == pane })
    {
      // Show the pane an attention link named; layout events follow.
      mux?.request(.focusPane(pane)) { _ in }
    }
    epoch += 1
    attachment = a
    a.epoch = epoch
    a.writerID = writer
    a.scheduler.reset()
    a.highestSubmittedScreenRevision = 0
    a.exitNoticeSent = false
    touch(state: exitStatus == nil ? .attached : .exited, attached: true)
    statusBox.withLock { $0.isAttached = true }
    a.send(
      .attached(
        .init(
          attachmentEpoch: epoch,
          writerID: writer,
          lastFullyAppliedInputSequence: ledger.lastApplied,
          partialInputSequence: nil,
          resizeRevision: resizeRevision,
          features: .supported
        )
      )
    )
    completion(.success(epoch))
    pumpInput()
    a.scheduler.markDirty()
    pumpSnapshots(a)
  }

  private func detachOnQueue(_ a: HostAttachment) {
    a.isCurrent = false
    guard attachment === a else { return }
    attachment = nil
    touch(state: exitStatus == nil && !terminated ? .detached : nil)
    statusBox.withLock { $0.isAttached = false }
    closeMux {}
  }

  private func revokeLeaseAdmission() {
    leaseAdmission?.revoke()
    // Pending requests retain their own ticket; the owner need not retain
    // a closed transport after its attachment has gone away.
    leaseAdmission = nil
  }

  /// Releases the lease after any in-flight input is answered: input
  /// sent to the service is applied (FIFO), so its outcome must be
  /// recorded before the connection goes away.
  private func closeMux(then next: @escaping () -> Void) {
    revokeLeaseAdmission()
    afterClose.append(next)
    guard !awaitingServiceClose else { return }
    guard mux != nil else { return drainAfterClose() }
    closing = true
    guard !inputInFlight else { return }
    guard let closed = mux else { return }
    mux = nil
    muxAttachment = nil
    closing = false
    awaitingServiceClose = true
    closed.close { [self] in
      awaitingServiceClose = false
      drainAfterClose()
    }
  }

  private func drainAfterClose() {
    let pending = afterClose
    afterClose = []
    for next in pending { next() }
  }

  /// The service ended the lease without being asked (another frontend
  /// took over, or the workspace ended).
  private func leaseLost(reason code: RSTErrorCode) {
    revokeLeaseAdmission()
    // Input the service admitted before releasing the lease was answered
    // first (FIFO); anything later was refused, so nothing is uncertain.
    let lost = mux
    mux = nil
    muxAttachment = nil
    inputInFlight = false
    lost?.close()
    statusBox.withLock { $0.isAttached = false }
    guard let a = attachment else { return }
    attachment = nil
    a.isCurrent = false
    a.fail(code)
    touch(state: exitStatus == nil && !terminated ? .detached : nil)
  }

  private func touch(state: State? = nil, attached: Bool = false) {
    let now = ContinuousClock.now
    let wall = Date().timeIntervalSince1970
    statusBox.withLock { s in
      if s.state == .terminated { return }
      if let state { s.state = state }
      if attached { s.everAttached = true }
      s.lastActivity = now
      s.lastActivityWall = wall
    }
  }

  // MARK: Service events (owner queue)

  private func muxEvent(_ event: MuxEvent) {
    switch event {
    case let .layout(ws): apply(ws)
    case let .paneExited(pane, status, _):
      guard pane == activePane else { return }
      exited(status)
    case .detached:
      // Ask whether the workspace still exists rather than parse text.
      guard let session = mux else { return }
      session.request(.listWorkspaces) { [self, weak session] result in
        guard let session, mux === session else { return }
        if case let .success(.workspaces(list)) = result,
          !list.contains(where: { $0.id == workspace })
        {
          markTerminatedOnQueue()
        } else {
          leaseLost(reason: .writerBusy)
        }
      }
    default: break
    }
  }

  private func markTerminatedOnQueue() {
    if let a = attachment { a.send(.terminated(epoch: a.epoch)) }
    endAuthorizationOnQueue()
  }

  /// Follows the workspace's active pane.
  private func apply(_ ws: WorkspaceSnapshot) {
    guard ws.id == workspace, ws.layoutRevision >= layoutRevision else {
      return
    }
    layoutRevision = ws.layoutRevision
    let allExited =
      !ws.panes.isEmpty && ws.panes.allSatisfy { $0.exitStatus != nil }
    statusBox.withLock { $0.allPanesExited = allExited }
    let pane = ws.activeTabSnapshot?.activePane
    let summary = pane.flatMap { ws.pane($0) }
    if let summary {
      columns = summary.columns
      rows = summary.rows
      statusBox.withLock { s in
        s.columns = summary.columns
        s.rows = summary.rows
      }
    }
    if pane != activePane {
      activePane = pane
      exitStatus = nil
      if let status = summary?.exitStatus {
        exited(status)
      } else {
        // The shown pane is live again: the session is no longer exited.
        statusBox.withLock { s in
          guard s.state == .exited else { return }
          s.state = attachment == nil ? .detached : .attached
          s.exitStatus = nil
          s.exitedAt = nil
        }
      }
      contentChanged()
    } else if let status = summary?.exitStatus, exitStatus == nil {
      exited(status)
    }
  }

  private func exited(_ status: Int32) {
    guard exitStatus == nil else { return }
    exitStatus = status
    if !inputInFlight {
      // Admitted but never written: the pane is gone, so retire it.
      for done in ledger.discard(through: ledger.lastAdmitted) {
        acknowledge(done)
      }
    }
    let now = ContinuousClock.now
    statusBox.withLock { s in
      guard s.state != .terminated else { return }
      s.state = .exited
      s.exitStatus = status
      s.exitedAt = now
    }
    contentChanged()
  }

  private func contentChanged() {
    guard let a = attachment, a.isCurrent else { return }
    a.scheduler.markDirty()
    pumpSnapshots(a)
  }

  // MARK: Control messages (owner queue)

  private func handle(_ message: ControlMessage, from a: HostAttachment) {
    guard a === attachment, a.isCurrent else {
      // A fenced attachment: nothing it sends takes effect.
      if case let .input(input) = message {
        a.send(.error(.init(.staleEpoch, sequence: input.sequence)))
      }
      return
    }
    guard let messageEpoch = message.epoch, messageEpoch == a.epoch else {
      if case let .input(input) = message {
        a.send(.error(.init(.staleEpoch, sequence: input.sequence)))
      } else {
        a.send(.error(.init(.staleEpoch)))
      }
      return
    }
    touch()
    switch message {
    case let .input(input):
      // Input returns a history window to live output, as typing does
      // in a local terminal.
      a.pendingViewportLines = 0
      if a.historyTop != nil {
        a.historyTop = nil
        contentChanged()
      }
      admit(input, from: a)
    case let .viewport(_, lines): moveHistoryWindow(by: Int(lines), for: a)
    case let .screenAck(_, revision):
      guard revision <= a.highestSubmittedScreenRevision else {
        a.fail(.malformed)
        detachOnQueue(a)
        return
      }
      for stream in a.scheduler.acknowledged(revision: revision) {
        a.connection.cancelSnapshot(stream: stream)
      }
      pumpSnapshots(a)
    case let .ping(_, nonce): a.send(.pong(epoch: a.epoch, nonce: nonce))
    case .detach:
      a.send(.detached(epoch: a.epoch))
      detachOnQueue(a)
      a.closeAfterFlush()
    case .terminate:
      a.send(.terminated(epoch: a.epoch))
      detachOnQueue(a)
      a.closeAfterFlush()
      onTerminateRequested?(id)
    default:
      // Server-to-client messages and repeated attaches are violations.
      a.fail(.malformed)
      detachOnQueue(a)
    }
  }

  /// Moves `a`'s history window. Requests that arrive while a move is
  /// resolving accumulate and follow it, so a continuous swipe moves by
  /// its whole distance instead of only its first step.
  private func moveHistoryWindow(by lines: Int, for a: HostAttachment) {
    let bound = Int(ControlMessage.maxViewportLines)
    a.pendingViewportLines = min(
      max(a.pendingViewportLines + lines, -bound),
      bound
    )
    if !a.viewportMoveInFlight { resolveViewportMove(for: a) }
  }

  /// Resolves the accumulated movement on the pane's queue, reading only,
  /// then presents it. Results for a replaced attachment, or overtaken by
  /// input returning to live output, are dropped.
  private func resolveViewportMove(for a: HostAttachment) {
    guard let pane = activePane, a.pendingViewportLines != 0 else { return }
    let lines = a.pendingViewportLines
    a.pendingViewportLines = 0
    a.viewportMoveInFlight = true
    let current = a.historyTop
    service.inspect(
      pane: pane,
      { ScreenExporter.historyTop($0, from: current, moving: lines) },
      completion: { [weak self] resolved in
        self?.queue
          .async { [weak self] in
            a.viewportMoveInFlight = false
            guard let self, a === self.attachment, a.isCurrent else { return }
            // Nil `resolved`: the pane is gone. Nil top: live output.
            if let top = resolved, a.historyTop == current, top != current {
              a.historyTop = top
              self.contentChanged()
            }
            self.resolveViewportMove(for: a)
          }
      }
    )
  }

  private func admit(_ input: ControlMessage.Input, from a: HostAttachment) {
    let sequence = input.sequence
    guard exitStatus == nil, !terminated else {
      a.send(.error(.init(.sessionExited, sequence: sequence)))
      return
    }
    guard let writer = a.writerID else { return }
    switch ledger.classify(
      writer: writer,
      sequence: sequence,
      operation: input.operation
    ) {
    case .alreadyApplied: a.send(.inputAck(epoch: a.epoch, sequence: sequence))
    case .inProgress:
      // Still queued for the pane; its acknowledgment follows.
      break
    case let .rejected(rejection):
      a.send(.error(.init(RSTErrorCode(rejection), sequence: sequence)))
    case .admit:
      if case .resize = input.operation, !canAdmitResize() {
        a.send(.error(.init(.limitExceeded, sequence: sequence)))
        return
      }
      guard !writerFailed else {
        a.send(.error(.init(.internalError, sequence: sequence)))
        return
      }
      // The pane encodes with its authoritative modes when written; the
      // bound is reserved meanwhile so admission stays bounded.
      ledger.reserve(sequence, operation: input.operation)
      pumpInput()
    }
  }

  /// Include queued resizes: a preceding operation can exhaust the revision
  /// before this one reaches the service. Refuse before reserving its sequence.
  private func canAdmitResize() -> Bool {
    var projected = resizeRevision
    for entry in ledger.admitted {
      if case let .resize(_, _, requested) = entry.operation {
        let (next, overflow) = projected.addingReportingOverflow(1)
        guard !overflow else { return false }
        projected = max(next, requested)
      }
    }
    return projected < UInt64.max
  }

  /// Submits the ledger's head to the pane, one operation at a time, so
  /// a refused operation can be retried without reordering.
  private func pumpInput() {
    guard !inputInFlight, !writerFailed, exitStatus == nil, !retryScheduled,
      let mux, mux.isOpen, let smx = muxAttachment, let pane = activePane,
      let head = ledger.admitted.first
    else { return }
    inputInFlight = true
    let done: (MuxError?) -> Void = { [weak self] error in
      self?.inputAnswered(head.sequence, error)
    }
    switch head.operation {
    case let .committedText(text):
      mux.input(.input(.text(text)), attachment: smx, pane: pane, done)
    case let .paste(text):
      mux.input(.input(.paste(text)), attachment: smx, pane: pane, done)
    case let .key(key):
      let keypad = mux.welcome?.features.contains(.keypadKeys) ?? false
      guard let (name, modifiers) = Self.muxKey(key, keypadKeys: keypad) else {
        done(nil)  // Keypad Begin has no main-keyboard key to fall back to.
        return
      }
      mux.input(
        .input(.key(name, modifiers)),
        attachment: smx,
        pane: pane,
        done
      )
    case let .resize(c, r, revision):
      let (nextRevision, overflow) = resizeRevision.addingReportingOverflow(1)
      guard !overflow else {
        done(MuxError(.invalidRequest, "resize revision exhausted"))
        return
      }
      geometryGeneration += 1
      let batch = GeometryBatch(
        layoutRevision: layoutRevision,
        generation: geometryGeneration,
        entries: [.init(pane: pane, columns: c, rows: r)]
      )
      mux.request(.setGeometry(batch)) { [weak self] result in
        guard let self else { return }
        if case .success = result {
          self.columns = c
          self.rows = r
          self.resizeRevision = max(nextRevision, revision)
          self.statusBox.withLock { s in
            s.columns = c
            s.rows = r
          }
        }
        if case let .failure(error) = result { done(error) } else { done(nil) }
      }
    }
  }

  private func inputAnswered(_ sequence: UInt64, _ error: MuxError?) {
    inputInFlight = false
    defer {
      // The shown pane exited while this was in flight (`exited` could
      // not retire then): nothing left may reach another pane.
      if exitStatus != nil, ledger.hasPending {
        for done in ledger.discard(through: ledger.lastAdmitted) {
          acknowledge(done)
        }
      }
    }
    var pumpAfterAnswer = false
    // The answer is recorded first, even when the lease is about to be
    // released: an operation the pane took must complete in the ledger,
    // or the next attachment would send it again.
    defer {
      if closing {
        closeMux {}
      } else if pumpAfterAnswer {
        // Next operation on a later turn: a synchronous answer never
        // recurses through `pumpInput`.
        queue.async { [weak self] in self?.pumpInput() }
      }
    }
    guard let error else {
      if let done = ledger.completeHead() { acknowledge(done) }
      pumpAfterAnswer = true
      return
    }
    switch error.code {
    case .resourceLimit, .staleGeometry, .staleRevision:
      // A record larger than the peer's chunk or empty-pane budget is
      // refused forever. Retrying it holds every later operation.
      if error.code == .resourceLimit, let limits = mux?.welcome?.limits,
        let head = ledger.admitted.first, head.sequence == sequence,
        Self.permanentlyExceeds(head.operation, limits: limits)
      {
        for done in ledger.discard(through: sequence) { acknowledge(done) }
        pumpAfterAnswer = true
        break
      }
      // Nothing was written; retry after the pane drains or the layout
      // settles, never in a tight loop.
      guard !closing else { break }
      retryScheduled = true
      queue.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in
        self?.retryScheduled = false
        self?.pumpInput()
      }
    case .connectionLost, .notAttached, .staleAttachment:
      // The lease ended; the head stays admitted for the next attachment,
      // which resumes pumping.
      break
    case .paneExited, .notFound:
      // The target pane is gone: everything admitted for it is retired,
      // never delivered to whichever pane is shown next.
      for done in ledger.discard(through: ledger.lastAdmitted) {
        acknowledge(done)
      }
    default:
      // A refusal of this one operation (e.g. malformed for the pane):
      // retire it and continue; the writer stays usable.
      for done in ledger.discard(through: sequence) { acknowledge(done) }
      pumpAfterAnswer = true
    }
  }

  private static func permanentlyExceeds(
    _ operation: InputOperation,
    limits: MuxLimits
  ) -> Bool {
    switch operation {
    case let .committedText(text):
      return MuxService.permanentlyExceedsText(
        utf8Count: text.utf8.count,
        limits: limits
      )
    case let .paste(text):
      let newlines = text.utf8.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
      return MuxService.permanentlyExceedsPaste(
        utf8Count: text.utf8.count,
        newlineCount: newlines,
        limits: limits
      )
    case .key: return MuxService.permanentlyExceedsKey(limits: limits)
    case .resize: return false
    }
  }

  private func acknowledge(_ sequence: UInt64) {
    guard let a = attachment, a.isCurrent else { return }
    a.send(.inputAck(epoch: a.epoch, sequence: sequence))
  }

  /// Without `keypadKeys`, keypad keys become the keys they type.
  static func muxKey(
    _ key: SemanticKey,
    keypadKeys: Bool = true
  ) -> (MuxKey, MuxKeyModifiers)? {
    var modifiers: MuxKeyModifiers = []
    if key.modifiers.contains(.shift) { modifiers.insert(.shift) }
    if key.modifiers.contains(.alt) { modifiers.insert(.alt) }
    if key.modifiers.contains(.control) { modifiers.insert(.control) }
    let name: MuxKey? =
      switch key.name {
      case let .character(scalar): .character(scalar.value)
      case .enter: .enter
      case .tab: .tab
      case .backspace: .backspace
      case .escape: .escape
      case .up: .up
      case .down: .down
      case .left: .left
      case .right: .right
      case .home: .home
      case .end: .end
      case .pageUp: .pageUp
      case .pageDown: .pageDown
      case .insert: .insert
      case .delete: .delete
      case let .function(n): .function(n)
      case let .keypad(k):
        if keypadKeys {
          MuxKeypadKey(rawValue: k.rawValue).map(MuxKey.keypad)
        } else {
          KeypadKey(rawValue: k.rawValue)?.mainKey.flatMap(Self.muxKey)
        }
      }
    return name.map { ($0, modifiers) }
  }

  private static func muxKey(_ key: Key) -> MuxKey? {
    switch key {
    case let .character(scalar): .character(scalar.value)
    case .enter: .enter
    case .up: .up
    case .down: .down
    case .left: .left
    case .right: .right
    case .home: .home
    case .end: .end
    case .pageUp: .pageUp
    case .pageDown: .pageDown
    case .insert: .insert
    case .delete: .delete
    default: nil
    }
  }

  // MARK: Snapshots (owner queue)

  private func stamp(epoch: UInt64) -> ScreenExporter.Stamp {
    ScreenExporter.Stamp(
      sessionID: id,
      attachmentEpoch: epoch,
      screenRevision: screenRevision,
      resizeRevision: resizeRevision,
      lastFullyAppliedInputSequence: ledger.lastApplied
    )
  }

  private func pumpSnapshots(_ a: HostAttachment) {
    guard a === attachment, a.isCurrent, let pane = activePane else { return }
    pruneSnapshotWork()
    let now = ContinuousClock.now
    switch a.scheduler.next(now: now) {
    case .idle: return
    case let .wait(until):
      guard !a.timerArmed else { return }
      a.timerArmed = true
      let delay = now.duration(to: until)
      queue.asyncAfter(deadline: .now() + delay.dispatchInterval) {
        [weak self, a] in
        a.timerArmed = false
        self?.pumpSnapshots(a)
      }
    case let .capture(cancel):
      if let cancel { a.connection.cancelSnapshot(stream: cancel) }
      screenRevision += 1
      let stamp = stamp(epoch: a.epoch)
      let historyTop = a.historyTop
      a.nextStreamID += 1
      let stream = a.nextStreamID
      a.scheduler.started(stream: stream, revision: stamp.screenRevision)
      pruneSnapshotWork()
      let exit = exitStatus
      // Exported in the pane's order, so every byte parsed before this
      // point (including final output after exit) is included.
      service.inspect(
        pane: pane,
        { ScreenExporter.export($0, stamp: stamp, historyTop: historyTop) },
        completion: { [weak self] snapshot in
          self?.queue
            .async { [weak self] in
              self?.captured(snapshot, stream: stream, exit: exit, to: a)
            }
        }
      )
    }
  }

  private func captured(
    _ snapshot: ScreenSnapshot?,
    stream: UInt64,
    exit: Int32?,
    to a: HostAttachment
  ) {
    guard wantsSnapshot(stream: stream, from: a) else { return }
    guard let snapshot else {
      a.scheduler.failed(stream: stream)
      return
    }
    if let exit, !a.exitNoticeSent {
      a.exitNoticeSent = true
      a.send(
        .sessionExited(
          epoch: a.epoch,
          status: exit,
          finalScreenRevision: snapshot.screenRevision
        )
      )
    }
    transmit(snapshot, stream: stream, to: a)
  }

  /// Retains only captures still owned by the bounded scheduler, rather than
  /// queueing one encoding closure for every superseded screen revision.
  private func transmit(
    _ snapshot: ScreenSnapshot,
    stream: UInt64,
    to a: HostAttachment
  ) {
    pruneSnapshotWork()
    pendingSnapshotEncodes.append(
      SnapshotEncoding(snapshot: snapshot, stream: stream, attachment: a)
    )
    startNextSnapshotEncoding()
  }

  private func wantsSnapshot(stream: UInt64, from a: HostAttachment) -> Bool {
    a === attachment && a.isCurrent
      && a.scheduler.streams.contains(where: { $0.id == stream })
  }

  private func pruneSnapshotWork() {
    pendingSnapshotEncodes.removeAll {
      !wantsSnapshot(stream: $0.stream, from: $0.attachment)
    }
    for send in snapshotSends.values
    where !wantsSnapshot(stream: send.stream, from: send.attachment) {
      send.task.cancel()
    }
  }

  private func startNextSnapshotEncoding() {
    pruneSnapshotWork()
    guard !encodingSnapshot, snapshotSends.count < 2,
      !pendingSnapshotEncodes.isEmpty
    else { return }
    let job = pendingSnapshotEncodes.removeFirst()
    encodingSnapshot = true
    let encode = snapshotEncoder
    encodeQueue.async { [weak self] in
      let result = Result { try encode(job.snapshot) }
      self?.queue
        .async { [weak self] in self?.snapshotEncoded(result, job: job) }
    }
  }

  private func snapshotEncoded(
    _ result: Result<[UInt8], any Error>,
    job: SnapshotEncoding
  ) {
    encodingSnapshot = false
    defer { startNextSnapshotEncoding() }
    let a = job.attachment
    let stream = job.stream
    guard wantsSnapshot(stream: stream, from: a) else { return }
    switch result {
    case .failure: snapshotFailed(stream: stream, to: a, retry: true)
    case let .success(payload):
      // A peer can acknowledge before the send's completion reaches this
      // queue. Publish the bound before starting transport work, but never
      // include captures still waiting for encoding or an available slot.
      a.highestSubmittedScreenRevision = max(
        a.highestSubmittedScreenRevision,
        job.snapshot.screenRevision
      )
      let id = UUID()
      let task = Task { [weak self] in
        let retry: Bool?
        do {
          guard !Task.isCancelled else { throw RSTTransportError.canceled }
          try await a.connection.sendSnapshot(payload, stream: stream)
          retry = nil
        } catch { retry = (error as? RSTTransportError) != .closed }
        self?.queue
          .async { [weak self] in
            guard let self else { return }
            self.snapshotSends.removeValue(forKey: id)
            if let retry {
              self.snapshotFailed(stream: stream, to: a, retry: retry)
            }
            self.startNextSnapshotEncoding()
          }
      }
      snapshotSends[id] = SnapshotSend(
        stream: stream,
        attachment: a,
        task: task
      )
    }
  }

  /// Encoding and transport failures settle on the attachment's owner queue.
  private func snapshotFailed(stream: UInt64, to a: HostAttachment, retry: Bool)
  {
    guard wantsSnapshot(stream: stream, from: a) else { return }
    a.scheduler.failed(stream: stream)
    if retry { pumpSnapshots(a) }
  }
}

extension Duration {
  var dispatchInterval: DispatchTimeInterval {
    guard self >= .zero else { return .nanoseconds(0) }
    let (seconds, attoseconds) = components
    let nanos = seconds.multipliedReportingOverflow(by: 1_000_000_000)
    let total = nanos.partialValue.addingReportingOverflow(
      attoseconds / 1_000_000_000
    )
    guard !nanos.overflow, !total.overflow,
      let value = Int(exactly: total.partialValue)
    else { return .never }
    return .nanoseconds(value)
  }
}
#endif
