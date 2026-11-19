/// An owned presentation frame produced elsewhere — for example by a
/// remote host's authoritative terminal — for display without parsing.
///
/// Install with `TerminalSession.installPresentation(_:)` on a session in
/// presentation mode. The frame replaces the visible state atomically,
/// preserving the host's row/cell layout: nothing is reflowed and widths
/// are not recalculated.
public struct PresentationFrame: Sendable, Equatable {
  public struct Style: Sendable, Hashable {
    /// 0xRRGGBB, or nil for the local default.
    public var foreground: UInt32?
    public var background: UInt32?
    public var underlineColor: UInt32?
    /// Presentation attributes only; structural flags are derived from
    /// cell widths.
    public var flags: CellFlags

    public init(
      foreground: UInt32? = nil,
      background: UInt32? = nil,
      underlineColor: UInt32? = nil,
      flags: CellFlags = []
    ) {
      self.foreground = foreground
      self.background = background
      self.underlineColor = underlineColor
      self.flags = flags
    }
  }

  public struct Cell: Sendable, Hashable {
    /// Complete grapheme cluster; empty for a blank cell.
    public var text: String
    /// 1 narrow, 2 wide lead, 0 continuation of the preceding wide lead.
    public var width: UInt8
    /// Index into `styles`.
    public var style: Int

    public init(text: String = "", width: UInt8 = 1, style: Int = 0) {
      self.text = text
      self.width = width
      self.style = style
    }
  }

  public var columns: Int
  public var rows: Int
  /// Row-major, `columns * rows` cells.
  public var cells: [Cell]
  public var wrapped: [Bool]
  public var styles: [Style]
  public var cursorX: Int
  public var cursorY: Int
  public var cursorVisible: Bool
  public var cursorStyle: CursorStyle
  public var cursorBlinking: Bool
  public var reverseVideo: Bool
  public var alternateScreen: Bool
  public var title: String
  /// Per row, the host's row identity `[generation, alternate, row,
  /// version, screen]` when the host sends shared frames (spec.roaming.md
  /// §6): equal identities mean equal row content, so a terminal frontend
  /// can skip comparing the row, and a selection can follow its rows
  /// across frames. `screen` is 1 for a row that can still change in
  /// place. Nil otherwise.
  public var rowKeys: [[UInt64]]? = nil

  public init(
    columns: Int,
    rows: Int,
    cells: [Cell],
    wrapped: [Bool],
    styles: [Style],
    cursorX: Int,
    cursorY: Int,
    cursorVisible: Bool = true,
    cursorStyle: CursorStyle = .block,
    cursorBlinking: Bool = false,
    reverseVideo: Bool = false,
    alternateScreen: Bool = false,
    title: String = ""
  ) {
    self.columns = columns
    self.rows = rows
    self.cells = cells
    self.wrapped = wrapped
    self.styles = styles
    self.cursorX = cursorX
    self.cursorY = cursorY
    self.cursorVisible = cursorVisible
    self.cursorStyle = cursorStyle
    self.cursorBlinking = cursorBlinking
    self.reverseVideo = reverseVideo
    self.alternateScreen = alternateScreen
    self.title = title
  }
}

extension PresentationFrame {
  /// Largest accepted grid. RST/1 itself bounds grids to 200 x 80; this
  /// local cap only keeps a malformed frame from allocating unboundedly.
  public static let maxColumns = 1024
  public static let maxRows = 1024
  public static let maxCells = 262_144
  /// Longest cell grapheme, in UTF-8 bytes (spec.roaming.md §12).
  public static let maxGraphemeUTF8 = 64
  /// Longest title, in UTF-8 bytes.
  public static let maxTitleUTF8 = 1024

  /// Whether the frame can be installed: dimensions, cell and style
  /// counts, style indices and colors, widths and continuations, cell
  /// text, cursor bounds and title length. O(cells), without allocating
  /// per cell.
  public var isValid: Bool {
    guard (1 ... Self.maxColumns).contains(columns),
      (1 ... Self.maxRows).contains(rows), columns * rows <= Self.maxCells,
      cells.count == columns * rows, wrapped.count == rows, !styles.isEmpty,
      styles.count <= cells.count, (0 ..< columns).contains(cursorX),
      (0 ..< rows).contains(cursorY), title.utf8.count <= Self.maxTitleUTF8
    else { return false }
    for style in styles {
      for color in [style.foreground, style.background, style.underlineColor]
      where (color ?? 0) > 0xFF_FFFF { return false }
    }
    for y in 0 ..< rows {
      let base = y * columns
      for x in 0 ..< columns {
        let cell = cells[base + x]
        guard cell.style >= 0, cell.style < styles.count else { return false }
        switch cell.width {
        case 1: break
        case 2:
          guard x + 1 < columns, cells[base + x + 1].width == 0 else {
            return false
          }
        case 0:
          guard x > 0, cells[base + x - 1].width == 2, cell.text.isEmpty else {
            return false
          }
        default: return false
        }
        guard cell.text.utf8.count <= Self.maxGraphemeUTF8 else { return false }
        for scalar in cell.text.unicodeScalars {
          // Controls would be interpreted nowhere but could confuse
          // rendering and copied text.
          let v = scalar.value
          if v < 0x20 || (0x7F ... 0x9F).contains(v) { return false }
        }
      }
    }
    return true
  }
}

/// What a frontend may offer for the session it displays. Remote
/// presentation sessions disable features that would otherwise operate on
/// a local emulator (spec.roaming.md §A.4.1).
public struct SurfaceCapabilities: Sendable, Hashable {
  public var scrollback: Bool
  public var search: Bool
  public var mouseReporting: Bool
  /// Program-initiated clipboard writes (OSC 52) may reach the pasteboard.
  public var remoteClipboardWrites: Bool
  /// User-initiated local copy of the displayed frame.
  public var localCopy: Bool
  /// Paste from the local clipboard.
  public var paste: Bool
  public var openURLs: Bool
  public var localProcess: Bool
  public var textInput: Bool

  public init(
    scrollback: Bool,
    search: Bool,
    mouseReporting: Bool,
    remoteClipboardWrites: Bool,
    localCopy: Bool,
    paste: Bool,
    openURLs: Bool,
    localProcess: Bool,
    textInput: Bool
  ) {
    self.scrollback = scrollback
    self.search = search
    self.mouseReporting = mouseReporting
    self.remoteClipboardWrites = remoteClipboardWrites
    self.localCopy = localCopy
    self.paste = paste
    self.openURLs = openURLs
    self.localProcess = localProcess
    self.textInput = textInput
  }

  /// A local or ordinary byte-stream session: every feature.
  public static let full = SurfaceCapabilities(
    scrollback: true,
    search: true,
    mouseReporting: true,
    remoteClipboardWrites: true,
    localCopy: true,
    paste: true,
    openURLs: true,
    localProcess: true,
    textInput: true
  )

  /// RST/1 v1 presentation: current viewport only, local copy and paste,
  /// no remote side effects.
  public static let roaming = SurfaceCapabilities(
    scrollback: false,
    search: false,
    mouseReporting: false,
    remoteClipboardWrites: false,
    localCopy: true,
    paste: true,
    openURLs: false,
    localProcess: false,
    textInput: true
  )
}
