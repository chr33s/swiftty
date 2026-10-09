@testable import SwifttyCore
import Testing
import TestSupport

struct DCSTests {
    @Test(arguments: ["7", "8", "999", "65535", "3;2", "3:2"], [false, true])
    func `invalid cursor styles leave presentation and status replies unchanged`(_ parameters: String, _ fragmented: Bool) {
        for alternate in [false, true] {
            for style in 0 ... 6 {
                var vt = VT(8, 3)
                if alternate {
                    vt.feed("\(CSI)?1049h")
                }
                vt.feed("\(CSI)\(style) q\(CSI)2;3H\(CSI)1;31m")
                let cursor = vt.state.cursor
                let shape = vt.state.cursorStyle
                let modes = vt.state.modes
                _ = vt.state.takeDamage()
                let command = "\(CSI)\(parameters) q"
                if fragmented {
                    for byte in command.utf8 {
                        vt.feed(bytes: [byte])
                    }
                } else {
                    vt.feed(command)
                }
                #expect(vt.state.cursor == cursor)
                #expect(vt.state.cursorStyle == shape)
                #expect(vt.state.modes == modes)
                let damage = vt.state.takeDamage()
                #expect(damage.isEmpty)
                vt.feed("\(ESC)P$q q\(ESC)\\")
                #expect(TestFixture(vt.takeOutput()) == TestFixture("\(ESC)P1$r\(max(1, style)) q\(ESC)\\"))
                vt.feed("X")
                #expect(vt.cell(2, 1).glyph == 0x58)
                #expect(vt.cell(2, 1).attributes == cursor.pen)
            }
        }
    }

    @Test(arguments: [
        ("$q", "m", "\u{1B}P1$r0m\u{1B}\\"),
        ("+q", "544E", "\u{1B}P1+r544E=787465726D2D323536636F6C6F72\u{1B}\\"),
    ].map(TestFixture.init), [false, true])
    func `DCS ignores DEL in query bodies`(_ fixture: TestFixture<(String, String, String)>, _ split: Bool) {
        let fixture = fixture.value
        var vt = VT(8, 3)
        let body = [UInt8(0x7F)] + fixture.1.utf8.flatMap { [$0, UInt8(0x7F)] }
        let input = Array(("\(ESC)P" + fixture.0).utf8) + body + Array("\(ESC)\\ok".utf8)
        if split {
            for byte in input {
                vt.feed(bytes: [byte])
            }
        } else {
            vt.feed(bytes: input)
        }
        #expect(TestFixture(vt.takeOutput()) == TestFixture(fixture.2))
        #expect(TestFixture(vt.lines) == TestFixture(["ok", "", ""]))
    }

    @Test(arguments: [4096, 4097])
    func `ignored DEL bytes do not exhaust the DCS request limit`(_ count: Int) {
        var vt = VT(8, 3)
        vt.feed("\(ESC)P$q")
        vt.feed(bytes: [UInt8](repeating: 0x7F, count: count))
        vt.feed("m\(ESC)\\")
        #expect(TestFixture(vt.takeOutput()) == TestFixture("\(ESC)P1$r0m\(ESC)\\"))
    }

    @Test(arguments: [false, true])
    func `tmux raw control mode preserves DEL bytes`(_ split: Bool) {
        var vt = VT(8, 3)
        let body = "%output %1 a\u{7F}b\r\n%exit\n"
        let input = "\(ESC)P1000p" + body + "\(ESC)\\ok"
        if split {
            for byte in input.utf8 {
                vt.feed(bytes: [byte])
            }
        } else {
            vt.feed(input)
        }
        #expect(vt.state.controlModeData == Array(body.utf8))
        #expect(vt.state.events == [.controlModeStarted, .controlModeEnded])
        #expect(TestFixture(vt.lines) == TestFixture(["ok", "", ""]))
    }

    @Test(arguments: ["$ qm", "+ q544E"], [false, true])
    func `multiple DCS intermediates do not hook prefix requests`(_ request: String, _ split: Bool) {
        var vt = VT(8, 3)
        let input = "\(ESC)P" + request + "\(ESC)\\ok"
        if split {
            for byte in input.utf8 {
                vt.feed(bytes: [byte])
            }
        } else {
            vt.feed(input)
        }
        #expect(TestFixture(vt.takeOutput().isEmpty) == TestFixture(true))
        #expect(TestFixture(vt.lines) == TestFixture(["ok", "", ""]))
    }

    @Test(arguments: ["$qm", "+q544E", "p%exit\r\n"].map(TestFixture.init), [25, 48])
    func `DCS parameter overflow does not hook a truncated request`(_ request: TestFixture<String>, _ count: Int) {
        let request = request.value
        var vt = VT(8, 3)
        let parameters = ["1000"] + Array(repeating: "0", count: count - 1)
        let input = "\(ESC)P" + parameters.joined(separator: ";") + request + "\(ESC)\\ok"
        for byte in input.utf8 {
            vt.feed(bytes: [byte])
        }
        #expect(TestFixture(vt.takeOutput().isEmpty) == TestFixture(true))
        #expect(vt.state.events.isEmpty)
        let controlMode = vt.state.isControlMode
        #expect(!controlMode)
        #expect(vt.state.controlModeData.isEmpty)
        #expect(TestFixture(vt.lines[0]) == TestFixture("ok"))
    }

    @Test(arguments: [4096, 4097])
    func `DCS request bodies accept the exact limit and discard overflow`(_ size: Int) {
        var vt = VT(20, 3)
        vt.feed("\(ESC)P$q")
        vt.feed(bytes: [UInt8](repeating: 0x78, count: size))
        vt.feed("\(ESC)\\")
        #expect(TestFixture(vt.takeOutput()) == TestFixture(size == 4096 ? "\(ESC)P0$r\(ESC)\\" : ""))
    }

    @Test(arguments: ["$qm", "+q544E"].map(TestFixture.init), ["\u{18}", "\u{1A}", "\u{1B}[31m"].map(TestFixture.init))
    func `cancelled DCS requests do not produce replies`(_ request: TestFixture<String>, _ cancel: TestFixture<String>) {
        let request = request.value
        let cancel = cancel.value
        var vt = VT(20, 3)
        vt.feed("\(ESC)P\(request)")
        for byte in cancel.utf8 {
            vt.feed(bytes: [byte])
        }
        vt.feed("ok")
        #expect(TestFixture(vt.takeOutput().isEmpty) == TestFixture(true))
        #expect(TestFixture(vt.lines[0]) == TestFixture("ok"))
        vt.feed("\(ESC)P$qm\(ESC)\\")
        #expect(TestFixture(vt.takeOutput().hasPrefix("\(ESC)P1$r")) == TestFixture(true))
    }

    @Test(arguments: ["$qm", "+q544E"], [1, 4096, 8192])
    func `oversized DCS requests are discarded across read boundaries`(_ request: String, _ chunk: Int) {
        var vt = VT(20, 3)
        vt.feed("\(ESC)P\(request)")
        let body = [UInt8](repeating: 0x78, count: 4096)
        for start in stride(from: 0, to: body.count, by: chunk) {
            vt.feed(bytes: Array(body[start ..< min(body.count, start + chunk)]))
        }
        vt.feed("r\(ESC)\\ok")
        #expect(TestFixture(vt.takeOutput().isEmpty) == TestFixture(true))
        #expect(TestFixture(vt.lines[0]) == TestFixture("ok"))
        vt.feed("\(ESC)P$qm\(ESC)\\")
        #expect(TestFixture(vt.takeOutput()) == TestFixture("\(ESC)P1$r0m\(ESC)\\"))
    }

    @Test(arguments: ["544E0", "544Egg", "544EZZ", "544E1z"])
    func `invalid termcap hex cannot match a valid prefix`(_ name: String) {
        var vt = VT(20, 3)
        vt.feed("\(ESC)P+q\(name)\(ESC)\\")
        #expect(TestFixture(vt.takeOutput()) == TestFixture("\(ESC)P0+r\(name)\(ESC)\\"))
    }

    @Test(arguments: ["\u{07}", "\u{1B}\\"].map(TestFixture.init))
    func `oversized OSC strings do not replace the title with a truncated value`(_ terminator: TestFixture<String>) {
        let terminator = terminator.value
        var vt = VT(20, 3)
        vt.feed("\(ESC)]0;original\u{07}\(ESC)]0;")
        vt.feed(bytes: [UInt8](repeating: 0x78, count: Parser.maxOSCBytes))
        vt.feed(terminator + "ok")
        #expect(vt.state.title == "original")
        #expect(TestFixture(vt.lines[0]) == TestFixture("ok"))
        vt.feed("\(ESC)]0;next\u{07}")
        #expect(vt.state.title == "next")
    }

    @Test func `decrqss SGR preserves underline colors`() {
        for (setting, expected) in [("58;5;123", "58:5:123"), ("58;2;12;34;56", "58:2::12:34:56")] {
            var vt = VT(20, 3)
            vt.feed("\(CSI)4:3;\(setting)m\(ESC)P$qm\(ESC)\\")
            #expect(TestFixture(vt.takeOutput()) == TestFixture("\(ESC)P1$r0;4:3;\(expected)m\(ESC)\\"))
            vt.feed("\(CSI)59m\(ESC)P$qm\(ESC)\\")
            #expect(TestFixture(vt.takeOutput()) == TestFixture("\(ESC)P1$r0;4:3m\(ESC)\\"))
        }
    }

    @Test func `tmux control mode streams raw lines`() {
        var vt = VT(20, 3)
        vt.feed("a\(ESC)P1000p%begin 1 2 0\r\n%end 1 2 0\r\n")
        let open = vt.state.isControlMode
        #expect(open)
        let started = vt.state.takeEvents()
        #expect(started == [.controlModeStarted])
        vt.feed("%output %1 hi\\033[m\r\n\(ESC)\\b")
        let data = String(decoding: vt.state.controlModeData, as: UTF8.self)
        #expect(TestFixture(data) == TestFixture("%begin 1 2 0\r\n%end 1 2 0\r\n%output %1 hi\\033[m\r\n"))
        let closed = !vt.state.isControlMode
        #expect(closed)
        let ended = vt.state.takeEvents()
        #expect(ended == [.controlModeEnded])
        #expect(TestFixture(vt.lines[0]) == TestFixture("ab"))
    }

    @Test func `control mode blocks carry raw escapes`() {
        var vt = VT(20, 3)
        // capture-pane -e output: SGR at a line start and mid-line, a
        // mid-line ST (OSC 8), and a UTF-8 glyph with a 0x9D byte (❯).
        let block = "%begin 1 3 1\n\(ESC)[35m❯\(ESC)[39m x\(ESC)]8;;u\(ESC)\\y\n\(ESC)[0m\n%end 1 3 1\n"
        vt.feed("\(ESC)P1000p" + block)
        vt.feed("%exit\n\(ESC)\\z")
        let data = String(decoding: vt.state.controlModeData, as: UTF8.self)
        #expect(TestFixture(data) == TestFixture(block + "%exit\n"))
        let events = vt.state.takeEvents()
        #expect(events == [.controlModeStarted, .controlModeEnded])
        #expect(TestFixture(vt.lines[0]) == TestFixture("z"))
    }

    @Test func `control mode line-start escape split across reads`() {
        var vt = VT(20, 3)
        vt.feed("\(ESC)P1000p%begin 1 4 1\n\(ESC)")
        vt.feed("[1mx\n%end 1 4 1\n")
        let open = vt.state.isControlMode
        #expect(open)
        let data = String(decoding: vt.state.controlModeData, as: UTF8.self)
        #expect(TestFixture(data) == TestFixture("%begin 1 4 1\n\(ESC)[1mx\n%end 1 4 1\n"))
    }

    @Test func `CAN aborts control mode mid-line`() {
        var vt = VT(20, 3)
        vt.feed("\(ESC)P1000p%output %1 partial")
        vt.feed("\u{18}q")
        let closed = !vt.state.isControlMode
        #expect(closed)
        let events = vt.state.takeEvents()
        #expect(events == [.controlModeStarted, .controlModeEnded])
        #expect(TestFixture(vt.lines[0]) == TestFixture("q"))
    }

    @Test func `control mode split across reads`() {
        var vt = VT(20, 3)
        vt.feed("\(ESC)P10")
        vt.feed("00p%exit\r\n\(ESC)")
        vt.feed("\\")
        let data = String(decoding: vt.state.controlModeData, as: UTF8.self)
        #expect(TestFixture(data) == TestFixture("%exit\r\n"))
        let events = vt.state.takeEvents()
        #expect(events == [.controlModeStarted, .controlModeEnded])
    }

    @Test func `unknown DCS is ignored`() {
        var vt = VT(20, 3)
        vt.feed("\(ESC)Pqsixeldata\(ESC)\\ok")
        #expect(TestFixture(vt.lines[0]) == TestFixture("ok"))
        let empty = vt.state.controlModeData.isEmpty
        #expect(empty)
    }

    @Test func xtgettcap() {
        var vt = VT(20, 3)
        vt.feed("\(ESC)P+q\(TerminalState.hex("TN"));\(TerminalState.hex("zz"))\(ESC)\\")
        #expect(TestFixture(vt.takeOutput()) ==
            TestFixture("\(ESC)P1+r544E=\(TerminalState.hex("xterm-256color"))\(ESC)\\\(ESC)P0+r7A7A\(ESC)\\"))
    }

    @Test func `decrqss cursor style`() {
        var vt = VT(20, 3)
        vt.feed("\(CSI)6 q\(ESC)P$q q\(ESC)\\")
        #expect(TestFixture(vt.takeOutput()) == TestFixture("\(ESC)P1$r6 q\(ESC)\\"))
    }
}

struct NotificationOSCTests {
    @Test func `osc 9 and progress`() {
        var vt = VT(20, 3)
        vt.feed("\(ESC)]9;done\u{07}\(ESC)]9;4;1;42\u{07}\(ESC)]777;notify;T;B\(ESC)\\")
        let events = vt.state.takeEvents()
        #expect(events == [.notification(title: "", body: "done"), .progress(state: 1, percent: 42), .notification(title: "T", body: "B")])
    }
}

struct HyperlinkTests {
    @Test func `osc 8 marks cells`() {
        var vt = VT(20, 2)
        vt.feed("\(ESC)]8;;https://example.com\u{07}link\(CSI)0m\(ESC)]8;;\u{07} x")
        let id = vt.cell(1, 0).attributes.link
        #expect(id != 0)
        let target = vt.state.hyperlink(id)
        #expect(target == "https://example.com")
        #expect(vt.cell(5, 0).attributes.link == 0)
        let stride = MemoryLayout<Cell>.stride
        #expect(stride == 16)
    }
}

struct HyperlinkReuseTests {
    @Test(arguments: ["scroll", "clear", "resize", "reset"])
    func `a full link table resumes assigning ids when cells become available`(_ operation: String) {
        var vt = VT(40, 2, scrollback: 0)
        for i in 0 ..< 255 {
            vt.feed("\(CSI)1G\(ESC)]8;;file:///full\(i)\u{07}L\(ESC)]8;;\u{07}")
        }
        let live = vt.cell(0, 0).attributes.link
        #expect(vt.state.hyperlink(live) == "file:///full254")
        vt.feed("\(ESC)]8;;file:///overflow\u{07}U\(ESC)]8;;\u{07}")
        #expect(vt.cell(1, 0).attributes.link == 0)
        switch operation {
        case "scroll": vt.feed("\r\n\r\n\r\n")
        case "clear": vt.state.clearScreenKeepingCursorLine()
        case "resize": vt.state.resize(columns: 40, rows: 3)
        default: vt.state.fullReset()
        }
        let x = vt.state.cursor.x, y = vt.state.cursor.y
        vt.feed("\(ESC)]8;;file:///available\u{07}N\(ESC)]8;;\u{07}")
        let assigned = vt.cell(x, y).attributes.link
        #expect(assigned != 0 && vt.state.hyperlink(assigned) == "file:///available")
        if operation == "clear" || operation == "resize" {
            #expect(vt.state.hyperlink(vt.cell(0, 0).attributes.link) == "file:///full254")
        }
    }

    @Test func `full table never retargets live cells`() {
        var vt = VT(40, 300, scrollback: 10_000_000)
        for i in 0 ..< 300 {
            vt.feed("\(ESC)]8;;file:///f\(i)\u{07}f\(i)\(ESC)]8;;\u{07}\r\n")
        }
        // Every linked cell still resolves to the URI it was written with.
        let lines = vt.lines
        var linked = 0
        for y in 0 ..< lines.count where lines[y].hasPrefix("f") {
            let link = vt.cell(0, y).attributes.link
            guard link != 0 else { continue }
            linked += 1
            let target = vt.state.hyperlink(link)
            #expect(target == "file:///" + lines[y])
        }
        #expect(linked >= 250)
    }

    @Test func `freed ids are reused`() {
        var vt = VT(40, 2, scrollback: 0)
        for i in 0 ..< 600 {
            vt.feed("\(ESC)]8;;file:///g\(i)\u{07}g\(ESC)]8;;\u{07}\r\n")
        }
        let link = vt.cell(0, 0).attributes.link
        let target = vt.state.hyperlink(link)
        #expect(link != 0 && target == "file:///g599")
    }
}

struct HyperlinkLifetimeTests {
    @Test(arguments: [0, 128, 1024], ["A", "漢", "👩‍💻"])
    func `reuse preserves links on the inactive alternate screen`(_ scrollback: Int, _ content: String) {
        var vt = VT(8, 2, scrollback: scrollback)
        let open = "\(ESC)]8;;file:///shared\u{07}"
        let close = "\(ESC)]8;;\u{07}"
        vt.feed(open + "P" + close)
        vt.feed("\(CSI)?47h\(CSI)H" + open + content + close + "\(CSI)?47l")
        // Reopening on primary must not replace the alternate screen's lifetime
        // with a primary row bound that expires when primary scrolls.
        vt.feed(open + close + String(repeating: "\r\n", count: 12))
        for index in 0 ..< 255 {
            vt.feed("\(ESC)]8;;file:///new\(index)\u{07}" + close)
        }
        vt.feed("\(ESC)]8;;file:///available\u{07}N" + close)
        let assigned = vt.cell(0, 1).attributes.link
        #expect(assigned != 0 && vt.state.hyperlink(assigned) == "file:///available")
        vt.feed("\(CSI)?47h")
        let cell = vt.cell(0, 0)
        #expect(TestFixture(vt.lines[0]) == TestFixture(content))
        #expect(vt.state.hyperlink(cell.attributes.link) == "file:///shared")
    }

    /// Fills the table with links that end on the first row, then forces
    /// reuse; `cell` must keep resolving to its original URI.
    @Test func `reused and saved links stay pinned`() {
        var vt = VT(40, 3, scrollback: 0)
        // Link A, ended; then printed again later (interned hit) on a fresh row.
        vt.feed("\(ESC)]8;;file:///A\u{07}a\(ESC)]8;;\u{07}\r\n")
        // Link B held by a saved cursor across a restore.
        vt.feed("\(ESC)]8;;file:///B\u{07}\(ESC)7\(ESC)]8;;\u{07}\r\n")
        // Push A's first row out of the screen (no history), then reuse A.
        vt.feed("x\r\nx\r\nx\r\n")
        vt.feed("\(ESC)]8;;file:///A\u{07}A\(ESC)]8;;\u{07}")
        vt.feed("\(ESC)8b") // restore: pen carries B again
        for i in 0 ..< 400 {
            vt.feed("\(ESC)]8;;file:///n\(i)\u{07}\(ESC)]8;;\u{07}")
        }
        let rowA = vt.lines.firstIndex { $0.contains("A") } ?? 0
        let colA = vt.lines[rowA].firstIndex(of: "A").map { vt.lines[rowA].distance(from: vt.lines[rowA].startIndex, to: $0) } ?? 0
        let a = vt.state.hyperlink(vt.cell(colA, rowA).attributes.link)
        #expect(a == "file:///A")
        // "b" was written with B's id after the restore.
        let rowB = vt.lines.firstIndex { $0.contains("b") } ?? 0
        let colB = vt.lines[rowB].firstIndex(of: "b").map { vt.lines[rowB].distance(from: vt.lines[rowB].startIndex, to: $0) } ?? 0
        let b = vt.state.hyperlink(vt.cell(colB, rowB).attributes.link)
        #expect(b == "file:///B")
    }
}
