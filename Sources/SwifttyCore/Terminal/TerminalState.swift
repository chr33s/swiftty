import Foundation

/// Side effects the frontend must handle, drained after each parse batch.
public enum TerminalEvent: Sendable, Equatable {
    case title(String)
    case bell
    case clipboard(String)
    case workingDirectory(String)
    case exited(Int32)
}

public struct Cursor: Sendable, Equatable {
    public enum Charset: UInt8, Sendable { case ascii, decSpecialGraphics }

    public var x = 0
    public var y = 0
    /// Set after printing in the last column; the next print wraps first.
    public var pendingWrap = false
    public var pen = CellAttributes.default
    public var g0 = Charset.ascii
    public var g1 = Charset.ascii
    public var shiftedOut = false // SO selects G1 into GL

    @inline(__always) var activeCharset: Charset {
        shiftedOut ? g1 : g0
    }
}

/// Complete terminal model: screens, scrollback, cursor, modes.
///
/// Mutated only by the parser on the session's terminal queue. All cell
/// writes go straight into the grid's contiguous storage.
public struct TerminalState: ~Copyable {
    public private(set) var columns: Int
    public private(set) var rows: Int

    /// Active screen; `inactiveGrid` holds the other one.
    public private(set) var grid: Grid
    private var inactiveGrid: Grid
    var graphemes = GraphemeTable()
    private let scrollbackLimitBytes: Int

    public internal(set) var cursor = Cursor()
    private var savedPrimary = Cursor()
    private var savedAlternate = Cursor()
    private var savedPrimaryModes: Modes = .initial
    private var savedAlternateModes: Modes = .initial

    public private(set) var scrollTop = 0
    public private(set) var scrollBottom: Int
    private var tabStops: [Bool]

    public internal(set) var modes: Modes = .initial
    public internal(set) var cursorStyle = CursorStyle.block
    public internal(set) var palette: Palette
    private let defaultPalette: Palette
    // Title / working directory as raw bytes; turned into events once per
    // batch by `takeEvents()` so OSC-heavy output does not allocate per sequence.
    private var titleBytes: [UInt8] = []
    private var titleChanged = false
    private var directoryBytes: [UInt8] = []
    private var directoryChanged = false
    private var spareGraphemes = GraphemeTable()

    public var title: String {
        String(decoding: titleBytes, as: UTF8.self)
    }

    /// Rows touched since the last `takeDamage()`.
    public private(set) var damage = DamageRegion.full
    /// Lines scrolled back from the bottom (0 = following output).
    public private(set) var viewportOffset = 0

    /// Bytes to send back to the application (DSR, DA, OSC queries).
    public var output: [UInt8] = []
    public var events: [TerminalEvent] = []

    /// Pixel size of one cell, for XTWINOPS reports.
    public var cellPixelSize = (width: 0, height: 0)

    private let widths = UnicodeWidth.table
    private var lastPrinted: UInt32 = 0
    private var joinNext = false

    public init(columns: Int, rows: Int, scrollbackLimitBytes: Int = 10_000_000, palette: Palette = .standard) {
        let columns = max(1, columns), rows = max(1, rows)
        self.columns = columns
        self.rows = rows
        grid = Grid(columns: columns, rows: rows)
        self.scrollbackLimitBytes = scrollbackLimitBytes
        grid = Grid(columns: columns, rows: rows, historyLimitBytes: scrollbackLimitBytes)
        inactiveGrid = Grid(columns: columns, rows: rows)
        scrollBottom = rows - 1
        tabStops = Self.defaultTabs(columns)
        self.palette = palette
        defaultPalette = palette
        output.reserveCapacity(256)
        events.reserveCapacity(8)
        titleBytes.reserveCapacity(256)
        directoryBytes.reserveCapacity(256)
    }

    /// Pending events, with title and directory changes coalesced to the
    /// latest value.
    public mutating func takeEvents() -> [TerminalEvent] {
        guard !events.isEmpty || titleChanged || directoryChanged else { return [] }
        var out = events
        events.removeAll(keepingCapacity: true)
        if titleChanged {
            out.append(.title(title))
        }
        if directoryChanged, let url = URL(string: String(decoding: directoryBytes, as: UTF8.self)), url.isFileURL {
            out.append(.workingDirectory(url.path))
        }
        titleChanged = false
        directoryChanged = false
        return out
    }

    private static func replace(_ target: inout [UInt8], with bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        if target.elementsEqual(bytes) {
            return false
        }
        target.removeAll(keepingCapacity: true)
        target.append(contentsOf: bytes)
        return true
    }

    public var isAlternateScreen: Bool {
        modes.contains(.alternateScreen)
    }

    public mutating func takeDamage() -> DamageRegion {
        let d = damage
        damage = .none
        return d
    }

    // MARK: Printing

    /// Bulk path for printable ASCII (0x20...0x7E).
    mutating func printASCII(_ bytes: UnsafeBufferPointer<UInt8>) {
        if modes.contains(.insert) || cursor.activeCharset != .ascii || joinNext {
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
                    writeNarrow(UInt32(bytes[n - 1]), pen, x: columns - 1)
                    break
                }
                wrapLine()
            }
            let row = grid.row(cursor.y)
            var x = cursor.x
            let chunk = min(columns - x, n - i)
            let end = x + chunk
            // Cells before the extent may hold wide characters to split.
            let checked = min(end, grid.extent(cursor.y))
            while x < checked {
                if row[x].width != 1 {
                    splitWide(row, x)
                }
                row[x] = Cell(glyph: UInt32(bytes[i]), attributes: pen, width: 1)
                x += 1
                i += 1
            }
            // Past the extent every cell is blank: store whole 16-byte cells.
            if x < end {
                Self.storeASCII(bytes.baseAddress! + i, count: end - x, pen: pen, into: row + x)
                i += end - x
                x = end
            }
            grid.extend(cursor.y, to: x)
            damage.insert(row: cursor.y)
            if x >= columns {
                cursor.x = columns - 1
                cursor.pendingWrap = true
            } else {
                cursor.x = x
            }
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
        for k in 0 ..< count {
            var cell = base
            cell[0] = UInt32(src[k])
            raw.storeBytes(of: cell, toByteOffset: k &* 16, as: SIMD4<UInt32>.self)
        }
    }

    /// Batched path for a run of printable scalars (mixed ASCII/UTF-8).
    /// Narrow scalars are written inline; anything else defers to `print`.
    mutating func printScalars(_ scalars: UnsafeBufferPointer<UInt32>) {
        if modes.contains(.insert) || cursor.activeCharset != .ascii {
            for cp in scalars {
                print(cp)
            }
            return
        }
        let pen = cursor.pen
        var tailPen = pen
        tailPen.flags.insert(.spacerTail)
        let narrow = Self.cellVector(Cell(glyph: 0, attributes: pen, width: 1))
        let wide = Self.cellVector(Cell(glyph: 0, attributes: pen, width: 2))
        let tail = Self.cellVector(Cell(glyph: 0, attributes: tailPen, width: 0))
        let autowrap = modes.contains(.autowrap)
        let n = scalars.count
        var i = 0
        while i < n {
            // Zero-width and joined scalars take the general path.
            let cp = scalars[i]
            if joinNext || (cp >= 0x300 && widths.lookup(cp) == 0) {
                print(cp)
                i += 1
                continue
            }
            if cursor.pendingWrap {
                guard autowrap else { print(cp); i += 1; continue }
                wrapLine()
            }
            // Write a run of narrow and wide scalars on the current row; a
            // wide scalar that does not fit goes through `print` to wrap.
            // Cells at or past the row's extent are blank, so only cells
            // before it need wide-character splitting.
            let row = grid.row(cursor.y)
            let raw = UnsafeMutableRawPointer(row)
            let clean = grid.extent(cursor.y)
            var x = cursor.x
            while i < n, x < columns {
                let c = scalars[i]
                let w = c < 0x300 ? 1 : Int(widths.lookup(c))
                if w == 0 || (w == 2 && x + 1 >= columns) {
                    break
                }
                if x < clean {
                    if row[x].width != 1 {
                        splitWide(row, x)
                    }
                    if w == 2, row[x + 1].width == 2 {
                        splitWide(row, x + 1)
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
            if i > 0 {
                lastPrinted = scalars[i - 1]
            }
            if x == cursor.x, i < n, !cursor.pendingWrap {
                print(scalars[i]) // wide scalar at the last column
                i += 1
                continue
            }
            grid.extend(cursor.y, to: x)
            damage.insert(row: cursor.y)
            if x >= columns {
                cursor.x = columns - 1
                cursor.pendingWrap = true
            } else {
                cursor.x = x
            }
        }
    }

    /// General path for one printable scalar.
    mutating func print(_ scalar: UInt32) {
        var cp = scalar
        if cursor.activeCharset == .decSpecialGraphics, (0x5F ... 0x7E).contains(cp) {
            cp = Self.decSpecial[Int(cp - 0x5F)]
        }
        let width = cp < 0x300 ? 1 : Int(widths.lookup(cp))
        if width == 0 || joinNext {
            attach(cp)
            return
        }
        if cursor.pendingWrap, modes.contains(.autowrap) {
            wrapLine()
        }
        if width == 2, cursor.x == columns - 1 {
            guard columns > 1 else { return }
            if modes.contains(.autowrap) {
                grid[cursor.x, cursor.y] = Cell(
                    glyph: 0, attributes: CellAttributes(flags: .spacerHead), width: 1,
                )
                wrapLine()
            } else {
                cursor.x -= 1
            }
        }
        if modes.contains(.insert) {
            insertBlanks(width)
        }

        let row = grid.row(cursor.y)
        let x = cursor.x
        if row[x].width != 1 {
            splitWide(row, x)
        }
        row[x] = Cell(glyph: cp, attributes: cursor.pen, width: UInt8(width))
        if width == 2 {
            if row[x + 1].width == 2 {
                splitWide(row, x + 1)
            }
            var tail = cursor.pen
            tail.flags.insert(.spacerTail)
            row[x + 1] = Cell(glyph: 0, attributes: tail, width: 0)
        }
        grid.extend(cursor.y, to: x + width)
        damage.insert(row: cursor.y)
        lastPrinted = cp
        if x + width >= columns {
            cursor.x = columns - 1
            cursor.pendingWrap = true
        } else {
            cursor.x = x + width
            cursor.pendingWrap = false
        }
    }

    @inline(__always)
    private mutating func writeNarrow(_ glyph: UInt32, _ pen: CellAttributes, x: Int) {
        let row = grid.row(cursor.y)
        if row[x].width != 1 {
            splitWide(row, x)
        }
        row[x] = Cell(glyph: glyph, attributes: pen, width: 1)
        grid.extend(cursor.y, to: x + 1)
        damage.insert(row: cursor.y)
    }

    /// Appends a zero-width scalar to the previous cell's grapheme cluster.
    private mutating func attach(_ cp: UInt32) {
        joinNext = cp == UnicodeWidth.zeroWidthJoiner
        var x = cursor.pendingWrap ? cursor.x : cursor.x - 1
        var y = cursor.y
        if x < 0 {
            // Previous cell is at the end of the previous row if it wrapped.
            guard y > 0, grid.isWrapped(y - 1) else { return }
            y -= 1
            x = columns - 1
        }
        let row = grid.row(y)
        if row[x].width == 0, x > 0 {
            x -= 1
        }
        if row[x].flags.contains(.spacerHead), x > 0 {
            x -= 1
        }
        guard row[x].glyph != 0 || row[x].isGrapheme else { return }
        let id = graphemes.appending(cp, to: row[x])
        row[x].glyph = id
        row[x].attributes.flags.insert(.grapheme)
        damage.insert(row: y)
    }

    /// Clears the other half of a wide character being overwritten at `x`.
    @inline(__always)
    private func splitWide(_ row: UnsafeMutablePointer<Cell>, _ x: Int) {
        let cell = row[x]
        if cell.width == 2, x + 1 < columns {
            row[x + 1] = Cell.erased(background: row[x + 1].attributes.background)
        } else if cell.width == 0, x > 0 {
            row[x - 1] = Cell.erased(background: row[x - 1].attributes.background)
        }
    }

    private mutating func wrapLine() {
        grid.setWrapped(cursor.y, true)
        cursor.x = 0
        cursor.pendingWrap = false
        index()
    }

    // MARK: C0 controls

    mutating func execute(_ byte: UInt8) {
        joinNext = false
        switch byte {
        case 0x07: events.append(.bell)
        case 0x08: // BS
            if cursor.x > 0, !cursor.pendingWrap {
                cursor.x -= 1
            }
            cursor.pendingWrap = false
        case 0x09: tabForward(1)
        case 0x0A, 0x0B, 0x0C:
            index()
            if modes.contains(.linefeedNewline) {
                carriageReturn()
            }
        case 0x0D: carriageReturn()
        case 0x0E: cursor.shiftedOut = true
        case 0x0F: cursor.shiftedOut = false
        default: break
        }
    }

    private mutating func carriageReturn() {
        cursor.x = 0
        cursor.pendingWrap = false
    }

    /// IND: move down, scrolling the region at its bottom margin.
    mutating func index() {
        if cursor.y == scrollBottom {
            scrollUp(1)
        } else if cursor.y < rows - 1 {
            cursor.y += 1
        }
    }

    /// RI: move up, scrolling the region down at its top margin.
    mutating func reverseIndex() {
        if cursor.y == scrollTop {
            scrollDown(1)
        } else if cursor.y > 0 {
            cursor.y -= 1
        }
    }

    private var eraseCell: Cell {
        .erased(background: cursor.pen.background)
    }

    /// Scrolls the region up; full-screen scrolls on the primary screen
    /// feed the scrollback.
    mutating func scrollUp(_ count: Int, toScrollback: Bool = true) {
        let n = min(count, scrollBottom - scrollTop + 1)
        guard n > 0 else { return }
        if toScrollback, !isAlternateScreen, scrollTop == 0, scrollBottom == rows - 1 {
            // Rows move into history by id; no cells are copied.
            grid.scrollUpIntoHistory(count: n, fill: eraseCell)
            if viewportOffset > 0 {
                viewportOffset = min(viewportOffset + n, grid.historyCount)
            }
            if graphemes.needsCompaction {
                compactGraphemes()
            }
        } else {
            grid.scrollUp(top: scrollTop, bottom: scrollBottom, count: n, fill: eraseCell)
        }
        markScrolled()
    }

    mutating func scrollDown(_ count: Int) {
        grid.scrollDown(top: scrollTop, bottom: scrollBottom, count: count, fill: eraseCell)
        markScrolled()
    }

    private mutating func markScrolled() {
        if scrollTop == 0, scrollBottom == rows - 1 {
            damage.setFull()
        } else {
            damage.insert(rows: scrollTop ..< scrollBottom + 1)
        }
    }

    // MARK: Cursor movement

    private mutating func moveTo(column: Int, row: Int) {
        let origin = modes.contains(.origin)
        let top = origin ? scrollTop : 0
        let bottom = origin ? scrollBottom : rows - 1
        cursor.y = min(max(top + row, top), bottom)
        cursor.x = min(max(column, 0), columns - 1)
        cursor.pendingWrap = false
    }

    private mutating func moveUp(_ n: Int) {
        let limit = cursor.y >= scrollTop ? scrollTop : 0
        cursor.y = max(cursor.y - n, limit)
        cursor.pendingWrap = false
    }

    private mutating func moveDown(_ n: Int) {
        let limit = cursor.y <= scrollBottom ? scrollBottom : rows - 1
        cursor.y = min(cursor.y + n, limit)
        cursor.pendingWrap = false
    }

    private mutating func tabForward(_ n: Int) {
        var x = cursor.x
        for _ in 0 ..< n {
            x += 1
            while x < columns - 1, !tabStops[x] {
                x += 1
            }
            if x >= columns - 1 {
                x = columns - 1; break
            }
        }
        cursor.x = x
        cursor.pendingWrap = false
    }

    private mutating func tabBackward(_ n: Int) {
        var x = cursor.x
        for _ in 0 ..< n {
            x -= 1
            while x > 0, !tabStops[x] {
                x -= 1
            }
            if x <= 0 {
                x = 0; break
            }
        }
        cursor.x = x
        cursor.pendingWrap = false
    }

    // MARK: Erase / edit

    /// Erases `x0..<x1` on row `y`, widening the range over split wide chars.
    private mutating func erase(row y: Int, from x0: Int, to x1: Int) {
        guard x0 < x1 else { return }
        let row = grid.row(y)
        var lo = x0, hi = x1
        if row[lo].width == 0, lo > 0 {
            lo -= 1
        }
        if hi < columns, row[hi].width == 0 {
            hi += 1
        }
        grid.fill(row: y, from: lo, to: hi, with: eraseCell)
        if hi == columns {
            grid.setWrapped(y, false)
        }
        damage.insert(row: y)
    }

    private mutating func eraseDisplay(_ mode: Int) {
        switch mode {
        case 0:
            erase(row: cursor.y, from: cursor.x, to: columns)
            for y in cursor.y + 1 ..< rows {
                erase(row: y, from: 0, to: columns)
            }
        case 1:
            for y in 0 ..< cursor.y {
                erase(row: y, from: 0, to: columns)
            }
            erase(row: cursor.y, from: 0, to: cursor.x + 1)
        case 2:
            for y in 0 ..< rows {
                erase(row: y, from: 0, to: columns)
            }
        case 3:
            if isAlternateScreen {
                inactiveGrid.clearHistory()
            } else {
                grid.clearHistory()
            }
            viewportOffset = 0
            damage.setFull()
        default: break
        }
        cursor.pendingWrap = false
    }

    private mutating func eraseLine(_ mode: Int) {
        switch mode {
        case 0: erase(row: cursor.y, from: cursor.x, to: columns)
        case 1: erase(row: cursor.y, from: 0, to: cursor.x + 1)
        case 2: erase(row: cursor.y, from: 0, to: columns)
        default: break
        }
        cursor.pendingWrap = false
    }

    private mutating func insertBlanks(_ n: Int) {
        let row = grid.row(cursor.y)
        if row[cursor.x].width == 0 {
            splitWide(row, cursor.x)
        }
        grid.insertCells(row: cursor.y, at: cursor.x, count: n, fill: eraseCell)
        if row[columns - 1].width == 2 {
            row[columns - 1] = eraseCell
        }
        damage.insert(row: cursor.y)
    }

    private mutating func deleteChars(_ n: Int) {
        let row = grid.row(cursor.y)
        if row[cursor.x].width == 0 {
            splitWide(row, cursor.x)
        }
        let end = cursor.x + n
        if end < columns, row[end].width == 0 {
            splitWide(row, end)
        }
        grid.deleteCells(row: cursor.y, at: cursor.x, count: n, fill: eraseCell)
        damage.insert(row: cursor.y)
        cursor.pendingWrap = false
    }

    private mutating func insertLines(_ n: Int) {
        guard cursor.y >= scrollTop, cursor.y <= scrollBottom else { return }
        grid.scrollDown(top: cursor.y, bottom: scrollBottom, count: n, fill: eraseCell)
        damage.insert(rows: cursor.y ..< scrollBottom + 1)
        cursor.x = 0
        cursor.pendingWrap = false
    }

    private mutating func deleteLines(_ n: Int) {
        guard cursor.y >= scrollTop, cursor.y <= scrollBottom else { return }
        grid.scrollUp(top: cursor.y, bottom: scrollBottom, count: n, fill: eraseCell)
        damage.insert(rows: cursor.y ..< scrollBottom + 1)
        cursor.x = 0
        cursor.pendingWrap = false
    }

    // MARK: CSI

    mutating func csiDispatch(_ csi: borrowing CSISequence) {
        joinNext = false
        let marker = csi.marker, inter = csi.intermediate
        if marker == 0, inter == 0 {
            dispatchPlainCSI(csi)
            return
        }
        switch (marker, inter, csi.final) {
        case (0x3F, 0, 0x68): for i in 0 ..< csi.count {
                setDECMode(csi.value(i), true)
            } // ? h
        case (0x3F, 0, 0x6C): for i in 0 ..< csi.count {
                setDECMode(csi.value(i), false)
            } // ? l
        case (0x3F, 0, 0x4A): eraseDisplay(csi.value(0)) // DECSED
        case (0x3F, 0, 0x4B): eraseLine(csi.value(0)) // DECSEL
        case (0x3F, 0, 0x6E): // ? n
            if csi.value(0) == 6 {
                reply("\u{1B}[?\(reportedRow);\(cursor.x + 1)R")
            }
        case (0x3F, 0x24, 0x70): // DECRQM ? $ p
            let n = csi.value(0)
            let state = Modes.dec(n).map { modes.contains($0) ? 1 : 2 } ?? 0
            reply("\u{1B}[?\(n);\(state)$y")
        case (0, 0x24, 0x70): // ANSI DECRQM
            let n = csi.value(0)
            let state = Modes.ansi(n).map { modes.contains($0) ? 1 : 2 } ?? 0
            reply("\u{1B}[\(n);\(state)$y")
        case (0x3E, 0, 0x63): reply("\u{1B}[>1;10;0c") // DA2
        case (0x3E, 0, 0x71): reply("\u{1B}P>|swiftty 0.1\u{1B}\\") // XTVERSION
        case (0, 0x20, 0x71): // DECSCUSR
            let p = csi.value(0)
            cursorStyle = p <= 2 ? .block : p <= 4 ? .underline : .bar
            if p == 0 || p % 2 == 1 {
                modes.insert(.cursorBlink)
            } else {
                modes.remove(.cursorBlink)
            }
        case (0, 0x21, 0x70): softReset() // DECSTR
        default: break // unsupported: ignored
        }
    }

    private mutating func dispatchPlainCSI(_ csi: borrowing CSISequence) {
        let n = csi.param(0, default: 1)
        switch csi.final {
        case 0x40: insertBlanks(min(n, columns - cursor.x)) // ICH @
        case 0x41: moveUp(n) // CUU A
        case 0x42, 0x65: moveDown(n) // CUD B, VPR e
        case 0x43, 0x61: cursor.x = min(cursor.x + n, columns - 1); cursor.pendingWrap = false // CUF C, HPR a
        case 0x44: cursor.x = max(cursor.x - n, 0); cursor.pendingWrap = false // CUB D
        case 0x45: moveDown(n); cursor.x = 0 // CNL E
        case 0x46: moveUp(n); cursor.x = 0 // CPL F
        case 0x47, 0x60: cursor.x = min(n - 1, columns - 1); cursor.pendingWrap = false // CHA G, HPA `
        case 0x48, 0x66: moveTo(column: csi.param(1, default: 1) - 1, row: n - 1) // CUP H, HVP f
        case 0x49: tabForward(n) // CHT I
        case 0x4A: eraseDisplay(csi.value(0)) // ED J
        case 0x4B: eraseLine(csi.value(0)) // EL K
        case 0x4C: insertLines(n) // IL L
        case 0x4D: deleteLines(n) // DL M
        case 0x50: deleteChars(n) // DCH P
        case 0x53: scrollUp(n, toScrollback: false) // SU S
        case 0x54: scrollDown(n) // SD T
        case 0x58: erase(row: cursor.y, from: cursor.x, to: min(cursor.x + n, columns)); cursor.pendingWrap = false // ECH X
        case 0x5A: tabBackward(n) // CBT Z
        case 0x62: // REP b
            if lastPrinted != 0 {
                for _ in 0 ..< min(n, 65535) {
                    print(lastPrinted)
                }
            }
        case 0x63: if csi.value(0) == 0 {
                reply("\u{1B}[?62;22c")
            } // DA1
        case 0x64: // VPA d
            let origin = modes.contains(.origin)
            moveTo(column: cursor.x, row: n - 1 - (origin ? 0 : 0))
        case 0x67: // TBC g
            switch csi.value(0) {
            case 0: tabStops[cursor.x] = false
            case 3: for i in tabStops.indices {
                    tabStops[i] = false
                }
            default: break
            }
        case 0x68: for i in 0 ..< csi.count {
                setANSIMode(csi.value(i), true)
            } // SM h
        case 0x6C: for i in 0 ..< csi.count {
                setANSIMode(csi.value(i), false)
            } // RM l
        case 0x6D: selectGraphicRendition(csi) // SGR m
        case 0x6E: // DSR n
            switch csi.value(0) {
            case 5: reply("\u{1B}[0n")
            case 6: reply("\u{1B}[\(reportedRow);\(cursor.x + 1)R")
            default: break
            }
        case 0x72: // DECSTBM r
            let top = csi.param(0, default: 1) - 1
            let bottom = min(csi.param(1, default: rows), rows) - 1
            if top < bottom {
                scrollTop = top
                scrollBottom = bottom
                moveTo(column: 0, row: 0)
            }
        case 0x73: saveCursor() // SCOSC s
        case 0x74: windowOperation(csi) // XTWINOPS t
        case 0x75: restoreCursor() // SCORC u
        default: break
        }
    }

    private var reportedRow: Int {
        modes.contains(.origin) ? cursor.y - scrollTop + 1 : cursor.y + 1
    }

    private mutating func windowOperation(_ csi: borrowing CSISequence) {
        switch csi.value(0) {
        case 14:
            reply("\u{1B}[4;\(rows * cellPixelSize.height);\(columns * cellPixelSize.width)t")
        case 16: reply("\u{1B}[6;\(cellPixelSize.height);\(cellPixelSize.width)t")
        case 18: reply("\u{1B}[8;\(rows);\(columns)t")
        default: break
        }
    }

    // MARK: SGR

    private mutating func selectGraphicRendition(_ csi: borrowing CSISequence) {
        if csi.count == 0 {
            cursor.pen = .default
            return
        }
        var pen = cursor.pen
        var i = 0
        while i < csi.count {
            let p = csi.value(i)
            switch p {
            case 0: pen = .default
            case 1: pen.flags.insert(.bold)
            case 2: pen.flags.insert(.faint)
            case 3: pen.flags.insert(.italic)
            case 4:
                if csi.isSubparameter(i + 1) {
                    i += 1
                    pen.flags.remove([.underline, .doubleUnderline])
                    switch csi.value(i) {
                    case 0: break
                    case 2: pen.flags.insert(.doubleUnderline)
                    default: pen.flags.insert(.underline)
                    }
                } else {
                    pen.flags.insert(.underline)
                }
            case 5, 6: pen.flags.insert(.blink)
            case 7: pen.flags.insert(.inverse)
            case 8: pen.flags.insert(.invisible)
            case 9: pen.flags.insert(.strikethrough)
            case 21: pen.flags.insert(.doubleUnderline)
            case 22: pen.flags.remove([.bold, .faint])
            case 23: pen.flags.remove(.italic)
            case 24: pen.flags.remove([.underline, .doubleUnderline])
            case 25: pen.flags.remove(.blink)
            case 27: pen.flags.remove(.inverse)
            case 28: pen.flags.remove(.invisible)
            case 29: pen.flags.remove(.strikethrough)
            case 30 ... 37: pen.foreground = .palette(UInt8(p - 30))
            case 38: if let c = extendedColor(csi, &i) {
                    pen.foreground = c
                }
            case 39: pen.foreground = .default
            case 40 ... 47: pen.background = .palette(UInt8(p - 40))
            case 48: if let c = extendedColor(csi, &i) {
                    pen.background = c
                }
            case 49: pen.background = .default
            case 53: pen.flags.insert(.overline)
            case 55: pen.flags.remove(.overline)
            case 58: _ = extendedColor(csi, &i) // underline color: parsed, not rendered
            case 90 ... 97: pen.foreground = .palette(UInt8(p - 90 + 8))
            case 100 ... 107: pen.background = .palette(UInt8(p - 100 + 8))
            default: break
            }
            i += 1
        }
        cursor.pen = pen
    }

    /// Parses `38;5;n`, `38;2;r;g;b` and their colon forms; leaves `i` on
    /// the last consumed parameter.
    private func extendedColor(_ csi: borrowing CSISequence, _ i: inout Int) -> TerminalColor? {
        if csi.isSubparameter(i + 1) {
            var end = i + 1
            while csi.isSubparameter(end + 1) {
                end += 1
            }
            defer { i = end }
            let kind = csi.value(i + 1)
            let args = end - (i + 1)
            if kind == 5, args >= 1 {
                return .palette(UInt8(clamping: csi.value(i + 2)))
            }
            if kind == 2, args >= 3 {
                let base = end - 2 // last three are r, g, b (optional colorspace id first)
                return .rgb(
                    UInt8(clamping: csi.value(base)),
                    UInt8(clamping: csi.value(base + 1)),
                    UInt8(clamping: csi.value(base + 2)),
                )
            }
            return nil
        }
        switch csi.value(i + 1) {
        case 5:
            defer { i += 2 }
            return i + 2 < csi.count ? .palette(UInt8(clamping: csi.value(i + 2))) : nil
        case 2:
            defer { i += 4 }
            guard i + 4 < csi.count else { return nil }
            return .rgb(
                UInt8(clamping: csi.value(i + 2)),
                UInt8(clamping: csi.value(i + 3)),
                UInt8(clamping: csi.value(i + 4)),
            )
        default:
            i += 1
            return nil
        }
    }

    // MARK: Modes

    private mutating func setANSIMode(_ n: Int, _ on: Bool) {
        guard let mode = Modes.ansi(n) else { return }
        if on {
            modes.insert(mode)
        } else {
            modes.remove(mode)
        }
    }

    private mutating func setDECMode(_ n: Int, _ on: Bool) {
        switch n {
        case 1049:
            if on {
                saveCursor()
                enterAlternateScreen(clear: true)
            } else {
                leaveAlternateScreen()
                restoreCursor()
            }
            return
        case 1047:
            if on {
                enterAlternateScreen(clear: false)
            } else {
                if isAlternateScreen {
                    grid.clear(rows: 0 ..< rows, with: .blank)
                }
                leaveAlternateScreen()
            }
            return
        case 47:
            if on {
                enterAlternateScreen(clear: false)
            } else {
                leaveAlternateScreen()
            }
            return
        case 1048:
            if on {
                saveCursor()
            } else {
                restoreCursor()
            }
            return
        default: break
        }
        guard let mode = Modes.dec(n) else { return }
        if on {
            if Modes.mouseTracking.contains(mode) {
                modes.subtract(Modes.mouseTracking)
            }
            if mode == .mouseSGR || mode == .mouseUTF8 {
                modes.subtract([.mouseSGR, .mouseUTF8])
            }
            modes.insert(mode)
        } else {
            modes.remove(mode)
        }
        switch mode {
        case .origin: moveTo(column: 0, row: 0)
        case .reverseVideo, .synchronizedOutput: damage.setFull()
        default: break
        }
    }

    private mutating func enterAlternateScreen(clear: Bool) {
        guard !isAlternateScreen else { return }
        swap(&grid, &inactiveGrid)
        modes.insert(.alternateScreen)
        if clear {
            grid.clear(rows: 0 ..< rows, with: eraseCell)
        }
        viewportOffset = 0
        damage.setFull()
    }

    private mutating func leaveAlternateScreen() {
        guard isAlternateScreen else { return }
        swap(&grid, &inactiveGrid)
        modes.remove(.alternateScreen)
        damage.setFull()
    }

    private mutating func saveCursor() {
        if isAlternateScreen {
            savedAlternate = cursor
            savedAlternateModes = modes
        } else {
            savedPrimary = cursor
            savedPrimaryModes = modes
        }
    }

    private mutating func restoreCursor() {
        let saved = isAlternateScreen ? savedAlternate : savedPrimary
        let savedModes = isAlternateScreen ? savedAlternateModes : savedPrimaryModes
        cursor = saved
        cursor.x = min(cursor.x, columns - 1)
        cursor.y = min(cursor.y, rows - 1)
        for mode in [Modes.origin, .autowrap] {
            if savedModes.contains(mode) {
                modes.insert(mode)
            } else {
                modes.remove(mode)
            }
        }
    }

    private mutating func softReset() {
        modes.subtract([.insert, .origin, .cursorKeys, .keypadApplication])
        modes.insert([.autowrap, .cursorVisible])
        cursor.pen = .default
        cursor.g0 = .ascii
        cursor.g1 = .ascii
        cursor.shiftedOut = false
        cursor.pendingWrap = false
        scrollTop = 0
        scrollBottom = rows - 1
        savedPrimary = Cursor()
        savedAlternate = Cursor()
    }

    private mutating func fullReset() {
        if isAlternateScreen {
            leaveAlternateScreen()
        }
        grid.clear(rows: 0 ..< rows, with: .blank)
        inactiveGrid.clear(rows: 0 ..< rows, with: .blank)
        grid.clearHistory()
        graphemes.removeAll()
        cursor = Cursor()
        savedPrimary = Cursor()
        savedAlternate = Cursor()
        modes = .initial
        cursorStyle = .block
        palette = defaultPalette
        scrollTop = 0
        scrollBottom = rows - 1
        tabStops = Self.defaultTabs(columns)
        viewportOffset = 0
        lastPrinted = 0
        damage.setFull()
    }

    // MARK: ESC

    mutating func escDispatch(intermediate: UInt8, final: UInt8) {
        joinNext = false
        switch (intermediate, final) {
        case (0, 0x37): saveCursor() // DECSC 7
        case (0, 0x38): restoreCursor() // DECRC 8
        case (0, 0x44): index() // IND D
        case (0, 0x45): index(); carriageReturn() // NEL E
        case (0, 0x48): tabStops[cursor.x] = true // HTS H
        case (0, 0x4D): reverseIndex() // RI M
        case (0, 0x63): fullReset() // RIS c
        case (0, 0x3D): modes.insert(.keypadApplication) // DECKPAM =
        case (0, 0x3E): modes.remove(.keypadApplication) // DECKPNM >
        case (0x28, _): cursor.g0 = final == 0x30 ? .decSpecialGraphics : .ascii // SCS G0
        case (0x29, _): cursor.g1 = final == 0x30 ? .decSpecialGraphics : .ascii // SCS G1
        case (0x23, 0x38): // DECALN #8
            let e = Cell(glyph: 0x45, attributes: .default, width: 1)
            for y in 0 ..< rows {
                grid.fill(row: y, from: 0, to: columns, with: e)
            }
            scrollTop = 0
            scrollBottom = rows - 1
            moveTo(column: 0, row: 0)
            damage.setFull()
        default: break
        }
    }

    // MARK: OSC

    mutating func oscDispatch(_ data: UnsafeBufferPointer<UInt8>, terminatedByBell: Bool) {
        joinNext = false
        var command = 0
        var i = 0
        while i < data.count, data[i] != 0x3B {
            guard (0x30 ... 0x39).contains(data[i]) else { return }
            command = command * 10 + Int(data[i] - 0x30)
            i += 1
        }
        let rest = i < data.count ? UnsafeBufferPointer(rebasing: data[(i + 1)...]) : UnsafeBufferPointer(rebasing: data[data.count...])
        let st = terminatedByBell ? "\u{07}" : "\u{1B}\\"
        switch command {
        case 0, 2:
            if Self.replace(&titleBytes, with: rest) {
                titleChanged = true
            }
        case 4:
            let parts = String(decoding: rest, as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false)
            var k = 0
            while k + 1 < parts.count {
                if let index = Int(parts[k]), (0 ..< 256).contains(index) {
                    if parts[k + 1] == "?" {
                        reply("\u{1B}]4;\(index);\(Self.formatColor(palette.colors[index]))\(st)")
                    } else if let rgb = Self.parseColor(parts[k + 1]) {
                        palette.colors[index] = rgb
                        damage.setFull()
                    }
                }
                k += 2
            }
        case 7:
            if Self.replace(&directoryBytes, with: rest) {
                directoryChanged = true
            }
        case 10, 11, 12:
            let spec = String(decoding: rest, as: UTF8.self)
            if spec == "?" {
                let rgb = command == 10 ? palette.foreground : command == 11 ? palette.background : palette.cursor
                reply("\u{1B}]\(command);\(Self.formatColor(rgb))\(st)")
            } else if let rgb = Self.parseColor(Substring(spec)) {
                switch command {
                case 10: palette.foreground = rgb
                case 11: palette.background = rgb
                default: palette.cursor = rgb
                }
                damage.setFull()
            }
        case 52:
            let s = String(decoding: rest, as: UTF8.self)
            guard let semi = s.firstIndex(of: ";") else { return }
            let payload = s[s.index(after: semi)...]
            // Clipboard reads ("?") are refused: they would leak data to the app.
            if payload != "?", let decoded = Data(base64Encoded: String(payload)) {
                events.append(.clipboard(String(decoding: decoded, as: UTF8.self)))
            }
        case 104:
            if rest.isEmpty {
                palette.colors = defaultPalette.colors
            } else {
                for part in String(decoding: rest, as: UTF8.self).split(separator: ";") {
                    if let index = Int(part), (0 ..< 256).contains(index) {
                        palette.colors[index] = defaultPalette.colors[index]
                    }
                }
            }
            damage.setFull()
        case 110: palette.foreground = defaultPalette.foreground; damage.setFull()
        case 111: palette.background = defaultPalette.background; damage.setFull()
        case 112: palette.cursor = defaultPalette.cursor
        default: break // 1, 8, 133, ... are ignored
        }
    }

    static func formatColor(_ rgb: UInt32) -> String {
        func c(_ v: UInt32) -> String {
            let s = String(v & 0xFF, radix: 16)
            let byte = s.count == 1 ? "0" + s : s
            return byte + byte
        }
        return "rgb:\(c(rgb >> 16))/\(c(rgb >> 8))/\(c(rgb))"
    }

    /// Parses `rgb:R/G/B` (1–4 hex digits each) or `#RRGGBB`.
    static func parseColor(_ spec: Substring) -> UInt32? {
        if spec.hasPrefix("#"), spec.count == 7, let v = UInt32(spec.dropFirst(), radix: 16) {
            return v
        }
        guard spec.hasPrefix("rgb:") else { return nil }
        let parts = spec.dropFirst(4).split(separator: "/")
        guard parts.count == 3 else { return nil }
        var rgb: UInt32 = 0
        for part in parts {
            guard (1 ... 4).contains(part.count), let v = UInt32(part, radix: 16) else { return nil }
            let maxValue = (UInt32(1) << (4 * UInt32(part.count))) - 1
            rgb = rgb << 8 | (v * 255 + maxValue / 2) / maxValue
        }
        return rgb
    }

    private mutating func reply(_ s: String) {
        output.append(contentsOf: s.utf8)
    }

    // MARK: Viewport

    /// Scrolls the viewport by `delta` lines (positive = towards history).
    public mutating func scrollViewport(by delta: Int) {
        guard !isAlternateScreen else { return }
        let target = min(max(viewportOffset + delta, 0), grid.historyCount)
        if target != viewportOffset {
            viewportOffset = target
            damage.setFull()
        }
    }

    public mutating func scrollViewportToBottom() {
        scrollViewport(by: -viewportOffset)
    }

    /// Lines of primary-screen history.
    public var scrollbackCount: Int {
        isAlternateScreen ? inactiveGrid.historyCount : grid.historyCount
    }

    /// History line `index` (0 = oldest) of the primary screen.
    public func scrollbackLine(_ index: Int) -> (cells: UnsafeBufferPointer<Cell>, wrapped: Bool) {
        isAlternateScreen ? inactiveGrid.historyLine(index) : grid.historyLine(index)
    }

    /// Cells shown at visible row `y`, which may come from scrollback.
    public func viewportRow(_ y: Int) -> (cells: UnsafeBufferPointer<Cell>, wrapped: Bool) {
        if viewportOffset == 0 {
            return (grid.cells(row: y), grid.isWrapped(y))
        }
        // A non-zero offset implies the primary screen is active.
        let history = grid.historyCount
        let v = history - viewportOffset + y
        if v < history {
            return grid.historyLine(v)
        }
        return (grid.cells(row: v - history), grid.isWrapped(v - history))
    }

    /// Scalars making up `cell`'s content (empty for a blank cell).
    public func scalars(of cell: Cell) -> [Unicode.Scalar] {
        if cell.isGrapheme {
            return graphemes.scalars(cell.glyph).compactMap(Unicode.Scalar.init)
        }
        if cell.glyph == 0 || cell.isSpacer {
            return []
        }
        return Unicode.Scalar(cell.glyph).map { [$0] } ?? []
    }

    func graphemeScalars(_ id: UInt32) -> UnsafeBufferPointer<UInt32> {
        graphemes.scalars(id)
    }

    /// Text of active-screen row `y` with trailing blanks trimmed.
    public func text(row y: Int) -> String {
        Self.text(of: grid.cells(row: y), self)
    }

    /// The visible screen as text lines (trailing blanks trimmed).
    public var screenLines: [String] {
        (0 ..< rows).map { Self.text(of: viewportRow($0).cells, self) }
    }

    public func scrollbackText(_ index: Int) -> String {
        Self.text(of: scrollbackLine(index).cells, self)
    }

    private static func text(of cells: UnsafeBufferPointer<Cell>, _ state: borrowing TerminalState) -> String {
        var s = String.UnicodeScalarView()
        for cell in cells where !cell.isSpacer {
            let scalars = state.scalars(of: cell)
            if scalars.isEmpty {
                s.append(" ")
            } else {
                s.append(contentsOf: scalars)
            }
        }
        var str = String(s)
        while str.last == " " {
            str.removeLast()
        }
        return str
    }

    // MARK: Resize

    public mutating func resize(columns newColumns: Int, rows newRows: Int) {
        let newColumns = max(1, newColumns), newRows = max(1, newRows)
        guard newColumns != columns || newRows != rows else { return }
        let alternate = isAlternateScreen
        if alternate {
            swap(&grid, &inactiveGrid)
        } // `grid` is primary now
        var primaryCursor = alternate ? savedPrimary : cursor
        reflowPrimary(columns: newColumns, rows: newRows, cursor: &primaryCursor)
        if alternate {
            savedPrimary = primaryCursor
            swap(&grid, &inactiveGrid)
            grid.resize(columns: newColumns, rows: newRows)
            cursor.x = min(cursor.x, newColumns - 1)
            cursor.y = min(cursor.y, newRows - 1)
        } else {
            cursor = primaryCursor
            inactiveGrid.resize(columns: newColumns, rows: newRows)
        }
        savedAlternate.x = min(savedAlternate.x, newColumns - 1)
        savedAlternate.y = min(savedAlternate.y, newRows - 1)
        cursor.pendingWrap = false
        columns = newColumns
        rows = newRows
        scrollTop = 0
        scrollBottom = newRows - 1
        tabStops = Self.defaultTabs(newColumns)
        viewportOffset = min(viewportOffset, grid.historyCount)
        damage.setFull()
    }

    /// Re-wraps primary screen + scrollback to a new width, keeping the
    /// cursor on the same logical position. Allocates temporaries; resize is
    /// not a hot path.
    private mutating func reflowPrimary(columns newColumns: Int, rows newRows: Int, cursor c: inout Cursor) {
        // 1. Gather logical lines.
        var lastRow = min(c.y, grid.rows - 1)
        for y in stride(from: grid.rows - 1, to: lastRow, by: -1)
            where grid.cells(row: y).contains(where: { !$0.isBlank }) {
            lastRow = y
            break
        }
        var cells: [Cell] = []
        var lineStarts: [Int] = []
        var lineOpen = false
        var cursorLine = 0, cursorOffset = 0
        let history = grid.historyCount
        for p in 0 ..< history + lastRow + 1 {
            let (row, wrapped) = p < history ? grid.historyLine(p) : (grid.cells(row: p - history), grid.isWrapped(p - history))
            if !lineOpen {
                lineStarts.append(cells.count); lineOpen = true
            }
            if p == history + c.y {
                cursorLine = lineStarts.count - 1
                cursorOffset = cells.count - lineStarts[cursorLine] + c.x
            }
            var length = row.count
            if !wrapped {
                while length > 0, row[length - 1].isBlank {
                    length -= 1
                }
            }
            for k in 0 ..< length where !row[k].flags.contains(.spacerHead) {
                cells.append(row[k])
            }
            if !wrapped {
                lineOpen = false
            }
        }
        lineStarts.append(cells.count)

        // 2. Re-wrap into rows of the new width.
        var out: [Cell] = []
        var outWrapped: [Bool] = []
        var cursorRow = -1, cursorColumn = 0
        func newRow() {
            out.append(contentsOf: repeatElement(Cell.blank, count: newColumns))
            outWrapped.append(false)
        }
        for line in 0 ..< lineStarts.count - 1 {
            let lo = lineStarts[line], hi = lineStarts[line + 1]
            newRow()
            var col = 0
            for k in lo ..< hi {
                let cell = cells[k]
                if line == cursorLine, k - lo == cursorOffset, cursorRow < 0 {
                    cursorRow = outWrapped.count - 1
                    cursorColumn = min(col, newColumns - 1)
                }
                if cell.width == 0 {
                    continue
                } // tails are re-created with their lead
                let w = Int(cell.width)
                if col + w > newColumns {
                    if w == 2, col < newColumns {
                        out[out.count - newColumns + col] = Cell(glyph: 0, attributes: CellAttributes(flags: .spacerHead), width: 1)
                    }
                    outWrapped[outWrapped.count - 1] = true
                    newRow()
                    col = 0
                    if line == cursorLine, k - lo == cursorOffset {
                        cursorRow = outWrapped.count - 1; cursorColumn = 0
                    }
                }
                guard w <= newColumns else { continue }
                let base = out.count - newColumns
                out[base + col] = cell
                if w == 2 {
                    var tail = cell.attributes
                    tail.flags.subtract(.grapheme)
                    tail.flags.insert(.spacerTail)
                    out[base + col + 1] = Cell(glyph: 0, attributes: tail, width: 0)
                }
                col += w
            }
            if line == cursorLine, cursorRow < 0 {
                // Cursor sits past the end of the line's content.
                var position = col + (cursorOffset - (hi - lo))
                while position >= newColumns, position > 0 {
                    if position == newColumns {
                        position = newColumns - 1; break
                    }
                    newRow()
                    position -= newColumns
                }
                cursorRow = outWrapped.count - 1
                cursorColumn = max(0, position)
            }
        }
        if cursorRow < 0 {
            newRow(); cursorRow = outWrapped.count - 1
        }

        // 3. Split between scrollback and screen, keeping the cursor visible.
        let total = outWrapped.count
        var top = max(0, total - newRows)
        if cursorRow < top {
            top = cursorRow
        }
        grid.reset(columns: newColumns, rows: newRows)
        out.withUnsafeBufferPointer { buf in
            for r in 0 ..< top {
                grid.appendHistory(UnsafeBufferPointer(rebasing: buf[r * newColumns ..< (r + 1) * newColumns]), wrapped: outWrapped[r])
            }
            for r in top ..< min(total, top + newRows) {
                grid.setRow(r - top, UnsafeBufferPointer(rebasing: buf[r * newColumns ..< (r + 1) * newColumns]), wrapped: outWrapped[r])
            }
        }
        c.x = cursorColumn
        c.y = min(cursorRow - top, newRows - 1)
    }

    /// Debug check: cells past each row's extent are blank (both screens).
    func checkExtentInvariant() -> Bool {
        for y in 0 ..< rows {
            let row = grid.cells(row: y)
            for x in grid.extent(y) ..< columns where !row[x].isBlank {
                return false
            }
            let other = inactiveGrid.cells(row: y)
            for x in inactiveGrid.extent(y) ..< columns where !other[x].isBlank {
                return false
            }
        }
        return true
    }

    // MARK: Graphemes

    private mutating func compactGraphemes() {
        var fresh = GraphemeTable()
        swap(&fresh, &spareGraphemes) // reuse the previous table's capacity
        fresh.removeAll()
        for y in 0 ..< grid.rows {
            let row = grid.row(y)
            for x in 0 ..< grid.columns where row[x].isGrapheme {
                fresh.adopt(&row[x], from: graphemes)
            }
        }
        for y in 0 ..< inactiveGrid.rows {
            let row = inactiveGrid.row(y)
            for x in 0 ..< inactiveGrid.columns where row[x].isGrapheme {
                fresh.adopt(&row[x], from: graphemes)
            }
        }
        for i in 0 ..< grid.historyCount {
            let line = grid.historyMutableCells(i)
            for x in line.indices where line[x].isGrapheme {
                fresh.adopt(&line[x], from: graphemes)
            }
        }
        for i in 0 ..< inactiveGrid.historyCount {
            let line = inactiveGrid.historyMutableCells(i)
            for x in line.indices where line[x].isGrapheme {
                fresh.adopt(&line[x], from: graphemes)
            }
        }
        swap(&graphemes, &fresh)
        swap(&fresh, &spareGraphemes)
    }

    // MARK: Tables

    private static func defaultTabs(_ columns: Int) -> [Bool] {
        (0 ..< columns).map { $0 % 8 == 0 && $0 != 0 }
    }

    /// DEC Special Graphics for 0x5F...0x7E.
    static let decSpecial: [UInt32] = [
        0x00A0, 0x25C6, 0x2592, 0x2409, 0x240C, 0x240D, 0x240A, 0x00B0,
        0x00B1, 0x2424, 0x240B, 0x2518, 0x2510, 0x250C, 0x2514, 0x253C,
        0x23BA, 0x23BB, 0x2500, 0x23BC, 0x23BD, 0x251C, 0x2524, 0x2534,
        0x252C, 0x2502, 0x2264, 0x2265, 0x03C0, 0x2260, 0x00A3, 0x00B7,
    ]
}
