#if os(macOS)
import ScreenProtocol
import SessionCore
import SwiftMuxExport
import SwiftMuxProtocol
import SwifttyEngine

/// Converts the authoritative `TerminalState` into an owned RST/1
/// `ScreenSnapshot` (spec §6, §A.4.2).
///
/// Runs while the state is borrowed on its owner's queue (for example
/// inside `TerminalSession.withState` called from outside that queue) and
/// copies everything it needs, so nothing borrowed outlives the call.
/// Never use `TerminalSession.snapshot()` for this: it consumes renderer
/// damage and synchronizes on the session queue.
public enum ScreenExporter {
  /// Revision and identity metadata stamped on an exported snapshot.
  public struct Stamp: Sendable, Hashable {
    public var sessionID: SessionID
    public var attachmentEpoch: UInt64
    public var screenRevision: UInt64
    public var resizeRevision: UInt64
    public var lastFullyAppliedInputSequence: UInt64

    public init(
      sessionID: SessionID,
      attachmentEpoch: UInt64 = 0,
      screenRevision: UInt64 = 0,
      resizeRevision: UInt64 = 0,
      lastFullyAppliedInputSequence: UInt64 = 0
    ) {
      self.sessionID = sessionID
      self.attachmentEpoch = attachmentEpoch
      self.screenRevision = screenRevision
      self.resizeRevision = resizeRevision
      self.lastFullyAppliedInputSequence = lastFullyAppliedInputSequence
    }
  }

  /// The history window top after moving `lines` (positive reveals older
  /// lines) from `top` (nil: live output). Nil again at the live screen;
  /// the alternate screen has no history window. Reads metadata only.
  public static func historyTop(
    _ state: borrowing TerminalState,
    from top: Int?,
    moving lines: Int
  ) -> Int? {
    guard !state.isAlternateScreen else { return nil }
    let first = state.firstAbsoluteRow
    let live = first + state.scrollbackCount
    let start = min(max(top ?? live, first), live)
    let (moved, overflow) = start.subtractingReportingOverflow(lines)
    let next =
      overflow ? (lines > 0 ? first : live) : min(max(moved, first), live)
    return next >= live ? nil : next
  }

  /// Copies the active screen, or with `historyTop` the window of the
  /// primary screen and its history starting at that absolute row,
  /// without moving the terminal's own viewport. The result always passes
  /// `ScreenSnapshot.validate()` for grids within the RST/1 limits; larger
  /// host grids are clipped to `RSTLimits.maxColumns` × `maxRows`.
  public static func export(
    _ state: borrowing TerminalState,
    stamp: Stamp,
    historyTop: Int? = nil
  ) -> ScreenSnapshot {
    let columns = min(max(state.columns, 1), RSTLimits.maxColumns)
    let rows = min(max(state.rows, 1), RSTLimits.maxRows)
    // Absolute row shown first; the live screen unless a window is open.
    let live = state.firstAbsoluteRow + state.scrollbackCount
    let top =
      state.isAlternateScreen
      ? state.firstAbsoluteRow
      : min(max(historyTop ?? live, state.firstAbsoluteRow), live)
    let inHistory = !state.isAlternateScreen && top < live
    var styles = StyleTable(palette: state.palette)
    var cells: [[ScreenCell]] = []
    cells.reserveCapacity(rows)
    var wrapped: [Bool] = []
    wrapped.reserveCapacity(rows)
    var scalars: [UInt32] = []
    scalars.reserveCapacity(16)

    for y in 0 ..< rows {
      var row: [ScreenCell] = []
      row.reserveCapacity(columns)
      guard let (source, isWrapped) = state.line(absoluteRow: top + y) else {
        for _ in 0 ..< columns {
          row.append(ScreenCell("", width: 1, style: 0))
        }
        cells.append(row)
        wrapped.append(false)
        continue
      }
      var x = 0
      while x < columns {
        let cell = source[x]
        let style = styles.index(for: cell.attributes, in: state)
        let flags = cell.flags
        // Spacers that are not the tail of an exported wide lead (a
        // padding head, or an orphan) present as blank narrow cells.
        if flags.contains(.spacerHead) || flags.contains(.spacerTail)
          || cell.width == 0
        {
          row.append(ScreenCell("", width: 1, style: style))
          x += 1
          continue
        }
        scalars.removeAll(keepingCapacity: true)
        state.appendScalars(of: cell, to: &scalars)
        let text = Self.text(scalars)
        let hasTail =
          x + 1 < columns && source[x + 1].flags.contains(.spacerTail)
        if cell.width == 2, hasTail {
          row.append(ScreenCell(text, width: 2, style: style))
          row.append(ScreenCell("", width: 0, style: style))
          x += 2
        } else {
          row.append(ScreenCell(text, width: 1, style: style))
          x += 1
        }
      }
      cells.append(row)
      wrapped.append(isWrapped)
    }

    var exportedStyles = styles.styles
    if exportedStyles.count > RSTLimits.maxStyles {
      // There are at most maxStyles cells. A table with one extra style
      // therefore has a distinct nonplain style for every cell: the reserved
      // plain entry is unused. Remove it without dropping any cell's style.
      exportedStyles.removeFirst()
      for y in cells.indices {
        for x in cells[y].indices { cells[y][x].style -= 1 }
      }
    }

    let cursor = state.cursor
    let shape: CursorShape =
      switch state.cursorStyle {
      case .block: .block
      case .underline: .underline
      case .bar: .bar
      }
    return ScreenSnapshot(
      sessionID: stamp.sessionID,
      attachmentEpoch: stamp.attachmentEpoch,
      screenRevision: stamp.screenRevision,
      resizeRevision: stamp.resizeRevision,
      columns: columns,
      rows: rows,
      activeBuffer: state.isAlternateScreen ? .alternate : .primary,
      cursor: ScreenCursor(
        row: min(max(cursor.y, 0), rows - 1),
        column: min(max(cursor.x, 0), columns),
        // The cursor is on the live screen, not in a history window.
        visible: state.modes.contains(.cursorVisible) && !inHistory,
        shape: shape,
        blinking: state.modes.contains(.cursorBlink)
      ),
      reverseVideo: state.modes.contains(.reverseVideo),
      title: boundedTitle(state.title),
      wrapped: wrapped,
      styles: exportedStyles,
      cells: cells,
      lastFullyAppliedInputSequence: stamp.lastFullyAppliedInputSequence
    )
  }

  /// The shared frame model of the same window (`paneFrames`,
  /// spec.roaming.md §6): palette-tagged colors, row versions from
  /// `versions`, clipped to the RST/1 grid, with the RST/1 profile's
  /// title bound and without search, drop targets or mouse modes. Nil only
  /// when the frame exceeds an export budget.
  package static func frame(
    _ state: borrowing TerminalState,
    stamp: Stamp,
    historyTop: Int? = nil,
    versions: RowVersionBox
  ) -> (PaneFrame, RSTFrameHeader)? {
    let owned = state.captureOwnedWindow(top: historyTop)
      .cropped(
        columns: min(max(state.columns, 1), RSTLimits.maxColumns),
        rows: min(max(state.rows, 1), RSTLimits.maxRows)
      )
    let header = RSTFrameHeader(
      sessionID: stamp.sessionID,
      attachmentEpoch: stamp.attachmentEpoch,
      screenRevision: stamp.screenRevision,
      resizeRevision: stamp.resizeRevision,
      lastFullyAppliedInputSequence: stamp.lastFullyAppliedInputSequence
    )
    guard
      var frame = try? FrameExporter.frame(
        from: owned,
        identity: header.frameIdentity,
        limits: SnapshotFrame.frameLimits,
        overlongGrapheme: RSTLimits.graphemePlaceholder.unicodeScalars.first!
          .value
      )
    else { return nil }
    frame.title = boundedTitle(frame.title)
    frame.search = nil
    frame.dropTarget = nil
    frame.modes.subtract([
      .mouseTracking, .mouseButtonMotion, .mouseAnyMotion, .kittyPasteEvents,
    ])
    frame.rowVersions = versions.stamp(owned)
    return (frame, header)
  }

  static func text(_ scalars: [UInt32]) -> String {
    RSTPresentation.text(scalars)
  }

  static func boundedTitle(_ title: String) -> String {
    RSTPresentation.boundedTitle(title)
  }
}

/// Deduplicating style table; index 0 is always the plain style.
struct StyleTable {
  private(set) var styles: [CellStyle] = [.plain]
  private var indices: [CellStyle: Int] = [.plain: 0]
  private var cache: [CellAttributes: Int] = [:]
  let palette: Palette

  init(palette: Palette) { self.palette = palette }

  mutating func index(
    for attributes: CellAttributes,
    in state: borrowing TerminalState
  ) -> Int {
    if let cached = cache[attributes] { return cached }
    let style = Self.style(attributes, palette: palette, state: state)
    let index: Int
    if let existing = indices[style] {
      index = existing
    } else {
      index = styles.count
      styles.append(style)
      indices[style] = index
    }
    cache[attributes] = index
    return index
  }

  static func style(
    _ attributes: CellAttributes,
    palette: Palette,
    state: borrowing TerminalState
  ) -> CellStyle {
    let underline = state.underlineColor(attributes.underlineColor)
      .flatMap { resolve($0, palette) }
    return CellStyle(
      foreground: resolve(attributes.foreground, palette),
      background: resolve(attributes.background, palette),
      underlineColor: underline,
      attributes: textAttributes(attributes.flags)
    )
  }

  /// Palette and direct colors resolve to RGB; the default color is nil
  /// so the client applies its own default.
  static func resolve(_ color: TerminalColor, _ palette: Palette) -> RGBColor? {
    switch color.kind {
    case .default: nil
    case let .palette(index): RGBColor(palette.colors[Int(index)])
    case let .rgb(value): RGBColor(value)
    }
  }

  static func textAttributes(_ flags: CellFlags) -> TextAttributes {
    RSTPresentation.attributes(flags)
  }

}
#endif
