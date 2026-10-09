/// Type policies prevent the compiler from merging the ordinary and wide loops.
private protocol ScalarPrintingPolicy {
    static var enabled: Bool { get }
}

private enum ScalarPrintingDisabled: ScalarPrintingPolicy {
    static var enabled: Bool {
        false
    }
}

private enum ScalarPrintingEnabled: ScalarPrintingPolicy {
    static var enabled: Bool {
        true
    }
}

/// Cell printing, charset translation, grapheme attachment, and the batched SIMD paths.
extension TerminalState {
    // MARK: Printing

    /// Fast paths only handle the common case: full-width margins, no
    /// insert mode and no charset translation.
    @inline(__always) private var printsFast: Bool {
        !modes.contains(.insert) && cursor.printsPlain && scrollLeft == 0 && scrollRight == columns - 1
    }

    /// Bulk path for printable ASCII (0x20...0x7E).
    mutating func printASCII(_ bytes: UnsafeBufferPointer<UInt8>) {
        if !printsFast {
            for b in bytes {
                print(UInt32(b))
            }
            return
        }
        let pen = cursor.pen
        let n = bytes.count
        var i = 0
        while i < n {
            if cursor.pendingWrap {
                guard modes.contains(.autowrap) else {
                    // No autowrap: the last column keeps being overwritten.
                    writeCell(UInt32(bytes[n - 1]), .narrow)
                    break
                }
                printWrap()
            }
            let row = grid.row(cursor.y)
            var x = cursor.x
            let chunk = min(columns - x, n - i)
            let end = x + chunk
            invalidateSelection(rows: cursor.y ..< cursor.y + 1, from: x, to: end)
            // Cells before the extent may hold wide characters to split.
            let checked = min(end, grid.extent(cursor.y))
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
                if x < columns, row[x].width == 0 {
                    // The last write split a wide character.
                    row[x] = eraseCell
                }
            }
            // Past the extent every cell is blank: store whole 16-byte cells.
            if x < end {
                Self.storeASCII(bytes.baseAddress! + i, count: end - x, pen: pen, into: row + x)
                i += end - x
                x = end
            }
            finishPrintRun(at: x)
        }
        lastPrinted = UInt32(bytes[n - 1])
    }

    /// Writes ASCII cells as SIMD stores of a cell template whose first
    /// lane (the glyph) is replaced per byte.
    /// A cell as one 16-byte vector (its size is 15 bytes, stride 16).
    @inline(__always)
    static func cellVector(_ cell: Cell) -> SIMD4<UInt32> {
        var v = SIMD4<UInt32>()
        withUnsafeMutableBytes(of: &v) { $0.storeBytes(of: cell, as: Cell.self) }
        return v
    }

    @inline(__always)
    static func storeASCII(_ src: UnsafePointer<UInt8>, count: Int, pen: CellAttributes, into dst: UnsafeMutablePointer<Cell>) {
        let base = cellVector(Cell(glyph: 0, attributes: pen, width: 1))
        let raw = UnsafeMutableRawPointer(dst)
        // Amortize the loop branch over four cells in long runs.
        let grouped = count & ~3
        var k = 0
        while k < grouped {
            var first = base, second = base, third = base, fourth = base
            first[0] = UInt32(src[k])
            second[0] = UInt32(src[k &+ 1])
            third[0] = UInt32(src[k &+ 2])
            fourth[0] = UInt32(src[k &+ 3])
            raw.storeBytes(of: first, toByteOffset: k &* 16, as: SIMD4<UInt32>.self)
            raw.storeBytes(of: second, toByteOffset: (k &+ 1) &* 16, as: SIMD4<UInt32>.self)
            raw.storeBytes(of: third, toByteOffset: (k &+ 2) &* 16, as: SIMD4<UInt32>.self)
            raw.storeBytes(of: fourth, toByteOffset: (k &+ 3) &* 16, as: SIMD4<UInt32>.self)
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
    mutating func printScalars(_ scalars: UnsafeBufferPointer<UInt32>) {
        // Small or narrow prefixes use the ordinary loop. The helper still
        // validates every batched scalar's width and possible grapheme joins.
        let batchesWide = scalars.count >= 8 && scalars[0] >= 0x300 && scalars[3] >= 0x300
            && scalars[4] >= 0x300 && scalars[7] >= 0x300 && ScalarInfoTable.shared.lookup(scalars[0]) >> 5 == 2
        if batchesWide {
            if selection != nil {
                printScalars(scalars, tracksSelection: ScalarPrintingEnabled.self, batch: ScalarPrintingEnabled.self)
            } else {
                printScalars(scalars, tracksSelection: ScalarPrintingDisabled.self, batch: ScalarPrintingEnabled.self)
            }
        } else {
            if selection != nil {
                printScalars(scalars, tracksSelection: ScalarPrintingEnabled.self, batch: ScalarPrintingDisabled.self)
            } else {
                printScalars(scalars, tracksSelection: ScalarPrintingDisabled.self, batch: ScalarPrintingDisabled.self)
            }
        }
    }

    /// Specialize selection bookkeeping and wide writes independently.
    @inline(__always)
    private mutating func printScalars<SelectionPolicy: ScalarPrintingPolicy, BatchPolicy: ScalarPrintingPolicy>(
        _ scalars: UnsafeBufferPointer<UInt32>, tracksSelection _: SelectionPolicy.Type, batch _: BatchPolicy.Type,
    ) {
        if !scalars.isEmpty {
            markSearchDirty()
        }
        if !printsFast {
            for cp in scalars {
                print(cp)
            }
            return
        }
        let (narrow, wide, tail) = Self.scalarCellTemplates(cursor.pen)
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
            if Self.mayJoin(cp, after: previous, clustering: clustering, widths: widths) {
                print(cp)
                previous = scalarBeforeCursor() // a selector may have been ignored
                i += 1
                continue
            }
            if cursor.pendingWrap {
                guard autowrap else { print(cp); previous = scalarBeforeCursor(); previousKnown = true; i += 1; continue }
                printWrap()
            }
            // Write a run of narrow and wide scalars on the current row; a
            // wide scalar that does not fit goes through `print` to wrap.
            // Cells at or past the row's extent are blank, so only cells
            // before it need wide-character splitting.
            let row = grid.row(cursor.y)
            let raw = UnsafeMutableRawPointer(row)
            let clean = grid.extent(cursor.y)
            let selected = SelectionPolicy.enabled ? selectedColumns(inScreenRow: cursor.y) : nil
            var x = cursor.x
            let start = i
            // Break class of the previous scalar in this run: below U+0300
            // every scalar behaves as Other for joining purposes.
            var previousClass = 0
            var canBatchWide = true
            while i < n, x < columns {
                let c = scalars[i]
                let w: Int, cls: Int
                if c < 0x300, c != 0xA9, c != 0xAE {
                    (w, cls) = (1, 0)
                    // Other never joins Other. Latin-1 only needs the mask
                    // after a different class, such as a Prepend character.
                    if previousClass != 0, clustering, c > 0x7F, i > start,
                       graphemeTables.joinMask[previousClass] & 1 != 0 {
                        break
                    }
                } else {
                    let info = scalarInfo.lookup(c)
                    w = Int(info >> 5)
                    cls = Int(info & 0x1F)
                    // Includes the Latin-1 pictographs U+00A9/U+00AE.
                    if clustering, i > start, graphemeTables.joinMask[previousClass] >> UInt32(cls) & 1 != 0 {
                        break
                    }
                }
                if w == 0 || (w == 2 && x + 1 >= columns) {
                    break
                }
                if BatchPolicy.enabled, canBatchWide, w == 2, x >= clean, columns - x >= 8, n - i >= 4 {
                    let batch = Self.storeWideRun(
                        scalars.baseAddress! + i,
                        count: min(n - i, (columns - x) / 2),
                        into: raw + x * 16,
                        head: wide,
                        tail: tail,
                        clustering: clustering,
                    )
                    if batch.count > 0 {
                        previousClass = batch.lastClass
                        x += batch.count * 2
                        i += batch.count
                        continue
                    }
                    canBatchWide = false
                }
                previousClass = cls
                if x < clean {
                    if row[x].width != 1 {
                        splitWide(row, x, replacingWidth: w)
                    }
                    if w == 2, row[x + 1].width != 1 {
                        splitWide(row, x + 1, replacingWidth: 0)
                    }
                }
                var cell = w == 1 ? narrow : wide
                cell[0] = c
                raw.storeBytes(of: cell, toByteOffset: x &* 16, as: SIMD4<UInt32>.self)
                if w == 2 {
                    raw.storeBytes(of: tail, toByteOffset: (x &+ 1) &* 16, as: SIMD4<UInt32>.self)
                }
                x += w
                i += 1
            }
            if i > start {
                if let selected, selected.overlaps(cursor.x ..< x) {
                    setSelection(nil)
                }
                lastPrinted = scalars[i - 1]
                previous = scalars[i - 1]
                previousKnown = true
            }
            if x == cursor.x, i < n, !cursor.pendingWrap {
                print(scalars[i]) // wide scalar at the last column, or a joiner
                previous = scalarBeforeCursor()
                previousKnown = true
                i += 1
                continue
            }
            finishPrintRun(at: x)
        }
    }

    /// Reuse the current pen for narrow cells, wide heads and spacer tails.
    @inline(__always)
    private static func scalarCellTemplates(_ pen: CellAttributes) -> (SIMD4<UInt32>, SIMD4<UInt32>, SIMD4<UInt32>) {
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
        var i = 0, previousClass = 0
        while count - i >= 4 {
            let c0 = scalars[i], c1 = scalars[i + 1], c2 = scalars[i + 2], c3 = scalars[i + 3]
            let a = info.lookup(c0), b = info.lookup(c1), c = info.lookup(c2), d = info.lookup(c3)
            // Widths are 0...2: every entry must carry the width-2 bit.
            guard (a & b & c & d) & 0x60 == 0x40 else { break }
            let cls0 = Int(a & 0x1F), cls1 = Int(b & 0x1F), cls2 = Int(c & 0x1F), cls3 = Int(d & 0x1F)
            if clustering,
               (i > 0 && masks[previousClass] >> UInt32(cls0) & 1 != 0)
               || masks[cls0] >> UInt32(cls1) & 1 != 0
               || masks[cls1] >> UInt32(cls2) & 1 != 0
               || masks[cls2] >> UInt32(cls3) & 1 != 0 {
                break
            }
            var first = head, second = head, third = head, fourth = head
            first[0] = c0
            second[0] = c1
            third[0] = c2
            fourth[0] = c3
            let destination = output + i * 32
            destination.storeBytes(of: first, as: SIMD4<UInt32>.self)
            destination.storeBytes(of: tail, toByteOffset: 16, as: SIMD4<UInt32>.self)
            destination.storeBytes(of: second, toByteOffset: 32, as: SIMD4<UInt32>.self)
            destination.storeBytes(of: tail, toByteOffset: 48, as: SIMD4<UInt32>.self)
            destination.storeBytes(of: third, toByteOffset: 64, as: SIMD4<UInt32>.self)
            destination.storeBytes(of: tail, toByteOffset: 80, as: SIMD4<UInt32>.self)
            destination.storeBytes(of: fourth, toByteOffset: 96, as: SIMD4<UInt32>.self)
            destination.storeBytes(of: tail, toByteOffset: 112, as: SIMD4<UInt32>.self)
            previousClass = cls3
            i += 4
        }
        return (i, previousClass)
    }

    /// General path for one printable scalar (Ghostty `Terminal.print`).
    mutating func print(_ c: UInt32) {
        // A single shift applies to this scalar even if it joins a cell or
        // is discarded. Keep it available to writeCell until printing ends.
        defer { cursor.singleShift = nil }
        let rightLimit = cursor.x > scrollRight ? columns : scrollRight + 1
        if c > 0x7F, modes.contains(.graphemeCluster), printJoining(c, rightLimit: rightLimit) {
            return
        }
        // Regional indicators pair into a two-column flag.
        let width = c <= 0xFF ? 1 : (0x1F1E6 ... 0x1F1FF).contains(c) ? 2 : Int(widths.lookup(c))
        if width == 0 {
            attachZeroWidth(c)
            return
        }
        lastPrinted = c
        if cursor.pendingWrap, modes.contains(.autowrap) {
            printWrap()
        }
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
            writeCell(0, .narrow) // a wide character never fits one column
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
        if cell.width == 2 {
            return .wide
        }
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
        case .decSpecialGraphics: return (0x5F ... 0x7E).contains(c) ? Self.decSpecial[Int(c - 0x5F)] : c
        }
    }

    /// Writes one cell at the cursor (Ghostty `printCell`), clearing the
    /// other half of a wide character it replaces.
    mutating func writeCell(_ c: UInt32, _ kind: CellKind) {
        invalidateSelection(rows: cursor.y ..< cursor.y + 1, from: cursor.x, to: cursor.x + 1)
        let glyph = cursor.printsPlain ? c : mapCharset(c)
        let row = grid.row(cursor.y)
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
            glyph: kind == .narrow || kind == .wide ? glyph : 0, attributes: attributes,
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
        let above = grid.row(cursor.y - 1)
        guard above[columns - 1].flags.contains(.spacerHead) else { return }
        above[columns - 1].attributes.flags.remove(.spacerHead)
        damage.insert(row: cursor.y - 1)
    }

    /// Whether `c` might extend the cluster ending in `previous` (nil:
    /// unknown), so the batched path must hand it to `print`.
    @inline(__always)
    private static func mayJoin(_ c: UInt32, after previous: UInt32?, clustering: Bool, widths: WidthTable) -> Bool {
        if c <= 0x7F {
            return false
        } // Ghostty's intentional ASCII boundary
        guard clustering else { return widths.lookup(c) == 0 }
        guard let previous else { return true }
        return GraphemeBreak.mayJoin(previous: previous, c)
    }

    /// The last scalar of the cell a joining scalar would attach to, or a
    /// stand-in that joins at least as readily (nil: unknown).
    /// Inlining avoids copying the terminal state for read-only batch lookups.
    @inline(__always)
    private func scalarBeforeCursor() -> UInt32? {
        let row = grid.row(cursor.y)
        var x: Int = if !modes.contains(.autowrap), cursor.x == columns - 1 {
            Self.hasText(row[cursor.x]) ? cursor.x : cursor.x - 1
        } else {
            cursor.pendingWrap ? cursor.x : cursor.x - 1
        }
        if x >= 0, Self.kind(of: row[x]) == .spacerTail {
            x -= 1
        }
        guard x >= 0 else { return 0x20 } // nothing to join
        let cell = row[x]
        if cell.isGrapheme {
            return graphemes.lastScalar(of: cell)
        }
        return cell.glyph == 0 ? 0x20 : cell.glyph
    }

    /// Zero-width scalar outside a grapheme cluster (mode 2027 off, or no
    /// previous cell): attaches to the cell before the cursor.
    private mutating func attachZeroWidth(_ c: UInt32) {
        if modes.contains(.graphemeCluster) {
            return
        }
        // Printing the rightmost cell sets pendingWrap even when autowrap
        // is disabled: the cursor still names the cell just printed.
        let left = cursor.pendingWrap ? 0 : 1
        if cursor.x == 0, left == 1 {
            return
        }
        let row = grid.row(cursor.y)
        var x = cursor.x - left
        if Self.kind(of: row[x]) == .spacerTail, x > 0 {
            x -= 1
        }
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
    mutating func appendGrapheme(_ c: UInt32, x: Int, y: Int) {
        let row = grid.row(y)
        if row[x].isGrapheme, graphemes.scalarCount(row[x].glyph) > Self.graphemeMaxLength {
            return
        }
        let id = graphemes.appending(c, to: row[x])
        invalidateSelection(rows: y ..< y + 1, from: x, to: x + 1)
        row[x].glyph = id
        row[x].attributes.flags.insert(.grapheme)
        damage.insert(row: y)
        // Entries are append-only, so the table only grows here; checking on
        // every append bounds it on either screen, scrolling or not.
        if graphemes.needsCompaction {
            compactGraphemes()
        }
    }

    /// Ghostty's `grapheme_max_len`: scalars joined to a cell's base.
    static let graphemeMaxLength = 64

    /// Clears the other half of a wide character being overwritten at `x`.
    @inline(__always)
    private mutating func splitWide(_ row: UnsafeMutablePointer<Cell>, _ x: Int, replacingWidth width: Int) {
        let cell = row[x]
        if cell.width == 2, x + 1 < columns {
            row[x + 1] = eraseCell
        } else if cell.width == 0, x > 0 {
            row[x - 1] = eraseCell
        }
        if Int(cell.width) != width {
            clearSpacerHeadAbove(x)
        }
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
