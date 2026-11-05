/// Storage for multi-scalar cells (base + combining marks / ZWJ sequences).
///
/// Cells flagged `.grapheme` store an id into this table. Entries are
/// append-only; `TerminalState` compacts the table when garbage grows.
/// Each entry contains a base scalar and at least one joined scalar.
struct GraphemeTable: ~Copyable {
  private(set) var scalars = GrowableBuffer<UInt32>()
  private(set) var entries = GrowableBuffer<UInt64>()  // start << 32 | count

  /// Bound retained garbage in small terminals; live content raises the limit.
  static let compactionThreshold = 1 << 16
  /// Scalar count that triggers compaction; raised after compacting.
  var compactionLimit = compactionThreshold

  var needsCompaction: Bool { scalars.count > compactionLimit }

  /// The newest entry, while one cell owns it; `appending` grows it in place.
  private var exclusiveTail = UInt32.max
  /// Break state after the tail, so joins need not replay the cluster.
  private var tailBreak = GraphemeBreak.State()
  private var tailBreakValid = false

  /// Call before anything that may copy cells.
  @inline(__always)
  mutating func releaseTail() { exclusiveTail = .max }

  @inline(__always)
  func breakState(after id: UInt32) -> GraphemeBreak.State? {
    id == exclusiveTail && tailBreakValid ? tailBreak : nil
  }

  @inline(__always)
  mutating func recordBreakState(_ state: GraphemeBreak.State, after id: UInt32)
  {
    guard id == exclusiveTail else { return }
    tailBreak = state
    tailBreakValid = true
  }

  /// Cluster contents, valid while this table is borrowed.
  @_lifetime(borrow self)
  func scalars(_ id: UInt32) -> Span<UInt32> {
    let entry = entries[Int(id)]
    let start = Int(entry >> 32)
    let count = Int(entry & 0xFFFF_FFFF)
    return scalars.span.extracting(start ..< start + count)
  }

  /// Scalars in `cell`'s content.
  @inline(__always)
  func scalarCount(ofCell cell: Cell) -> Int {
    cell.isGrapheme ? scalarCount(cell.glyph) : 1
  }

  /// Number of scalars in a cluster, without constructing a buffer view.
  func scalarCount(_ id: UInt32) -> Int { Int(entries[Int(id)] & 0xFFFF_FFFF) }

  /// Returns the id of `cell`'s cluster extended by `scalar`.
  mutating func appending(_ scalar: UInt32, to cell: Cell) -> UInt32 {
    if cell.isGrapheme, cell.glyph == exclusiveTail {
      let entry = entries[Int(exclusiveTail)]
      if Int(entry >> 32) + Int(entry & 0xFFFF_FFFF) == scalars.count {
        scalars.append(scalar)
        entries[Int(exclusiveTail)] = entry + 1
        tailBreakValid = false
        return exclusiveTail
      }
    }
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
    exclusiveTail = UInt32(entries.count - 1)
    tailBreakValid = false
    return exclusiveTail
  }

  /// Returns the id of `cell`'s cluster extended by every scalar of
  /// `added`, as successive single-scalar `appending` calls would.
  mutating func appending(
    contentsOf added: UnsafeBufferPointer<UInt32>,
    to cell: Cell
  ) -> UInt32 {
    precondition(!added.isEmpty)
    let id = appending(added[0], to: cell)
    guard added.count > 1 else { return id }
    // The first append left `id` as the exclusive tail at the end.
    scalars.append(contentsOf: UnsafeBufferPointer(rebasing: added[1...]))
    entries[Int(id)] += UInt64(added.count - 1)
    return id
  }

  /// Stores the cluster of `base` followed by `joined`, which is not
  /// empty, for a cell that held `base` alone. Returns its id: the
  /// exclusive tail, as after `appending` each scalar.
  @inline(__always)
  mutating func insert(
    base: UInt32,
    joined: UnsafeBufferPointer<UInt32>
  ) -> UInt32 {
    let start = scalars.count
    scalars.append(base)
    scalars.append(contentsOf: joined)
    entries.append(UInt64(start) << 32 | UInt64(joined.count + 1))
    exclusiveTail = UInt32(entries.count - 1)
    tailBreakValid = false
    return exclusiveTail
  }

  /// Stores a complete cluster of at least two scalars and returns its id.
  mutating func insert(_ cluster: [UInt32]) -> UInt32 {
    precondition(cluster.count >= 2, "a grapheme entry joins scalars")
    exclusiveTail = .max
    let start = scalars.count
    for scalar in cluster { scalars.append(scalar) }
    entries.append(UInt64(start) << 32 | UInt64(cluster.count))
    return UInt32(entries.count - 1)
  }

  /// Last scalar of a cell's content.
  func lastScalar(of cell: Cell) -> UInt32 {
    guard cell.isGrapheme else { return cell.glyph }
    let entry = entries[Int(cell.glyph)]
    return scalars[Int(entry >> 32) + Int(entry & 0xFFFF_FFFF) - 1]
  }

  /// Call once before `adopt` reads clusters from this table.
  mutating func prepareForAdoption() { scalars.padTail() }

  /// Copies `cell`'s cluster from `old` into this table (compaction).
  mutating func adopt(_ cell: inout Cell, from old: borrowing GraphemeTable) {
    guard cell.isGrapheme else { return }
    exclusiveTail = .max
    let entry = old.entries[Int(cell.glyph)]
    let lo = Int(entry >> 32)
    let n = Int(entry & 0xFFFF_FFFF)
    let start = scalars.count
    scalars.append(old.scalars, from: lo, count: n)
    entries.append(UInt64(start) << 32 | UInt64(n))
    cell.glyph = UInt32(entries.count - 1)
  }

  mutating func removeAll() {
    compactionLimit = Self.compactionThreshold
    exclusiveTail = .max
    scalars.removeAll(keepingCapacity: true)
    entries.removeAll(keepingCapacity: true)
  }
}

/// An append-only array without copy-on-write checks on each append.
///
/// The allocation extends `padding` elements past `capacity`, so a short
/// run copies between buffers as one fixed-size block once the source's
/// tail is padded. Unused capacity is otherwise never written.
package struct GrowableBuffer<Element: BitwiseCopyable>: ~Copyable {
  private var base: UnsafeMutablePointer<Element>?
  private var capacity = 0
  private(set) var count = 0
  private static var padding: Int { 8 }
  /// `count` when `padTail` last ran: valid while the two are equal.
  private var paddedCount = -1

  deinit { base?.deallocate() }

  subscript(i: Int) -> Element {
    @inline(__always)
    get {
      precondition(i >= 0 && i < count)
      return base.unsafelyUnwrapped[i]
    }
    @inline(__always)
    set {
      precondition(i >= 0 && i < count)
      base.unsafelyUnwrapped[i] = newValue
    }
  }

  var span: Span<Element> {
    @_lifetime(borrow self)
    get {
      let span = Span(
        _unsafeStart: base ?? UnsafeMutablePointer(
          bitPattern: MemoryLayout<Element>.alignment
        )!,
        count: count
      )
      return _overrideLifetime(span, borrowing: self)
    }
  }

  @inline(__always)
  mutating func append(_ element: Element) {
    if count == capacity { grow(to: count + 1) }
    base.unsafelyUnwrapped[count] = element
    count += 1
  }

  /// Initializes the `padding` elements past `count`, so that
  /// `append(_:from:count:)` may read a whole block from any element of
  /// this buffer until it next changes.
  mutating func padTail() {
    guard let base else { return }
    UnsafeMutableRawPointer(base + count)
      .initializeMemory(
        as: UInt8.self,
        repeating: 0,
        count: Self.padding * MemoryLayout<Element>.stride
      )
    paddedCount = count
  }

  /// Appends `n` elements of `other` starting at `start`.
  @inline(__always)
  mutating func append(
    _ other: borrowing GrowableBuffer<Element>,
    from start: Int,
    count n: Int
  ) {
    precondition(start >= 0 && n >= 0 && start + n <= other.count)
    guard n > 0 else { return }
    if count + n > capacity { grow(to: count + n) }
    let source = other.base.unsafelyUnwrapped + start
    let destination = base.unsafelyUnwrapped + count
    if n <= Self.padding, other.paddedCount == other.count {
      // Clusters are a few scalars long. Copy a whole block without
      // branching on the length: the padded source is initialized that
      // far, and the elements past `n` stay outside `count`.
      let bytes = Self.padding * MemoryLayout<Element>.stride
      let from = UnsafeRawPointer(source)
      let to = UnsafeMutableRawPointer(destination)
      var offset = 0
      while offset < bytes {
        to.storeBytes(
          of: from.loadUnaligned(fromByteOffset: offset, as: UInt64.self),
          toByteOffset: offset,
          as: UInt64.self
        )
        offset &+= 8
      }
    } else {
      destination.update(from: source, count: n)
    }
    count += n
  }

  /// Appends the elements of `other`, which is not part of this buffer.
  @inline(__always)
  mutating func append(contentsOf other: UnsafeBufferPointer<Element>) {
    guard let source = other.baseAddress, !other.isEmpty else { return }
    if count + other.count > capacity { grow(to: count + other.count) }
    Self.copy(other.count, from: source, to: base.unsafelyUnwrapped + count)
    count += other.count
  }

  /// Copies `n` elements between buffers that do not overlap. Clusters are
  /// a few scalars long: such runs copy as two words or vectors that may
  /// overlap each other, without a call.
  @inline(__always)
  private static func copy(
    _ n: Int,
    from source: UnsafePointer<Element>,
    to destination: UnsafeMutablePointer<Element>
  ) {
    let bytes = n &* MemoryLayout<Element>.stride
    let from = UnsafeRawPointer(source)
    let to = UnsafeMutableRawPointer(destination)
    if n == 1 {
      destination.pointee = source.pointee
    } else if bytes >= 8, bytes <= 16 {
      let head = from.loadUnaligned(as: UInt64.self)
      let tail = from.loadUnaligned(fromByteOffset: bytes &- 8, as: UInt64.self)
      to.storeBytes(of: head, as: UInt64.self)
      to.storeBytes(of: tail, toByteOffset: bytes &- 8, as: UInt64.self)
    } else if bytes > 16, bytes <= 32 {
      let head = from.loadUnaligned(as: SIMD16<UInt8>.self)
      let tail = from.loadUnaligned(
        fromByteOffset: bytes &- 16,
        as: SIMD16<UInt8>.self
      )
      to.storeBytes(of: head, as: SIMD16<UInt8>.self)
      to.storeBytes(of: tail, toByteOffset: bytes &- 16, as: SIMD16<UInt8>.self)
    } else {
      destination.update(from: source, count: n)
    }
  }

  mutating func removeAll(keepingCapacity: Bool) {
    count = 0
    if !keepingCapacity {
      base?.deallocate()
      base = nil
      capacity = 0
    }
  }

  @inline(never)
  private mutating func grow(to minimum: Int) {
    let grownCapacity = max(16, capacity * 2, minimum)
    let grown = UnsafeMutablePointer<Element>
      .allocate(capacity: grownCapacity + Self.padding)
    if let base {
      grown.update(from: base, count: count)
      base.deallocate()
    }
    capacity = grownCapacity
    base = grown
    paddedCount = -1
  }
}
