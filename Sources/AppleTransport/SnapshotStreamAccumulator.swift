import ScreenProtocol
import SessionCore

/// Accumulates one inbound snapshot stream with strict, header-driven
/// bounds (spec §7.2, §12). Nothing beyond the 9-byte header plus the
/// header's `encodedLength` is ever buffered, and that length is itself
/// capped by the negotiated limit and `RSTLimits.maxSnapshotEncodedBytes`. Only an exactly complete
/// payload is returned at FIN; partial, oversized, or trailing-data streams
/// are errors and their bytes are discarded by the caller.
public struct SnapshotStreamAccumulator: Sendable {
  /// Largest stream the client will ever buffer.
  public static let hardLimit =
    SnapshotFrame.headerLength + RSTLimits.maxSnapshotEncodedBytes

  public private(set) var bytes: [UInt8] = []
  /// Header length plus the header's encoded length, once known.
  public private(set) var expectedLength: Int?
  private let limits: NegotiatedLimits
  private let bufferLimit: Int

  public init(limits: NegotiatedLimits = NegotiatedLimits()) {
    self.limits = limits.effective
    bufferLimit =
      SnapshotFrame.headerLength + max(0, self.limits.maxSnapshotEncodedBytes)
  }

  /// Most bytes the next read should request: enough to complete the
  /// stream plus one, so an overrun is detected without buffering it all.
  public var nextReadLimit: Int {
    let target = expectedLength ?? bufferLimit
    return max(1, min(64 * 1024, target - bytes.count + 1))
  }

  public mutating func append(
    _ data: some Collection<UInt8>
  ) throws(FramingError) {
    let incoming = data.count
    let limit = expectedLength ?? bufferLimit
    guard incoming <= limit - bytes.count else {
      throw incoming > bufferLimit - bytes.count
        ? .snapshotTooLarge : .trailingData
    }
    var consumed = 0
    if expectedLength == nil {
      consumed = min(incoming, SnapshotFrame.headerLength - bytes.count)
      bytes.append(contentsOf: data.prefix(consumed))
      guard let header = try SnapshotFrame.header(bytes, limits: limits) else {
        return
      }
      expectedLength = SnapshotFrame.headerLength + header.encodedLength
    }
    guard let expectedLength else { return }
    guard incoming - consumed <= expectedLength - bytes.count else {
      throw .trailingData
    }
    bytes.append(contentsOf: data.dropFirst(consumed))
  }

  /// Call at FIN. Returns the payload only when exactly complete.
  public func finish() throws(FramingError) -> [UInt8] {
    guard let expectedLength, bytes.count == expectedLength else {
      throw .truncated
    }
    return bytes
  }
}

/// A token bucket for rate-limiting new handshakes (spec §12).
public struct TokenBucket: Sendable {
  public let capacity: Double
  public let refillPerSecond: Double
  private var tokens: Double
  private var last: ContinuousClock.Instant?

  public init(capacity: Int, refillPerSecond: Double) {
    self.capacity = Double(max(1, capacity))
    self.refillPerSecond = max(0, refillPerSecond)
    self.tokens = self.capacity
  }

  public mutating func take(now: ContinuousClock.Instant = .now) -> Bool {
    if let last {
      let elapsed = last.duration(to: now)
      let seconds =
        Double(elapsed.components.seconds) + Double(
          elapsed.components.attoseconds
        ) / 1e18
      tokens = min(capacity, tokens + max(0, seconds) * refillPerSecond)
    }
    last = now
    guard tokens >= 1 else { return false }
    tokens -= 1
    return true
  }
}
