@testable import SwifttyCore
import Testing
import TestSupport

struct SoftResetTests {
    @Test(arguments: [false, true], [false, true])
    func `soft reset disables margin mode and restores CSI cursor saving`(_ alternate: Bool, _ fragmented: Bool) {
        var vt = VT(8, 4)
        if alternate {
            vt.feed("\u{1B}[?1049h")
        }
        vt.feed("content\u{1B}[?69h\u{1B}[2;7s\u{1B}[2;4r\u{1B}[?6h\u{1B}[2;3H")
        let position = vt.cursor
        let cells = (0 ..< 4).flatMap { y in (0 ..< 8).map { vt.cell($0, y) } }
        if fragmented {
            for byte in "\u{1B}[!p".utf8 {
                vt.feed(bytes: [byte])
            }
        } else {
            vt.feed("\u{1B}[!p")
        }
        #expect(!vt.state.modes.contains(.leftRightMargin))
        #expect(!vt.state.modes.contains(.origin))
        #expect(vt.state.scrollLeft == 0)
        #expect(vt.state.scrollRight == 7)
        #expect(vt.state.scrollTop == 0)
        #expect(vt.state.scrollBottom == 3)
        #expect(vt.cursor == position)
        #expect((0 ..< 4).flatMap { y in (0 ..< 8).map { vt.cell($0, y) } } == cells)
        vt.feed("\u{1B}[?69$p")
        #expect(TestFixture(vt.takeOutput()) == TestFixture("\u{1B}[?69;2$y"))
        // Explicit margin requests are ignored until mode 69 is enabled again.
        vt.feed("\u{1B}[2;6s")
        #expect(vt.state.scrollLeft == 0)
        #expect(vt.state.scrollRight == 7)
        #expect(vt.cursor == position)
        vt.feed("\u{1B}[s\u{1B}[H\u{1B}[u")
        #expect(vt.cursor == position)
        vt.feed("X")
        #expect(vt.cell(position.x, position.y).glyph == 0x58)
    }

    @Test(arguments: [false, true], [false, true])
    func `soft reset restores configured indexed colors and damages existing text`(_ alternate: Bool, _ fragmented: Bool) {
        var configured = Palette.standard
        for index in 0 ..< 256 {
            configured.colors[index] = UInt32(index) * 0x010101
        }
        var vt = VT(8, 3)
        vt.state = TerminalState(columns: 8, rows: 3, palette: configured)
        vt.feed("\u{1B}[31mprimary")
        if alternate {
            vt.feed("\u{1B}[?1049h\u{1B}[H\u{1B}[32malternate")
        }
        vt.feed("\u{1B}]4;" + (0 ..< 256).map { "\($0);#ff0000" }.joined(separator: ";") + "\u{7}")
        vt.feed("\u{1B}]10;#112233\u{7}\u{1B}]11;#334455\u{7}\u{1B}]12;#556677\u{7}")
        vt.feed("\u{1B}]21;cursor_text=#123456;selection_foreground=#234567;selection_background=#345678\u{7}")
        var expected = vt.state.palette
        expected.colors = configured.colors
        let cells = (0 ..< 3).flatMap { y in (0 ..< 8).map { vt.cell($0, y) } }
        let primary = vt.state.dumpPrimaryANSI()
        let position = vt.cursor
        _ = vt.state.takeDamage()
        if fragmented {
            for byte in "\u{1B}[!p".utf8 {
                vt.feed(bytes: [byte])
            }
        } else {
            vt.feed("\u{1B}[!p")
        }
        #expect(vt.state.palette == expected)
        #expect(vt.cursor == position)
        #expect(vt.state.dumpPrimaryANSI() == primary)
        #expect((0 ..< 3).flatMap { y in (0 ..< 8).map { vt.cell($0, y) } } == cells)
        let damage = vt.state.takeDamage()
        #expect(damage.isFull)
        vt.feed("\u{1B}]4;1;?;255;?\u{7}")
        #expect(TestFixture(vt.takeOutput()) == TestFixture("\u{1B}]4;1;rgb:0101/0101/0101\u{7}\u{1B}]4;255;rgb:ffff/ffff/ffff\u{7}"))
        vt.feed("\u{1B}[!p")
        let repeatedDamage = vt.state.takeDamage()
        #expect(repeatedDamage.isEmpty)
    }

    @Test(arguments: [47, 1047, 1049], [(false, false), (false, true), (true, false), (true, true)])
    func `soft reset preserves the inactive screen saved cursor`(_ mode: Int, _ options: (Bool, Bool)) {
        let (resetOnAlternate, fragmented) = options
        var vt = VT(8, 4)
        vt.feed("\u{1B}[2;4r\u{1B}[?6h\u{1B}[1;3H\u{1B}(A\u{1B}[3;31m\u{1B}7")
        vt.feed("\u{1B}[?\(mode)h\u{1B}[?6l\u{1B}(B\u{1B}[0;34m\u{1B}[3;4H\u{1B}7")
        let saved = resetOnAlternate ? vt.state.savedPrimary : vt.state.savedAlternate
        if !resetOnAlternate {
            vt.feed("\u{1B}[?\(mode)l\u{1B}8")
        }
        if fragmented {
            for byte in "\u{1B}[!p".utf8 {
                vt.feed(bytes: [byte])
            }
        } else {
            vt.feed("\u{1B}[!p")
        }
        #expect((resetOnAlternate ? vt.state.savedPrimary : vt.state.savedAlternate) == saved)
        #expect((resetOnAlternate ? vt.state.savedAlternate : vt.state.savedPrimary) == Cursor())
        vt.feed(resetOnAlternate ? "\u{1B}[?\(mode)l\u{1B}8" : "\u{1B}[?47h\u{1B}8")
        #expect(vt.state.cursor == saved)
        #expect(vt.state.modes.contains(.origin) == resetOnAlternate)
        vt.feed("#")
        #expect(vt.cell(saved.x, saved.y).glyph == (resetOnAlternate ? 0xA3 : 0x23))
        #expect(vt.cell(saved.x, saved.y).attributes == saved.pen)
        #expect(vt.cursor == (saved.x + 1, saved.y))
    }

    @Test(arguments: Array(0 ... 6), [(false, false), (false, true), (true, false), (true, true)])
    func `soft reset restores cursor presentation and wrapping defaults without clearing content`(_ style: Int, _ options: (Bool, Bool)) {
        let (alternate, fragmented) = options
        var vt = VT(5, 3)
        if alternate {
            vt.feed("\u{1B}[?1049h")
        }
        vt.feed("ABCDE漢\u{1B}[2;4H\u{1B}[1;31;44m\u{1B}7")
        vt.feed("\u{1B}[\(style) q\u{1B}[?12;45;1045h\u{1B}[?7;25l")
        let cells = (0 ..< 3).flatMap { y in (0 ..< 5).map { vt.cell($0, y) } }
        let position = vt.cursor
        if fragmented {
            for byte in "\u{1B}[!p".utf8 {
                vt.feed(bytes: [byte])
            }
        } else {
            vt.feed("\u{1B}[!p")
        }
        #expect(vt.state.cursorStyle == .block)
        #expect(!vt.state.modes.contains(.cursorBlink))
        #expect(!vt.state.modes.contains(.reverseWrap))
        #expect(!vt.state.modes.contains(.reverseWrapExtended))
        #expect(vt.state.modes.contains([.autowrap, .cursorVisible]))
        #expect(vt.state.isAlternateScreen == alternate)
        #expect(vt.cursor == position)
        #expect(vt.state.cursor.pen == .default)
        #expect((0 ..< 3).flatMap { y in (0 ..< 5).map { vt.cell($0, y) } } == cells)
        // Backspace at the left edge must no longer reverse-wrap.
        vt.feed("\u{1B}[2;1H\u{08}")
        #expect(vt.cursor == (0, 1))
        vt.feed("\u{1B}8#")
        #expect(vt.cell(0, 0).glyph == 0x23)
        #expect(vt.cell(0, 0).attributes == .default)
    }
}
