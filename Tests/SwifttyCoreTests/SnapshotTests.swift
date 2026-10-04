@testable import SwifttyCore
import Testing

struct SnapshotTests {
    @Test func `snapshots carry only damaged rows as dirty`() {
        let session = TerminalSession(columns: 10, rows: 4)
        session.feed(Array("hello\r\nworld".utf8))
        let first = session.snapshot()
        #expect(first.damage.isFull)
        #expect(first.text == ["hello", "world", "", ""])

        session.feed(Array("\u{1B}[4;1Hbye".utf8))
        let second = session.snapshot()
        #expect(!second.damage.isFull)
        #expect(second.damage.contains(row: 3) && !second.damage.contains(row: 0))
        #expect(second.rows[3].isDirty && !second.rows[0].isDirty)
        #expect(second.text == ["hello", "world", "", "bye"])
        #expect(second.sequence > first.sequence)
        // The earlier snapshot is immutable even though content changed.
        #expect(first.text[3] == "")
    }

    @Test func `storage reuse keeps undamaged rows correct`() {
        let session = TerminalSession(columns: 8, rows: 3)
        for i in 0 ..< 20 {
            session.feed(Array("\u{1B}[\(i % 3 + 1);1H\u{1B}[Kline\(i)".utf8))
            let snap = session.snapshot()
            // Every row must reflect the latest write to it.
            for row in 0 ..< 3 {
                let last = stride(from: i, through: 0, by: -1).first { $0 % 3 == row }
                #expect(snap.text[row] == (last.map { "line\($0)" } ?? ""))
            }
        }
    }

    @Test func `graphemes and cursor`() {
        let session = TerminalSession(columns: 10, rows: 2)
        session.feed(Array("e\u{301}中".utf8))
        let snap = session.snapshot()
        let cell = snap.cells(row: 0)[0]
        #expect(cell.isGrapheme)
        #expect(snap.graphemeScalars(cell).count == 2)
        #expect(snap.text[0] == "e\u{301}中")
        #expect(snap.cursor == CursorState(x: 3, y: 0, isVisible: true, style: .block, isBlinking: false))
    }

    @Test func `synchronized output holds frames`() {
        let session = TerminalSession(columns: 10, rows: 2)
        session.feed(Array("a".utf8))
        _ = session.snapshot()
        session.feed(Array("\u{1B}[?2026hb".utf8))
        #expect(session.snapshot().text[0] == "a")
        session.feed(Array("\u{1B}[?2026l".utf8))
        #expect(session.snapshot().text[0] == "ab")
    }
}
