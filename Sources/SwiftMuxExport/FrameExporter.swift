import Foundation
import SwiftMuxProtocol
import SwifttyEngine

/// Converts a consistent owned capture into a `PaneFrame`.
public enum FrameExporter {
  /// Shown for a grapheme cluster longer than the frame budget allows.
  package static let replacementCharacter: UInt32 = 0xFFFD

  /// A cluster longer than `limits.maxGraphemeScalars` is shown as
  /// `overlongGrapheme` (U+FFFD by default) rather than failing the frame;
  /// nil fails it instead.
  ///
  /// - Throws: `resourceLimit` when valid state exceeds another export
  ///   budget (or an over-long cluster has no placeholder); cells are
  ///   never silently omitted.
  package static func frame(
    from screen: OwnedScreen,
    identity: FrameIdentity,
    limits: MuxLimits = .standard,
    overlongGrapheme: UInt32? = replacementCharacter
  ) throws(MuxError) -> PaneFrame {
    guard
      let count = limits.cellCount(columns: screen.columns, rows: screen.rows)
    else {
      throw MuxError(
        .resourceLimit,
        "pane \(screen.columns)x\(screen.rows) exceeds frame dimensions"
      )
    }
    var glyphs = [UInt32](repeating: 0, count: count)
    var styleIndex = [UInt16](repeating: 0, count: count)
    var kinds = [UInt8](repeating: CellKind.narrow.rawValue, count: count)
    var styles: [FrameStyle] = [.plain]
    var lookup: [FrameStyle: UInt16] = [.plain: 0]
    var graphemes: [[UInt32]] = []
    // Neighbouring cells usually share a style: skip the table lookup.
    var last: (style: FrameStyle, index: UInt16) = (.plain, 0)
    for i in 0 ..< count {
      let cell = screen.cells[i]
      let a = cell.attributes
      var flags = a.flags
      flags.subtract(.structural)
      let style = FrameStyle(
        foreground: a.foreground.rawValue,
        background: a.background.rawValue,
        flags: flags.rawValue,
        underlineColor: a.underlineColor
      )
      if style == last.style {
        styleIndex[i] = last.index
      } else if let idx = lookup[style] {
        styleIndex[i] = idx
        last = (style, idx)
      } else {
        guard styles.count < limits.maxStyles,
          let index = UInt16(exactly: styles.count)
        else { throw MuxError(.resourceLimit, "frame style table") }
        lookup[style] = index
        styleIndex[i] = index
        styles.append(style)
        last = (style, index)
      }
      if cell.flags.contains(.spacerTail) {
        kinds[i] = CellKind.continuation.rawValue
      } else if cell.flags.contains(.spacerHead) {
        kinds[i] = CellKind.padding.rawValue
      } else {
        if cell.width == 2 { kinds[i] = CellKind.wideLead.rawValue }
        if cell.isGrapheme {
          let scalars = screen.graphemes[Int(cell.glyph)]
          if scalars.count > limits.maxGraphemeScalars {
            // A profile with a placeholder shows it instead of failing.
            guard let overlongGrapheme else {
              throw MuxError(.resourceLimit, "grapheme cluster length")
            }
            glyphs[i] = overlongGrapheme
          } else {
            glyphs[i] = FrameGrid.graphemeFlag | UInt32(graphemes.count)
            graphemes.append(scalars)
          }
        } else {
          glyphs[i] = cell.glyph
        }
      }
    }
    repairCellStructure(
      &kinds,
      &glyphs,
      columns: screen.columns,
      rows: screen.rows
    )
    let p = screen.palette
    var colors: [UInt32] = []
    colors.reserveCapacity(256)
    for i in 0 ..< 256 { colors.append(p.colors[i]) }
    let modes = viewModes(screen)
    let search = searchState(screen)
    var title = screen.title
    if title.utf8.count > 4096 {
      var bytes = 0
      let prefix = title.unicodeScalars.prefix { scalar in
        let count = scalar.utf8.count
        guard bytes + count <= 4096 else { return false }
        bytes += count
        return true
      }
      title = String(String.UnicodeScalarView(prefix))
    }
    return PaneFrame(
      identity: identity,
      grid: FrameGrid(
        columns: screen.columns,
        rows: screen.rows,
        alternateScreen: screen.isAlternateScreen,
        wrapped: Data(screen.wrapped.map { $0 ? 1 : 0 }),
        glyphs: glyphs.withUnsafeBytes { Data($0) },
        styles: styleIndex.withUnsafeBytes { Data($0) },
        kinds: Data(kinds)
      ),
      graphemes: graphemes,
      styles: styles,
      underlineColors: screen.underlineColors.map(\.rawValue),
      palette: FramePalette(
        colors: colors,
        foreground: p.foreground,
        background: p.background,
        cursor: p.cursor,
        cursorText: p.cursorText,
        selectionForeground: p.selectionForeground,
        selectionBackground: p.selectionBackground
      ),
      cursor: FrameCursor(
        x: screen.cursor.x,
        y: screen.cursor.y,
        visible: screen.cursor.isVisible,
        style: screen.cursor.style.rawValue,
        blinking: screen.cursor.isBlinking
      ),
      modes: modes,
      history: HistoryWindow(
        generation: screen.addressingGeneration,
        firstRow: screen.firstAbsoluteRow,
        availableRows: screen.scrollbackCount + screen.rows,
        viewportTop: screen.viewportTopRow,
        viewportOffset: screen.viewportOffset,
        scrollbackRows: screen.scrollbackCount
      ),
      search: search,
      title: title,
      dropTarget: screen.dropTypes.map { types in
        FrameDropTarget(
          types: Array(
            types.filter { $0.utf8.count <= FrameDropTarget.maxTypeBytes }
              .prefix(FrameDropTarget.maxTypes)
          ),
          accepted: screen.dropAccepted.map {
            switch $0 {
            case .none: .none
            case .copy: .copy
            case .move: .move
            }
          }
        )
      }
    )
  }

  static func viewModes(_ screen: OwnedScreen) -> SupportedViewModes {
    var modes: SupportedViewModes = []
    if screen.modes.contains(.cursorKeys) { modes.insert(.cursorKeys) }
    if screen.modes.contains(.bracketedPaste) { modes.insert(.bracketedPaste) }
    if screen.isAlternateScreen { modes.insert(.alternateScreen) }
    if screen.modes.contains(.reverseVideo) { modes.insert(.reverseVideo) }
    if screen.modes.contains(.focusEvents) { modes.insert(.focusEvents) }
    if !screen.modes.isDisjoint(with: .mouseTracking) {
      modes.insert(.mouseTracking)
    }
    if screen.modes.contains(.mouseButton) { modes.insert(.mouseButtonMotion) }
    if screen.modes.contains(.mouseAny) { modes.insert(.mouseAnyMotion) }
    if screen.modes.contains(.alternateScroll) {
      modes.insert(.alternateScroll)
    }
    if screen.modes.contains(.keypadApplication) {
      modes.insert(.keypadApplication)
    }
    if screen.modes.contains(.kittyPasteEvents) {
      modes.insert(.kittyPasteEvents)
    }
    return modes
  }

  static func searchState(_ screen: OwnedScreen) -> FrameSearch? {
    var search: FrameSearch?
    if screen.searchMatchCount > 0 || !screen.searchMatches.isEmpty {
      search = FrameSearch(
        matchCount: screen.searchMatchCount,
        selected: nil,
        visible: screen.searchMatches.compactMap { m in
          let startRow = max(0, m.startRow)
          let endRow = min(screen.rows - 1, m.endRow)
          guard startRow <= endRow else { return nil }
          return FrameSpan(
            startRow: startRow,
            startColumn: m.startRow < 0
              ? 0 : min(m.startColumn, screen.columns - 1),
            endRow: endRow,
            endColumn: m.endRow >= screen.rows
              ? screen.columns - 1 : min(m.endColumn, screen.columns - 1)
          )
        },
        selectedVisible: screen.selectedSearchMatch
      )
      if let s = search, s.visible.count != screen.searchMatches.count {
        search?.selectedVisible = nil
      }
    }
    return search
  }

  /// The engine guarantees lead/continuation pairs; repair defensively
  /// at row edges so the exported frame always validates.
  static func repairCellStructure(
    _ kinds: inout [UInt8],
    _ glyphs: inout [UInt32],
    columns: Int,
    rows: Int
  ) {
    for y in 0 ..< rows {
      for x in 0 ..< columns {
        let i = y * columns + x
        if kinds[i] == CellKind.wideLead.rawValue,
          x == columns - 1 || kinds[i + 1] != CellKind.continuation.rawValue
        {
          kinds[i] = CellKind.narrow.rawValue
        }
        if kinds[i] == CellKind.continuation.rawValue,
          x == 0 || kinds[i - 1] != CellKind.wideLead.rawValue
        {
          kinds[i] = CellKind.narrow.rawValue
          glyphs[i] = 0
        }
        if kinds[i] == CellKind.padding.rawValue, x != columns - 1 {
          kinds[i] = CellKind.narrow.rawValue
          glyphs[i] = 0
        }
      }
    }
  }
}
