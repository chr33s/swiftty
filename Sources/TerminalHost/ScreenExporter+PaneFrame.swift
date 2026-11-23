#if os(macOS)
import Foundation
import ScreenProtocol
import SessionCore
import SwiftMuxProtocol

extension ScreenExporter {
  /// An RST/1 screen from a frame a SwiftMux worker sent this host (its
  /// controller viewport, row versions included): clipped to the RST/1
  /// grid, overlong graphemes shown as the placeholder, with the RST/1
  /// profile's title bound and without search, drop targets, motion or
  /// paste-event modes. Nil when it still exceeds the RST/1 budgets.
  package static func frame(
    from source: PaneFrame,
    stamp: Stamp
  ) -> (PaneFrame, RSTFrameHeader)? {
    let header = RSTFrameHeader(
      sessionID: stamp.sessionID,
      attachmentEpoch: stamp.attachmentEpoch,
      screenRevision: stamp.screenRevision,
      resizeRevision: stamp.resizeRevision,
      lastFullyAppliedInputSequence: stamp.lastFullyAppliedInputSequence
    )
    var frame = source
    frame.identity = header.frameIdentity
    frame.title = boundedTitle(frame.title)
    frame.search = nil
    frame.dropTarget = nil
    frame.modes.subtract([
      .mouseButtonMotion, .mouseAnyMotion, .kittyPasteEvents,
    ])
    clip(&frame)
    let limits = SnapshotFrame.frameLimits
    replaceOverlongGraphemes(&frame, maxScalars: limits.maxGraphemeScalars)
    guard (try? FrameValidator.validate(frame, limits: limits)) != nil else {
      return nil
    }
    return (frame, header)
  }

  /// Keeps the top-left RST/1 grid; a wide cell whose trailing half is
  /// clipped becomes blank. Row addressing is unchanged.
  static func clip(_ frame: inout PaneFrame) {
    let source = frame.grid
    let columns = min(source.columns, RSTLimits.maxColumns)
    let rows = min(source.rows, RSTLimits.maxRows)
    guard columns != source.columns || rows != source.rows else { return }
    var glyphs = Data(capacity: columns * rows * 4)
    var styles = Data(capacity: columns * rows * 2)
    var kinds = Data(capacity: columns * rows)
    var wrapped = Data(capacity: rows)
    for y in 0 ..< rows {
      wrapped.append(source.isWrapped(row: y) ? 1 : 0)
      for x in 0 ..< columns {
        let i = y * source.columns + x
        var glyph = source.glyph(at: i)
        var style = UInt16(truncatingIfNeeded: source.style(at: i))
        var kind = source.kind(at: i)
        if x == columns - 1, kind == .wideLead, columns < source.columns {
          (glyph, style, kind) = (0, 0, .narrow)
        }
        withUnsafeBytes(of: glyph.littleEndian) {
          glyphs.append(contentsOf: $0)
        }
        withUnsafeBytes(of: style.littleEndian) {
          styles.append(contentsOf: $0)
        }
        kinds.append(kind.rawValue)
      }
    }
    frame.grid = FrameGrid(
      columns: columns,
      rows: rows,
      alternateScreen: source.alternateScreen,
      wrapped: wrapped,
      glyphs: glyphs,
      styles: styles,
      kinds: kinds
    )
    frame.rowVersions = frame.rowVersions.map { Array($0.prefix(rows)) }
    frame.cursor.x = min(max(0, frame.cursor.x), columns - 1)
    frame.cursor.y = min(max(0, frame.cursor.y), rows - 1)
  }

  /// Clusters longer than RST/1 carries show the placeholder instead.
  static func replaceOverlongGraphemes(
    _ frame: inout PaneFrame,
    maxScalars: Int
  ) {
    guard frame.graphemes.contains(where: { $0.count > maxScalars }) else {
      return
    }
    let placeholder = RSTLimits.graphemePlaceholder.unicodeScalars.first!.value
    var kept: [[UInt32]] = []
    var remap: [Int: UInt32] = [:]
    for (index, scalars) in frame.graphemes.enumerated() {
      if scalars.count > maxScalars {
        remap[index] = placeholder
      } else {
        remap[index] = FrameGrid.graphemeFlag | UInt32(kept.count)
        kept.append(scalars)
      }
    }
    var glyphs = frame.grid.glyphs
    let count = frame.grid.columns * frame.grid.rows
    for i in 0 ..< count {
      let glyph = frame.grid.glyph(at: i)
      guard glyph & FrameGrid.graphemeFlag != 0,
        let replacement = remap[Int(glyph & ~FrameGrid.graphemeFlag)]
      else { continue }
      withUnsafeBytes(of: replacement.littleEndian) {
        glyphs.replaceSubrange(
          glyphs.startIndex + i * 4 ..< glyphs.startIndex + i * 4 + 4,
          with: $0
        )
      }
    }
    frame.grid.glyphs = glyphs
    frame.graphemes = kept
  }
}
#endif
