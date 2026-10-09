@testable import SwifttyCore
import Testing
import TestSupport

struct AlternateScreenTests {
    @Test(arguments: ["\u{1B}[1\"q", "\u{1B}V"].map(TestFixture.init))
    func `entering mode 1049 cancels pending wrap on the cleared alternate screen`(_ protection: TestFixture<String>) {
        let protection = protection.value
        var vt = VT(4, 3)
        vt.feed(protection + "ABCD")
        #expect(vt.state.cursor.pendingWrap)
        let primary = vt.state.dumpPrimaryANSI()
        vt.feed("\u{1B}[?1049h")
        #expect(!vt.state.cursor.pendingWrap)
        #expect(vt.cursor == (3, 0))
        #expect(vt.state.dumpPrimaryANSI() == primary)
        vt.feed("X")
        #expect(TestFixture(vt.lines) == TestFixture(["   X", "", ""]))
    }

    @Test(arguments: ["\u{1B}[1\"q", "\u{1B}V"].map(TestFixture.init), [1047, 1049])
    func `alternate screen clears ignore protection and cancel pending wrap`(_ protection: TestFixture<String>, _ mode: Int) {
        let protection = protection.value
        var vt = VT(4, 3)
        vt.feed("P\u{1B}[?1049h\u{1B}[H\u{1B}[44m" + protection + "ABCD")
        #expect(vt.state.cursor.pendingWrap)
        let blank = vt.state.eraseCell
        vt.feed(mode == 1049 ? "\u{1B}[?1049h" : "\u{1B}[?1047l")
        #expect(!vt.state.cursor.pendingWrap)
        #expect(vt.cursor == (3, 0))
        if mode == 1049 {
            #expect(Array(vt.state.grid.cells(row: 0)) == Array(repeating: blank, count: 4))
            #expect(vt.state.savedAlternate.pendingWrap)
        } else {
            #expect(Array(vt.state.inactiveGrid.cells(row: 0)) == Array(repeating: blank, count: 4))
        }
        vt.feed("X")
        #expect(TestFixture(vt.lines) == TestFixture([mode == 1049 ? "   X" : "P  X", "", ""]))
    }

    @Test(arguments: [47, 1047, 1049], [false, true])
    func `repeated alternate screen enabling clears only for mode 1049`(_ mode: Int, _ fragmented: Bool) {
        var vt = VT(8, 3)
        vt.feed("primary\u{1B}[?\(mode)h\u{1B}[H\u{1B}[44m\u{1B}]133;A\u{7}漢X")
        let primary = vt.state.dumpPrimaryANSI()
        let cursor = vt.state.cursor
        let blank = vt.state.eraseCell
        let original = Array(vt.state.grid.cells(row: 0))
        let selection = Selection(anchor: TerminalPoint(row: 0, column: 0), head: TerminalPoint(row: 0, column: 2))
        vt.state.setSelection(selection)
        _ = vt.state.takeDamage()
        let generation = vt.state.addressingGeneration
        let command = "\u{1B}[?\(mode)h"
        if fragmented {
            for byte in command.utf8 {
                vt.feed(bytes: [byte])
            }
        } else {
            vt.feed(command)
        }
        #expect(vt.state.cursor == cursor)
        #expect(vt.state.dumpPrimaryANSI() == primary)
        if mode == 1049 {
            for y in 0 ..< 3 {
                #expect(Array(vt.state.grid.cells(row: y)) == Array(repeating: blank, count: 8))
                #expect(vt.state.grid.mark(y) == .none)
                let wrapped = vt.state.grid.isWrapped(y)
                #expect(!wrapped)
            }
            #expect(vt.state.selection == nil)
            #expect(vt.state.addressingGeneration != generation)
            let damage = vt.state.takeDamage()
            #expect(damage.isFull)
            vt.feed("\u{1B}[H\u{1B}8")
            #expect(vt.state.cursor == cursor) // Repeated enable saved the alternate cursor.
        } else {
            #expect(Array(vt.state.grid.cells(row: 0)) == original)
            #expect(vt.state.selection == selection)
            #expect(vt.state.addressingGeneration == generation)
            let damage = vt.state.takeDamage()
            #expect(damage.isEmpty)
        }
    }
}
