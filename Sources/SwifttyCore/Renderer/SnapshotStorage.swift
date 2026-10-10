final class SnapshotStorage: @unchecked Sendable {
  private(set) var columns = 0
  private(set) var rows = 0
  private(set) var cells: UnsafeMutablePointer<Cell>
  private(set) var rowRecords: UnsafeMutablePointer<RowSnapshot>
  private var cellCapacity = 0
  private var rowCapacity = 0

  private(set) var graphemeScalars: UnsafeMutablePointer<UInt32>
  private(set) var graphemeEntries: UnsafeMutablePointer<UInt64>
  private(set) var scalarCount = 0
  private var scalarCapacity = 64
  private(set) var entryCount = 0
  private var entryCapacity = 16
  private(set) var hasGraphemes = false

  /// Damage accumulated since this storage was last filled.
  var pending = DamageRegion.full

  init() {
    cells = .allocate(capacity: 1)
    rowRecords = .allocate(capacity: 1)
    graphemeScalars = .allocate(capacity: scalarCapacity)
    graphemeEntries = .allocate(capacity: entryCapacity)
  }

  deinit {
    cells.deallocate()
    rowRecords.deallocate()
    graphemeScalars.deallocate()
    graphemeEntries.deallocate()
  }

  func ensureSize(columns: Int, rows: Int) {
    precondition(columns > 0 && rows > 0)
    let count = checkedAllocationCount(columns, rows)
    _ = checkedAllocationCount(count, MemoryLayout<Cell>.stride)
    guard columns != self.columns || rows != self.rows else { return }
    if count > cellCapacity {
      cells.deallocate()
      cellCapacity = count
      cells = .allocate(capacity: cellCapacity)
    }
    if rows > rowCapacity {
      rowRecords.deallocate()
      rowCapacity = rows
      rowRecords = .allocate(capacity: rowCapacity)
    }
    self.columns = columns
    self.rows = rows
    pending.setFull()
  }

  /// Copies damaged rows from `state`; everything when graphemes are
  /// involved in a changed frame since their side table is rebuilt from scratch.
  func fill(from state: borrowing TerminalState, damage: DamageRegion) {
    var full = pending.isFull || (hasGraphemes && !pending.isEmpty)
    if !full {
      for y in 0 ..< rows
      where pending.contains(row: y)
        && Self.row(y, of: state).cells.contains(where: \.isGrapheme)
      {
        full = true
        break
      }
    }
    if full {
      scalarCount = 0
      entryCount = 0
      hasGraphemes = false
    }
    for y in 0 ..< rows {
      let changed = full || pending.contains(row: y)
      guard changed else {
        // isWrapped is still current
        rowRecords[y].isDirty = damage.contains(row: y)
        continue
      }
      let (src, wrapped) = Self.row(y, of: state)
      rowRecords[y] = RowSnapshot(
        isDirty: damage.contains(row: y),
        isWrapped: wrapped
      )
      let dst = cells + y * columns
      let n = min(src.count, columns)
      if n > 0 { dst.update(from: src.baseAddress!, count: n) }
      if n < columns { (dst + n).update(repeating: .blank, count: columns - n) }
      for x in 0 ..< n where dst[x].isGrapheme {
        dst[x].glyph = appendGrapheme(state.graphemeScalars(dst[x].glyph))
        hasGraphemes = true
      }
    }
    pending = .none
  }

  /// Visible row `y`, or for `y >= state.rows` the overscan row below.
  static func row(
    _ y: Int,
    of state: borrowing TerminalState
  ) -> (cells: UnsafeBufferPointer<Cell>, wrapped: Bool) {
    if y < state.rows { return state.viewportRow(y) }
    return state.line(absoluteRow: state.absoluteRow(viewportRow: y)) ?? (
      UnsafeBufferPointer(start: nil, count: 0), false
    )
  }

  private func appendGrapheme(_ scalars: borrowing Span<UInt32>) -> UInt32 {
    if scalarCount + scalars.count > scalarCapacity {
      let grown = UnsafeMutablePointer<UInt32>
        .allocate(
          capacity: max(scalarCapacity * 2, scalarCount + scalars.count)
        )
      grown.update(from: graphemeScalars, count: scalarCount)
      graphemeScalars.deallocate()
      graphemeScalars = grown
      scalarCapacity = max(scalarCapacity * 2, scalarCount + scalars.count)
    }
    if entryCount == entryCapacity {
      let grown = UnsafeMutablePointer<UInt64>
        .allocate(capacity: entryCapacity * 2)
      grown.update(from: graphemeEntries, count: entryCount)
      graphemeEntries.deallocate()
      graphemeEntries = grown
      entryCapacity *= 2
    }
    scalars.withUnsafeBufferPointer { buffer in
      (graphemeScalars + scalarCount)
        .update(from: buffer.baseAddress!, count: buffer.count)
    }
    graphemeEntries[entryCount] =
      UInt64(scalarCount) << 32 | UInt64(scalars.count)
    scalarCount += scalars.count
    entryCount += 1
    return UInt32(entryCount - 1)
  }
}
