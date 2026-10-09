@testable import SwifttyCore
import Synchronization
import Testing
import TestSupport

/// Milestone 3: shell integration and the smaller protocols.
struct ProtocolParityTests {
    @Test(arguments: ["", ";k=c", ";k=s"], [false, true])
    func `output at column zero replaces a prompt row mark`(_ kind: String, _ rewind: Bool) {
        var vt = VT(20, 5)
        vt.feed("\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}cmd\r\n\u{1B}]133;A\(kind)\u{7}> \u{1B}]133;B\u{7}")
        if rewind {
            vt.feed("\r")
        }
        for byte in "\u{1B}]133;C\u{7}result".utf8 {
            vt.feed(bytes: [byte])
        }
        let promptMark: RowMark = kind.isEmpty ? .prompt : .promptContinuation
        #expect(vt.state.mark(absoluteRow: 1) == (rewind ? .output : promptMark))
        #expect(vt.state.semanticState == .output)
        #expect(vt.state.inputStart == nil)
        vt.feed("\r\n\u{1B}]133;D;0\u{7}\u{1B}]133;A\u{7}$ ")
        if rewind {
            let range = vt.state.commandOutputRange(at: TerminalPoint(row: 1, column: 0))
            #expect(range?.start.row == 1 && range?.end.row == 1)
            #expect(TestFixture(vt.lines[1]) == TestFixture("result"))
        }
    }

    @Test(arguments: [0, 1, 2], [4, 6])
    func `full prompt redraw drops selections on cleared rows during height changes`(_ selectedRow: Int, _ newRows: Int) {
        var vt = VT(20, 5)
        vt.feed("out\r\n\u{1B}]133;A;redraw=1\u{7}first\r\n> \u{1B}]133;B\u{7}abc")
        let start = TerminalPoint(row: selectedRow, column: 0)
        vt.state.setSelection(Selection(anchor: start, head: TerminalPoint(row: selectedRow, column: 2)))
        vt.state.resize(columns: 20, rows: newRows)
        #expect(TestFixture(vt.lines[0]) == TestFixture("out"))
        #expect(TestFixture(vt.lines[1] == "" && vt.lines[2] == "") == TestFixture(true))
        if selectedRow == 0 {
            #expect(vt.state.selection?.start == start)
        } else {
            #expect(vt.state.selection == nil)
        }
    }

    @Test(arguments: ["0", "1", "last"])
    func `prompt redraw modes distinguish the final row from the full prompt`(_ mode: String) {
        var vt = VT(20, 5)
        vt.feed("out\r\n\u{1B}]133;A;redraw=\(mode)\u{7}first\r\n\u{1B}]133;A;k=s\u{7}> \u{1B}]133;B\u{7}abc")
        vt.feed("\(CSI)4;1Hbelow\(CSI)3;6H")
        vt.state.resize(columns: 30, rows: 5)
        #expect(TestFixture(vt.lines[0]) == TestFixture("out"))
        #expect(TestFixture(vt.lines[1]) == TestFixture(mode == "1" ? "" : "first"))
        #expect(TestFixture(vt.lines[2]) == TestFixture(mode == "0" ? "> abc" : ""))
        #expect(TestFixture(vt.lines[3]) == TestFixture(mode == "1" ? "" : "below"))
        if mode == "last" {
            #expect(vt.cursor == (5, 2))
            #expect(vt.state.inputStart == nil)
        }
    }

    @Test func `last row prompt redraw clears the cursor row after reflow`() {
        var vt = VT(6, 5)
        let report = "out\r\n\u{1B}]133;A;redraw=last\u{7}$ \u{1B}]133;B\u{7}abcdefghij"
        for byte in report.utf8 {
            vt.feed(bytes: [byte])
        }
        vt.state.resize(columns: 8, rows: 5)
        #expect(TestFixture(vt.lines[0]) == TestFixture("out"))
        #expect(TestFixture(vt.lines[1]) == TestFixture("$ abcdef"))
        #expect(TestFixture(vt.lines[2]) == TestFixture(""))
        #expect(vt.cursor == (4, 2))
        #expect(vt.state.inputStart == nil)
    }

    @Test(arguments: [1, 2])
    func `last row prompt redraw invalidates only selections on the cleared row`(_ selectedRow: Int) {
        var vt = VT(20, 5)
        vt.feed("out\r\n\u{1B}]133;A;redraw=last\u{7}first\r\n> \u{1B}]133;B\u{7}abc")
        let start = TerminalPoint(row: selectedRow, column: 0)
        vt.state.setSelection(Selection(anchor: start, head: TerminalPoint(row: selectedRow, column: 4)))
        vt.state.resize(columns: 20, rows: 6)
        #expect(TestFixture(vt.lines[1]) == TestFixture("first"))
        #expect(TestFixture(vt.lines[2]) == TestFixture(""))
        if selectedRow == 1 {
            #expect(vt.state.selection?.start == start)
            #expect(TestFixture(vt.state.text(from: start, to: TerminalPoint(row: selectedRow, column: 4))) == TestFixture("first"))
        } else {
            #expect(vt.state.selection == nil)
        }
    }

    @Test(arguments: ["", "2", "true", "false", "0oops", "1oops", "lastoops", " 0"])
    func `malformed prompt redraw options preserve the prior setting`(_ malformed: String) {
        for redraw in ["0", "1", "last"] {
            var vt = VT(20, 5)
            vt.feed("out\r\n\u{1B}]133;A;redraw=\(redraw)\u{7}$ \u{1B}]133;B\u{7}abc")
            let report = "\u{1B}]133;A;redraw=\(malformed)\u{7}\u{1B}]133;B\u{7}"
            for byte in report.utf8 {
                vt.feed(bytes: [byte])
            }
            vt.state.resize(columns: 10, rows: 5)
            #expect(TestFixture(vt.lines[0]) == TestFixture("out"))
            #expect(TestFixture(vt.lines[1]) == TestFixture(redraw == "0" ? "$ abc" : ""))
        }
    }

    @Test(arguments: [
        ("D;0", Optional(0)), ("D;-1", Optional(-1)), ("D;+12;aid=foo", Optional(12)),
        ("D;2147483647", Optional(2_147_483_647)), ("D;-2147483648", Optional(-2_147_483_648)),
        ("D;1234567", Optional(1_234_567)), ("D;12oops", nil), ("D;-4_2;aid=foo", nil),
        ("D;2147483648", nil), ("D;-2147483649", nil), ("D;999999999999999999999", nil),
        ("D;+", nil), ("D;;aid=foo", nil), ("D", nil),
    ] as [(String, Int?)])
    func `command completion parses the whole signed exit status field`(_ sample: (String, Int?)) {
        for split in [false, true] {
            var vt = VT(10, 2)
            vt.feed("\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}cmd\r\n\u{1B}]133;C\u{7}")
            _ = vt.state.takeEvents()
            let report = "\u{1B}]133;\(sample.0)\u{7}"
            if split {
                for byte in report.utf8 {
                    vt.feed(bytes: [byte])
                }
            } else {
                vt.feed(report)
            }
            #expect(vt.state.lastExitCode == sample.1)
            #expect(vt.state.semanticState == .none)
            let events = vt.state.takeEvents()
            #expect(events == [.commandFinished(exitCode: sample.1)])
        }
    }

    @Test func `semantic mark lookup rejects extreme rows after history eviction`() {
        var state = TerminalState(columns: 4, rows: 2, scrollbackLimitRows: 1)
        var parser = Parser()
        let output = Array("0\r\n1\r\n2\r\n3\r\n\u{1B}]133;A\u{7}$ ".utf8)
        parser.consume(output.span, into: &state)
        #expect(state.firstAbsoluteRow > 0)
        #expect(state.mark(absoluteRow: .min) == nil)
        #expect(state.mark(absoluteRow: .max) == nil)
        #expect(state.mark(absoluteRow: state.firstAbsoluteRow - 1) == nil)
        #expect(state.mark(absoluteRow: state.screenAbsoluteRow(1)) == .prompt)
    }

    @Test(arguments: [4, 6])
    func `click to move rejects negative columns on wrapped command rows`(_ columns: Int) {
        var vt = VT(columns, 4)
        vt.feed("\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}" + String(repeating: "a", count: columns * 2 + 1))
        let moves = vt.state.promptCursorMoves(to: TerminalPoint(row: 1, column: -1))
        #expect(moves == nil)
        let extreme = vt.state.promptCursorMoves(to: TerminalPoint(row: 1, column: .min))
        #expect(extreme == nil)
    }

    @Test(arguments: [4, 6])
    func `click to move bounds oversized columns to the chosen row`(_ columns: Int) {
        var vt = VT(columns, 4)
        vt.feed("\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}" + String(repeating: "a", count: columns * 2 + 1))
        let moves = vt.state.promptCursorMoves(to: TerminalPoint(row: 1, column: .max))
        #expect(moves == -3)
        let before = vt.state.promptCursorMoves(to: TerminalPoint(row: .min, column: 0))
        let after = vt.state.promptCursorMoves(to: TerminalPoint(row: .max, column: 0))
        #expect(before == nil && after == nil)
    }

    @Test func `pixel size reports clamp invalid and overflowing dimensions`() {
        var vt = VT(10, 5)
        vt.state.cellPixelSize = (Int.min, -1)
        vt.feed("\(CSI)14t\(CSI)16t")
        #expect(TestFixture(vt.takeOutput()) == TestFixture("\(CSI)4;0;0t\(CSI)6;0;0t"))
        vt.state.cellPixelSize = (Int.max, Int.max)
        vt.feed("\(CSI)14t\(CSI)16t\(CSI)?2048h")
        #expect(TestFixture(vt.takeOutput()) ==
            TestFixture("\(CSI)4;\(Int.max);\(Int.max)t\(CSI)6;\(Int.max);\(Int.max)t\(CSI)48;5;10;\(Int.max);\(Int.max)t"))
        vt.state.cellPixelSize = (8, 16)
        #expect(TestFixture(vt.takeOutput()) == TestFixture("\(CSI)48;5;10;80;80t"))
        vt.state.cellPixelSize = (8, 16)
        #expect(TestFixture(vt.takeOutput().isEmpty) == TestFixture(true))
    }

    @Test func `cell pixel changes publish in-band resize reports once`() {
        let session = TerminalSession(columns: 10, rows: 5)
        let replies = Mutex<[[UInt8]]>([])
        session.onTerminalReply = { bytes in replies.withLock { $0.append(bytes) } }
        session.setCellPixelSize(width: 8, height: 16)
        session.feed(Array("\u{1B}[?2048h".utf8))
        _ = session.snapshot()
        replies.withLock { $0.removeAll() }
        session.setCellPixelSize(width: 10, height: 20)
        _ = session.snapshot()
        #expect(TestFixture(replies.withLock { $0 }) == TestFixture([Array("\u{1B}[48;5;10;100;100t".utf8)]))
        session.setCellPixelSize(width: 10, height: 20)
        _ = session.snapshot()
        #expect(replies.withLock { $0.count } == 1)
        session.feed(Array("\u{1B}[?2048l".utf8))
        session.setCellPixelSize(width: 12, height: 24)
        _ = session.snapshot()
        #expect(replies.withLock { $0.count } == 1)
    }

    let promptA = "\u{1B}]133;A\u{07}", inputB = "\u{1B}]133;B\u{07}", outputC = "\u{1B}]133;C\u{07}"

    func doneD(_ code: Int) -> String {
        "\u{1B}]133;D;\(code)\u{07}"
    }

    /// Two commands with output, then a third prompt being edited.
    func session(_ vt: inout VT) {
        vt.feed("\(promptA)$ \(inputB)ls\r\n\(outputC)a\r\nb\r\n\(doneD(0))")
        vt.feed("\(promptA)$ \(inputB)false\r\n\(outputC)\(doneD(1))")
        vt.feed("\(promptA)$ \(inputB)echo hi")
    }

    @Test func `semantic prompts mark rows and track state`() {
        var vt = VT(20, 10)
        session(&vt)
        do { let ok = vt.state.grid.mark(0) == .prompt; #expect(ok) }
        do { let ok = vt.state.grid.mark(1) == .output; #expect(ok) }
        do { let ok = vt.state.grid.mark(3) == .prompt; #expect(ok) }
        do { let ok = vt.state.grid.mark(4) == .prompt; #expect(ok) } // no output: the next prompt takes the row
        do { let ok = vt.state.semanticState == .input; #expect(ok) }
        do { let ok = vt.state.lastExitCode == 1; #expect(ok) }
        do { let ok = vt.state.takeEvents().contains(.commandFinished(exitCode: 1)); #expect(ok) }
        do { let ok = vt.state.promptRows() == [0, 3, 4]; #expect(ok) }
    }

    @Test func `command output range`() throws {
        var vt = VT(20, 10)
        session(&vt)
        let range = vt.state.commandOutputRange(at: TerminalPoint(row: 0, column: 3))
        #expect(range?.start.row == 1 && range?.end.row == 2)
        do { let ok = try vt.state.text(from: #require(range?.start), to: #require(range?.end)) == "a\nb"; #expect(ok) }
        // From inside the output too.
        do { let ok = vt.state.commandOutputRange(at: TerminalPoint(row: 2, column: 0))?.start.row == 1; #expect(ok) }
    }

    @Test func `marks survive scrolling and reflow`() {
        var vt = VT(10, 3)
        vt.feed("\(promptA)$ \(inputB)x\r\n\(outputC)1\r\n2\r\n3\r\n\(doneD(0))\(promptA)$ ")
        do { let ok = vt.state.promptRows().count == 2; #expect(ok) }
        vt.state.resize(columns: 5, rows: 3)
        do { let ok = vt.state.promptRows().count == 2; #expect(ok) }
        let first = vt.state.promptRows()[0]
        do { let ok = vt.state.mark(absoluteRow: first + 1) == .output; #expect(ok) }
    }

    @Test func `jump to prompt scrolls the viewport`() {
        var vt = VT(10, 3)
        for i in 0 ..< 5 {
            vt.feed("\(promptA)$ \(inputB)c\(i)\r\n\(outputC)o\r\n\(doneD(0))")
        }
        vt.feed("\(promptA)$ ")
        let prompts = vt.state.promptRows()
        #expect(prompts.count == 6)
        do { let ok = vt.state.jumpToPrompt(-1); #expect(ok) }
        // prompts[4] is already the top row.
        do { let ok = vt.state.absoluteRow(viewportRow: 0) == prompts[3]; #expect(ok) }
        do { let ok = vt.state.jumpToPrompt(-2); #expect(ok) }
        do { let ok = vt.state.absoluteRow(viewportRow: 0) == prompts[1]; #expect(ok) }
        do { let ok = vt.state.jumpToPrompt(1); #expect(ok) }
        do { let ok = vt.state.absoluteRow(viewportRow: 0) == prompts[2]; #expect(ok) }
        do { let ok = !vt.state.jumpToPrompt(-10); #expect(ok) }
    }

    @Test func `jump to prompt fails when the target cannot move the viewport`() {
        var vt = VT(10, 3)
        vt.feed("\(promptA)$ \(inputB)c\r\n\(outputC)o\r\n\(doneD(0))\(promptA)$ ")
        #expect(vt.state.promptRows() == [0, 2])
        #expect(vt.state.viewportOffset == 0)
        let moved = vt.state.jumpToPrompt(1)
        #expect(!moved)
        #expect(vt.state.viewportOffset == 0)
    }

    @Test func `click to move the shell cursor`() {
        var vt = VT(20, 5)
        vt.feed("\(promptA)$ \(inputB)echo hello\(CSI)5D") // cursor on the "h" of "hello"
        let row = vt.state.screenAbsoluteRow(0)
        #expect(vt.cursor == (7, 0))
        do { let ok = vt.state.promptCursorMoves(to: TerminalPoint(row: row, column: 2)) == -5; #expect(ok) }
        do { let ok = vt.state.promptCursorMoves(to: TerminalPoint(row: row, column: 10)) == 3; #expect(ok) }
        do { let ok = vt.state.promptCursorMoves(to: TerminalPoint(row: row, column: 19)) == 5; #expect(ok) } // clamped to the end
        do { let ok = vt.state.promptCursorMoves(to: TerminalPoint(row: row, column: 0)) == nil; #expect(ok) } // on the prompt
        vt.feed("\r\n\(outputC)")
        do { let ok = vt.state.promptCursorMoves(to: TerminalPoint(row: row, column: 3)) == nil; #expect(ok) }
    }

    @Test func `click to move counts wide characters once`() {
        var vt = VT(20, 5)
        vt.feed("\(promptA)$ \(inputB)中文x")
        let row = vt.state.screenAbsoluteRow(0)
        do { let ok = vt.state.promptCursorMoves(to: TerminalPoint(row: row, column: 2)) == -3; #expect(ok) }
    }

    @Test func `prompt is cleared on resize when the shell redraws it`() {
        var vt = VT(20, 5)
        vt.feed("out\r\n\u{1B}]133;A;redraw=1\u{07}$ \(inputB)abc")
        vt.state.resize(columns: 10, rows: 5)
        #expect(TestFixture(vt.lines[0] == "out" && vt.lines[1] == "") == TestFixture(true))
        #expect(vt.cursor == (0, 1))
        // Without redraw=1 the prompt is kept.
        var keep = VT(20, 5)
        keep.feed("out\r\n\(promptA)$ \(inputB)abc")
        keep.state.resize(columns: 10, rows: 5)
        #expect(TestFixture(keep.lines[1]) == TestFixture("$ abc"))
    }

    @Test func `title stack`() {
        var vt = VT()
        vt.feed("\u{1B}]2;one\u{07}\(CSI)22;0t\u{1B}]2;two\u{07}")
        do { let ok = vt.state.title == "two"; #expect(ok) }
        vt.feed("\(CSI)23;0t")
        do { let ok = vt.state.title == "one"; #expect(ok) }
        do { let ok = vt.state.takeEvents().last == .title("one"); #expect(ok) }
        vt.feed("\(CSI)23;0t") // empty stack: no change
        do { let ok = vt.state.title == "one"; #expect(ok) }
    }

    @Test func `push and pop SGR`() {
        var vt = VT()
        vt.feed("\(CSI)1;31m\(CSI)#{\(CSI)0;4;32mx\(CSI)#}y")
        #expect(vt.cell(0, 0).attributes.flags.contains(.underline))
        let y = vt.cell(1, 0).attributes
        #expect(y.flags.contains(.bold) && !y.flags.contains(.underline))
        #expect(y.foreground == .palette(1))
        vt.feed("\(CSI)#p\(CSI)0m\(CSI)#qz")
        #expect(vt.cell(2, 0).attributes.flags.contains(.bold))
    }

    @Test func `color scheme reports`() {
        var vt = VT()
        vt.feed("\(CSI)?996n")
        #expect(TestFixture(vt.takeOutput()) == TestFixture("\(CSI)?997;1n"))
        vt.state.setColorScheme(.light)
        #expect(TestFixture(vt.takeOutput()) == TestFixture("")) // not subscribed
        vt.feed("\(CSI)?2031h")
        vt.state.setColorScheme(.dark)
        #expect(TestFixture(vt.takeOutput()) == TestFixture("\(CSI)?997;1n"))
        vt.feed("\(CSI)?2031$p")
        #expect(TestFixture(vt.takeOutput()) == TestFixture("\(CSI)?2031;1$y"))
    }

    @Test func `in-band resize reports`() {
        var vt = VT(10, 5)
        vt.state.cellPixelSize = (8, 16)
        vt.feed("\(CSI)?2048h")
        #expect(TestFixture(vt.takeOutput()) == TestFixture("\(CSI)48;5;10;80;80t"))
        vt.state.resize(columns: 20, rows: 4)
        #expect(TestFixture(vt.takeOutput()) == TestFixture("\(CSI)48;4;20;64;160t"))
        vt.feed("\(CSI)?2048l")
        vt.state.resize(columns: 10, rows: 4)
        #expect(TestFixture(vt.takeOutput()) == TestFixture(""))
    }

    @Test func `pointer shape events`() {
        var vt = VT()
        vt.feed("\u{1B}]22;pointer\u{07}\u{1B}]22;pointer\u{07}\u{1B}]22;\u{07}")
        do { let ok = vt.state.takeEvents() == [.pointerShape("pointer"), .pointerShape("default")]; #expect(ok) }
    }

    @Test(arguments: ["pointer", "none", "crosshair", "default"], [false, true])
    func `reset notifies the frontend when clearing a pointer shape`(_ shape: String, _ useAPI: Bool) {
        var vt = VT()
        vt.feed("\u{1B}]22;\(shape)\u{7}")
        let initial = vt.state.takeEvents()
        #expect(initial == [.pointerShape(shape)])
        if useAPI {
            vt.state.reset()
        } else {
            vt.feed("\u{1B}c")
        }
        #expect(vt.state.pointerShape.isEmpty)
        let resetEvents = vt.state.takeEvents()
        #expect(resetEvents == [.pointerShape("")])
        vt.state.reset()
        let repeated = vt.state.takeEvents()
        #expect(repeated.isEmpty)
    }

    @Test func `kitty color protocol`() {
        var vt = VT()
        vt.feed("\u{1B}]21;foreground=#102030;selection_background=#ff0000;1=#00ff00\u{1B}\\")
        do { let ok = vt.state.palette.foreground == 0x102030; #expect(ok) }
        do { let ok = vt.state.palette.selectionBackground == 0xFF0000; #expect(ok) }
        do { let ok = vt.state.palette.colors[1] == 0x00FF00; #expect(ok) }
        vt.feed("\u{1B}]21;foreground=?;cursor_text=?;bogus=?\u{1B}\\")
        #expect(TestFixture(vt.takeOutput()) == TestFixture("\u{1B}]21;foreground=rgb:1010/2020/3030;cursor_text=;bogus=\u{1B}\\"))
        vt.feed("\u{1B}]21;foreground=;selection_background=;1=\u{07}")
        do { let ok = vt.state.palette.foreground == Palette.standard.foreground; #expect(ok) }
        do { let ok = vt.state.palette.selectionBackground == nil; #expect(ok) }
        do { let ok = vt.state.palette.colors[1] == Palette.standard.colors[1]; #expect(ok) }
    }

    @Test func `underline color is stored per cell`() {
        var vt = VT()
        vt.feed("\(CSI)4:3;58;2;255;0;0;31ma\(CSI)58;5;4mb\(CSI)59mc\(CSI)39md")
        let a = vt.cell(0, 0).attributes
        #expect(a.flags.contains(.underlineStyleA))
        #expect(a.foreground == .palette(1))
        do { let ok = vt.state.underlineColor(a.underlineColor) == .rgb(255, 0, 0); #expect(ok) }
        do { let ok = vt.state.underlineColor(vt.cell(1, 0).attributes.underlineColor) == .palette(4); #expect(ok) }
        #expect(vt.cell(2, 0).attributes.underlineColor == 0)
        // Changing the text color keeps the underline color and vice versa.
        var pen = CellAttributes(foreground: .palette(2))
        pen.underlineColor = 5
        pen.foreground = .rgb(1, 2, 3)
        #expect(pen.underlineColor == 5 && pen.foreground == .rgb(1, 2, 3))
        #expect(!Cell(glyph: 0, attributes: pen, width: 1).isBlank)
    }

    @Test func `kitty alternate keys`() {
        var out: [UInt8] = []
        let event = KeyEvent(.character("a"), modifiers: [.shift, .control], shiftedKey: "A", baseLayoutKey: "q")
        #expect(TestFixture(InputEncoder.encode(.key(event), modes: .initial, keyboardFlags: 1 | 4, into: &out)) == TestFixture(true))
        #expect(TestFixture(String(decoding: out, as: UTF8.self)) == TestFixture("\(CSI)97:65:113;6u"))
        out = []
        let unshifted = KeyEvent(.character("a"), modifiers: .control, shiftedKey: "A", baseLayoutKey: "q")
        _ = InputEncoder.encode(.key(unshifted), modes: .initial, keyboardFlags: 1 | 4, into: &out)
        #expect(TestFixture(String(decoding: out, as: UTF8.self)) == TestFixture("\(CSI)97::113;5u"))
        out = []
        _ = InputEncoder.encode(.key(unshifted), modes: .initial, keyboardFlags: 1, into: &out)
        #expect(TestFixture(String(decoding: out, as: UTF8.self)) == TestFixture("\(CSI)97;5u"))
    }

    @Test func `reset clears shell state`() {
        var vt = VT()
        vt.feed("\(promptA)$ \(inputB)\(CSI)22t\(CSI)58;5;1m\(ESC)c")
        do { let ok = vt.state.semanticState == .none; #expect(ok) }
        do { let ok = vt.state.underlineColor(1) == nil; #expect(ok) }
    }
}

struct LinkTests {
    @Test func `OSC 8 hyperlinks`() {
        var vt = VT(20, 2)
        vt.feed("go \u{1B}]8;;https://example.com\u{07}here\u{1B}]8;;\u{07} now")
        do {
            let link = vt.state.link(at: TerminalPoint(row: 0, column: 4))
            #expect(link?.url == "https://example.com" && link?.range.start.column == 3 && link?.range.end.column == 6)
        }
        do { let ok = vt.state.link(at: TerminalPoint(row: 0, column: 9), detectURLs: false) == nil; #expect(ok) }
    }

    @Test func `detected URLs follow wraps and trim punctuation`() {
        var vt = VT(12, 3)
        vt.feed("see https://a.example/x_(y). ok")
        do {
            let link = vt.state.link(at: TerminalPoint(row: 1, column: 2))
            #expect(link?.url == "https://a.example/x_(y)")
            #expect(link?.range.start == TerminalPoint(row: 0, column: 4))
        }
        do { let ok = vt.state.link(at: TerminalPoint(row: 0, column: 1)) == nil; #expect(ok) }
        do { let ok = vt.state.link(at: TerminalPoint(row: 1, column: 2), detectURLs: false) == nil; #expect(ok) }
    }

    @Test(arguments: ["HTTP", "Https", "FTP", "sSh", "GIT", "FILE", "MAILTO"])
    func `detected URL schemes ignore case while preserving the target`(_ scheme: String) {
        let target = scheme == "MAILTO" ? "MAILTO:User@Example.test" : scheme + "://Example.test/CaseSensitive"
        var vt = VT(17, 4)
        vt.feed("see " + target + ". ok")
        let link = vt.state.link(at: TerminalPoint(row: 0, column: 4))
        #expect(link?.url == target)
        #expect(link?.range.start == TerminalPoint(row: 0, column: 4))
        let opens = LinkPolicy.openableURL(target) != nil
        #expect(opens == (scheme != "FILE" && scheme != "GIT"))
    }
}

/// Fixes from the review of milestones 2-4.
struct ShellIntegrationReviewTests {
    let promptA = "\u{1B}]133;A\u{07}", inputB = "\u{1B}]133;B\u{07}", outputC = "\u{1B}]133;C\u{07}"

    @Test func `long prompts mark the logical line already in history`() {
        var vt = VT(10, 2)
        vt.feed(promptA + String(repeating: "p", count: 30) + inputB + "abc")
        let start = TerminalPoint(row: 3, column: 0)
        #expect(vt.state.inputStart == start)
        let moves = vt.state.promptCursorMoves(to: start)
        #expect(moves == -3)
    }

    @Test func `evicted command origins disable click to move`() {
        var state = TerminalState(columns: 10, rows: 2, scrollbackLimitRows: 1)
        var parser = Parser()
        let bytes = Array(("\(promptA)$ \(inputB)" + String(repeating: "a", count: 40)).utf8)
        bytes.withUnsafeBufferPointer { parser.consume($0, into: &state) }
        #expect(state.inputStart == nil)
    }

    @Test func `click to move follows long input into history`() {
        var vt = VT(10, 2)
        vt.feed("\(promptA)$ \(inputB)" + String(repeating: "a", count: 30))
        let start = TerminalPoint(row: 0, column: 2)
        #expect(vt.state.inputStart == start)
        let moves = vt.state.promptCursorMoves(to: start)
        #expect(moves == -30)
        vt.state.resize(columns: 8, rows: 2)
        #expect(vt.state.inputStart == start)
        let reflowedMoves = vt.state.promptCursorMoves(to: start)
        #expect(reflowedMoves == -30)
        vt.feed("Z")
        let afterWrap = vt.state.promptCursorMoves(to: start)
        #expect(afterWrap == -31)
        let end = TerminalPoint(row: vt.state.screenAbsoluteRow(vt.state.cursor.y), column: vt.state.cursor.x)
        let input = vt.state.text(from: start, to: end)
        #expect(input == String(repeating: "a", count: 30) + "Z")
        vt.feed("\(outputC)\r\n\(promptA)$ \(inputB)new")
        let newStart = vt.state.inputStart
        #expect(newStart != nil && newStart != start)
        let staleMoves = vt.state.promptCursorMoves(to: start)
        #expect(staleMoves == nil)
    }

    @Test func `erasing the screen drops prompt marks`() {
        var vt = VT(20, 6)
        vt.feed("\(promptA)$ \(inputB)ls\r\n\(outputC)a\r\n\(promptA)$ \(inputB)x\r\n")
        do { let ok = vt.state.promptRows().count == 2; #expect(ok) }
        vt.feed("\(CSI)H\(CSI)2J")
        do { let ok = vt.state.promptRows().isEmpty; #expect(ok) }
        do { let ok = vt.state.hasSemanticPrompts; #expect(ok) }
        vt.feed("\(promptA)$ \(inputB)y\r\n\(outputC)out\r\nmore\r\n")
        do { let ok = vt.state.promptRows() == [vt.state.screenAbsoluteRow(0)]; #expect(ok) }
        let range = vt.state.commandOutputRange(at: TerminalPoint(row: vt.state.screenAbsoluteRow(0), column: 0))
        #expect(range?.end.row == vt.state.screenAbsoluteRow(2))
    }

    @Test func `clear screen keeping the cursor line drops marks below it`() {
        var vt = VT(20, 6)
        vt.feed("\(promptA)$ \(inputB)ls\r\n\(outputC)a\r\n\(promptA)$ \(inputB)x")
        vt.state.clearScreenKeepingCursorLine()
        do { let ok = vt.state.promptRows() == [vt.state.screenAbsoluteRow(0)]; #expect(ok) }
        // The command line moved to the top; click-to-move follows it.
        let row = vt.state.screenAbsoluteRow(0)
        do { let ok = vt.state.promptCursorMoves(to: TerminalPoint(row: row, column: 2)) == -1; #expect(ok) }
    }

    @Test func `click to move survives a width change`() throws {
        var vt = VT(20, 4)
        vt.feed("out\r\n\(promptA)$ \(inputB)echo hello world")
        vt.state.resize(columns: 10, rows: 4) // the command line now wraps
        let start = vt.state.inputStart
        #expect(start?.column == 2)
        let cursor = (vt.state.screenAbsoluteRow(vt.state.cursor.y), vt.state.cursor.x)
        // Back to the start of "hello": 11 characters ("hello world").
        let target = try TerminalPoint(row: #require(start?.row), column: 7)
        do { let ok = vt.state.promptCursorMoves(to: target) == -11; #expect(ok) }
        #expect(cursor.0 > start!.row)
        // Typing on wraps past the bottom and scrolls; the start stays put.
        vt.feed(" and more text")
        do { let ok = vt.state.scrollbackCount > 0; #expect(ok) }
        do { let ok = vt.state.inputStart == start; #expect(ok) }
    }

    @Test func `keybind actions may contain equals signs`() {
        var b = Keybindings()
        #expect(TestFixture(b.apply("ctrl+e=text:export A=1\\n")) == TestFixture(nil))
        #expect(TestFixture(b.action(for: KeyEvent(.character("e"), modifiers: .control))) == TestFixture(.text("export A=1\n")))
        #expect(b.apply("super+==increase_font_size:2") == nil)
        #expect(b.action(for: KeyEvent(.character("="), modifiers: .command)) == .increaseFontSize(2))
        #expect(b.apply("ctrl+k=csi:=1u") == nil)
        #expect(b.action(for: KeyEvent(.character("k"), modifiers: .control)) == .csi("=1u"))
    }

    @Test func `command quoting supports argument splitting and shell execution`() {
        #expect(Configuration.arguments(#""/Users/me/My Tools/fish" -l"#) == ["/Users/me/My Tools/fish", "-l"])
        #expect(Configuration.arguments(#"sh -c 'echo  hi'"#) == ["sh", "-c", "echo  hi"])
        #expect(Configuration.arguments(#"a\ b "c\"d" '' e"#) == ["a b", "c\"d", "", "e"])
        #expect(Configuration.parse("command = \"/opt/my shell\" --login").sessionConfiguration().command == [
            "/bin/bash", "--noprofile", "--norc", "-c", "exec -l \"/opt/my shell\" --login",
        ])
    }

    @Test func `only web, mail, ftp and ssh links open`() {
        #expect(LinkPolicy.openableURL("https://example.com") != nil)
        #expect(LinkPolicy.openableURL("file:///Users/x/evil.command") == nil)
        #expect(LinkPolicy.openableURL("javascript:alert(1)") == nil)
        #expect(ActionDispatch.viewportDelta(for: .scrollPageUp, rows: 24, history: 100) == 24)
    }
}
