/// Per-row metadata in a snapshot.
public struct RowSnapshot: Sendable, BitwiseCopyable {
  /// Row changed since the previous snapshot.
  public var isDirty: Bool
  public var isWrapped: Bool
}

public struct CursorState: Sendable, Equatable {
  public var x: Int
  public var y: Int
  public var isVisible: Bool
  public var style: CursorStyle
  public var isBlinking: Bool
}

/// A highlighted span in snapshot rows (inclusive; rows may lie outside
/// the snapshot when the span is partly scrolled out).
public struct HighlightSpan: Sendable, Equatable {
  public var startRow: Int
  public var startColumn: Int
  public var endRow: Int
  public var endColumn: Int
  public var rectangle: Bool

  public init(
    startRow: Int,
    startColumn: Int,
    endRow: Int,
    endColumn: Int,
    rectangle: Bool = false
  ) {
    self.startRow = startRow
    self.startColumn = startColumn
    self.endRow = endRow
    self.endColumn = endColumn
    self.rectangle = rectangle
  }

  public func contains(row: Int, column: Int) -> Bool {
    guard row >= startRow, row <= endRow else { return false }
    if rectangle {
      return column >= min(startColumn, endColumn)
        && column <= max(startColumn, endColumn)
    }
    if row == startRow, column < startColumn { return false }
    if row == endRow, column > endColumn { return false }
    return true
  }
}

/// Stable identity of the builder that produced a snapshot.
final class SnapshotSource: Sendable {}

/// Immutable view of the screen for the renderer.
///
/// Backed by pooled storage that is refilled only for damaged rows, so
/// producing a snapshot does not copy the whole grid every frame. Storage is
/// never mutated while any snapshot referencing it is alive.
public struct RenderSnapshot: @unchecked Sendable {
  let storage: SnapshotStorage
  let source: SnapshotSource
  // Base pointers into `storage`, valid while `storage` is retained. Kept
  // here (rather than read through the class) so span accessors do not
  // borrow the class reference; Swift 6.4's optimizer miscompiles that.
  private let rowBase: UnsafeMutablePointer<RowSnapshot>
  private let cellBase: UnsafeMutablePointer<Cell>
  private let graphemeScalarBase: UnsafeMutablePointer<UInt32>
  private let graphemeEntryCount: Int
  private let graphemeScalarCount: Int
  private let graphemeEntryBase: UnsafeMutablePointer<UInt64>
  public let columns: Int
  /// Visible rows plus `overscanRows` rows below them.
  public let rowCount: Int
  /// Rows after the screen's last row, drawn when the viewport is offset by
  /// a fraction of a row (smooth scrolling) or into a bottom inset.
  public let overscanRows: Int
  public let cursor: CursorState
  public let selection: HighlightSpan?
  /// Visible search matches, ordered by both start and end position.
  public let searchMatches: [HighlightSpan]
  /// Index into `searchMatches` of the selected match, if visible.
  public let selectedSearchMatch: Int?
  /// Total matches and selected index across the screen and scrollback.
  public let searchMatchCount: Int
  public let searchSelectedIndex: Int?
  /// Rows that changed since the previous snapshot returned by the session.
  public internal(set) var damage: DamageRegion
  public let palette: Palette
  /// Colors for `CellAttributes.underlineColor` ids (id 1 is index 0).
  public let underlineColors: [TerminalColor]
  public let modes: Modes
  public let viewportOffset: Int
  public let scrollbackCount: Int
  /// Monotonic counter within one session; equal sequences from that
  /// session mean identical content.
  public let sequence: UInt64

  init(
    storage: SnapshotStorage,
    source: SnapshotSource,
    columns: Int,
    rowCount: Int,
    overscanRows: Int,
    cursor: CursorState,
    selection: HighlightSpan?,
    searchMatches: [HighlightSpan],
    selectedSearchMatch: Int?,
    searchMatchCount: Int,
    searchSelectedIndex: Int?,
    damage: DamageRegion,
    palette: Palette,
    underlineColors: [TerminalColor] = [],
    modes: Modes,
    viewportOffset: Int,
    scrollbackCount: Int,
    sequence: UInt64,
  ) {
    self.storage = storage
    self.source = source
    rowBase = storage.rowRecords
    cellBase = storage.cells
    graphemeScalarBase = storage.graphemeScalars
    graphemeEntryBase = storage.graphemeEntries
    graphemeEntryCount = storage.entryCount
    graphemeScalarCount = storage.scalarCount
    self.columns = columns
    self.rowCount = rowCount
    self.overscanRows = overscanRows
    self.cursor = cursor
    self.selection = selection
    self.searchMatches = searchMatches
    self.selectedSearchMatch = selectedSearchMatch
    self.searchMatchCount = searchMatchCount
    self.searchSelectedIndex = searchSelectedIndex
    self.damage = damage
    self.palette = palette
    self.underlineColors = underlineColors
    self.modes = modes
    self.viewportOffset = viewportOffset
    self.scrollbackCount = scrollbackCount
    self.sequence = sequence
  }

  /// Borrowed row metadata. O(1), with no allocation.
  public var rows: Span<RowSnapshot> {
    @_lifetime(borrow self)
    get {
      let span = Span(_unsafeStart: rowBase, count: rowCount)
      return _overrideLifetime(span, borrowing: self)
    }
  }

  /// Borrowed row cells. O(1), with no allocation.
  @_lifetime(borrow self)
  public func cells(row y: Int) -> Span<Cell> {
    precondition(y >= 0 && y < rowCount)
    let span = Span(_unsafeStart: cellBase + y * columns, count: columns)
    return _overrideLifetime(span, borrowing: self)
  }

  /// Borrowed scalars of a grapheme cell obtained from this snapshot.
  /// Ids are snapshot-local; a cell from another snapshot is invalid input.
  /// - Complexity: O(1), with no allocation.
  @_lifetime(borrow self)
  public func graphemeScalars(_ cell: Cell) -> Span<UInt32> {
    precondition(
      cell.isGrapheme && Int(cell.glyph) < graphemeEntryCount,
      "invalid snapshot grapheme id"
    )
    let entry = graphemeEntryBase[Int(cell.glyph)]
    let start = Int(entry >> 32)
    let count = Int(entry & 0xFFFF_FFFF)
    precondition(
      start <= graphemeScalarCount && count <= graphemeScalarCount - start
    )
    let span = Span(_unsafeStart: graphemeScalarBase + start, count: count)
    return _overrideLifetime(span, borrowing: self)
  }

  /// Plain-text dump of the snapshot (tests and accessibility).
  public var text: [String] {
    var lines: [String] = []
    for y in 0 ..< rowCount {
      var s = String.UnicodeScalarView()
      let row = cells(row: y)
      for x in 0 ..< row.count {
        let cell = row[x]
        if cell.isSpacer { continue }
        if cell.isGrapheme {
          let scalars = graphemeScalars(cell)
          for i in 0 ..< scalars.count {
            s.append(Unicode.Scalar(scalars[i]) ?? "\u{FFFD}")
          }
        } else {
          s.append(
            cell.glyph == 0 ? " " : Unicode.Scalar(cell.glyph) ?? "\u{FFFD}"
          )
        }
      }
      var line = String(s)
      while line.last == " " { line.removeLast() }
      lines.append(line)
    }
    return lines
  }
}
