/// Proposed v1 resource limits (spec.roaming.md §12). Every decoder and
/// queue checks these before allocating.
public enum RSTLimits {
  public static let protocolName = "RST/1"
  public static let alpn = "rst/1"

  public static let maxSessionsPerAccount = 8
  public static let maxColumns = 200
  public static let maxRows = 80
  public static let maxControlRecordBytes = 64 * 1024
  public static let maxSnapshotEncodedBytes = 4 * 1024 * 1024
  public static let maxSnapshotDecodedBytes = 4 * 1024 * 1024
  public static let maxInFlightSnapshots = 2
  /// Generated/pending input bytes per endpoint.
  public static let maxPendingInputBytes = 64 * 1024
  public static let maxPasteBytes = 32 * 1024
  public static let maxGraphemeBytes = 64
  /// Display text for a cell whose grapheme exceeds `maxGraphemeBytes`.
  public static let graphemePlaceholder = "\u{FFFD}"
  public static let maxTitleBytes = 1024
  public static let maxStyles = maxColumns * maxRows
  public static let sftpOutstandingRequests = 8
  public static let sftpChunkBytes = 32 * 1024
  public static let maxBootstrapEnvelopeBytes = 64 * 1024

  /// Snapshot capture cadence and cancellation budget (§7.3).
  public static let maxCapturesPerSecond = 30
  /// Cadence for history-window moves, which answer the viewer's scroll.
  public static let maxInteractiveCapturesPerSecond = 120
  public static let maxCancellationsPerSecond = 10

  /// Session lifetimes (§4, §5.2).
  public static let reservationLifetime: Duration = .seconds(60)
  public static let detachedRetention: Duration = .seconds(24 * 3600)
  public static let exitedRetention: Duration = .seconds(5 * 60)
  public static let maxTokenLifetime: Duration = .seconds(8 * 3600)

  /// Client liveness (§9).
  public static let heartbeatInterval: Duration = .seconds(20)
  public static let minimumStaleTimeout: Duration = .seconds(2)
}
