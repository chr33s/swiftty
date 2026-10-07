import Foundation

/// Side effects the frontend must handle, drained after each parse batch.
public enum TerminalEvent: Sendable, Equatable {
    case title(String)
    case bell
    case clipboard(String)
    case workingDirectory(String)
    case exited(Int32)
    /// `DCS 1000 p`: tmux control mode began; its stream follows through
    /// `TerminalState.controlModeData` until `.controlModeEnded`.
    case controlModeStarted
    case controlModeEnded
    /// OSC 9 / OSC 777;notify desktop notification.
    case notification(title: String, body: String)
    /// OSC 9;4 progress: state 0 remove, 1 set, 2 error, 3 indeterminate,
    /// 4 pause; `percent` is nil when not given.
    case progress(state: Int, percent: Int?)
    /// OSC 22: the application asked for this mouse pointer shape (a CSS
    /// cursor name such as `text`, `pointer`, `default`).
    case pointerShape(String)
    /// OSC 133 ; D: a command finished with this exit status (the latest,
    /// once per batch).
    case commandFinished(exitCode: Int?)
}

public struct Cursor: Sendable, Equatable {
    public enum Charset: UInt8, Sendable { case ascii, decSpecialGraphics, british }

    public var x = 0
    public var y = 0
    /// Set after printing in the last column; the next print wraps first.
    public var pendingWrap = false
    public var pen = CellAttributes.default
    public var g0 = Charset.ascii
    public var g1 = Charset.ascii
    public var g2 = Charset.ascii
    public var g3 = Charset.ascii
    /// Slot (0...3) invoked into GL by SI/SO/LS2/LS3.
    public var gl: UInt8 = 0
    /// Slot used for the next printed cell only (SS2/SS3).
    public var singleShift: UInt8?

    /// SO selects G1 into GL.
    public var shiftedOut: Bool {
        get { gl == 1 }
        set { gl = newValue ? 1 : 0 }
    }

    /// DECSCA / SPA: printed cells are protected from selective erase.
    public var isProtected: Bool {
        get { pen.flags.contains(.protected) }
        set {
            if newValue {
                pen.flags.insert(.protected)
            } else {
                pen.flags.remove(.protected)
            }
        }
    }

    func charset(_ slot: UInt8) -> Charset {
        switch slot {
        case 0: g0
        case 1: g1
        case 2: g2
        default: g3
        }
    }

    mutating func setCharset(_ slot: UInt8, _ set: Charset) {
        switch slot {
        case 0: g0 = set
        case 1: g1 = set
        case 2: g2 = set
        default: g3 = set
        }
    }

    @inline(__always) var activeCharset: Charset {
        charset(singleShift ?? gl)
    }

    /// No translation applies to the next printed cell.
    @inline(__always) var printsPlain: Bool {
        singleShift == nil && charset(gl) == .ascii
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
    public internal(set) var grid: Grid
    var inactiveGrid: Grid
    var graphemes = GraphemeTable()
    private let scrollbackLimitBytes: Int

    public internal(set) var cursor = Cursor()
    var savedPrimary = Cursor()
    var savedAlternate = Cursor()
    private var savedPrimaryModes: Modes = .initial
    private var savedAlternateModes: Modes = .initial

    public private(set) var scrollTop = 0
    public private(set) var scrollBottom: Int
    /// DECSLRM left/right margins (only settable with DECLRMM).
    public private(set) var scrollLeft = 0
    public private(set) var scrollRight: Int
    private var tabStops: [Bool]

    /// How plain erases treat protected cells: only ISO protection (SPA)
    /// shields them; DEC protection (DECSCA) applies to DECSED/DECSEL.
    enum ProtectedMode { case off, iso, dec }
    var protectedMode = ProtectedMode.off

    public internal(set) var modes: Modes = .initial
    public internal(set) var cursorStyle = CursorStyle.block
    public internal(set) var palette: Palette
    var defaultPalette: Palette
    // Title / working directory as raw bytes; turned into events once per
    // batch by `takeEvents()` so OSC-heavy output does not allocate per sequence.
    var titleBytes: [UInt8] = []
    var titleChanged = false
    var directoryBytes: [UInt8] = []
    var directoryChanged = false
    private var spareGraphemes = GraphemeTable()

    public var title: String {
        String(decoding: titleBytes, as: UTF8.self)
    }

    /// Rows touched since the last `takeDamage()`.
    public internal(set) var damage = DamageRegion.full
    /// Lines scrolled back from the bottom (0 = following output).
    public internal(set) var viewportOffset = 0

    /// Bytes to send back to the application (DSR, DA, OSC queries).
    public var output: [UInt8] = []
    /// Drop replies to queries: set when another terminal (e.g. tmux) has
    /// already answered the application.
    public var discardsReplies = false
    /// With `discardsReplies`, still answer the OSC 7501 support query: the
    /// other terminal passes it through unanswered (tmux does).
    public var answersProgramStatusWhileDiscarding = false
    public var events: [TerminalEvent] = []

    /// Kitty keyboard protocol flags stack (`CSI > flags u`); the top applies.
    public private(set) var keyboardFlagStack: [UInt8] = []
    public var keyboardFlags: UInt8 {
        keyboardFlagStack.last ?? 0
    }

    /// OSC 8 targets by id (1...255); ids are reused round-robin.
    var hyperlinks: [[UInt8]] = []
    var hyperlinkHashes: [UInt64] = []
    var hyperlinkIndex: [UInt64: UInt8] = Dictionary(minimumCapacity: 512)
    var freeHyperlinkSlots: [Int] = []
    /// Per slot: last absolute row its cells can occupy (.max: unknown).
    var hyperlinkLastRow: [Int] = []
    var hyperlinkScanCooldown = 0

    /// Current selection, in absolute rows (see `Selection.swift`).
    public internal(set) var selection: Selection?
    /// Search matches, oldest first, and the selected one.
    public internal(set) var searchMatches: [TerminalRange] = []
    public internal(set) var searchSelected: Int?

    /// tmux control-mode bytes received since the host last drained them.
    public var controlModeData: [UInt8] = []
    public internal(set) var isControlMode = false
    var dcsKind = DCSKind.ignored
    var dcsBuffer: [UInt8] = []

    enum DCSKind { case ignored, tmux, termcap, statusString }

    /// Pixel size of one cell, for XTWINOPS reports.
    public var cellPixelSize = (width: 0, height: 0)

    /// Shell integration and host-facing state (`TerminalState+Shell.swift`).
    public internal(set) var semanticState = SemanticState.none
    /// The shell redraws its prompt after a resize (OSC 133 `redraw=1`).
    var promptRedraws = false
    /// Where the command line being typed starts (OSC 133 ; B), as an
    /// offset into its logical line; that line's first row carries the
    /// grid's input-line flag, so the point follows scrolling and reflow.
    var inputOffset: Int?
    /// Whether any OSC 133 prompt has been seen (menus enable on it).
    public internal(set) var hasSemanticPrompts = false
    public internal(set) var lastExitCode: Int?
    /// A command finished since the last `takeEvents()`.
    var commandFinished = false
    var titleStack: [[UInt8]] = []
    var penStack: [CellAttributes] = []
    /// Appearance the host reports for color-scheme queries (mode 2031).
    public internal(set) var colorScheme = ColorScheme.dark
    var underlineColors: [TerminalColor] = []
    var pointerShape = ""

    /// Consume OSC 7501 program status (and answer its support query).
    /// Off by default: the terminal claims support only for an embedder
    /// that reads `programStatus`. Turning it off clears the records.
    public var programStatusEnabled = false {
        didSet {
            if !programStatusEnabled, programStatus.removeAll() {
                programStatusChanged = true
            }
        }
    }

    /// OSC 7501 records (`TerminalState+ProgramStatus.swift`).
    public internal(set) var programStatus = ProgramStatusStore()
    /// `programStatus` changed since the last `takeProgramStatusChange()`.
    public internal(set) var programStatusChanged = false

    private let widths = UnicodeWidth.table
    private var lastPrinted: UInt32 = 0

    /// - Parameters:
    ///   - scrollbackLimitBytes: cell memory for history (Ghostty's `scrollback-limit`).
    ///   - scrollbackLimitRows: additional cap on history lines.
    public init(
        columns: Int, rows: Int, scrollbackLimitBytes: Int = 10_000_000,
        scrollbackLimitRows: Int = 100_000, palette: Palette = .standard,
    ) {
        let columns = max(1, columns), rows = max(1, rows)
        self.columns = columns
        self.rows = rows
        grid = Grid(columns: columns, rows: rows)
        self.scrollbackLimitBytes = scrollbackLimitBytes
        grid = Grid(
            columns: columns, rows: rows, historyLimitBytes: scrollbackLimitBytes,
            maxHistoryRows: max(1, scrollbackLimitRows),
        )
        inactiveGrid = Grid(columns: columns, rows: rows)
        scrollBottom = rows - 1
        scrollRight = columns - 1
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
        guard !events.isEmpty || titleChanged || directoryChanged || commandFinished else { return [] }
        var out = events
        events.removeAll(keepingCapacity: true)
        if titleChanged {
            out.append(.title(title))
        }
        if directoryChanged, let url = URL(string: String(decoding: directoryBytes, as: UTF8.self)), url.isFileURL {
            out.append(.workingDirectory(url.path))
        }
        if commandFinished {
            out.append(.commandFinished(exitCode: lastExitCode))
        }
        titleChanged = false
        directoryChanged = false
        commandFinished = false
        return out
    }

    static func replace(_ target: inout [UInt8], with bytes: UnsafeBufferPointer<UInt8>) -> Bool {
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
    /// Narrow and wide scalars that cannot join the previous cluster are
    /// written inline; anything else defers to `print`.
    mutating func printScalars(_ scalars: UnsafeBufferPointer<UInt32>) {
        if !printsFast {
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
            if cp > 0xFF, !previousKnown {
                previous = scalarBeforeCursor()
                previousKnown = true
            }
            if Self.mayJoin(cp, after: previous, clustering: clustering, widths: widths) {
                print(cp)
                previous = cp
                i += 1
                continue
            }
            if cursor.pendingWrap {
                guard autowrap else { print(cp); previous = cp; previousKnown = true; i += 1; continue }
                printWrap()
            }
            // Write a run of narrow and wide scalars on the current row; a
            // wide scalar that does not fit goes through `print` to wrap.
            // Cells at or past the row's extent are blank, so only cells
            // before it need wide-character splitting.
            let row = grid.row(cursor.y)
            let raw = UnsafeMutableRawPointer(row)
            let clean = grid.extent(cursor.y)
            var x = cursor.x
            let start = i
            // Break class of the previous scalar in this run: below U+0300
            // every scalar behaves as Other for joining purposes.
            var previousClass = 0
            while i < n, x < columns {
                let c = scalars[i]
                let w: Int, cls: Int
                if c < 0x300 {
                    (w, cls) = (1, 0)
                } else {
                    let info = scalarInfo.lookup(c)
                    w = Int(info >> 5)
                    cls = Int(info & 0x1F)
                    // Joining within the run (the first scalar was checked above).
                    if clustering, i > start, graphemeTables.joinMask[previousClass] >> UInt32(cls) & 1 != 0 {
                        break
                    }
                }
                if w == 0 || (w == 2 && x + 1 >= columns) {
                    break
                }
                previousClass = cls
                if x < clean {
                    if row[x].width != 1 {
                        splitWide(row, x)
                    }
                    if w == 2, row[x + 1].width != 1 {
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
            if i > start {
                lastPrinted = scalars[i - 1]
                previous = scalars[i - 1]
                previousKnown = true
            }
            if x == cursor.x, i < n, !cursor.pendingWrap {
                print(scalars[i]) // wide scalar at the last column, or a joiner
                previous = scalars[i]
                previousKnown = true
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

    /// General path for one printable scalar (Ghostty `Terminal.print`).
    mutating func print(_ c: UInt32) {
        let rightLimit = cursor.x > scrollRight ? columns : scrollRight + 1
        if c > 0xFF, modes.contains(.graphemeCluster), cursor.x > 0, printJoining(c, rightLimit: rightLimit) {
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
    private func clearSpacerHeadAbove(_ x: Int) {
        guard cursor.y > 0, x <= 1 else { return }
        let above = grid.row(cursor.y - 1)
        above[columns - 1].attributes.flags.remove(.spacerHead)
    }

    /// Whether `c` might extend the cluster ending in `previous` (nil:
    /// unknown), so the batched path must hand it to `print`.
    @inline(__always)
    private static func mayJoin(_ c: UInt32, after previous: UInt32?, clustering: Bool, widths: WidthTable) -> Bool {
        if c <= 0xFF {
            return false
        }
        guard clustering else { return widths.lookup(c) == 0 }
        guard let previous else { return true }
        return GraphemeBreak.mayJoin(previous: previous, c)
    }

    /// The last scalar of the cell a joining scalar would attach to, or a
    /// stand-in that joins at least as readily (nil: unknown).
    private func scalarBeforeCursor() -> UInt32? {
        if !modes.contains(.autowrap), cursor.x == columns - 1 {
            return nil
        }
        var x = cursor.pendingWrap ? cursor.x : cursor.x - 1
        let row = grid.row(cursor.y)
        if x >= 0, Self.kind(of: row[x]) == .spacerTail {
            x -= 1
        }
        guard x >= 0 else { return 0x20 } // nothing to join
        let cell = row[x]
        if cell.isGrapheme {
            return graphemes.scalars(cell.glyph).last
        }
        return cell.glyph == 0 ? 0x20 : cell.glyph
    }

    /// Zero-width scalar outside a grapheme cluster (mode 2027 off, or no
    /// previous cell): attaches to the cell before the cursor.
    private mutating func attachZeroWidth(_ c: UInt32) {
        if modes.contains(.graphemeCluster) {
            return
        }
        let left = modes.contains(.autowrap) && cursor.pendingWrap ? 0 : 1
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
            let base = row[x].isGrapheme ? graphemes.scalars(row[x].glyph).first ?? 0 : row[x].glyph
            guard GraphemeBreak.isExtendedPictographic(base) else { return }
        }
        appendGrapheme(c, x: x, y: cursor.y)
    }

    /// Appends `c` to the cluster in cell (`x`, `y`).
    mutating func appendGrapheme(_ c: UInt32, x: Int, y: Int) {
        let row = grid.row(y)
        if row[x].isGrapheme, graphemes.scalars(row[x].glyph).count > Self.graphemeMaxLength {
            return
        }
        let id = graphemes.appending(c, to: row[x])
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
    private func splitWide(_ row: UnsafeMutablePointer<Cell>, _ x: Int) {
        let cell = row[x]
        if cell.width == 2, x + 1 < columns {
            row[x + 1] = eraseCell
        } else if cell.width == 0, x > 0 {
            row[x - 1] = eraseCell
        }
    }

    /// Wraps to the left margin of the next line (Ghostty `printWrap`);
    /// only a wrap from the last column marks the row soft-wrapped.
    mutating func printWrap() {
        if cursor.x == columns - 1 {
            grid.setWrapped(cursor.y, true)
        }
        index()
        cursor.x = scrollLeft
    }

    // MARK: C0 controls

    mutating func execute(_ byte: UInt8) {
        switch byte {
        case 0x07: events.append(.bell)
        case 0x08: cursorLeft(1) // BS
        case 0x09: tabForward(1)
        case 0x0A, 0x0B, 0x0C:
            index()
            if modes.contains(.linefeedNewline) {
                carriageReturn()
            }
        case 0x0D: carriageReturn()
        case 0x0E: cursor.gl = 1 // SO
        case 0x0F: cursor.gl = 0 // SI
        default: break
        }
    }

    private mutating func carriageReturn() {
        cursor.pendingWrap = false
        cursor.x = modes.contains(.origin) || cursor.x >= scrollLeft ? scrollLeft : 0
    }

    /// IND: move down, scrolling the region at its bottom margin.
    mutating func index() {
        cursor.pendingWrap = false
        if cursor.y < scrollTop || cursor.y > scrollBottom {
            if cursor.y < rows - 1 {
                cursor.y += 1
            }
            return
        }
        if cursor.y == scrollBottom, cursor.x >= scrollLeft, cursor.x <= scrollRight {
            if scrollTop == 0, !hasHorizontalMargins, !isAlternateScreen || scrollBottom == 0 {
                scrollIntoHistory(1)
            } else if hasHorizontalMargins {
                scrollUp(1)
            } else {
                grid.scrollUp(top: scrollTop, bottom: scrollBottom, count: 1, fill: eraseCell)
                markScrolled()
            }
            return
        }
        if cursor.y < scrollBottom {
            cursor.y += 1
        }
    }

    /// RI: move up, scrolling the region down at its top margin.
    mutating func reverseIndex() {
        if cursor.y != scrollTop || cursor.x < scrollLeft || cursor.x > scrollRight {
            cursorUp(1)
        } else {
            scrollDown(1)
        }
    }

    var eraseCell: Cell {
        .erased(background: cursor.pen.background)
    }

    var hasHorizontalMargins: Bool {
        scrollLeft != 0 || scrollRight != columns - 1
    }

    /// Scrolls rows `0...scrollBottom` up by `count`, the top ones into
    /// the primary screen's history; rows below the region stay put.
    private mutating func scrollIntoHistory(_ count: Int) {
        let n = min(count, scrollBottom + 1)
        guard n > 0 else { return }
        if isAlternateScreen {
            grid.scrollUp(top: 0, bottom: scrollBottom, count: n, fill: eraseCell)
        } else {
            // Rows move into history by id; no cells are copied.
            grid.scrollUpIntoHistory(count: n, bottom: scrollBottom, fill: eraseCell)
            if viewportOffset > 0 {
                viewportOffset = min(viewportOffset + n, grid.historyCount)
            }
        }
        markScrolled()
    }

    /// SU: scrolls the region up; a full-width region at the top of the
    /// primary screen feeds the scrollback.
    mutating func scrollUp(_ count: Int) {
        if scrollTop == 0, !hasHorizontalMargins, !isAlternateScreen || scrollBottom == rows - 1 {
            scrollIntoHistory(count)
            return
        }
        let saved = (cursor.x, cursor.y, cursor.pendingWrap)
        cursor.x = scrollLeft
        cursor.y = scrollTop
        deleteLines(count)
        (cursor.x, cursor.y, cursor.pendingWrap) = saved
    }

    /// SD: scrolls the region down.
    mutating func scrollDown(_ count: Int) {
        let saved = (cursor.x, cursor.y, cursor.pendingWrap)
        cursor.x = scrollLeft
        cursor.y = scrollTop
        insertLines(count)
        (cursor.x, cursor.y, cursor.pendingWrap) = saved
    }

    private mutating func markScrolled() {
        if scrollTop == 0, scrollBottom == rows - 1 {
            damage.setFull()
        } else {
            damage.insert(rows: scrollTop ..< scrollBottom + 1)
        }
    }

    // MARK: Cursor movement

    /// CUP: 1-based, relative to the margins in origin mode.
    private mutating func setCursorPosition(row: Int, column: Int) {
        let origin = modes.contains(.origin)
        let xOffset = origin ? scrollLeft : 0, yOffset = origin ? scrollTop : 0
        let xMax = origin ? scrollRight + 1 : columns, yMax = origin ? scrollBottom + 1 : rows
        cursor.pendingWrap = false
        cursor.x = max(min(xMax, max(column, 1) + xOffset) - 1, 0)
        cursor.y = max(min(yMax, max(row, 1) + yOffset) - 1, 0)
    }

    private mutating func cursorUp(_ n: Int) {
        cursor.pendingWrap = false
        let limit = cursor.y >= scrollTop ? cursor.y - scrollTop : cursor.y
        cursor.y -= min(limit, max(n, 1))
    }

    private mutating func cursorDown(_ n: Int) {
        cursor.pendingWrap = false
        let limit = cursor.y <= scrollBottom ? scrollBottom - cursor.y : rows - cursor.y - 1
        cursor.y += min(limit, max(n, 1))
    }

    private mutating func cursorRight(_ n: Int) {
        cursor.pendingWrap = false
        let limit = cursor.x <= scrollRight ? scrollRight - cursor.x : columns - cursor.x - 1
        cursor.x += min(limit, max(n, 1))
    }

    /// CUB / BS, with reverse wrap (modes 45 / 1045) when autowrap is on.
    private mutating func cursorLeft(_ n: Int) {
        enum Wrap { case none, reverse, extended }
        let wrap: Wrap = !modes.contains(.autowrap) ? .none
            : modes.contains(.reverseWrapExtended) ? .extended
            : modes.contains(.reverseWrap) ? .reverse : .none
        var count = max(n, 1)
        if wrap == .none {
            cursor.x -= min(count, cursor.x)
            cursor.pendingWrap = false
            return
        }
        if cursor.pendingWrap {
            count -= 1
            cursor.pendingWrap = false
            if count == 0 {
                return
            }
        }
        let top = scrollTop, bottom = scrollBottom, right = scrollRight
        let left = cursor.x < scrollLeft ? 0 : scrollLeft
        if cursor.x == left, wrap == .reverse, cursor.y <= top {
            cursor.x = left
            cursor.y = top
            return
        }
        while true {
            let amount = min(cursor.x - left, count)
            count -= amount
            cursor.x -= amount
            if count == 0 {
                break
            }
            if cursor.y == top {
                if wrap != .extended {
                    break
                }
                cursor.x = right
                cursor.y = bottom
                count -= 1
                continue
            }
            if cursor.y == 0 {
                break
            }
            if wrap != .extended, !grid.isWrapped(cursor.y - 1) {
                break
            }
            cursor.x = right
            cursor.y -= 1
            count -= 1
        }
    }

    /// HT: to the next tab stop, stopping at the right margin.
    private mutating func tabForward(_ n: Int) {
        for _ in 0 ..< max(n, 1) {
            let start = cursor.x
            // Like Ghostty, a tab leaves a pending wrap alone.
            while cursor.x < scrollRight {
                cursor.x += 1
                if tabStops[cursor.x] {
                    break
                }
            }
            if cursor.x == start {
                break
            }
        }
    }

    /// CBT: to the previous tab stop (the left margin in origin mode).
    private mutating func tabBackward(_ n: Int) {
        let limit = modes.contains(.origin) ? scrollLeft : 0
        for _ in 0 ..< max(n, 1) {
            let start = cursor.x
            while cursor.x > limit {
                cursor.x -= 1
                if tabStops[cursor.x] {
                    break
                }
            }
            if cursor.x == start {
                break
            }
        }
    }

    // MARK: Erase / edit

    /// Blanks `x0..<x1` on row `y` with the pen's background; with
    /// `protected`, cells protected by DECSCA/SPA are skipped.
    private mutating func clearCells(row y: Int, from x0: Int, to x1: Int, protected: Bool = false) {
        guard x0 < x1 else { return }
        if protected {
            let row = grid.row(y)
            var a = x0
            while a < x1 {
                while a < x1, row[a].flags.contains(.protected) {
                    a += 1
                }
                var b = a
                while b < x1, !row[b].flags.contains(.protected) {
                    b += 1
                }
                grid.fill(row: y, from: a, to: b, with: eraseCell)
                a = b
            }
        } else {
            grid.fill(row: y, from: x0, to: x1, with: eraseCell)
        }
        damage.insert(row: y)
    }

    /// Clears a wide character straddling the boundary before column `x`
    /// of the cursor row (Ghostty `splitCellBoundary`).
    private mutating func splitCellBoundary(_ x: Int) {
        let y = cursor.y
        let row = grid.row(y)
        if x == columns {
            if grid.isWrapped(y), row[columns - 1].flags.contains(.spacerHead) {
                clearCells(row: y, from: columns - 1, to: columns)
            }
            return
        }
        if x <= 1, y > 0, grid.isWrapped(y - 1), row[0].width == 2,
           grid.row(y - 1)[columns - 1].flags.contains(.spacerHead) {
            clearCells(row: y - 1, from: columns - 1, to: columns)
        }
        if x > 0, row[x - 1].width == 2 {
            clearCells(row: y, from: x - 1, to: x + 1)
        }
    }

    /// Clears the pending wrap and unwraps the cursor row.
    private mutating func resetCursorWrap() {
        cursor.pendingWrap = false
        guard grid.isWrapped(cursor.y) else { return }
        grid.setWrapped(cursor.y, false)
        if grid.row(cursor.y)[columns - 1].flags.contains(.spacerHead) {
            clearCells(row: cursor.y, from: columns - 1, to: columns)
        }
    }

    /// ECH: erases `n` cells from the cursor, including a wide character's
    /// tail at the end.
    private mutating func eraseChars(_ n: Int) {
        let remaining = columns - cursor.x
        var count = min(remaining, max(n, 1))
        if count != remaining, grid.row(cursor.y)[cursor.x + count - 1].width == 2 {
            count += 1
        }
        splitCellBoundary(cursor.x)
        splitCellBoundary(cursor.x + count)
        resetCursorWrap()
        clearCells(row: cursor.y, from: cursor.x, to: cursor.x + count, protected: protectedMode == .iso)
    }

    /// EL / DECSEL (`selective`: protected cells survive).
    private mutating func eraseLine(_ mode: Int, selective: Bool = false) {
        let row = grid.row(cursor.y)
        let start: Int, end: Int
        switch mode {
        case 0:
            var x = cursor.x
            if x > 0, Self.kind(of: row[x]) == .spacerTail {
                x -= 1
            }
            resetCursorWrap()
            (start, end) = (x, columns)
        case 1:
            let x = row[cursor.x].width == 2 ? cursor.x + 1 : cursor.x
            (start, end) = (0, x + 1)
        case 2:
            resetCursorWrap()
            (start, end) = (0, columns)
        default: return
        }
        cursor.pendingWrap = false
        clearCells(row: cursor.y, from: start, to: end, protected: selective || protectedMode == .iso)
    }

    /// Clears whole rows; an unprotected clear also unwraps them.
    private mutating func clearRows(_ range: Range<Int>, protected: Bool) {
        for y in range {
            clearCells(row: y, from: 0, to: columns, protected: protected)
            if !protected {
                grid.setWrapped(y, false)
                grid.clearMarks(y) // the prompt or output it marked is gone
            }
        }
    }

    /// ED / DECSED (`selective`: protected cells survive).
    private mutating func eraseDisplay(_ mode: Int, selective: Bool = false) {
        let protected = selective || protectedMode == .iso
        switch mode {
        case 0:
            eraseLine(0, selective: selective)
            clearRows(cursor.y + 1 ..< rows, protected: protected)
        case 1:
            eraseLine(1, selective: selective)
            clearRows(0 ..< cursor.y, protected: protected)
        case 2:
            clearRows(0 ..< rows, protected: protected)
            cursor.pendingWrap = false
        case 3:
            invalidateSelection()
            forgetHyperlinkRows()
            if isAlternateScreen {
                inactiveGrid.clearHistory()
            } else {
                grid.clearHistory()
            }
            viewportOffset = 0
            damage.setFull()
        case 22: // scroll the screen's contents into history
            var used = 0
            for y in stride(from: rows - 1, through: 0, by: -1)
                where grid.cells(row: y).contains(where: { !$0.isBlank }) {
                used = y + 1
                break
            }
            let (savedTop, savedBottom) = (scrollTop, scrollBottom)
            (scrollTop, scrollBottom) = (0, rows - 1)
            scrollIntoHistory(used)
            (scrollTop, scrollBottom) = (savedTop, savedBottom)
            cursor.pendingWrap = false
        default: break
        }
    }

    /// Prepares row `y` for having cells in the margins moved: clears wide
    /// characters cut by a margin and drops a spacer head that would no
    /// longer lead into the next row.
    private func rowWillBeShifted(_ y: Int) {
        let row = grid.row(y)
        if scrollRight == columns - 1 || scrollLeft < 2 {
            row[columns - 1].attributes.flags.remove(.spacerHead)
        }
        if scrollLeft > 0, Self.kind(of: row[scrollLeft]) == .spacerTail {
            row[scrollLeft - 1] = Self.narrowed(row[scrollLeft - 1])
            row[scrollLeft] = Self.narrowed(row[scrollLeft])
        }
        if scrollRight + 1 < columns, row[scrollRight].width == 2 {
            row[scrollRight] = Self.narrowed(row[scrollRight])
            row[scrollRight + 1] = Self.narrowed(row[scrollRight + 1])
        }
    }

    /// An empty narrow cell keeping `cell`'s style.
    static func narrowed(_ cell: Cell) -> Cell {
        var attributes = cell.attributes
        attributes.flags.subtract(.structural)
        return Cell(glyph: 0, attributes: attributes, width: 1)
    }

    /// Copies the margin columns of row `src` onto row `dst`.
    private func copyMarginCells(from src: Int, to dst: Int) {
        let n = scrollRight - scrollLeft + 1
        (grid.row(dst) + scrollLeft).update(from: grid.row(src) + scrollLeft, count: n)
        grid.extend(dst, to: scrollRight + 1)
    }

    /// IL: inserts blank lines at the cursor within the margins.
    private mutating func insertLines(_ n: Int) {
        guard n > 0, cursor.y >= scrollTop, cursor.y <= scrollBottom,
              cursor.x >= scrollLeft, cursor.x <= scrollRight else { return }
        let top = cursor.y, bottom = scrollBottom
        for y in top ... bottom {
            rowWillBeShifted(y)
        }
        if hasHorizontalMargins {
            let k = min(n, bottom - top + 1)
            for y in stride(from: bottom, through: top + k, by: -1) {
                copyMarginCells(from: y - k, to: y)
            }
            for y in top ..< top + k {
                clearCells(row: y, from: scrollLeft, to: scrollRight + 1)
            }
        } else {
            grid.scrollDown(top: top, bottom: bottom, count: n, fill: eraseCell)
            for y in top ... bottom {
                grid.setWrapped(y, false)
            }
        }
        damage.insert(rows: top ..< bottom + 1)
        cursor.x = scrollLeft
        cursor.pendingWrap = false
    }

    /// DL: deletes lines at the cursor within the margins.
    private mutating func deleteLines(_ n: Int) {
        guard n > 0, cursor.y >= scrollTop, cursor.y <= scrollBottom,
              cursor.x >= scrollLeft, cursor.x <= scrollRight else { return }
        let top = cursor.y, bottom = scrollBottom
        for y in top ... bottom {
            rowWillBeShifted(y)
        }
        if hasHorizontalMargins {
            let k = min(n, bottom - top + 1)
            for y in stride(from: top, through: bottom - k, by: 1) {
                copyMarginCells(from: y + k, to: y)
            }
            for y in bottom - k + 1 ... bottom {
                clearCells(row: y, from: scrollLeft, to: scrollRight + 1)
            }
        } else {
            grid.scrollUp(top: top, bottom: bottom, count: n, fill: eraseCell)
            for y in top ... bottom {
                grid.setWrapped(y, false)
            }
        }
        damage.insert(rows: top ..< bottom + 1)
        cursor.x = scrollLeft
        cursor.pendingWrap = false
    }

    /// ICH: inserts blanks at the cursor, shifting cells up to the right
    /// margin.
    private mutating func insertBlanks(_ n: Int) {
        cursor.pendingWrap = false
        guard n > 0, cursor.x >= scrollLeft, cursor.x <= scrollRight else { return }
        let y = cursor.y, x = cursor.x
        let row = grid.row(y)
        if Self.kind(of: row[x]) == .spacerTail, x > 0 {
            clearCells(row: y, from: x - 1, to: x + 1)
        }
        let rem = scrollRight - x + 1
        if row[scrollRight].width == 2 {
            clearCells(row: y, from: scrollRight, to: min(scrollRight + 2, columns))
        }
        let count = min(n, rem)
        let keep = rem - count
        if keep > 0 {
            if row[x + keep - 1].width == 2 {
                clearCells(row: y, from: x + keep - 1, to: x + keep + 1)
            }
            (row + x + count).update(from: row + x, count: keep)
            grid.extend(y, to: x + count + keep)
        }
        clearCells(row: y, from: x, to: x + count)
    }

    /// DCH: deletes cells at the cursor, pulling in blanks at the right
    /// margin.
    private mutating func deleteChars(_ n: Int) {
        guard n > 0, cursor.x >= scrollLeft, cursor.x <= scrollRight else { return }
        let y = cursor.y, x = cursor.x
        let rem = scrollRight - x + 1
        let count = min(n, rem)
        splitCellBoundary(x)
        splitCellBoundary(x + count)
        splitCellBoundary(scrollRight + 1)
        let keep = rem - count
        if keep > 0 {
            let row = grid.row(y)
            (row + x).update(from: row + x + count, count: keep)
        }
        clearCells(row: y, from: x + keep, to: x + rem)
        resetCursorWrap()
    }

    // MARK: CSI

    mutating func csiDispatch(_ csi: borrowing CSISequence) {
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
        case (0x3F, 0, 0x4A): eraseDisplay(csi.value(0), selective: true) // DECSED
        case (0x3F, 0, 0x4B): eraseLine(csi.value(0), selective: true) // DECSEL
        case (0, 0x22, 0x71): // DECSCA " q
            switch csi.value(0) {
            case 0, 2: cursor.isProtected = false
            case 1:
                cursor.isProtected = true
                protectedMode = .dec
            default: break
            }
        case (0x3F, 0, 0x6E): // ? n
            switch csi.value(0) {
            case 6: reply("\u{1B}[?\(reportedRow);\(reportedColumn)R")
            case 996: reportColorScheme()
            default: break
            }
        case (0, 0x23, 0x7B), (0, 0x23, 0x70): pushPen() // XTPUSHSGR # { and # p
        case (0, 0x23, 0x7D), (0, 0x23, 0x71): popPen() // XTPOPSGR # } and # q
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
        case (0x3F, 0, 0x75): reply("\u{1B}[?\(keyboardFlags)u") // kitty keyboard query
        case (0x3E, 0, 0x75): // push
            if keyboardFlagStack.count >= 16 {
                keyboardFlagStack.removeFirst()
            }
            keyboardFlagStack.append(UInt8(clamping: csi.value(0)) & 0x1F)
        case (0x3C, 0, 0x75): // pop
            keyboardFlagStack.removeLast(min(max(csi.value(0), 1), keyboardFlagStack.count))
        case (0x3D, 0, 0x75): // set
            let flags = UInt8(clamping: csi.value(0)) & 0x1F
            let current = keyboardFlags
            let updated: UInt8 = switch csi.param(1, default: 1) {
            case 2: current | flags
            case 3: current & ~flags
            default: flags
            }
            if keyboardFlagStack.isEmpty {
                keyboardFlagStack.append(updated)
            } else {
                keyboardFlagStack[keyboardFlagStack.count - 1] = updated
            }
        default: break // unsupported: ignored
        }
    }

    private mutating func dispatchPlainCSI(_ csi: borrowing CSISequence) {
        let n = csi.param(0, default: 1)
        switch csi.final {
        case 0x40: insertBlanks(n) // ICH @
        case 0x41: cursorUp(n) // CUU A
        case 0x42: cursorDown(n) // CUD B
        case 0x65: setCursorRow(cursor.y + 1 + n, relative: true) // VPR e
        case 0x43: cursorRight(n) // CUF C
        case 0x61: setCursorColumn(cursor.x + 1 + n, relative: true) // HPR a
        case 0x44: cursorLeft(n) // CUB D
        case 0x45: cursorDown(n); carriageReturn() // CNL E
        case 0x46: cursorUp(n); carriageReturn() // CPL F
        case 0x47, 0x60: setCursorColumn(n) // CHA G, HPA `
        case 0x48, 0x66: setCursorPosition(row: n, column: csi.param(1, default: 1)) // CUP H, HVP f
        case 0x49: tabForward(n) // CHT I
        case 0x4A: eraseDisplay(csi.value(0)) // ED J
        case 0x4B: eraseLine(csi.value(0)) // EL K
        case 0x4C: insertLines(n) // IL L
        case 0x4D: deleteLines(n) // DL M
        case 0x50: deleteChars(n) // DCH P
        case 0x53: scrollUp(n) // SU S
        case 0x54: scrollDown(n) // SD T
        case 0x58: eraseChars(n) // ECH X
        case 0x5A: tabBackward(n) // CBT Z
        case 0x62: // REP b
            if lastPrinted != 0 {
                let c = lastPrinted
                for _ in 0 ..< min(n, 65535) {
                    print(c)
                }
            }
        case 0x63: if csi.value(0) == 0 {
                reply("\u{1B}[?62;22c")
            } // DA1
        case 0x64: setCursorRow(n) // VPA d
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
            case 6: reply("\u{1B}[\(reportedRow);\(reportedColumn)R")
            default: break
            }
        case 0x72: // DECSTBM r
            let top = max(1, csi.value(0))
            let bottom = min(rows, csi.value(1) == 0 ? rows : csi.value(1))
            if top < bottom {
                scrollTop = top - 1
                scrollBottom = bottom - 1
                setCursorPosition(row: 1, column: 1)
            }
        case 0x73: // DECSLRM s, or SCOSC without parameters unless DECLRMM
            if csi.count == 0, !modes.contains(.leftRightMargin) {
                saveCursor()
            } else {
                setLeftRightMargins(csi.value(0), csi.value(1))
            }
        case 0x74: windowOperation(csi) // XTWINOPS t
        case 0x75: restoreCursor() // SCORC u
        default: break
        }
    }

    private mutating func setLeftRightMargins(_ leftRequest: Int, _ rightRequest: Int) {
        guard modes.contains(.leftRightMargin) else { return }
        let left = max(1, leftRequest)
        let right = min(columns, rightRequest == 0 ? columns : rightRequest)
        guard left < right else { return }
        scrollLeft = left - 1
        scrollRight = right - 1
        setCursorPosition(row: 1, column: 1)
    }

    /// CHA / HPA / HPR: moves within the row (relative to the left margin
    /// in origin mode).
    private mutating func setCursorColumn(_ column: Int, relative: Bool = false) {
        let origin = modes.contains(.origin) && !relative
        let offset = origin ? scrollLeft : 0, limit = origin ? scrollRight + 1 : columns
        cursor.pendingWrap = false
        cursor.x = max(min(limit, max(column, 1) + offset) - 1, 0)
    }

    /// VPA / VPR: moves within the column (relative to the top margin in
    /// origin mode).
    private mutating func setCursorRow(_ row: Int, relative: Bool = false) {
        let origin = modes.contains(.origin) && !relative
        let offset = origin ? scrollTop : 0, limit = origin ? scrollBottom + 1 : rows
        cursor.pendingWrap = false
        cursor.y = max(min(limit, max(row, 1) + offset) - 1, 0)
    }

    private var reportedColumn: Int {
        modes.contains(.origin) ? cursor.x - scrollLeft + 1 : cursor.x + 1
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
        case 22: pushTitle()
        case 23: popTitle()
        default: break
        }
    }

    // MARK: SGR

    private mutating func selectGraphicRendition(_ csi: borrowing CSISequence) {
        if csi.count == 0 {
            // SGR leaves hyperlinks and protection alone.
            cursor.pen = CellAttributes(flags: cursor.pen.flags.intersection(.protected), link: cursor.pen.link)
            return
        }
        var pen = cursor.pen
        var i = 0
        while i < csi.count {
            let p = csi.value(i)
            switch p {
            case 0: pen = CellAttributes(flags: pen.flags.intersection(.protected), link: pen.link)
            case 1: pen.flags.insert(.bold)
            case 2: pen.flags.insert(.faint)
            case 3: pen.flags.insert(.italic)
            case 4:
                if csi.isSubparameter(i + 1) {
                    i += 1
                    pen.flags.subtract(.anyUnderline)
                    switch csi.value(i) {
                    case 0: break
                    case 2: pen.flags.insert(.doubleUnderline)
                    case 3: pen.flags.formUnion([.underline, .underlineStyleA])
                    case 4: pen.flags.formUnion([.underline, .underlineStyleB])
                    case 5: pen.flags.formUnion([.underline, .underlineStyleA, .underlineStyleB])
                    default: pen.flags.insert(.underline)
                    }
                } else {
                    pen.flags.subtract(.anyUnderline)
                    pen.flags.insert(.underline)
                }
            case 5, 6: pen.flags.insert(.blink)
            case 7: pen.flags.insert(.inverse)
            case 8: pen.flags.insert(.invisible)
            case 9: pen.flags.insert(.strikethrough)
            case 21: pen.flags.subtract(.anyUnderline); pen.flags.insert(.doubleUnderline)
            case 22: pen.flags.remove([.bold, .faint])
            case 23: pen.flags.remove(.italic)
            case 24: pen.flags.subtract(.anyUnderline)
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
            case 58: if let c = extendedColor(csi, &i) {
                    pen.underlineColor = internUnderlineColor(c)
                }
            case 59: pen.underlineColor = 0
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
        case .origin: setCursorPosition(row: 1, column: 1)
        case .reverseVideo, .synchronizedOutput: damage.setFull()
        case .leftRightMargin where !on:
            scrollLeft = 0
            scrollRight = columns - 1
        case .column132: setColumnMode(on)
        case .inBandResize where on: reportSize()
        default: break
        }
    }

    /// DECCOLM: switches between 80 and 132 columns when mode 40 allows it.
    private mutating func setColumnMode(_ wide: Bool) {
        guard modes.contains(.enableColumnMode) else {
            modes.remove(.column132)
            return
        }
        resize(columns: wide ? 132 : 80, rows: rows)
        eraseDisplay(2)
        setCursorPosition(row: 1, column: 1)
    }

    private mutating func enterAlternateScreen(clear: Bool) {
        guard !isAlternateScreen else { return }
        invalidateSelection()
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
        invalidateSelection()
        swap(&grid, &inactiveGrid)
        modes.remove(.alternateScreen)
        damage.setFull()
    }

    private mutating func saveCursor() {
        holdHyperlink(cursor.pen.link) // a restore may write with it later
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
        penLinkWillChange(to: saved.pen.link)
        cursor = saved
        cursor.x = min(cursor.x, columns - 1)
        cursor.y = min(cursor.y, rows - 1)
        if savedModes.contains(.origin) {
            modes.insert(.origin)
        } else {
            modes.remove(.origin)
        }
    }

    private mutating func softReset() {
        modes.subtract([.insert, .origin, .cursorKeys, .keypadApplication])
        modes.insert([.autowrap, .cursorVisible])
        cursor.pen = .default
        (cursor.g0, cursor.g1, cursor.g2, cursor.g3) = (.ascii, .ascii, .ascii, .ascii)
        cursor.gl = 0
        cursor.singleShift = nil
        cursor.pendingWrap = false
        protectedMode = .off
        scrollTop = 0
        scrollBottom = rows - 1
        scrollLeft = 0
        scrollRight = columns - 1
        savedPrimary = Cursor()
        savedAlternate = Cursor()
    }

    mutating func fullReset() {
        invalidateSelection()
        resetShellState()
        if programStatus.removeAll() {
            programStatusChanged = true
        }
        hyperlinks = []
        hyperlinkHashes = []
        hyperlinkIndex.removeAll(keepingCapacity: true)
        freeHyperlinkSlots = []
        hyperlinkLastRow = []
        hyperlinkScanCooldown = 0
        keyboardFlagStack = []
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
        scrollLeft = 0
        scrollRight = columns - 1
        protectedMode = .off
        tabStops = Self.defaultTabs(columns)
        viewportOffset = 0
        lastPrinted = 0
        damage.setFull()
    }

    // MARK: ESC

    mutating func escDispatch(intermediate: UInt8, final: UInt8) {
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
        case (0x28 ... 0x2B, _): // SCS: designate G0...G3
            let set: Cursor.Charset? = switch final {
            case 0x42: .ascii // B
            case 0x30: .decSpecialGraphics // 0
            case 0x41: .british // A
            default: nil
            }
            if let set {
                cursor.setCharset(intermediate - 0x28, set)
            }
        case (0, 0x4E): cursor.singleShift = 2 // SS2 N
        case (0, 0x4F): cursor.singleShift = 3 // SS3 O
        case (0, 0x6E): cursor.gl = 2 // LS2 n
        case (0, 0x6F): cursor.gl = 3 // LS3 o
        case (0, 0x56): // SPA V
            cursor.isProtected = true
            protectedMode = .iso
        case (0, 0x57): cursor.isProtected = false // EPA W
        case (0x23, 0x38): // DECALN #8
            cursor.pen = CellAttributes(
                foreground: cursor.pen.foreground, background: cursor.pen.background,
                flags: cursor.pen.flags.intersection(.protected), link: cursor.pen.link,
            )
            (scrollTop, scrollBottom, scrollLeft, scrollRight) = (0, rows - 1, 0, columns - 1)
            modes.remove(.origin)
            let e = Cell(glyph: 0x45, attributes: CellAttributes(
                foreground: cursor.pen.foreground, background: cursor.pen.background,
            ), width: 1)
            for y in 0 ..< rows {
                grid.fill(row: y, from: 0, to: columns, with: e)
                grid.setWrapped(y, false)
            }
            setCursorPosition(row: 1, column: 1)
            damage.setFull()
        default: break
        }
    }

    mutating func reply(_ s: String) {
        guard !discardsReplies else { return }
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
        if modes.contains(.synchronizedOutput) {
            modes.remove(.synchronizedOutput) // a resize ends a synchronized update
            damage.setFull()
        }
        guard newColumns != columns || newRows != rows else { return }
        clearPromptForResize()
        // A height-only change (an on-screen keyboard, an edit menu) keeps
        // lines intact, so a selection survives it; the rebuilt history
        // renumbers lines from zero, hence the shift. A width change
        // re-wraps lines and drops it.
        let carriedSelection = newColumns == columns ? selection : nil
        let firstBefore = firstAbsoluteRow
        invalidateSelection()
        forgetHyperlinkRows()
        let alternate = isAlternateScreen
        if alternate {
            swap(&grid, &inactiveGrid)
        } // `grid` is primary now
        // The live cursor first: it must stay on screen.
        var cursors = alternate ? [savedPrimary] : [cursor, savedPrimary]
        reflowPrimary(columns: newColumns, rows: newRows, cursors: &cursors, rewrap: modes.contains(.autowrap))
        if alternate {
            savedPrimary = cursors[0]
            swap(&grid, &inactiveGrid)
            grid.resize(columns: newColumns, rows: newRows)
            cursor.x = min(cursor.x, newColumns - 1)
            cursor.y = min(cursor.y, newRows - 1)
            cursor.pendingWrap = cursor.pendingWrap && cursor.x == newColumns - 1
        } else {
            cursor = cursors[0]
            savedPrimary = cursors[1]
            inactiveGrid.resize(columns: newColumns, rows: newRows)
        }
        savedAlternate.x = min(savedAlternate.x, newColumns - 1)
        savedAlternate.y = min(savedAlternate.y, newRows - 1)
        columns = newColumns
        rows = newRows
        scrollTop = 0
        scrollBottom = newRows - 1
        scrollLeft = 0
        scrollRight = newColumns - 1
        if tabStops.count != newColumns {
            tabStops = Self.defaultTabs(newColumns)
        }
        viewportOffset = min(viewportOffset, grid.historyCount)
        if var carried = carriedSelection {
            let shift = isAlternateScreen ? 0 : -firstBefore
            carried.anchor.row += shift
            carried.head.row += shift
            if carried.end.row >= firstAbsoluteRow {
                setSelection(carried)
            }
        }
        if modes.contains(.inBandResize) {
            reportSize()
        }
        damage.setFull()
    }

    /// Re-wraps primary screen + scrollback to a new width, keeping each
    /// cursor on the same logical position (a pending wrap is the position
    /// after its cell). Without `rewrap` (autowrap off) rows are truncated
    /// instead. Allocates temporaries; resize is not a hot path.
    private mutating func reflowPrimary(columns newColumns: Int, rows newRows: Int, cursors: inout [Cursor], rewrap: Bool) {
        // A height change keeps the old top row in place, as Ghostty does:
        // shrinking drops blank rows below the content before pushing rows
        // into history, and growing pulls history back down only when the
        // live cursor sits on the bottom row. The old top row is tracked as
        // one more mark. A width change re-wraps and keeps the bottom.
        let pullsHistory = newColumns != grid.columns
            || (newRows > grid.rows && cursors[0].y >= grid.rows - 1)
        let screenTopMark = cursors.count
        cursors.append(Cursor())
        defer { cursors.removeLast() }
        // 1. Gather logical lines.
        var lastRow = min(cursors.map(\.y).max() ?? 0, grid.rows - 1)
        for y in stride(from: grid.rows - 1, to: lastRow, by: -1)
            where grid.cells(row: y).contains(where: { !$0.isBlank }) {
            lastRow = y
            break
        }
        var cells: [Cell] = []
        var lineStarts: [Int] = []
        var lineWrapped: [Bool] = []
        var lineMarks: [UInt8] = []
        var lineOpen = false
        // Per cursor: logical line, offset in it, and pending wrap.
        var marks = cursors.map { _ in (line: 0, offset: 0, pending: false) }
        let history = grid.historyCount
        for p in 0 ..< history + lastRow + 1 {
            let (row, wrapped) = p < history ? grid.historyLine(p) : (grid.cells(row: p - history), grid.isWrapped(p - history))
            if !lineOpen {
                lineStarts.append(cells.count)
                lineWrapped.append(wrapped)
                lineMarks.append(p < history ? grid.historyMarkBits(p) : grid.markBits(p - history))
                lineOpen = true
            }
            for (i, c) in cursors.enumerated() where p == history + c.y {
                let line = lineStarts.count - 1
                let x = rewrap ? c.x : min(c.x, newColumns - 1)
                let pending = c.pendingWrap && x == c.x
                marks[i] = (line, cells.count - lineStarts[line] + x + (pending ? 1 : 0), pending)
            }
            var length = row.count
            if !wrapped || !rewrap {
                while length > 0, row[length - 1].isBlank {
                    length -= 1
                }
            }
            for k in 0 ..< length where rewrap ? !row[k].flags.contains(.spacerHead) : true {
                cells.append(row[k])
            }
            if !wrapped || !rewrap {
                lineOpen = false
            }
        }
        lineStarts.append(cells.count)

        // 2. Re-wrap into rows of the new width.
        var out: [Cell] = []
        var outWrapped: [Bool] = []
        var outMarks: [UInt8] = []
        var placed = cursors.map { _ in (row: -1, column: 0, pending: false) }
        func newRow() {
            out.append(contentsOf: repeatElement(Cell.blank, count: newColumns))
            outWrapped.append(false)
            outMarks.append(0)
        }
        for line in 0 ..< lineStarts.count - 1 {
            let lo = lineStarts[line], hi = lineStarts[line + 1]
            newRow()
            outMarks[outMarks.count - 1] = lineMarks[line]
            var col = 0
            for k in lo ..< hi {
                let cell = cells[k]
                for i in marks.indices where marks[i].line == line && k - lo == marks[i].offset && placed[i].row < 0 {
                    placed[i] = (outWrapped.count - 1, min(col, newColumns - 1), false)
                }
                if cell.width == 0 {
                    continue
                } // tails are re-created with their lead
                let w = Int(cell.width)
                if col + w > newColumns {
                    guard rewrap else { break } // truncated; a cut wide character is dropped
                    if w == 2, col < newColumns {
                        out[out.count - newColumns + col] = Cell(glyph: 0, attributes: CellAttributes(flags: .spacerHead), width: 1)
                    }
                    outWrapped[outWrapped.count - 1] = true
                    newRow()
                    col = 0
                    for i in marks.indices where marks[i].line == line && k - lo == marks[i].offset {
                        placed[i] = (outWrapped.count - 1, 0, false)
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
            if !rewrap {
                outWrapped[outWrapped.count - 1] = lineWrapped[line]
            }
            for i in marks.indices where marks[i].line == line && placed[i].row < 0 {
                // The cursor sits past the end of the line's content.
                // Blank cells after it are not kept, so it is clamped to
                // the last column; a pending wrap there stays pending.
                let position = col + (marks[i].offset - (hi - lo))
                let pending = marks[i].pending && position == newColumns
                placed[i] = (outWrapped.count - 1, min(position, newColumns - 1), pending)
            }
        }
        for i in placed.indices where placed[i].row < 0 {
            newRow()
            placed[i] = (outWrapped.count - 1, 0, false)
        }

        // 3. Split between scrollback and screen, keeping the live cursor visible.
        let total = outWrapped.count
        var top = max(0, total - newRows)
        if !pullsHistory {
            top = max(top, placed[screenTopMark].row)
        }
        // Keep the live cursor visible, but never at the cost of rows below
        // the screen: those would be neither on screen nor in history.
        if placed[0].row < top {
            top = max(placed[0].row, total - newRows)
        }
        grid.reset(columns: newColumns, rows: newRows)
        out.withUnsafeBufferPointer { buf in
            for r in 0 ..< top {
                grid.appendHistory(
                    UnsafeBufferPointer(rebasing: buf[r * newColumns ..< (r + 1) * newColumns]),
                    wrapped: outWrapped[r], marks: outMarks[r],
                )
            }
            for r in top ..< min(total, top + newRows) {
                grid.setRow(
                    r - top, UnsafeBufferPointer(rebasing: buf[r * newColumns ..< (r + 1) * newColumns]),
                    wrapped: outWrapped[r], marks: outMarks[r],
                )
            }
        }
        for i in cursors.indices {
            cursors[i].x = placed[i].column
            cursors[i].y = min(max(placed[i].row - top, 0), newRows - 1)
            cursors[i].pendingWrap = placed[i].pending
        }
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
        // Live clusters alone may exceed the threshold; wait for as much
        // garbage again so compaction stays amortized.
        fresh.compactionLimit = max(GraphemeTable.compactionThreshold, fresh.scalars.count * 2)
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
