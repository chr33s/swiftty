import SwifttyEngine

extension RenderSnapshot {
  /// An immutable snapshot with its own storage and full damage, built
  /// from an owned (already validated) screen. Grapheme cells must index
  /// `screen.graphemes`.
  package init(
    owned screen: OwnedScreen,
    selection: HighlightSpan? = nil,
    sequence: UInt64
  ) {
    let storage = SnapshotStorage()
    storage.load(screen)
    self.init(
      storage: storage,
      source: SnapshotSource(),
      columns: screen.columns,
      rowCount: screen.rows,
      overscanRows: 0,
      cursor: screen.cursor,
      selection: selection,
      searchMatches: screen.searchMatches,
      selectedSearchMatch: screen.selectedSearchMatch,
      searchMatchCount: screen.searchMatchCount,
      searchSelectedIndex: nil,
      damage: .full,
      palette: screen.palette,
      underlineColors: screen.underlineColors,
      modes: screen.modes,
      viewportOffset: screen.viewportOffset,
      scrollbackCount: screen.scrollbackCount,
      sequence: sequence,
      images: screen.images,
      imageCellSize: screen.imageCellSize,
    )
  }
}

extension SnapshotStorage {
  /// Fills this fresh storage from an owned screen.
  func load(_ screen: OwnedScreen) {
    ensureSize(columns: screen.columns, rows: screen.rows)
    var ids: [UInt32] = []
    ids.reserveCapacity(screen.graphemes.count)
    for scalars in screen.graphemes {
      ids.append(appendGrapheme(scalars.span))
      hasGraphemes = true
    }
    for y in 0 ..< screen.rows {
      rowRecords[y] = RowSnapshot(isDirty: true, isWrapped: screen.wrapped[y])
      let dst = cells + y * screen.columns
      for x in 0 ..< screen.columns {
        var cell = screen.cells[y * screen.columns + x]
        if cell.isGrapheme { cell.glyph = ids[Int(cell.glyph)] }
        dst[x] = cell
      }
    }
    pending = .none
  }
}
