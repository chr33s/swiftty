/// Storage for multi-scalar cells (base + combining marks / ZWJ sequences).
///
/// Cells flagged `.grapheme` store an id into this table. Entries are
/// append-only; `TerminalState` compacts the table when garbage grows.
/// Each entry contains a base scalar and at least one joined scalar.
struct GraphemeTable: ~Copyable {
  private(set) var scalars: [UInt32] = []
  private(set) var entries: [UInt64] = []  // start << 32 | count

  /// Bound retained garbage in small terminals; live content raises the limit.
  static let compactionThreshold = 1 << 16
  /// Scalar count that triggers compaction; raised after compacting.
  var compactionLimit = compactionThreshold

  var needsCompaction: Bool { scalars.count > compactionLimit }

  /// Cluster contents, valid while this table is borrowed.
  @_lifetime(borrow self)
  func scalars(_ id: UInt32) -> Span<UInt32> {
    let entry = entries[Int(id)]
    let start = Int(entry >> 32)
    let count = Int(entry & 0xFFFF_FFFF)
    return scalars.span.extracting(start ..< start + count)
  }

  /// Number of scalars in a cluster, without constructing a buffer view.
  func scalarCount(_ id: UInt32) -> Int { Int(entries[Int(id)] & 0xFFFF_FFFF) }

  /// Returns the id of `cell`'s cluster extended by `scalar`.
  mutating func appending(_ scalar: UInt32, to cell: Cell) -> UInt32 {
    let start = scalars.count
    if cell.isGrapheme {
      let entry = entries[Int(cell.glyph)]
      let lo = Int(entry >> 32)
      let n = Int(entry & 0xFFFF_FFFF)
      for i in lo ..< lo + n { scalars.append(scalars[i]) }
    } else {
      scalars.append(cell.glyph)
    }
    scalars.append(scalar)
    entries.append(UInt64(start) << 32 | UInt64(scalars.count - start))
    return UInt32(entries.count - 1)
  }

  /// Last scalar of a cell's content.
  func lastScalar(of cell: Cell) -> UInt32 {
    guard cell.isGrapheme else { return cell.glyph }
    let entry = entries[Int(cell.glyph)]
    return scalars[Int(entry >> 32) + Int(entry & 0xFFFF_FFFF) - 1]
  }

  /// Copies `cell`'s cluster from `old` into this table (compaction).
  mutating func adopt(_ cell: inout Cell, from old: borrowing GraphemeTable) {
    guard cell.isGrapheme else { return }
    let entry = old.entries[Int(cell.glyph)]
    let lo = Int(entry >> 32)
    let n = Int(entry & 0xFFFF_FFFF)
    let start = scalars.count
    scalars.append(contentsOf: old.scalars[lo ..< lo + n])
    entries.append(UInt64(start) << 32 | UInt64(n))
    cell.glyph = UInt32(entries.count - 1)
  }

  mutating func removeAll() {
    compactionLimit = Self.compactionThreshold
    scalars.removeAll(keepingCapacity: true)
    entries.removeAll(keepingCapacity: true)
  }
}
