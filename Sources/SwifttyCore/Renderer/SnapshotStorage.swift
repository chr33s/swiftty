/// Pooled cell, row and grapheme buffers behind `RenderSnapshot`.
///
/// Sendable: all fields and buffers are mutated only by the owning builder
/// (on the session queue) or before first publication, and only while no
/// snapshot references the storage; published storage is read-only. Buffers
/// are owned by the instance and deallocated in `deinit`.
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
  var hasGraphemes = false

  /// Damage accumulated since this storage was last filled.
  var pending = DamageRegion.full
  /// Per row copied by the latest `fill`: whether any cell is a grapheme
  /// or (with `detectPlaceholders`) a plane-16 scalar, so may be a kitty
  /// placeholder (spec.graphics.md §10.2).
  private(set) var placeholderCandidates: [Bool] = []

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
    if placeholderCandidates.count < rows {
      placeholderCandidates = [Bool](repeating: false, count: rows)
    }
    pending.setFull()
  }

  /// Copies damaged rows from `state`. The grapheme side table is append
  /// only: unchanged rows keep their entries and changed rows append new
  /// ones, so a screen of graphemes (emoji, kitty graphics placeholders)
  /// refills only what changed. A full refill compacts it once dead
  /// entries outnumber a few screens' worth.
  @inline(__always)
  func fill(
    from state: borrowing TerminalState,
    damage: DamageRegion,
    detectPlaceholders: Bool = false
  ) {
    let full =
      pending.isFull || entryCount > max(4096, 4 * rows * columns)
      || scalarCount > max(1 << 16, 16 * rows * columns)
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
      // Candidates are graphemes (a placeholder with diacritics) and
      // U+10EEEE alone. With images on screen, OR-ing the glyphs costs one
      // instruction per cell; any plane-16 scalar sets bit 20 and only
      // triggers the engine's exact scan. Only rows copied by this fill
      // are read, so rows copied without images need no bit.
      var grapheme = false
      for x in 0 ..< n where dst[x].isGrapheme {
        dst[x].glyph = appendGrapheme(state.graphemeScalars(dst[x].glyph))
        grapheme = true
      }
      if grapheme { hasGraphemes = true }
      placeholderCandidates[y] =
        grapheme || detectPlaceholders && Self.hasPlane16Glyph(dst, n)
    }
    pending = .none
  }

  /// Whether any glyph has bit 20 set (a plane-16 scalar such as
  /// U+10EEEE). Branchless OR, one instruction per cell.
  static func hasPlane16Glyph(
    _ cells: UnsafeMutablePointer<Cell>,
    _ n: Int
  ) -> Bool {
    var glyphs: UInt32 = 0
    for x in 0 ..< n { glyphs |= cells[x].glyph }
    return glyphs & KittyGraphics.placeholder & 0x10_0000 != 0
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

  func appendGrapheme(_ scalars: borrowing Span<UInt32>) -> UInt32 {
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
      let dst = graphemeScalars + scalarCount
      // Most clusters are a few scalars (a kitty placeholder is three):
      // a memmove call per cluster cost more than the copy.
      if buffer.count <= 4 {
        for i in 0 ..< buffer.count { dst[i] = buffer[i] }
      } else {
        dst.update(from: buffer.baseAddress!, count: buffer.count)
      }
    }
    graphemeEntries[entryCount] =
      UInt64(scalarCount) << 32 | UInt64(scalars.count)
    scalarCount += scalars.count
    entryCount += 1
    return UInt32(entryCount - 1)
  }
}
