@testable import SwifttyCore
import Testing
import TestSupport

struct SavedCursorTests {
    @Test(arguments: ["", "0", "0;0", "2;7"], [(false, false), (false, true), (true, false), (true, true)])
    func `CSI margin commands preserve the saved cursor when margin mode is enabled`(_ parameters: String, _ options: (Bool, Bool)) {
        let (alternate, fragmented) = options
        var vt = VT(8, 4)
        if alternate {
            vt.feed("\(CSI)?1049h")
        }
        vt.feed("\(CSI)2;3H\(CSI)31m\(ESC)7")
        let saved = vt.state.cursor
        vt.feed("\(CSI)?69h\(CSI)3;6s\(CSI)3;4H\(CSI)34m\(ESC)(A")
        let command = "\(CSI)\(parameters)s"
        if fragmented {
            for byte in command.utf8 {
                vt.feed(bytes: [byte])
            }
        } else {
            vt.feed(command)
        }
        #expect(vt.cursor == (0, 0))
        #expect(vt.state.scrollLeft == (parameters == "2;7" ? 1 : 0))
        #expect(vt.state.scrollRight == (parameters == "2;7" ? 6 : 7))
        vt.feed("\(ESC)8#")
        #expect(vt.cursor == (saved.x + 1, saved.y))
        #expect(vt.cell(saved.x, saved.y).glyph == 0x23)
        #expect(vt.cell(saved.x, saved.y).attributes == saved.pen)
    }

    @Test(arguments: ["", "0", "1", "0;0", "1;2", "0:0"], [(false, false), (false, true), (true, false), (true, true)])
    func `CSI cursor saving accepts only omitted parameters outside margin mode`(_ parameters: String, _ options: (Bool, Bool)) {
        let (alternate, fragmented) = options
        var vt = VT(8, 4)
        if alternate {
            vt.feed("\(CSI)?1049h")
        }
        vt.feed("\(CSI)2;3H\(CSI)31m\(ESC)7")
        let original = vt.state.cursor
        vt.feed("\(CSI)3;4H\(CSI)34m\(ESC)(A")
        let current = vt.state.cursor
        let command = "\(CSI)\(parameters)s"
        if fragmented {
            for byte in command.utf8 {
                vt.feed(bytes: [byte])
            }
        } else {
            vt.feed(command)
        }
        #expect(vt.state.cursor == current)
        #expect(vt.state.scrollLeft == 0)
        #expect(vt.state.scrollRight == 7)
        vt.feed("\(CSI)H\(ESC)8")
        let expected = parameters.isEmpty ? current : original
        #expect(vt.state.cursor == expected)
        vt.feed("#")
        #expect(vt.cell(expected.x, expected.y).glyph == (parameters.isEmpty ? 0xA3 : 0x23))
        #expect(vt.cell(expected.x, expected.y).attributes == expected.pen)
    }

    @Test(arguments: ["", "0", "1", "0;0", "1;2", "0:0"], [(false, false), (false, true), (true, false), (true, true)])
    func `CSI cursor restore accepts semicolon parameters and ignores colon commands`(_ parameters: String, _ options: (Bool, Bool)) {
        let (alternate, fragmented) = options
        var vt = VT(8, 4)
        if alternate {
            vt.feed("\(CSI)?1049h")
        }
        vt.feed("\(CSI)2;3H\(CSI)31m\(ESC)(A\(ESC)7")
        let saved = vt.state.cursor
        vt.feed("\(CSI)3;4H\(CSI)34m\(ESC)(B")
        let current = vt.state.cursor
        let command = "\(CSI)\(parameters)u"
        if fragmented {
            for byte in command.utf8 {
                vt.feed(bytes: [byte])
            }
        } else {
            vt.feed(command)
        }
        let ignored = parameters.contains(":")
        let expected = ignored ? current : saved
        #expect(vt.state.cursor == expected)
        vt.feed("#")
        #expect(vt.cell(expected.x, expected.y).glyph == (ignored ? 0x23 : 0xA3))
        #expect(vt.cell(expected.x, expected.y).attributes == expected.pen)
    }

    @Test(arguments: [2, 3], [("\u{1B}7", "\u{1B}8"), ("\u{1B}[s", "\u{1B}[u"), ("\u{1B}[?1048h", "\u{1B}[?1048l")].map(TestFixture.init))
    func `restored single shifts translate exactly the next printed character`(_ slot: Int, _ commands: TestFixture<(String, String)>) {
        let commands = commands.value
        for alternate in [false, true] {
            var vt = VT(8, 3)
            if alternate {
                vt.feed("\u{1B}[?1049h")
            }
            let designation = slot == 2 ? "\u{1B}*A" : "\u{1B}+A"
            let shift = slot == 2 ? "\u{1B}N" : "\u{1B}O"
            vt.feed(designation + shift + commands.0 + "#")
            #expect(vt.cell(0, 0).glyph == 0xA3)
            #expect(vt.state.cursor.singleShift == nil)
            vt.feed("\u{1B}[H" + commands.1 + "##")
            #expect(vt.cell(0, 0).glyph == 0xA3)
            #expect(vt.cell(1, 0).glyph == 0x23)
            #expect(vt.state.cursor.singleShift == nil)
            #expect(vt.cursor == (2, 0))
        }
    }

    @Test(
        arguments: Array(0 ... 3),
        [("\u{1B}7", "\u{1B}8"), ("\u{1B}[s", "\u{1B}[u"), ("\u{1B}[?1048h", "\u{1B}[?1048l")].map(TestFixture.init),
    )
    func `cursor restore reinstates GL character sets and styled printing on each screen`(
        _ slot: Int,
        _ commands: TestFixture<(String, String)>,
    ) {
        let commands = commands.value
        for alternate in [false, true] {
            var vt = VT(8, 3)
            if alternate {
                vt.feed("\u{1B}[?1049h")
            }
            let designator = ["(", ")", "*", "+"][slot]
            let invoke = ["\u{0F}", "\u{0E}", "\u{1B}n", "\u{1B}o"][slot]
            vt.feed("\u{1B}" + designator + "A" + invoke + "\u{1B}[2;3H\u{1B}[1;31;44;4:3;58;2;11;22;33m" + commands.0)
            let expected = vt.state.cursor.pen
            vt.feed("\u{1B}(B\u{1B})B\u{1B}*B\u{1B}+B\u{0F}\u{1B}[0m\u{1B}[H" + commands.1 + "#")
            #expect(vt.cell(2, 1).glyph == 0xA3)
            #expect(vt.cell(2, 1).attributes == expected)
            #expect(vt.cursor == (3, 1))
            #expect(TestFixture(vt.lines[0].isEmpty) == TestFixture(true))
            vt.feed("\u{0F}\u{1B}(B#")
            #expect(vt.cell(3, 1).glyph == 0x23)
        }
    }
}
