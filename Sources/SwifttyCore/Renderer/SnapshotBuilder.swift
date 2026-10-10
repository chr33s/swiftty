/// Produces snapshots from terminal state using a small storage pool.
package struct SnapshotBuilder {
  private let source = SnapshotSource()
  private var pool: [SnapshotStorage] = []
  private var sequence: UInt64 = 0
  private(set) var last: RenderSnapshot?

  package init() { pool.reserveCapacity(3) }

  package mutating func build(
    from state: inout TerminalState,
    overscan: Int = 0
  ) -> RenderSnapshot {
    state.refreshSearchIfNeeded()
    var damage = state.takeDamage()
    if state.viewportOffset > 0, !damage.isEmpty { damage.setFull() }
    // Overscan rows exist only while scrolled back: the rows below the
    // viewport are then still on screen or in history.
    let extra = min(max(overscan, 0), state.viewportOffset)
    let rowCount = state.rows + extra
    if last == nil || last!.columns != state.columns
      || last!.rowCount != rowCount
    {
      damage.setFull()
    }
    for storage in pool { storage.pending.formUnion(damage) }

    let storage = takeFreeStorage()
    storage.ensureSize(columns: state.columns, rows: rowCount)
    storage.fill(from: state, damage: damage)

    sequence &+= 1
    let modes = state.modes
    func span(
      _ start: TerminalPoint,
      _ end: TerminalPoint,
      rectangle: Bool
    ) -> HighlightSpan {
      HighlightSpan(
        startRow: state.viewportRow(absoluteRow: start.row),
        startColumn: start.column,
        endRow: state.viewportRow(absoluteRow: end.row),
        endColumn: end.column,
        rectangle: rectangle,
      )
    }
    let selection = state.selection.map {
      span($0.start, $0.end, rectangle: $0.rectangle)
    }
    var matches: [HighlightSpan] = []
    var selectedMatch: Int?
    if !state.searchMatches.isEmpty {
      let top = state.absoluteRow(viewportRow: 0)
      let bottom = top + rowCount - 1
      // Match starts and ends are monotonic. Skip history outside the
      // viewport without walking every result on each redraw.
      var first = 0
      var upper = state.searchMatches.count
      while first < upper {
        let middle = first + (upper - first) / 2
        if state.searchMatches[middle].end.row < top {
          first = middle + 1
        } else {
          upper = middle
        }
      }
      var end = first
      upper = state.searchMatches.count
      while end < upper {
        let middle = end + (upper - end) / 2
        if state.searchMatches[middle].start.row <= bottom {
          end = middle + 1
        } else {
          upper = middle
        }
      }
      matches.reserveCapacity(end - first)
      for i in first ..< end {
        let m = state.searchMatches[i]
        if i == state.searchSelected { selectedMatch = matches.count }
        matches.append(span(m.start, m.end, rectangle: false))
      }
    }
    let snapshot = RenderSnapshot(
      storage: storage,
      source: source,
      columns: state.columns,
      rowCount: rowCount,
      overscanRows: extra,
      cursor: CursorState(
        x: state.cursor.x,
        y: state.cursor.y,
        isVisible: modes.contains(.cursorVisible) && state.viewportOffset == 0,
        style: state.cursorStyle,
        isBlinking: modes.contains(.cursorBlink),
      ),
      selection: selection,
      searchMatches: matches,
      selectedSearchMatch: selectedMatch,
      searchMatchCount: state.searchMatches.count,
      searchSelectedIndex: state.searchSelected,
      damage: damage,
      palette: state.palette,
      underlineColors: state.underlineColors,
      modes: modes,
      viewportOffset: state.viewportOffset,
      scrollbackCount: state.scrollbackCount,
      sequence: sequence,
    )
    last = snapshot
    return snapshot
  }

  /// The previous snapshot with no damage (synchronized output).
  func repeatLast() -> RenderSnapshot? {
    guard var snapshot = last else { return nil }
    snapshot.damage = .none
    return snapshot
  }

  private mutating func takeFreeStorage() -> SnapshotStorage {
    last = nil  // drop our own reference so the last storage can be reused
    for i in pool.indices where isKnownUniquelyReferenced(&pool[i]) {
      return pool[i]
    }
    let storage = SnapshotStorage()
    if pool.count < 3 { pool.append(storage) } else { pool[0] = storage }
    return storage
  }
}
