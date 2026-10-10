import Foundation

// Shared frontend actions, pointer shapes, blinking, links, and gestures.

/// Turns fractional scroll distances into whole lines, carrying the rest.
public struct ScrollAccumulator: Sendable {
  public private(set) var remainder: CGFloat = 0

  public init() {}

  /// Adds `lines` (positive scrolls back into history) and returns the
  /// whole lines to scroll now. Nonfinite or unrepresentable distances
  /// are ignored, preserving the accumulated fraction.
  public mutating func add(_ lines: CGFloat) -> Int {
    let total = remainder + lines
    guard let whole = Int(exactly: total.rounded(.towardZero)), whole != .min
    else { return 0 }
    remainder = total - CGFloat(whole)
    return whole
  }

  public mutating func reset() { remainder = 0 }
}

/// Conversions at the frontend boundary, where scaled configuration
/// values can overflow even though their inputs were finite.
public enum TerminalGeometry {
  /// Nonnegative pixels for terminal reports, saturated to an integer.
  public static func pixelExtent(_ value: CGFloat) -> Int {
    guard value > 0 else { return 0 }
    if value >= CGFloat(Int.max) { return .max }
    return Int(value)
  }

  /// A cell coordinate, retaining out-of-grid positions for dragging.
  /// Bounds match the renderer's grid and leave room for row arithmetic.
  public static func cellIndex(_ value: CGFloat) -> Int {
    guard !value.isNaN else { return 0 }
    let limit = CGFloat(UInt16.max)
    return Int(min(limit, max(-limit, value)).rounded(.down))
  }

  /// Maps an IME UTF-16 position to the columns used by preedit rendering.
  /// Positions inside a grapheme snap to its start, or its end when
  /// `roundUp` is true (for the end of a nonempty text range).
  public static func compositionColumn(
    in scalars: [Unicode.Scalar],
    atUTF16Offset target: Int,
    roundUp: Bool = false
  ) -> Int {
    compositionPosition(in: scalars, atUTF16Offset: target, roundUp: roundUp)
      .column
  }

  /// The rendered column and matching UTF-16 grapheme boundary of an IME
  /// position. Out-of-range positions clamp to the composition's bounds.
  public static func compositionPosition(
    in scalars: [Unicode.Scalar],
    atUTF16Offset target: Int,
    roundUp: Bool = false,
  ) -> (column: Int, utf16Offset: Int) {
    guard target > 0 else { return (0, 0) }
    let values = scalars.map(\.value)
    var offset = 0
    var utf16 = 0
    var column = 0
    while offset < values.count {
      let (length, width) = GraphemeBreak.graphemeWidth(values[offset...])
      let columns = max(1, width)
      var end = utf16
      for i in offset ..< offset + length { end += values[i] > 0xFFFF ? 2 : 1 }
      if target < end {
        return roundUp ? (column + columns, end) : (column, utf16)
      }
      column += columns
      if target == end { return (column, end) }
      utf16 = end
      offset += length
    }
    return (column, utf16)
  }

  /// Grapheme boundaries around a rendered preedit column. Positions
  /// outside the composition return an empty range at the nearest end.
  public static func compositionRange(
    in scalars: [Unicode.Scalar],
    atColumn target: CGFloat,
  ) -> (columns: Range<Int>, utf16: Range<Int>) {
    guard target >= 0 else { return (0 ..< 0, 0 ..< 0) }
    let values = scalars.map(\.value)
    var offset = 0
    var utf16 = 0
    var column = 0
    while offset < values.count {
      let (length, width) = GraphemeBreak.graphemeWidth(values[offset...])
      let endColumn = column + max(1, width)
      var end = utf16
      for i in offset ..< offset + length { end += values[i] > 0xFFFF ? 2 : 1 }
      if target < CGFloat(endColumn) {
        return (column ..< endColumn, utf16 ..< end)
      }
      column = endColumn
      utf16 = end
      offset += length
    }
    return (column ..< column, utf16 ..< utf16)
  }
}

// MARK: - Key-binding actions

public enum ActionDispatch {
  /// - Parameters:
  ///   - action: Requested keybinding action.
  ///   - rows: Visible rows.
  ///   - history: Available history rows.
  /// - Returns: Viewport lines (positive towards history), or nil for other actions.
  public static func viewportDelta(
    for action: KeyAction,
    rows: Int,
    history: Int
  ) -> Int? {
    switch action {
    case .scrollToTop: history
    case .scrollToBottom: -history
    case .scrollPageUp: rows
    case .scrollPageDown: -rows
    // Ghostty's `scroll_page_lines:n` scrolls down for positive n.
    case let .scrollPageLines(n): n == .min ? .max : -n
    default: nil
    }
  }

  /// Menu and discoverability-HUD title.
  public static func title(for action: KeyAction) -> String {
    switch action {
    case .copyToClipboard: "Copy"
    case .pasteFromClipboard: "Paste"
    case .increaseFontSize: "Bigger"
    case .decreaseFontSize: "Smaller"
    case .resetFontSize: "Reset Font Size"
    case .selectAll: "Select All"
    case .scrollToTop: "Scroll to Top"
    case .scrollToBottom: "Scroll to Bottom"
    case .scrollPageUp: "Page Up"
    case .scrollPageDown: "Page Down"
    case let .scrollPageLines(n):
      n < 0 ? "Scroll Up \(n.magnitude) Lines" : "Scroll Down \(n) Lines"
    case let .jumpToPrompt(n): n < 0 ? "Previous Prompt" : "Next Prompt"
    case .startSearch: "Find…"
    case .searchSelection: "Find Selection"
    case let .navigateSearch(next): next ? "Find Next" : "Find Previous"
    case .endSearch: "End Find"
    case .clearScreen: "Clear Screen"
    case .reset: "Reset Terminal"
    case .text, .textBytes, .csi, .esc: "Send Text"
    case .ignore: "Ignore"
    }
  }
}

// MARK: - Pointer shapes

/// OSC 22 pointer shapes (CSS cursor names) reduced to what iPadOS pointers
/// can show.
public enum PointerShape: Equatable, Sendable {
  case beam, link, system, crosshair, resizeHorizontal, resizeVertical, move,
    hidden

  /// Shape for a CSS cursor name; unknown names fall back to the I-beam.
  public init(cssName: String) {
    switch cssName.lowercased() {
    case "text", "vertical-text": self = .beam
    case "pointer", "hand", "alias", "copy", "context-menu", "help":
      self = .link
    case "default", "auto", "progress", "wait", "not-allowed", "no-drop",
      "zoom-in", "zoom-out":
      self = .system
    case "crosshair", "cell": self = .crosshair
    case "ew-resize", "col-resize", "e-resize", "w-resize":
      self = .resizeHorizontal
    case "ns-resize", "row-resize", "n-resize", "s-resize":
      self = .resizeVertical
    case "move", "all-scroll", "grab", "grabbing", "nesw-resize", "nwse-resize",
      "ne-resize", "nw-resize", "se-resize", "sw-resize":
      self = .move
    case "none": self = .hidden
    default: self = .beam
    }
  }

  /// The pointer for the current state: a link under the pointer wins,
  /// then the application's OSC 22 shape, then the system pointer while
  /// it tracks the mouse, else the I-beam.
  public static func resolve(
    applicationShape: String,
    overLink: Bool,
    tracking: Bool
  ) -> PointerShape {
    if overLink { return .link }
    if !applicationShape.isEmpty {
      return PointerShape(cssName: applicationShape)
    }
    return tracking ? .system : .beam
  }
}

// MARK: - Blinking

/// Cursor and SGR 5 text blink phases. Both start visible, toggle on each
/// tick while they blink, and return to visible on input.
public struct BlinkState: Equatable, Sendable {
  public static let interval: TimeInterval = 0.6

  public private(set) var cursorVisible = true
  public private(set) var textVisible = true

  public init() {}

  /// Whether a timer is needed: something blinks and is being shown.
  public static func needsTimer(
    cursorBlinks: Bool,
    textBlinks: Bool,
    focused: Bool,
    background: Bool
  ) -> Bool { !background && ((cursorBlinks && focused) || textBlinks) }

  public mutating func tick(cursorBlinks: Bool, textBlinks: Bool) {
    cursorVisible = cursorBlinks ? !cursorVisible : true
    textVisible = textBlinks ? !textVisible : true
  }

  /// Typing shows the cursor (and keeps it shown for a full phase).
  public mutating func reset() {
    cursorVisible = true
    textVisible = true
  }
}

// MARK: - Links

public enum LinkPolicy {
  /// Schemes opened with the system handler; others (file, javascript,
  /// custom app schemes) are ignored.
  public static let schemes: Set<String> = [
    "http", "https", "mailto", "ftp", "ssh",
  ]

  public static func openableURL(_ string: String) -> URL? {
    guard let url = URL(string: string.trimmingCharacters(in: .whitespaces)),
      let scheme = url.scheme?.lowercased(), schemes.contains(scheme)
    else { return nil }
    // A scheme alone ("https:") goes nowhere.
    guard scheme == "mailto" || url.host?.isEmpty == false else { return nil }
    return url
  }

  /// The link's cells in snapshot rows, for underlining under the pointer.
  public static func span(
    of range: TerminalRange,
    firstVisibleRow: Int
  ) -> HighlightSpan {
    HighlightSpan(
      startRow: range.start.row - firstVisibleRow,
      startColumn: range.start.column,
      endRow: range.end.row - firstVisibleRow,
      endColumn: range.end.column,
    )
  }
}

// MARK: - Click to move

public enum ClickToMove {
  /// Arrow presses moving the shell's cursor by `moves` characters
  /// (negative is left), as `promptCursorMoves(to:)` reports.
  public static func keys(_ moves: Int) -> [KeyEvent] {
    Array(repeating: KeyEvent(moves < 0 ? .left : .right), count: abs(moves))
  }
}

// MARK: - Selection

public enum SelectionMath {
  /// Selection from the span a gesture started on to the span now under
  /// the finger, keeping the whole starting unit (a word stays selected
  /// when dragging backwards).
  public static func extend(
    origin: (start: TerminalPoint, end: TerminalPoint),
    to span: (start: TerminalPoint, end: TerminalPoint),
    rectangle: Bool = false,
  ) -> Selection {
    span.start < origin.start
      ? Selection(anchor: origin.end, head: span.start, rectangle: rectangle)
      : Selection(anchor: origin.start, head: span.end, rectangle: rectangle)
  }

  /// Viewport lines to scroll when dragging past the top (+1, into
  /// history) or bottom (−1) of `rows` visible rows.
  public static func edgeScroll(row: Int, rows: Int) -> Int {
    row < 0 ? 1 : row >= rows ? -1 : 0
  }
}
