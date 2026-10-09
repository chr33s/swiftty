/// Viewport scrolling and text extraction for the visible screen and history.
public extension TerminalState {
    // MARK: Viewport

    /// Scrolls the viewport by `delta` lines (positive = towards history).
    mutating func scrollViewport(by delta: Int) {
        guard !isAlternateScreen else { return }
        let boundedDelta = min(max(delta, -viewportOffset), grid.historyCount - viewportOffset)
        let target = viewportOffset + boundedDelta
        if target != viewportOffset {
            viewportOffset = target
            damage.setFull()
        }
    }

    mutating func scrollViewportToBottom() {
        scrollViewport(by: -viewportOffset)
    }

    /// Lines of primary-screen history.
    var scrollbackCount: Int {
        isAlternateScreen ? inactiveGrid.historyCount : grid.historyCount
    }

    /// History line `index` (0 = oldest) of the primary screen.
    func scrollbackLine(_ index: Int) -> (cells: UnsafeBufferPointer<Cell>, wrapped: Bool) {
        isAlternateScreen ? inactiveGrid.historyLine(index) : grid.historyLine(index)
    }

    /// Cells shown at visible row `y`, which may come from scrollback.
    func viewportRow(_ y: Int) -> (cells: UnsafeBufferPointer<Cell>, wrapped: Bool) {
        if viewportOffset == 0 {
            return (grid.cells(row: y), grid.isWrapped(y))
        }
        // A non-zero offset implies the primary screen is active.
        let history = grid.historyCount
        let v = history - viewportOffset + y
        if v < history {
            return grid.historyLine(v)
        }
        return (grid.cells(row: v - history), grid.isWrapped(v - history))
    }

    /// Scalars making up `cell`'s content (empty for a blank cell).
    func scalars(of cell: Cell) -> [Unicode.Scalar] {
        if cell.isGrapheme {
            let points = graphemes.scalars(cell.glyph)
            var result: [Unicode.Scalar] = []
            result.reserveCapacity(points.count)
            for point in points {
                if let scalar = Unicode.Scalar(point) {
                    result.append(scalar)
                }
            }
            return result
        }
        if cell.glyph == 0 || cell.isSpacer {
            return []
        }
        return Unicode.Scalar(cell.glyph).map { [$0] } ?? []
    }

    @_lifetime(borrow self)
    internal func graphemeScalars(_ id: UInt32) -> Span<UInt32> {
        graphemes.scalars(id)
    }

    /// Appends rendered cell text without allocating a temporary scalar array.
    /// Blank cells and clusters containing no valid scalars become one space.
    internal func appendText(of cell: Cell, to text: inout String.UnicodeScalarView) {
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
            if !appended {
                text.append(" ")
            }
        } else {
            text.append(cell.glyph == 0 ? " " : Unicode.Scalar(cell.glyph) ?? " ")
        }
    }

    /// Text of active-screen row `y` with trailing blanks trimmed.
    func text(row y: Int) -> String {
        Self.text(of: grid.cells(row: y), self)
    }

    /// The visible screen as text lines (trailing blanks trimmed).
    var screenLines: [String] {
        (0 ..< rows).map { Self.text(of: viewportRow($0).cells, self) }
    }

    func scrollbackText(_ index: Int) -> String {
        Self.text(of: scrollbackLine(index).cells, self)
    }

    private static func text(of cells: UnsafeBufferPointer<Cell>, _ state: borrowing TerminalState) -> String {
        var s = String.UnicodeScalarView()
        for cell in cells where !cell.isSpacer {
            state.appendText(of: cell, to: &s)
        }
        var str = String(s)
        while str.last == " " {
            str.removeLast()
        }
        return str
    }
}
