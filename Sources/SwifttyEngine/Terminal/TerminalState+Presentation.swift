/// Presentation frames: screens produced by another terminal, installed
/// cell for cell without parsing (spec.roaming.md §A.4.3).
extension TerminalState {
  /// Replaces everything visible with `frame`, which must be valid
  /// (`PresentationFrame.isValid`). Keeps the frame's layout: rows are not
  /// reflowed and widths are not recalculated. Discards history, the
  /// selection, search results, modes and the inactive screen, and
  /// damages the whole screen.
  package mutating func installPresentation(_ frame: PresentationFrame) {
    // A selection made on the previous frame, in the host's addresses,
    // before the reset discards it (live selection, spec.roaming.md §7.5).
    let carried = presentationSelectionToCarry()
    // Reset first: resizing the blank screen then has nothing to reflow.
    fullReset()
    resize(columns: frame.columns, rows: frame.rows)
    endSearch()
    let attributes = frame.styles.map { style in
      var attributes = CellAttributes(
        foreground: Self.presentationColor(style.foreground),
        background: Self.presentationColor(style.background),
        flags: style.flags.subtracting(.structural),
      )
      if let underline = style.underlineColor {
        attributes.underlineColor = internUnderlineColor(
          Self.presentationColor(underline)
        )
      }
      return attributes
    }
    var cluster: [UInt32] = []
    for y in 0 ..< rows {
      let row = grid._unsafeRow(y)
      let base = y * columns
      var extent = 0
      for x in 0 ..< columns {
        let source = frame.cells[base + x]
        var cell: Cell
        if source.width == 0 {
          // A continuation takes its lead's pen, as when printing.
          var tail = row[x - 1].attributes
          tail.flags.subtract(.structural)
          tail.flags.insert(.spacerTail)
          cell = Cell(glyph: 0, attributes: tail, width: 0)
        } else {
          cell = Cell(
            glyph: 0,
            attributes: attributes[source.style],
            width: source.width
          )
          cluster.removeAll(keepingCapacity: true)
          for scalar in source.text.unicodeScalars {
            cluster.append(scalar.value)
          }
          if cluster.count == 1 {
            cell.glyph = cluster[0]
          } else if cluster.count > 1 {
            cell.glyph = graphemes.insert(cluster)
            cell.attributes.flags.insert(.grapheme)
          }
        }
        row[x] = cell
        if !cell.isBlank { extent = x + 1 }
      }
      grid.extend(y, to: extent)
      grid.setWrapped(y, frame.wrapped[y])
    }
    cursor.x = frame.cursorX
    cursor.y = frame.cursorY
    cursor.pendingWrap = false
    cursorStyle = frame.cursorStyle
    modes.update(.cursorVisible, frame.cursorVisible)
    modes.update(.cursorBlink, frame.cursorBlinking)
    modes.update(.reverseVideo, frame.reverseVideo)
    modes.update(.alternateScreen, frame.alternateScreen)
    if frame.mouseTracking != !modes.isDisjoint(with: Modes.mouseTracking) {
      modes.subtract(Modes.mouseTracking)
      if frame.mouseTracking { modes.insert(.mouseNormal) }
    }
    if title != frame.title {
      titleBytes = Array(frame.title.utf8)
      titleChanged = true
    }
    damage.setFull()
    presentationKeys = frame.rowKeys.flatMap {
      // Rows within 2^48 keep selection arithmetic from overflowing.
      $0.count == frame.rows
        && $0.allSatisfy { $0.count >= 4 && $0[2] <= 1 << 48 } ? $0 : nil
    }
    restorePresentationSelection(carried)
    _checkInvariants()
  }

  /// The current selection in host addresses: the one last placed while
  /// the user has not changed it (it may reach beyond the shown rows),
  /// otherwise the shown selection, keeping each end the user did not move.
  private func presentationSelectionToCarry() -> PresentationSelection? {
    guard let keys = presentationKeys, !keys.isEmpty else { return nil }
    if let previous = presentationSelection, selection == presentedSelection {
      return previous
    }
    guard let selection else { return nil }
    func cell(_ p: TerminalPoint) -> (row: Int, column: Int) {
      (viewportRow(absoluteRow: p.row), p.column)
    }
    return PresentationSelection.carrying(
      anchor: cell(selection.anchor),
      head: cell(selection.head),
      placed: presentedSelection.map { (cell($0.anchor), cell($0.head)) },
      previous: presentationSelection,
      keys: keys,
      rectangle: selection.rectangle
    )
  }

  /// Places a carried selection on the installed frame, or ends it: another
  /// generation or screen, or a selected row whose version changed.
  private mutating func restorePresentationSelection(
    _ carried: PresentationSelection?
  ) {
    presentationSelection = nil
    presentedSelection = nil
    guard var carried, let keys = presentationKeys else { return }
    switch carried.place(in: keys, columns: columns) {
    case .ended: return
    case .hidden:
      // Wholly off the frame: nothing to show, but the selection survives.
      presentationSelection = carried
    case let .shown(anchor, head):
      setSelection(
        Selection(
          anchor: viewportPoint(row: anchor.row, column: anchor.column),
          head: viewportPoint(row: head.row, column: head.column),
          rectangle: carried.rectangle
        )
      )
      presentationSelection = carried
      presentedSelection = selection
    }
  }

  /// Extends a live presentation selection to a shown cell, keeping its
  /// anchor's host address even when the anchor has scrolled out of view.
  /// False when there is no live selection to extend.
  public mutating func extendPresentationSelection(
    toViewportRow row: Int,
    column: Int,
    rectangle: Bool
  ) -> Bool {
    guard var carried = presentationSelectionToCarry(),
      let keys = presentationKeys, !keys.isEmpty
    else { return false }
    let y = min(max(row, 0), keys.count - 1)
    carried.head = (
      Int(Int64(bitPattern: keys[y][2])), min(max(column, 0), columns - 1)
    )
    carried.rectangle = rectangle
    restorePresentationSelection(carried)
    return presentationSelection != nil
  }

  /// Whether the selection is a live presentation selection, which
  /// follows the host's rows across frames.
  public var hasLivePresentationSelection: Bool {
    presentationKeys != nil && presentationSelectionToCarry() != nil
  }

  /// The selection in host addresses when it reaches beyond the rows of
  /// the shown frame, so only the host can copy all of it; nil otherwise.
  /// Includes changes the user made since the last frame.
  public var presentationSelectionBeyondView: PresentationSelection? {
    guard let carried = presentationSelectionToCarry(),
      let keys = presentationKeys
    else { return nil }
    return carried.isShown(in: keys) ? nil : carried
  }

  private static func presentationColor(_ rgb: UInt32?) -> TerminalColor {
    guard let rgb else { return .default }
    return .rgb(
      UInt8(truncatingIfNeeded: rgb >> 16),
      UInt8(truncatingIfNeeded: rgb >> 8),
      UInt8(truncatingIfNeeded: rgb)
    )
  }
}

extension Modes {
  fileprivate mutating func update(_ mode: Modes, _ on: Bool) {
    if on { insert(mode) } else { remove(mode) }
  }
}
