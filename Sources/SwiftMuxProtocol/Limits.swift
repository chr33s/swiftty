/// Proposed starting budgets (spec §5). Not measured capabilities.
public struct MuxLimits: Codable, Sendable, Equatable {
  public var maxPanes = 32
  public var historyRowsPerPane = 10000
  public var historyBytesPerPane = 16 << 20
  public var totalHistoryBytes = 128 << 20
  /// History kept back for every pane that could still be created, so
  /// early panes cannot starve later ones of the shared budget.
  public var minHistoryBytesPerPane = 1 << 20
  /// Admitted, unwritten PTY input per pane.
  public var inputBytesPerPane = 256 << 10
  /// Terminal replies (and paste closing markers) held beyond input.
  public var replyReserveBytes = 64 << 10
  public var readTurnBytes = 64 << 10
  public var maxFrameBytes = 16 << 20
  /// Kitty graphics bytes each pane screen may hold (spec.graphics.md §8.2).
  public var imageBytesPerScreen = 256_000_000
  public var maxColumns = 512
  public var maxRows = 256
  public var pendingFrameBudget = 64 << 20
  public var maxPasteBytes = 1 << 20
  public var maxPasteChunkBytes = 32 << 10
  public var maxControlRecordBytes = 256 << 10
  /// Frame export interval for each subscribed pane (60 Hz).
  public var frameIntervalNanoseconds: UInt64 = 16_666_667
  public var maxStyles = 4096
  public var maxGraphemeScalars = 32
  public var maxGeometryBatch = 64
  public var maxNameBytes = 256
  public var maxSearchBytes = 1024
  public var minPaneColumns = 10
  public var minPaneRows = 2
  /// OSC 7501 inbox (spec.inbox.md §3).
  public var statusRecordsPerPane = 64
  public var statusTextBytes = 16 << 20
  /// Zero disables paging; page requests fail with resourceLimit.
  public var inboxPageSize = 100
  public var inboxSubscribers = 16
  /// Pending coalesced inbox updates per subscriber before resync.
  public var inboxPendingUpdates = 64
  /// Resolved occurrences retained for stale-link answers.
  public var resolvedHistory = 256

  public init() {}

  public static let standard = MuxLimits()

  /// Checks peer-advertised capacities before client arithmetic or use.
  /// Zero may disable a budget; dimensions and record/chunk units stay
  /// positive.
  package func validateForClient() throws(MuxError) {
    let capacities = [
      maxPanes, historyRowsPerPane, historyBytesPerPane, totalHistoryBytes,
      minHistoryBytesPerPane, inputBytesPerPane, replyReserveBytes,
      readTurnBytes, maxFrameBytes, pendingFrameBudget, maxPasteBytes,
      maxNameBytes, maxSearchBytes, statusRecordsPerPane, statusTextBytes,
      inboxPageSize, inboxSubscribers, inboxPendingUpdates, resolvedHistory,
    ]
    guard capacities.allSatisfy({ $0 >= 0 }), maxColumns > 0, maxRows > 0,
      minPaneColumns > 0, minPaneRows > 0, maxControlRecordBytes > 0,
      maxPasteChunkBytes > 0, maxStyles > 0, maxStyles <= Int(UInt16.max),
      maxGraphemeScalars > 0, maxGeometryBatch > 0
    else { throw MuxError(.invalidRequest, "invalid peer limits") }
    guard maxFrameBytes <= Int.max - (64 << 10) else {
      throw MuxError(.invalidRequest, "peer frame record limit overflows")
    }
    let (cells, overflow) = maxColumns.multipliedReportingOverflow(by: maxRows)
    guard !overflow, cells <= Int.max / 4 else {
      throw MuxError(.invalidRequest, "peer grid byte count overflows")
    }
  }

  /// Checks local configuration before constructing terminal storage.
  /// PTY dimensions use UInt16. Also bound eager screen and history metadata
  /// allocations independently of the operator's byte budgets.
  package func validateForService() throws(MuxError) {
    try validateForClient()
    guard maxColumns <= Int(UInt16.max), maxRows <= Int(UInt16.max),
      minPaneColumns <= maxColumns, minPaneRows <= maxRows,
      maxColumns * maxRows <= 1 << 20, historyRowsPerPane <= 1_000_000,
      historyBytesPerPane <= (Int(Int32.max) - maxRows) * 16,
      totalHistoryBytes <= (Int(Int32.max) - maxRows) * 16, readTurnBytes > 0
    else { throw MuxError(.invalidRequest, "invalid service limits") }
  }

  /// A search query the service accepts: non-empty, within
  /// `maxSearchBytes`. Clients check the same rule before sending.
  public func validSearchQuery(_ query: String) -> Bool {
    !query.isEmpty && query.utf8.count <= maxSearchBytes
  }

  /// Bytes in one cell grid, or nil when it exceeds the dimension limits.
  public func cellCount(columns: Int, rows: Int) -> Int? {
    guard columns > 0, rows > 0, columns <= maxColumns, rows <= maxRows else {
      return nil
    }
    let (n, overflow) = columns.multipliedReportingOverflow(by: rows)
    return overflow ? nil : n
  }
}
