@testable import SwifttyCore
import Testing

/// Milestone 3: shell integration and the smaller protocols.
struct ProtocolParityTests {
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
        #expect(vt.lines[0] == "out" && vt.lines[1] == "")
        #expect(vt.cursor == (0, 1))
        // Without redraw=1 the prompt is kept.
        var keep = VT(20, 5)
        keep.feed("out\r\n\(promptA)$ \(inputB)abc")
        keep.state.resize(columns: 10, rows: 5)
        #expect(keep.lines[1] == "$ abc")
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
        #expect(vt.takeOutput() == "\(CSI)?997;1n")
        vt.state.setColorScheme(.light)
        #expect(vt.takeOutput() == "") // not subscribed
        vt.feed("\(CSI)?2031h")
        vt.state.setColorScheme(.dark)
        #expect(vt.takeOutput() == "\(CSI)?997;1n")
        vt.feed("\(CSI)?2031$p")
        #expect(vt.takeOutput() == "\(CSI)?2031;1$y")
    }

    @Test func `in-band resize reports`() {
        var vt = VT(10, 5)
        vt.state.cellPixelSize = (8, 16)
        vt.feed("\(CSI)?2048h")
        #expect(vt.takeOutput() == "\(CSI)48;5;10;80;80t")
        vt.state.resize(columns: 20, rows: 4)
        #expect(vt.takeOutput() == "\(CSI)48;4;20;64;160t")
        vt.feed("\(CSI)?2048l")
        vt.state.resize(columns: 10, rows: 4)
        #expect(vt.takeOutput() == "")
    }

    @Test func `pointer shape events`() {
        var vt = VT()
        vt.feed("\u{1B}]22;pointer\u{07}\u{1B}]22;pointer\u{07}\u{1B}]22;\u{07}")
        do { let ok = vt.state.takeEvents() == [.pointerShape("pointer"), .pointerShape("default")]; #expect(ok) }
    }

    @Test func `kitty color protocol`() {
        var vt = VT()
        vt.feed("\u{1B}]21;foreground=#102030;selection_background=#ff0000;1=#00ff00\u{1B}\\")
        do { let ok = vt.state.palette.foreground == 0x102030; #expect(ok) }
        do { let ok = vt.state.palette.selectionBackground == 0xFF0000; #expect(ok) }
        do { let ok = vt.state.palette.colors[1] == 0x00FF00; #expect(ok) }
        vt.feed("\u{1B}]21;foreground=?;cursor_text=?;bogus=?\u{1B}\\")
        #expect(vt.takeOutput() == "\u{1B}]21;foreground=rgb:1010/2020/3030;cursor_text=;bogus=\u{1B}\\")
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
        #expect(InputEncoder.encode(.key(event), modes: .initial, keyboardFlags: 1 | 4, into: &out))
        #expect(String(decoding: out, as: UTF8.self) == "\(CSI)97:65:113;6u")
        out = []
        let unshifted = KeyEvent(.character("a"), modifiers: .control, shiftedKey: "A", baseLayoutKey: "q")
        _ = InputEncoder.encode(.key(unshifted), modes: .initial, keyboardFlags: 1 | 4, into: &out)
        #expect(String(decoding: out, as: UTF8.self) == "\(CSI)97::113;5u")
        out = []
        _ = InputEncoder.encode(.key(unshifted), modes: .initial, keyboardFlags: 1, into: &out)
        #expect(String(decoding: out, as: UTF8.self) == "\(CSI)97;5u")
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
}
