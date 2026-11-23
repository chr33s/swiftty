import ScreenProtocol
import SwiftMuxExport
import SessionCore
import SwiftMuxProtocol
import SwifttyEngine

/// Maps an RST/1 screen in the shared frame model (`paneFrames`,
/// spec.roaming.md §6) to the screen model the client presents: palette
/// tags resolve against the frame's own palette, cell structure and
/// widths are kept exactly. The result is validated like any snapshot.
public enum FrameScreenMapper {
  public static func snapshot(
    _ frame: PaneFrame,
    header: RSTFrameHeader
  ) throws(SnapshotValidationError) -> ScreenSnapshot {
    let g = frame.grid
    var styles: [CellStyle] = [.plain]
    var styleIndex: [CellStyle: Int] = [.plain: 0]
    var mapped = [Int](repeating: -1, count: frame.styles.count)
    var cells: [[ScreenCell]] = []
    cells.reserveCapacity(g.rows)
    var wrapped: [Bool] = []
    wrapped.reserveCapacity(g.rows)
    for y in 0 ..< g.rows {
      wrapped.append(g.isWrapped(row: y))
      var row: [ScreenCell] = []
      row.reserveCapacity(g.columns)
      for x in 0 ..< g.columns {
        let i = y * g.columns + x
        let s = g.style(at: i)
        if mapped[s] < 0 {
          let style = cellStyle(frame.styles[s], frame: frame)
          if let known = styleIndex[style] {
            mapped[s] = known
          } else {
            mapped[s] = styles.count
            styleIndex[style] = styles.count
            styles.append(style)
          }
        }
        let style = mapped[s]
        switch g.kind(at: i) {
        case .continuation: row.append(ScreenCell("", width: 0, style: style))
        case .padding: row.append(ScreenCell("", width: 1, style: style))
        case .wideLead:
          row.append(ScreenCell(text(frame, y, x), width: 2, style: style))
        case .narrow:
          row.append(ScreenCell(text(frame, y, x), width: 1, style: style))
        }
      }
      cells.append(row)
    }
    let shape: CursorShape =
      switch frame.cursor.style {
      case 1: .underline
      case 2: .bar
      default: .block
      }
    let snapshot = ScreenSnapshot(
      sessionID: header.sessionID,
      attachmentEpoch: header.attachmentEpoch,
      screenRevision: header.screenRevision,
      resizeRevision: header.resizeRevision,
      columns: g.columns,
      rows: g.rows,
      activeBuffer: g.alternateScreen ? .alternate : .primary,
      cursor: ScreenCursor(
        row: frame.cursor.y,
        column: frame.cursor.x,
        visible: frame.cursor.visible,
        shape: shape,
        blinking: frame.cursor.blinking
      ),
      reverseVideo: frame.modes.contains(.reverseVideo),
      mouseTracking: frame.modes.contains(.mouseTracking),
      title: frame.title,
      wrapped: wrapped,
      styles: styles,
      cells: cells,
      lastFullyAppliedInputSequence: header.lastFullyAppliedInputSequence
    )
    try snapshot.validate()
    return snapshot
  }

  /// Grapheme text as the host's legacy export shows it.
  static func text(_ frame: PaneFrame, _ y: Int, _ x: Int) -> String {
    let glyph = frame.grid.glyph(at: y * frame.grid.columns + x)
    return RSTPresentation.text(
      glyph & FrameGrid.graphemeFlag != 0
        ? frame.graphemes[Int(glyph & ~FrameGrid.graphemeFlag)]
        : glyph == 0 ? [] : [glyph]
    )
  }

  static func cellStyle(_ style: FrameStyle, frame: PaneFrame) -> CellStyle {
    func resolve(_ raw: UInt32) -> RGBColor? {
      switch TerminalColor(rawValue: raw).kind {
      case .default: nil
      case let .palette(index): RGBColor(frame.palette.colors[Int(index)])
      case let .rgb(value): RGBColor(value)
      }
    }
    let underline =
      style.underlineColor == 0
      ? nil : resolve(frame.underlineColors[Int(style.underlineColor) - 1])
    return CellStyle(
      foreground: resolve(style.foreground),
      background: resolve(style.background),
      underlineColor: underline,
      attributes: RSTPresentation.attributes(CellFlags(rawValue: style.flags))
    )
  }

}
