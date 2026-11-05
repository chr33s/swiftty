/// Keep ordinary and wide loops separate during compiler specialization.
private protocol ScalarPrintingPolicy { static var enabled: Bool { get } }

private enum ScalarPrintingDisabled: ScalarPrintingPolicy {
  static var enabled: Bool { false }
}

private enum ScalarPrintingEnabled: ScalarPrintingPolicy {
  static var enabled: Bool { true }
}

/// Cell printing, charset translation, grapheme attachment, and the batched SIMD paths.
extension TerminalState {
  // MARK: Printing

  /// Fast paths only handle the common case: full-width margins, no
  /// insert mode and no charset translation.
  @inline(__always)
  private var printsFast: Bool {
    !modes.contains(.insert) && cursor.printsPlain && scrollLeft == 0
      && scrollRight == columns - 1
  }

  /// Bulk path for printable ASCII (0x20...0x7E).
  mutating func printASCII(_ bytes: UnsafeBufferPointer<UInt8>) {
    if !printsFast {
      resolveDeferredClears()
      for b in bytes { print(UInt32(b)) }
      return
    }
    let pen = cursor.pen
    let n = bytes.count
    var i = 0
    while i < n {
      if cursor.pendingWrap {
        guard modes.contains(.autowrap) else {
          // No autowrap: the last column keeps being overwritten.
          resolveDeferredClears()
          writeCell(UInt32(bytes[n - 1]), .narrow)
          break
        }
        printWrap()
      }
      let row = grid._unsafeRow(cursor.y)
      var x = cursor.x
      let chunk = min(columns - x, n - i)
      let end = x + chunk
      invalidateSelection(rows: cursor.y ..< cursor.y + 1, from: x, to: end)
      grid.prepareWrite(cursor.y, from: x)
      // Cells before the extent may hold wide characters to split.
      let extent = grid.extent(cursor.y)
      let checked = min(end, extent)
      if x < checked {
        // Overwriting the first half of a wide character at the
        // chunk's edge orphans its tail; other cells are rewritten.
        if row[x].width == 0 || (x <= 1 && row[x].width == 2) {
          writeCell(UInt32(bytes[i]), .narrow)
          x += 1
          i += 1
        }
        while x < checked {
          row[x] = Cell(glyph: UInt32(bytes[i]), attributes: pen, width: 1)
          x += 1
          i += 1
        }
        if x < extent, row[x].width == 0 {
          // The last write split a wide character.
          row[x] = eraseCell
        }
      }
      if x < end {
        Self.storeASCII(
          bytes.baseAddress! + i,
          count: end - x,
          pen: pen,
          into: row + x
        )
        i += end - x
        x = end
      }
      finishPrintRun(at: x)
    }
    lastPrinted = UInt32(bytes[n - 1])
  }

  /// A cell as a 16-byte SIMD template; its 15-byte value leaves one padding
  /// byte.
  @inline(__always)
  static func cellVector(_ cell: Cell) -> SIMD4<UInt32> {
    var v = SIMD4<UInt32>()
    withUnsafeMutableBytes(of: &v) { $0.storeBytes(of: cell, as: Cell.self) }
    return v
  }

  @inline(__always)
  static func storeASCII(
    _ src: UnsafePointer<UInt8>,
    count: Int,
    pen: CellAttributes,
    into dst: UnsafeMutablePointer<Cell>
  ) {
    let base = cellVector(Cell(glyph: 0, attributes: pen, width: 1))
    let raw = UnsafeMutableRawPointer(dst)
    // Amortize the loop branch over four cells in long runs.
    let grouped = count & ~3
    var k = 0
    while k < grouped {
      var first = base
      var second = base
      var third = base
      var fourth = base
      first[0] = UInt32(src[k])
      second[0] = UInt32(src[k &+ 1])
      third[0] = UInt32(src[k &+ 2])
      fourth[0] = UInt32(src[k &+ 3])
      raw.storeBytes(of: first, toByteOffset: k &* 16, as: SIMD4<UInt32>.self)
      raw.storeBytes(
        of: second,
        toByteOffset: (k &+ 1) &* 16,
        as: SIMD4<UInt32>.self
      )
      raw.storeBytes(
        of: third,
        toByteOffset: (k &+ 2) &* 16,
        as: SIMD4<UInt32>.self
      )
      raw.storeBytes(
        of: fourth,
        toByteOffset: (k &+ 3) &* 16,
        as: SIMD4<UInt32>.self
      )
      k &+= 4
    }
    for k in grouped ..< count {
      var cell = base
      cell[0] = UInt32(src[k])
      raw.storeBytes(of: cell, toByteOffset: k &* 16, as: SIMD4<UInt32>.self)
    }
  }

  /// Batched path for a run of printable scalars (mixed ASCII/UTF-8).
  /// Narrow and wide scalars that cannot join the previous cluster are
  /// written inline; anything else defers to `print`.
  ///
  /// Like `printASCII`, sequential writes may run over rows whose deferred
  /// clears are pending: the inline writer reads no cell at or past a row's
  /// extent, and resolves the clears before any fallback reads cells.
  mutating func printScalars(_ scalars: UnsafeBufferPointer<UInt32>) {
    if selection != nil {
      printScalars(scalars, tracksSelection: ScalarPrintingEnabled.self)
    } else {
      printScalars(scalars, tracksSelection: ScalarPrintingDisabled.self)
    }
  }

  /// Specialize selection bookkeeping.
  @inline(__always)
  private mutating func printScalars<SelectionPolicy: ScalarPrintingPolicy>(
    _ scalars: UnsafeBufferPointer<UInt32>,
    tracksSelection _: SelectionPolicy.Type
  ) {
    if !scalars.isEmpty { markSearchDirty() }
    if !printsFast || selection != nil {
      resolveDeferredClears()
      if !printsFast {
        for cp in scalars { print(cp) }
        return
      }
    }
    let autowrap = modes.contains(.autowrap)
    let clustering = modes.contains(.graphemeCluster)
    let widths = widths
    let graphemeTables = GraphemeBreak.tables
    let scalarInfo = ScalarInfoTable.shared
    let columns = columns
    let n = scalars.count
    var i = 0
    // Last scalar of the cell before the cursor, looked up only when a
    // scalar that could join it arrives.
    var previous: UInt32?
    var previousKnown = false
    while i < n {
      let cp = scalars[i]
      if cp > 0x7F, !previousKnown {
        previous = scalarBeforeCursor()
        previousKnown = true
      }
      if Self.mayJoin(
        cp,
        after: previous,
        clustering: clustering,
        widths: widths
      ) {
        i += printJoiningExtend(scalars, at: i)
        previous = scalarBeforeCursor()  // a selector may have been ignored
        continue
      }
      if cursor.pendingWrap {
        // Without autowrap the last column is overwritten. A scalar with
        // no width never wraps the line: `print` attaches or drops it.
        guard autowrap, cp < 0x300 || scalarInfo.lookup(cp) >> 5 != 0 else {
          resolveDeferredClears()
          print(cp);
          previous = scalarBeforeCursor();
          previousKnown = true;
          i += 1;
          continue
        }
        printWrap()
      }
      // Write a run of narrow and wide scalars on the current row; a
      // wide scalar that does not fit goes through `print` to wrap.
      // Cells at or past the row's extent are blank, so only cells
      // before it need wide-character splitting.
      let row = grid._unsafeRow(cursor.y)
      let raw = UnsafeMutableRawPointer(row)
      grid.prepareWrite(cursor.y, from: cursor.x)
      let clean = grid.extent(cursor.y)
      let selected =
        SelectionPolicy.enabled ? selectedColumns(inScreenRow: cursor.y) : nil
      var x = cursor.x
      let start = i
      // Break class of the previous scalar in this run: below U+0300
      // every scalar behaves as Other for joining purposes.
      var previousClass = GraphemeBreak.noClass
      // Index of the last scalar that started a cell.
      var lastBase = -1
      // The last scalar taken was a selector its cluster ignored.
      var selectorIgnored = false
      if x >= clean, x < columns - 1 {
        (i, x, lastBase, selectorIgnored) = printFresh(
          scalars,
          from: i,
          row: row,
          column: x,
          clustering: clustering,
          previousClass: &previousClass
        )
      }
      // Cells that hold content, and the last column.
      let rewriteStart = i
      let (narrow, wide, tail) =
        i < n && x < columns
        ? Self.scalarCellTemplates(cursor.pen)
        : (SIMD4<UInt32>(), SIMD4<UInt32>(), SIMD4<UInt32>())
      while i < n, x < columns {
        let c = scalars[i]
        let w: Int
        let cls: Int
        if c < 0x300, c != 0xA9, c != 0xAE {
          (w, cls) = (1, 0)
          // Other never joins Other. Latin-1 only needs the mask
          // after a different class, such as a Prepend character.
          if previousClass != 0, clustering, c > 0x7F, i > start,
            graphemeTables.joinMask[previousClass] & 1 != 0
          {
            break
          }
        } else {
          let info = scalarInfo.lookup(c)
          w = Int(info >> 5)
          cls = Int(info & 0x1F)
          // Includes the Latin-1 pictographs U+00A9/U+00AE.
          if clustering, i > start,
            graphemeTables.joinMask[previousClass] >> UInt32(cls) & 1 != 0
          {
            break
          }
        }
        if w == 0 || (w == 2 && x + 1 >= columns) { break }
        previousClass = cls
        if x < clean {
          splitWide(beforeStoring: w, column: x, row: row, clean: clean)
        }
        var cell = w == 1 ? narrow : wide
        cell[0] = c
        raw.storeBytes(of: cell, toByteOffset: x &* 16, as: SIMD4<UInt32>.self)
        if w == 2 {
          raw.storeBytes(
            of: tail,
            toByteOffset: (x &+ 1) &* 16,
            as: SIMD4<UInt32>.self
          )
        }
        x += w
        i += 1
      }
      if i > rewriteStart { lastBase = i - 1 }
      if i > start {
        if let selected, selected.overlaps(cursor.x ..< x) { setSelection(nil) }
        lastPrinted = scalars[lastBase]
        previous = scalars[i - 1]
        previousKnown = !selectorIgnored
      }
      if x == cursor.x, i < n, !cursor.pendingWrap {
        resolveDeferredClears()
        print(scalars[i])  // wide scalar at the last column, or a joiner
        previous = scalarBeforeCursor()
        previousKnown = true
        i += 1
        continue
      }
      finishPrintRun(at: x)
    }
  }

  /// Writes scalars from `start` onto the blank cells of `row` from
  /// `column`, which is before the last column. Bases are stored without
  /// reading the row. Scalars that join a base stored here are appended to
  /// its cluster as a group, as `printJoining` would one at a time. Stops
  /// at the last column, at a zero-width scalar that joins nothing, and at
  /// a cluster at its length limit, which `print` handles.
  ///
  /// Returns the next scalar and column, the last base's index, and
  /// whether a cluster ignored a selector. `previousClass` becomes the
  /// break class the next scalar follows (`noClass`: it starts a cell).
  @inline(never)
  private mutating func printFresh(
    _ scalars: UnsafeBufferPointer<UInt32>,
    from start: Int,
    row: UnsafeMutablePointer<Cell>,
    column: Int,
    clustering: Bool,
    previousClass: inout Int
  ) -> (i: Int, x: Int, lastBase: Int, selectorIgnored: Bool) {
    let p = scalars.baseAddress.unsafelyUnwrapped
    let n = scalars.count
    let raw = UnsafeMutableRawPointer(row)
    let info = ScalarInfoTable.shared
    let tables = GraphemeBreak.tables
    let masks = UnsafePointer(
      (clustering ? tables.joinMask : tables.noJoinMask).baseAddress
        .unsafelyUnwrapped
    )
    let limit = columns - 1
    let pen = cursor.pen
    var tailPen = pen
    tailPen.flags.insert(.spacerTail)
    let tailCell = Cell(glyph: 0, attributes: tailPen, width: 0)
    let store = BaseStore(
      info: info,
      masks: masks,
      limit: limit,
      head: Self.cellWords(Cell(glyph: 0, attributes: pen, width: 0)),
      tail: Self.cellWords(tailCell)
    )
    assert(Self.cellWords(.blank).1 == 1 << Self.cellWidthShift)
    var i = start
    var x = column
    var lastBase = -1
    // Column of the last base, and of the spacer a narrow base leaves in
    // the next cell: the next base replaces it, or a blank at the end.
    var baseColumn = column - 2
    var stray = -1
    var following = GraphemeBreak.noClass
    var canBatchWide = true
    var appended = false
    var selectorIgnored = false
    while i < n, x < limit {
      let c = p[i]
      let packed = info.lookup(c)
      if masks[following] >> UInt32(packed & 0x1F) & 1 != 0, c > 0x7F {
        let joined = joinFresh(
          p,
          from: i,
          to: n,
          base: row + baseColumn,
          after: following,
          tail: tailCell
        )
        i += joined.count
        following = joined.nextClass
        if joined.flags != 0 || row[baseColumn].isGrapheme {
          appended = true
          let width = Int(row[baseColumn].width)
          if joined.flags & Self.joinNarrowed != 0 {
            // The cell after the base held its tail: it stays in use.
            grid.extend(cursor.y, to: baseColumn + 2)
            invalidateSelection(
              rows: cursor.y ..< cursor.y + 1,
              from: baseColumn,
              to: baseColumn + 2
            )
            stray = -1
          }
          if width == 2 { stray = -1 }
          x = baseColumn + width
          if joined.flags & Self.joinIgnoredSelector != 0 {
            selectorIgnored = true
          }
          if joined.flags & Self.joinDeferred != 0 { break }
        }
        continue
      }
      let w = Int(packed >> 5)
      if w == 0 { break }
      if w == 2, canBatchWide, n - i >= 4, limit - x >= 7 {
        let (_, wide, tail) = Self.scalarCellTemplates(pen)
        let batch = Self.storeWideRun(
          p + i,
          count: min(n - i, (limit + 1 - x) / 2),
          into: raw + x * 16,
          head: wide,
          tail: tail,
          clustering: clustering,
        )
        if batch.count > 0 {
          following = batch.lastClass
          x += batch.count * 2
          i += batch.count
          lastBase = i - 1
          baseColumn = x - 2
          stray = -1
          selectorIgnored = false
          continue
        }
        canBatchWide = false
      }
      // Stores this scalar at least.
      (i, x) = Self.storeBases(
        p,
        from: i,
        to: n,
        into: raw,
        column: x,
        batchingWide: canBatchWide,
        store
      )
      lastBase = i - 1
      let last = info.lookup(p[lastBase])
      following = Int(last & 0x1F)
      baseColumn = x - Int(last >> 5)
      stray = last >> 5 == 1 ? x : -1
      selectorIgnored = false
    }
    if stray >= 0 { row[stray] = .blank }
    if appended, graphemes.needsCompaction {
      // Resolving clears blanks from the extent: cover this run first.
      grid.extend(cursor.y, to: x)
      resolveDeferredClears()
      compactGraphemes()
    }
    previousClass = following
    return (i, x, lastBase, selectorIgnored)
  }

  /// The pen and tables `storeBases` writes with.
  private struct BaseStore {
    let info: ScalarInfoTable
    let masks: UnsafePointer<UInt32>
    /// The last column.
    let limit: Int
    /// The pen's cell with no glyph and no width, and its spacer.
    let head: (UInt64, UInt64)
    let tail: (UInt64, UInt64)
  }

  /// Where `Cell.width`, the top two bits of the cell, lies in its second
  /// word.
  private static var cellWidthShift: UInt64 { 62 }

  /// Stores a cell for the scalar at `start`, which has a width and joins
  /// nothing, and for each one after it, stopping before one that may join
  /// its predecessor, has no width, or (with `batchingWide`) starts a run
  /// for `storeWideRun`, and at the last column. The cell after a narrow
  /// base is left holding a spacer.
  ///
  /// A leaf with its state in registers: the width selects no branch.
  @inline(never)
  private static func storeBases(
    _ p: UnsafePointer<UInt32>,
    from start: Int,
    to n: Int,
    into row: UnsafeMutableRawPointer,
    column: Int,
    batchingWide: Bool,
    _ store: borrowing BaseStore
  ) -> (i: Int, x: Int) {
    let info = store.info
    let masks = store.masks
    let limit = store.limit
    let (headLow, headHigh) = store.head
    let (tailLow, tailHigh) = store.tail
    // The width that ends the loop for a batch: none without batching.
    let batchWidth = batchingWide ? 2 : 3
    var i = start
    var x = column
    var mask: UInt32 = 0
    var first = true
    while i < n, x < limit {
      let c = p[i]
      let packed = UInt32(info.lookup(c))
      let cls = packed & 0x1F
      if mask &>> cls & 1 != 0, c > 0x7F { break }
      let w = Int(packed &>> 5)
      if w == 0 { break }
      if w == batchWidth, !first, n &- i >= 4, limit &- x >= 7 { break }
      first = false
      let cell = row + x &* 16
      // A head is the pen with a glyph, at offset 0, and a width.
      cell.storeBytes(of: headLow | UInt64(c), as: UInt64.self)
      cell.storeBytes(
        of: headHigh | UInt64(truncatingIfNeeded: w) &<< cellWidthShift,
        toByteOffset: 8,
        as: UInt64.self
      )
      cell.storeBytes(of: tailLow, toByteOffset: 16, as: UInt64.self)
      cell.storeBytes(of: tailHigh, toByteOffset: 24, as: UInt64.self)
      mask = masks[Int(cls)]
      x &+= w
      i &+= 1
    }
    return (i, x)
  }

  /// `joinFresh` left a scalar to `print`: its cluster is at its limit.
  private static let joinDeferred = 1
  /// `joinFresh` dropped a selector, as `printJoining` ignores one after
  /// a scalar that has no emoji variation.
  private static let joinIgnoredSelector = 2
  /// `joinFresh` narrowed a wide cluster.
  private static let joinNarrowed = 4

  /// Appends the scalars from `start` that join the cluster of `base`, a
  /// cell holding one scalar of class `previousClass` with blank cells
  /// after it. Follows the break state from that scalar and applies each
  /// joined scalar's width effect, as `printJoining` does one scalar at
  /// a time; `tail` is the spacer for a cluster that becomes wide.
  ///
  /// Returns the scalars taken, `join...` flags, and the class the next
  /// scalar follows (`noClass`: it starts a cell).
  @inline(never)
  private mutating func joinFresh(
    _ p: UnsafePointer<UInt32>,
    from start: Int,
    to n: Int,
    base: UnsafeMutablePointer<Cell>,
    after previousClass: Int,
    tail: Cell
  ) -> (count: Int, flags: Int, nextClass: Int) {
    let tables = GraphemeBreak.tables
    let classes = GraphemeBreak.Property.count
    var state = 0
    var g1 = previousClass
    // Last scalar kept in the cluster, and how many joined its base.
    var previous = base.pointee.glyph
    var kept = 0
    var wide = base.pointee.width == 2
    var j = start
    // First scalar taken but not yet stored.
    var pending = start
    var flags = 0
    while j < n {
      let scalar = p[j]
      guard scalar > 0x7F else { break }
      let properties = tables.props(scalar)
      let g2 = Int(properties & 0x1F)
      let step = tables.breaks[(state &* classes &+ g1) &* classes &+ g2]
      if step & 1 != 0 { break }
      if kept == Self.graphemeMaxLength {
        flags |= Self.joinDeferred
        break
      }
      // Marks and joiners add no width; an emoji joins a wide base.
      if scalar &>> 1 == 0xFE0E &>> 1
        || (properties & GraphemeBreak.zeroInGraphemeBit == 0 && !wide)
      {
        let effect = Self.applyWidthEffect(
          of: scalar,
          after: previous,
          to: base,
          tail: tail
        )
        wide = base.pointee.width == 2
        flags |= effect
        if effect == Self.joinIgnoredSelector {
          // Dropped: the cluster and its break state stay as they were.
          storeJoined(p + pending, count: j &- pending, in: base)
          j &+= 1
          pending = j
          continue
        }
      }
      state = Int(step &>> 1)
      g1 = g2
      previous = scalar
      kept &+= 1
      j &+= 1
    }
    storeJoined(p + pending, count: j &- pending, in: base)
    if kept > 0 {
      graphemes.recordBreakState(
        GraphemeBreak.State(raw: UInt8(truncatingIfNeeded: state)),
        after: base.pointee.glyph
      )
    }
    let deferred = flags & Self.joinDeferred != 0
    return (j - start, flags, deferred ? g1 : GraphemeBreak.noClass)
  }

  /// `GraphemeBreak.widthEffect` of `scalar` joining the cluster of `base`
  /// after `previous`, applied to the cell and the one after it. Returns
  /// `joinIgnoredSelector`, `joinNarrowed` or zero.
  @inline(never)
  private static func applyWidthEffect(
    of scalar: UInt32,
    after previous: UInt32,
    to base: UnsafeMutablePointer<Cell>,
    tail: Cell
  ) -> Int {
    switch GraphemeBreak.widthEffect(previous: previous, scalar) {
    case .ignore: return joinIgnoredSelector
    case .noChange: return 0
    case .wide:
      if base.pointee.width != 2 {
        base.pointee.width = 2
        (base + 1).pointee = tail
      }
      return 0
    case .narrow:
      guard base.pointee.width == 2 else { return 0 }
      base.pointee.width = 1
      (base + 1).pointee = narrowed((base + 1).pointee)
      return joinNarrowed
    }
  }

  /// Appends `count` scalars to the cluster of `cell`.
  @inline(never)
  private mutating func storeJoined(
    _ scalars: UnsafePointer<UInt32>,
    count: Int,
    in cell: UnsafeMutablePointer<Cell>
  ) {
    guard count > 0 else { return }
    let joined = UnsafeBufferPointer(start: scalars, count: count)
    cell.pointee.glyph =
      cell.pointee.isGrapheme
      ? graphemes.appending(contentsOf: joined, to: cell.pointee)
      : graphemes.insert(base: cell.pointee.glyph, joined: joined)
    cell.pointee.attributes.flags.insert(.grapheme)
  }

  /// A cell as two little-endian words.
  @inline(__always)
  private static func cellWords(_ cell: Cell) -> (UInt64, UInt64) {
    let v = unsafeBitCast(cellVector(cell), to: SIMD2<UInt64>.self)
    return (v[0], v[1])
  }

  /// Clears the other halves of wide characters a `width` store at
  /// `column`, before the row's clean extent, would orphan.
  private mutating func splitWide(
    beforeStoring width: Int,
    column x: Int,
    row: UnsafeMutablePointer<Cell>,
    clean: Int
  ) {
    if row[x].width != 1 { splitWide(row, x, replacingWidth: width) }
    // Cells past the extent are blank, or stale until a deferred clear.
    if width == 2, x + 1 < clean, row[x + 1].width != 1 {
      splitWide(row, x + 1, replacingWidth: 0)
    }
  }

  /// Reuse the current pen for narrow cells, wide heads and spacer tails.
  @inline(__always)
  private static func scalarCellTemplates(
    _ pen: CellAttributes
  ) -> (SIMD4<UInt32>, SIMD4<UInt32>, SIMD4<UInt32>) {
    var tailPen = pen
    tailPen.flags.insert(.spacerTail)
    return (
      Self.cellVector(Cell(glyph: 0, attributes: pen, width: 1)),
      Self.cellVector(Cell(glyph: 0, attributes: pen, width: 2)),
      Self.cellVector(Cell(glyph: 0, attributes: tailPen, width: 0)),
    )
  }

  /// Commit the row extent, damage and cursor after a batch of cell stores.
  @inline(__always)
  private mutating func finishPrintRun(at end: Int) {
    grid.extend(cursor.y, to: end)
    damage.insert(row: cursor.y)
    if end >= columns {
      cursor.x = columns - 1
      cursor.pendingWrap = true
    } else {
      cursor.x = end
    }
  }

  /// The caller has checked the first scalar's preceding cluster and
  /// guarantees blank destination cells. Stop before any possible join.
  @inline(never)
  private static func storeWideRun(
    _ scalars: UnsafePointer<UInt32>,
    count: Int,
    into output: UnsafeMutableRawPointer,
    head: SIMD4<UInt32>,
    tail: SIMD4<UInt32>,
    clustering: Bool,
  ) -> (count: Int, lastClass: Int) {
    guard count >= 4, scalars[3] >= 0x300 else { return (0, 0) }
    let info = ScalarInfoTable.shared
    let masks = GraphemeBreak.tables.joinMask
    var i = 0
    var previousClass = 0
    while count - i >= 4 {
      let c0 = scalars[i]
      let c1 = scalars[i + 1]
      let c2 = scalars[i + 2]
      let c3 = scalars[i + 3]
      let a = info.lookup(c0)
      let b = info.lookup(c1)
      let c = info.lookup(c2)
      let d = info.lookup(c3)
      // Widths are 0...2: every entry must carry the width-2 bit.
      guard (a & b & c & d) & 0x60 == 0x40 else { break }
      let cls0 = Int(a & 0x1F)
      let cls1 = Int(b & 0x1F)
      let cls2 = Int(c & 0x1F)
      let cls3 = Int(d & 0x1F)
      if clustering,
        (i > 0 && masks[previousClass] >> UInt32(cls0) & 1 != 0)
          || masks[cls0] >> UInt32(cls1) & 1 != 0
          || masks[cls1] >> UInt32(cls2) & 1 != 0
          || masks[cls2] >> UInt32(cls3) & 1 != 0
      {
        break
      }
      var first = head
      var second = head
      var third = head
      var fourth = head
      first[0] = c0
      second[0] = c1
      third[0] = c2
      fourth[0] = c3
      let destination = output + i * 32
      destination.storeBytes(of: first, as: SIMD4<UInt32>.self)
      destination.storeBytes(of: tail, toByteOffset: 16, as: SIMD4<UInt32>.self)
      destination.storeBytes(
        of: second,
        toByteOffset: 32,
        as: SIMD4<UInt32>.self
      )
      destination.storeBytes(of: tail, toByteOffset: 48, as: SIMD4<UInt32>.self)
      destination.storeBytes(
        of: third,
        toByteOffset: 64,
        as: SIMD4<UInt32>.self
      )
      destination.storeBytes(of: tail, toByteOffset: 80, as: SIMD4<UInt32>.self)
      destination.storeBytes(
        of: fourth,
        toByteOffset: 96,
        as: SIMD4<UInt32>.self
      )
      destination.storeBytes(
        of: tail,
        toByteOffset: 112,
        as: SIMD4<UInt32>.self
      )
      previousClass = cls3
      i += 4
    }
    // The last few of a run, under the same conditions.
    while i > 0, i < count {
      let scalar = scalars[i]
      let packed = info.lookup(scalar)
      guard packed & 0x60 == 0x40 else { break }
      let cls = Int(packed & 0x1F)
      if clustering, masks[previousClass] >> UInt32(cls) & 1 != 0 { break }
      var cell = head
      cell[0] = scalar
      let destination = output + i * 32
      destination.storeBytes(of: cell, as: SIMD4<UInt32>.self)
      destination.storeBytes(of: tail, toByteOffset: 16, as: SIMD4<UInt32>.self)
      previousClass = cls
      i += 1
    }
    return (i, previousClass)
  }

  /// `print`, with Extend appended directly: after a cell with text it never
  /// starts a cluster and leaves the width unchanged. ZWJ keeps `print`,
  /// whose recorded break state the emoji that follows needs.
  ///
  /// Consecutive Extend scalars join the same cell, so they are appended
  /// together. Returns the number of scalars consumed from `at`.
  @inline(never)
  private mutating func printJoiningExtend(
    _ scalars: UnsafeBufferPointer<UInt32>,
    at start: Int
  ) -> Int {
    resolveDeferredClears()
    let c = scalars[start]
    guard modes.contains(.graphemeCluster), cursor.singleShift == nil,
      Self.isSafeExtend(c)
    else {
      print(c)
      return 1
    }
    // The cell `printJoining` would join.
    let row = grid._unsafeRow(cursor.y)
    let rightLimit = cursor.x > scrollRight ? columns : scrollRight + 1
    var left: Int =
      if modes.contains(.autowrap) {
        cursor.pendingWrap ? 0 : 1
      } else if cursor.x != rightLimit - 1 { 1 } else {
        Self.hasText(row[cursor.x]) ? 0 : 1
      }
    guard cursor.x >= left else {
      print(c)
      return 1
    }
    if Self.kind(of: row[cursor.x - left]) == .spacerTail { left += 1 }
    guard cursor.x - left >= 0, Self.hasText(row[cursor.x - left]) else {
      print(c)
      return 1
    }
    var end = start + 1
    while end < scalars.count, Self.isSafeExtend(scalars[end]) { end += 1 }
    appendGraphemes(
      UnsafeBufferPointer(rebasing: scalars[start ..< end]),
      x: cursor.x - left,
      y: cursor.y
    )
    return end - start
  }

  /// Extend other than the emoji presentation selectors, which may be
  /// ignored, and that adds no width to a cluster.
  @inline(__always)
  private static func isSafeExtend(_ c: UInt32) -> Bool {
    let cls = UInt32(ScalarInfoTable.shared.lookup(c) & 0x1F)
    return GraphemeBreak.Property.extendMask >> cls & 1 != 0 && c != 0xFE0E
      && c != 0xFE0F && GraphemeBreak.isZeroInGrapheme(c)
  }

  /// General path for one printable scalar (Ghostty `Terminal.print`).
  mutating func print(_ c: UInt32) {
    // A single shift applies to this scalar even if it joins a cell or
    // is discarded. Keep it available to writeCell until printing ends.
    defer { cursor.singleShift = nil }
    let rightLimit = cursor.x > scrollRight ? columns : scrollRight + 1
    if c > 0x7F, modes.contains(.graphemeCluster),
      printJoining(c, rightLimit: rightLimit)
    {
      return
    }
    // Regional indicators pair into a two-column flag.
    let width =
      c <= 0xFF
      ? 1 : (0x1F1E6 ... 0x1F1FF).contains(c) ? 2 : Int(widths.lookup(c))
    if width == 0 {
      attachZeroWidth(c)
      return
    }
    lastPrinted = c
    if cursor.pendingWrap, modes.contains(.autowrap) { printWrap() }
    if modes.contains(.insert), cursor.x + width < columns {
      insertBlanks(width)
    }
    if width == 1 {
      writeCell(c, .narrow)
    } else if rightLimit - scrollLeft > 1 {
      if cursor.x == rightLimit - 1 {
        guard modes.contains(.autowrap) else { return }
        if rightLimit == columns {
          grid.setWrapped(cursor.y, true)
          writeCell(0, .spacerHead)
        } else {
          writeCell(0, .narrow)
        }
        printWrap()
      }
      writeCell(c, .wide)
      cursor.x += 1
      writeCell(0, .spacerTail)
    } else {
      writeCell(0, .narrow)  // a wide character never fits one column
    }
    if cursor.x == rightLimit - 1 {
      cursor.pendingWrap = true
    } else {
      cursor.x += 1
    }
  }

  enum CellKind { case narrow, wide, spacerTail, spacerHead }

  @inline(__always)
  static func kind(of cell: Cell) -> CellKind {
    if cell.width == 2 { return .wide }
    if cell.width == 0 || cell.flags.contains(.spacerTail) {
      return .spacerTail
    }
    return cell.flags.contains(.spacerHead) ? .spacerHead : .narrow
  }

  /// Translates `c` through the invoked charset, consuming a single shift.
  private mutating func mapCharset(_ c: UInt32) -> UInt32 {
    let set = cursor.charset(cursor.singleShift ?? cursor.gl)
    cursor.singleShift = nil
    switch set {
    case .ascii: return c
    case _ where c > 0xFF: return 0x20
    case .british: return c == 0x23 ? 0xA3 : c
    case .decSpecialGraphics:
      return (0x5F ... 0x7E).contains(c) ? Self.decSpecial[Int(c - 0x5F)] : c
    }
  }

  /// Writes one cell at the cursor (Ghostty `printCell`), clearing the
  /// other half of a wide character it replaces.
  mutating func writeCell(_ c: UInt32, _ kind: CellKind) {
    invalidateSelection(
      rows: cursor.y ..< cursor.y + 1,
      from: cursor.x,
      to: cursor.x + 1
    )
    let glyph = cursor.printsPlain ? c : mapCharset(c)
    let row = grid._unsafeRow(cursor.y)
    let x = cursor.x
    let old = Self.kind(of: row[x])
    if old != kind {
      switch old {
      case .wide where x < columns - 1:
        row[x + 1] = eraseCell
        clearSpacerHeadAbove(x)
      case .spacerTail where x > 0:
        row[x - 1] = eraseCell
        clearSpacerHeadAbove(x)
      default: break
      }
    }
    var attributes = cursor.pen
    switch kind {
    case .narrow, .wide: break
    case .spacerTail: attributes.flags.insert(.spacerTail)
    case .spacerHead: attributes.flags.insert(.spacerHead)
    }
    row[x] = Cell(
      glyph: kind == .narrow || kind == .wide ? glyph : 0,
      attributes: attributes,
      width: kind == .wide ? 2 : kind == .spacerTail ? 0 : 1,
    )
    grid.extend(cursor.y, to: x + 1)
    damage.insert(row: cursor.y)
  }

  /// A wide character at the start of a row lost its spacer head on the
  /// row above.
  @inline(__always)
  private mutating func clearSpacerHeadAbove(_ x: Int) {
    guard cursor.y > 0, x <= 1 else { return }
    let above = grid._unsafeRow(cursor.y - 1)
    guard above[columns - 1].flags.contains(.spacerHead) else { return }
    above[columns - 1].attributes.flags.remove(.spacerHead)
    damage.insert(row: cursor.y - 1)
  }

  /// Whether `c` might extend the cluster ending in `previous` (nil:
  /// unknown), so the batched path must hand it to `print`.
  @inline(__always)
  private static func mayJoin(
    _ c: UInt32,
    after previous: UInt32?,
    clustering: Bool,
    widths: WidthTable
  ) -> Bool {
    if c <= 0x7F { return false }  // Ghostty's intentional ASCII boundary
    guard clustering else { return widths.lookup(c) == 0 }
    guard let previous else { return true }
    return GraphemeBreak.mayJoin(previous: previous, c)
  }

  /// The last scalar of the cell a joining scalar would attach to, or a
  /// stand-in that joins at least as readily (nil: unknown).
  /// Inlining avoids copying the terminal state for read-only batch lookups.
  @inline(__always)
  private func scalarBeforeCursor() -> UInt32? {
    let row = grid._unsafeRow(cursor.y)
    var x: Int =
      if !modes.contains(.autowrap), cursor.x == columns - 1 {
        Self.hasText(row[cursor.x]) ? cursor.x : cursor.x - 1
      } else { cursor.pendingWrap ? cursor.x : cursor.x - 1 }
    // Cells past the extent are blank, or stale until a deferred clear.
    if grid.storage.hasStaleRows, x >= grid.extent(cursor.y) { return 0x20 }
    if x >= 0, Self.kind(of: row[x]) == .spacerTail { x -= 1 }
    guard x >= 0 else { return 0x20 }  // nothing to join
    let cell = row[x]
    if cell.isGrapheme { return graphemes.lastScalar(of: cell) }
    return cell.glyph == 0 ? 0x20 : cell.glyph
  }

  /// Zero-width scalar outside a grapheme cluster (mode 2027 off, or no
  /// previous cell): attaches to the cell before the cursor.
  private mutating func attachZeroWidth(_ c: UInt32) {
    if modes.contains(.graphemeCluster) { return }
    // Printing the rightmost cell sets pendingWrap even when autowrap
    // is disabled: the cursor still names the cell just printed.
    let left = cursor.pendingWrap ? 0 : 1
    if cursor.x == 0, left == 1 { return }
    let row = grid._unsafeRow(cursor.y)
    var x = cursor.x - left
    if Self.kind(of: row[x]) == .spacerTail, x > 0 { x -= 1 }
    guard row[x].glyph != 0 || row[x].isGrapheme else { return }
    if c == 0xFE0F || c == 0xFE0E {
      let base: UInt32
      if row[x].isGrapheme {
        let scalars = graphemes.scalars(row[x].glyph)
        base = scalars.isEmpty ? 0 : scalars[0]
      } else {
        base = row[x].glyph
      }
      guard GraphemeBreak.isExtendedPictographic(base) else { return }
    }
    appendGrapheme(c, x: x, y: cursor.y)
  }

  /// Appends `c` to the cluster in cell (`x`, `y`).
  /// False once the cluster is at its length limit.
  @discardableResult
  mutating func appendGrapheme(_ c: UInt32, x: Int, y: Int) -> Bool {
    let row = grid._unsafeRow(y)
    if row[x].isGrapheme,
      graphemes.scalarCount(row[x].glyph) > Self.graphemeMaxLength
    {
      return false
    }
    let id = graphemes.appending(c, to: row[x])
    invalidateSelection(rows: y ..< y + 1, from: x, to: x + 1)
    row[x].glyph = id
    row[x].attributes.flags.insert(.grapheme)
    damage.insert(row: y)
    // Entries are append-only, so the table only grows here; checking on
    // every append bounds it on either screen, scrolling or not.
    if graphemes.needsCompaction { compactGraphemes() }
    return true
  }

  /// `appendGrapheme` for each of `added`, with one cell lookup and one
  /// round of selection, damage and compaction bookkeeping. Scalars past
  /// the cluster length limit are dropped, as `appendGrapheme` drops them.
  mutating func appendGraphemes(
    _ added: UnsafeBufferPointer<UInt32>,
    x: Int,
    y: Int
  ) {
    let row = grid._unsafeRow(y)
    let cell = row[x]
    let length = cell.isGrapheme ? graphemes.scalarCount(cell.glyph) : 1
    let accepted = min(added.count, Self.graphemeMaxLength + 1 - length)
    guard accepted > 0 else { return }
    let id = graphemes.appending(
      contentsOf: UnsafeBufferPointer(rebasing: added[..<accepted]),
      to: cell
    )
    invalidateSelection(rows: y ..< y + 1, from: x, to: x + 1)
    row[x].glyph = id
    row[x].attributes.flags.insert(.grapheme)
    damage.insert(row: y)
    if graphemes.needsCompaction { compactGraphemes() }
  }

  /// Ghostty's `grapheme_max_len`: scalars joined to a cell's base.
  static let graphemeMaxLength = 64

  /// Clears the other half of a wide character being overwritten at `x`.
  @inline(__always)
  private mutating func splitWide(
    _ row: UnsafeMutablePointer<Cell>,
    _ x: Int,
    replacingWidth width: Int
  ) {
    let cell = row[x]
    if cell.width == 2, x + 1 < columns {
      row[x + 1] = eraseCell
    } else if cell.width == 0, x > 0 {
      row[x - 1] = eraseCell
    }
    if Int(cell.width) != width { clearSpacerHeadAbove(x) }
  }

  /// Wraps to the left margin of the next line (Ghostty `printWrap`);
  /// only a wrap from the last column marks the row soft-wrapped.
  mutating func printWrap() {
    if cursor.x == columns - 1 {
      markSearchDirty()
      grid.setWrapped(cursor.y, true)
    }
    index()
    cursor.x = scrollLeft
  }
}
