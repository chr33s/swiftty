@testable import SwifttyCore
import Testing

struct DCSTests {
    @Test func `tmux control mode streams raw lines`() {
        var vt = VT(20, 3)
        vt.feed("a\(ESC)P1000p%begin 1 2 0\r\n%end 1 2 0\r\n")
        let open = vt.state.isControlMode
        #expect(open)
        let started = vt.state.takeEvents()
        #expect(started == [.controlModeStarted])
        vt.feed("%output %1 hi\\033[m\r\n\(ESC)\\b")
        let data = String(decoding: vt.state.controlModeData, as: UTF8.self)
        #expect(data
            == "%begin 1 2 0\r\n%end 1 2 0\r\n%output %1 hi\\033[m\r\n")
        let closed = !vt.state.isControlMode
        #expect(closed)
        let ended = vt.state.takeEvents()
        #expect(ended == [.controlModeEnded])
        #expect(vt.lines[0] == "ab")
    }

    @Test func `control mode split across reads`() {
        var vt = VT(20, 3)
        vt.feed("\(ESC)P10")
        vt.feed("00p%exit\r\n\(ESC)")
        vt.feed("\\")
        let data = String(decoding: vt.state.controlModeData, as: UTF8.self)
        #expect(data == "%exit\r\n")
        let events = vt.state.takeEvents()
        #expect(events == [.controlModeStarted, .controlModeEnded])
    }

    @Test func `unknown DCS is ignored`() {
        var vt = VT(20, 3)
        vt.feed("\(ESC)Pqsixeldata\(ESC)\\ok")
        #expect(vt.lines[0] == "ok")
        let empty = vt.state.controlModeData.isEmpty
        #expect(empty)
    }

    @Test func xtgettcap() {
        var vt = VT(20, 3)
        vt.feed("\(ESC)P+q\(TerminalState.hex("TN"));\(TerminalState.hex("zz"))\(ESC)\\")
        #expect(vt.takeOutput() == "\(ESC)P1+r544E=\(TerminalState.hex("xterm-256color"))\(ESC)\\\(ESC)P0+r7A7A\(ESC)\\")
    }

    @Test func `decrqss cursor style`() {
        var vt = VT(20, 3)
        vt.feed("\(CSI)6 q\(ESC)P$q q\(ESC)\\")
        #expect(vt.takeOutput() == "\(ESC)P1$r6 q\(ESC)\\")
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
    /// Fills the table with links that end on the first row, then forces
    /// reuse; `cell` must keep resolving to its original URI.
    @Test func reusedAndSavedLinksStayPinned() {
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
