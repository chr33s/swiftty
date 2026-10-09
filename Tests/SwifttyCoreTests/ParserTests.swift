@testable import SwifttyCore
import Testing
import TestSupport

struct ParserTests {
    @Test(arguments: [
        ("lines and repeat", Array("12345678\r\nA\u{1B}[2b\r\n\r\n漢\u{301}\r\n#".utf8)),
        ("truncated three-byte UTF-8", [0xE2, 0x0D, 0x0A, 0x80, 0x61]),
        ("truncated four-byte UTF-8", [0xF0, 0x9F, 0x0D, 0x0A, 0x92, 0x61]),
        ("CSI parameters", Array("\u{1B}[31\r\nmA\r\n\u{1B}[0mB".utf8)),
        ("charset designation", Array("\u{1B}(\r\n0q\r\nq".utf8)),
        ("single shift", Array("\u{1B}*A\u{1B}N\r\n#\r\n#".utf8)),
        ("OSC payload", Array("\u{1B}]0;line\r\nname\u{07}A\r\n".utf8)),
        ("DCS payload", Array("\u{1B}P$q\r\nm\u{1B}\\A\r\n".utf8)),
        ("control-mode payload", Array("\u{1B}P1000p%begin 0 1 0\r\nvalue\r\n%end 0 1 0\r\n%exit\r\n\u{1B}\\A".utf8)),
    ].map(TestFixture.init), [false, true])
    func `CRLF dispatch matches bytewise parsing across modes and states`(_ sample: TestFixture<(String, [UInt8])>, _ newline: Bool) {
        let bytes = sample.value.1 + Array("\u{1B}[6n".utf8)
        let splits = Set([0, 1, 15, 16, 17, bytes.count - 1, bytes.count].filter { $0 <= bytes.count }
            + bytes.indices.filter { bytes[$0] == 0x0D }.map { $0 + 1 }).sorted()
        for columns in [1, 8, 17] {
            for margins in ["", "\u{1B}[2;4r", "\u{1B}[2;4r\u{1B}[?6h", "\u{1B}[?69h\u{1B}[2;7s\u{1B}[2;4r", "\u{1B}[?1049h"] {
                for split in splits {
                    var actual = VT(columns, 5, scrollback: 4096), reference = VT(columns, 5, scrollback: 4096)
                    let setup = "seed\r\nrow\r\nline\r\nbase\r\nlast\r\n" + margins
                        + "\u{1B}[20\(newline ? "h" : "l")\u{1B}[4;1H\u{1B}[44m"
                    actual.feed(setup)
                    reference.feed(setup)
                    let point = TerminalPoint(row: actual.state.absoluteRow(viewportRow: 3), column: 0)
                    actual.state.selection = Selection(anchor: point, head: point)
                    reference.state.selection = Selection(anchor: point, head: point)
                    _ = actual.state.takeDamage()
                    _ = reference.state.takeDamage()
                    actual.feed(bytes: Array(bytes[..<split]))
                    actual.feed(bytes: Array(bytes[split...]))
                    for byte in bytes {
                        reference.feed(bytes: [byte])
                    }
                    let cells = (0 ..< 5).flatMap { y in (0 ..< columns).map { actual.cell($0, y) } }
                    let expected = (0 ..< 5).flatMap { y in (0 ..< columns).map { reference.cell($0, y) } }
                    #expect(cells == expected)
                    #expect(TestFixture(actual.lines) == TestFixture(reference.lines))
                    #expect(actual.state.cursor == reference.state.cursor)
                    #expect(actual.state.lastPrinted == reference.state.lastPrinted)
                    #expect(actual.state.selection == reference.state.selection)
                    #expect(actual.state.takeDamage() == reference.state.takeDamage())
                    #expect(TestFixture(actual.state.output) == TestFixture(reference.state.output))
                    #expect(TestFixture(actual.state.events) == TestFixture(reference.state.events))
                    #expect(TestFixture(actual.state.controlModeData) == TestFixture(reference.state.controlModeData))
                    #expect(actual.parser.continuation.state == reference.parser.continuation.state)
                    #expect(actual.parser.continuation.controlModeLineStart == reference.parser.continuation.controlModeLineStart)
                    for y in 0 ..< 5 {
                        let extent = actual.state.grid.extent(y), expectedExtent = reference.state.grid.extent(y)
                        let wrapped = actual.state.grid.isWrapped(y), expectedWrapped = reference.state.grid.isWrapped(y)
                        let mark = actual.state.grid.mark(y), expectedMark = reference.state.grid.mark(y)
                        #expect(extent == expectedExtent)
                        #expect(wrapped == expectedWrapped)
                        #expect(mark == expectedMark)
                    }
                    let history = (0 ..< actual.state.scrollbackCount).map { actual.state.scrollbackText($0) }
                    let expectedHistory = (0 ..< reference.state.scrollbackCount).map { reference.state.scrollbackText($0) }
                    #expect(TestFixture(history) == TestFixture(expectedHistory))
                }
            }
        }
    }

    @Test(arguments: ["38", "48", "58"], [false, true])
    func `unknown semicolon color modes preserve following attributes`(_ target: String, _ fragmented: Bool) {
        let attributes: [(Int, CellFlags)] = [(0, []), (1, .bold), (3, .italic), (4, .underline), (7, .inverse)]
        for (parameter, flag) in attributes {
            var vt = VT(8, 3)
            vt.feed("\u{1B}[36;45;58;5;9m")
            var expected = parameter == 0 ? CellAttributes() : vt.state.cursor.pen
            expected.flags.formUnion([flag, .strikethrough])
            let input = "\u{1B}[\(target);\(parameter);9mX"
            if fragmented {
                for byte in input.utf8 {
                    vt.feed(bytes: [byte])
                }
            } else {
                vt.feed(input)
            }
            #expect(vt.cell(0, 0).attributes == expected, Comment(rawValue: escapedTestText("target=\(target) parameter=\(parameter)")))
        }
    }

    @Test(arguments: ["38", "48", "58"], [";", ":"])
    func `missing indexed colors preserve the pen and parsing resumes`(_ target: String, _ separator: String) {
        var vt = VT(8, 3)
        vt.feed("\u{1B}[1;3;36;45;58;5;9m")
        let original = vt.state.cursor.pen
        vt.feed("\u{1B}[\(target)\(separator)5mX\u{1B}[9mY")
        #expect(vt.cell(0, 0).attributes == original)
        var following = original
        following.flags.insert(.strikethrough)
        #expect(vt.cell(1, 0).attributes == following)
        #expect(TestFixture(vt.lines) == TestFixture(["XY", "", ""]))
    }

    @Test(arguments: [
        "0:4", "1:0", "3:31", "31:1", "999:2:0", "4:3:1", "4:0:31",
        "38:2:1:2:3:4:5", "48:2:1:2:3:4:5", "58:2:1:2:3:4:5",
    ], [false, true])
    func `malformed SGR colon groups preserve the pen and skip their subparameters`(_ group: String, _ split: Bool) {
        var vt = VT(8, 3)
        vt.feed("\u{1B}[1;3;4;36;45;58;5;9m")
        let original = vt.state.cursor.pen
        let input = "\u{1B}[" + group + "mX\u{1B}[" + group + ";9mY"
        if split {
            for byte in input.utf8 {
                vt.feed(bytes: [byte])
            }
        } else {
            vt.feed(input)
        }
        #expect(vt.cell(0, 0).attributes == original)
        var following = original
        following.flags.insert(.strikethrough)
        #expect(vt.cell(1, 0).attributes == following)
        #expect(TestFixture(vt.lines) == TestFixture(["XY", "", ""]))
    }

    @Test(arguments: ["38", "48", "58"], [":2:11:22:33", ":2::11:22:33", ":2:0:11:22:33"])
    func `SGR colon RGB accepts three components and an optional colorspace`(_ target: String, _ parameters: String) {
        var vt = VT(8, 3)
        vt.feed("\u{1B}[" + target + parameters + ";9mX")
        let attributes = vt.cell(0, 0).attributes
        let actual: TerminalColor = switch target {
        case "38": attributes.foreground
        case "48": attributes.background
        default: vt.state.underlineColor(attributes.underlineColor) ?? .default
        }
        #expect(actual == .rgb(11, 22, 33))
        #expect(attributes.flags == .strikethrough)
    }

    @Test(arguments: [UInt8(0x80), 0x81], [false, true])
    func `raw C1 controls still cancel a pending ESC sequence`(_ byte: UInt8, _ intermediate: Bool) {
        var vt = VT(8, 3)
        vt.feed("abc\u{1B}" + (intermediate ? "#" : ""))
        vt.feed(bytes: [byte])
        vt.feed(intermediate ? "8" : "c")
        #expect(TestFixture(vt.lines) == TestFixture([intermediate ? "abc8" : "abcc", "", ""]))
    }

    @Test(arguments: [
        ("", "D", ["abc", "   q", ""]),
        ("(", "0", ["abc─", "", ""]),
        ("#", "8", ["qEEEEEEE", "EEEEEEEE", "EEEEEEEE"]),
    ], [(UInt8(0xA0), false), (0xA0, true), (0xC3, false), (0xC3, true), (0xFF, false), (0xFF, true)])
    func `high bytes do not terminate ESC sequences`(_ fixture: (String, String, [String]), _ delivery: (UInt8, Bool)) {
        var vt = VT(8, 3)
        vt.feed("abc")
        let input = Array(("\u{1B}" + fixture.0).utf8) + [delivery.0] + Array((fixture.1 + "q").utf8)
        if delivery.1 {
            for byte in input {
                vt.feed(bytes: [byte])
            }
        } else {
            vt.feed(bytes: input)
        }
        #expect(TestFixture(vt.lines) == TestFixture(fixture.2))
    }

    @Test(arguments: ["1m", "31m", "2J", "3H"], [false, true])
    func `CSI cannot start with a colon parameter separator`(_ suffix: String, _ split: Bool) {
        var vt = VT(8, 3)
        vt.feed("abc\u{1B}[3;36m\u{1B}[2;4H")
        let pen = vt.state.cursor.pen
        let input = "\u{1B}[:" + suffix
        if split {
            for byte in input.utf8 {
                vt.feed(bytes: [byte])
            }
        } else {
            vt.feed(input)
        }
        #expect(vt.state.cursor.pen == pen)
        #expect(vt.cursor == (3, 1))
        #expect(TestFixture(vt.lines) == TestFixture(["abc", "", ""]))
        vt.feed("Z")
        #expect(vt.cell(3, 1).glyph == 0x5A)
    }

    @Test(arguments: [
        ("abc", "# 8", "abcq"),
        ("abc", "( 0", "abcq"),
        ("abc\u{1B}(0", "(  B", "abc─"),
        ("abc", "# \u{07}\u{7F}8", "abcq"),
    ].map(TestFixture.init), [false, true])
    func `multiple ESC intermediates do not execute prefix commands`(_ fixture: TestFixture<(String, String, String)>, _ split: Bool) {
        let fixture = fixture.value
        var vt = VT(8, 3)
        vt.feed(fixture.0)
        let input = "\u{1B}" + fixture.1 + "q"
        if split {
            for byte in input.utf8 {
                vt.feed(bytes: [byte])
            }
        } else {
            vt.feed(input)
        }
        #expect(TestFixture(vt.lines) == TestFixture([fixture.2, "", ""]))
        #expect(TestFixture(vt.state.events) == TestFixture(fixture.1.contains("\u{07}") ? [.bell] : []))
    }

    @Test(arguments: ["6  q", "1\" q", "! p", "?25$ p"], [false, true])
    func `multiple CSI intermediates do not execute prefix commands`(_ sequence: String, _ split: Bool) {
        var vt = VT(8, 3)
        vt.feed("abc\u{1B}[3;31m\u{1B}[2;4H")
        let pen = vt.state.cursor.pen
        let modes = vt.state.modes
        let style = vt.state.cursorStyle
        let input = "\u{1B}[" + sequence
        if split {
            for byte in input.utf8 {
                vt.feed(bytes: [byte])
            }
        } else {
            vt.feed(input)
        }
        #expect(vt.state.cursor.pen == pen)
        #expect(vt.state.cursor.x == 3)
        #expect(vt.state.cursor.y == 1)
        #expect(vt.state.cursorStyle == style)
        #expect(vt.state.modes == modes)
        #expect(TestFixture(vt.takeOutput().isEmpty) == TestFixture(true))
        vt.feed("Z")
        #expect(TestFixture(vt.lines) == TestFixture(["abc", "   Z", ""]))
    }

    @Test(arguments: [(23, false), (24, false), (24, true), (25, false), (48, false)], [false, true])
    func `SGR parameter overflow discards the whole sequence`(_ fixture: (Int, Bool), _ split: Bool) {
        let (count, trailingEmpty) = fixture
        var vt = VT(8, 3)
        vt.feed("\u{1B}[3;36m")
        let original = vt.state.cursor.pen
        let parameters = Array(repeating: "1", count: count - 1) + ["31"]
        let input = "\u{1B}[" + parameters.joined(separator: ";") + (trailingEmpty ? ";" : "") + "mZ"
        if split {
            for byte in input.utf8 {
                vt.feed(bytes: [byte])
            }
        } else {
            vt.feed(input)
        }
        if count + (trailingEmpty ? 1 : 0) <= CSISequence.maxParams {
            #expect(vt.cell(0, 0).attributes.flags.isSuperset(of: [.bold, .italic]))
            #expect(vt.cell(0, 0).attributes.foreground == .palette(1))
        } else {
            #expect(vt.cell(0, 0).attributes == original)
        }
        #expect(TestFixture(vt.lines[0]) == TestFixture("Z"))
        vt.feed("\u{1B}[0mY")
        #expect(vt.cell(1, 0).attributes == CellAttributes())
    }

    @Test(arguments: [
        "1:2H", "2:J", "2:K", "?25:1l", "6:n", "=10:1u", "1:\"q", "6: q",
        String(repeating: "1;", count: CSISequence.maxParams) + ":H",
    ], [false, true])
    func `colon parameters outside SGR are ignored`(_ sequence: String, _ split: Bool) {
        var vt = VT(8, 3)
        vt.feed("abcdef\r\nghijkl\u{1B}[2;4H")
        let lines = vt.lines
        let modes = vt.state.modes
        let pen = vt.state.cursor.pen
        let style = vt.state.cursorStyle
        let input = "\u{1B}[" + sequence
        if split {
            for byte in input.utf8 {
                vt.feed(bytes: [byte])
            }
        } else {
            vt.feed(input)
        }
        #expect(TestFixture(vt.lines) == TestFixture(lines))
        #expect(vt.state.cursor.x == 3)
        #expect(vt.state.cursor.y == 1)
        #expect(vt.state.modes == modes)
        #expect(vt.state.cursor.pen == pen)
        #expect(vt.state.cursorStyle == style)
        #expect(vt.state.keyboardFlags == 0)
        #expect(vt.state.output.isEmpty)
        vt.feed("Z") // The rejected sequence must still return to ground.
        #expect(vt.cell(3, 1).glyph == 0x5A)
    }

    @Test(arguments: [Int.min, -1, 1, CSISequence.maxParams, Int.max])
    func `CSI parameter access treats out of range indices as missing`(_ index: Int) {
        var sequence = CSISequence()
        sequence.count = 1
        sequence.params[0] = 7
        sequence.colonMask = 1
        #expect(sequence.value(0) == 7)
        #expect(sequence.param(0, default: 99) == 7)
        #expect(sequence.isSubparameter(0))
        #expect(sequence.value(index) == 0)
        #expect(sequence.param(index, default: 99) == 99)
        #expect(!sequence.isSubparameter(index))
    }

    @Test func `legacy combining marks stop at the horizontal margin with autowrap disabled`() {
        var vt = VT(6, 2)
        vt.feed("\u{1B}[?2027l\u{1B}[?7l\u{1B}[?69h\u{1B}[2;4s\u{1B}[1;2Haae\u{301}")
        #expect(vt.state.scalars(of: vt.cell(3, 0)) == Array("e\u{301}".unicodeScalars))
        #expect(vt.cell(2, 0).glyph == 0x61)
        #expect(vt.state.cursor.x == 3)
        #expect(vt.state.cursor.y == 0)
    }

    @Test func `legacy combining marks before a populated rightmost cell attach to the new text`() {
        var vt = VT(4, 2)
        vt.feed("\u{1B}[?2027l\u{1B}[?7labcZ\u{1B}[1;3He\u{301}")
        #expect(TestFixture(vt.lines) == TestFixture(["abe\u{301}Z", ""]))
        #expect(!vt.cell(3, 0).isGrapheme)
    }

    @Test(arguments: [1, 4], [false, true])
    func `legacy combining marks attach to the last printed cell at the right edge`(_ columns: Int, _ autowrap: Bool) {
        var vt = VT(columns, 2)
        vt.feed("\u{1B}[?2027l")
        if !autowrap {
            vt.feed("\u{1B}[?7l")
        }
        let input = String(repeating: "a", count: columns - 1) + "e\u{301}"
        for byte in input.utf8 {
            vt.feed(bytes: [byte])
        }
        #expect(TestFixture(vt.lines) == TestFixture([input, ""]))
        #expect(vt.state.scalars(of: vt.cell(columns - 1, 0)) == Array("e\u{301}".unicodeScalars))
        #expect(vt.state.cursor.x == columns - 1)
        #expect(vt.state.cursor.y == 0)
    }

    @Test(arguments: [false, true])
    func `ignored selectors do not change the preceding scalar for joining`(_ split: Bool) {
        let input = "😀\u{200D}\u{FE0F}©"
        var vt = VT(10, 2)
        if split {
            for byte in input.utf8 {
                vt.feed(bytes: [byte])
            }
        } else {
            vt.feed(input)
        }
        #expect(vt.state.scalars(of: vt.cell(0, 0)) == Array("😀\u{200D}©".unicodeScalars))
        #expect(vt.state.cursor.x == 2)
    }

    @Test(arguments: ["\u{D4E}é", "\u{D4E}©", "\u{D4E}®", "😀\u{200D}©", "😀\u{200D}®"], [false, true])
    func `low codepoint scalars can finish Unicode grapheme clusters`(_ text: String, _ split: Bool) {
        var vt = VT(10, 2)
        if split {
            for byte in text.utf8 {
                vt.feed(bytes: [byte])
            }
        } else {
            vt.feed(text)
        }
        #expect(vt.cell(0, 0).isGrapheme)
        #expect(vt.cell(0, 0).width == 2)
        #expect(vt.state.scalars(of: vt.cell(0, 0)) == Array(text.unicodeScalars))
        #expect(vt.cell(1, 0).isSpacer)
        #expect(vt.state.cursor.x == 2)
    }

    @Test(arguments: [1, 10])
    func `leading combining marks do not inspect a preceding cell`(_ columns: Int) {
        var vt = VT(columns, 2)
        vt.feed("\u{301}e")
        #expect(TestFixture(vt.lines) == TestFixture(["e", ""]))
        #expect(!vt.cell(0, 0).isGrapheme)
    }

    @Test(arguments: [false, true])
    func `single column terminals keep combining marks on the last cell`(_ autowrap: Bool) {
        var vt = VT(1, 2)
        if !autowrap {
            vt.feed("\u{1B}[?7l")
        }
        vt.feed("e\u{301}")
        #expect(TestFixture(vt.lines) == TestFixture(["e\u{301}", ""]))
        #expect(vt.cell(0, 0).isGrapheme)
        #expect(vt.state.cursor.pendingWrap)
        if autowrap {
            vt.feed("x")
            #expect(TestFixture(vt.lines) == TestFixture(["e\u{301}", "x"]))
        }
    }

    @Test(arguments: [
        ("rgb:f/0/8", UInt32(0xFF0088)),
        ("rgb:ff/00/80", UInt32(0xFF0080)),
        ("rgb:fff/000/808", UInt32(0xFF0080)),
        ("rgb:ffff/0000/8080", UInt32(0xFF0080)),
        ("#fF0080", UInt32(0xFF0080)),
    ])
    func `valid color specifications retain component scaling`(_ color: String, _ expected: UInt32) {
        var vt = VT()
        vt.feed("\(ESC)]11;\(color)\u{07}\(ESC)]4;1;\(color)\u{07}")
        #expect(vt.state.palette.background == expected)
        #expect(vt.state.palette.colors[1] == expected)
    }

    @Test(arguments: ["rgb:/ff/00/00", "rgb:ff//00/00", "rgb:ff/00/00/", "rgb:ff/00/00//", "rgb:+f/00/00", "rgb:ff/+0/00", "#+12345"])
    func `malformed color specifications preserve the palette`(_ color: String) {
        var vt = VT()
        let background = vt.state.palette.background
        let indexed = vt.state.palette.colors[1]
        vt.feed("\(ESC)]11;\(color)\u{07}\(ESC)]4;1;\(color)\u{07}")
        #expect(vt.state.palette.background == background)
        #expect(vt.state.palette.colors[1] == indexed)
    }

    @Test func `printable ASCII`() {
        var vt = VT()
        vt.feed("hello")
        #expect(TestFixture(vt.lines[0]) == TestFixture("hello"))
        #expect(vt.cursor == (5, 0))
    }

    @Test func `utf 8 multibyte and split across buffers`() {
        var vt = VT()
        let bytes = Array("é€😀".utf8)
        for b in bytes {
            vt.feed(bytes: [b])
        } // one byte at a time
        #expect(TestFixture(vt.lines[0]) == TestFixture("é€😀"))
        #expect(vt.cursor == (4, 0)) // é(1) €(1) 😀(2)
    }

    @Test func `malformed UTF 8 becomes replacement`() {
        var vt = VT()
        vt.feed(bytes: [0x41, 0xC3, 0x41, 0xFF, 0xE2, 0x82, 0x42, 0xED, 0xA0, 0x80])
        // C3 41: truncated → U+FFFD, A; FF invalid; E2 82 42 truncated; ED A0 80 surrogate
        #expect(TestFixture(vt.lines[0]) == TestFixture("A\u{FFFD}A\u{FFFD}\u{FFFD}B\u{FFFD}"))
    }

    @Test func `three byte sequences valid surrogate and truncated`() {
        var vt = VT(20, 1)
        // E4 B8 AD = 中; ED A0 80 = surrogate (one U+FFFD); E1 41 = truncated
        // (one U+FFFD, then "A" is reprocessed); EF BF BD = U+FFFD itself.
        vt.feed(bytes: [0xE4, 0xB8, 0xAD, 0xED, 0xA0, 0x80, 0xE1, 0x41, 0xEF, 0xBF, 0xBD, 0x7A])
        #expect(TestFixture(vt.lines[0]) == TestFixture("中\u{FFFD}\u{FFFD}A\u{FFFD}z"))
    }

    @Test func `bulk three byte decode matches byte at a time`() {
        let text = "日本語中文字符한국어漢字東京大阪" + "\u{E000}\u{FFFD}\u{0800}\u{D7FF}\u{E000}"
        var batched = VT(80, 2), single = VT(80, 2)
        batched.feed(text)
        for b in Array(text.utf8) {
            single.feed(bytes: [b])
        }
        #expect(TestFixture(batched.lines) == TestFixture(single.lines))
        // U+D7FF is zero-width with nothing to join, so it is dropped (as in Ghostty).
        #expect(TestFixture(batched.lines[0].unicodeScalars.elementsEqual(text.unicodeScalars.filter { $0.value != 0xD7FF })) ==
            TestFixture(true))
        // A surrogate inside an otherwise valid 12-byte window falls back.
        var mixed = VT(20, 1)
        mixed.feed(bytes: [0xE4, 0xB8, 0xAD, 0xED, 0xA0, 0x80, 0xE4, 0xB8, 0xAD, 0xE4, 0xB8, 0xAD])
        #expect(TestFixture(mixed.lines[0]) == TestFixture("中\u{FFFD}中中"))
    }

    @Test(arguments: [0, 1, 2, 3])
    func `UTF 8 runs match bytewise input with every changed block byte`(_ prefix: Int) {
        let initial = Array(String(repeating: "é", count: prefix).utf8)
        let block = Array("漢字一\u{9FFF}abcd".utf8)
        for position in block.indices {
            for value in UInt8.min ... UInt8.max {
                var bytes = block
                bytes[position] = value
                expectUTF8RunMatchesBytewise(bytes, prefix: initial, context: "prefix=\(prefix), position=\(position), byte=\(value)")
            }
        }
    }

    @Test(arguments: Array(0 ..< 16))
    func `UTF 8 two byte runs match bytewise input with every changed block byte`(_ prefix: Int) {
        let initial = Array(String(repeating: "漢", count: prefix).utf8)
        let block = Array(String(repeating: "\u{80}©éœδя\u{7FE}\u{7FF}", count: 2).utf8)
        for position in block.indices {
            for value in UInt8.min ... UInt8.max {
                var bytes = block
                bytes[position] = value
                expectUTF8RunMatchesBytewise(bytes, prefix: initial, context: "prefix=\(prefix), position=\(position), byte=\(value)")
            }
        }
    }

    @Test(arguments: Array(0 ..< 16) + Array(1008 ... 1025))
    func `UTF 8 two byte runs preserve ordering at scratch and input boundaries`(_ prefix: Int) {
        let text = String(repeating: "漢", count: prefix) + String(repeating: "\u{80}©éœδя\u{7FE}\u{7FF}", count: 3) + "😀a"
        let bytes = Array(text.utf8)
        let boundary = prefix * 3
        for split in Array(boundary ... boundary + 32) + [bytes.count - 1, bytes.count] {
            var actual = VT(65, 20), reference = VT(65, 20)
            actual.feed(bytes: Array(bytes[..<split]))
            actual.feed(bytes: Array(bytes[split...]))
            for byte in bytes {
                reference.feed(bytes: [byte])
            }
            #expect(TestFixture(actual.lines) == TestFixture(reference.lines))
            #expect(actual.state.cursor == reference.state.cursor)
            let history = (0 ..< actual.state.scrollbackCount).map { actual.state.scrollbackText($0) }
            let expected = (0 ..< reference.state.scrollbackCount).map { reference.state.scrollbackText($0) }
            #expect(history == expected)
        }
    }

    private func expectUTF8RunMatchesBytewise(_ bytes: [UInt8], prefix: [UInt8], context: String) {
        var actual = VT(32, 3, scrollback: 0), reference = VT(32, 3, scrollback: 0)
        actual.feed(bytes: prefix + bytes)
        for byte in prefix + bytes {
            reference.feed(bytes: [byte])
        }
        let followup = Array("éA\u{1B}[6n".utf8)
        actual.feed(bytes: followup)
        for byte in followup {
            reference.feed(bytes: [byte])
        }
        #expect(TestFixture(actual.lines) == TestFixture(reference.lines), Comment(rawValue: escapedTestText("\(context)")))
        #expect(actual.cursor == reference.cursor, Comment(rawValue: escapedTestText("\(context)")))
        #expect(actual.state.output == reference.state.output, Comment(rawValue: escapedTestText("\(context)")))
        let events = actual.state.takeEvents(), expectedEvents = reference.state.takeEvents()
        #expect(events == expectedEvents, Comment(rawValue: escapedTestText("\(context)")))
    }

    @Test(arguments: [0, 1, 2, 3], [0, 1, 2, 3])
    func `UTF 8 runs validate overlong and surrogate sequences in every lane`(_ prefix: Int, _ lane: Int) {
        let initial = Array(String(repeating: "é", count: prefix).utf8)
        let boundaries: [[UInt8]] = [
            [0xE0, 0x80, 0x80], [0xE0, 0x9F, 0xBF], [0xE0, 0xA0, 0x80],
            [0xED, 0x9F, 0xBF], [0xED, 0xA0, 0x80], [0xED, 0xBF, 0xBF],
            [0xEE, 0x80, 0x80], [0xEF, 0xBF, 0xBF], [0xF0, 0x90, 0x80],
        ]
        for triple in boundaries {
            var bytes = Array("漢字一\u{9FFF}abcd".utf8)
            bytes.replaceSubrange(lane * 3 ..< lane * 3 + 3, with: triple)
            expectUTF8RunMatchesBytewise(bytes, prefix: initial, context: "prefix=\(prefix), lane=\(lane), bytes=\(triple)")
        }
    }

    @Test(arguments: [0, 1, 2, 3, 1019, 1020, 1021, 1022, 1023, 1024])
    func `UTF 8 runs preserve ordering around scratch capacity`(_ prefix: Int) {
        let text = String(repeating: "é", count: prefix) + String(repeating: "漢字一\u{9FFF}", count: 5) + "é😀a"
        let bytes = Array(text.utf8)
        for split in [0, 1, 2, bytes.count - 1, bytes.count] {
            var actual = VT(33, 3, scrollback: 4096), reference = VT(33, 3, scrollback: 4096)
            actual.feed(bytes: Array(bytes.prefix(split)))
            actual.feed(bytes: Array(bytes.dropFirst(split)))
            for byte in bytes {
                reference.feed(bytes: [byte])
            }
            #expect(TestFixture(actual.lines) == TestFixture(reference.lines))
            #expect(actual.cursor == reference.cursor)
            let history = (0 ..< actual.state.scrollbackCount).map { actual.state.scrollbackText($0) }
            let expected = (0 ..< reference.state.scrollbackCount).map { reference.state.scrollbackText($0) }
            #expect(history == expected)
        }
    }

    @Test(arguments: [0, 1, 2, 3])
    func `three byte decoding matches incremental decoding at continuation boundaries`(_ split: Int) {
        let tails: [UInt8] = [0, 0x7F, 0x80, 0x8F, 0x9F, 0xA0, 0xBF, 0xC0, 0xFF]
        for lead in UInt8(0xE0) ... 0xEF {
            for first in tails {
                for second in tails {
                    let bytes = [lead, first, second]
                    var actual = VT(12, 1, scrollback: 0), reference = VT(12, 1, scrollback: 0)
                    actual.feed("a")
                    reference.feed("a")
                    actual.feed(bytes: Array(bytes.prefix(split)))
                    actual.feed(bytes: Array(bytes.dropFirst(split)) + [0x7A])
                    for byte in bytes + [0x7A] {
                        reference.feed(bytes: [byte])
                    }
                    #expect(TestFixture(actual.lines) == TestFixture(reference.lines), Comment(rawValue: escapedTestText("bytes=\(bytes)")))
                    #expect(actual.cursor == reference.cursor, Comment(rawValue: escapedTestText("bytes=\(bytes)")))
                }
            }
        }
    }

    @Test func `c 0 controls`() {
        var vt = VT()
        vt.feed("ab\rc\n d\u{08}e\tf")
        #expect(TestFixture(vt.lines[0]) == TestFixture("cb"))
        #expect(TestFixture(vt.lines[1]) == TestFixture("  e     f"))
        vt.feed("\u{07}")
        do { let ok = vt.state.events.contains(.bell); #expect(ok, Comment(rawValue: escapedTestText("vt.state.events.contains(.bell)"))) }
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
        #expect(TestFixture(vt.lines[4].hasSuffix("ok")) == TestFixture(true))
    }

    @Test func `erase operations`() {
        var vt = VT(5, 3)
        vt.feed("aaaaa\(CSI)2;1Hbbbbb\(CSI)3;1Hccccc")
        vt.feed("\(CSI)2;3H\(CSI)K")
        #expect(TestFixture(vt.lines) == TestFixture(["aaaaa", "bb", "ccccc"]))
        vt.feed("\(CSI)1K")
        #expect(TestFixture(vt.lines[1]) == TestFixture(""))
        vt.feed("\(CSI)1;2H\(CSI)1J")
        #expect(TestFixture(vt.lines) == TestFixture(["  aaa", "", "ccccc"]))
        vt.feed("\(CSI)J")
        #expect(TestFixture(vt.lines) == TestFixture(["", "", ""]))
        vt.feed("xyz\(CSI)1;1H\(CSI)2X")
        #expect(TestFixture(vt.lines[0]) == TestFixture("  yz"))
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
        #expect(TestFixture(vt.lines[0]) == TestFixture("xy"))
    }

    @Test func `osc clipboard and color query`() {
        var vt = VT()
        vt.feed("\(ESC)]52;c;aGVsbG8=\u{07}")
        do { let ok = vt.state.events.last == .clipboard("hello"); #expect(
            ok,
            Comment(rawValue: escapedTestText("vt.state.events.last == .clipboard(\"hello\")")),
        ) }
        vt.feed("\(ESC)]52;c;?\u{07}") // reads refused
        #expect(TestFixture(vt.takeOutput().isEmpty) == TestFixture(true))
        vt.feed("\(ESC)]11;?\u{07}")
        #expect(TestFixture(vt.takeOutput()) == TestFixture("\(ESC)]11;rgb:2828/2c2c/3434\u{07}"))
        vt.feed("\(ESC)]4;1;rgb:ff/00/80\(ESC)\\\(ESC)]4;1;?\(ESC)\\")
        #expect(TestFixture(vt.takeOutput()) == TestFixture("\(ESC)]4;1;rgb:ffff/0000/8080\(ESC)\\"))
    }

    @Test func `unsupported sequences are ignored`() {
        var vt = VT()
        vt.feed("a\(ESC)P1$qm\(ESC)\\b\(CSI)?999h\(CSI)>4;1m\(CSI)=5uc\(ESC)_apc\(ESC)\\d\(ESC)^pm\(ESC)\\e")
        vt.feed("\(ESC)]999;whatever\u{07}f\(CSI)1;2;3$zg")
        #expect(TestFixture(vt.lines[0]) == TestFixture("abcdefg"))
    }

    @Test func `cancel aborts sequence`() {
        var vt = VT()
        vt.feed("\(CSI)31\u{18}x\(ESC)]0;t\u{1A}y")
        #expect(TestFixture(vt.lines[0]) == TestFixture("xy"))
        #expect(vt.cell(0, 0).attributes == .default)
        do { let ok = vt.state.events.isEmpty; #expect(ok, Comment(rawValue: escapedTestText("vt.state.events.isEmpty"))) }
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
            Comment(
                rawValue: escapedTestText(
                    "vt.state.modes.isSuperset(of: [.cursorKeys, .bracketedPaste, .mouseSGR, .mouseButton, .insert])",
                ),
            ),
        ) }
        vt.feed("\(CSI)?1003h")
        do { let ok = vt.state.modes.contains(.mouseAny) && !vt.state.modes.contains(.mouseButton); #expect(
            ok,
            Comment(rawValue: escapedTestText("vt.state.modes.contains(.mouseAny) && !vt.state.modes.contains(.mouseButton)")),
        ) }
        vt.feed("\(CSI)?25l\(CSI)?1;25$p")
        do { let ok = !vt.state.modes.contains(.cursorVisible); #expect(
            ok,
            Comment(rawValue: escapedTestText("!vt.state.modes.contains(.cursorVisible)")),
        ) }
        #expect(TestFixture(vt.takeOutput()) == TestFixture("\(CSI)?1;1$y"))
        vt.feed("\(CSI)3;4H\(CSI)6n\(CSI)5n\(CSI)c\(CSI)>c\(CSI)18t")
        #expect(TestFixture(vt.takeOutput()) == TestFixture("\(CSI)3;4R\(CSI)0n\(CSI)?62;22c\(CSI)>1;10;0c\(CSI)8;5;10t"))
    }

    @Test func `simd scan stops at controls`() {
        let bytes = Array((String(repeating: "x", count: 37) + "\u{1B}" + String(repeating: "y", count: 20)).utf8)
        let end = bytes.withUnsafeBufferPointer { Parser.scanPrintableASCII($0.baseAddress!, from: 0, to: $0.count) }
        #expect(end == 37)
        let mid = bytes.withUnsafeBufferPointer { Parser.scanPrintableASCII($0.baseAddress!, from: 38, to: $0.count) }
        #expect(mid == bytes.count)
    }

    @Test(arguments: [0, 1, 15, 16], [0, 1, 15, 16, 17, 31, 32, 33])
    func `ASCII scan respects every stop byte and range boundary`(_ start: Int, _ length: Int) {
        let end = start + length
        var bytes = [UInt8](repeating: 0x1B, count: start)
        bytes.append(contentsOf: repeatElement(UInt8(0x20), count: length))
        bytes.append(contentsOf: repeatElement(UInt8(0xFF), count: 16))
        let complete = bytes.withUnsafeBufferPointer { Parser.scanPrintableASCII($0.baseAddress!, from: start, to: end) }
        #expect(complete == end)
        for position in start ..< end {
            for byte in UInt16(0) ... 255 where byte < 0x20 || byte > 0x7E {
                bytes[position] = UInt8(byte)
                let stopped = bytes.withUnsafeBufferPointer { Parser.scanPrintableASCII($0.baseAddress!, from: start, to: end) }
                #expect(stopped == position)
            }
            bytes[position] = 0x20
        }
        for byte in UInt8(0x20) ... 0x7E {
            for position in start ..< end {
                bytes[position] = byte
            }
            let printable = bytes.withUnsafeBufferPointer { Parser.scanPrintableASCII($0.baseAddress!, from: start, to: end) }
            #expect(printable == end)
        }
    }

    @Test func `dec special graphics`() {
        var vt = VT()
        vt.feed("\(ESC)(0lqk\(ESC)(Bq\u{0E}")
        #expect(TestFixture(vt.lines[0]) == TestFixture("┌─┐q"))
        vt.feed("\(ESC))0\u{0E}x\u{0F}x")
        #expect(TestFixture(vt.lines[0]) == TestFixture("┌─┐q│x"))
    }
}
