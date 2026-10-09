import Dispatch
import SwifttyCore
@testable import SwifttyMobile
import Testing
import TestSupport

private func bytes(_ s: String) -> [UInt8] {
    Array(s.utf8)
}

private func text(_ b: [UInt8]) -> String {
    String(decoding: b, as: UTF8.self)
}

/// Feeds `input` through a demo shell into a terminal and returns the
/// terminal, as the frontend would see it.
private func run(_ input: [String], columns: Int = 60, rows: Int = 20) -> TerminalSession {
    let session = TerminalSession(columns: columns, rows: rows)
    var shell = DemoShell(columns: columns)
    session.feed(DemoShell.prompt)
    for chunk in input {
        session.feed(shell.input(bytes(chunk)))
    }
    return session
}

private func screen(_ session: TerminalSession) -> [String] {
    session.withState { state in
        (0 ..< state.rows).map { y in
            let row = state.absoluteRow(viewportRow: y)
            return state.text(from: TerminalPoint(row: row, column: 0), to: TerminalPoint(row: row, column: state.columns - 1))
        }
    }
}

struct DemoShellTests {
    @Test(arguments: [false, true])
    func `pasted controls cannot erase or cancel a typed command`(_ bracketed: Bool) {
        var shell = DemoShell()
        _ = shell.input(bytes("echo prefix"))
        var input: [UInt8] = []
        InputEncoder.encode(.paste("\u{15}middle\u{03}tail\u{7F}end"), modes: bracketed ? [.bracketedPaste] : .initial, into: &input)
        _ = shell.input(input)
        #expect(shell.lineText == "echo prefix middle tail end")
        #expect(shell.cursor == shell.line.count)
    }

    @Test func `a resize queued before the demo echo uses the new width for editing`() {
        let session = TerminalSession(columns: 12, rows: 24)
        let demo = DemoSource(session: session)
        demo.start()
        session.queue.sync {}
        session.queue.sync {}
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        session.queue.async {
            entered.signal()
            release.wait()
        }
        entered.wait()
        let typed = "abc漢" + String(repeating: "a", count: 20)
        session.send(.bytes(bytes(typed + "\u{1B}[H" + "X")))
        session.resize(columns: 13, rows: 24)
        release.signal()
        session.queue.sync {}
        session.queue.sync {}
        let expected = TerminalSession(columns: 12, rows: 24)
        expected.feed(DemoShell.banner + DemoShell.prompt)
        expected.resize(columns: 13, rows: 24)
        expected.queue.sync {}
        expected.feed(bytes("X" + typed))
        #expect(screen(session) == screen(expected))
        demo.stop()
        session.queue.sync {}
    }

    @Test(arguments: [12, 13, 80])
    func `editing a wrapped command preserves its text across rows`(_ columns: Int) {
        let typed = String(repeating: "a", count: columns * 2 + 3) + "Z"
        let actual = run([typed, "\u{1B}[H", "X"], columns: columns, rows: 8)
        let expected = TerminalSession(columns: columns, rows: 8)
        expected.feed(DemoShell.prompt + bytes("X" + typed))
        #expect(screen(actual) == screen(expected))
        #expect(actual.withState { ($0.cursor.x, $0.cursor.y) } == (9, 0))
    }

    @Test(arguments: [12, 13, 80])
    func `wrapped deletion clears rows that the shortened tail no longer fills`(_ columns: Int) {
        let typed = String(repeating: "a", count: columns * 2 + 3) + "Z"
        let actual = run([typed, "\u{1B}[H\u{1B}[3~\u{1B}[3~\u{1B}[3~"], columns: columns, rows: 8)
        let expected = TerminalSession(columns: columns, rows: 8)
        expected.feed(DemoShell.prompt + bytes(String(typed.dropFirst(3))))
        #expect(screen(actual) == screen(expected))
        #expect(actual.withState { ($0.cursor.x, $0.cursor.y) } == (8, 0))
    }

    @Test(arguments: ["漢", "👩‍💻", "❤️"])
    func `wide graphemes at a wrap boundary include their spacer in cursor movement`(_ cluster: String) {
        let typed = "abc" + cluster + "Z"
        let actual = run([typed, "\u{1B}[D\u{7F}"], columns: 12, rows: 8)
        let expected = TerminalSession(columns: 12, rows: 8)
        expected.feed(DemoShell.prompt + bytes("abcZ"))
        #expect(screen(actual) == screen(expected))
        #expect(actual.withState { ($0.cursor.x, $0.cursor.y) } == (11, 0))
        let restored = run([typed, "\u{1B}[H\u{1B}[F"], columns: 12, rows: 8)
        let reference = run([typed], columns: 12, rows: 8)
        #expect(screen(restored) == screen(reference))
        #expect(restored.withState { ($0.cursor.x, $0.cursor.y) } == reference.withState { ($0.cursor.x, $0.cursor.y) })
    }

    @Test func `the demo transport uses the current terminal width for wrapped editing`() {
        let session = TerminalSession(columns: 12, rows: 24)
        let demo = DemoSource(session: session)
        demo.start()
        session.resize(columns: 13, rows: 24)
        let typed = String(repeating: "a", count: 29) + "Z"
        session.send(.bytes(bytes(typed + "\u{1B}[H" + "X")))
        session.queue.sync {}
        session.queue.sync {}
        let expected = TerminalSession(columns: 13, rows: 24)
        expected.feed(DemoShell.banner + DemoShell.prompt + bytes("X" + typed))
        #expect(screen(session) == screen(expected))
        demo.stop()
        session.queue.sync {}
    }

    @Test func `submitting from the middle of a wrapped command puts output after its complete line`() {
        let actual = run(["echo " + String(repeating: "a", count: 32), "\u{1B}[H\r"], columns: 12, rows: 16)
        let expected = run(["echo " + String(repeating: "a", count: 32), "\r"], columns: 12, rows: 16)
        #expect(screen(actual) == screen(expected))
    }

    @Test(arguments: [1, 2, 4, 8, 12, 13])
    func `submitting after deleting a row boundary character preserves the pending wrap`(_ columns: Int) {
        let letters = columns * 2 + (columns - 13 % columns) % columns
        let command = "echo " + String(repeating: "a", count: letters)
        let actual = run([command + "X", "\u{7F}\r"], columns: columns, rows: 40)
        let expected = run([command, "\r"], columns: columns, rows: 40)
        #expect(screen(actual) == screen(expected))
    }

    @Test(arguments: ["\u{600}a", "\u{600}漢", "\u{94D}क"])
    func `clusters with a zero width lead keep editing aligned`(_ cluster: String) {
        let session = TerminalSession(columns: 60, rows: 5)
        var shell = DemoShell()
        session.feed(DemoShell.prompt)
        let start = session.withState { $0.cursor.x }
        let columns = TerminalGeometry.compositionColumn(in: Array(cluster.unicodeScalars), atUTF16Offset: .max)
        session.feed(shell.input(bytes(cluster + "Z")))
        #expect(screen(session)[0].hasPrefix("demo:~$ "))
        #expect(session.withState { $0.cursor.x } == start + columns + 1)
        session.feed(shell.input([0x0C]))
        #expect(screen(session)[0].hasPrefix("demo:~$ "))
        #expect(session.withState { $0.cursor.x } == start + columns + 1)
        session.feed(shell.input(bytes("\u{1B}[D\u{7F}")))
        #expect(shell.lineText == "Z")
        #expect(screen(session)[0] == "demo:~$ Z")
        #expect(session.withState { $0.cursor.x } == start)
    }

    @Test(arguments: ["\u{301}", "\u{200D}", "\u{FE0F}", "\u{200B}"])
    func `standalone zero width text occupies an editable cell without changing the prompt`(_ mark: String) {
        let session = TerminalSession(columns: 60, rows: 5)
        var shell = DemoShell()
        session.feed(DemoShell.prompt)
        let start = session.withState { $0.cursor.x }
        let prompt = "demo:~$ "
        session.feed(shell.input(bytes(mark + "Z")))
        #expect(shell.lineText == mark + "Z")
        #expect(screen(session)[0].hasPrefix(prompt))
        #expect(session.withState { $0.cursor.x } == start + 2)
        session.feed(shell.input([0x0C])) // Repainting must retain the placeholder.
        #expect(screen(session)[0].hasPrefix(prompt))
        #expect(session.withState { $0.cursor.x } == start + 2)
        session.feed(shell.input(bytes("\u{1B}[H\u{1B}[3~")))
        #expect(shell.lineText == "Z")
        #expect(screen(session)[0] == prompt + "Z")
        #expect(session.withState { $0.cursor.x } == start)
    }

    @Test func `zero width separators in the middle of a line remain editable`() {
        let session = run(["A\u{200B}Z", "\u{1B}[D\u{7F}"])
        #expect(screen(session)[0] == "demo:~$ AZ")
        #expect(session.withState { $0.cursor.x } == 9)
    }

    @Test func `restarting with queued input puts its old echo before the fresh prompt`() {
        let session = TerminalSession(columns: 60, rows: 30)
        let demo = DemoSource(session: session)
        demo.start()
        session.queue.sync {}
        session.queue.sync {}
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        session.queue.async {
            entered.signal()
            release.wait()
        }
        entered.wait()
        session.send(.text("stale"))
        demo.stop()
        demo.start()
        session.send(.text("echo fresh\r"))
        release.signal()
        session.queue.sync {}
        session.queue.sync {}
        #expect(TestFixture(screen(session).joined(separator: "\n").contains("$ echo fresh\nfresh\n")) == TestFixture(true))
        demo.stop()
        session.queue.sync {}
    }

    @Test func `stopping the demo preserves input already queued before stop`() {
        let session = TerminalSession(columns: 60, rows: 30)
        let demo = DemoSource(session: session)
        demo.start()
        session.queue.sync {}
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        session.queue.async {
            entered.signal()
            release.wait()
        }
        entered.wait()
        session.send(.text("echo before\r"))
        demo.stop()
        release.signal()
        session.queue.sync {}
        session.queue.sync {}
        let stopped = screen(session)
        #expect(stopped.contains("before"))
        session.send(.text("echo after\r"))
        session.queue.sync {}
        session.queue.sync {}
        #expect(screen(session) == stopped)
    }

    @Test(arguments: [bytes("echo stale"), bytes("\u{1B}[123"), [UInt8(0xC3)]], [false, true])
    func `restarting the demo resets partially entered input`(_ pending: [UInt8], _ stopFirst: Bool) {
        let session = TerminalSession(columns: 60, rows: 30)
        let demo = DemoSource(session: session)
        demo.start()
        session.send(.bytes(pending))
        session.queue.sync {}
        session.queue.sync {} // Drain the echo's return hop.
        if stopFirst {
            demo.stop()
        }
        demo.start()
        session.send(.bytes([0xA9] + bytes("echo fresh\r")))
        session.queue.sync {}
        session.queue.sync {}
        #expect(screen(session).contains("fresh"))
        demo.stop()
        session.queue.sync {}
    }

    @Test(arguments: [(2, "\u{7F}"), (3, "\u{1B}[3~")].map(TestFixture.init))
    func `deleting a separator merges flags without stranding the cursor`(_ sample: TestFixture<(Int, String)>) {
        let sample = sample.value
        let session = TerminalSession(columns: 60, rows: 5)
        var shell = DemoShell()
        session.feed(DemoShell.prompt)
        let start = session.withState { $0.cursor.x }
        session.feed(shell.input(bytes("A🇻X🇳Z")))
        for _ in 0 ..< sample.0 {
            session.feed(shell.input(bytes("\u{1B}[D")))
        }
        session.feed(shell.input(bytes(sample.1)))
        #expect(shell.lineText == "A🇻🇳Z")
        #expect(shell.cursor == 3)
        #expect(screen(session)[0].hasSuffix("$ A🇻🇳Z"))
        #expect(session.withState { $0.cursor.x } == start + 3)
        session.feed(shell.input([0x7F]))
        #expect(shell.lineText == "AZ")
        #expect(screen(session)[0].hasSuffix("$ AZ"))
        #expect(session.withState { $0.cursor.x } == start + 1)
    }

    struct InsertionCase: Sendable {
        let before: String
        let leftMoves: Int
        let insertion: String
        let after: String
        let cursorScalarIndex: Int
        let cursorColumnOffset: Int
    }

    @Test(arguments: [
        InsertionCase(before: "A👩💻Z", leftMoves: 2, insertion: "\u{200D}", after: "A👩‍💻Z", cursorScalarIndex: 4, cursorColumnOffset: 3),
        InsertionCase(before: "A👍Z", leftMoves: 1, insertion: "🏽", after: "A👍🏽Z", cursorScalarIndex: 3, cursorColumnOffset: 3),
        InsertionCase(before: "AeZ", leftMoves: 1, insertion: "\u{301}", after: "Ae\u{301}Z", cursorScalarIndex: 3, cursorColumnOffset: 2),
        InsertionCase(before: "A🇻Z", leftMoves: 2, insertion: "🇳", after: "A🇳🇻Z", cursorScalarIndex: 3, cursorColumnOffset: 3),
        InsertionCase(before: "A❤Z", leftMoves: 1, insertion: "\u{FE0F}", after: "A❤️Z", cursorScalarIndex: 3, cursorColumnOffset: 3),
    ])
    func `insertion that merges graphemes keeps the cursor at a rendered boundary`(_ sample: InsertionCase) {
        let session = TerminalSession(columns: 60, rows: 5)
        var shell = DemoShell()
        session.feed(DemoShell.prompt)
        let start = session.withState { $0.cursor.x }
        session.feed(shell.input(bytes(sample.before)))
        for _ in 0 ..< sample.leftMoves {
            session.feed(shell.input(bytes("\u{1B}[D")))
        }
        session.feed(shell.input(bytes(sample.insertion)))
        #expect(shell.lineText == sample.after)
        #expect(shell.cursor == sample.cursorScalarIndex)
        #expect(screen(session)[0].hasSuffix("$ " + sample.after))
        #expect(session.withState { $0.cursor.x } == start + sample.cursorColumnOffset)
        session.feed(shell.input([0x7F]))
        #expect(shell.lineText == "AZ")
        #expect(screen(session)[0].hasSuffix("$ AZ"))
        #expect(session.withState { $0.cursor.x } == start + 1)
    }

    @Test(arguments: [UInt8(0x03), 0x18, 0x1A])
    func `interrupting an incomplete escape restores ordinary input`(_ control: UInt8) {
        var shell = DemoShell()
        _ = shell.input(bytes("a\u{1B}[123"))
        let output = shell.input([control] + bytes("b"))
        #expect(shell.lineText == (control == 0x03 ? "b" : "ab"))
        if control == 0x03 {
            #expect(TestFixture(text(output).hasPrefix("^C\r\n")) == TestFixture(true))
        }
    }

    @Test func `oversized escape parameters are discarded through their final byte`() {
        var shell = DemoShell()
        _ = shell.input(bytes("ab\u{1B}["))
        _ = shell.input(Array(repeating: UInt8(ascii: "0"), count: 1024 * 1024))
        #expect(shell.input(bytes("DX")) == bytes("X"))
        #expect(shell.lineText == "abX" && shell.cursor == 3)
        _ = shell.input(bytes("\u{1B}[123\u{1B}[D"))
        #expect(shell.cursor == 2)
    }

    @Test(arguments: [
        ([UInt8(0xC3), 0x61, 0xA9], "a"),
        ([0xC3, 0x0D, 0xA9], ""),
        ([0xC3, 0x03, 0xA9], ""),
        ([0xC3, 0x1B, 0x5B, 0x44, 0xA9], ""),
        ([0xE2, 0xC3, 0xA9], "é"),
        ([0xFF, 0xC3, 0xA9], "é"),
    ])
    func `invalid UTF8 does not span ASCII controls or new leading bytes`(_ sample: ([UInt8], String)) {
        for split in [false, true] {
            var shell = DemoShell()
            if split {
                for byte in sample.0 {
                    _ = shell.input([byte])
                }
            } else {
                _ = shell.input(sample.0)
            }
            #expect(shell.lineText == sample.1)
            _ = shell.input(bytes("ö"))
            #expect(shell.lineText == sample.1 + "ö")
        }
    }

    @Test(arguments: ["e\u{301}", "👩‍💻", "🇻🇳", "👍🏽"])
    func `backspace removes a complete rendered grapheme`(_ cluster: String) {
        let session = TerminalSession(columns: 60, rows: 5)
        var shell = DemoShell()
        session.feed(DemoShell.prompt)
        let start = session.withState { $0.cursor.x }
        session.feed(shell.input(bytes("A" + cluster)))
        session.feed(shell.input([0x7F]))
        #expect(shell.lineText == "A")
        #expect(screen(session)[0].hasSuffix("$ A"))
        #expect(session.withState { $0.cursor.x } == start + 1)
        let middle = run(["A" + cluster + "Z", "\u{1B}[D", "\u{7F}"])
        #expect(screen(middle)[0].hasSuffix("$ AZ"))
        #expect(middle.withState { $0.cursor.x } == start + 1)
    }

    @Test(arguments: ["e\u{301}", "👩‍💻", "🇻🇳", "👍🏽"])
    func `arrows and forward delete edit whole rendered graphemes`(_ cluster: String) {
        let session = TerminalSession(columns: 60, rows: 5)
        var shell = DemoShell()
        session.feed(DemoShell.prompt)
        let start = session.withState { $0.cursor.x }
        session.feed(shell.input(bytes("A" + cluster)))
        session.feed(shell.input(bytes("\u{1B}[D")))
        #expect(shell.cursor == 1)
        #expect(session.withState { $0.cursor.x } == start + 1)
        session.feed(shell.input(bytes("\u{1B}[C")))
        #expect(shell.cursor == shell.line.count)
        session.feed(shell.input(bytes("\u{1B}[D\u{1B}[3~")))
        #expect(shell.lineText == "A")
        #expect(screen(session)[0].hasSuffix("$ A"))
        #expect(session.withState { $0.cursor.x } == start + 1)
    }

    @Test func `echoes and runs commands`() {
        var shell = DemoShell()
        #expect(shell.input(bytes("echo hi")) == bytes("echo hi"))
        #expect(shell.lineText == "echo hi")
        let out = text(shell.input([0x0D]))
        // Command-output mark, output, end mark with status, next prompt.
        #expect(TestFixture(out.hasPrefix("\r\n\u{1B}]133;C\u{7}hi\r\n\u{1B}]133;D;0\u{7}")) == TestFixture(true))
        #expect(out.hasSuffix(text(DemoShell.prompt)))
        #expect(shell.lineText.isEmpty)
        #expect(TestFixture(text(shell.input(bytes("nope\r"))).contains("nope: command not found\r\n\u{1B}]133;D;127")) ==
            TestFixture(true))
    }

    @Test func `prompt carries OSC 133 marks`() {
        let prompt = text(DemoShell.prompt)
        #expect(TestFixture(prompt.hasPrefix("\u{1B}]133;A\u{7}")) == TestFixture(true))
        #expect(TestFixture(prompt.hasSuffix("\u{1B}]133;B\u{7}")) == TestFixture(true))
    }

    @Test func `backspace erases characters`() {
        var shell = DemoShell()
        _ = shell.input(bytes("ab"))
        #expect(TestFixture(shell.input([0x7F])) == TestFixture(bytes("\u{1B}[1D\u{1B}[J")))
        #expect(shell.lineText == "a")
        _ = shell.input(bytes("漢"))
        // A wide character takes two cells to rub out.
        #expect(TestFixture(shell.input([0x7F])) == TestFixture(bytes("\u{1B}[2D\u{1B}[J")))
        #expect(shell.lineText == "a")
        _ = shell.input([0x7F])
        #expect(shell.input([0x7F]) == [0x07]) // nothing left: bell
    }

    @Test func `ignores other escape sequences`() {
        var shell = DemoShell()
        // Up/down, a kitty key report, focus and bracketed-paste markers.
        let out = shell.input(bytes("\u{1B}[A\u{1B}OB\u{1B}[97;5u\u{1B}[I\u{1B}[200~pasted\u{1B}[201~"))
        #expect(out == bytes("pasted"))
        #expect(shell.lineText == "pasted")
    }

    @Test func `split UTF-8 sequences`() {
        var shell = DemoShell()
        let e = bytes("é")
        #expect(shell.input([e[0]]).isEmpty)
        #expect(shell.input([e[1]]) == e)
        #expect(shell.lineText == "é")
    }

    @Test func `control keys`() {
        var shell = DemoShell()
        _ = shell.input(bytes("abc"))
        #expect(TestFixture(text(shell.input([0x03])).hasPrefix("^C\r\n")) == TestFixture(true))
        #expect(shell.lineText.isEmpty)
        _ = shell.input(bytes("xy"))
        _ = shell.input([0x15]) // Ctrl-U
        #expect(shell.lineText.isEmpty)
    }

    /// Arrows edit mid-line, and the terminal shows the result.
    @Test func `cursor editing`() {
        let session = run(["helo", "\u{1B}[D", "l", "\u{1B}[H", "X", "\u{1B}[F", "!", "\u{1B}[D\u{1B}[D\u{1B}[3~"])
        let line = screen(session)[0]
        #expect(line.hasSuffix("$ Xhell!"))
        let cursor = session.withState { $0.cursor.x }
        #expect(cursor == line.count - 1) // on the "!"
    }

    /// Click-to-move against the demo's marks: the arrows the core asks
    /// for, typed back into the shell, land the cursor on the clicked cell.
    @Test func `click to move round trip`() {
        let session = TerminalSession(columns: 40, rows: 5)
        var shell = DemoShell()
        session.feed(DemoShell.prompt)
        session.feed(shell.input(bytes("echo hello")))
        let target = session.withState { state in
            TerminalPoint(row: state.absoluteRow(viewportRow: 0), column: state.cursor.x - 5) // the "h"
        }
        let moves = session.withState { $0.promptCursorMoves(to: target) }
        #expect(moves == -5)
        var out: [UInt8] = []
        for key in ClickToMove.keys(moves ?? 0) {
            InputEncoder.encode(.key(key), modes: .initial, into: &out)
        }
        session.feed(shell.input(out))
        #expect(session.withState { $0.cursor.x } == target.column)
        #expect(shell.cursor == 5)
    }

    @Test func `command output range`() throws {
        let session = run(["echo one\r", "echo two\r"])
        let rows = screen(session)
        let outputRow = try #require(rows.firstIndex(of: "one"))
        let range = session.withState { state in
            state.commandOutputRange(at: TerminalPoint(row: state.absoluteRow(viewportRow: 0), column: 2))
        }
        let selected = session.withState { state in
            range.map { state.text(from: $0.start, to: $0.end) }
        }
        #expect(selected == "one")
        #expect(outputRow == 1)
    }

    @Test func `links command prints OSC 8 and a URL`() throws {
        let session = run(["links\r"])
        let rows = screen(session)
        let row = try #require(rows.firstIndex { $0.hasPrefix("OSC 8:") })
        let (osc8, detected) = session.withState { state in
            let y = state.absoluteRow(viewportRow: row)
            let column = rows[row].distance(from: rows[row].startIndex, to: rows[row].range(of: "Ghostty")!.lowerBound)
            let urlRow = state.absoluteRow(viewportRow: row + 1)
            return (
                state.link(at: TerminalPoint(row: y, column: column)),
                state.link(at: TerminalPoint(row: urlRow, column: 12)),
            )
        }
        #expect(osc8?.url == "https://ghostty.org")
        #expect(osc8.map { $0.id != 0 } == true)
        #expect(detected?.url == "https://github.com/ghostty-org/ghostty")
        #expect(detected?.id == 0)
    }

    /// The demo end to end: typed keys go out through `onWrite`, the echo
    /// comes back through `receive`, and the screen shows the result.
    @Test func `drives a session`() async throws {
        let session = TerminalSession(columns: 60, rows: 30)
        let demo = DemoSource(session: session)
        demo.start()
        for text in ["echo hello", "\r", "colors\r"] {
            session.send(.text(text))
        }
        // Each round trip hops queue -> receive -> queue; wait for it.
        var lines: [String] = []
        for _ in 0 ..< 200 {
            lines = screen(session)
            if lines.contains(where: { $0.contains("blink") }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let joined = lines.joined(separator: "\n")
        #expect(joined.contains("local echo shell"))
        #expect(TestFixture(joined.contains("$ echo hello\nhello\n")) == TestFixture(true))
        #expect(joined.contains("bold italic underline strike inverse faint"))
        #expect(joined.contains("curly red curly dotted dashed double blink"))
        demo.stop()
    }
}
