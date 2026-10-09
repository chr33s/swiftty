@testable import SwifttyCore
import Testing

struct ShellCursorMovementTests {
    @Test(arguments: [(3, "😀"), (4, "😀"), (3, "❤\u{FE0F}"), (4, "❤\u{FE0F}"), (3, "👨‍👩‍👧"), (4, "👨‍👩‍👧")], Array(0 ... 4))
    func `click movement counts character boundaries in both directions across wraps`(_ fixture: (Int, String), _ from: Int) {
        let (columns, emoji) = fixture
        var vt = VT(columns, 5, scrollback: 4096)
        vt.feed("\u{1B}[?2027h\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}漢x" + emoji + "y")
        let leads: [(Int, Int)] = columns == 3 ? [(1, 0), (1, 2), (2, 0), (2, 2)] : [(0, 2), (1, 0), (1, 1), (1, 3)]
        if from < 4 {
            let (row, column) = leads[from]
            vt.feed("\u{1B}[\(row + 1);\(column + 1)H")
        }
        let cursor = vt.cursor
        let pending = vt.state.cursor.pendingWrap
        // Either half of a wide character identifies a valid insertion
        // boundary: the lead precedes it and the tail follows it.
        for (index, lead) in leads.enumerated() {
            let (row, column) = lead
            let moves = vt.state.promptCursorMoves(to: TerminalPoint(row: row, column: column))
            #expect(moves == index - from)
            if index == 0 || index == 2 {
                let tailMoves = vt.state.promptCursorMoves(to: TerminalPoint(row: row, column: column + 1))
                #expect(tailMoves == index + 1 - from)
            }
        }
        let end = leads[3]
        let endMoves = vt.state.promptCursorMoves(to: TerminalPoint(row: end.0, column: columns))
        #expect(endMoves == 4 - from)
        if columns == 3 {
            let paddingMoves = vt.state.promptCursorMoves(to: TerminalPoint(row: 0, column: 2))
            #expect(paddingMoves == -from)
        }
        let promptMoves = vt.state.promptCursorMoves(to: TerminalPoint(row: 0, column: 1))
        #expect(promptMoves == nil)
        #expect(vt.cursor == cursor)
        #expect(vt.state.cursor.pendingWrap == pending)
    }
}
