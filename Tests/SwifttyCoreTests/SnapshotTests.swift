import Dispatch
@testable import SwifttyCore
import Synchronization
import Testing
import TestSupport

struct SnapshotTests {
    @Test func `concurrent readers retain immutable snapshots while updates resize the pool`() {
        let session = TerminalSession(columns: 20, rows: 3)
        session.feed(Array("A👩‍💻e\u{301}🇻🇳Z\r\nsecond".utf8))
        let original = session.snapshot()
        let originalText = original.text
        let stable = Mutex(true)
        DispatchQueue.concurrentPerform(iterations: 160) { index in
            if index.isMultiple(of: 2) {
                session.resize(columns: 12 + index % 19, rows: 2 + index % 5)
                session.feed(Array("\u{1B}[HA👩‍💻e\u{301}🇻🇳\(index)\r\nsecond".utf8))
                _ = session.snapshot()
            } else {
                let snapshot = session.snapshot()
                let expected = snapshot.text
                for _ in 0 ..< 32 {
                    if snapshot.text != expected || original.text != originalText {
                        stable.withLock { $0 = false }
                    }
                }
            }
        }
        #expect(stable.withLock { $0 })
        #expect(TestFixture(original.text) == TestFixture(originalText))
    }

    @Test func `search snapshots with dense history fit a frame budget`() {
        var state = TerminalState(columns: 120, rows: 40, scrollbackLimitBytes: 64 * 1024 * 1024)
        var parser = Parser()
        let content = [UInt8](repeating: 0x61, count: 512 * 1024)
        parser.consume(content.span, into: &state)
        state.search("a")
        #expect(state.searchMatches.count == content.count)
        var builder = SnapshotBuilder()
        var times: [Double] = []
        for _ in 0 ..< 40 {
            let start = DispatchTime.now().uptimeNanoseconds
            let snapshot = builder.build(from: &state)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            #expect(snapshot.searchMatchCount == content.count)
            #expect(snapshot.searchMatches.count <= 120 * 40)
        }
        times = Array(times.dropFirst(5)).sorted()
        let p95 = times[times.count * 95 / 100]
        print("search-snapshot p95_ms=\(p95)")
        #expect(p95 < 16.7)
    }

    @Test func `search snapshots preserve clipped matches and selected indices through overscan`() {
        var state = TerminalState(columns: 4, rows: 2)
        var parser = Parser()
        let content = Array(String(repeating: "ababa----", count: 20).utf8)
        parser.consume(content.span, into: &state)
        state.search("ababa")
        #expect(state.searchMatches.count == 20)
        var builder = SnapshotBuilder()
        for selected in [0, state.searchMatches.count / 2, state.searchMatches.count - 1] {
            state.searchSelected = selected
            for offset in [0, 3, state.grid.historyCount] {
                state.scrollViewport(by: offset - state.viewportOffset)
                for overscan in [0, 1, 3] {
                    let snapshot = builder.build(from: &state, overscan: overscan)
                    let top = state.absoluteRow(viewportRow: 0), bottom = top + snapshot.rowCount - 1
                    let indices = state.searchMatches.indices.filter {
                        state.searchMatches[$0].end.row >= top && state.searchMatches[$0].start.row <= bottom
                    }
                    let expected = indices.map { index in
                        let match = state.searchMatches[index]
                        return HighlightSpan(
                            startRow: state.viewportRow(absoluteRow: match.start.row), startColumn: match.start.column,
                            endRow: state.viewportRow(absoluteRow: match.end.row), endColumn: match.end.column,
                        )
                    }
                    #expect(snapshot.searchMatches == expected)
                    #expect(snapshot.selectedSearchMatch == indices.firstIndex(of: selected))
                    #expect(snapshot.searchMatchCount == state.searchMatches.count && snapshot.searchSelectedIndex == selected)
                }
            }
        }
    }

    @Test func `snapshots carry only damaged rows as dirty`() {
        let session = TerminalSession(columns: 10, rows: 4)
        session.feed(Array("hello\r\nworld".utf8))
        let first = session.snapshot()
        #expect(first.damage.isFull)
        #expect(TestFixture(first.text) == TestFixture(["hello", "world", "", ""]))

        session.feed(Array("\u{1B}[4;1Hbye".utf8))
        let second = session.snapshot()
        #expect(!second.damage.isFull)
        #expect(second.damage.contains(row: 3) && !second.damage.contains(row: 0))
        #expect(second.rows[3].isDirty && !second.rows[0].isDirty)
        #expect(TestFixture(second.text) == TestFixture(["hello", "world", "", "bye"]))
        #expect(second.sequence > first.sequence)
        // The earlier snapshot is immutable even though content changed.
        #expect(TestFixture(first.text[3]) == TestFixture(""))
    }

    @Test(arguments: [false, true])
    func `storage reuse keeps undamaged rows correct`(_ graphemes: Bool) {
        let session = TerminalSession(columns: 16, rows: 3)
        let suffix = graphemes ? "👩‍💻e\u{301}" : ""
        for i in 0 ..< 20 {
            session.feed(Array("\u{1B}[\(i % 3 + 1);1H\u{1B}[Kline\(i)\(suffix)".utf8))
            // Updated and unchanged frames must all reflect each row's latest write.
            for _ in 0 ..< 4 {
                let snap = session.snapshot()
                for row in 0 ..< 3 {
                    let last = stride(from: i, through: 0, by: -1).first { $0 % 3 == row }
                    #expect(TestFixture(snap.text[row]) == TestFixture((last.map { "line\($0)\(suffix)" } ?? "")))
                }
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
        #expect(TestFixture(snap.text[0]) == TestFixture("e\u{301}中"))
        #expect(snap.cursor == CursorState(x: 3, y: 0, isVisible: true, style: .block, isBlinking: false))
    }

    @Test func `synchronized output holds frames`() {
        let session = TerminalSession(columns: 10, rows: 2)
        session.feed(Array("a".utf8))
        _ = session.snapshot()
        session.feed(Array("\u{1B}[?2026hb".utf8))
        #expect(TestFixture(session.snapshot().text[0]) == TestFixture("a"))
        session.feed(Array("\u{1B}[?2026l".utf8))
        #expect(TestFixture(session.snapshot().text[0]) == TestFixture("ab"))
    }

    @Test func `program exit releases the final synchronized frame`() {
        let session = TerminalSession(columns: 10, rows: 2)
        session.feed(Array("a".utf8))
        _ = session.snapshot()
        session.feed(Array("\u{1B}[?2026hb".utf8))
        #expect(TestFixture(session.snapshot().text[0]) == TestFixture("a"))
        session.programExited()
        #expect(!session.modes.contains(.synchronizedOutput))
        #expect(TestFixture(session.snapshot().text[0]) == TestFixture("ab"))

        session.feed(Array("\u{1B}[?2026hc".utf8))
        #expect(TestFixture(session.snapshot().text[0]) == TestFixture("ab"))
        session.feed(Array("\u{1B}[?2026l".utf8))
        #expect(TestFixture(session.snapshot().text[0]) == TestFixture("abc"))
    }
}
