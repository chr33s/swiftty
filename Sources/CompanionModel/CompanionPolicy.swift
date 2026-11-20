import Foundation

/// How current cached companion data is, relative to the watch's clock.
///
/// There is deliberately no "live" value: status is always "as observed
/// by the iPhone at `capturedAt`", and the UI shows that time.
public enum CompanionFreshness: String, Hashable, Sendable {
  /// Observed recently. Still displayed with its capture time.
  case fresh
  /// Older than the fresh window, or timestamped in the future.
  case stale
  /// Nothing cached, or too old to describe the session at all.
  case unavailable
}

public struct CompanionStaleness: Hashable, Sendable {
  /// Age up to which data counts as `fresh`.
  public var freshFor: TimeInterval
  /// Age beyond which data counts as `unavailable`.
  public var unavailableAfter: TimeInterval
  /// Tolerated clock skew for timestamps slightly in the future.
  public var futureSkew: TimeInterval

  public init(
    freshFor: TimeInterval = 60,
    unavailableAfter: TimeInterval = 30 * 60,
    futureSkew: TimeInterval = 5
  ) {
    self.freshFor = freshFor
    self.unavailableAfter = max(unavailableAfter, freshFor)
    self.futureSkew = futureSkew
  }

  public static let standard = CompanionStaleness()

  /// A timestamp further in the future than `futureSkew` cannot be
  /// trusted, so it is `stale` rather than `fresh`.
  public func evaluate(capturedAt: Date?, now: Date) -> CompanionFreshness {
    guard let capturedAt else { return .unavailable }
    let age = now.timeIntervalSince(capturedAt)
    if age < -futureSkew { return .stale }
    if age > unavailableAfter { return .unavailable }
    if age > freshFor { return .stale }
    return .fresh
  }

  public func evaluate(
    _ status: CompanionStatus?,
    now: Date
  ) -> CompanionFreshness { evaluate(capturedAt: status?.capturedAt, now: now) }
}

/// Permits at most one pending companion refresh (spec §2.3).
///
/// A request that never receives a reply is abandoned after `timeout`, so
/// an unreachable phone cannot wedge the gate permanently.
public struct RefreshGate: Hashable, Sendable {
  public struct Pending: Hashable, Sendable {
    public let request: CompanionRequest
    public let startedAt: Date
  }

  public private(set) var pending: Pending?
  public let timeout: TimeInterval

  /// NaN and infinity never compare as an elapsed age, so they would leave
  /// the single pending request stuck. Those values use the finite default.
  public init(timeout: TimeInterval = CompanionLimits.refreshTimeout) {
    self.timeout = timeout.isFinite ? timeout : CompanionLimits.refreshTimeout
  }

  public var isPending: Bool { pending != nil }

  /// Starts a request of `kind`, or returns `nil` while another request is
  /// still pending.
  public mutating func begin(
    _ kind: CompanionRequest.Kind,
    now: Date
  ) -> CompanionRequest? {
    expireIfNeeded(now: now)
    guard pending == nil else { return nil }
    let request = CompanionRequest(kind: kind)
    pending = Pending(request: request, startedAt: now)
    return request
  }

  /// Completes the pending request when `id` matches it. A reply for any
  /// other (expired or unknown) request is not accepted.
  @discardableResult
  public mutating func complete(_ id: CompanionRequestID) -> Bool {
    guard pending?.request.id == id else { return false }
    pending = nil
    return true
  }

  /// Abandons a pending request older than `timeout`; returns whether one
  /// was abandoned.
  @discardableResult
  public mutating func expireIfNeeded(now: Date) -> Bool {
    guard let pending else { return false }
    let age = now.timeIntervalSince(pending.startedAt)
    if timeout.isFinite, age.isFinite, age >= 0, age < timeout { return false }
    self.pending = nil
    return true
  }

  public mutating func cancel() { pending = nil }
}

/// Phone-side companion settings. Both are user choices; preview text is
/// disabled by default.
public struct CompanionSettings: Hashable, Sendable, Codable {
  /// Whether any status is shared with the watch.
  public var sharingEnabled: Bool
  /// Whether an on-request bounded text preview may be sent. Has no
  /// effect while `sharingEnabled` is false.
  public var previewEnabled: Bool

  public init(sharingEnabled: Bool = true, previewEnabled: Bool = false) {
    self.sharingEnabled = sharingEnabled
    self.previewEnabled = previewEnabled
  }

  /// Default: status sharing on, preview text off.
  public static let `default` = CompanionSettings()

  /// Preview text is allowed only when both toggles are on.
  public var allowsPreview: Bool { sharingEnabled && previewEnabled }
}
