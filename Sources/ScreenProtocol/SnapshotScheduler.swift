/// Bounded snapshot scheduling (spec §7.3): at most two in-flight snapshot
/// streams plus the latest unsent state, which is represented lazily by
/// the dirty flag and captured only when a slot can take it.
///
/// One in-flight stream is protected from cancellation caused merely by
/// new output, so a frame always finishes under continuous output. The
/// second is replaceable, with cancellations limited to ten per second.
/// Pure state; the owner supplies times and performs the actions.
public struct SnapshotScheduler: Sendable {
  public typealias Instant = ContinuousClock.Instant

  public struct Stream: Hashable, Sendable {
    public var id: UInt64
    public var revision: UInt64
    public var isProtected: Bool
  }

  public enum Action: Equatable, Sendable {
    /// Nothing to send.
    case idle
    /// Ask again at the given time (cadence or cancellation budget).
    case wait(until: Instant)
    /// Capture current state onto a new stream, first canceling the
    /// given replaceable stream if present.
    case capture(cancel: UInt64?)
  }

  public private(set) var streams: [Stream] = []
  public private(set) var isDirty = false
  /// The pending change answers the viewer directly (a history-window
  /// move), so it uses the interactive cadence.
  public private(set) var isInteractive = false
  public private(set) var acknowledgedRevision: UInt64 = 0
  private var lastCapture: Instant?
  private var cancellations: [Instant] = []
  public let captureInterval: Duration
  /// Cadence for interactive changes; never slower than `captureInterval`.
  public let interactiveInterval: Duration
  public let cancellationLimit: Int

  /// Nonpositive capture rates use one capture per second. Nonpositive
  /// cancellation rates disable replacement until a stream retires.
  public init(
    capturesPerSecond: Int = 30,
    interactiveCapturesPerSecond: Int = 120,
    cancellationsPerSecond: Int = 10
  ) {
    captureInterval = .seconds(1) / max(1, capturesPerSecond)
    interactiveInterval = min(
      captureInterval,
      .seconds(1) / max(1, interactiveCapturesPerSecond)
    )
    cancellationLimit = max(0, cancellationsPerSecond)
  }

  /// Terminal state changed since the last capture. An interactive change
  /// (the viewer scrolled) is captured at `interactiveInterval` instead of
  /// waiting out output's cadence; the two-stream bound still applies.
  public mutating func markDirty(interactive: Bool = false) {
    isDirty = true
    if interactive { isInteractive = true }
  }

  /// Decides what to do now. A `.capture` result commits the scheduler to
  /// the capture: call `started` with the new stream afterwards.
  public mutating func next(now: Instant) -> Action {
    guard isDirty else { return .idle }
    let interval = isInteractive ? interactiveInterval : captureInterval
    if let last = lastCapture, now < last + interval {
      return .wait(until: last + interval)
    }
    switch streams.count {
    case 0, 1: return commitCapture(now: now, cancel: nil)
    default:
      guard cancellationLimit > 0 else { return .idle }
      cancellations.removeAll { $0 + .seconds(1) <= now }
      guard cancellations.count < cancellationLimit else {
        return .wait(until: cancellations[0] + .seconds(1))
      }
      guard let victim = streams.firstIndex(where: { !$0.isProtected }) else {
        // Both protected cannot happen; wait for an acknowledgment.
        return .idle
      }
      let id = streams.remove(at: victim).id
      cancellations.append(now)
      return commitCapture(now: now, cancel: id)
    }
  }

  private mutating func commitCapture(now: Instant, cancel: UInt64?) -> Action {
    isDirty = false
    isInteractive = false
    lastCapture = now
    return .capture(cancel: cancel)
  }

  /// Registers the stream carrying a just-captured revision.
  public mutating func started(stream id: UInt64, revision: UInt64) {
    precondition(streams.count < 2, "more than two in-flight snapshots")
    let isProtected = !streams.contains(where: \.isProtected)
    streams.append(Stream(id: id, revision: revision, isProtected: isProtected))
  }

  /// `ScreenAck(R)`: retires every stream at or below R and returns their
  /// ids so the owner can cancel any still sending. Promotes a surviving
  /// newer stream to protected status.
  public mutating func acknowledged(revision: UInt64) -> [UInt64] {
    guard revision > acknowledgedRevision else { return [] }
    acknowledgedRevision = revision
    let retired = streams.filter { $0.revision <= revision }.map(\.id)
    streams.removeAll { $0.revision <= revision }
    promote()
    return retired
  }

  /// A stream failed or was reset by the peer before acknowledgment: its
  /// state must be resent.
  public mutating func failed(stream id: UInt64) {
    guard streams.contains(where: { $0.id == id }) else { return }
    streams.removeAll { $0.id == id }
    promote()
    isDirty = true
  }

  /// New attachment: discard old transport streams and send current state.
  public mutating func reset() {
    streams = []
    cancellations = []
    lastCapture = nil
    acknowledgedRevision = 0
    isDirty = true
  }

  private mutating func promote() {
    if !streams.isEmpty, !streams.contains(where: \.isProtected) {
      streams[0].isProtected = true
    }
  }
}
