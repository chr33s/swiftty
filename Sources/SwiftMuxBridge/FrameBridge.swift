import Foundation
import SwiftMuxProtocol
import SwifttyCore
@_exported import SwiftMuxExport

/// Builds app-owned renderer input from a validated frame.
public enum FrameImporter {
  /// Validates, then converts. Never partially applies an invalid frame.
  package static func screen(
    from frame: PaneFrame,
    limits: MuxLimits = .standard
  ) throws(MuxError) -> OwnedScreen {
    try FrameValidator.validate(frame, limits: limits)
    return convert(frame)
  }

  /// Converts a frame that already passed `FrameValidator` (every frame
  /// `MuxConnection` delivers): an invalid one can trap.
  private static func convert(_ frame: PaneFrame) -> OwnedScreen {
    let g = frame.grid
    let count = g.columns * g.rows
    var cells: [Cell] = []
    cells.reserveCapacity(count)
    // Attributes per style entry, built once rather than per cell.
    let table = frame.styles.map { s in
      var attributes = CellAttributes(
        foreground: TerminalColor(rawValue: s.foreground),
        background: TerminalColor(rawValue: s.background),
        flags: CellFlags(rawValue: s.flags).subtracting(.structural)
      )
      attributes.underlineColor = s.underlineColor
      return attributes
    }
    for i in 0 ..< count {
      let glyph = g.glyph(at: i)
      var cell = Cell(glyph: 0, attributes: table[g.style(at: i)], width: 1)
      switch g.kind(at: i) {
      case .continuation:
        cell.width = 0
        cell.attributes.flags.insert(.spacerTail)
      case .padding: cell.attributes.flags.insert(.spacerHead)
      case .narrow, .wideLead:
        cell.width = g.kind(at: i) == .wideLead ? 2 : 1
        if glyph & FrameGrid.graphemeFlag != 0 {
          cell.glyph = glyph & ~FrameGrid.graphemeFlag
          cell.attributes.flags.insert(.grapheme)
        } else {
          cell.glyph = glyph
        }
      }
      cells.append(cell)
    }
    var colors = InlineArray<256, UInt32>(repeating: 0)
    for i in 0 ..< 256 { colors[i] = frame.palette.colors[i] }
    let p = frame.palette
    var modes: Modes = []
    if frame.modes.contains(.cursorKeys) { modes.insert(.cursorKeys) }
    if frame.modes.contains(.bracketedPaste) { modes.insert(.bracketedPaste) }
    if frame.modes.contains(.alternateScreen) { modes.insert(.alternateScreen) }
    if frame.modes.contains(.reverseVideo) { modes.insert(.reverseVideo) }
    if frame.modes.contains(.focusEvents) { modes.insert(.focusEvents) }
    if frame.modes.contains(.keypadApplication) {
      modes.insert(.keypadApplication)
    }
    if frame.cursor.visible { modes.insert(.cursorVisible) }
    if frame.cursor.blinking { modes.insert(.cursorBlink) }
    modes.insert(.autowrap)
    let search = frame.search
    return OwnedScreen(
      columns: g.columns,
      rows: g.rows,
      cells: cells,
      wrapped: (0 ..< g.rows).map(g.isWrapped(row:)),
      graphemes: frame.graphemes,
      cursor: CursorState(
        x: frame.cursor.x,
        y: frame.cursor.y,
        isVisible: frame.cursor.visible,
        style: CursorStyle(rawValue: frame.cursor.style) ?? .block,
        isBlinking: frame.cursor.blinking
      ),
      palette: Palette(
        colors: colors,
        foreground: p.foreground,
        background: p.background,
        cursor: p.cursor,
        cursorText: p.cursorText,
        selectionForeground: p.selectionForeground,
        selectionBackground: p.selectionBackground
      ),
      underlineColors: frame.underlineColors.map {
        TerminalColor(rawValue: $0)
      },
      modes: modes,
      title: frame.title,
      isAlternateScreen: g.alternateScreen,
      addressingGeneration: frame.history.generation,
      firstAbsoluteRow: frame.history.firstRow,
      viewportTopRow: frame.history.viewportTop,
      viewportOffset: frame.history.viewportOffset,
      scrollbackCount: frame.history.scrollbackRows,
      searchMatches: (search?.visible ?? [])
        .map {
          HighlightSpan(
            startRow: $0.startRow,
            startColumn: $0.startColumn,
            endRow: $0.endRow,
            endColumn: $0.endColumn
          )
        },
      selectedSearchMatch: search?.selectedVisible,
      searchMatchCount: search?.matchCount ?? 0
    )
  }

  /// A renderer snapshot of a frame `MuxConnection` delivered, which it
  /// has already validated against the server's limits.
  package static func snapshot(
    fromValidated frame: PaneFrame,
    selection: HighlightSpan? = nil,
    sequence: UInt64,
    limits: MuxLimits = .standard
  ) -> RenderSnapshot {
    assert((try? FrameValidator.validate(frame, limits: limits)) != nil)
    return RenderSnapshot(
      owned: convert(frame),
      selection: selection,
      sequence: sequence
    )
  }

  /// An independent renderer snapshot with full damage.
  public static func snapshot(
    from frame: PaneFrame,
    selection: HighlightSpan? = nil,
    sequence: UInt64,
    limits: MuxLimits = .standard
  ) throws(MuxError) -> RenderSnapshot {
    RenderSnapshot(
      owned: try screen(from: frame, limits: limits),
      selection: selection,
      sequence: sequence
    )
  }
}
