@testable import SwifttyCore
import Testing
import TestSupport

struct TerminalStateTests {
    @Test(arguments: [false, true])
    func `keypad mode transitions preserve terminal content and unrelated modes`(_ fragmented: Bool) {
        var vt = VT(8, 3)
        vt.feed("text\(CSI)2;3H\(CSI)4h")
        let cursor = vt.state.cursor
        let modes = vt.state.modes
        let lines = vt.lines
        #expect(!modes.contains(.keypadApplication))
        _ = vt.state.takeDamage()
        for enabled in [true, true, false, false, true] {
            let sequence = "\(ESC)\(enabled ? "=" : ">")"
            if fragmented {
                for byte in sequence.utf8 {
                    vt.feed(bytes: [byte])
                }
            } else {
                vt.feed(sequence)
            }
            #expect(vt.state.modes == (enabled ? modes.union(.keypadApplication) : modes))
            #expect(vt.state.cursor == cursor)
            #expect(TestFixture(vt.lines) == TestFixture(lines))
            let damage = vt.state.takeDamage()
            #expect(damage.isEmpty)
        }
        vt.feed("X")
        #expect(vt.cell(2, 1).glyph == 0x58)
    }

    @Test(arguments: ["\(CSI)!p", "\(ESC)c"].map(TestFixture.init), [false, true])
    func `terminal resets restore numeric keypad mode`(_ sequence: TestFixture<String>, _ fragmented: Bool) {
        var vt = VT(8, 3)
        vt.feed("text\(ESC)=")
        #expect(vt.state.modes.contains(.keypadApplication))
        if fragmented {
            for byte in sequence.value.utf8 {
                vt.feed(bytes: [byte])
            }
        } else {
            vt.feed(sequence.value)
        }
        #expect(!vt.state.modes.contains(.keypadApplication))
        vt.feed("\(ESC)=")
        #expect(vt.state.modes.contains(.keypadApplication))
    }

    @Test(arguments: [false, true], [(false, 2), (false, 3), (true, 2), (true, 3)])
    func `combining characters consume single shifts`(_ clustering: Bool, _ input: (Bool, Int)) {
        let (fragmented, slot) = input
        var vt = VT(10, 2)
        vt.feed("\u{1B}[?2027\(clustering ? "h" : "l")\u{1B}\(slot == 2 ? "*" : "+")A#\u{1B}\(slot == 2 ? "N" : "O")")
        #expect(vt.state.cursor.singleShift != nil)
        if fragmented {
            for byte in "\u{301}".utf8 {
                vt.feed(bytes: [byte])
            }
        } else {
            vt.feed("\u{301}")
        }
        #expect(vt.state.cursor.singleShift == nil)
        #expect(vt.state.scalars(of: vt.cell(0, 0)) == Array("#\u{301}".unicodeScalars))
        vt.feed("#")
        #expect(vt.cell(1, 0).glyph == 0x23)
        #expect(vt.cursor.x == 2)
    }

    @Test(arguments: ["a", "ab", "é", "éx", "漢", "漢x"], [0, 1])
    func `batched overwrites maintain wrapped wide character spacers`(_ text: String, _ column: Int) {
        var actual = VT(5, 3), reference = VT(5, 3)
        let initial = "ABCD\u{1B}[44m漢\u{1B}[0m\u{1B}[2;\(column + 1)H"
        actual.feed(initial)
        reference.feed(initial)
        #expect(actual.cell(4, 0).flags.contains(.spacerHead))
        var attributes = actual.cell(4, 0).attributes
        let keepsHead = column == 0 && text.hasPrefix("漢")
        if !keepsHead {
            attributes.flags.remove(.spacerHead)
        }
        _ = actual.state.takeDamage()
        actual.feed(text)
        for byte in text.utf8 {
            reference.feed(bytes: [byte])
        }
        for y in 0 ..< 3 {
            for x in 0 ..< 5 {
                #expect(actual.cell(x, y) == reference.cell(x, y))
            }
        }
        #expect(actual.cell(4, 0).attributes == attributes)
        #expect(actual.cursor == reference.cursor)
        let damage = actual.state.takeDamage()
        #expect(damage.contains(row: 1))
        #expect(damage.contains(row: 0) == !keepsHead)
    }

    @Test func `autowrap and pending wrap`() {
        var vt = VT(5, 3)
        vt.feed("abcde")
        #expect(vt.cursor == (4, 0))
        do { let ok = vt.state.cursor.pendingWrap; #expect(ok, Comment(rawValue: escapedTestText("vt.state.cursor.pendingWrap"))) }
        vt.feed("f")
        #expect(TestFixture(vt.lines[0] == "abcde" && vt.lines[1] == "f") == TestFixture(true))
        do { let ok = vt.state.grid.isWrapped(0); #expect(ok, Comment(rawValue: escapedTestText("vt.state.grid.isWrapped(0)"))) }
        vt.feed("\(CSI)?7l\(CSI)3;1H12345678")
        #expect(TestFixture(vt.lines[2]) == TestFixture("12348"))
    }

    @Test func `pending wrap cleared by cursor move`() {
        var vt = VT(5, 3)
        vt.feed("abcde\rX")
        #expect(TestFixture(vt.lines[0]) == TestFixture("Xbcde"))
        #expect(vt.cursor == (1, 0))
    }

    @Test func `scrolling feeds scrollback`() {
        var vt = VT(5, 3)
        vt.feed("1\r\n2\r\n3\r\n4\r\n5")
        #expect(TestFixture(vt.lines) == TestFixture(["3", "4", "5"]))
        do { let ok = vt.state.scrollbackCount == 2; #expect(ok, Comment(rawValue: escapedTestText("vt.state.scrollbackCount == 2"))) }
        do { let ok = vt.state.scrollbackText(0) == "1"; #expect(
            ok,
            Comment(rawValue: escapedTestText("vt.state.scrollbackText(0) == \"1\"")),
        ) }
        do { let ok = vt.state.scrollbackText(1) == "2"; #expect(
            ok,
            Comment(rawValue: escapedTestText("vt.state.scrollbackText(1) == \"2\"")),
        ) }
    }

    @Test func `scroll region`() {
        var vt = VT(5, 5)
        vt.feed("a\r\nb\r\nc\r\nd\r\ne")
        vt.feed("\(CSI)2;4r")
        #expect(vt.cursor == (0, 0))
        vt.feed("\(CSI)4;1H\nX")
        #expect(TestFixture(vt.lines) == TestFixture(["a", "c", "d", "X", "e"]))
        #expect(vt.state.scrollbackCount == 0) // region scrolls do not save lines
        vt.feed("\(CSI)2;1H\(ESC)M")
        #expect(TestFixture(vt.lines) == TestFixture(["a", "", "c", "d", "e"]))
        vt.feed("\(CSI)2;1H\(CSI)2L")
        #expect(TestFixture(vt.lines) == TestFixture(["a", "", "", "", "e"]))
        vt.feed("\(CSI)r\(CSI)S")
        do { let ok = vt.state.scrollTop == 0 && vt.state.scrollBottom == 4; #expect(
            ok,
            Comment(rawValue: escapedTestText("vt.state.scrollTop == 0 && vt.state.scrollBottom == 4")),
        ) }
    }

    @Test func `insert delete lines`() {
        var vt = VT(3, 4)
        vt.feed("a\r\nb\r\nc\r\nd\(CSI)2;1H\(CSI)L")
        #expect(TestFixture(vt.lines) == TestFixture(["a", "", "b", "c"]))
        vt.feed("\(CSI)2M")
        #expect(TestFixture(vt.lines) == TestFixture(["a", "c", "", ""]))
    }

    @Test func `insert delete characters`() {
        var vt = VT(6, 1)
        vt.feed("abcdef\(CSI)1;2H\(CSI)2@")
        #expect(TestFixture(vt.lines[0]) == TestFixture("a  bcd"))
        vt.feed("\(CSI)3P")
        #expect(TestFixture(vt.lines[0]) == TestFixture("acd"))
        vt.feed("\(CSI)4h\(CSI)1;1HXY")
        #expect(TestFixture(vt.lines[0]) == TestFixture("XYacd"))
    }

    @Test func `wide characters`() {
        var vt = VT(5, 2)
        vt.feed("a中b")
        #expect(vt.cell(1, 0).width == 2 && vt.cell(2, 0).flags.contains(.spacerTail))
        #expect(vt.cursor == (4, 0))
        vt.feed("文") // does not fit in the last column: wraps
        #expect(vt.cell(4, 0).flags.contains(.spacerHead))
        #expect(TestFixture(vt.lines[0] == "a中b" && vt.lines[1] == "文") == TestFixture(true))
        // Overwriting half of a wide char clears the other half.
        vt.feed("\(CSI)1;3Hx")
        #expect(TestFixture(vt.lines[0]) == TestFixture("a xb"))
        #expect(!vt.cell(1, 0).flags.contains(.spacerTail) && vt.cell(1, 0).width == 1)
    }

    @Test func `combining marks and ZWJ`() {
        var vt = VT(10, 2)
        vt.feed("e\u{301}x")
        #expect(vt.cell(0, 0).isGrapheme)
        do { let ok = vt.state.scalars(of: vt.cell(0, 0)) == ["e", "\u{301}"]; #expect(
            ok,
            Comment(rawValue: escapedTestText("vt.state.scalars(of: vt.cell(0, 0)) == [\"e\", \"\\u{301}\"]")),
        ) }
        #expect(vt.cursor == (2, 0))
        vt.feed("👩\u{200D}💻!")
        do { let ok = vt.state.scalars(of: vt.cell(2, 0)).count == 3; #expect(
            ok,
            Comment(rawValue: escapedTestText("vt.state.scalars(of: vt.cell(2, 0)).count == 3")),
        ) }
        #expect(vt.cell(3, 0).flags.contains(.spacerTail))
        #expect(TestFixture(vt.lines[0]) == TestFixture("e\u{301}x👩\u{200D}💻!"))
    }

    @Test func `combining after wrap attaches to previous row`() {
        var vt = VT(3, 2)
        vt.feed("abc\u{301}")
        do { let ok = vt.state.scalars(of: vt.cell(2, 0)) == ["c", "\u{301}"]; #expect(
            ok,
            Comment(rawValue: escapedTestText("vt.state.scalars(of: vt.cell(2, 0)) == [\"c\", \"\\u{301}\"]")),
        ) }
    }

    @Test func `alternate screen`() {
        var vt = VT(5, 3)
        vt.feed("main\(CSI)2;2H")
        vt.feed("\(CSI)?1049h")
        do { let ok = vt.state.isAlternateScreen; #expect(ok, Comment(rawValue: escapedTestText("vt.state.isAlternateScreen"))) }
        #expect(TestFixture(vt.lines) == TestFixture(["", "", ""]))
        vt.feed("alt\r\n\r\n\r\nscroll")
        do { let ok = vt.state.scrollbackCount == 0; #expect(ok, Comment(rawValue: escapedTestText("vt.state.scrollbackCount == 0"))) }
        vt.feed("\(CSI)?1049l")
        #expect(TestFixture(vt.lines[0]) == TestFixture("main"))
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
        #expect(TestFixture(vt.lines[1] == "X" && vt.lines[4] == "Y") == TestFixture(true))
        vt.feed("\(CSI)6n")
        #expect(TestFixture(vt.takeOutput()) == TestFixture("\(CSI)4;2R"))
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
        #expect(TestFixture(vt.lines) == TestFixture(["0123456789", "abcde", "xy"]))
        vt.state.resize(columns: 20, rows: 3)
        #expect(TestFixture(vt.lines) == TestFixture(["0123456789abcde", "xy", ""]))
        #expect(vt.cursor == (2, 1))
        vt.state.resize(columns: 5, rows: 3)
        // 15 chars → 3 rows, plus "xy": 4 rows; oldest goes to scrollback.
        #expect(TestFixture(vt.lines) == TestFixture(["56789", "abcde", "xy"]))
        do { let ok = vt.state.scrollbackText(0) == "01234"; #expect(
            ok,
            Comment(rawValue: escapedTestText("vt.state.scrollbackText(0) == \"01234\"")),
        ) }
        #expect(vt.cursor == (2, 2))
    }

    @Test func `resize height moves lines through scrollback`() {
        var vt = VT(5, 4)
        vt.feed("a\r\nb\r\nc\r\nd")
        vt.state.resize(columns: 5, rows: 2)
        #expect(TestFixture(vt.lines) == TestFixture(["c", "d"]))
        do { let ok = vt.state.scrollbackCount == 2; #expect(ok, Comment(rawValue: escapedTestText("vt.state.scrollbackCount == 2"))) }
        vt.state.resize(columns: 5, rows: 4)
        #expect(TestFixture(vt.lines) == TestFixture(["a", "b", "c", "d"]))
        do { let ok = vt.state.scrollbackCount == 0; #expect(ok, Comment(rawValue: escapedTestText("vt.state.scrollbackCount == 0"))) }
        #expect(vt.cursor == (1, 3))
    }

    @Test(arguments: [4, 8], [false, true])
    func `resize keeps the cursor on a retained wide character tail`(_ newColumns: Int, _ autowrap: Bool) {
        var vt = VT(6, 3)
        vt.feed("a漢bc\u{1B}[1;3H")
        if !autowrap {
            vt.feed("\u{1B}[?7l")
        }
        #expect(vt.cursor == (2, 0))
        vt.state.resize(columns: newColumns, rows: 3)
        #expect(vt.cursor == (2, 0))
        #expect(vt.cell(2, 0).flags.contains(.spacerTail))
        vt.feed("X")
        #expect(vt.cell(2, 0).glyph == 0x58)
    }

    @Test(arguments: [3, 8])
    func `resize tracks a cursor on a wide tail across a wrap boundary`(_ newColumns: Int) {
        var vt = VT(4, 3)
        vt.feed("ab漢cd\u{1B}[1;4H")
        vt.state.resize(columns: newColumns, rows: 3)
        let expected = newColumns == 3 ? (1, 1) : (3, 0)
        #expect(vt.cursor == expected)
        #expect(vt.cell(expected.0, expected.1).flags.contains(.spacerTail))
    }

    @Test func `resize with wide characters`() {
        var vt = VT(6, 2)
        vt.feed("ab中文")
        vt.state.resize(columns: 3, rows: 3)
        #expect(TestFixture(vt.lines) == TestFixture(["ab", "中", "文"]))
        #expect(vt.cell(2, 0).flags.contains(.spacerHead))
        vt.state.resize(columns: 8, rows: 3)
        #expect(TestFixture(vt.lines[0]) == TestFixture("ab中文"))
    }

    @Test func `resize in alternate screen keeps primary`() {
        var vt = VT(10, 3)
        vt.feed("0123456789x\(CSI)?1049h")
        vt.state.resize(columns: 20, rows: 3)
        vt.feed("\(CSI)?1049l")
        #expect(TestFixture(vt.lines[0]) == TestFixture("0123456789x"))
    }

    @Test func `viewport scrolling`() {
        var vt = VT(5, 2)
        vt.feed("1\r\n2\r\n3\r\n4")
        vt.state.scrollViewport(by: 1)
        #expect(TestFixture(vt.lines) == TestFixture(["2", "3"]))
        vt.state.scrollViewport(by: 10)
        #expect(TestFixture(vt.lines) == TestFixture(["1", "2"]))
        vt.feed("\r\n5") // output while scrolled keeps the view pinned
        #expect(TestFixture(vt.lines) == TestFixture(["1", "2"]))
        vt.state.scrollViewportToBottom()
        #expect(TestFixture(vt.lines) == TestFixture(["4", "5"]))
    }

    @Test func `damage tracking`() {
        var vt = VT(5, 4)
        _ = vt.state.takeDamage()
        vt.feed("\(CSI)3;1Hx")
        let d = vt.state.takeDamage()
        #expect(!d.isFull && d.contains(row: 2) && !d.contains(row: 0))
        vt.feed("\r\n\r\n")
        do { let ok = vt.state.takeDamage().isFull; #expect(ok, Comment(rawValue: escapedTestText("vt.state.takeDamage().isFull"))) }
    }

    @Test func `full reset`() {
        var vt = VT(5, 2)
        vt.feed("\(CSI)31mab\(CSI)?1h\r\n\r\n\(ESC)c")
        #expect(TestFixture(vt.lines) == TestFixture(["", ""]))
        do { let ok = vt.state.modes == .initial; #expect(ok, Comment(rawValue: escapedTestText("vt.state.modes == .initial"))) }
        do { let ok = vt.state.scrollbackCount == 0; #expect(ok, Comment(rawValue: escapedTestText("vt.state.scrollbackCount == 0"))) }
    }

    @Test func `repeat character`() {
        var vt = VT(10, 1)
        vt.feed("x\(CSI)4b")
        #expect(TestFixture(vt.lines[0]) == TestFixture("xxxxx"))
    }
}

struct GridInvariantTests {
    @Test func `cell layout matches fast path assumptions`() {
        #expect(MemoryLayout<Cell>.stride == 16)
        #expect(MemoryLayout<Cell>.offset(of: \Cell.glyph) == 0)
    }

    @Test(arguments: [0, 1, 2, 3, 4, 5, 7, 8, 9, 63, 64, 65, 127, 128, 129, 200, 257])
    func `cell fill preserves attributes and stays within its bounds`(count: Int) {
        var attributes = CellAttributes(
            foreground: .rgb(0x12, 0x34, 0x56), background: .palette(231),
            flags: [.bold, .italic, .underline, .underlineStyleB, .protected], link: 255,
        )
        attributes.underlineColor = 63
        let patterns: [Cell] = [
            .blank, .erased(background: .rgb(0xAB, 0xCD, 0xEF)),
            Cell(glyph: 0x41, attributes: attributes, width: 1),
            Cell(glyph: 0x6F22, attributes: attributes, width: 2),
            Cell(glyph: 0, attributes: CellAttributes(flags: .spacerTail), width: 0),
            Cell(glyph: UInt32.max, attributes: CellAttributes(flags: .grapheme), width: 2),
        ]
        let sentinel = Cell(glyph: 0x10FFFF, attributes: CellAttributes(link: 7), width: 1)
        for prefix in [1, 5] {
            let capacity = prefix + count + 5
            let cells = UnsafeMutablePointer<Cell>.allocate(capacity: capacity)
            cells.initialize(repeating: sentinel, count: capacity)
            defer { cells.deinitialize(count: capacity); cells.deallocate() }
            for pattern in patterns {
                cells.update(repeating: sentinel, count: capacity)
                Grid.fill(cells + prefix, count, pattern)
                for index in 0 ..< capacity {
                    let expected = (prefix ..< prefix + count).contains(index) ? pattern : sentinel
                    #expect(cells[index] == expected, "count \(count), prefix \(prefix), index \(index)")
                }
            }
        }
    }

    @Test func `fast ASCII path matches general path`() {
        var fast = VT(7, 4), slow = VT(7, 4)
        let text = "\u{1B}[1;32mThe quick brown fox jumps over the lazy dog\u{1B}[0m 中x"
        fast.feed(text)
        for scalar in text.unicodeScalars {
            slow.feed(String(scalar)) // one scalar per call: no bulk path
        }
        #expect(TestFixture(fast.lines) == TestFixture(slow.lines))
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
            #expect(ok, Comment(rawValue: escapedTestText("invariant broken after step \(i)")))
            if !ok {
                break
            }
        }
    }
}

struct ResizePullTests {
    @Test func `growing keeps the top row when the cursor is not at the bottom`() {
        var vt = VT(10, 4)
        vt.feed("a\r\nb\r\nc\r\nd\r\ne\r\nf") // a, b in history; screen c..f
        vt.feed("\(CSI)2J\(CSI)H") // cleared, cursor at the top
        vt.feed("top")
        vt.state.resize(columns: 10, rows: 6)
        #expect(TestFixture(vt.lines[0]) == TestFixture("top"))
        #expect(vt.cursor == (3, 0))
    }

    @Test func `growing pulls history when the cursor is at the bottom`() {
        var vt = VT(10, 4)
        vt.feed("a\r\nb\r\nc\r\nd\r\ne\r\nf")
        vt.state.resize(columns: 10, rows: 6)
        #expect(TestFixture(vt.lines) == TestFixture(["a", "b", "c", "d", "e", "f"]))
        #expect(vt.cursor == (1, 5))
    }
}

struct ResizeShrinkTests {
    @Test func `shrinking drops blank rows before pulling history`() {
        var vt = VT(10, 6)
        vt.feed("a\r\nb\r\nc\r\nd\r\ne\r\nf\r\ng") // a in history
        vt.feed("\(CSI)2J\(CSI)H")
        vt.feed("top")
        vt.state.resize(columns: 10, rows: 3)
        #expect(TestFixture(vt.lines) == TestFixture(["top", "", ""]))
        vt.state.resize(columns: 10, rows: 6)
        #expect(TestFixture(vt.lines[0]) == TestFixture("top"))
    }
}

struct ResizeSelectionTests {
    @Test func `a height change keeps the selection on the same text`() {
        var vt = VT(10, 6)
        vt.feed("a\r\nb\r\nc\r\nd\r\ne\r\nf\r\ng\r\nhello") // history: a, b
        let row = vt.state.absoluteRow(viewportRow: 5)
        vt.state.setSelection(Selection(anchor: TerminalPoint(row: row, column: 0), head: TerminalPoint(row: row, column: 4)))
        #expect(vt.state.selectionText == "hello")
        vt.state.resize(columns: 10, rows: 3)
        #expect(vt.state.selectionText == "hello")
        vt.state.resize(columns: 10, rows: 8)
        #expect(vt.state.selectionText == "hello")
    }

    @Test func `a width change drops the selection`() {
        var vt = VT(10, 3)
        vt.feed("hello")
        vt.state.setSelection(Selection(anchor: TerminalPoint(row: 0, column: 0), head: TerminalPoint(row: 0, column: 4)))
        vt.state.resize(columns: 8, rows: 3)
        #expect(vt.state.selection == nil)
    }
}
