import Foundation

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

  public internal(set) var cursor = Cursor()
  var savedPrimary = Cursor()
  var savedAlternate = Cursor()
  /// Position of the live primary cursor while its grid is inactive;
  /// independent of the application's DECSC saved cursor.
  var inactivePrimaryCursor = Cursor()
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
  /// Identifies each new synchronized frame, even when a single parser
  /// batch ends one frame and begins the next.
  private(set) var synchronizedOutputGeneration: UInt64 = 0
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

  public var title: String { String(decoding: titleBytes, as: UTF8.self) }

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
  private var inactiveKeyboardFlagStack: [UInt8] = []
  public var keyboardFlags: UInt8 { keyboardFlagStack.last ?? 0 }

  /// OSC 8 targets by id (1...255); ids are reused round-robin.
  var hyperlinks: [[UInt8]] = []
  var hyperlinkHashes: [UInt64] = []
  var hyperlinkIndex: [UInt64: UInt8] = Dictionary(minimumCapacity: 512)
  var freeHyperlinkSlots: [Int] = []
  /// Per slot: last absolute row its cells can occupy (.max: unknown).
  var hyperlinkLastRow: [Int] = []
  var hyperlinkScanCooldown = 0
  /// First history row at which a fully occupied link table may free an id.
  var hyperlinkReclaimAfter: Int?

  /// Current selection, in absolute rows (see `Selection.swift`).
  public internal(set) var selection: Selection?
  /// Changes when resizing, clearing, resetting or switching screens
  /// invalidates retained cell coordinates. Ordinary output and viewport
  /// scrolling preserve it; callers must also check row availability.
  public internal(set) var addressingGeneration: UInt64 = 0
  /// Search matches ordered by start and end position, and the selected index.
  public internal(set) var searchMatches: [TerminalRange] = []
  public internal(set) var searchSelected: Int?
  var searchQuery: String?
  var searchNeedsRefresh = false

  /// tmux control-mode bytes received since the host last drained them.
  public var controlModeData: [UInt8] = []
  /// Byte offsets for pending end events, keeping multiple streams apart.
  var controlModeEndOffsets: [Int] = []
  public internal(set) var isControlMode = false
  var dcsKind = DCSKind.ignored
  var dcsBuffer: [UInt8] = []

  enum DCSKind: Sendable { case ignored, tmux, termcap, statusString }

  /// Pixel size of one cell, for XTWINOPS and in-band resize reports.
  public var cellPixelSize = (width: 0, height: 0) {
    didSet {
      cellPixelSize = (
        max(0, cellPixelSize.width), max(0, cellPixelSize.height)
      )
      if cellPixelSize.width != oldValue.width
        || cellPixelSize.height != oldValue.height,
        modes.contains(.inBandResize)
      {
        reportSize()
      }
    }
  }

  var textAreaPixelSize: (width: Int, height: Int) {
    func extent(_ cells: Int, _ size: Int) -> Int {
      let (value, overflow) = cells.multipliedReportingOverflow(by: size)
      return overflow ? Int.max : value
    }
    return (
      extent(columns, cellPixelSize.width), extent(rows, cellPixelSize.height)
    )
  }

  /// Shell integration and host-facing state (`TerminalState+Shell.swift`).
  public internal(set) var semanticState = SemanticState.none
  /// Which prompt rows the shell redraws after a resize (OSC 133 `redraw`).
  var promptRedraw = PromptRedraw.none
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

  let widths = UnicodeWidth.table
  var lastPrinted: UInt32 = 0

  /// Creates a blank terminal; nonpositive screen dimensions become one.
  /// History uses `scrollbackLimitBytes`, capped by `scrollbackLimitRows`.
  /// Nonpositive history limits disable history.
  public init(
    columns: Int,
    rows: Int,
    scrollbackLimitBytes: Int = 10_000_000,
    scrollbackLimitRows: Int = 100_000,
    palette: Palette = .standard,
  ) {
    let columns = max(1, columns)
    let rows = max(1, rows)
    self.columns = columns
    self.rows = rows
    grid = Grid(
      columns: columns,
      rows: rows,
      historyLimitBytes: scrollbackLimitBytes,
      maxHistoryRows: scrollbackLimitRows,
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
    controlModeEndOffsets.removeAll(keepingCapacity: true)
    guard !events.isEmpty || titleChanged || directoryChanged || commandFinished
    else { return [] }
    var out = events
    events.removeAll(keepingCapacity: true)
    if titleChanged { out.append(.title(title)) }
    if directoryChanged,
      let url = URL(string: String(decoding: directoryBytes, as: UTF8.self)),
      url.isFileURL
    {
      out.append(.workingDirectory(url.path))
    }
    if commandFinished { out.append(.commandFinished(exitCode: lastExitCode)) }
    titleChanged = false
    directoryChanged = false
    commandFinished = false
    return out
  }

  static func replace(
    _ target: inout [UInt8],
    with bytes: UnsafeBufferPointer<UInt8>
  ) -> Bool {
    if target.elementsEqual(bytes) { return false }
    target.removeAll(keepingCapacity: true)
    target.append(contentsOf: bytes)
    return true
  }

  public var isAlternateScreen: Bool { modes.contains(.alternateScreen) }

  public mutating func takeDamage() -> DamageRegion {
    let d = damage
    damage = .none
    return d
  }

  // MARK: C0 controls

  mutating func execute(_ byte: UInt8) {
    switch byte {
    case 0x07: events.append(.bell)
    case 0x08: cursorLeft(1)  // BS
    case 0x09: tabForward(1)
    case 0x0A, 0x0B, 0x0C:
      index()
      if modes.contains(.linefeedNewline) { carriageReturn() }
    case 0x0D: carriageReturn()
    case 0x0E: cursor.gl = 1  // SO
    case 0x0F: cursor.gl = 0  // SI
    default: break
    }
  }

  private mutating func carriageReturn() {
    cursor.pendingWrap = false
    cursor.x =
      modes.contains(.origin) || cursor.x >= scrollLeft ? scrollLeft : 0
  }

  /// IND: move down, scrolling the region at its bottom margin.
  mutating func index() {
    cursor.pendingWrap = false
    if cursor.y < scrollTop || cursor.y > scrollBottom {
      if cursor.y < rows - 1 { cursor.y += 1 }
      return
    }
    if cursor.y == scrollBottom, cursor.x >= scrollLeft, cursor.x <= scrollRight
    {
      if scrollTop == 0, !hasHorizontalMargins,
        !isAlternateScreen || scrollBottom == 0
      {
        scrollIntoHistory(1)
      } else if hasHorizontalMargins {
        scrollUp(1)
      } else {
        invalidateSelection(
          rows: scrollTop ..< scrollBottom + 1,
          from: 0,
          to: columns
        )
        grid.scrollUp(
          top: scrollTop,
          bottom: scrollBottom,
          count: 1,
          fill: eraseCell
        )
        markScrolled()
      }
      return
    }
    if cursor.y < scrollBottom { cursor.y += 1 }
  }

  /// RI: move up, scrolling the region down at its top margin.
  mutating func reverseIndex() {
    if cursor.y != scrollTop || cursor.x < scrollLeft || cursor.x > scrollRight
    {
      cursorUp(1)
    } else {
      scrollDown(1)
    }
  }

  var eraseCell: Cell { .erased(background: cursor.pen.background) }

  var hasHorizontalMargins: Bool {
    scrollLeft != 0 || scrollRight != columns - 1
  }

  /// Scrolls rows `0...scrollBottom` up by `count`, the top ones into
  /// the primary screen's history; rows below the region stay put.
  private mutating func scrollIntoHistory(_ count: Int) {
    let n = min(count, scrollBottom + 1)
    guard n > 0 else { return }
    if isAlternateScreen {
      invalidateSelection(rows: 0 ..< scrollBottom + 1, from: 0, to: columns)
      grid.scrollUp(top: 0, bottom: scrollBottom, count: n, fill: eraseCell)
    } else {
      let regionEnd = screenAbsoluteRow(scrollBottom)
      grid.scrollUpIntoHistory(count: n, bottom: scrollBottom, fill: eraseCell)
      if let selection {
        // Stationary rows below the region acquire new absolute row
        // numbers. A selection crossing the boundary is no longer
        // contiguous because the region gains blank rows between them.
        if selection.start.row <= regionEnd, selection.end.row > regionEnd {
          setSelection(nil)
        } else {
          var retained = selection
          if retained.start.row > regionEnd {
            retained.anchor.row += n
            retained.head.row += n
          }
          clipSelectionToAvailableRows(retained)
        }
      }
      if viewportOffset > 0 {
        viewportOffset = min(viewportOffset + n, grid.historyCount)
      }
    }
    markScrolled()
  }

  /// SU: scrolls the region up; a full-width region at the top of the
  /// primary screen feeds the scrollback.
  mutating func scrollUp(_ count: Int) {
    if scrollTop == 0, !hasHorizontalMargins,
      !isAlternateScreen || scrollBottom == rows - 1
    {
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
    markSearchDirty()
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
    let xOffset = origin ? scrollLeft : 0
    let yOffset = origin ? scrollTop : 0
    let xMax = origin ? scrollRight + 1 : columns
    let yMax = origin ? scrollBottom + 1 : rows
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
    let limit =
      cursor.y <= scrollBottom ? scrollBottom - cursor.y : rows - cursor.y - 1
    cursor.y += min(limit, max(n, 1))
  }

  private mutating func cursorRight(_ n: Int) {
    cursor.pendingWrap = false
    let limit =
      cursor.x <= scrollRight ? scrollRight - cursor.x : columns - cursor.x - 1
    cursor.x += min(limit, max(n, 1))
  }

  /// CUB / BS, with reverse wrap (modes 45 / 1045) when autowrap is on.
  private mutating func cursorLeft(_ n: Int) {
    enum Wrap { case none, reverse, extended }
    let wrap: Wrap =
      !modes.contains(.autowrap)
      ? .none
      : modes.contains(.reverseWrapExtended)
        ? .extended : modes.contains(.reverseWrap) ? .reverse : .none
    var count = max(n, 1)
    if wrap == .none {
      cursor.x -= min(count, cursor.x)
      cursor.pendingWrap = false
      return
    }
    if cursor.pendingWrap {
      count -= 1
      cursor.pendingWrap = false
      if count == 0 { return }
    }
    let top = scrollTop
    let bottom = scrollBottom
    let right = scrollRight
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
      if count == 0 { break }
      if cursor.y == top {
        if wrap != .extended { break }
        cursor.x = right
        cursor.y = bottom
        count -= 1
        continue
      }
      if cursor.y == 0 { break }
      if wrap != .extended, !grid.isWrapped(cursor.y - 1) { break }
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
        if tabStops[cursor.x] { break }
      }
      if cursor.x == start { break }
    }
  }

  /// CBT: to the previous tab stop (the left margin in origin mode).
  private mutating func tabBackward(_ n: Int) {
    let limit = modes.contains(.origin) ? scrollLeft : 0
    for _ in 0 ..< max(n, 1) {
      let start = cursor.x
      while cursor.x > limit {
        cursor.x -= 1
        if tabStops[cursor.x] { break }
      }
      if cursor.x == start { break }
    }
  }

  // MARK: Erase / edit

  /// Blanks `x0..<x1` on row `y` with the pen's background; with
  /// `protected`, cells protected by DECSCA/SPA are skipped.
  private mutating func clearCells(
    row y: Int,
    from x0: Int,
    to x1: Int,
    protected: Bool = false
  ) {
    guard x0 < x1 else { return }
    if protected {
      let row = grid._unsafeRow(y)
      var a = x0
      while a < x1 {
        while a < x1, row[a].flags.contains(.protected) { a += 1 }
        var b = a
        while b < x1, !row[b].flags.contains(.protected) { b += 1 }
        invalidateSelection(rows: y ..< y + 1, from: a, to: b)
        grid.fill(row: y, from: a, to: b, with: eraseCell)
        a = b
      }
    } else {
      invalidateSelection(rows: y ..< y + 1, from: x0, to: x1)
      grid.fill(row: y, from: x0, to: x1, with: eraseCell)
    }
    damage.insert(row: y)
  }

  /// Clears a wide character straddling the boundary before column `x`
  /// of the cursor row (Ghostty `splitCellBoundary`).
  private mutating func splitCellBoundary(_ x: Int, protected: Bool = false) {
    let y = cursor.y
    let row = grid._unsafeRow(y)
    if x == columns {
      if grid.isWrapped(y), row[columns - 1].flags.contains(.spacerHead) {
        clearCells(row: y, from: columns - 1, to: columns, protected: protected)
      }
      return
    }
    if x <= 1, y > 0, grid.isWrapped(y - 1), row[0].width == 2,
      grid._unsafeRow(y - 1)[columns - 1].flags.contains(.spacerHead)
    {
      clearCells(
        row: y - 1,
        from: columns - 1,
        to: columns,
        protected: protected
      )
    }
    if x > 0, row[x - 1].width == 2 {
      clearCells(row: y, from: x - 1, to: x + 1, protected: protected)
    }
  }

  /// Clears the pending wrap and unwraps the cursor row.
  private mutating func resetCursorWrap(protected: Bool = false) {
    cursor.pendingWrap = false
    guard grid.isWrapped(cursor.y) else { return }
    markSearchDirty()
    grid.setWrapped(cursor.y, false)
    let row = grid._unsafeRow(cursor.y)
    if row[columns - 1].flags.contains(.spacerHead) {
      if protected, row[columns - 1].flags.contains(.protected) {
        // Unwrapping removes the spacer role, but a protected blank
        // still keeps its colors, attributes, and selection.
        row[columns - 1].attributes.flags.remove(.spacerHead)
        damage.insert(row: cursor.y)
      } else {
        clearCells(row: cursor.y, from: columns - 1, to: columns)
      }
    }
  }

  /// ECH: erases `n` cells from the cursor, including a wide character's
  /// tail at the end.
  private mutating func eraseChars(_ n: Int) {
    let protected = protectedMode == .iso
    let remaining = columns - cursor.x
    var count = min(remaining, max(n, 1))
    if count != remaining,
      grid._unsafeRow(cursor.y)[cursor.x + count - 1].width == 2
    {
      count += 1
    }
    splitCellBoundary(cursor.x, protected: protected)
    splitCellBoundary(cursor.x + count, protected: protected)
    resetCursorWrap(protected: protected)
    clearCells(
      row: cursor.y,
      from: cursor.x,
      to: cursor.x + count,
      protected: protected
    )
  }

  /// EL / DECSEL (`selective`: protected cells survive).
  private mutating func eraseLine(_ mode: Int, selective: Bool = false) {
    let protected = selective || protectedMode == .iso
    let row = grid._unsafeRow(cursor.y)
    let start: Int
    let end: Int
    switch mode {
    case 0:
      var x = cursor.x
      if x > 0, Self.kind(of: row[x]) == .spacerTail { x -= 1 }
      resetCursorWrap(protected: protected)
      (start, end) = (x, columns)
    case 1:
      let x = row[cursor.x].width == 2 ? cursor.x + 1 : cursor.x
      (start, end) = (0, x + 1)
    case 2:
      resetCursorWrap(protected: protected)
      (start, end) = (0, columns)
    default: return
    }
    cursor.pendingWrap = false
    clearCells(row: cursor.y, from: start, to: end, protected: protected)
  }

  /// Clears whole rows; an unprotected clear also unwraps them.
  private mutating func clearRows(_ range: Range<Int>, protected: Bool) {
    for y in range {
      clearCells(row: y, from: 0, to: columns, protected: protected)
      if !protected {
        grid.setWrapped(y, false)
        grid.clearMarks(y)  // the prompt or output it marked is gone
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
      addressingGeneration &+= 1
      clearRows(0 ..< rows, protected: protected)
      cursor.pendingWrap = false
    case 3:
      addressingGeneration &+= 1
      invalidateSelection()
      forgetHyperlinkRows()
      if isAlternateScreen {
        inactiveGrid.clearHistory()
      } else {
        grid.clearHistory()
      }
      viewportOffset = 0
      damage.setFull()
    case 22:  // scroll the screen's contents into history
      var used = 0
      for y in stride(from: rows - 1, through: 0, by: -1)
      where grid._unsafeCells(row: y).contains(where: { !$0.isBlank }) {
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
  private mutating func rowWillBeShifted(_ y: Int) {
    invalidateSelection(
      rows: y ..< y + 1,
      from: scrollLeft,
      to: scrollRight + 1
    )
    let row = grid._unsafeRow(y)
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
    (grid._unsafeRow(dst) + scrollLeft)
      .update(from: grid._unsafeRow(src) + scrollLeft, count: n)
    grid.extend(dst, to: scrollRight + 1)
  }

  /// IL: inserts blank lines at the cursor within the margins.
  private mutating func insertLines(_ n: Int) {
    guard n > 0, cursor.y >= scrollTop, cursor.y <= scrollBottom,
      cursor.x >= scrollLeft, cursor.x <= scrollRight
    else { return }
    let top = cursor.y
    let bottom = scrollBottom
    for y in top ... bottom { rowWillBeShifted(y) }
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
      for y in top ... bottom { grid.setWrapped(y, false) }
    }
    damage.insert(rows: top ..< bottom + 1)
    cursor.x = scrollLeft
    cursor.pendingWrap = false
  }

  /// DL: deletes lines at the cursor within the margins.
  private mutating func deleteLines(_ n: Int) {
    guard n > 0, cursor.y >= scrollTop, cursor.y <= scrollBottom,
      cursor.x >= scrollLeft, cursor.x <= scrollRight
    else { return }
    let top = cursor.y
    let bottom = scrollBottom
    for y in top ... bottom { rowWillBeShifted(y) }
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
      for y in top ... bottom { grid.setWrapped(y, false) }
    }
    damage.insert(rows: top ..< bottom + 1)
    cursor.x = scrollLeft
    cursor.pendingWrap = false
  }

  /// ICH: inserts blanks at the cursor, shifting cells up to the right
  /// margin.
  mutating func insertBlanks(_ n: Int) {
    cursor.pendingWrap = false
    guard n > 0, cursor.x >= scrollLeft, cursor.x <= scrollRight else { return }
    let y = cursor.y
    let x = cursor.x
    invalidateSelection(rows: y ..< y + 1, from: x, to: scrollRight + 1)
    let row = grid._unsafeRow(y)
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
    let y = cursor.y
    let x = cursor.x
    let rem = scrollRight - x + 1
    invalidateSelection(rows: y ..< y + 1, from: x, to: scrollRight + 1)
    let count = min(n, rem)
    splitCellBoundary(x)
    splitCellBoundary(x + count)
    splitCellBoundary(scrollRight + 1)
    let keep = rem - count
    if keep > 0 {
      let row = grid._unsafeRow(y)
      (row + x).update(from: row + x + count, count: keep)
    }
    clearCells(row: y, from: x + keep, to: x + rem)
    resetCursorWrap()
  }

  // MARK: CSI

  mutating func csiDispatch(_ csi: borrowing CSISequence) {
    let marker = csi.marker
    let inter = csi.intermediate
    if marker == 0, inter == 0 {
      dispatchPlainCSI(csi)
      return
    }
    switch (marker, inter, csi.final) {
    case (0x3F, 0, 0x68):
      for i in 0 ..< csi.count { setDECMode(csi.value(i), true) }  // ? h
    case (0x3F, 0, 0x6C):
      for i in 0 ..< csi.count { setDECMode(csi.value(i), false) }  // ? l
    case (0x3F, 0, 0x4A): eraseDisplay(csi.value(0), selective: true)  // DECSED
    case (0x3F, 0, 0x4B): eraseLine(csi.value(0), selective: true)  // DECSEL
    case (0, 0x22, 0x71):  // DECSCA " q
      switch csi.value(0) {
      case 0, 2: cursor.isProtected = false
      case 1:
        cursor.isProtected = true
        protectedMode = .dec
      default: break
      }
    case (0x3F, 0, 0x6E):  // ? n
      switch csi.value(0) {
      case 6: reply("\u{1B}[?\(reportedRow);\(reportedColumn)R")
      case 996: reportColorScheme()
      default: break
      }
    case (0, 0x23, 0x7B), (0, 0x23, 0x70): pushPen()  // XTPUSHSGR # { and # p
    case (0, 0x23, 0x7D), (0, 0x23, 0x71): popPen()  // XTPOPSGR # } and # q
    case (0x3F, 0x24, 0x70):  // DECRQM ? $ p
      let n = csi.value(0)
      let state = Modes.dec(n).map { modes.contains($0) ? 1 : 2 } ?? 0
      reply("\u{1B}[?\(n);\(state)$y")
    case (0, 0x24, 0x70):  // ANSI DECRQM
      let n = csi.value(0)
      let state = Modes.ansi(n).map { modes.contains($0) ? 1 : 2 } ?? 0
      reply("\u{1B}[\(n);\(state)$y")
    case (0x3E, 0, 0x63): reply("\u{1B}[>1;10;0c")  // DA2
    case (0x3E, 0, 0x71): reply("\u{1B}P>|swiftty 0.1\u{1B}\\")  // XTVERSION
    case (0, 0x20, 0x71):  // DECSCUSR
      let p = csi.value(0)
      guard csi.count <= 1, (0 ... 6).contains(p) else { return }
      cursorStyle = p <= 2 ? .block : p <= 4 ? .underline : .bar
      if p == 0 || p % 2 == 1 {
        modes.insert(.cursorBlink)
      } else {
        modes.remove(.cursorBlink)
      }
    case (0, 0x21, 0x70): softReset()  // DECSTR
    // kitty keyboard query
    case (0x3F, 0, 0x75): reply("\u{1B}[?\(keyboardFlags)u")
    case (0x3E, 0, 0x75):  // push
      if keyboardFlagStack.count >= 16 { keyboardFlagStack.removeFirst() }
      keyboardFlagStack.append(UInt8(clamping: csi.value(0)) & 0x1F)
    case (0x3C, 0, 0x75):  // pop
      keyboardFlagStack.removeLast(
        min(max(csi.value(0), 1), keyboardFlagStack.count)
      )
    case (0x3D, 0, 0x75):  // set
      let flags = UInt8(clamping: csi.value(0)) & 0x1F
      let current = keyboardFlags
      let updated: UInt8 =
        switch csi.param(1, default: 1) {
        case 2: current | flags
        case 3: current & ~flags
        default: flags
        }
      if keyboardFlagStack.isEmpty {
        keyboardFlagStack.append(updated)
      } else {
        keyboardFlagStack[keyboardFlagStack.count - 1] = updated
      }
    default: break  // unsupported: ignored
    }
  }

  private mutating func dispatchPlainCSI(_ csi: borrowing CSISequence) {
    let n = csi.param(0, default: 1)
    switch csi.final {
    case 0x40: insertBlanks(n)  // ICH @
    case 0x41: cursorUp(n)  // CUU A
    case 0x42: cursorDown(n)  // CUD B
    case 0x65: setCursorRow(cursor.y + 1 + n, relative: true)  // VPR e
    case 0x43: cursorRight(n)  // CUF C
    case 0x61: setCursorColumn(cursor.x + 1 + n, relative: true)  // HPR a
    case 0x44: cursorLeft(n)  // CUB D
    case 0x45:
      cursorDown(n);
      carriageReturn()  // CNL E
    case 0x46:
      cursorUp(n);
      carriageReturn()  // CPL F
    case 0x47, 0x60: setCursorColumn(n)  // CHA G, HPA `
    case 0x48, 0x66:
      // CUP H, HVP f
      setCursorPosition(row: n, column: csi.param(1, default: 1))
    case 0x49: tabForward(n)  // CHT I
    case 0x4A: eraseDisplay(csi.value(0))  // ED J
    // EL K
    case 0x4B: eraseLine(csi.value(0))
    case 0x4C: insertLines(n)  // IL L
    case 0x4D: deleteLines(n)  // DL M
    case 0x50: deleteChars(n)  // DCH P
    case 0x53: scrollUp(n)  // SU S
    case 0x54: scrollDown(n)  // SD T
    case 0x58: eraseChars(n)  // ECH X
    case 0x5A: tabBackward(n)  // CBT Z
    case 0x62:  // REP b
      if lastPrinted != 0 {
        let c = lastPrinted
        for _ in 0 ..< min(n, 65535) { print(c) }
      }
    case 0x63: if csi.value(0) == 0 { reply("\u{1B}[?62;22c") }  // DA1
    case 0x64: setCursorRow(n)  // VPA d
    case 0x67:  // TBC g
      switch csi.value(0) {
      case 0: tabStops[cursor.x] = false
      case 3: for i in tabStops.indices { tabStops[i] = false }
      default: break
      }
    // SM h
    case 0x68: for i in 0 ..< csi.count { setANSIMode(csi.value(i), true) }
    // RM l
    case 0x6C: for i in 0 ..< csi.count { setANSIMode(csi.value(i), false) }
    case 0x6D: selectGraphicRendition(csi)  // SGR m
    // DSR n
    case 0x6E:
      switch csi.value(0) {
      case 5: reply("\u{1B}[0n")
      case 6: reply("\u{1B}[\(reportedRow);\(reportedColumn)R")
      default: break
      }
    case 0x72:  // DECSTBM r
      let top = max(1, csi.value(0))
      let bottom = min(rows, csi.value(1) == 0 ? rows : csi.value(1))
      if top < bottom {
        scrollTop = top - 1
        scrollBottom = bottom - 1
        setCursorPosition(row: 1, column: 1)
      }
    case 0x73:  // DECSLRM s, or SCOSC without parameters unless DECLRMM
      if csi.count == 0, !modes.contains(.leftRightMargin) {
        saveCursor()
      } else {
        setLeftRightMargins(csi.value(0), csi.value(1))
      }
    case 0x74: windowOperation(csi)  // XTWINOPS t
    case 0x75: restoreCursor()  // SCORC u
    default: break
    }
  }

  private mutating func setLeftRightMargins(
    _ leftRequest: Int,
    _ rightRequest: Int
  ) {
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
    let offset = origin ? scrollLeft : 0
    let limit = origin ? scrollRight + 1 : columns
    cursor.pendingWrap = false
    cursor.x = max(min(limit, max(column, 1) + offset) - 1, 0)
  }

  /// VPA / VPR: moves within the column (relative to the top margin in
  /// origin mode).
  private mutating func setCursorRow(_ row: Int, relative: Bool = false) {
    let origin = modes.contains(.origin) && !relative
    let offset = origin ? scrollTop : 0
    let limit = origin ? scrollBottom + 1 : rows
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
      reply("\u{1B}[4;\(textAreaPixelSize.height);\(textAreaPixelSize.width)t")
    case 16: reply("\u{1B}[6;\(cellPixelSize.height);\(cellPixelSize.width)t")
    case 18: reply("\u{1B}[8;\(rows);\(columns)t")
    case 22: pushTitle()
    case 23: popTitle()
    default: break
    }
  }

  // MARK: Modes

  private mutating func setANSIMode(_ n: Int, _ on: Bool) {
    guard let mode = Modes.ansi(n) else { return }
    if on { modes.insert(mode) } else { modes.remove(mode) }
  }

  private mutating func setDECMode(_ n: Int, _ on: Bool) {
    switch n {
    case 1049:
      if on {
        saveCursor()
        enterAlternateScreen()
        // Every 1049 enable clears, including when already on
        // the alternate screen. It also saves that screen's cursor.
        addressingGeneration &+= 1
        invalidateSelection()
        grid.clear(rows: 0 ..< rows, with: eraseCell)
        cursor.pendingWrap = false
        damage.setFull()
      } else {
        leaveAlternateScreen()
        restoreCursor()
      }
      return
    case 1047:
      if on {
        enterAlternateScreen()
      } else {
        if isAlternateScreen {
          grid.clear(rows: 0 ..< rows, with: eraseCell)
          cursor.pendingWrap = false
        }
        leaveAlternateScreen()
      }
      return
    case 47:
      if on { enterAlternateScreen() } else { leaveAlternateScreen() }
      return
    case 1048:
      if on { saveCursor() } else { restoreCursor() }
      return
    default: break
    }
    guard let mode = Modes.dec(n) else { return }
    if on {
      if mode == .synchronizedOutput, !modes.contains(mode) {
        synchronizedOutputGeneration &+= 1
      }
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

  private mutating func enterAlternateScreen() {
    guard !isAlternateScreen else { return }
    inactivePrimaryCursor.x = cursor.x
    inactivePrimaryCursor.y = cursor.y
    inactivePrimaryCursor.pendingWrap = cursor.pendingWrap
    addressingGeneration &+= 1
    invalidateSelection()
    swap(&grid, &inactiveGrid)
    swap(&keyboardFlagStack, &inactiveKeyboardFlagStack)
    modes.insert(.alternateScreen)
    viewportOffset = 0
    damage.setFull()
  }

  private mutating func leaveAlternateScreen() {
    guard isAlternateScreen else { return }
    addressingGeneration &+= 1
    invalidateSelection()
    swap(&grid, &inactiveGrid)
    swap(&keyboardFlagStack, &inactiveKeyboardFlagStack)
    modes.remove(.alternateScreen)
    damage.setFull()
  }

  private mutating func saveCursor() {
    holdHyperlink(cursor.pen.link)  // a restore may write with it later
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
    modes.subtract([
      .insert, .origin, .cursorKeys, .keypadApplication, .cursorBlink,
      .reverseWrap, .reverseWrapExtended, .leftRightMargin,
    ])
    modes.insert([.autowrap, .cursorVisible])
    cursorStyle = .block
    for index in 0 ..< 256
    where palette.colors[index] != defaultPalette.colors[index] {
      palette.colors = defaultPalette.colors
      damage.setFull()
      break
    }
    cursor.pen = .default
    (cursor.g0, cursor.g1, cursor.g2, cursor.g3) = (
      .ascii, .ascii, .ascii, .ascii
    )
    cursor.gl = 0
    cursor.singleShift = nil
    cursor.pendingWrap = false
    protectedMode = .off
    scrollTop = 0
    scrollBottom = rows - 1
    scrollLeft = 0
    scrollRight = columns - 1
    // DECSTR resets only the active screen's saved cursor. The
    // inactive screen may still need it when the application returns.
    if isAlternateScreen {
      savedAlternate = Cursor()
      savedAlternateModes = .initial
    } else {
      savedPrimary = Cursor()
      savedPrimaryModes = .initial
    }
  }

  mutating func fullReset() {
    addressingGeneration &+= 1
    discardControlString()
    invalidateSelection()
    resetShellState()
    if programStatus.removeAll() { programStatusChanged = true }
    hyperlinks = []
    hyperlinkHashes = []
    hyperlinkIndex.removeAll(keepingCapacity: true)
    freeHyperlinkSlots = []
    hyperlinkLastRow = []
    hyperlinkScanCooldown = 0
    hyperlinkReclaimAfter = nil
    keyboardFlagStack = []
    inactiveKeyboardFlagStack = []
    if isAlternateScreen { leaveAlternateScreen() }
    grid.clear(rows: 0 ..< rows, with: .blank)
    inactiveGrid.clear(rows: 0 ..< rows, with: .blank)
    grid.clearHistory()
    graphemes.removeAll()
    cursor = Cursor()
    savedPrimary = Cursor()
    savedAlternate = Cursor()
    inactivePrimaryCursor = Cursor()
    savedPrimaryModes = .initial
    savedAlternateModes = .initial
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
    case (0, 0x37): saveCursor()  // DECSC 7
    case (0, 0x38): restoreCursor()  // DECRC 8
    case (0, 0x44): index()  // IND D
    case (0, 0x45):
      index();
      carriageReturn()  // NEL E
    case (0, 0x48): tabStops[cursor.x] = true  // HTS H
    case (0, 0x4D): reverseIndex()  // RI M
    case (0, 0x63): fullReset()  // RIS c
    case (0, 0x3D): modes.insert(.keypadApplication)  // DECKPAM =
    case (0, 0x3E): modes.remove(.keypadApplication)  // DECKPNM >
    case (0x28 ... 0x2B, _):  // SCS: designate G0...G3
      let set: Cursor.Charset? =
        switch final {
        case 0x42: .ascii  // B
        case 0x30: .decSpecialGraphics  // 0
        case 0x41: .british  // A
        default: nil
        }
      if let set { cursor.setCharset(intermediate - 0x28, set) }
    case (0, 0x4E): cursor.singleShift = 2  // SS2 N
    case (0, 0x4F): cursor.singleShift = 3  // SS3 O
    case (0, 0x6E): cursor.gl = 2  // LS2 n
    case (0, 0x6F): cursor.gl = 3  // LS3 o
    case (0, 0x56):  // SPA V
      cursor.isProtected = true
      protectedMode = .iso
    case (0, 0x57): cursor.isProtected = false  // EPA W
    case (0x23, 0x38):  // DECALN #8
      invalidateSelection()
      cursor.pen = CellAttributes(
        foreground: cursor.pen.foreground,
        background: cursor.pen.background,
        flags: cursor.pen.flags.intersection(.protected),
        link: cursor.pen.link,
      )
      (scrollTop, scrollBottom, scrollLeft, scrollRight) = (
        0, rows - 1, 0, columns - 1
      )
      modes.remove(.origin)
      let e = Cell(
        glyph: 0x45,
        attributes: CellAttributes(
          foreground: cursor.pen.foreground,
          background: cursor.pen.background,
        ),
        width: 1
      )
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

  // MARK: Resize

  public mutating func resize(columns newColumns: Int, rows newRows: Int) {
    let newColumns = max(1, newColumns)
    let newRows = max(1, newRows)
    if modes.contains(.synchronizedOutput) {
      modes.remove(.synchronizedOutput)  // a resize ends a synchronized update
      damage.setFull()
    }
    guard newColumns != columns || newRows != rows else { return }
    addressingGeneration &+= 1
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
      swap(&keyboardFlagStack, &inactiveKeyboardFlagStack)
    }  // `grid` is primary now
    // The live cursor first: it must stay on screen.
    var cursors =
      alternate
      ? [inactivePrimaryCursor, savedPrimary] : [cursor, savedPrimary]
    reflowPrimary(
      columns: newColumns,
      rows: newRows,
      cursors: &cursors,
      rewrap: modes.contains(.autowrap)
    )
    if alternate {
      inactivePrimaryCursor = cursors[0]
      savedPrimary = cursors[1]
      swap(&grid, &inactiveGrid)
      swap(&keyboardFlagStack, &inactiveKeyboardFlagStack)
      grid.resize(columns: newColumns, rows: newRows)
      cursor.x = min(cursor.x, newColumns - 1)
      cursor.y = min(cursor.y, newRows - 1)
      if cursor.pendingWrap, cursor.x < newColumns - 1 {
        cursor.x += 1
        cursor.pendingWrap = false
      }
    } else {
      cursor = cursors[0]
      savedPrimary = cursors[1]
      inactiveGrid.resize(columns: newColumns, rows: newRows)
    }
    savedAlternate.x = min(savedAlternate.x, newColumns - 1)
    savedAlternate.y = min(savedAlternate.y, newRows - 1)
    if savedAlternate.pendingWrap, savedAlternate.x < newColumns - 1 {
      savedAlternate.x += 1
      savedAlternate.pendingWrap = false
    }
    // Height-only reflow renumbers retained primary rows from zero.
    // Move old search ranges with them before refreshing, so matching
    // the selected range still identifies the same occurrence.
    if !alternate, newColumns == columns, firstBefore != 0 {
      shiftSearchRows(by: -firstBefore)
    }
    columns = newColumns
    rows = newRows
    scrollTop = 0
    scrollBottom = newRows - 1
    scrollLeft = 0
    scrollRight = newColumns - 1
    if tabStops.count != newColumns { tabStops = Self.defaultTabs(newColumns) }
    viewportOffset = min(viewportOffset, grid.historyCount)
    if var carried = carriedSelection {
      let shift = isAlternateScreen ? 0 : -firstBefore
      carried.anchor.row += shift
      carried.head.row += shift
      clipSelectionToAvailableRows(carried)
    }
    clearLastPromptRowAfterResize()
    if modes.contains(.inBandResize) { reportSize() }
    damage.setFull()
    refreshSearchIfNeeded()
    _checkInvariants()
  }

  /// Debug check: cells past each row's extent are blank (both screens).
  func checkExtentInvariant() -> Bool {
    for y in 0 ..< rows {
      let row = grid._unsafeCells(row: y)
      for x in grid.extent(y) ..< columns where !row[x].isBlank { return false }
      let other = inactiveGrid._unsafeCells(row: y)
      for x in inactiveGrid.extent(y) ..< columns where !other[x].isBlank {
        return false
      }
    }
    return true
  }

  @inline(__always)
  func _checkInvariants() {
    #if SWIFTTY_INTERNAL_CHECKS
    precondition(
      grid.checkInvariants() && inactiveGrid.checkInvariants(),
      "invalid row ownership or extent"
    )
    func checkCells(_ cells: UnsafeBufferPointer<Cell>) -> String? {
      for x in cells.indices {
        let cell = cells[x]
        let flags = cell.attributes.flags.rawValue
        if cell.width == 1 && flags & CellFlags.structural.rawValue == 0 {
          continue
        }
        if cell.width == 2 {
          guard
            x + 1 < cells.count
              && cells[x + 1].attributes.flags.rawValue
                & CellFlags.spacerTail.rawValue != 0
          else {
            return
              "invalid cell at column \(x): width=\(cell.width), flags=\(cell.flags.rawValue)"
          }
        }
        if flags & CellFlags.spacerTail.rawValue != 0 {
          guard x > 0 && cells[x - 1].width == 2 && cell.width == 0 else {
            return
              "invalid cell at column \(x): width=\(cell.width), flags=\(cell.flags.rawValue)"
          }
        }
        if flags & CellFlags.spacerHead.rawValue != 0
          && (x != cells.count - 1 || cell.width != 1)
        {
          return
            "invalid cell at column \(x): width=\(cell.width), flags=\(cell.flags.rawValue)"
        }
        if flags & CellFlags.grapheme.rawValue != 0 {
          guard Int(cell.glyph) < graphemes.entries.count else {
            return
              "invalid cell at column \(x): width=\(cell.width), flags=\(cell.flags.rawValue)"
          }
          let entry = graphemes.entries[Int(cell.glyph)]
          let start = Int(entry >> 32)
          let count = Int(entry & 0xFFFF_FFFF)
          guard
            count >= 2 && start <= graphemes.scalars.count
              && count <= graphemes.scalars.count - start
          else {
            return
              "invalid cell at column \(x): width=\(cell.width), flags=\(cell.flags.rawValue)"
          }
        }
      }
      return nil
    }
    for y in 0 ..< rows {
      let active = checkCells(grid._unsafeCells(row: y))
      let inactive = checkCells(inactiveGrid._unsafeCells(row: y))
      precondition(
        active == nil && inactive == nil,
        "screen row \(y): \(active ?? inactive ?? "")"
      )
    }
    for i in 0 ..< grid.historyCount {
      let error = checkCells(grid.historyLine(i).cells)
      precondition(error == nil, "history row \(i): \(error ?? "")")
    }
    for i in 0 ..< inactiveGrid.historyCount {
      let error = checkCells(inactiveGrid.historyLine(i).cells)
      precondition(error == nil, "inactive history row \(i): \(error ?? "")")
    }
    #endif
  }

  // MARK: Graphemes

  package mutating func compactGraphemes() {
    var fresh = GraphemeTable()
    swap(&fresh, &spareGraphemes)  // reuse the previous table's capacity
    fresh.removeAll()
    for y in 0 ..< grid.rows {
      let row = grid._unsafeRow(y)
      for x in 0 ..< grid.columns where row[x].isGrapheme {
        fresh.adopt(&row[x], from: graphemes)
      }
    }
    for y in 0 ..< inactiveGrid.rows {
      let row = inactiveGrid._unsafeRow(y)
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
    fresh.compactionLimit = max(
      GraphemeTable.compactionThreshold,
      fresh.scalars.count * 2
    )
    swap(&graphemes, &fresh)
    swap(&fresh, &spareGraphemes)
  }

  // MARK: Tables

  private static func defaultTabs(_ columns: Int) -> [Bool] {
    (0 ..< columns).map { $0 % 8 == 0 && $0 != 0 }
  }

  /// DEC Special Graphics for 0x5F...0x7E.
  static let decSpecial: [UInt32] = [
    0x00A0, 0x25C6, 0x2592, 0x2409, 0x240C, 0x240D, 0x240A, 0x00B0, 0x00B1,
    0x2424, 0x240B, 0x2518, 0x2510, 0x250C, 0x2514, 0x253C, 0x23BA, 0x23BB,
    0x2500, 0x23BC, 0x23BD, 0x251C, 0x2524, 0x2534, 0x252C, 0x2502, 0x2264,
    0x2265, 0x03C0, 0x2260, 0x00A3, 0x00B7,
  ]
}
