import Foundation
import ScreenProtocol
import SessionCore
import SwiftMuxProtocol

/// A fake host's screen as the RST/1 frame record a real host sends:
/// text, widths, cursor, title and modes; every cell in the plain style.
func rstFrameRecord(_ snapshot: ScreenSnapshot) throws -> [UInt8] {
  let header = RSTFrameHeader(
    sessionID: snapshot.sessionID,
    attachmentEpoch: snapshot.attachmentEpoch,
    screenRevision: snapshot.screenRevision,
    resizeRevision: snapshot.resizeRevision,
    lastFullyAppliedInputSequence: snapshot.lastFullyAppliedInputSequence
  )
  var glyphs: [UInt32] = []
  var kinds: [UInt8] = []
  var graphemes: [[UInt32]] = []
  for row in snapshot.cells {
    for cell in row {
      let scalars = cell.text.unicodeScalars.map(\.value)
      switch scalars.count {
      case 0: glyphs.append(0)
      case 1: glyphs.append(scalars[0])
      default:
        glyphs.append(FrameGrid.graphemeFlag | UInt32(graphemes.count))
        graphemes.append(scalars)
      }
      let kind: CellKind =
        switch cell.width {
        case 0: .continuation
        case 2: .wideLead
        default: .narrow
        }
      kinds.append(kind.rawValue)
    }
  }
  let cursorStyle: UInt8 =
    switch snapshot.cursor.shape {
    case .block: 0
    case .underline: 1
    case .bar: 2
    }
  var modes: SupportedViewModes = []
  if snapshot.activeBuffer == .alternate { modes.insert(.alternateScreen) }
  if snapshot.reverseVideo { modes.insert(.reverseVideo) }
  if snapshot.mouseTracking { modes.insert(.mouseTracking) }
  let frame = PaneFrame(
    identity: header.frameIdentity,
    grid: FrameGrid(
      columns: snapshot.columns,
      rows: snapshot.rows,
      alternateScreen: snapshot.activeBuffer == .alternate,
      wrapped: Data(snapshot.wrapped.map { $0 ? 1 : 0 }),
      glyphs: glyphs.map(\.littleEndian).withUnsafeBytes { Data($0) },
      styles: Data(repeating: 0, count: glyphs.count * 2),
      kinds: Data(kinds)
    ),
    graphemes: graphemes,
    styles: [.plain],
    underlineColors: [],
    palette: FramePalette(
      colors: Array(repeating: 0x10_2030, count: 256),
      foreground: 0xFF_FFFF,
      background: 0,
      cursor: 0xFF_FFFF
    ),
    cursor: FrameCursor(
      // A snapshot parks a pending-wrap cursor past the last column; a
      // frame keeps it on the grid (the engine holds pending wrap as a flag).
      x: min(snapshot.cursor.column, snapshot.columns - 1),
      y: snapshot.cursor.row,
      visible: snapshot.cursor.visible,
      style: cursorStyle,
      blinking: snapshot.cursor.blinking
    ),
    modes: modes,
    history: HistoryWindow(
      generation: 0,
      firstRow: 0,
      availableRows: snapshot.rows,
      viewportTop: 0,
      viewportOffset: 0,
      scrollbackRows: 0
    ),
    search: nil,
    title: snapshot.title
  )
  let record = SMXB.encode(frame, envelope: .rst(header.bytes))
  return try SnapshotFrame.encode(frame: [UInt8](record))
}
