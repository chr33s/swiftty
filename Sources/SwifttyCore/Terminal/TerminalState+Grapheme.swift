/// Grapheme clustering while printing (mode 2027), after Ghostty's
/// `Terminal.print`: a scalar that does not start a new cluster joins the
/// cell before the cursor, and may widen or narrow it.
extension TerminalState {
    /// Joins `c` to the previous cell's cluster. Returns false when `c`
    /// starts a new cluster and must be printed normally.
    mutating func printJoining(_ c: UInt32, rightLimit: Int) -> Bool {
        let y = cursor.y
        let row = grid.row(y)
        var left: Int = if modes.contains(.autowrap) {
            cursor.pendingWrap ? 0 : 1
        } else if cursor.x != rightLimit - 1 {
            1
        } else {
            Self.hasText(row[cursor.x]) ? 0 : 1
        }
        // A full one-column row can join its own cell at column zero.
        // An empty first column has no preceding cell to inspect.
        guard cursor.x >= left else { return false }
        if Self.kind(of: row[cursor.x - left]) == .spacerTail {
            left += 1
        }
        guard cursor.x - left >= 0 else { return false }
        var x = cursor.x - left
        let cell = row[x]
        guard Self.hasText(cell) else { return false }

        var state = GraphemeBreak.State()
        var previous: UInt32
        if cell.isGrapheme {
            let scalars = graphemes.scalars(cell.glyph)
            previous = scalars[0]
            let rest = scalars.extracting(droppingFirst: 1)
            for cp in rest {
                _ = GraphemeBreak.isBreak(previous, cp, &state)
                previous = cp
            }
        } else {
            previous = cell.glyph
        }
        if GraphemeBreak.isBreak(previous, c, &state) {
            return false
        }
        if cell.isGrapheme, graphemes.scalarCount(cell.glyph) > Self.graphemeMaxLength {
            // Discard the joined scalar before changing width or moving the
            // cell. A scalar that starts a new cluster still prints normally.
            return true
        }

        var cellY = y
        switch GraphemeBreak.widthEffect(previous: previous, c) {
        case .ignore:
            return true
        case .wide where cell.width != 2:
            cursor.x -= left
            if rightLimit - scrollLeft <= 1 {
                // As with a scalar printed wide initially, a widened cluster
                // cannot fit a one-column region. Do not wrap it into another
                // one-column row or write a tail past the row's storage.
                writeCell(0, .narrow)
                var attributes = cell.attributes
                attributes.flags.subtract(.structural)
                row[x].attributes = attributes
                cursor.pendingWrap = true
                return true
            }
            if cursor.x == rightLimit - 1 {
                guard modes.contains(.autowrap) else { return true }
                // The widened cluster no longer fits: move it to the next line.
                let rowWrap = rightLimit == columns
                if rowWrap {
                    grid.setWrapped(y, true)
                }
                var attributes = cell.attributes
                attributes.flags.subtract(.structural)
                if rowWrap {
                    attributes.flags.insert(.spacerHead)
                }
                writeCell(0, rowWrap ? .spacerHead : .narrow)
                row[x].attributes = attributes
                printWrap()
                // Clear any intersecting wide cell, then transfer the whole
                // base cell without reapplying the current pen or charset.
                writeCell(0, .wide)
                grid.row(cursor.y)[cursor.x] = Cell(glyph: cell.glyph, attributes: cell.attributes, width: 2)
                x = cursor.x
                cellY = cursor.y
            } else {
                row[x].width = 2
            }
            cursor.x += 1
            writeCell(0, .spacerTail)
            var tailAttributes = cell.attributes
            tailAttributes.flags.subtract(.structural)
            tailAttributes.flags.insert(.spacerTail)
            grid.row(cursor.y)[cursor.x].attributes = tailAttributes
            if cursor.x == rightLimit - 1 {
                cursor.pendingWrap = true
            } else {
                cursor.x += 1
            }
        case .narrow where cell.width == 2:
            invalidateSelection(rows: y ..< y + 1, from: x, to: x + 2)
            row[x].width = 1
            if x < columns - 1 {
                row[x + 1] = Self.narrowed(row[x + 1])
            }
            cursor.pendingWrap = false
            cursor.x = min(x + 1, rightLimit - 1)
        default:
            break
        }
        appendGrapheme(c, x: x, y: cellY)
        return true
    }

    @inline(__always)
    static func hasText(_ cell: Cell) -> Bool {
        !cell.isSpacer && (cell.glyph != 0 || cell.isGrapheme)
    }
}
