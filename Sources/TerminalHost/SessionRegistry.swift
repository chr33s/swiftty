#if os(macOS)
import AppleTransport
import CryptoKit
import Dispatch
import Foundation
import ScreenProtocol
import SessionCore
import SwiftMuxProtocol
import SwiftMuxService
import Synchronization

/// The QUIC server certificate delivered through SSH (spec §5.2) and its
/// SPKI pin (spec.inbox.md §1.8).
public struct HostCertificate: Sendable, Hashable {
  public var der: Data
  /// Lowercase hex SHA-256 of `der`.
  public var sha256Hex: String
  /// Lowercase hex SHA-256 of the certificate's DER SubjectPublicKeyInfo
  /// (the QUIC pin). Nil only when `der` is not an X.509 certificate,
  /// which `init?(der:sha256Hex:)` — the production path — refuses.
  public var spkiSHA256Hex: String?

  public init(der: Data) {
    self.der = der
    sha256Hex = hexString(SHA256.hash(data: der))
    spkiSHA256Hex = try? CertificatePin.spkiFingerprint(der)
  }

  /// Fails unless `sha256Hex` is the lowercase fingerprint of `der` and
  /// `der` is a certificate whose SPKI pin can be computed.
  public init?(der: Data, sha256Hex: String) {
    let expected = hexString(SHA256.hash(data: der))
    guard expected == sha256Hex,
      let spki = try? CertificatePin.spkiFingerprint(der)
    else { return nil }
    self.der = der
    self.sha256Hex = sha256Hex
    spkiSHA256Hex = spki
  }
}

/// What every grant advertises: the approved endpoint and certificate.
public struct HostIdentity: Sendable, Hashable {
  public var endpoint: BootstrapEndpoint
  public var certificate: HostCertificate

  public init(endpoint: BootstrapEndpoint, certificate: HostCertificate) {
    self.endpoint = endpoint
    self.certificate = certificate
  }
}

/// Session limits and lifetimes (spec §4, §5.2, §12). Lifetimes govern
/// remote authorization only: a SwiftMux workspace outlives them unless
/// this host created it and it was never attached or its shell exited
/// (spec.inbox.md §1–2: "local shell lifetime is separate").
public struct RegistryPolicy: Sendable {
  public var maxSessions = RSTLimits.maxSessionsPerAccount
  public var reservationLifetime = RSTLimits.reservationLifetime
  public var detachedRetention = RSTLimits.detachedRetention
  public var exitedRetention = RSTLimits.exitedRetention
  /// Must be positive to issue create/resume grants. Nonpositive values
  /// fail with `internalError`; positive values are clamped to the wire limit.
  public var tokenLifetime = RSTLimits.maxTokenLifetime
  /// Failed attachment attempts allowed per window before every attempt
  /// is refused until the window passes.
  public var attachFailureLimit = 16
  public var attachFailureWindow: Duration = .seconds(10)
  public var sweepInterval: Duration = .seconds(1)

  public init() {}
}

/// Remote authorization for SwiftMux workspaces: bootstrap grants,
/// capabilities, attachment authorization and retention. It owns no
/// shells; RST/1 session identifiers are workspace identities and the
/// grant's server instance is the SwiftMux service epoch.
///
/// Sendable: entries, credentials and counters live in the `state` Mutex,
/// the sweep timer in `timer`, and the identity in `identityBox`; the
/// `control` client is used only on its own queue and closed there in
/// `deinit`. No unsafe storage.
public final class SessionRegistry: @unchecked Sendable {
  /// Includes transport-closed requests until their owner work finishes.
  private static let maxPendingAttachments = 32

  private struct Credential {
    var token: ApplicationToken
    var writer: WriterID
    var expiresAt: ContinuousClock.Instant
    var takeover: Bool
    var target: ResumeTarget?
  }

  private struct Entry {
    var session: RoamingSession
    var credential: Credential?
    var createdAt: ContinuousClock.Instant
    /// Created by a bootstrap `create`, so an abandoned reservation or
    /// exited shell may be ended here. Workspaces from elsewhere are not.
    var createdHere: Bool
  }

  private struct State {
    var entries: [SessionID: Entry] = [:]
    var failures: [ContinuousClock.Instant] = []
    var pendingAttachments = 0
    /// Creates own a quota slot before asking the service to allocate.
    var pendingCreates = 0
    /// Keep admission closed until every queued workspace-end command replies.
    var ending: [SessionID: Int] = [:]
    var workspaceEndGeneration: UInt64 = 0

    mutating func beginEnding(_ id: SessionID) {
      workspaceEndGeneration += 1
      ending[id, default: 0] += 1
    }

    mutating func finishEnding(_ id: SessionID) {
      guard let count = ending[id] else { return }
      if count > 1 {
        ending[id] = count - 1
      } else {
        ending.removeValue(forKey: id)
      }
    }
    /// Revision floors of removed entries whose workspace may be resumed
    /// again (bounded, oldest dropped first).
    var floors: [SessionID: RoamingSession.Floor] = [:]
    var floorOrder: [SessionID] = []

    mutating func retire(_ id: SessionID, _ floor: RoamingSession.Floor) {
      if floors.updateValue(floor, forKey: id) == nil { floorOrder.append(id) }
      while floorOrder.count > 1024 {
        floors.removeValue(forKey: floorOrder.removeFirst())
      }
    }
  }

  /// The SwiftMux service epoch.
  public let serverInstanceID: SessionCore.ServerInstanceID
  /// The endpoint and certificate every new grant advertises; replaced
  /// when the QUIC certificate is renewed.
  public var identity: HostIdentity { identityBox.withLock { $0 } }
  private let identityBox: Mutex<HostIdentity>
  public let policy: RegistryPolicy
  public let service: MuxService
  private let makeLaunch: @Sendable () -> LaunchSpec
  private let control: MuxLocalSession
  private let state = Mutex(State())
  private struct SweepTimerState {
    var source: DispatchSourceTimer?
    var generation = UUID()
    var inFlight = false
  }
  private let timer = Mutex(SweepTimerState())

  public convenience init(
    service: MuxService,
    identity: HostIdentity,
    policy: RegistryPolicy = RegistryPolicy(),
    launch: @escaping @Sendable () -> LaunchSpec = { LaunchSpec() }
  ) {
    self.init(
      service: service,
      identity: identity,
      policy: policy,
      launch: launch,
      control: MuxLocalSession(
        queue: DispatchQueue(label: "swiftmux.roaming.registry")
      )
    )
  }

  /// The same control frontend, supplied explicitly for connection-lifetime tests.
  init(
    service: MuxService,
    identity: HostIdentity,
    policy: RegistryPolicy = RegistryPolicy(),
    launch: @escaping @Sendable () -> LaunchSpec = { LaunchSpec() },
    control: MuxLocalSession
  ) {
    self.service = service
    serverInstanceID = SessionCore.ServerInstanceID(service.instance)
    identityBox = Mutex(identity)
    var policy = policy
    policy.tokenLifetime = min(policy.tokenLifetime, RSTLimits.maxTokenLifetime)
    self.policy = policy
    makeLaunch = launch
    self.control = control
    control.queue.sync {
      control.connect(to: service, frontend: .control, remote: true)
    }
  }

  deinit {
    timer.withLock { $0.source?.cancel() }
    let control = control
    control.queue.async { control.close() }
  }

  // MARK: Bootstrap operations

  /// Starts a new workspace (one pane, kept after exit so the final
  /// screen survives) and grants its first capability.
  public func create(
    grid: GridSize
  ) async throws(BootstrapErrorCode) -> BootstrapGrant {
    guard grid.isValid else { throw .malformed }
    guard policy.tokenLifetime > .zero else { throw .internalError }
    let reserved = state.withLock { s -> Bool in
      guard s.entries.count + s.pendingCreates < policy.maxSessions else {
        return false
      }
      s.pendingCreates += 1
      return true
    }
    guard reserved else { throw .sessionLimit }
    var reservationHeld = true
    defer { if reservationHeld { state.withLock { $0.pendingCreates -= 1 } } }
    let result = await control.request(
      .newWorkspace(
        NewWorkspaceRequest(
          columns: grid.columns,
          rows: grid.rows,
          launch: makeLaunch(),
          remainOnExit: true
        )
      )
    )
    guard case let .success(.created(ws)) = result else {
      if case let .failure(error) = result, error.code == .resourceLimit {
        throw .sessionLimit
      }
      throw .internalError
    }
    let id = SessionID(ws.id)
    let session = makeSession(id, grid: grid)
    let writerID = WriterID.random()
    let now = ContinuousClock.now
    let credential = issue(writer: writerID, takeover: false, now: now)
    let authorized: Bool
    do {
      authorized = try session.authorize(
        writer: writerID,
        token: credential.token
      )
    } catch { throw .internalError }
    guard authorized else { throw .internalError }
    let admitted = state.withLock { s -> Bool in
      // A concurrent resume may have authorized the service workspace
      // before this create's reply reached us. Preserve that owner and grant.
      guard s.entries[id] == nil else {
        s.entries[id]?.createdHere = true
        return false
      }
      s.entries[id] = Entry(
        session: session,
        credential: credential,
        createdAt: now,
        createdHere: true
      )
      // Transfer the reservation to its entry on one state turn.
      s.pendingCreates -= 1
      return true
    }
    guard admitted else { throw .internalError }
    reservationHeld = false
    return grant(id, credential: credential, grid: grid)
  }

  /// Issues fresh credentials for a workspace and revokes the previous
  /// capability. Any workspace of the service can be resumed, including
  /// one created by the Mac app. The writer is kept only when `writerID`
  /// names the current writer; a different writer cannot take over while
  /// admitted input is incomplete.
  public func resume(
    _ id: SessionID,
    writerID: WriterID? = nil,
    takeover: Bool = false,
    target: ResumeTarget? = nil,
    grid: GridSize? = nil
  ) async throws(BootstrapErrorCode) -> BootstrapGrant {
    guard policy.tokenLifetime > .zero else { throw .internalError }
    let retained = try state.withLock {
      s throws(BootstrapErrorCode) -> RoamingSession? in
      guard s.ending[id] == nil else { throw .unknownSession }
      return s.entries[id]?.session
    }
    let retainedCredential: Credential?
    if let retained {
      retainedCredential = try authorizeResume(
        id,
        session: retained,
        writerID: writerID,
        takeover: takeover,
        target: target
      )
    } else {
      retainedCredential = nil
    }
    // Retained authorization does not prove the workspace still exists:
    // a detached owner receives no service layout/lease notifications.
    var session: RoamingSession?
    while session == nil {
      let listedGeneration = try state.withLock {
        s throws(BootstrapErrorCode) -> UInt64 in
        guard s.ending[id] == nil else { throw .unknownSession }
        return s.workspaceEndGeneration
      }
      guard let workspaces = await listWorkspaces() else {
        throw .internalError
      }
      let exists = workspaces.contains { $0.id == id.workspace }
      var listInvalidated = false
      session = try state.withLock {
        s throws(BootstrapErrorCode) -> RoamingSession? in
        // The workspace list may precede a concurrent termination.
        guard s.ending[id] == nil else { throw .unknownSession }
        // Even a completed end invalidates a list captured before it.
        // Refresh instead of installing credentials from that snapshot.
        guard s.workspaceEndGeneration == listedGeneration else {
          listInvalidated = true
          return nil
        }
        guard exists else {
          if let entry = s.entries[id] {
            if let retired = entry.session.retire(when: { _ in true }) {
              s.retire(id, retired.floor)
            }
            s.entries.removeValue(forKey: id)
          }
          throw .unknownSession
        }
        if let existing = s.entries[id] { return existing.session }
        guard s.entries.count + s.pendingCreates < policy.maxSessions else {
          return nil
        }
        // Select the floor and construct only the entry being installed.
        // Another resume/retirement cannot advance it between these steps.
        let candidate = makeSession(
          id,
          grid: grid ?? GridSize(columns: 80, rows: 24),
          floor: s.floors[id] ?? RoamingSession.Floor()
        )
        s.entries[id] = Entry(
          session: candidate,
          credential: nil,
          createdAt: .now,
          createdHere: false
        )
        return candidate
      }
      if listInvalidated { continue }
      guard session != nil else { throw .sessionLimit }
    }
    guard let session else { throw .unknownSession }
    let credential: Credential
    if session === retained, let retainedCredential {
      credential = try finalizeResumeCredential(
        id,
        session: session,
        credential: retainedCredential
      )
    } else {
      credential = try authorizeResume(
        id,
        session: session,
        writerID: writerID,
        takeover: takeover,
        target: target
      )
    }
    let status = session.status
    return grant(
      id,
      credential: credential,
      grid: GridSize(
        columns: min(max(status.columns, 1), RSTLimits.maxColumns),
        rows: min(max(status.rows, 1), RSTLimits.maxRows)
      )
    )
  }

  /// The retained token is rotated before verification but not disclosed
  /// until now. Start its advertised lifetime after that service wait.
  private func finalizeResumeCredential(
    _ id: SessionID,
    session: RoamingSession,
    credential: Credential
  ) throws(BootstrapErrorCode) -> Credential {
    try state.withLock { s throws(BootstrapErrorCode) -> Credential in
      guard s.ending[id] == nil, s.entries[id]?.session === session,
        session.status.state != .terminated
      else { throw .unknownSession }
      let now = ContinuousClock.now
      guard s.entries[id]?.credential?.token == credential.token else {
        // A concurrent resume may already have superseded this grant.
        // Never revive an expired token or overwrite its newer credential.
        guard credential.expiresAt > now else { throw .internalError }
        return credential
      }
      var refreshed = credential
      refreshed.expiresAt = now + policy.tokenLifetime
      guard refreshed.expiresAt > now else { throw .internalError }
      s.entries[id]?.credential?.expiresAt = refreshed.expiresAt
      return refreshed
    }
  }

  /// Keep credential rotation and owner authorization atomic before any
  /// service wait, so an old pending lease cannot commit during verification.
  private func authorizeResume(
    _ id: SessionID,
    session: RoamingSession,
    writerID: WriterID?,
    takeover: Bool,
    target: ResumeTarget?
  ) throws(BootstrapErrorCode) -> Credential {
    return try state.withLock { s throws(BootstrapErrorCode) -> Credential in
      // Writer authorization and token publication belong to the same
      // entry and operation. A captured session may have been retired or
      // replaced before this turn.
      guard s.ending[id] == nil, s.entries[id]?.session === session else {
        throw .unknownSession
      }
      let writer: WriterID
      if let requested = writerID, requested == session.writerID {
        writer = requested
      } else {
        writer = WriterID.random()
      }
      var credential = issue(writer: writer, takeover: takeover, now: .now)
      credential.target = target
      let authorized: Bool
      do {
        authorized = try session.authorize(
          writer: writer,
          token: credential.token
        )
      } catch { throw .writerBusy }
      guard authorized else { throw .unknownSession }
      s.entries[id]?.credential = credential
      return credential
    }
  }

  /// The service's workspaces, most recently active first (bounded by
  /// the wire limit). A failed control query is never an empty success.
  public func list() async throws(BootstrapErrorCode) -> [SessionSummary] {
    let summaries = try await workspaces()
    let entries = state.withLock { $0.entries }
    let list = summaries.map { ws -> SessionSummary in
      let id = SessionID(ws.id)
      guard let status = entries[id]?.session.status else {
        return SessionSummary(
          sessionID: id,
          state: ws.isAttached ? .attached : .detached,
          columns: 80,
          rows: 24,
          lastActivity: ws.createdAt.timeIntervalSince1970
        )
      }
      let state: SessionSummary.State =
        switch status.state {
        case .reserved: .reserved
        case .attached: .attached
        case .detached: ws.isAttached ? .attached : .detached
        case .exited, .terminated: .exited
        }
      return SessionSummary(
        sessionID: id,
        state: state,
        columns: min(max(status.columns, 1), RSTLimits.maxColumns),
        rows: min(max(status.rows, 1), RSTLimits.maxRows),
        lastActivity: status.lastActivityWall,
        exitStatus: status.exitStatus
      )
    }
    return Array(
      list.sorted { $0.lastActivity > $1.lastActivity }
        .prefix(RSTLimits.maxSessionsPerAccount)
    )
  }

  /// Revokes credentials and ends the workspace (an explicit user
  /// request). Returns false when it does not exist.
  @discardableResult
  public func terminate(_ id: SessionID) async -> Bool {
    let entry = state.withLock { s -> Entry? in
      s.beginEnding(id)
      let entry = s.entries[id]
      if let retired = entry?.session.retire(when: { _ in true }) {
        s.retire(id, retired.floor)
      }
      s.entries.removeValue(forKey: id)
      return entry
    }
    defer { state.withLock { $0.finishEnding(id) } }
    let result = await control.request(.endWorkspace(.id(id.workspace)))
    if case .success = result { return true }
    return entry != nil
  }

  /// Answers one validated bootstrap request (spec §5.1).
  public func handle(_ request: BootstrapRequest) async -> BootstrapResponse {
    do { try request.validate() } catch {
      switch error {
      case .unsupportedProtocol, .tooManyProtocols:
        return .failure(.unsupportedVersion)
      case .missingSession, .invalidGrid, .missingAttention:
        return .failure(.malformed)
      }
    }
    do throws(BootstrapErrorCode) {
      switch request.operation {
      case .create:
        guard let grid = request.initialGrid else { throw .malformed }
        return .granted(try await create(grid: grid))
      case .resume:
        guard let id = request.sessionID else { throw .malformed }
        return .granted(
          try await resume(
            id,
            writerID: request.writerID,
            takeover: request.takeover ?? false,
            target: request.target,
            grid: request.initialGrid
          )
        )
      case .list: return .sessions(try await list())
      case .terminate:
        guard let id = request.sessionID else { throw .malformed }
        guard await terminate(id) else { throw .unknownSession }
        return .terminated(id)
      case .attention:
        guard let attention = request.attention else { throw .malformed }
        return .metadata(try await metadata(attention))
      }
    } catch { return .failure(error) }
  }

  /// Answers lease-free metadata through the control client, which never
  /// holds a lease, so `leaseHeldElsewhere` reports any holder.
  public func metadata(
    _ request: AttentionRequest
  ) async throws(BootstrapErrorCode) -> HostMetadata {
    var metadata = HostMetadata(serviceEpoch: service.instance)
    switch request {
    case .workspaces: metadata.workspaces = try await workspaces()
    case let .inbox(query): metadata.inbox = try await inboxPage(query)
    case let .locate(reference):
      guard
        case let .success(.attention(location)) = await control.request(
          .locateAttention(reference)
        )
      else { throw .internalError }
      metadata.location = location
    case let .markSeen(reference): try await acknowledge(.markSeen(reference))
    case let .snooze(reference, until):
      try await acknowledge(.snooze(reference, until: until))
    case let .markReviewed(reference):
      try await acknowledge(.markReviewed(reference))
    }
    return metadata
  }

  private func acknowledge(
    _ command: MuxCommand
  ) async throws(BootstrapErrorCode) {
    switch await control.request(command) {
    case .success: return
    case let .failure(error) where error.code == .notFound:
      throw .unknownSession
    case let .failure(error) where error.code == .invalidRequest:
      throw .malformed
    case .failure: throw .internalError
    }
  }

  /// One inbox page that fits the bootstrap envelope: the row limit is
  /// halved until the encoded response fits, so the cursor stays exact.
  private func inboxPage(
    _ query: InboxQuery
  ) async throws(BootstrapErrorCode) -> InboxPage {
    var query = query
    query.limit = min(max(query.limit, 1), 100)
    while true {
      guard
        case let .success(.inbox(page)) = await control.request(.inbox(query))
      else { throw .internalError }
      let response = BootstrapResponse.metadata(
        HostMetadata(serviceEpoch: service.instance, inbox: page)
      )
      if (try? BootstrapEnvelope.encode(response)) != nil { return page }
      guard query.limit > 1 else { throw .internalError }
      query.limit /= 2
    }
  }

  /// Create operations holding quota before publishing their entry.
  var pendingCreationCount: Int { state.withLock { $0.pendingCreates } }

  /// Control requests still awaiting a service reply.
  var pendingControlRequestCount: Int {
    control.queue.sync { control.pendingRequestCount }
  }

  /// Attachment operations still awaiting their owner result.
  var pendingAttachmentCount: Int { state.withLock { $0.pendingAttachments } }

  /// The roaming session for `id`, if retained (diagnostics and tests).
  public func session(_ id: SessionID) -> RoamingSession? {
    state.withLock { $0.entries[id]?.session }
  }

  private func makeSession(
    _ id: SessionID,
    grid: GridSize,
    floor: RoamingSession.Floor = RoamingSession.Floor()
  ) -> RoamingSession {
    let session = RoamingSession(
      id: id,
      service: service,
      grid: grid,
      floor: floor
    )
    session.onTerminateRequested = { [weak self] id in
      guard let self else { return }
      Task { _ = await self.terminate(id) }
    }
    return session
  }

  /// The service's workspaces; failure says nothing about their existence.
  package func workspaces() async throws(BootstrapErrorCode)
    -> [WorkspaceSummary]
  {
    guard let list = await listWorkspaces() else { throw .internalError }
    return list
  }

  /// Nil when the service did not answer.
  private func listWorkspaces() async -> [WorkspaceSummary]? {
    guard
      case let .success(.workspaces(list)) = await control.request(
        .listWorkspaces
      )
    else { return nil }
    return list
  }

  // MARK: Attachments

  /// Serves one authenticated RST/1 connection. Pass every connection the
  /// listener accepts.
  public func accept(_ connection: any RSTConnection) {
    HostAttachment(connection: connection, registry: self).start()
  }

  /// Validates an `Attach` (rate limit, instance, session, constant-time
  /// token comparison, expiry, writer) and attaches on success. At most
  /// 32 unfinished attachments are admitted across this registry; closed
  /// transports retain their slot until the owner operation replies.
  func attach(
    _ request: ControlMessage.Attach,
    attachment: HostAttachment
  ) async -> AttachOutcome<RoamingSession> {
    let now = ContinuousClock.now
    let checked = state.withLock {
      s -> AttachOutcome<(RoamingSession, Credential)> in
      s.failures.removeAll { $0 + policy.attachFailureWindow <= now }
      guard s.failures.count < policy.attachFailureLimit else {
        return .failure(.limitExceeded)
      }
      let result = Self.authorize(
        request,
        entries: s.entries,
        instance: serverInstanceID,
        now: now
      )
      if case .failure = result { s.failures.append(now) }
      if case .success = result {
        guard s.pendingAttachments < Self.maxPendingAttachments else {
          return .failure(.limitExceeded)
        }
        s.pendingAttachments += 1
      }
      return result
    }
    guard case let .success((session, credential)) = checked else {
      if case let .failure(code) = checked { return .failure(code) }
      return .failure(.internalError)
    }
    defer { state.withLock { $0.pendingAttachments -= 1 } }
    switch await session.attach(
      attachment,
      writer: request.writerID,
      token: credential.token,
      expiresAt: credential.expiresAt,
      takeover: credential.takeover,
      target: credential.target
    ) {
    case .success:
      // Takeover and focus apply to the confirmed attachment only; a
      // later reconnect with the same token neither displaces a newer
      // holder nor moves focus back.
      state.withLock { s in
        guard
          s.entries[request.sessionID]?.credential?.token == credential.token
        else { return }
        s.entries[request.sessionID]?.credential?.takeover = false
        s.entries[request.sessionID]?.credential?.target = nil
      }
      return .success(session)
    case let .failure(code):
      state.withLock { $0.failures.append(now) }
      return .failure(code)
    }
  }

  private static func authorize(
    _ request: ControlMessage.Attach,
    entries: [SessionID: Entry],
    instance: SessionCore.ServerInstanceID,
    now: ContinuousClock.Instant
  ) -> AttachOutcome<(RoamingSession, Credential)> {
    guard request.serverInstanceID == instance else {
      return .failure(.wrongInstance)
    }
    guard let entry = entries[request.sessionID] else {
      return .failure(.unknownSession)
    }
    guard let credential = entry.credential,
      credential.token.matches(request.applicationToken)
    else { return .failure(.unauthorized) }
    guard now < credential.expiresAt else { return .failure(.expired) }
    guard credential.writer == request.writerID else {
      return .failure(.unauthorized)
    }
    return .success((entry.session, credential))
  }

  // MARK: Retention

  /// Expires remote authorization. Ends only workspaces this host
  /// created that were never attached, or whose shell exited; every
  /// other workspace keeps running and only loses its remote grant.
  @discardableResult
  public func sweep(now: ContinuousClock.Instant = .now) async -> [SessionID] {
    // A detached session sees no layout events, so a shell that exits
    // while no remote client is attached is learned from the service.
    // Entries created after the list was requested may not be in it, and
    // a failed list says nothing: neither is ever taken as "ended".
    let listedAt = ContinuousClock.now
    let listed = await listWorkspaces()
    let workspaces = Dictionary(
      (listed ?? []).map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let (removed, end) = state.withLock {
      s -> ([SessionID], [(id: SessionID, onlyIfExited: Bool)]) in
      var removed: [SessionID] = []
      var end: [(id: SessionID, onlyIfExited: Bool)] = []
      for (id, entry) in s.entries {
        let summary = workspaces[id.workspace]
        let gone = listed != nil && summary == nil && entry.createdAt < listedAt
        let retired = entry.session.retire { status in
          // Check and close admission together on the owner queue. A lease
          // confirmed before this turn keeps its entry; a later one fails.
          if status.isAttached, status.state != .terminated { return false }
          if gone { return true }
          let allExited =
            summary.map { $0.paneCount > 0 && $0.livePaneCount == 0 }
            ?? status.allPanesExited
          switch status.state {
          case .reserved:
            return now - entry.createdAt >= policy.reservationLifetime
          case .detached where allExited:
            return now - status.lastActivity >= policy.exitedRetention
          case .detached:
            return now - status.lastActivity >= policy.detachedRetention
          case .exited:
            return now - (status.exitedAt ?? status.lastActivity)
              >= policy.exitedRetention
          case .terminated: return true
          case .attached: return false
          }
        }
        guard let retired else { continue }
        let status = retired.status
        let allExited =
          summary.map { $0.paneCount > 0 && $0.livePaneCount == 0 }
          ?? status.allPanesExited
        s.entries.removeValue(forKey: id)
        s.retire(id, retired.floor)
        removed.append(id)
        // Only host-created unused reservations or wholly exited
        // workspaces may be ended. The service rechecks cleanup eligibility.
        if entry.createdHere, !gone, status.state == .reserved || allExited {
          s.beginEnding(id)
          end.append((id, status.state != .reserved))
        }
      }
      return (removed, end)
    }
    for pending in end {
      if pending.onlyIfExited {
        // A native frontend may add a live pane after the list replied.
        // Check again in service order, atomically with ending the workspace.
        _ = await withCheckedContinuation { continuation in
          service.endExitedWorkspace(pending.id.workspace) { ended in
            continuation.resume(returning: ended)
          }
        }
      } else {
        // Local use outlives its lease. Expire remote authorization while
        // preserving any workspace a native frontend has already used.
        _ = await withCheckedContinuation { continuation in
          service.endReservedWorkspace(pending.id.workspace) { ended in
            continuation.resume(returning: ended)
          }
        }
      }
      state.withLock { $0.finishEnding(pending.id) }
    }
    return removed
  }

  /// Sweeps periodically until stopped or released. Only one periodic
  /// sweep may await the service, including across timer replacement.
  public func startSweeping() {
    let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    let generation = UUID()
    let interval = max(policy.sweepInterval, .milliseconds(1)).dispatchInterval
    source.schedule(deadline: .now() + interval, repeating: interval)
    source.setEventHandler { [weak self] in
      guard let self else { return }
      let admitted = timer.withLock { state -> Bool in
        guard state.generation == generation, !state.inFlight else {
          return false
        }
        state.inFlight = true
        return true
      }
      guard admitted else { return }
      Task {
        await self.sweep()
        self.timer.withLock { $0.inFlight = false }
      }
    }
    timer.withLock { state in
      state.source?.cancel()
      state.generation = generation
      state.source = source
      source.resume()
    }
  }

  /// Stops future periodic sweeps. An admitted sweep finishes before any
  /// new timer may start another one.
  public func stopSweeping() {
    timer.withLock { state in
      state.source?.cancel()
      state.source = nil
      state.generation = UUID()
    }
  }

  // MARK: Helpers

  private func issue(
    writer: WriterID,
    takeover: Bool,
    now: ContinuousClock.Instant
  ) -> Credential {
    Credential(
      token: .random(),
      writer: writer,
      expiresAt: now + policy.tokenLifetime,
      takeover: takeover
    )
  }

  /// Advertises a renewed certificate (and endpoint) in later grants.
  /// Grants already issued keep their pin; their clients fetch a fresh
  /// grant when the old pin stops matching.
  public func replaceIdentity(_ identity: HostIdentity) {
    identityBox.withLock { $0 = identity }
  }

  private func grant(
    _ id: SessionID,
    credential: Credential,
    grid: GridSize
  ) -> BootstrapGrant {
    let identity = identity
    let remaining = ContinuousClock.now.duration(to: credential.expiresAt)
    let seconds =
      Double(remaining.components.seconds) + Double(
        remaining.components.attoseconds
      ) / 1e18
    return BootstrapGrant(
      serverInstanceID: serverInstanceID,
      sessionID: id,
      writerID: credential.writer,
      endpoint: identity.endpoint,
      serverCertificateDER: identity.certificate.der,
      serverCertificateSHA256: identity.certificate.sha256Hex,
      serverSPKISHA256: identity.certificate.spkiSHA256Hex,
      applicationToken: credential.token,
      tokenExpiresAt: Date().timeIntervalSince1970 + max(0, seconds),
      initialGrid: grid
    )
  }
}
#endif
