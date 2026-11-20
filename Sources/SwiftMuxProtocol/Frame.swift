import Foundation

public struct FrameIdentity: Codable, Sendable, Equatable {
  public var server: ServerInstanceID
  public var attachment: AttachmentID
  public var pane: PaneID
  /// Monotonic per pane within one server instance.
  public var revision: UInt64
  public var layoutRevision: UInt64
  /// Monotonic per pane: advances with every applied resize, whichever
  /// lease sent it (0 = none). Not the client's batch generation.
  public var geometryGeneration: UInt64
  public var viewportRevision: UInt64

  public init(
    server: ServerInstanceID,
    attachment: AttachmentID,
    pane: PaneID,
    revision: UInt64,
    layoutRevision: UInt64,
    geometryGeneration: UInt64,
    viewportRevision: UInt64
  ) {
    self.server = server
    self.attachment = attachment
    self.pane = pane
    self.revision = revision
    self.layoutRevision = layoutRevision
    self.geometryGeneration = geometryGeneration
    self.viewportRevision = viewportRevision
  }
}

/// Frame-local style table entry.
public struct FrameStyle: Codable, Sendable, Hashable {
  /// `TerminalColor` raw values: tag byte (0 default, 1 palette, 2 RGB).
  public var foreground: UInt32
  public var background: UInt32
  /// Cell flags excluding structural bits.
  public var flags: UInt16
  /// Index into `FrameAppearance.underlineColors` plus one, or 0.
  public var underlineColor: UInt8

  public init(
    foreground: UInt32,
    background: UInt32,
    flags: UInt16,
    underlineColor: UInt8
  ) {
    self.foreground = foreground
    self.background = background
    self.flags = flags
    self.underlineColor = underlineColor
  }

  public static let plain = FrameStyle(
    foreground: 0,
    background: 0,
    flags: 0,
    underlineColor: 0
  )
}

/// Explicit cell structure: a wide lead is followed by one continuation.
public enum CellKind: UInt8, Sendable {
  case continuation = 0
  case narrow = 1
  case wideLead = 2
  /// Row-end padding where a wide character did not fit.
  case padding = 3
}

/// Owned grid. Row-major packed little-endian arrays, `columns * rows`
/// entries each: glyph UInt32 (scalar, or `graphemeFlag | index`),
/// style UInt16 (style table index) and kind UInt8 (`CellKind`).
public struct FrameGrid: Codable, Sendable, Equatable {
  public static let graphemeFlag: UInt32 = 0x8000_0000

  public var columns: Int
  public var rows: Int
  public var alternateScreen: Bool
  /// One byte per row: 1 when the row soft-wraps into the next.
  public var wrapped: Data
  public var glyphs: Data
  public var styles: Data
  public var kinds: Data

  public init(
    columns: Int,
    rows: Int,
    alternateScreen: Bool,
    wrapped: Data,
    glyphs: Data,
    styles: Data,
    kinds: Data
  ) {
    self.columns = columns
    self.rows = rows
    self.alternateScreen = alternateScreen
    self.wrapped = wrapped
    self.glyphs = glyphs
    self.styles = styles
    self.kinds = kinds
  }

  @inline(__always)
  public func glyph(at i: Int) -> UInt32 {
    glyphs.withUnsafeBytes {
      $0.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
    }
    .littleEndian
  }

  @inline(__always)
  public func style(at i: Int) -> Int {
    Int(
      styles.withUnsafeBytes {
        $0.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self)
      }
      .littleEndian
    )
  }

  @inline(__always)
  public func kind(at i: Int) -> CellKind {
    CellKind(rawValue: kinds[kinds.startIndex + i]) ?? .narrow
  }

  public func isWrapped(row: Int) -> Bool {
    wrapped[wrapped.startIndex + row] != 0
  }
}

public struct FramePalette: Codable, Sendable, Equatable {
  /// 256 entries, `0xRRGGBB`.
  public var colors: [UInt32]
  public var foreground: UInt32
  public var background: UInt32
  public var cursor: UInt32
  public var cursorText: UInt32?
  public var selectionForeground: UInt32?
  public var selectionBackground: UInt32?

  public init(
    colors: [UInt32],
    foreground: UInt32,
    background: UInt32,
    cursor: UInt32,
    cursorText: UInt32? = nil,
    selectionForeground: UInt32? = nil,
    selectionBackground: UInt32? = nil
  ) {
    self.colors = colors
    self.foreground = foreground
    self.background = background
    self.cursor = cursor
    self.cursorText = cursorText
    self.selectionForeground = selectionForeground
    self.selectionBackground = selectionBackground
  }

  /// Every palette entry is a 24-bit RGB value; optional overrides may
  /// be absent to use the renderer's default.
  public var isValid: Bool {
    colors.count == 256 && colors.allSatisfy { $0 <= 0xFF_FFFF }
      && [foreground, background, cursor].allSatisfy { $0 <= 0xFF_FFFF }
      && [cursorText, selectionForeground, selectionBackground]
        .allSatisfy { $0.map { $0 <= 0xFF_FFFF } ?? true }
  }
}

public struct FrameCursor: Codable, Sendable, Equatable {
  public var x: Int
  public var y: Int
  public var visible: Bool
  /// 0 block, 1 underline, 2 bar.
  public var style: UInt8
  public var blinking: Bool

  public init(x: Int, y: Int, visible: Bool, style: UInt8, blinking: Bool) {
    self.x = x
    self.y = y
    self.visible = visible
    self.style = style
    self.blinking = blinking
  }
}

/// Modes a frontend may consult; enhanced keyboard reporting is absent
/// from this profile. Mouse modes are set only by a service offering
/// `ServiceFeatures.mouseReporting`.
public struct SupportedViewModes: OptionSet, Codable, Sendable, Hashable {
  public var rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }
  public static let cursorKeys = SupportedViewModes(rawValue: 1 << 0)
  public static let bracketedPaste = SupportedViewModes(rawValue: 1 << 1)
  public static let alternateScreen = SupportedViewModes(rawValue: 1 << 2)
  public static let reverseVideo = SupportedViewModes(rawValue: 1 << 3)
  public static let focusEvents = SupportedViewModes(rawValue: 1 << 4)
  public static let keypadApplication = SupportedViewModes(rawValue: 1 << 5)
  /// The program receives clicks (any of modes 9, 1000, 1002, 1003).
  public static let mouseTracking = SupportedViewModes(rawValue: 1 << 6)
  /// …and motion while a button is held (1002).
  public static let mouseButtonMotion = SupportedViewModes(rawValue: 1 << 7)
  /// …and all motion (1003).
  public static let mouseAnyMotion = SupportedViewModes(rawValue: 1 << 8)
  /// The wheel sends arrow keys on the alternate screen (1007).
  public static let alternateScroll = SupportedViewModes(rawValue: 1 << 9)
  /// Pastes are reported as kitty paste events (5522), from a service
  /// offering `ServiceFeatures.kittyClipboard`.
  public static let kittyPasteEvents = SupportedViewModes(rawValue: 1 << 10)
}

public struct HistoryWindow: Codable, Sendable, Equatable {
  /// Addressing generation: absolute rows from another generation are invalid.
  public var generation: UInt64
  public var firstRow: Int
  /// History plus screen rows available for addressing.
  public var availableRows: Int
  /// Absolute row shown at viewport row 0.
  public var viewportTop: Int
  /// Rows scrolled back from the live screen (0 = following output).
  public var viewportOffset: Int
  public var scrollbackRows: Int

  public init(
    generation: UInt64,
    firstRow: Int,
    availableRows: Int,
    viewportTop: Int,
    viewportOffset: Int,
    scrollbackRows: Int
  ) {
    self.generation = generation
    self.firstRow = firstRow
    self.availableRows = availableRows
    self.viewportTop = viewportTop
    self.viewportOffset = viewportOffset
    self.scrollbackRows = scrollbackRows
  }

  /// Largest absolute row, count or offset a frame may carry. Far beyond
  /// any history, and small enough that row arithmetic cannot overflow.
  public static let maxRow = 1 << 48

  /// Every field is non-negative and at most `maxRow`, so sums of a field
  /// and a grid coordinate (`viewportTop + y`) cannot overflow.
  public var isBounded: Bool {
    [firstRow, availableRows, viewportTop, viewportOffset, scrollbackRows]
      .allSatisfy { $0 >= 0 && $0 <= Self.maxRow }
  }

  public func address(
    viewportRow y: Int,
    alternateScreen: Bool
  ) -> HistoryAddress {
    HistoryAddress(
      generation: generation,
      alternateScreen: alternateScreen,
      row: viewportTop + y
    )
  }
}

/// Inclusive highlighted range in viewport coordinates.
public struct FrameSpan: Codable, Sendable, Equatable {
  public var startRow: Int
  public var startColumn: Int
  public var endRow: Int
  public var endColumn: Int

  public init(startRow: Int, startColumn: Int, endRow: Int, endColumn: Int) {
    self.startRow = startRow
    self.startColumn = startColumn
    self.endRow = endRow
    self.endColumn = endColumn
  }
}

public struct FrameSearch: Codable, Sendable, Equatable {
  public var matchCount: Int
  public var selected: Int?
  /// Visible matches; `selectedVisible` indexes this array.
  public var visible: [FrameSpan]
  public var selectedVisible: Int?

  public init(
    matchCount: Int,
    selected: Int?,
    visible: [FrameSpan],
    selectedVisible: Int?
  ) {
    self.matchCount = matchCount
    self.selected = selected
    self.visible = visible
    self.selectedVisible = selectedVisible
  }
}

/// Complete visible terminal state for one pane. No pointers, pooled ids
/// or GPU resources; column widths are the server's.
public struct PaneFrame: Codable, Sendable, Equatable {
  public var identity: FrameIdentity
  public var grid: FrameGrid
  public var graphemes: [[UInt32]]
  public var styles: [FrameStyle]
  public var underlineColors: [UInt32]
  public var palette: FramePalette
  public var cursor: FrameCursor
  public var modes: SupportedViewModes
  public var history: HistoryWindow
  public var search: FrameSearch?
  public var title: String
  /// The program's drop registration (`dropTargets`); nil when none.
  public var dropTarget: FrameDropTarget?
  /// Per row, the service's edit version (spec.multiplexer.md §4, "Row
  /// identity and versions"). With the row's address it identifies the
  /// row's content: equal identities mean equal content. Nil from a
  /// service that does not track versions.
  public var rowVersions: [UInt64]?

  public init(
    identity: FrameIdentity,
    grid: FrameGrid,
    graphemes: [[UInt32]],
    styles: [FrameStyle],
    underlineColors: [UInt32],
    palette: FramePalette,
    cursor: FrameCursor,
    modes: SupportedViewModes,
    history: HistoryWindow,
    search: FrameSearch?,
    title: String,
    dropTarget: FrameDropTarget? = nil,
    rowVersions: [UInt64]? = nil
  ) {
    self.identity = identity
    self.grid = grid
    self.graphemes = graphemes
    self.styles = styles
    self.underlineColors = underlineColors
    self.palette = palette
    self.cursor = cursor
    self.modes = modes
    self.history = history
    self.search = search
    self.title = title
    self.dropTarget = dropTarget
    self.rowVersions = rowVersions
  }

  /// Identity of row `y`, or nil when the frame carries no versions.
  public func rowIdentity(_ y: Int) -> RowIdentity? {
    guard let rowVersions, y >= 0, y < rowVersions.count else { return nil }
    return RowIdentity(
      address: history.address(
        viewportRow: y,
        alternateScreen: grid.alternateScreen
      ),
      version: rowVersions[y]
    )
  }

  /// Row keys `[generation, alternate, row, version, screen]` for
  /// address-based selections (`PresentationSelection`) and keyed diffs;
  /// `screen` is 1 for a row that can still change in place.
  public var rowKeys: [[UInt64]]? {
    guard let identities = rowIdentities else { return nil }
    let screenTop = history.viewportTop + history.viewportOffset
    return identities.map {
      [
        $0.address.generation, $0.address.alternateScreen ? 1 : 0,
        UInt64(bitPattern: Int64($0.address.row)), $0.version,
        $0.address.alternateScreen || $0.address.row >= screenTop ? 1 : 0,
      ]
    }
  }

  /// Identities of every row, or nil without versions.
  public var rowIdentities: [RowIdentity]? {
    guard let rowVersions, rowVersions.count == grid.rows else { return nil }
    return (0 ..< grid.rows).map { rowIdentity($0)! }
  }

  /// Text of row `y`, trailing blanks trimmed.
  public func text(row y: Int) -> String {
    var s = String.UnicodeScalarView()
    for x in 0 ..< grid.columns {
      s.append(contentsOf: scalars(row: y, column: x))
    }
    var line = String(s)
    while line.last == " " { line.removeLast() }
    return line
  }

  public var lines: [String] { (0 ..< grid.rows).map(text(row:)) }

  /// Display scalars of a cell; a blank is one space, structural cells none.
  public func scalars(row y: Int, column x: Int) -> [Unicode.Scalar] {
    let i = y * grid.columns + x
    switch grid.kind(at: i) {
    case .continuation, .padding: return []
    case .narrow, .wideLead: break
    }
    let g = grid.glyph(at: i)
    if g & FrameGrid.graphemeFlag != 0 {
      return graphemes[Int(g & ~FrameGrid.graphemeFlag)]
        .compactMap(Unicode.Scalar.init)
    }
    if g == 0 { return [" "] }
    return [Unicode.Scalar(g) ?? " "]
  }
}

/// Decides which owned frame is visible. Nothing installs while unattached.
/// A stale server instance, attachment, geometry or layout revision, or older
/// frame revision never replaces a newer installed frame. A frame with the
/// installed revision is accepted again: the service resends a complete
/// frame on resubscription without advancing the revision.
public struct FrameInstallation: Sendable, Equatable {
  /// Identity of the frame installed per pane; the gate needs no cells.
  public private(set) var visible: [PaneID: FrameIdentity] = [:]

  public init() {}

  @discardableResult
  public mutating func install(
    _ frame: PaneFrame,
    server: ServerInstanceID?,
    attachment: AttachmentID?
  ) -> Bool {
    let identity = frame.identity
    if let server, identity.server != server { return false }
    guard let attachment, identity.attachment == attachment else {
      return false
    }
    if let shown = visible[identity.pane] {
      if shown.server != identity.server { return false }
      if shown.attachment != identity.attachment { return false }
      if identity.revision < shown.revision { return false }
      if identity.geometryGeneration < shown.geometryGeneration { return false }
      if identity.layoutRevision < shown.layoutRevision { return false }
    }
    visible[identity.pane] = identity
    return true
  }

  public mutating func retain(attachment: AttachmentID) {
    visible = visible.filter { $0.value.attachment == attachment }
  }

  /// Forgets panes that are no longer shown.
  public mutating func retain(panes: Set<PaneID>) {
    visible = visible.filter { panes.contains($0.key) }
  }
}
