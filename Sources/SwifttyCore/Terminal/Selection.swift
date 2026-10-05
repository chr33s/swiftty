/// A cell position addressed independently of scrolling.
///
/// `row` is an absolute line number: on the primary screen line 0 is the
/// first line ever written to history, so a point keeps naming the same line
/// as output scrolls (`TerminalState.absoluteRow(viewportRow:)`). On the
/// alternate screen rows are screen rows.
public struct TerminalPoint: Hashable, Sendable, Comparable {
    public var row: Int
    public var column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    public static func < (lhs: TerminalPoint, rhs: TerminalPoint) -> Bool {
        lhs.row != rhs.row ? lhs.row < rhs.row : lhs.column < rhs.column
    }
}

/// A selected span: from `anchor` (where it began) to `head` (where it is
/// being extended to), inclusive. `rectangle` selects a column block.
public struct Selection: Equatable, Sendable {
    public var anchor: TerminalPoint
    public var head: TerminalPoint
    public var rectangle: Bool

    public init(anchor: TerminalPoint, head: TerminalPoint, rectangle: Bool = false) {
        self.anchor = anchor
        self.head = head
        self.rectangle = rectangle
    }

    public var start: TerminalPoint {
        rectangle ? TerminalPoint(row: min(anchor.row, head.row), column: min(anchor.column, head.column)) : min(anchor, head)
    }

    public var end: TerminalPoint {
        rectangle ? TerminalPoint(row: max(anchor.row, head.row), column: max(anchor.column, head.column)) : max(anchor, head)
    }

    public func contains(_ p: TerminalPoint) -> Bool {
        let s = start, e = end
        if rectangle {
            return p.row >= s.row && p.row <= e.row && p.column >= s.column && p.column <= e.column
        }
        return p >= s && p <= e
    }
}

/// An inclusive span of cells, used for search matches.
public struct TerminalRange: Hashable, Sendable {
    public var start: TerminalPoint
    public var end: TerminalPoint

    public init(start: TerminalPoint, end: TerminalPoint) {
        self.start = start
        self.end = end
    }
}

public extension TerminalState {
    // MARK: Addressing

    /// Absolute row of the first line still available.
    var firstAbsoluteRow: Int {
        isAlternateScreen ? 0 : grid.historyEvicted
    }

    /// Lines available for addressing: history plus the screen.
    var addressableRows: Int {
        (isAlternateScreen ? 0 : grid.historyCount) + rows
    }

    /// Absolute row shown at visible row `y`.
    func absoluteRow(viewportRow y: Int) -> Int {
        isAlternateScreen ? y : grid.historyEvicted + grid.historyCount - viewportOffset + y
    }

    /// Visible row showing absolute row `row` (may be outside `0..<rows`).
    func viewportRow(absoluteRow row: Int) -> Int {
        isAlternateScreen ? row : row - (grid.historyEvicted + grid.historyCount - viewportOffset)
    }

    /// Cells of absolute row `row`, or nil once it has left history.
    func line(absoluteRow row: Int) -> (cells: UnsafeBufferPointer<Cell>, wrapped: Bool)? {
        let index = row - firstAbsoluteRow
        guard index >= 0, index < addressableRows else { return nil }
        let history = isAlternateScreen ? 0 : grid.historyCount
        if index < history {
            return grid.historyLine(index)
        }
        return (grid.cells(row: index - history), grid.isWrapped(index - history))
    }

    /// Point clamped to the addressable area.
    func clamp(_ p: TerminalPoint) -> TerminalPoint {
        TerminalPoint(
            row: min(max(p.row, firstAbsoluteRow), firstAbsoluteRow + addressableRows - 1),
            column: min(max(p.column, 0), columns - 1),
        )
    }

    // MARK: Text

    /// Text between two points (inclusive). Soft-wrapped lines join without
    /// a newline; trailing blanks of each hard line are trimmed.
    func text(from a: TerminalPoint, to b: TerminalPoint, rectangle: Bool = false) -> String {
        let start = clamp(min(a, b)), end = clamp(max(a, b))
        let left = min(a.column, b.column), right = max(a.column, b.column)
        var out = String.UnicodeScalarView()
        var pendingNewline = false
        for row in start.row ... end.row {
            guard let (cells, wrapped) = line(absoluteRow: row) else { continue }
            let lo = rectangle ? left : row == start.row ? start.column : 0
            let hi = rectangle ? right : row == end.row ? end.column : columns - 1
            var lineScalars = String.UnicodeScalarView()
            if lo <= hi {
                for x in lo ... min(hi, cells.count - 1) where !cells[x].isSpacer {
                    let scalars = self.scalars(of: cells[x])
                    if scalars.isEmpty {
                        lineScalars.append(" ")
                    } else {
                        lineScalars.append(contentsOf: scalars)
                    }
                }
            }
            let joinsNext = !rectangle && wrapped && row != end.row
            if !joinsNext {
                while lineScalars.last == " " {
                    lineScalars.removeLast()
                }
            }
            if pendingNewline {
                out.append("\n")
            }
            out.append(contentsOf: lineScalars)
            pendingNewline = !joinsNext
        }
        return String(out)
    }

    var selectionText: String? {
        guard let selection else { return nil }
        return text(from: selection.start, to: selection.end, rectangle: selection.rectangle)
    }

    // MARK: Selection

    mutating func setSelection(_ newValue: Selection?) {
        let clamped = newValue.map { s in
            Selection(anchor: clamp(s.anchor), head: clamp(s.head), rectangle: s.rectangle)
        }
        guard clamped != selection else { return }
        selection = clamped
        damage.setFull()
    }

    /// Selects everything addressable: history and the screen.
    mutating func selectAll() {
        setSelection(Selection(
            anchor: TerminalPoint(row: firstAbsoluteRow, column: 0),
            head: TerminalPoint(row: firstAbsoluteRow + addressableRows - 1, column: columns - 1),
        ))
    }

    /// Selection was made on content that is gone (screen switch, resize,
    /// clear): drop it.
    internal mutating func invalidateSelection() {
        if selection != nil {
            selection = nil
            damage.setFull()
        }
        if !searchMatches.isEmpty {
            searchMatches = []
            searchSelected = nil
        }
    }

    /// Word around `p`: a run of cells of the same class (word characters,
    /// blanks, or other punctuation) following soft wraps.
    func wordRange(at p: TerminalPoint) -> (start: TerminalPoint, end: TerminalPoint) {
        let p = clamp(p)
        func cls(_ q: TerminalPoint) -> Int? {
            guard let (cells, _) = line(absoluteRow: q.row) else { return nil }
            var cell = cells[q.column]
            if cell.width == 0, q.column > 0 {
                cell = cells[q.column - 1]
            }
            let scalars = scalars(of: cell)
            guard let s = scalars.first, s != " " else { return 0 }
            return Self.isWordScalar(s) ? 1 : 2
        }
        guard let target = cls(p) else { return (p, p) }
        var start = p
        while let prev = step(start, by: -1), cls(prev) == target {
            start = prev
        }
        var end = p
        while let next = step(end, by: 1), cls(next) == target {
            end = next
        }
        return (start, end)
    }

    /// Whole logical line (across soft wraps) containing `p`.
    func lineRange(at p: TerminalPoint) -> (start: TerminalPoint, end: TerminalPoint) {
        let p = clamp(p)
        var top = p.row
        while top > firstAbsoluteRow, let (_, wrapped) = line(absoluteRow: top - 1), wrapped {
            top -= 1
        }
        var bottom = p.row
        while let (_, wrapped) = line(absoluteRow: bottom), wrapped, bottom < firstAbsoluteRow + addressableRows - 1 {
            bottom += 1
        }
        return (TerminalPoint(row: top, column: 0), TerminalPoint(row: bottom, column: columns - 1))
    }

    /// Neighbouring cell across soft wraps only.
    private func step(_ p: TerminalPoint, by delta: Int) -> TerminalPoint? {
        if delta < 0 {
            if p.column > 0 {
                return TerminalPoint(row: p.row, column: p.column - 1)
            }
            guard let (_, wrapped) = line(absoluteRow: p.row - 1), wrapped else { return nil }
            return TerminalPoint(row: p.row - 1, column: columns - 1)
        }
        if p.column < columns - 1 {
            return TerminalPoint(row: p.row, column: p.column + 1)
        }
        guard let (_, wrapped) = line(absoluteRow: p.row), wrapped, line(absoluteRow: p.row + 1) != nil else { return nil }
        return TerminalPoint(row: p.row + 1, column: 0)
    }

    internal static func isWordScalar(_ s: Unicode.Scalar) -> Bool {
        if s.properties.isAlphabetic || s.properties.numericType != nil {
            return true
        }
        switch s {
        case "_", "-", ".", "/", "~", ":", "@", "+", "%", "#", "=", "?", "&": return true
        default: return false
        }
    }

    // MARK: Search

    /// Finds every occurrence of `needle` (case-insensitive unless it has
    /// an uppercase letter), oldest first; matches may span soft wraps.
    mutating func search(_ needle: String) {
        searchMatches = []
        searchSelected = nil
        damage.setFull()
        let target = Array(needle.unicodeScalars)
        guard !target.isEmpty else { return }
        let caseSensitive = needle.contains { $0.isUppercase }
        func fold(_ s: Unicode.Scalar) -> Unicode.Scalar {
            caseSensitive ? s : (s.properties.lowercaseMapping.unicodeScalars.first ?? s)
        }
        let folded = target.map(fold)

        // Walk logical lines, collecting one scalar per cell position.
        var scalars: [Unicode.Scalar] = []
        var points: [TerminalPoint] = []
        var row = firstAbsoluteRow
        let last = firstAbsoluteRow + addressableRows
        while row < last {
            scalars.removeAll(keepingCapacity: true)
            points.removeAll(keepingCapacity: true)
            while row < last, let (cells, wrapped) = line(absoluteRow: row) {
                for x in 0 ..< cells.count where !cells[x].isSpacer {
                    let content = self.scalars(of: cells[x])
                    let point = TerminalPoint(row: row, column: x)
                    if content.isEmpty {
                        scalars.append(" "); points.append(point)
                    } else {
                        for s in content {
                            scalars.append(fold(s)); points.append(point)
                        }
                    }
                }
                row += 1
                if !wrapped {
                    break
                }
            }
            guard scalars.count >= folded.count else { continue }
            var i = 0
            while i + folded.count <= scalars.count {
                if scalars[i] == folded[0], Array(scalars[i ..< i + folded.count]) == folded {
                    var end = points[i + folded.count - 1]
                    if let (cells, _) = line(absoluteRow: end.row), cells[end.column].width == 2 {
                        end.column += 1
                    }
                    searchMatches.append(TerminalRange(start: points[i], end: end))
                    i += folded.count
                } else {
                    i += 1
                }
            }
        }
    }

    /// Moves the selected match (wrapping) and scrolls it into view.
    /// `forward` goes towards newer output. Returns the selected index.
    @discardableResult
    mutating func selectSearchMatch(forward: Bool) -> Int? {
        guard !searchMatches.isEmpty else { return nil }
        let n = searchMatches.count
        let next = switch searchSelected {
        case let i?: forward ? (i + 1) % n : (i - 1 + n) % n
        case nil: forward ? 0 : n - 1
        }
        searchSelected = next
        scrollToShow(row: searchMatches[next].start.row)
        damage.setFull()
        return next
    }

    mutating func endSearch() {
        searchMatches = []
        searchSelected = nil
        damage.setFull()
    }

    /// Scrolls the viewport so absolute `row` is visible.
    mutating func scrollToShow(row: Int) {
        guard !isAlternateScreen else { return }
        let y = viewportRow(absoluteRow: row)
        if y < 0 {
            scrollViewport(by: -y)
        } else if y >= rows {
            scrollViewport(by: rows - 1 - y)
        }
    }

    /// Scrolls so that history line `top` (0 = oldest available) is the first
    /// visible row.
    mutating func scrollViewport(toTopRow top: Int) {
        guard !isAlternateScreen else { return }
        let target = grid.historyCount - min(max(top, 0), grid.historyCount)
        scrollViewport(by: target - viewportOffset)
    }
}
