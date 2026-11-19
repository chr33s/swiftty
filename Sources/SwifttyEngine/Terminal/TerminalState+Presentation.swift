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
    if title != frame.title {
      titleBytes = Array(frame.title.utf8)
      titleChanged = true
    }
    damage.setFull()
    presentationKeys = frame.rowKeys.flatMap {
      $0.count == frame.rows && $0.allSatisfy { $0.count >= 4 } ? $0 : nil
    }
    restorePresentationSelection(carried)
    _checkInvariants()
  }

  /// The selection to carry into the next frame: the one last placed if
  /// the user has not changed it (it may reach beyond the shown rows),
  /// otherwise the current selection in host addresses.
  private func presentationSelectionToCarry() -> PresentationSelection? {
    guard let keys = presentationKeys, !keys.isEmpty else { return nil }
    // Unchanged since placed, including a selection wholly off the frame
    // (nothing shown, nothing placed).
    if let previous = presentationSelection, selection == presentedSelection {
      return previous
    }
    guard let selection else { return nil }
    func point(_ p: TerminalPoint) -> (row: Int, column: Int)? {
      let y = viewportRow(absoluteRow: p.row)
      guard y >= 0, y < keys.count else { return nil }
      return (Int(Int64(bitPattern: keys[y][2])), p.column)
    }
    // An end the user did not move keeps its host address, which may lie
    // beyond the shown rows.
    let previous = presentationSelection
    let placed = presentedSelection
    let anchor =
      previous != nil && selection.anchor == placed?.anchor
      ? previous!.anchor : point(selection.anchor)
    let head =
      previous != nil && selection.head == placed?.head
      ? previous!.head : point(selection.head)
    guard let anchor, let head else { return nil }
    var carried = PresentationSelection(
      generation: keys[0][0],
      alternateScreen: keys[0][1] != 0,
      anchor: anchor,
      head: head,
      rectangle: selection.rectangle
    )
    if let previous, previous.generation == carried.generation {
      carried.seen = previous.seen
    }
    carried.record(keys)
    return carried
  }

  /// Places a carried selection on the installed frame, or ends it: another
  /// generation or screen, or a selected row whose version changed.
  private mutating func restorePresentationSelection(
    _ carried: PresentationSelection?
  ) {
    presentationSelection = nil
    presentedSelection = nil
    guard var carried, let keys = presentationKeys, !keys.isEmpty,
      keys[0][0] == carried.generation,
      (keys[0][1] != 0) == carried.alternateScreen, carried.record(keys)
    else { return }
    let top = Int(Int64(bitPattern: keys[0][2]))
    let anchorFirst =
      (carried.anchor.row, carried.anchor.column) <= (
        carried.head.row, carried.head.column
      )
    let start = anchorFirst ? carried.anchor : carried.head
    let end = anchorFirst ? carried.head : carried.anchor
    presentationSelection = carried
    // Wholly off the frame: nothing to show, but the selection survives.
    guard start.row - top < rows, end.row - top >= 0 else { return }
    // Ends beyond the frame clamp to its edges; the carried selection
    // keeps them for copying.
    let startPoint =
      start.row < top
      ? viewportPoint(row: 0, column: 0)
      : viewportPoint(row: start.row - top, column: start.column)
    let endPoint =
      end.row - top >= rows
      ? viewportPoint(row: rows - 1, column: columns - 1)
      : viewportPoint(row: end.row - top, column: end.column)
    setSelection(
      Selection(
        anchor: anchorFirst ? startPoint : endPoint,
        head: anchorFirst ? endPoint : startPoint,
        rectangle: carried.rectangle
      )
    )
    presentedSelection = selection
  }

  /// The selection in host addresses when it reaches beyond the rows of
  /// the shown frame, so only the host can copy all of it; nil otherwise.
  public var presentationSelectionBeyondView: PresentationSelection? {
    guard let carried = presentationSelection, let keys = presentationKeys,
      !keys.isEmpty, selection == presentedSelection
    else { return nil }
    let top = Int(Int64(bitPattern: keys[0][2]))
    let shown = top ..< top + keys.count
    return shown.contains(carried.anchor.row)
      && shown.contains(carried.head.row) ? nil : carried
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

/// A presentation selection in the host's addresses, which outlives the
/// frames it was drawn on (spec.roaming.md §7.5).
public struct PresentationSelection: Sendable, Equatable {
  public var generation: UInt64
  public var alternateScreen: Bool
  /// Host absolute rows and columns.
  public var anchor: (row: Int, column: Int)
  public var head: (row: Int, column: Int)
  public var rectangle: Bool
  /// Versions of selected rows when first seen, and whether each was a
  /// screen row (only those can change in place).
  public var seen: [Int: (version: UInt64, screen: Bool)] = [:]

  public init(
    generation: UInt64,
    alternateScreen: Bool,
    anchor: (row: Int, column: Int),
    head: (row: Int, column: Int),
    rectangle: Bool
  ) {
    self.generation = generation
    self.alternateScreen = alternateScreen
    self.anchor = anchor
    self.head = head
    self.rectangle = rectangle
  }

  public static func == (a: Self, b: Self) -> Bool {
    a.generation == b.generation && a.alternateScreen == b.alternateScreen
      && a.anchor == b.anchor && a.head == b.head && a.rectangle == b.rectangle
  }

  /// Records versions of selected rows in `keys` not seen before; false
  /// when a row seen before has another version now.
  @discardableResult
  mutating func record(_ keys: [[UInt64]]) -> Bool {
    let lo = min(anchor.row, head.row)
    let hi = max(anchor.row, head.row)
    for key in keys {
      let row = Int(Int64(bitPattern: key[2]))
      guard row >= lo, row <= hi else { continue }
      if let known = seen[row] {
        guard known.version == key[3] else { return false }
      } else {
        seen[row] = (key[3], key.count > 4 ? key[4] != 0 : true)
      }
    }
    return true
  }
}

extension Modes {
  fileprivate mutating func update(_ mode: Modes, _ on: Bool) {
    if on { insert(mode) } else { remove(mode) }
  }
}
