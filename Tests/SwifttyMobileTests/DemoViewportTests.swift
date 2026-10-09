import SwifttyCore
@testable import SwifttyMobile
import Testing
import TestSupport

struct DemoViewportTests {
    func bytes(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    @Test(arguments: ["", "\u{1B}[I", "\u{1B}[O", "\u{1B}[200~\u{1B}[201~", "\u{1B}[97;1:3u", "\u{1B}["].map(TestFixture.init))
    func `ignored input does not redraw a windowed command`(_ ignored: TestFixture<String>) {
        let ignored = ignored.value
        var editor = DemoShell(columns: 12)
        _ = editor.input(bytes(String(repeating: "a", count: 60) + "\u{1B}[H"), rows: 3)
        #expect(editor.input(bytes(ignored), rows: 3).isEmpty)
        #expect(!editor.input([], columns: 13, rows: 4).isEmpty)
    }

    @Test(arguments: ["\u{1B}[H\u{7F}\u{7F}X", "\u{1B}[3~\u{1B}[3~!"].map(TestFixture.init))
    func `windowed redraw preserves every editing bell`(_ editing: TestFixture<String>) {
        let editing = editing.value
        var editor = DemoShell(columns: 12)
        var terminal = TerminalState(columns: 12, rows: 3)
        var parser = Parser()
        let prompt = DemoShell.prompt
        parser.consume(prompt.span, into: &terminal)
        let typed = editor.input(bytes(String(repeating: "a", count: 60)), rows: 3)
        parser.consume(typed.span, into: &terminal)
        _ = terminal.takeEvents()
        let output = editor.input(bytes(editing), rows: 3)
        parser.consume(output.span, into: &terminal)
        #expect(terminal.takeEvents().filter { $0 == .bell }.count == 2)
        #expect(editor.line.count == 61)
    }

    @Test(arguments: [false, true])
    func `resizing retains a windowed prompt without waiting for new input`(_ finish: Bool) {
        let session = TerminalSession(columns: 12, rows: 3)
        var editor = DemoShell(columns: 12)
        session.feed(DemoShell.prompt)
        let typed = String(repeating: "a", count: 60) + "Z"
        session.feed(editor.input(bytes(typed + "\u{1B}[HX"), rows: 3))
        if finish {
            session.feed(editor.input(bytes("\r" + "echo next"), rows: 3))
        }
        session.resize(columns: 13, rows: 4)
        let visible = session.snapshot().text.joined(separator: "\n")
        #expect(visible.contains(finish ? "demo:~$ echo" : "demo:~$ X"))
        #expect(session.withState { $0.semanticState } == .input)
        let moves = session.withState { state in
            state.promptCursorMoves(to: TerminalPoint(row: state.screenAbsoluteRow(state.cursor.y), column: state.cursor.x))
        }
        #expect(moves == 0)
    }

    @Test(arguments: ["漢", "👩‍💻", "👍🏽", "🇻🇳", "❤️"], [3, 32])
    func `one column editing uses one placeholder per wide grapheme`(_ cluster: String, _ height: Int) {
        let session = TerminalSession(columns: 1, rows: height)
        var editor = DemoShell(columns: 1)
        session.feed(DemoShell.prompt)
        session.feed(editor.input(bytes("A" + cluster + "Z"), rows: height))
        let visible = session.snapshot().text
        #expect(Array(visible.prefix(height == 3 ? 3 : 11).suffix(3)) == ["A", "", "Z"])
        #expect(session.withState { ($0.cursor.x, $0.cursor.y, $0.cursor.pendingWrap) } == (0, height == 3 ? 2 : 10, true))
        session.feed(editor.input([0x7F, 0x7F], rows: height))
        #expect(editor.lineText == "A")
        #expect(editor.cursor == 1)
        // Erasing a row boundary may leave the insertion position at the
        // next row's start; verify subsequent typing rather than requiring
        // one of the terminal's two equivalent wrap representations.
        session.feed(editor.input(bytes("B"), rows: height))
        #expect(editor.lineText == "AB")
        #expect(session.withState { ($0.cursor.x, $0.cursor.y, $0.cursor.pendingWrap) } == (0, height == 3 ? 2 : 9, true))
    }

    @Test(arguments: [1, 2, 3, 8, 12, 13], ["a", "a漢e\u{301}👩‍💻"])
    func `windowed rows and caret match a complete command at every grapheme boundary`(_ columns: Int, _ cluster: String) {
        for height in 1 ... 3 {
            let actual = TerminalSession(columns: columns, rows: height)
            let reference = TerminalSession(columns: columns, rows: 256)
            var editor = DemoShell(columns: columns), referenceEditor = DemoShell(columns: columns)
            let typed = String(repeating: cluster, count: cluster == "a" ? 48 : 8) + "Z"
            actual.feed(DemoShell.prompt)
            reference.feed(DemoShell.prompt)
            actual.feed(editor.input(bytes(typed), rows: height))
            reference.feed(referenceEditor.input(bytes(typed)))
            let count = reference.withState { $0.cursor.y + 1 }
            repeat {
                let actualRows = actual.snapshot().text
                let referenceRows = Array(reference.snapshot().text.prefix(count))
                let caret = actual.withState { ($0.cursor.x, $0.cursor.y, $0.cursor.pendingWrap) }
                let referenceCaret = reference.withState { ($0.cursor.x, $0.cursor.y, $0.cursor.pendingWrap) }
                let matches = (0 ... max(0, count - height)).contains { top in
                    actualRows == Array(referenceRows[top ..< min(count, top + height)])
                        && caret.0 == referenceCaret.0 && caret.1 == referenceCaret.1 - top && caret.2 == referenceCaret.2
                }
                #expect(
                    matches,
                    Comment(
                        rawValue: escapedTestText(
                            "columns=\(columns), height=\(height), cursor=\(editor.cursor), caret=\(caret), reference=\(referenceCaret)",
                        ),
                    ),
                )
                if editor.cursor == 0 {
                    break
                }
                actual.feed(editor.input(bytes("\u{1B}[D"), rows: height))
                reference.feed(referenceEditor.input(bytes("\u{1B}[D")))
            } while true
        }
    }

    @Test(arguments: [12, 13], ["a", "漢", "👩‍💻"])
    func `long commands keep Home End and insertion visible`(_ columns: Int, _ cluster: String) {
        let session = TerminalSession(columns: columns, rows: 3)
        var editor = DemoShell(columns: columns)
        let typed = String(repeating: cluster, count: columns * 4) + "Z"
        session.feed(DemoShell.prompt)
        session.feed(editor.input(bytes(typed), rows: 3))
        session.feed(editor.input(bytes("\u{1B}[HX"), rows: 3))
        #expect(editor.lineText == "X" + typed)
        let reference = TerminalSession(columns: columns, rows: 256)
        reference.feed(DemoShell.prompt + bytes("X" + typed))
        #expect(TestFixture(session.snapshot().text) == TestFixture(Array(reference.snapshot().text.prefix(3))))
        #expect(session.withState { ($0.cursor.x, $0.cursor.y) } == (9, 0))
        session.feed(editor.input([0x0C], rows: 3))
        #expect(TestFixture(session.snapshot().text) == TestFixture(Array(reference.snapshot().text.prefix(3))))
        #expect(session.withState { ($0.cursor.x, $0.cursor.y) } == (9, 0))
        session.feed(editor.input(bytes("\u{1B}[F!"), rows: 3))
        #expect(editor.lineText == "X" + typed + "!")
        let ending = TerminalSession(columns: columns, rows: 3)
        ending.feed(DemoShell.prompt + bytes(editor.lineText))
        #expect(TestFixture(session.snapshot().text) == TestFixture(ending.snapshot().text))
        #expect(session.withState { ($0.cursor.x, $0.cursor.y, $0.cursor.pendingWrap) }
            == ending.withState { ($0.cursor.x, $0.cursor.y, $0.cursor.pendingWrap) })
        session.feed(editor.input([0x15], rows: 3))
        #expect(editor.lineText.isEmpty)
        #expect(TestFixture(session.snapshot().text) == TestFixture(["demo:~$", "", ""]))
        #expect(session.withState { ($0.cursor.x, $0.cursor.y) } == (8, 0))
    }

    @Test(arguments: ["\r", "\u{03}"].map(TestFixture.init))
    func `finishing a windowed command restores its complete line`(_ ending: TestFixture<String>) {
        let ending = ending.value
        let session = TerminalSession(columns: 12, rows: 3)
        var editor = DemoShell(columns: 12)
        let typed = "echo " + String(repeating: "a", count: 60) + "Z"
        session.feed(DemoShell.prompt)
        let editing = "\u{1B}[H" + String(repeating: "\u{1B}[C", count: 5) + "X"
        session.feed(editor.input(bytes(typed + editing + ending), rows: 3))
        var referenceEditor = DemoShell(columns: 12)
        let reference = TerminalSession(columns: 12, rows: 3)
        reference.feed(DemoShell.prompt)
        reference.feed(referenceEditor.input(bytes("echo X" + typed.dropFirst(5) + ending)))
        #expect(TestFixture(session.snapshot().text) == TestFixture(reference.snapshot().text))
        #expect(editor.lineText.isEmpty)
        #expect(session.withState { $0.semanticState } == .input)
    }

    @Test func `windowed deletion and resize keep the caret aligned`() {
        let session = TerminalSession(columns: 12, rows: 3)
        var editor = DemoShell(columns: 12)
        let typed = String(repeating: "abc", count: 25) + "Z"
        session.feed(DemoShell.prompt)
        session.feed(editor.input(bytes(typed + "\u{1B}[H\u{1B}[3~"), rows: 3))
        #expect(editor.lineText == String(typed.dropFirst()))
        session.resize(columns: 13, rows: 4)
        let right = String(repeating: "\u{1B}[C", count: 17)
        session.feed(editor.input(bytes(right + "\u{7F}"), columns: 13, rows: 4))
        let reference = TerminalSession(columns: 13, rows: 128)
        reference.feed(DemoShell.prompt + bytes(editor.lineText))
        #expect(TestFixture(session.snapshot().text) == TestFixture(Array(reference.snapshot().text.prefix(4))))
        #expect(editor.cursor == 16)
        #expect(session.withState { ($0.cursor.x, $0.cursor.y) } == (11, 1))
        let moves = session.withState { state in
            state.promptCursorMoves(to: TerminalPoint(row: state.screenAbsoluteRow(0), column: 8))
        }
        #expect(moves == -16)
    }

    @Test func `the demo transport edits commands taller than its screen`() {
        let session = TerminalSession(columns: 12, rows: 3)
        let demo = DemoSource(session: session)
        demo.start()
        session.queue.sync {}
        session.queue.sync {}
        let typed = String(repeating: "a", count: 60) + "Z"
        session.send(.bytes(bytes(typed + "\u{1B}[HX")))
        session.queue.sync {}
        session.queue.sync {}
        #expect(TestFixture(session.snapshot().text[0]) == TestFixture("demo:~$ Xaaa"))
        #expect(session.withState { ($0.cursor.x, $0.cursor.y) } == (9, 0))
        demo.stop()
        session.queue.sync {}
    }
}
