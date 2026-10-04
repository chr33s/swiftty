/// Grapheme clustering while printing (mode 2027), after Ghostty's
/// `Terminal.print`: a scalar that does not start a new cluster joins the
/// cell before the cursor, and may widen or narrow it.
extension TerminalState {
    /// Joins `c` to the previous cell's cluster. Returns false when `c`
    /// starts a new cluster and must be printed normally.
    mutating func printJoining(_ c: UInt32, rightLimit: Int) -> Bool {
        let y = cursor.y
        let row = grid.row(y)
        var left: Int
        if modes.contains(.autowrap) {
            left = cursor.pendingWrap ? 0 : 1
        } else if cursor.x != rightLimit - 1 {
            left = 1
        } else {
            left = Self.hasText(row[cursor.x]) ? 0 : 1
        }
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
            for cp in scalars.dropFirst() {
                _ = GraphemeBreak.isBreak(previous, cp, &state)
                previous = cp
            }
        } else {
            previous = cell.glyph
        }
        if GraphemeBreak.isBreak(previous, c, &state) {
            return false
        }

        var cellY = y
        switch GraphemeBreak.widthEffect(previous: previous, c) {
        case .ignore:
            return true
        case .wide where cell.width != 2:
            cursor.x -= left
            if cursor.x == rightLimit - 1 {
                guard modes.contains(.autowrap) else { return true }
                // The widened cluster no longer fits: move it to the next line.
                let rowWrap = rightLimit == columns
                if rowWrap {
                    grid.setWrapped(y, true)
                }
                let base = cell.isGrapheme ? graphemes.scalars(cell.glyph)[0] : cell.glyph
                if cell.isGrapheme {
                    var attributes = cell.attributes
                    attributes.flags.subtract(.structural)
                    if rowWrap {
                        attributes.flags.insert(.spacerHead)
                    }
                    row[x] = Cell(glyph: 0, attributes: attributes, width: 1)
                } else {
                    writeCell(0, rowWrap ? .spacerHead : .narrow)
                }
                printWrap()
                writeCell(base, .wide)
                if cell.isGrapheme {
                    let moved = grid.row(cursor.y)
                    moved[cursor.x].glyph = cell.glyph
                    moved[cursor.x].attributes.flags.insert(.grapheme)
                }
                x = cursor.x
                cellY = cursor.y
            } else {
                row[x].width = 2
            }
            cursor.x += 1
            writeCell(0, .spacerTail)
            if cursor.x == rightLimit - 1 {
                cursor.pendingWrap = true
            } else {
                cursor.x += 1
            }
        case .narrow where cell.width == 2:
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
