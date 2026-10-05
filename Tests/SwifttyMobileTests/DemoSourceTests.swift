import Dispatch
import SwifttyCore
@testable import SwifttyMobile
import Testing

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
    var shell = DemoShell()
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
    @Test func `echoes and runs commands`() {
        var shell = DemoShell()
        #expect(shell.input(bytes("echo hi")) == bytes("echo hi"))
        #expect(shell.lineText == "echo hi")
        let out = text(shell.input([0x0D]))
        // Command-output mark, output, end mark with status, next prompt.
        #expect(out.hasPrefix("\r\n\u{1B}]133;C\u{7}hi\r\n\u{1B}]133;D;0\u{7}"))
        #expect(out.hasSuffix(text(DemoShell.prompt)))
        #expect(shell.lineText.isEmpty)
        #expect(text(shell.input(bytes("nope\r"))).contains("nope: command not found\r\n\u{1B}]133;D;127"))
    }

    @Test func `prompt carries OSC 133 marks`() {
        let prompt = text(DemoShell.prompt)
        #expect(prompt.hasPrefix("\u{1B}]133;A\u{7}"))
        #expect(prompt.hasSuffix("\u{1B}]133;B\u{7}"))
    }

    @Test func `backspace erases characters`() {
        var shell = DemoShell()
        _ = shell.input(bytes("ab"))
        #expect(shell.input([0x7F]) == bytes("\u{1B}[1D\u{1B}[K"))
        #expect(shell.lineText == "a")
        _ = shell.input(bytes("漢"))
        // A wide character takes two cells to rub out.
        #expect(shell.input([0x7F]) == bytes("\u{1B}[2D\u{1B}[K"))
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
        #expect(text(shell.input([0x03])).hasPrefix("^C\r\n"))
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
        #expect(joined.contains("$ echo hello\nhello\n"))
        #expect(joined.contains("bold italic underline strike inverse faint"))
        #expect(joined.contains("curly red curly dotted dashed double blink"))
        demo.stop()
    }
}
