@testable import SwifttyCore
import Testing

struct ParserTests {
    @Test func `printable ASCII`() {
        var vt = VT()
        vt.feed("hello")
        #expect(vt.lines[0] == "hello")
        #expect(vt.cursor == (5, 0))
    }

    @Test func `utf 8 multibyte and split across buffers`() {
        var vt = VT()
        let bytes = Array("é€😀".utf8)
        for b in bytes {
            vt.feed(bytes: [b])
        } // one byte at a time
        #expect(vt.lines[0] == "é€😀")
        #expect(vt.cursor == (4, 0)) // é(1) €(1) 😀(2)
    }

    @Test func `malformed UTF 8 becomes replacement`() {
        var vt = VT()
        vt.feed(bytes: [0x41, 0xC3, 0x41, 0xFF, 0xE2, 0x82, 0x42, 0xED, 0xA0, 0x80])
        // C3 41: truncated → U+FFFD, A; FF invalid; E2 82 42 truncated; ED A0 80 surrogate
        #expect(vt.lines[0] == "A\u{FFFD}A\u{FFFD}\u{FFFD}B\u{FFFD}")
    }

    @Test func `c 0 controls`() {
        var vt = VT()
        vt.feed("ab\rc\n d\u{08}e\tf")
        #expect(vt.lines[0] == "cb")
        #expect(vt.lines[1] == "  e     f")
        vt.feed("\u{07}")
        do { let ok = vt.state.events.contains(.bell); #expect(ok, "vt.state.events.contains(.bell)") }
    }

    @Test func `csi cursor movement`() {
        var vt = VT(10, 5)
        vt.feed("\(CSI)3;4H")
        #expect(vt.cursor == (3, 2))
        vt.feed("\(CSI)A\(CSI)2C")
        #expect(vt.cursor == (5, 1))
        vt.feed("\(CSI)10B\(CSI)99D")
        #expect(vt.cursor == (0, 4))
        vt.feed("\(CSI)7G\(CSI)2d")
        #expect(vt.cursor == (6, 1))
        vt.feed("\(CSI)H")
        #expect(vt.cursor == (0, 0))
        vt.feed("\(CSI)2E")
        #expect(vt.cursor == (0, 2))
    }

    @Test func `csi parameters default and overflow`() {
        var vt = VT(10, 5)
        vt.feed("\(CSI);5H") // empty first param → 1
        #expect(vt.cursor == (4, 0))
        vt.feed("\(CSI)99999999;2H") // clamped, then clamped to screen
        #expect(vt.cursor == (1, 4))
        let many = (0 ..< 40).map { _ in "1" }.joined(separator: ";")
        vt.feed("\(CSI)\(many)m ok")
        #expect(vt.lines[4].hasSuffix("ok"))
    }

    @Test func `erase operations`() {
        var vt = VT(5, 3)
        vt.feed("aaaaa\(CSI)2;1Hbbbbb\(CSI)3;1Hccccc")
        vt.feed("\(CSI)2;3H\(CSI)K")
        #expect(vt.lines == ["aaaaa", "bb", "ccccc"])
        vt.feed("\(CSI)1K")
        #expect(vt.lines[1] == "")
        vt.feed("\(CSI)1;2H\(CSI)1J")
        #expect(vt.lines == ["  aaa", "", "ccccc"])
        vt.feed("\(CSI)J")
        #expect(vt.lines == ["", "", ""])
        vt.feed("xyz\(CSI)1;1H\(CSI)2X")
        #expect(vt.lines[0] == "  yz")
    }

    @Test func `sgr attributes and colors`() {
        var vt = VT(20, 2)
        vt
            .feed(
                "\(CSI)1;3;4;31;42mA\(CSI)0mB\(CSI)38;5;200;48;2;1;2;3mC\(CSI)38:2::10:20:30mD\(CSI)4:3;9mE\(CSI)22;23;24;29;39;49mF\(CSI)95;104mG",
            )
        let a = vt.cell(0, 0).attributes
        #expect(a.flags.isSuperset(of: [.bold, .italic, .underline]))
        #expect(a.foreground == .palette(1) && a.background == .palette(2))
        #expect(vt.cell(1, 0).attributes == .default)
        #expect(vt.cell(2, 0).attributes.foreground == .palette(200))
        #expect(vt.cell(2, 0).attributes.background == .rgb(1, 2, 3))
        #expect(vt.cell(3, 0).attributes.foreground == .rgb(10, 20, 30))
        #expect(vt.cell(4, 0).flags.isSuperset(of: [.underline, .strikethrough]))
        let f = vt.cell(5, 0).attributes
        #expect(f.foreground == .default && f.background == .rgb(1, 2, 3) || f.background == .default)
        #expect(f.flags.isEmpty)
        #expect(vt.cell(6, 0).attributes.foreground == .palette(13))
        #expect(vt.cell(6, 0).attributes.background == .palette(12))
    }

    @Test func `osc title with bel and ST`() {
        var vt = VT()
        vt.feed("\(ESC)]0;hello\u{07}x")
        do { let ok = vt.state.takeEvents() == [.title("hello")]; #expect(ok) }
        vt.feed("\(ESC)]2;wörld\(ESC)\\y\(ESC)]2;wörld\u{07}")
        do { let ok = vt.state.takeEvents() == [.title("wörld")]; #expect(ok) } // coalesced
        do { let ok = vt.state.takeEvents().isEmpty; #expect(ok) }
        vt.feed("\(ESC)]7;file://host/tmp/a%20b\u{07}")
        do { let ok = vt.state.takeEvents() == [.workingDirectory("/tmp/a b")]; #expect(ok) }
        #expect(vt.lines[0] == "xy")
    }

    @Test func `osc clipboard and color query`() {
        var vt = VT()
        vt.feed("\(ESC)]52;c;aGVsbG8=\u{07}")
        do { let ok = vt.state.events.last == .clipboard("hello"); #expect(ok, "vt.state.events.last == .clipboard(\"hello\")") }
        vt.feed("\(ESC)]52;c;?\u{07}") // reads refused
        #expect(vt.takeOutput().isEmpty)
        vt.feed("\(ESC)]11;?\u{07}")
        #expect(vt.takeOutput() == "\(ESC)]11;rgb:2828/2c2c/3434\u{07}")
        vt.feed("\(ESC)]4;1;rgb:ff/00/80\(ESC)\\\(ESC)]4;1;?\(ESC)\\")
        #expect(vt.takeOutput() == "\(ESC)]4;1;rgb:ffff/0000/8080\(ESC)\\")
    }

    @Test func `unsupported sequences are ignored`() {
        var vt = VT()
        vt.feed("a\(ESC)P1$qm\(ESC)\\b\(CSI)?999h\(CSI)>4;1m\(CSI)=5uc\(ESC)_apc\(ESC)\\d\(ESC)^pm\(ESC)\\e")
        vt.feed("\(ESC)]999;whatever\u{07}f\(CSI)1;2;3$zg")
        #expect(vt.lines[0] == "abcdefg")
    }

    @Test func `cancel aborts sequence`() {
        var vt = VT()
        vt.feed("\(CSI)31\u{18}x\(ESC)]0;t\u{1A}y")
        #expect(vt.lines[0] == "xy")
        #expect(vt.cell(0, 0).attributes == .default)
        do { let ok = vt.state.events.isEmpty; #expect(ok, "vt.state.events.isEmpty") }
    }

    @Test func `control inside CSI executes`() {
        var vt = VT()
        vt.feed("ab\(CSI)2\rC") // CR inside CSI executes immediately
        #expect(vt.cursor == (2, 0))
    }

    @Test func `modes and reports`() {
        var vt = VT(10, 5)
        vt.feed("\(CSI)?1h\(CSI)?2004h\(CSI)?1006h\(CSI)?1002h\(CSI)4h")
        do { let ok = vt.state.modes.isSuperset(of: [.cursorKeys, .bracketedPaste, .mouseSGR, .mouseButton, .insert]); #expect(
            ok,
            "vt.state.modes.isSuperset(of: [.cursorKeys, .bracketedPaste, .mouseSGR, .mouseButton, .insert])",
        ) }
        vt.feed("\(CSI)?1003h")
        do { let ok = vt.state.modes.contains(.mouseAny) && !vt.state.modes.contains(.mouseButton); #expect(
            ok,
            "vt.state.modes.contains(.mouseAny) && !vt.state.modes.contains(.mouseButton)",
        ) }
        vt.feed("\(CSI)?25l\(CSI)?1;25$p")
        do { let ok = !vt.state.modes.contains(.cursorVisible); #expect(ok, "!vt.state.modes.contains(.cursorVisible)") }
        #expect(vt.takeOutput() == "\(CSI)?1;1$y")
        vt.feed("\(CSI)3;4H\(CSI)6n\(CSI)5n\(CSI)c\(CSI)>c\(CSI)18t")
        #expect(vt.takeOutput() == "\(CSI)3;4R\(CSI)0n\(CSI)?62;22c\(CSI)>1;10;0c\(CSI)8;5;10t")
    }

    @Test func `simd scan stops at controls`() {
        let bytes = Array((String(repeating: "x", count: 37) + "\u{1B}" + String(repeating: "y", count: 20)).utf8)
        let end = bytes.withUnsafeBufferPointer { Parser.scanPrintableASCII($0.baseAddress!, from: 0, to: $0.count) }
        #expect(end == 37)
        let mid = bytes.withUnsafeBufferPointer { Parser.scanPrintableASCII($0.baseAddress!, from: 38, to: $0.count) }
        #expect(mid == bytes.count)
    }

    @Test func `dec special graphics`() {
        var vt = VT()
        vt.feed("\(ESC)(0lqk\(ESC)(Bq\u{0E}")
        #expect(vt.lines[0] == "┌─┐q")
        vt.feed("\(ESC))0\u{0E}x\u{0F}x")
        #expect(vt.lines[0] == "┌─┐q│x")
    }
}
