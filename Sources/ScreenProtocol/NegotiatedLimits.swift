import SessionCore

extension NegotiatedLimits {
  /// Zero input/paste budgets disable those capacities. Every framing
  /// and geometry bound must be positive.
  public var isValid: Bool {
    maxColumns > 0 && maxRows > 0 && maxControlRecordBytes > 0
      && maxSnapshotEncodedBytes > 0 && maxSnapshotDecodedBytes > 0
      && maxPendingInputBytes >= 0 && maxPasteBytes >= 0
  }

  /// A peer can lower supported bounds, but cannot raise local hard caps.
  public var effective: NegotiatedLimits {
    var result = self
    result.maxColumns = min(maxColumns, RSTLimits.maxColumns)
    result.maxRows = min(maxRows, RSTLimits.maxRows)
    result.maxControlRecordBytes = min(
      maxControlRecordBytes,
      RSTLimits.maxControlRecordBytes
    )
    result.maxSnapshotEncodedBytes = min(
      maxSnapshotEncodedBytes,
      RSTLimits.maxSnapshotEncodedBytes
    )
    result.maxSnapshotDecodedBytes = min(
      maxSnapshotDecodedBytes,
      RSTLimits.maxSnapshotDecodedBytes
    )
    result.maxPendingInputBytes = min(
      maxPendingInputBytes,
      RSTLimits.maxPendingInputBytes
    )
    result.maxPasteBytes = min(maxPasteBytes, RSTLimits.maxPasteBytes)
    return result
  }

  public func contains(_ grid: GridSize) -> Bool {
    grid.isValid && grid.columns <= maxColumns && grid.rows <= maxRows
  }

  /// Checks per-operation bounds before queueing or replay. The queue
  /// separately accounts for the total retained input byte budget.
  public func permits(_ operation: InputOperation) -> Bool {
    guard (try? operation.validate()) != nil,
      operation.expansionBound <= maxPendingInputBytes
    else { return false }
    switch operation {
    case let .committedText(text), let .paste(text):
      return maxPasteBytes > 0 && text.utf8.count <= maxPasteBytes
    case let .resize(columns, rows, _):
      return contains(GridSize(columns: columns, rows: rows))
    case .key, .wheel: return true
    }
  }
}
