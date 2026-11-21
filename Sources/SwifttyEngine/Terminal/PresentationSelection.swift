/// A selection in a remote host's addresses (spec.roaming.md §7.5;
/// spec.multiplexer.md §4, "Live selection across pages"), which outlives
/// the frames it was drawn on. Frames describe their rows with keys
/// `[generation, alternate, row, version, screen]`; this type carries a
/// selection from one frame to the next and places it on each, for
/// presentation sessions and native mux panes alike.
public struct PresentationSelection: Sendable, Equatable {
  public enum Unit: Sendable, Equatable { case character, word, line }

  /// Where a selection lies on a frame, in its viewport cells.
  public enum Placement: Equatable, Sendable {
    /// Another generation or screen, or a selected row edited in place.
    case ended
    /// Wholly above or below the frame; it is kept for copying.
    case hidden
    /// Ends clamped to the frame: an end above starts at its first cell,
    /// one below ends at its last.
    case shown(anchor: Cell, head: Cell)
  }

  public struct Cell: Equatable, Sendable {
    public var row: Int
    public var column: Int
    public init(row: Int, column: Int) {
      self.row = row
      self.column = column
    }
  }

  public var generation: UInt64
  public var alternateScreen: Bool
  /// Host absolute rows and columns.
  public var anchor: (row: Int, column: Int)
  public var head: (row: Int, column: Int)
  public var rectangle: Bool
  public var unit: Unit
  /// Versions of selected rows when first seen, and whether each was a
  /// screen row (only those can change in place).
  public var seen: [Int: (version: UInt64, screen: Bool)] = [:]

  public init(
    generation: UInt64,
    alternateScreen: Bool,
    anchor: (row: Int, column: Int),
    head: (row: Int, column: Int),
    rectangle: Bool,
    unit: Unit = .character
  ) {
    self.generation = generation
    self.alternateScreen = alternateScreen
    self.anchor = anchor
    self.head = head
    self.rectangle = rectangle
    self.unit = unit
  }

  public static func == (a: Self, b: Self) -> Bool {
    a.generation == b.generation && a.alternateScreen == b.alternateScreen
      && a.anchor == b.anchor && a.head == b.head && a.rectangle == b.rectangle
      && a.unit == b.unit
  }

  /// Host rows the selection covers.
  public var rows: ClosedRange<Int> {
    min(anchor.row, head.row) ... max(anchor.row, head.row)
  }

  /// The host addresses of a selection shown at viewport cells of a frame
  /// with `keys`. An end the user did not move (equal to where `previous`
  /// was `placed`) keeps `previous`'s address, which may lie beyond the
  /// frame. Nil when a moved end is outside the frame.
  public static func carrying(
    anchor: (row: Int, column: Int),
    head: (row: Int, column: Int),
    placed: ((row: Int, column: Int), (row: Int, column: Int))?,
    previous: PresentationSelection?,
    keys: [[UInt64]],
    rectangle: Bool,
    unit: Unit = .character
  ) -> PresentationSelection? {
    guard !keys.isEmpty else { return nil }
    func host(_ cell: (row: Int, column: Int)) -> (row: Int, column: Int)? {
      guard cell.row >= 0, cell.row < keys.count else { return nil }
      return (Int(Int64(bitPattern: keys[cell.row][2])), cell.column)
    }
    let kept = previous.flatMap {
      $0.generation == keys[0][0] && $0.alternateScreen == (keys[0][1] != 0)
        ? $0 : nil
    }
    let hostAnchor =
      kept != nil && placed.map { $0.0 == anchor } == true
      ? kept!.anchor : host(anchor)
    let hostHead =
      kept != nil && placed.map { $0.1 == head } == true
      ? kept!.head : host(head)
    guard let hostAnchor, let hostHead else { return nil }
    var carried = PresentationSelection(
      generation: keys[0][0],
      alternateScreen: keys[0][1] != 0,
      anchor: hostAnchor,
      head: hostHead,
      rectangle: rectangle,
      unit: unit
    )
    if let kept {
      carried.seen = kept.seen.filter { carried.rows.contains($0.key) }
    }
    carried.record(keys)
    return carried
  }

  /// Records versions of the frame's selected rows and places the
  /// selection on it.
  public mutating func place(in keys: [[UInt64]], columns: Int) -> Placement {
    guard !keys.isEmpty, keys[0][0] == generation,
      (keys[0][1] != 0) == alternateScreen, record(keys)
    else { return .ended }
    let top = Int(Int64(bitPattern: keys[0][2]))
    let count = keys.count
    let anchorFirst = (anchor.row, anchor.column) <= (head.row, head.column)
    let start = anchorFirst ? anchor : head
    let end = anchorFirst ? head : anchor
    guard start.row - top < count, end.row - top >= 0 else { return .hidden }
    // A clamped end moves to the frame's edge row. A linear selection then
    // spans that row from its start or to its end; a rectangle keeps its
    // columns.
    let lastColumn = max(columns - 1, 0)
    let first =
      start.row < top
      ? Cell(row: 0, column: rectangle ? min(start.column, lastColumn) : 0)
      : Cell(row: start.row - top, column: start.column)
    let last =
      end.row - top >= count
      ? Cell(
        row: count - 1,
        column: rectangle ? min(end.column, lastColumn) : lastColumn
      )
      : Cell(row: end.row - top, column: end.column)
    return .shown(
      anchor: anchorFirst ? first : last,
      head: anchorFirst ? last : first
    )
  }

  /// Both ends lie on the frame with `keys`.
  public func isShown(in keys: [[UInt64]]) -> Bool {
    guard let first = keys.first, let last = keys.last else { return false }
    let shown =
      Int(Int64(bitPattern: first[2])) ... Int(Int64(bitPattern: last[2]))
    return shown.contains(anchor.row) && shown.contains(head.row)
  }

  /// Screen rows the selection covers with the versions first seen: what
  /// a copy request lists.
  public var screenRowVersions: [(row: Int, version: UInt64)] {
    seen.filter { $0.value.screen && rows.contains($0.key) }
      .sorted { $0.key < $1.key }.map { ($0.key, $0.value.version) }
  }

  /// Records versions of selected rows in `keys` not seen before; false
  /// when a row seen before has another version now.
  @discardableResult
  mutating func record(_ keys: [[UInt64]]) -> Bool {
    let covered = rows
    for key in keys {
      let row = Int(Int64(bitPattern: key[2]))
      guard covered.contains(row) else { continue }
      if let known = seen[row] {
        guard known.version == key[3] else { return false }
      } else {
        seen[row] = (key[3], key.count > 4 ? key[4] != 0 : true)
      }
    }
    return true
  }
}
