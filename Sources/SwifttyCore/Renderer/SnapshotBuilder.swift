/// Produces snapshots from terminal state using a small storage pool.
package struct SnapshotBuilder {
  private let source = SnapshotSource()
  private var pool: [SnapshotStorage] = []
  private var sequence: UInt64 = 0
  private var presentationRevision: UInt64 = 0
  private(set) var last: RenderSnapshot?
  /// Inputs of the last image capture, to reuse it while nothing moved.
  private var imageKey:
    (revision: UInt64, top: Int, rows: Int, columns: Int, cell: SIMD2<Int>)?
  private var images: [KittyGraphics.Placement] = []
  private var placeholderRows: [KittyGraphics.PlaceholderRow] = []
  private var placeholderShape: (top: Int, rows: Int, columns: Int)?
  /// Damaged rows to rescan, reused across frames.
  private var rescan: [Int] = []
  /// Whether virtual placements exist, as of a graphics revision.
  private var usesPlaceholders: (revision: UInt64, value: Bool) = (.max, false)
  /// The latest capture found kitty images in the state.
  private var hadKittyImages = false

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
    let modes = state.modes
    let cursor = CursorState(
      x: state.cursor.x,
      y: state.cursor.y,
      isVisible: modes.contains(.cursorVisible) && state.viewportOffset == 0,
      style: state.cursorStyle,
      isBlinking: modes.contains(.cursorBlink),
    )
    let presentationChanged =
      !damage.isEmpty || last?.cursor != cursor || last?.modes != modes
      || last?.viewportOffset != state.viewportOffset
    for storage in pool { storage.pending.formUnion(damage) }

    let storage = takeFreeStorage()
    storage.ensureSize(columns: state.columns, rows: rowCount)
    // As of the previous capture: the first capture with images rescans
    // every row, so it needs no candidate bits.
    storage.fill(
      from: state,
      damage: damage,
      detectPlaceholders: hadKittyImages
    )
    // After the fill: placeholder rescans read the rows just copied.
    let imagesChanged = captureImages(
      &state,
      rows: rowCount,
      damage: damage,
      storage: storage
    )
    if presentationChanged || imagesChanged { presentationRevision &+= 1 }

    sequence &+= 1
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
      cursor: cursor,
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
      presentationRevision: presentationRevision,
      images: images,
      imageCellSize: state.presentationImages.isEmpty
        ? SIMD2(state.cellPixelSize.width, state.cellPixelSize.height)
        : state.presentationImageCellSize,
    )
    last = snapshot
    return snapshot
  }

  /// Refreshes `images`; true when they changed. Placeholder runs depend
  /// on cell contents, so any damage recaptures while images exist.
  private mutating func captureImages(
    _ state: inout TerminalState,
    rows: Int,
    damage: DamageRegion,
    storage: SnapshotStorage
  ) -> Bool {
    if !state.presentationImages.isEmpty {
      imageKey = nil
      hadKittyImages = false
      guard state.presentationImages != images else { return false }
      images = state.presentationImages
      return true
    }
    guard let probe = state.kittySnapshotKey else {
      // No images now. Clears both local images and presentation ones (a
      // roaming pane switched to one without images).
      if hadKittyImages {
        hadKittyImages = false
        imageKey = nil
        // Images that return start with a full rescan.
        placeholderRows = []
        placeholderShape = nil
      }
      guard !images.isEmpty else { return false }
      images = []
      return true
    }
    hadKittyImages = true
    let cell = SIMD2(state.cellPixelSize.width, state.cellPixelSize.height)
    let key = (
      revision: probe.revision, top: probe.top, rows: rows,
      columns: state.columns, cell: cell
    )
    let sameKey =
      imageKey.map {
        $0.revision == key.revision && $0.top == key.top && $0.rows == key.rows
          && $0.columns == key.columns && $0.cell == key.cell
      } ?? false
    if sameKey, damage.isEmpty { return false }
    // Anchored placements depend only on the key; placeholder runs only on
    // row contents, so damaged rows are rescanned and an unchanged result
    // skips reassembly (spec.graphics.md §10.2).
    var rowsChanged = false
    var cached: [KittyGraphics.PlaceholderRow]?
    if usesPlaceholders.revision != key.revision {
      usesPlaceholders = (key.revision, state.kittyUsesPlaceholders)
    }
    if usesPlaceholders.value {
      let shape = (top: key.top, rows: rows, columns: key.columns)
      if placeholderShape.map({ $0 != shape }) ?? true
        || placeholderRows.count != rows
      {
        placeholderRows = (0 ..< rows)
          .map { state.kittyPlaceholderRow(absoluteRow: key.top + $0) }
        placeholderShape = shape
        rowsChanged = true
      } else {
        // A damaged row that held no runs needs the engine only when its
        // freshly copied cells include a candidate.
        // Rows are collected first: calling into `state` from inside the
        // closure copied the whole TerminalState once per row.
        let candidates = storage.placeholderCandidates
        rescan.removeAll(keepingCapacity: true)
        damage.forEachRow(below: rows) { y in
          if placeholderRows[y].isEmpty, !candidates[y] { return }
          rescan.append(y)
        }
        for y in rescan {
          let row = state.kittyPlaceholderRow(absoluteRow: key.top + y)
          if row != placeholderRows[y] {
            placeholderRows[y] = row
            rowsChanged = true
          }
        }
      }
      cached = placeholderRows
    } else if !placeholderRows.isEmpty {
      placeholderRows = []
      placeholderShape = nil
      rowsChanged = true
    }
    if sameKey, !rowsChanged { return false }
    imageKey = key
    let captured = state.kittyPlacements(rows: rows, placeholderRows: cached)
    guard captured != images else { return false }
    images = captured
    return true
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
