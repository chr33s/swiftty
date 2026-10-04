@testable import SwifttyCore
import Testing

struct SelectionTests {
    @Test func `text across wraps and lines`() {
        var vt = VT(5, 3)
        vt.feed("abcdefg\r\nxy")
        let a = vt.state.absoluteRow(viewportRow: 0)
        let text = vt.state.text(from: TerminalPoint(row: a, column: 0), to: TerminalPoint(row: a + 2, column: 4))
        #expect(text == "abcdefg\nxy")
    }

    @Test func `points stay pinned while scrolling`() {
        var vt = VT(5, 2)
        vt.feed("one\r\ntwo")
        let row = vt.state.absoluteRow(viewportRow: 0)
        vt.state.setSelection(Selection(anchor: TerminalPoint(row: row, column: 0), head: TerminalPoint(row: row, column: 2)))
        vt.feed("\r\nthree\r\nfour")
        let text = vt.state.selectionText
        #expect(text == "one")
    }

    @Test func `word and line ranges`() {
        var vt = VT(20, 2)
        vt.feed("ls /usr/bin; echo")
        let row = vt.state.absoluteRow(viewportRow: 0)
        let word = vt.state.wordRange(at: TerminalPoint(row: row, column: 5))
        #expect(word.start.column == 3 && word.end.column == 10)
        let line = vt.state.lineRange(at: TerminalPoint(row: row, column: 5))
        #expect(line.start.column == 0 && line.end.column == 19)
    }

    @Test func `search finds matches across history`() {
        var vt = VT(10, 2)
        vt.feed("foo bar\r\nbaz\r\nFoo\r\nx")
        vt.state.search("foo")
        let count = vt.state.searchMatches.count
        #expect(count == 2)
        let selected = vt.state.selectSearchMatch(forward: false)
        #expect(selected == 1)
    }

    @Test func `alternate screen clears selection`() {
        var vt = VT(10, 2)
        vt.feed("hi")
        vt.state.setSelection(Selection(anchor: TerminalPoint(row: 0, column: 0), head: TerminalPoint(row: 0, column: 1)))
        vt.feed("\(CSI)?1049h")
        let cleared = vt.state.selection == nil
        #expect(cleared)
    }
}

struct DumpTests {
    @Test func `dump round trips`() {
        var vt = VT(6, 3)
        vt.feed("\(CSI)1;31mred\(CSI)0m plain\r\nabcdefgh\r\nz")
        let dump = vt.state.dumpPrimaryANSI()
        var copy = VT(6, 3)
        copy.feed(bytes: dump)
        #expect(copy.lines == vt.lines)
        let a = copy.state.absoluteRow(viewportRow: 0)
        let b = vt.state.absoluteRow(viewportRow: 0)
        #expect(copy.state.text(from: TerminalPoint(row: a - 1, column: 0), to: TerminalPoint(row: a + 2, column: 5))
            == vt.state.text(from: TerminalPoint(row: b - 1, column: 0), to: TerminalPoint(row: b + 2, column: 5)))
        #expect(copy.cell(0, 0).attributes.foreground == vt.cell(0, 0).attributes.foreground)
    }
}
