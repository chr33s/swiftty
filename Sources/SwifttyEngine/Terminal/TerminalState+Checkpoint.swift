import Foundation

// Planned-replacement checkpoints (spec.durability.md §6). Every field is
// encoded explicitly; the inventory below lists what is deliberately left out.
//
// Omitted, with reason:
// - `damage`: derived; import marks the screen fully damaged.
// - `spareGraphemes`, grid storage pools, row maps, chunk residency,
//   scrollback compression units and stale-cell lists: physical layout. The
//   logical rows they hold are encoded.
// - `widths`: a static table.
// - A kitty graphics chunked load in progress (abandoned at the cut) and the
//   graphics settings (`kittyGraphicsEnabled`, media, limit), which the
//   importing host reinstalls; images and placements are section 15.
// - `onShellCommandFinished`, `onShellCommandStarted`, `kittyClipboardReader`,
//   `kittyClipboardWriter`:
//   host callbacks; the importing host installs its own.
// - `searchNeedsRefresh` is encoded; derived matches are encoded too so the
//   selected index keeps its meaning.
//
// Refused rather than encoded, because they are unsettled external effects
// that the frozen cut must settle first (§6): pending replies (`output`),
// undelivered `events`, tmux control-mode data, kitty clipboard reads and
// writes in flight, an open kitty clipboard write transaction, an untaken
// program-status journal, and a drag-and-drop operation in progress.

package enum TerminalCheckpoint {
  package static let formatVersion: UInt16 = 1
  static let magic: [UInt8] = Array("SWTC".utf8)

  enum Section: UInt8 {
    case header = 1
    case activeGrid = 2
    case inactiveGrid = 3
    case graphemes = 4
    case cursors = 5
    case screen = 6
    case colors = 7
    case text = 8
    case input = 9
    case hyperlinks = 10
    case selection = 11
    case shell = 12
    case clipboard = 13
    case programStatus = 14
  }
}

extension TerminalState {
  /// Encodes the complete logical state. Mutating only to resolve stale
  /// cells and borrow cold history; terminal behaviour does not change.
  package mutating func checkpoint() throws(CheckpointError) -> [UInt8] {
    guard output.isEmpty else { throw CheckpointError("unsettled replies") }
    guard events.isEmpty, !titleChanged, !directoryChanged, !commandFinished
    else { throw CheckpointError("undelivered terminal events") }
    guard controlModeData.isEmpty, controlModeEndOffsets.isEmpty else {
      throw CheckpointError("undelivered control-mode data")
    }
    guard pendingKittyClipboardReads.isEmpty,
      pendingKittyClipboardWrites.isEmpty, kittyClipboardWrite == nil
    else { throw CheckpointError("clipboard operation in flight") }
    if let drag = dragAndDrop {
      guard !drag.chunking, !drag.hovered, !drag.dropped, drag.accepted == nil,
        !drag.acceptInProgress, drag.offered == nil, drag.items == nil
      else { throw CheckpointError("drag-and-drop operation in progress") }
    }
    grid.resolveStaleRows()
    inactiveGrid.resolveStaleRows()
    var w = CheckpointWriter()
    for byte in TerminalCheckpoint.magic { w.u8(byte) }
    w.u16(TerminalCheckpoint.formatVersion)
    w.section(TerminalCheckpoint.Section.header.rawValue) { h in
      h.int(columns)
      h.int(rows)
      h.bool(isAlternateScreen)
      h.u64(addressingGeneration)
      h.bool(scrollbackCompressionRequested)
    }
    var active = CheckpointWriter()
    grid.checkpoint(into: &active)
    w.u8(TerminalCheckpoint.Section.activeGrid.rawValue)
    w.data(active.bytes)
    var inactive = CheckpointWriter()
    inactiveGrid.checkpoint(into: &inactive)
    w.u8(TerminalCheckpoint.Section.inactiveGrid.rawValue)
    w.data(inactive.bytes)
    w.section(TerminalCheckpoint.Section.graphemes.rawValue) {
      graphemes.checkpoint(into: &$0)
      $0.u32(lastPrinted)
    }
    w.section(TerminalCheckpoint.Section.cursors.rawValue) { c in
      for cursor in [
        cursor, savedPrimary, savedAlternate, inactivePrimaryCursor,
      ] { c.cursor(cursor) }
      c.u64(savedPrimaryModes.rawValue)
      c.u64(savedAlternateModes.rawValue)
      c.u8(cursorStyle.rawValue)
    }
    w.section(TerminalCheckpoint.Section.screen.rawValue) { s in
      s.int(scrollTop)
      s.int(scrollBottom)
      s.int(scrollLeft)
      s.int(scrollRight)
      s.int(tabStops.count)
      for stop in tabStops { s.bool(stop) }
      s.u8(protectedMode.checkpointTag)
      s.u64(modes.rawValue)
      s.u64(synchronizedOutputGeneration)
      s.int(viewportOffset)
      s.int(cellPixelSize.width)
      s.int(cellPixelSize.height)
      s.int(keyboardFlagStack.count)
      for flags in keyboardFlagStack { s.u8(flags) }
      s.int(inactiveKeyboardFlagStack.count)
      for flags in inactiveKeyboardFlagStack { s.u8(flags) }
      s.bool(isControlMode)
      s.u8(dcsKind.checkpointTag)
      s.data(dcsBuffer)
    }
    w.section(TerminalCheckpoint.Section.colors.rawValue) { c in
      c.palette(palette)
      c.palette(defaultPalette)
      c.u8(colorScheme == .dark ? 0 : 1)
      c.int(underlineColors.count)
      for color in underlineColors { c.u32(color.rawValue) }
      c.int(penStack.count)
      for pen in penStack { c.attributes(pen) }
    }
    w.section(TerminalCheckpoint.Section.text.rawValue) { t in
      t.data(titleBytes)
      t.data(directoryBytes)
      t.int(titleStack.count)
      for title in titleStack { t.data(title) }
      t.string(pointerShape)
    }
    w.section(TerminalCheckpoint.Section.input.rawValue) { i in
      i.bool(discardsReplies)
      i.string(terminalVersion)
      i.string(terminfoName)
      i.bool(keyboardProtocolEnabled)
      i.bool(rectangleChecksumsEnabled)
      i.u8(defaultChecksumFlags.rawValue)
      i.u8(checksumFlags.rawValue)
      i.bool(clipboardWritesAdvertised)
      i.bool(answersProgramStatusWhileDiscarding)
    }
    w.section(TerminalCheckpoint.Section.hyperlinks.rawValue) {
      hyperlinks.checkpoint(into: &$0)
    }
    w.section(TerminalCheckpoint.Section.selection.rawValue) { s in
      s.selection(selection)
      s.selection(presentedSelection)
      s.bool(presentationKeys != nil)
      if let keys = presentationKeys {
        s.int(keys.count)
        for row in keys {
          s.int(row.count)
          for key in row { s.u64(key) }
        }
      }
      s.presentationSelection(presentationSelection)
      s.optionalString(searchQuery)
      s.optionalInt(searchSelected)
      s.bool(searchNeedsRefresh)
      s.int(searchMatches.count)
      for match in searchMatches {
        s.int(match.start.row)
        s.int(match.start.column)
        s.int(match.end.row)
        s.int(match.end.column)
      }
    }
    w.section(TerminalCheckpoint.Section.shell.rawValue) { s in
      s.u8(semanticState.checkpointTag)
      s.u8(promptRedraw.checkpointTag)
      s.promptClick(promptClick)
      s.optionalInt(inputOffset)
      s.bool(hasSemanticPrompts)
      s.optionalInt(lastExitCode)
      s.string(shellCommand)
    }
    w.section(TerminalCheckpoint.Section.clipboard.rawValue) { c in
      c.int(kittyClipboardWriteLimit)
      kittyClipboardGrants.checkpoint(into: &c)
      c.u64(kittyClipboardReadToken)
      c.u64(kittyClipboardWriteToken)
      c.bool(dragAndDrop != nil)
      if let drag = dragAndDrop {
        c.u32(drag.clientID)
        c.data(drag.registered)
      }
    }
    var status = CheckpointWriter()
    status.bool(programStatusEnabled)
    status.bool(programStatusChanged)
    try programStatus.checkpoint(into: &status)
    w.u8(TerminalCheckpoint.Section.programStatus.rawValue)
    w.data(status.bytes)
    checkpointKittyGraphics(into: &w)
    return w.bytes
  }

  /// A terminal with exactly the checkpointed state. Validates every count
  /// and reference before use; produces no replies, events or effects.
  package static func restored(
    checkpoint bytes: [UInt8]
  ) throws(CheckpointError) -> TerminalState {
    var r = CheckpointReader(bytes)
    for byte in TerminalCheckpoint.magic {
      guard try r.u8() == byte else {
        throw CheckpointError("not a terminal checkpoint")
      }
    }
    guard try r.u16() == TerminalCheckpoint.formatVersion else {
      throw CheckpointError("unsupported checkpoint version")
    }
    var header = try r.section(TerminalCheckpoint.Section.header.rawValue)
    let columns = try header.bounded(1 ... 4096)
    let rows = try header.bounded(1 ... 4096)
    let alternate = try header.bool()
    let addressing = try header.u64()
    let compression = try header.bool()
    try header.finish()
    var activeSection = try r.section(
      TerminalCheckpoint.Section.activeGrid.rawValue
    )
    let active = try Grid.restored(from: &activeSection)
    try activeSection.finish()
    var inactiveSection = try r.section(
      TerminalCheckpoint.Section.inactiveGrid.rawValue
    )
    let inactive = try Grid.restored(from: &inactiveSection)
    try inactiveSection.finish()
    guard active.columns == columns, active.rows == rows,
      inactive.columns == columns, inactive.rows == rows
    else { throw CheckpointError("grid geometry mismatch") }
    var state = TerminalState(columns: columns, rows: rows)
    try state.restore(
      from: &r,
      active: active,
      inactive: inactive,
      alternate: alternate,
      addressing: addressing,
      compression: compression
    )
    return state
  }

  private mutating func restore(
    from r: inout CheckpointReader,
    active: consuming Grid,
    inactive: consuming Grid,
    alternate: Bool,
    addressing: UInt64,
    compression: Bool
  ) throws(CheckpointError) {
    grid = active
    inactiveGrid = inactive
    addressingGeneration = addressing
    scrollbackCompressionRequested = compression

    var g = try r.section(TerminalCheckpoint.Section.graphemes.rawValue)
    try graphemes.restore(from: &g)
    lastPrinted = try g.u32()
    try g.finish()

    var c = try r.section(TerminalCheckpoint.Section.cursors.rawValue)
    cursor = try c.cursor(columns: columns, rows: rows)
    savedPrimary = try c.cursor(columns: columns, rows: rows)
    savedAlternate = try c.cursor(columns: columns, rows: rows)
    inactivePrimaryCursor = try c.cursor(columns: columns, rows: rows)
    savedPrimaryModes = Modes(rawValue: try c.u64())
    savedAlternateModes = Modes(rawValue: try c.u64())
    guard let style = CursorStyle(rawValue: try c.u8()) else {
      throw CheckpointError("invalid cursor style")
    }
    cursorStyle = style
    try c.finish()

    var s = try r.section(TerminalCheckpoint.Section.screen.rawValue)
    scrollTop = try s.bounded(0 ... rows - 1)
    scrollBottom = try s.bounded(scrollTop ... rows - 1)
    scrollLeft = try s.bounded(0 ... columns - 1)
    scrollRight = try s.bounded(scrollLeft ... columns - 1)
    let stops = try s.count(max: columns, minimumSize: 1)
    guard stops == columns else { throw CheckpointError("tab stop count") }
    tabStops = []
    for _ in 0 ..< stops { tabStops.append(try s.bool()) }
    protectedMode = try ProtectedMode(checkpointTag: try s.u8())
    let restoredModes = Modes(rawValue: try s.u64())
    synchronizedOutputGeneration = try s.u64()
    let offset = try s.bounded(0 ... Int(Int32.max))
    // Pixel size first: with in-band resize already on, setting it would
    // report a resize.
    let pixelWidth = try s.bounded(0 ... Int(Int32.max))
    let pixelHeight = try s.bounded(0 ... Int(Int32.max))
    cellPixelSize = (pixelWidth, pixelHeight)
    modes = restoredModes
    guard restoredModes.contains(.alternateScreen) == alternate else {
      throw CheckpointError("screen mode mismatch")
    }
    let primaryHistory =
      alternate ? inactiveGrid.historyCount : grid.historyCount
    guard offset <= primaryHistory, offset == 0 || !alternate else {
      throw CheckpointError("invalid viewport offset")
    }
    viewportOffset = offset
    keyboardFlagStack = []
    for _ in 0 ..< (try s.count(max: 64)) {
      keyboardFlagStack.append(try s.u8())
    }
    inactiveKeyboardFlagStack = []
    for _ in 0 ..< (try s.count(max: 64)) {
      inactiveKeyboardFlagStack.append(try s.u8())
    }
    isControlMode = try s.bool()
    dcsKind = try DCSKind(checkpointTag: try s.u8())
    dcsBuffer = try s.data(max: 1 << 20)
    try s.finish()

    var colors = try r.section(TerminalCheckpoint.Section.colors.rawValue)
    palette = try colors.palette()
    defaultPalette = try colors.palette()
    switch try colors.u8() {
    case 0: colorScheme = .dark
    case 1: colorScheme = .light
    default: throw CheckpointError("invalid colour scheme")
    }
    underlineColors = []
    for _ in 0 ..< (try colors.count(max: 1 << 16, minimumSize: 4)) {
      underlineColors.append(TerminalColor(rawValue: try colors.u32()))
    }
    penStack = []
    for _ in 0 ..< (try colors.count(max: 1024, minimumSize: 12)) {
      penStack.append(try colors.attributes())
    }
    try colors.finish()

    var t = try r.section(TerminalCheckpoint.Section.text.rawValue)
    titleBytes = try t.data(max: 1 << 16)
    directoryBytes = try t.data(max: 1 << 16)
    titleStack = []
    for _ in 0 ..< (try t.count(max: 1024)) {
      titleStack.append(try t.data(max: 1 << 16))
    }
    pointerShape = try t.string(max: 1 << 10)
    try t.finish()

    var i = try r.section(TerminalCheckpoint.Section.input.rawValue)
    discardsReplies = try i.bool()
    terminalVersion = try i.string(max: 1 << 10)
    terminfoName = try i.string(max: 1 << 10)
    keyboardProtocolEnabled = try i.bool()
    rectangleChecksumsEnabled = try i.bool()
    defaultChecksumFlags = ChecksumFlags(rawValue: try i.u8())
    checksumFlags = ChecksumFlags(rawValue: try i.u8())
    clipboardWritesAdvertised = try i.bool()
    answersProgramStatusWhileDiscarding = try i.bool()
    try i.finish()

    var h = try r.section(TerminalCheckpoint.Section.hyperlinks.rawValue)
    try hyperlinks.restore(from: &h)
    try h.finish()

    var sel = try r.section(TerminalCheckpoint.Section.selection.rawValue)
    selection = try sel.selection()
    presentedSelection = try sel.selection()
    if try sel.bool() {
      var keys: [[UInt64]] = []
      for _ in 0 ..< (try sel.count(max: 4096)) {
        var row: [UInt64] = []
        for _ in 0 ..< (try sel.count(max: 64, minimumSize: 8)) {
          row.append(try sel.u64())
        }
        keys.append(row)
      }
      presentationKeys = keys
    } else {
      presentationKeys = nil
    }
    presentationSelection = try sel.presentationSelection()
    searchQuery = try sel.optionalString(max: 1 << 16)
    searchSelected = try sel.optionalInt()
    searchNeedsRefresh = try sel.bool()
    searchMatches = []
    for _ in 0 ..< (try sel.count(max: 1 << 20, minimumSize: 32)) {
      searchMatches.append(
        TerminalRange(
          start: TerminalPoint(row: try sel.int(), column: try sel.int()),
          end: TerminalPoint(row: try sel.int(), column: try sel.int())
        )
      )
    }
    guard searchSelected.map({ $0 >= 0 && $0 < searchMatches.count }) ?? true
    else { throw CheckpointError("invalid search selection") }
    try sel.finish()

    var sh = try r.section(TerminalCheckpoint.Section.shell.rawValue)
    semanticState = try SemanticState(checkpointTag: try sh.u8())
    promptRedraw = try PromptRedraw(checkpointTag: try sh.u8())
    promptClick = try sh.promptClick()
    inputOffset = try sh.optionalInt()
    hasSemanticPrompts = try sh.bool()
    lastExitCode = try sh.optionalInt()
    shellCommand = try sh.string(max: 1 << 20)
    try sh.finish()

    var clip = try r.section(TerminalCheckpoint.Section.clipboard.rawValue)
    kittyClipboardWriteLimit = try clip.bounded(0 ... Int(Int32.max))
    try kittyClipboardGrants.restore(from: &clip)
    kittyClipboardReadToken = try clip.u64()
    kittyClipboardWriteToken = try clip.u64()
    if try clip.bool() {
      var drag = KittyDragAndDrop.State()
      drag.clientID = try clip.u32()
      drag.registered = try clip.data(max: 1 << 16)
      dragAndDrop = drag
    } else {
      dragAndDrop = nil
    }
    try clip.finish()

    var status = try r.section(
      TerminalCheckpoint.Section.programStatus.rawValue
    )
    programStatusEnabled = try status.bool()
    programStatusChanged = try status.bool()
    try programStatus.restore(from: &status)
    try status.finish()
    try restoreKittyGraphics(from: &r)
    try r.finish()

    try validateCheckpointReferences()
    output.removeAll(keepingCapacity: true)
    events.removeAll(keepingCapacity: true)
    damage.setFull()
  }

  /// Every grapheme cell names an entry and every link a live hyperlink.
  private func validateCheckpointReferences() throws(CheckpointError) {
    let entryCount = graphemes.entryCount
    let links = hyperlinks
    func check(_ cells: UnsafeBufferPointer<Cell>) -> Bool {
      for cell in cells {
        if cell.isGrapheme, Int(cell.glyph) >= entryCount { return false }
        let link = cell.attributes.link
        if link != 0, !links.isLive(link) { return false }
      }
      return true
    }
    var valid = true
    for index in 0 ..< grid.historyCount where valid {
      valid = grid.withHistoryLine(index) { cells, _ in check(cells) }
    }
    for index in 0 ..< inactiveGrid.historyCount where valid {
      valid = inactiveGrid.withHistoryLine(index) { cells, _ in check(cells) }
    }
    for y in 0 ..< grid.rows where valid {
      valid = check(grid._unsafeCells(row: y))
    }
    for y in 0 ..< inactiveGrid.rows where valid {
      valid = check(inactiveGrid._unsafeCells(row: y))
    }
    guard valid else { throw CheckpointError("dangling cell reference") }
  }
}

// MARK: Small encodings

extension CheckpointWriter {
  mutating func cursor(_ c: Cursor) {
    int(c.x)
    int(c.y)
    bool(c.pendingWrap)
    attributes(c.pen)
    for set in [c.g0, c.g1, c.g2, c.g3] { u8(set.rawValue) }
    u8(c.gl)
    bool(c.singleShift != nil)
    if let shift = c.singleShift { u8(shift) }
  }

  mutating func palette(_ p: Palette) {
    for i in 0 ..< 256 { u32(p.colors[i]) }
    u32(p.foreground)
    u32(p.background)
    u32(p.cursor)
    optionalU32(p.cursorText)
    optionalU32(p.selectionForeground)
    optionalU32(p.selectionBackground)
  }

  mutating func selection(_ s: Selection?) {
    bool(s != nil)
    guard let s else { return }
    int(s.anchor.row)
    int(s.anchor.column)
    int(s.head.row)
    int(s.head.column)
    bool(s.rectangle)
  }

  mutating func presentationSelection(_ s: PresentationSelection?) {
    bool(s != nil)
    guard let s else { return }
    u64(s.generation)
    bool(s.alternateScreen)
    int(s.anchor.row)
    int(s.anchor.column)
    int(s.head.row)
    int(s.head.column)
    bool(s.rectangle)
    let unit: UInt8 =
      switch s.unit {
      case .character: 0
      case .word: 1
      case .line: 2
      }
    u8(unit)
    int(s.seen.count)
    for (row, value) in s.seen.sorted(by: { $0.key < $1.key }) {
      int(row)
      u64(value.version)
      bool(value.screen)
    }
  }

  mutating func promptClick(_ p: PromptClick) {
    switch p {
    case .none: u8(0)
    case let .cursorKeys(keys):
      u8(1)
      let tag: UInt8 =
        switch keys {
        case .line: 0
        case .multiple: 1
        case .conservativeVertical: 2
        case .smartVertical: 3
        }
      u8(tag)
    case let .events(relative):
      u8(2)
      bool(relative)
    }
  }
}

extension CheckpointReader {
  mutating func cursor(
    columns: Int,
    rows: Int
  ) throws(CheckpointError) -> Cursor {
    var c = Cursor()
    c.x = try bounded(0 ... columns - 1)
    c.y = try bounded(0 ... rows - 1)
    c.pendingWrap = try bool()
    c.pen = try attributes()
    var sets: [Cursor.Charset] = []
    for _ in 0 ..< 4 {
      guard let set = Cursor.Charset(rawValue: try u8()) else {
        throw CheckpointError("invalid charset")
      }
      sets.append(set)
    }
    (c.g0, c.g1, c.g2, c.g3) = (sets[0], sets[1], sets[2], sets[3])
    c.gl = try u8()
    c.singleShift = try bool() ? try u8() : nil
    guard c.gl < 4, c.singleShift.map({ $0 < 4 }) ?? true else {
      throw CheckpointError("invalid shift state")
    }
    return c
  }

  mutating func palette() throws(CheckpointError) -> Palette {
    var p = Palette.standard
    for i in 0 ..< 256 { p.colors[i] = try u32() }
    p.foreground = try u32()
    p.background = try u32()
    p.cursor = try u32()
    p.cursorText = try optionalU32()
    p.selectionForeground = try optionalU32()
    p.selectionBackground = try optionalU32()
    return p
  }

  mutating func selection() throws(CheckpointError) -> Selection? {
    guard try bool() else { return nil }
    return Selection(
      anchor: TerminalPoint(row: try int(), column: try int()),
      head: TerminalPoint(row: try int(), column: try int()),
      rectangle: try bool()
    )
  }

  mutating func presentationSelection() throws(CheckpointError)
    -> PresentationSelection?
  {
    guard try bool() else { return nil }
    let generation = try u64()
    let alternate = try bool()
    let anchor = (row: try int(), column: try int())
    let head = (row: try int(), column: try int())
    let rectangle = try bool()
    let unit: PresentationSelection.Unit
    switch try u8() {
    case 0: unit = .character
    case 1: unit = .word
    case 2: unit = .line
    default: throw CheckpointError("invalid selection unit")
    }
    var value = PresentationSelection(
      generation: generation,
      alternateScreen: alternate,
      anchor: anchor,
      head: head,
      rectangle: rectangle,
      unit: unit
    )
    for _ in 0 ..< (try count(max: 1 << 16, minimumSize: 17)) {
      let row = try int()
      value.seen[row] = (version: try u64(), screen: try bool())
    }
    return value
  }

  mutating func promptClick() throws(CheckpointError) -> PromptClick {
    switch try u8() {
    case 0: return .none
    case 1:
      switch try u8() {
      case 0: return .cursorKeys(.line)
      case 1: return .cursorKeys(.multiple)
      case 2: return .cursorKeys(.conservativeVertical)
      case 3: return .cursorKeys(.smartVertical)
      default: throw CheckpointError("invalid prompt click keys")
      }
    case 2: return .events(relative: try bool())
    default: throw CheckpointError("invalid prompt click")
    }
  }
}

extension TerminalState.ProtectedMode {
  var checkpointTag: UInt8 {
    switch self {
    case .off: 0
    case .iso: 1
    case .dec: 2
    }
  }
  init(checkpointTag: UInt8) throws(CheckpointError) {
    switch checkpointTag {
    case 0: self = .off
    case 1: self = .iso
    case 2: self = .dec
    default: throw CheckpointError("invalid protected mode")
    }
  }
}

extension TerminalState.DCSKind {
  var checkpointTag: UInt8 {
    switch self {
    case .ignored: 0
    case .tmux: 1
    case .termcap: 2
    case .statusString: 3
    }
  }
  init(checkpointTag: UInt8) throws(CheckpointError) {
    switch checkpointTag {
    case 0: self = .ignored
    case 1: self = .tmux
    case 2: self = .termcap
    case 3: self = .statusString
    default: throw CheckpointError("invalid DCS kind")
    }
  }
}

extension SemanticState {
  var checkpointTag: UInt8 {
    switch self {
    case .none: 0
    case .prompt: 1
    case .input: 2
    case .output: 3
    }
  }
  init(checkpointTag: UInt8) throws(CheckpointError) {
    switch checkpointTag {
    case 0: self = .none
    case 1: self = .prompt
    case 2: self = .input
    case 3: self = .output
    default: throw CheckpointError("invalid semantic state")
    }
  }
}

extension TerminalState.PromptRedraw {
  var checkpointTag: UInt8 {
    switch self {
    case .none: 0
    case .all: 1
    case .lastRow: 2
    }
  }
  init(checkpointTag: UInt8) throws(CheckpointError) {
    switch checkpointTag {
    case 0: self = .none
    case 1: self = .all
    case 2: self = .lastRow
    default: throw CheckpointError("invalid prompt redraw")
    }
  }
}

// MARK: Hyperlinks

extension HyperlinkTable {
  /// The whole table: link ids stay as the cells carry them, and `id=`
  /// links keep continuing across the cut.
  func checkpoint(into w: inout CheckpointWriter) {
    w.int(target.count)
    for value in target { w.u32(value) }
    for row in lastRow { w.int(row) }
    for pin in pinned { w.bool(pin) }
    w.int(explicitID.count)
    for (id, bytes) in explicitID.sorted(by: { $0.key < $1.key }) {
      w.u32(id)
      w.data(bytes)
    }
    w.int(explicitIndex.count)
    for (key, id) in explicitIndex.entries.sorted(by: { $0.key < $1.key }) {
      w.u64(key)
      w.u32(id)
    }
    w.int(freeIDs.count)
    for id in freeIDs { w.u32(id) }
    w.int(closed.count)
    for entry in closed {
      w.u32(entry.id)
      w.int(entry.row)
    }
    w.int(closedHead)
    w.int(targets.count)
    for (i, bytes) in targets.enumerated() {
      w.data(bytes)
      w.u32(targetUses[i])
      w.u64(targetHash[i])
    }
    w.int(targetIndex.count)
    for (key, index) in targetIndex.entries.sorted(by: { $0.key < $1.key }) {
      w.u64(key)
      w.u32(index)
    }
    w.int(freeTargets.count)
    for index in freeTargets { w.u32(index) }
    w.int(scanThreshold)
    w.int(scanCooldown)
  }

  mutating func restore(from r: inout CheckpointReader) throws(CheckpointError)
  {
    let links = try r.count(max: Int(CellAttributes.maxLink), minimumSize: 13)
    var table = HyperlinkTable()
    for _ in 0 ..< links { table.target.append(try r.u32()) }
    for _ in 0 ..< links { table.lastRow.append(try r.int()) }
    for _ in 0 ..< links { table.pinned.append(try r.bool()) }
    // Bookkeeping can outlive the link it names; bounded by input size.
    for _ in 0 ..< (try r.count(max: 1 << 20, minimumSize: 12)) {
      let id = try r.u32()
      table.explicitID[id] = try r.data(max: 1 << 16)
    }
    for _ in 0 ..< (try r.count(max: 1 << 20, minimumSize: 12)) {
      let key = try r.u64()
      table.explicitIndex[key] = try r.u32()
    }
    for _ in 0 ..< (try r.count(max: links, minimumSize: 4)) {
      table.freeIDs.append(try r.u32())
    }
    for _ in 0 ..< (try r.count(max: 1 << 20, minimumSize: 12)) {
      table.closed.append((id: try r.u32(), row: try r.int()))
    }
    table.closedHead = try r.bounded(0 ... table.closed.count)
    let targetCount = try r.count(max: 1 << 20, minimumSize: 20)
    for _ in 0 ..< targetCount {
      table.targets.append(try r.data(max: 1 << 16))
      table.targetUses.append(try r.u32())
      table.targetHash.append(try r.u64())
    }
    var index = HashIndex(minimumCapacity: 512)
    for _ in 0 ..< (try r.count(max: targetCount, minimumSize: 12)) {
      let key = try r.u64()
      index[key] = try r.u32()
    }
    table.targetIndex = index
    for _ in 0 ..< (try r.count(max: targetCount, minimumSize: 4)) {
      table.freeTargets.append(try r.u32())
    }
    table.scanThreshold = try r.bounded(0 ... Int(Int32.max))
    table.scanCooldown = try r.bounded(0 ... Int(Int32.max))
    // Every live link names a stored target; every free id is in range.
    guard
      table.target.allSatisfy({
        $0 == Self.free || Int($0) < table.targets.count
      }), table.freeIDs.allSatisfy({ $0 >= 1 && Int($0) <= links }),
      table.targetIndex.entries.allSatisfy({ Int($0.value) < targetCount }),
      table.explicitIndex.entries.allSatisfy({ Int($0.value) <= links })
    else { throw CheckpointError("invalid hyperlink table") }
    self = table
  }
}
