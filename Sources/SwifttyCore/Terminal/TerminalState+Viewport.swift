/// Viewport scrolling and text extraction for the visible screen and history.
extension TerminalState {
  // MARK: Viewport

  /// Scrolls the viewport by `delta` lines (positive = towards history).
  public mutating func scrollViewport(by delta: Int) {
    guard !isAlternateScreen else { return }
    let boundedDelta = min(
      max(delta, -viewportOffset),
      grid.historyCount - viewportOffset
    )
    let target = viewportOffset + boundedDelta
    if target != viewportOffset {
      viewportOffset = target
      damage.setFull()
    }
  }

  public mutating func scrollViewportToBottom() {
    scrollViewport(by: -viewportOffset)
  }

  /// Lines of primary-screen history.
  public var scrollbackCount: Int {
    isAlternateScreen ? inactiveGrid.historyCount : grid.historyCount
  }

  /// History line `index` (0 = oldest) of the primary screen.
  internal func scrollbackLine(
    _ index: Int
  ) -> (cells: UnsafeBufferPointer<Cell>, wrapped: Bool) {
    isAlternateScreen
      ? inactiveGrid.historyLine(index) : grid.historyLine(index)
  }

  /// Cells shown at visible row `y`, which may come from scrollback.
  internal func viewportRow(
    _ y: Int
  ) -> (cells: UnsafeBufferPointer<Cell>, wrapped: Bool) {
    if viewportOffset == 0 {
      return (grid._unsafeCells(row: y), grid.isWrapped(y))
    }
    // A non-zero offset implies the primary screen is active.
    let history = grid.historyCount
    let v = history - viewportOffset + y
    if v < history { return grid.historyLine(v) }
    return (grid._unsafeCells(row: v - history), grid.isWrapped(v - history))
  }

  /// Borrowed visible row cells, including the scrolled viewport.
  /// O(1), with no allocation; mutation requires ending the borrow.
  @_lifetime(borrow self)
  public func viewportCells(row y: Int) -> Span<Cell> {
    precondition(y >= 0 && y < rows)
    let buffer = viewportRow(y).cells
    let span = Span(_unsafeStart: buffer.baseAddress!, count: buffer.count)
    return _overrideLifetime(span, borrowing: self)
  }

  /// Borrowed primary history cells, oldest first. O(1), no allocation.
  @_lifetime(borrow self)
  public func scrollbackCells(at index: Int) -> Span<Cell> {
    let buffer = scrollbackLine(index).cells
    let span = Span(_unsafeStart: buffer.baseAddress!, count: buffer.count)
    return _overrideLifetime(span, borrowing: self)
  }

  /// Scalars making up `cell`'s content (empty for a blank cell).
  public func scalars(of cell: Cell) -> [Unicode.Scalar] {
    if cell.isGrapheme {
      let points = graphemes.scalars(cell.glyph)
      var result: [Unicode.Scalar] = []
      result.reserveCapacity(points.count)
      for point in points {
        if let scalar = Unicode.Scalar(point) { result.append(scalar) }
      }
      return result
    }
    if cell.glyph == 0 || cell.isSpacer { return [] }
    return Unicode.Scalar(cell.glyph).map { [$0] } ?? []
  }

  @_lifetime(borrow self)
  internal func graphemeScalars(_ id: UInt32) -> Span<UInt32> {
    graphemes.scalars(id)
  }

  /// Appends rendered cell text without allocating a temporary scalar array.
  /// Blank cells and clusters containing no valid scalars become one space.
  internal func appendText(
    of cell: Cell,
    to text: inout String.UnicodeScalarView
  ) {
    guard !cell.isSpacer else { return }
    if cell.isGrapheme {
      var appended = false
      let scalars = graphemeScalars(cell.glyph)
      for point in scalars {
        if let scalar = Unicode.Scalar(point) {
          text.append(scalar)
          appended = true
        }
      }
      if !appended { text.append(" ") }
    } else {
      text.append(cell.glyph == 0 ? " " : Unicode.Scalar(cell.glyph) ?? " ")
    }
  }

  /// Text of active-screen row `y` with trailing blanks trimmed.
  public func text(row y: Int) -> String {
    Self.text(of: grid._unsafeCells(row: y), self)
  }

  /// The visible screen as text lines (trailing blanks trimmed).
  public var screenLines: [String] {
    (0 ..< rows).map { Self.text(of: viewportRow($0).cells, self) }
  }

  public func scrollbackText(_ index: Int) -> String {
    Self.text(of: scrollbackLine(index).cells, self)
  }

  private static func text(
    of cells: UnsafeBufferPointer<Cell>,
    _ state: borrowing TerminalState
  ) -> String {
    var s = String.UnicodeScalarView()
    for cell in cells where !cell.isSpacer {
      state.appendText(of: cell, to: &s)
    }
    var str = String(s)
    while str.last == " " { str.removeLast() }
    return str
  }
}
