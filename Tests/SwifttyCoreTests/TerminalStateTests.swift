@testable import SwifttyCore
import Testing

struct TerminalStateTests {
    @Test func `autowrap and pending wrap`() {
        var vt = VT(5, 3)
        vt.feed("abcde")
        #expect(vt.cursor == (4, 0))
        do { let ok = vt.state.cursor.pendingWrap; #expect(ok, "vt.state.cursor.pendingWrap") }
        vt.feed("f")
        #expect(vt.lines[0] == "abcde" && vt.lines[1] == "f")
        do { let ok = vt.state.grid.isWrapped(0); #expect(ok, "vt.state.grid.isWrapped(0)") }
        vt.feed("\(CSI)?7l\(CSI)3;1H12345678")
        #expect(vt.lines[2] == "12348")
    }

    @Test func `pending wrap cleared by cursor move`() {
        var vt = VT(5, 3)
        vt.feed("abcde\rX")
        #expect(vt.lines[0] == "Xbcde")
        #expect(vt.cursor == (1, 0))
    }

    @Test func `scrolling feeds scrollback`() {
        var vt = VT(5, 3)
        vt.feed("1\r\n2\r\n3\r\n4\r\n5")
        #expect(vt.lines == ["3", "4", "5"])
        do { let ok = vt.state.scrollbackCount == 2; #expect(ok, "vt.state.scrollbackCount == 2") }
        do { let ok = vt.state.scrollbackText(0) == "1"; #expect(ok, "vt.state.scrollbackText(0) == \"1\"") }
        do { let ok = vt.state.scrollbackText(1) == "2"; #expect(ok, "vt.state.scrollbackText(1) == \"2\"") }
    }

    @Test func `scroll region`() {
        var vt = VT(5, 5)
        vt.feed("a\r\nb\r\nc\r\nd\r\ne")
        vt.feed("\(CSI)2;4r")
        #expect(vt.cursor == (0, 0))
        vt.feed("\(CSI)4;1H\nX")
        #expect(vt.lines == ["a", "c", "d", "X", "e"])
        #expect(vt.state.scrollbackCount == 0) // region scrolls do not save lines
        vt.feed("\(CSI)2;1H\(ESC)M")
        #expect(vt.lines == ["a", "", "c", "d", "e"])
        vt.feed("\(CSI)2;1H\(CSI)2L")
        #expect(vt.lines == ["a", "", "", "", "e"])
        vt.feed("\(CSI)r\(CSI)S")
        do { let ok = vt.state.scrollTop == 0 && vt.state.scrollBottom == 4; #expect(
            ok,
            "vt.state.scrollTop == 0 && vt.state.scrollBottom == 4",
        ) }
    }

    @Test func `insert delete lines`() {
        var vt = VT(3, 4)
        vt.feed("a\r\nb\r\nc\r\nd\(CSI)2;1H\(CSI)L")
        #expect(vt.lines == ["a", "", "b", "c"])
        vt.feed("\(CSI)2M")
        #expect(vt.lines == ["a", "c", "", ""])
    }

    @Test func `insert delete characters`() {
        var vt = VT(6, 1)
        vt.feed("abcdef\(CSI)1;2H\(CSI)2@")
        #expect(vt.lines[0] == "a  bcd")
        vt.feed("\(CSI)3P")
        #expect(vt.lines[0] == "acd")
        vt.feed("\(CSI)4h\(CSI)1;1HXY")
        #expect(vt.lines[0] == "XYacd")
    }

    @Test func `wide characters`() {
        var vt = VT(5, 2)
        vt.feed("a中b")
        #expect(vt.cell(1, 0).width == 2 && vt.cell(2, 0).flags.contains(.spacerTail))
        #expect(vt.cursor == (4, 0))
        vt.feed("文") // does not fit in the last column: wraps
        #expect(vt.cell(4, 0).flags.contains(.spacerHead))
        #expect(vt.lines[0] == "a中b" && vt.lines[1] == "文")
        // Overwriting half of a wide char clears the other half.
        vt.feed("\(CSI)1;3Hx")
        #expect(vt.lines[0] == "a xb")
        #expect(!vt.cell(1, 0).flags.contains(.spacerTail) && vt.cell(1, 0).width == 1)
    }

    @Test func `combining marks and ZWJ`() {
        var vt = VT(10, 2)
        vt.feed("e\u{301}x")
        #expect(vt.cell(0, 0).isGrapheme)
        do { let ok = vt.state.scalars(of: vt.cell(0, 0)) == ["e", "\u{301}"]; #expect(
            ok,
            "vt.state.scalars(of: vt.cell(0, 0)) == [\"e\", \"\\u{301}\"]",
        ) }
        #expect(vt.cursor == (2, 0))
        vt.feed("👩\u{200D}💻!")
        do { let ok = vt.state.scalars(of: vt.cell(2, 0)).count == 3; #expect(ok, "vt.state.scalars(of: vt.cell(2, 0)).count == 3") }
        #expect(vt.cell(3, 0).flags.contains(.spacerTail))
        #expect(vt.lines[0] == "e\u{301}x👩\u{200D}💻!")
    }

    @Test func `combining after wrap attaches to previous row`() {
        var vt = VT(3, 2)
        vt.feed("abc\u{301}")
        do { let ok = vt.state.scalars(of: vt.cell(2, 0)) == ["c", "\u{301}"]; #expect(
            ok,
            "vt.state.scalars(of: vt.cell(2, 0)) == [\"c\", \"\\u{301}\"]",
        ) }
    }

    @Test func `alternate screen`() {
        var vt = VT(5, 3)
        vt.feed("main\(CSI)2;2H")
        vt.feed("\(CSI)?1049h")
        do { let ok = vt.state.isAlternateScreen; #expect(ok, "vt.state.isAlternateScreen") }
        #expect(vt.lines == ["", "", ""])
        vt.feed("alt\r\n\r\n\r\nscroll")
        do { let ok = vt.state.scrollbackCount == 0; #expect(ok, "vt.state.scrollbackCount == 0") }
        vt.feed("\(CSI)?1049l")
        #expect(vt.lines[0] == "main")
        #expect(vt.cursor == (1, 1))
    }

    @Test func `save restore cursor`() {
        var vt = VT(10, 5)
        vt.feed("\(CSI)3;3H\(CSI)31m\(ESC)7\(CSI)H\(CSI)0m\(ESC)8x")
        #expect(vt.cursor == (3, 2))
        #expect(vt.cell(2, 2).attributes.foreground == .palette(1))
    }

    @Test func `origin mode`() {
        var vt = VT(10, 6)
        vt.feed("\(CSI)2;5r\(CSI)?6h\(CSI)1;1HX\(CSI)99;1HY")
        #expect(vt.lines[1] == "X" && vt.lines[4] == "Y")
        vt.feed("\(CSI)6n")
        #expect(vt.takeOutput() == "\(CSI)4;2R")
    }

    @Test func tabs() {
        var vt = VT(20, 1)
        vt.feed("\ta\(CSI)3g\r\tb")
        #expect(vt.cursor.x == 19 + 1 - 1)
        vt.feed("\(CSI)1;3H\(ESC)H\r\tc")
        #expect(vt.cell(2, 0).glyph == UInt32(("c" as Unicode.Scalar).value))
    }

    @Test func `resize reflows wrapped lines`() {
        var vt = VT(10, 3)
        vt.feed("0123456789abcde\r\nxy")
        #expect(vt.lines == ["0123456789", "abcde", "xy"])
        vt.state.resize(columns: 20, rows: 3)
        #expect(vt.lines == ["0123456789abcde", "xy", ""])
        #expect(vt.cursor == (2, 1))
        vt.state.resize(columns: 5, rows: 3)
        // 15 chars → 3 rows, plus "xy": 4 rows; oldest goes to scrollback.
        #expect(vt.lines == ["56789", "abcde", "xy"])
        do { let ok = vt.state.scrollbackText(0) == "01234"; #expect(ok, "vt.state.scrollbackText(0) == \"01234\"") }
        #expect(vt.cursor == (2, 2))
    }

    @Test func `resize height moves lines through scrollback`() {
        var vt = VT(5, 4)
        vt.feed("a\r\nb\r\nc\r\nd")
        vt.state.resize(columns: 5, rows: 2)
        #expect(vt.lines == ["c", "d"])
        do { let ok = vt.state.scrollbackCount == 2; #expect(ok, "vt.state.scrollbackCount == 2") }
        vt.state.resize(columns: 5, rows: 4)
        #expect(vt.lines == ["a", "b", "c", "d"])
        do { let ok = vt.state.scrollbackCount == 0; #expect(ok, "vt.state.scrollbackCount == 0") }
        #expect(vt.cursor == (1, 3))
    }

    @Test func `resize with wide characters`() {
        var vt = VT(6, 2)
        vt.feed("ab中文")
        vt.state.resize(columns: 3, rows: 3)
        #expect(vt.lines == ["ab", "中", "文"])
        #expect(vt.cell(2, 0).flags.contains(.spacerHead))
        vt.state.resize(columns: 8, rows: 3)
        #expect(vt.lines[0] == "ab中文")
    }

    @Test func `resize in alternate screen keeps primary`() {
        var vt = VT(10, 3)
        vt.feed("0123456789x\(CSI)?1049h")
        vt.state.resize(columns: 20, rows: 3)
        vt.feed("\(CSI)?1049l")
        #expect(vt.lines[0] == "0123456789x")
    }

    @Test func `viewport scrolling`() {
        var vt = VT(5, 2)
        vt.feed("1\r\n2\r\n3\r\n4")
        vt.state.scrollViewport(by: 1)
        #expect(vt.lines == ["2", "3"])
        vt.state.scrollViewport(by: 10)
        #expect(vt.lines == ["1", "2"])
        vt.feed("\r\n5") // output while scrolled keeps the view pinned
        #expect(vt.lines == ["1", "2"])
        vt.state.scrollViewportToBottom()
        #expect(vt.lines == ["4", "5"])
    }

    @Test func `damage tracking`() {
        var vt = VT(5, 4)
        _ = vt.state.takeDamage()
        vt.feed("\(CSI)3;1Hx")
        let d = vt.state.takeDamage()
        #expect(!d.isFull && d.contains(row: 2) && !d.contains(row: 0))
        vt.feed("\r\n\r\n")
        do { let ok = vt.state.takeDamage().isFull; #expect(ok, "vt.state.takeDamage().isFull") }
    }

    @Test func `full reset`() {
        var vt = VT(5, 2)
        vt.feed("\(CSI)31mab\(CSI)?1h\r\n\r\n\(ESC)c")
        #expect(vt.lines == ["", ""])
        do { let ok = vt.state.modes == .initial; #expect(ok, "vt.state.modes == .initial") }
        do { let ok = vt.state.scrollbackCount == 0; #expect(ok, "vt.state.scrollbackCount == 0") }
    }

    @Test func `repeat character`() {
        var vt = VT(10, 1)
        vt.feed("x\(CSI)4b")
        #expect(vt.lines[0] == "xxxxx")
    }
}

struct GridInvariantTests {
    @Test func `cell layout matches fast path assumptions`() {
        #expect(MemoryLayout<Cell>.stride == 16)
        #expect(MemoryLayout<Cell>.offset(of: \Cell.glyph) == 0)
    }

    @Test func `fast ASCII path matches general path`() {
        var fast = VT(7, 4), slow = VT(7, 4)
        let text = "\u{1B}[1;32mThe quick brown fox jumps over the lazy dog\u{1B}[0m 中x"
        fast.feed(text)
        for scalar in text.unicodeScalars {
            slow.feed(String(scalar)) // one scalar per call: no bulk path
        }
        #expect(fast.lines == slow.lines)
        for y in 0 ..< 4 {
            for x in 0 ..< 7 {
                #expect(fast.cell(x, y) == slow.cell(x, y))
            }
        }
    }

    /// Every cell at or past a row's extent must be blank, whatever the
    /// sequence of operations (fuzzed with a fixed seed).
    @Test func `extent invariant holds under random operations`() {
        var seed: UInt64 = 42
        func next(_ n: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return Int((seed >> 33) % UInt64(n))
        }
        let pieces = [
            "abc",
            "中文",
            "e\u{301}",
            "\r\n",
            "\u{1B}[K",
            "\u{1B}[1K",
            "\u{1B}[2J",
            "\u{1B}[3@",
            "\u{1B}[2P",
            "\u{1B}[2L",
            "\u{1B}[M",
            "\u{1B}[41m \u{1B}[0m",
            "\u{1B}[5X",
            "\u{1B}[2;5r",
            "\u{1B}[r",
            "\u{1B}M",
            "\u{1B}[3S",
            "\u{1B}[2T",
            "\t",
            "\u{1B}[?1049h",
            "\u{1B}[?1049l",
            "\u{1B}[4h",
            "\u{1B}[4l",
            "😀",
        ]
        var vt = VT(12, 6)
        for i in 0 ..< 3000 {
            if i % 500 == 499 {
                vt.state.resize(columns: 6 + next(14), rows: 3 + next(6))
            }
            vt.feed("\u{1B}[\(1 + next(8));\(1 + next(14))H" + pieces[next(pieces.count)])
            let ok = vt.state.checkExtentInvariant()
            #expect(ok, "invariant broken after step \(i)")
            if !ok {
                break
            }
        }
    }
}
