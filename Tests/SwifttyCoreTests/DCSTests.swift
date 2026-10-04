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
