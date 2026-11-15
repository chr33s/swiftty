import Foundation
import ScreenProtocol
import SessionCore

/// Time sources for the client, injectable so tests can run fast.
public struct SurfaceTiming: Sendable {
  /// Monotonic time for liveness, heartbeats and deadlines.
  public var now: @Sendable () -> ContinuousClock.Instant
  /// Wall-clock seconds since 1970, for `tokenExpiresAt` and status.
  public var wallClock: @Sendable () -> Double
  /// Suspends for a duration measured on `now`'s clock; throws when the
  /// task is canceled.
  public var sleep: @Sendable (Duration) async throws -> Void

  public init(
    now: @escaping @Sendable () -> ContinuousClock.Instant,
    wallClock: @escaping @Sendable () -> Double,
    sleep: @escaping @Sendable (Duration) async throws -> Void
  ) {
    self.now = now
    self.wallClock = wallClock
    self.sleep = sleep
  }

  public static let system = SurfaceTiming(
    now: { ContinuousClock.now },
    wallClock: { Date().timeIntervalSince1970 },
    sleep: { try await Task.sleep(for: $0) }
  )
}

public struct RoamingClientConfiguration: Sendable {
  /// Grid requested when creating a session.
  public var initialGrid: GridSize
  /// Bound on waiting for `Detached`/`Terminated` when closing or
  /// entering the background (spec §9).
  public var detachDeadline: Duration
  /// Bound on connect + `Attached` + first current snapshot.
  public var attachTimeout: Duration
  /// Idle heartbeat interval (spec §9: 20 s).
  public var heartbeatInterval: Duration
  /// How often liveness is evaluated.
  public var livenessTick: Duration
  /// Renew credentials through SSH this long before `tokenExpiresAt`.
  public var tokenRefreshMargin: Duration
  /// Reconnect delay jitter (fraction of each `ReconnectBackoff` step).
  public var backoffJitter: Double
  /// Bound on queued outbound control records before the connection is
  /// treated as failed.
  public var maxOutboundRecords: Int

  /// `detachDeadline` unless configured otherwise.
  public static let defaultDetachDeadline: Duration = .seconds(2)

  public init(
    initialGrid: GridSize = GridSize(columns: 80, rows: 24),
    detachDeadline: Duration = defaultDetachDeadline,
    attachTimeout: Duration = .seconds(15),
    heartbeatInterval: Duration = RSTLimits.heartbeatInterval,
    livenessTick: Duration = .milliseconds(250),
    tokenRefreshMargin: Duration = .seconds(60),
    backoffJitter: Double = 0.2,
    maxOutboundRecords: Int = 512
  ) {
    self.initialGrid = initialGrid
    self.detachDeadline = detachDeadline
    self.attachTimeout = attachTimeout
    self.heartbeatInterval = heartbeatInterval
    self.livenessTick = livenessTick
    self.tokenRefreshMargin = tokenRefreshMargin
    self.backoffJitter = backoffJitter
    self.maxOutboundRecords = maxOutboundRecords
  }
}

/// Which session `RoamingClient.start(_:)` attaches to.
public enum RoamingTarget: Hashable, Sendable {
  /// A new session with this grid.
  case create(GridSize)
  /// A retained session after a cold launch (fresh writer identity).
  case resume(SessionID)
  /// A workspace opened from an attention link: focus `target.pane`
  /// and, when `target.expectedLease` is set, take over exactly that
  /// lease (the one the user confirmed).
  case reveal(SessionID, ResumeTarget)
}

/// Nonsecret reason for the latest failure, for display.
public enum RoamingFailure: Hashable, Sendable {
  case unreachable
  /// SSH authorized the attachment, but the grant's QUIC endpoint could
  /// not be reached. Says nothing about why (firewall, route, policy).
  case endpointUnreachable
  case hostKeyRejected
  case authenticationFailed
  /// The client key could not be read; no credential was offered.
  case credentialUnavailable
  case protocolViolation
  case attachRejected(RSTErrorCode)
  case bootstrapRejected(BootstrapErrorCode)
  case attachTimedOut
  case connectionLost
  case stale
  case snapshotRejected
  /// The session's resize revision cannot advance; its current grid remains usable.
  case resizeUnavailable
  /// Retained operations were abandoned because the host issued a new
  /// writer identity; they are not replayed.
  case pendingInputAbandoned(count: Int)
}

/// Observable client status for the UI and the watch companion bridge.
/// Contains no tokens, certificates or terminal input; the only endpoint
/// is the grant's nonsecret roaming host and port, for diagnostics.
public struct RoamingStatus: Hashable, Sendable {
  public var state: ClientConnectionState
  public var sessionID: SessionID?
  /// Wall-clock time the newest complete screen was installed.
  public var lastScreenAt: Date?
  public var screenRevision: UInt64?
  /// Submitted operations not yet acknowledged by the host PTY.
  public var pendingInputCount: Int
  /// Input refused because the client was not active (cumulative).
  public var refusedInputCount: Int
  public var title: String
  public var exitStatus: Int32?
  public var lastFailure: RoamingFailure?
  /// The transport's own reason for `lastFailure` when the roaming
  /// endpoint could not be reached (for example "No route to host" or a
  /// certificate mismatch). One bounded line, for diagnostics; it never
  /// carries tokens or certificates.
  public var lastFailureDetail: String?
  /// Consecutive reconnect attempts since the last success.
  public var reconnectAttempt: Int
  /// The QUIC endpoint the current grant names, once SSH has authorized
  /// one. Display only; never replaced by the SSH or discovered host.
  public var roamingEndpoint: BootstrapEndpoint?

  public init(
    state: ClientConnectionState = .idle,
    sessionID: SessionID? = nil,
    lastScreenAt: Date? = nil,
    screenRevision: UInt64? = nil,
    pendingInputCount: Int = 0,
    refusedInputCount: Int = 0,
    title: String = "",
    exitStatus: Int32? = nil,
    lastFailure: RoamingFailure? = nil,
    lastFailureDetail: String? = nil,
    reconnectAttempt: Int = 0,
    roamingEndpoint: BootstrapEndpoint? = nil
  ) {
    self.state = state
    self.sessionID = sessionID
    self.lastScreenAt = lastScreenAt
    self.screenRevision = screenRevision
    self.pendingInputCount = pendingInputCount
    self.refusedInputCount = refusedInputCount
    self.title = title
    self.exitStatus = exitStatus
    self.lastFailure = lastFailure
    self.lastFailureDetail = lastFailureDetail
    self.reconnectAttempt = reconnectAttempt
    self.roamingEndpoint = roamingEndpoint
  }
}

public enum RoamingClientError: Error, Hashable, Sendable {
  /// The caller cancelled, or the client closed/backgrounded during bootstrap.
  case cancelled
  /// `start` was called in a state that does not allow it.
  case invalidState(ClientConnectionState)
  case unreachable
  case hostKeyRejected
  case authenticationFailed
  /// The client key could not be read; no credential was offered.
  case credentialUnavailable
  case protocolViolation
  case rejected(BootstrapErrorCode)
  /// The requested session no longer exists.
  case sessionLost
  case sessionExited
}

/// How `RoamingClient.close(_:)` ends the attachment.
public enum RoamingCloseMode: Hashable, Sendable {
  /// Keep the host shell for a later resume.
  case detach
  /// Destroy the host session.
  case terminate
}
