// Ghostty oracle tests ported from upstream src/terminal/Terminal.zig
// (`test "Terminal: ..."` blocks at lines [11089, 14035)).
//
// Each test drives swiftty only through bytes. Ghostty API calls are mapped
// to the escape sequences they implement. Direct writes to
// `t.scrolling_region.left/right` are mapped to DECSLRM (with mode 69),
// wrapped in DECSC/DECRC so the cursor (and pending wrap) is unchanged.
//
// Skipped (no byte-level equivalent):
// - deleteLines across page boundary marks all shifted rows dirty: page capacity / node serial / dirty tracking.
// - deleteLines hyperlink-dense row crosses page boundary: page hyperlink capacity and page integrity internals.
// - deleteLines zero: deleteLines(0) has no byte form (CSI 0 M means 1).
// - print with style marks the row as styled: row.styled is a page internal.
// - insertBlanks zero: insertBlanks(0) has no byte form (CSI 0 @ means 1).
// - deleteChars zero count: deleteChars(0) has no byte form (CSI 0 P means 1).
// - restoreCursor uses default style on OutOfSpace: style-map capacity / allocation internals.
//
// Partially ported (internal-only assertions dropped, the observable part kept):
// - all `isDirty` / `clearDirty` checks are dropped.
// - bold style / garbage collect overwritten / do not garbage collect old styles in use:
//   style ref counts and style-map sizes dropped; cell attributes checked.
// - insertBlanks deleting graphemes / shift graphemes: page.graphemeCount dropped.
// - insertBlanks shifts hyperlinks / pushes hyperlink off end completely: row.hyperlink flag
//   and hyperlink ids replaced by the cell's link attribute.
// - saveCursor: charset GR (G3) assertion dropped (not observable).
// - setProtectedMode / saveCursor protected pen / DECALN resets graphemes with protected mode:
//   `cursor.protected` observed by printing and then erasing (DECSEL or EL).

@testable import SwifttyCore
import Testing

private extension VT {
    /// Ghostty `plainString`: rows joined by "\n", trailing blanks trimmed
    /// per row and trailing empty rows dropped.
    var t3Plain: String {
        var s = lines.joined(separator: "\n")
        while s.last == "\n" {
            s.removeLast()
        }
        return s
    }

    /// Ghostty `plainStringUnwrapped`: soft-wrapped rows are joined without
    /// a newline and keep their full width; spacer cells are skipped.
    var t3Unwrapped: String {
        var out = ""
        for y in 0 ..< state.rows {
            var row = ""
            for x in 0 ..< state.columns {
                let c = state.grid[x, y]
                if c.isSpacer { continue }
                let scalars = state.scalars(of: c)
                if scalars.isEmpty {
                    row.append(" ")
                } else {
                    row.unicodeScalars.append(contentsOf: scalars)
                }
            }
            if state.grid.isWrapped(y) {
                out += row
            } else {
                while row.last == " " {
                    row.removeLast()
                }
                out += row + "\n"
            }
        }
        while out.last == "\n" {
            out.removeLast()
        }
        return out
    }

    var t3PendingWrap: Bool {
        state.cursor.pendingWrap
    }

    func t3Wrapped(_ y: Int) -> Bool {
        state.grid.isWrapped(y)
    }

    /// Mimics `t.scrolling_region.left/right = ...` (0-based, inclusive)
    /// without moving the cursor.
    mutating func t3Margins(left: Int, right: Int) {
        feed("\(ESC)7\(CSI)?69h\(CSI)\(left + 1);\(right + 1)s\(ESC)8")
    }
}

private let t3Red = TerminalColor.rgb(0xFF, 0, 0)
private let t3BgRed = "\(CSI)48;2;255;0;0m"
private let t3Family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"

struct GhosttyTerminal3Tests {
    // MARK: cursorLeft

    @Test func `cursorLeft reverse wrap extended with pending wrap state`() {
        var vt = VT(5, 5)
        vt.feed("\(CSI)?7h\(CSI)?1045h")
        vt.feed("ABCDE")
        do { let ok = vt.t3PendingWrap; #expect(ok) }
        vt.feed("\(CSI)1D")
        do { let ok = !vt.t3PendingWrap; #expect(ok) }
        vt.feed("X")
        #expect(vt.t3Plain == "ABCDX")
    }

    @Test func `cursorLeft reverse wrap`() {
        var vt = VT(5, 5)
        vt.feed("\(CSI)?7h\(CSI)?45h")
        vt.feed("ABCDE1")
        vt.feed("\(CSI)2D")
        vt.feed("X")
        do { let ok = vt.t3PendingWrap; #expect(ok) }
        #expect(vt.t3Plain == "ABCDX\n1")
    }

    @Test func `cursorLeft reverse wrap with no soft wrap`() {
        var vt = VT(5, 5)
        vt.feed("\(CSI)?7h\(CSI)?45h")
        vt.feed("ABCDE\r\n1")
        vt.feed("\(CSI)2D")
        vt.feed("X")
        #expect(vt.t3Plain == "ABCDE\nX")
    }

    @Test func `cursorLeft reverse wrap before left margin`() {
        var vt = VT(5, 5)
        vt.feed("\(CSI)?7h\(CSI)?45h")
        vt.feed("\(CSI)3r")
        vt.feed("\(CSI)1D")
        vt.feed("X")
        #expect(vt.t3Plain == "\n\nX")
    }

    @Test func `cursorLeft extended reverse wrap`() {
        var vt = VT(5, 5)
        vt.feed("\(CSI)?7h\(CSI)?1045h")
        vt.feed("ABCDE\r\n1")
        vt.feed("\(CSI)2D")
        vt.feed("X")
        #expect(vt.t3Plain == "ABCDX\n1")
    }

    @Test func `cursorLeft extended reverse wrap bottom wraparound`() {
        var vt = VT(5, 3)
        vt.feed("\(CSI)?7h\(CSI)?1045h")
        vt.feed("ABCDE\r\n1")
        vt.feed("\(CSI)\(1 + 5 + 1)D")
        vt.feed("X")
        #expect(vt.t3Plain == "ABCDE\n1\n    X")
    }

    @Test func `cursorLeft extended reverse wrap is priority if both set`() {
        var vt = VT(5, 3)
        vt.feed("\(CSI)?7h\(CSI)?45h\(CSI)?1045h")
        vt.feed("ABCDE\r\n1")
        vt.feed("\(CSI)\(1 + 5 + 1)D")
        vt.feed("X")
        #expect(vt.t3Plain == "ABCDE\n1\n    X")
    }

    @Test func `cursorLeft extended reverse wrap above top scroll region`() {
        var vt = VT(5, 5)
        vt.feed("\(CSI)?7h\(CSI)?1045h")
        vt.feed("\(CSI)3r")
        vt.feed("\(CSI)2;1H")
        vt.feed("\(CSI)1000D")
        #expect(vt.cursor == (0, 0))
    }

    @Test func `cursorLeft reverse wrap on first row`() {
        var vt = VT(5, 5)
        vt.feed("\(CSI)?7h\(CSI)?45h")
        vt.feed("\(CSI)3r")
        vt.feed("\(CSI)1;2H")
        vt.feed("\(CSI)1000D")
        #expect(vt.cursor == (0, 0))
    }

    // MARK: cursorDown / cursorRight

    @Test func `cursorDown basic`() {
        var vt = VT(5, 5)
        vt.feed("A\(CSI)10BX")
        #expect(vt.t3Plain == "A\n\n\n\n X")
    }

    @Test func `cursorDown above bottom scroll margin`() {
        var vt = VT(5, 5)
        vt.feed("\(CSI)1;3r")
        vt.feed("A\(CSI)10BX")
        #expect(vt.t3Plain == "A\n\n X")
    }

    @Test func `cursorDown below bottom scroll margin`() {
        var vt = VT(5, 5)
        vt.feed("\(CSI)1;3r")
        vt.feed("A")
        vt.feed("\(CSI)4;1H")
        vt.feed("\(CSI)10BX")
        #expect(vt.t3Plain == "A\n\n\n\nX")
    }

    @Test func `cursorDown resets wrap`() {
        var vt = VT(5, 5)
        vt.feed("ABCDE")
        do { let ok = vt.t3PendingWrap; #expect(ok) }
        vt.feed("\(CSI)1B")
        do { let ok = !vt.t3PendingWrap; #expect(ok) }
        vt.feed("X")
        #expect(vt.t3Plain == "ABCDE\n    X")
    }

    @Test func `cursorRight resets wrap`() {
        var vt = VT(5, 5)
        vt.feed("ABCDE")
        do { let ok = vt.t3PendingWrap; #expect(ok) }
        vt.feed("\(CSI)1C")
        do { let ok = !vt.t3PendingWrap; #expect(ok) }
        vt.feed("X")
        #expect(vt.t3Plain == "ABCDX")
    }

    @Test func `cursorRight to the edge of screen`() {
        var vt = VT(5, 5)
        vt.feed("\(CSI)100CX")
        #expect(vt.t3Plain == "    X")
    }

    @Test func `cursorRight left of right margin`() {
        var vt = VT(5, 5)
        vt.t3Margins(left: 0, right: 2)
        vt.feed("\(CSI)100CX")
        #expect(vt.t3Plain == "  X")
    }

    @Test func `cursorRight right of right margin`() {
        var vt = VT(5, 5)
        vt.t3Margins(left: 0, right: 2)
        vt.feed("\(CSI)1;4H")
        vt.feed("\(CSI)100CX")
        #expect(vt.t3Plain == "    X")
    }

    // MARK: deleteLines

    @Test func `deleteLines simple`() {
        var vt = VT(5, 5)
        vt.feed("ABC\r\nDEF\r\nGHI")
        vt.feed("\(CSI)2;2H")
        vt.feed("\(CSI)M")
        #expect(vt.t3Plain == "ABC\nGHI")
    }

    @Test func `deleteLines colors with bg color`() {
        var vt = VT(5, 5)
        vt.feed("ABC\r\nDEF\r\nGHI")
        vt.feed("\(CSI)2;2H")
        vt.feed(t3BgRed)
        vt.feed("\(CSI)M")
        #expect(vt.t3Plain == "ABC\nGHI")
        for x in 0 ..< 5 {
            #expect(vt.cell(x, 4).attributes.background == t3Red, "x=\(x)")
        }
    }

    @Test func `deleteLines (legacy)`() {
        var vt = VT(80, 80)
        vt.feed("A\r\nB\r\nC\r\nD")
        vt.feed("\(CSI)2A")
        vt.feed("\(CSI)M")
        vt.feed("E\r\n")
        #expect(vt.cursor == (0, 2))
        #expect(vt.t3Plain == "A\nE\nD")
    }

    @Test func `deleteLines with scroll region`() {
        var vt = VT(80, 80)
        vt.feed("A\r\nB\r\nC\r\nD")
        vt.feed("\(CSI)1;3r")
        vt.feed("\(CSI)1;1H")
        vt.feed("\(CSI)M")
        vt.feed("E\r\n")
        #expect(vt.t3Plain == "E\nC\n\nD")
    }

    @Test func `deleteLines with scroll region, large count`() {
        var vt = VT(80, 80)
        vt.feed("A\r\nB\r\nC\r\nD")
        vt.feed("\(CSI)1;3r")
        vt.feed("\(CSI)1;1H")
        vt.feed("\(CSI)5M")
        vt.feed("E\r\n")
        #expect(vt.t3Plain == "E\n\n\nD")
    }

    @Test func `deleteLines with scroll region, cursor outside of region`() {
        var vt = VT(80, 80)
        vt.feed("A\r\nB\r\nC\r\nD")
        vt.feed("\(CSI)1;3r")
        vt.feed("\(CSI)4;1H")
        vt.feed("\(CSI)M")
        #expect(vt.t3Plain == "A\nB\nC\nD")
    }

    @Test func `deleteLines resets pending wrap`() {
        var vt = VT(5, 5)
        vt.feed("ABCDE")
        do { let ok = vt.t3PendingWrap; #expect(ok) }
        vt.feed("\(CSI)M")
        do { let ok = !vt.t3PendingWrap; #expect(ok) }
        vt.feed("B")
        #expect(vt.t3Plain == "B")
    }

    @Test func `deleteLines resets wrap`() {
        var vt = VT(3, 3)
        vt.feed("1\r\nABCDEF")
        vt.feed("\(CSI)1;2r")
        vt.feed("\(CSI)1;1H")
        vt.feed("\(CSI)M")
        vt.feed("X")
        #expect(vt.t3Plain == "XBC\n\nDEF")
        for y in 0 ..< 3 {
            let w = vt.t3Wrapped(y)
            #expect(!w, "row \(y) wrapped")
        }
    }

    @Test func `deleteLines left/right scroll region`() {
        var vt = VT(10, 10)
        vt.feed("ABC123\r\nDEF456\r\nGHI789")
        vt.t3Margins(left: 1, right: 3)
        vt.feed("\(CSI)2;2H")
        vt.feed("\(CSI)M")
        #expect(vt.t3Plain == "ABC123\nDHI756\nG   89")
    }

    @Test func `deleteLines left/right scroll region from top`() {
        var vt = VT(10, 10)
        vt.feed("ABC123\r\nDEF456\r\nGHI789")
        vt.t3Margins(left: 1, right: 3)
        vt.feed("\(CSI)1;2H")
        vt.feed("\(CSI)M")
        #expect(vt.t3Plain == "AEF423\nDHI756\nG   89")
    }

    @Test func `deleteLines left/right scroll region high count`() {
        var vt = VT(10, 10)
        vt.feed("ABC123\r\nDEF456\r\nGHI789")
        vt.t3Margins(left: 1, right: 3)
        vt.feed("\(CSI)2;2H")
        vt.feed("\(CSI)100M")
        #expect(vt.t3Plain == "ABC123\nD   56\nG   89")
    }

    @Test func `deleteLines wide character spacer head`() {
        var vt = VT(5, 3)
        vt.feed("AAAAABBBB\u{1F600}CCC")
        vt.feed("\(CSI)1;1H")
        vt.feed("\(CSI)M")
        #expect(vt.t3Plain == "BBBB\n\u{1F600}CCC")
        #expect(vt.t3Unwrapped == "BBBB\n\u{1F600}CCC")
    }

    @Test func `deleteLines wide character spacer head left scroll margin`() {
        var vt = VT(5, 3)
        vt.feed("AAAAABBBB\u{1F600}CCC")
        vt.t3Margins(left: 2, right: 4)
        vt.feed("\(CSI)1;3H")
        vt.feed("\(CSI)M")
        #expect(vt.t3Plain == "AABB\nBBCCC\n\u{1F600}")
        #expect(vt.t3Unwrapped == "AABB BBCCC\u{1F600}")
    }

    @Test func `deleteLines wide character spacer head right scroll margin`() {
        var vt = VT(5, 3)
        vt.feed("AAAAABBBB\u{1F600}CCC")
        vt.t3Margins(left: 0, right: 3)
        vt.feed("\(CSI)1;1H")
        vt.feed("\(CSI)M")
        #expect(vt.t3Plain == "BBBBA\n\u{1F600}CC\n    C")
        #expect(vt.t3Unwrapped == "BBBBA\u{1F600}CC     C")
    }

    @Test func `deleteLines wide character spacer head left and right scroll margin`() {
        var vt = VT(5, 3)
        vt.feed("AAAAABBBB\u{1F600}CCC")
        vt.t3Margins(left: 2, right: 3)
        vt.feed("\(CSI)1;3H")
        vt.feed("\(CSI)M")
        #expect(vt.t3Plain == "AABBA\nBBCC\n\u{1F600}  C")
        #expect(vt.t3Unwrapped == "AABBABBCC\u{1F600}  C")
    }

    @Test func `deleteLines wide character spacer head left (< 2) and right scroll margin`() {
        var vt = VT(5, 3)
        vt.feed("AAAAABBBB\u{1F600}CCC")
        vt.t3Margins(left: 1, right: 3)
        vt.feed("\(CSI)1;2H")
        vt.feed("\(CSI)M")
        #expect(vt.t3Plain == "ABBBA\nB CC\n    C")
        #expect(vt.t3Unwrapped == "ABBBAB CC     C")
    }

    @Test func `deleteLines wide characters split by left/right scroll region boundaries`() {
        var vt = VT(5, 2)
        vt.feed("AAAAA\r\n\u{1F600}B\u{1F600}")
        vt.t3Margins(left: 1, right: 3)
        vt.feed("\(CSI)1;2H")
        vt.feed("\(CSI)M")
        #expect(vt.t3Plain == "A B A")
    }

    // MARK: styles

    @Test func `default style is empty`() {
        var vt = VT(5, 5)
        vt.feed("A")
        let c = vt.cell(0, 0)
        #expect(c.glyph == 0x41)
        #expect(c.attributes == .default)
    }

    @Test func `bold style`() {
        var vt = VT(5, 5)
        vt.feed("\(CSI)1mA")
        let c = vt.cell(0, 0)
        #expect(c.glyph == 0x41)
        #expect(c.attributes.flags.contains(.bold))
        do { let ok = vt.state.cursor.pen.flags.contains(.bold); #expect(ok) }
    }

    @Test func `garbage collect overwritten`() {
        var vt = VT(5, 5)
        vt.feed("\(CSI)1mA")
        vt.feed("\(CSI)1;1H")
        vt.feed("\(CSI)0mB")
        let c = vt.cell(0, 0)
        #expect(c.glyph == 0x42)
        #expect(c.attributes == .default)
    }

    @Test func `do not garbage collect old styles in use`() {
        var vt = VT(5, 5)
        vt.feed("\(CSI)1mA")
        vt.feed("\(CSI)0mB")
        let c = vt.cell(1, 0)
        #expect(c.glyph == 0x42)
        #expect(c.attributes == .default)
        #expect(vt.cell(0, 0).attributes.flags.contains(.bold))
    }

    // MARK: DECALN

    @Test func `DECALN`() {
        var vt = VT(2, 2)
        vt.feed("A\r\nB")
        vt.feed("\(ESC)#8")
        #expect(vt.cursor == (0, 0))
        #expect(vt.t3Plain == "EE\nEE")
    }

    @Test func `decaln reset margins`() {
        var vt = VT(3, 3)
        vt.feed("\(CSI)?6h")
        vt.feed("\(CSI)2;3r")
        vt.feed("\(ESC)#8")
        vt.feed("\(CSI)1T")
        #expect(vt.t3Plain == "\nEEE\nEEE")
    }

    @Test func `decaln preserves color`() {
        var vt = VT(3, 3)
        vt.feed(t3BgRed)
        vt.feed("\(CSI)?6h")
        vt.feed("\(CSI)2;3r")
        vt.feed("\(ESC)#8")
        vt.feed("\(CSI)1T")
        #expect(vt.t3Plain == "\nEEE\nEEE")
        #expect(vt.cell(0, 0).attributes.background == t3Red)
    }

    @Test func `DECALN resets graphemes with protected mode`() {
        var vt = VT(3, 3)
        vt.feed("\(ESC)V") // SPA: ISO protected mode
        vt.feed("\(CSI)?2027h")
        vt.feed(t3Family)
        vt.feed("\(ESC)#8")
        #expect(vt.cursor == (0, 0))
        #expect(vt.t3Plain == "EEE\nEEE\nEEE")
        // cursor.protected and protected_mode == .iso: a printed cell is
        // protected and survives a plain EL; the DECALN cells are not.
        vt.feed("X\(CSI)1;1H\(CSI)K")
        #expect(vt.lines[0] == "X")
    }

    // MARK: insertBlanks

    @Test func `insertBlanks`() {
        var vt = VT(5, 2)
        vt.feed("ABC")
        vt.feed("\(CSI)1;1H")
        vt.feed("\(CSI)2@")
        #expect(vt.t3Plain == "  ABC")
    }

    @Test func `insertBlanks pushes off end`() {
        var vt = VT(3, 2)
        vt.feed("ABC")
        vt.feed("\(CSI)1;1H")
        vt.feed("\(CSI)2@")
        #expect(vt.t3Plain == "  A")
    }

    @Test func `insertBlanks more than size`() {
        var vt = VT(3, 2)
        vt.feed("ABC")
        vt.feed("\(CSI)1;1H")
        vt.feed("\(CSI)5@")
        #expect(vt.t3Plain == "")
    }

    @Test func `insertBlanks no scroll region, fits`() {
        var vt = VT(10, 10)
        vt.feed("ABC")
        vt.feed("\(CSI)1;1H")
        vt.feed("\(CSI)2@")
        #expect(vt.t3Plain == "  ABC")
    }

    @Test func `insertBlanks preserves background sgr`() {
        var vt = VT(10, 10)
        vt.feed("ABC")
        vt.feed("\(CSI)1;1H")
        vt.feed(t3BgRed)
        vt.feed("\(CSI)2@")
        #expect(vt.t3Plain == "  ABC")
        #expect(vt.cell(0, 0).attributes.background == t3Red)
    }

    @Test func `insertBlanks shift off screen`() {
        var vt = VT(5, 10)
        vt.feed("  ABC")
        vt.feed("\(CSI)1;3H")
        vt.feed("\(CSI)2@")
        vt.feed("X")
        #expect(vt.t3Plain == "  X A")
    }

    @Test func `insertBlanks split multi-cell character`() {
        var vt = VT(5, 10)
        vt.feed("123\u{6A4B}")
        vt.feed("\(CSI)1;1H")
        vt.feed("\(CSI)1@")
        #expect(vt.t3Plain == " 123")
    }

    @Test func `insertBlanks inside left/right scroll region`() {
        var vt = VT(10, 10)
        vt.t3Margins(left: 2, right: 4)
        vt.feed("\(CSI)1;3H")
        vt.feed("ABC")
        vt.feed("\(CSI)1;3H")
        vt.feed("\(CSI)2@")
        vt.feed("X")
        #expect(vt.t3Plain == "  X A")
    }

    @Test func `insertBlanks outside left/right scroll region`() {
        var vt = VT(6, 10)
        vt.feed("\(CSI)1;4H")
        vt.feed("ABC")
        vt.t3Margins(left: 2, right: 4)
        do { let ok = vt.t3PendingWrap; #expect(ok) }
        vt.feed("\(CSI)2@")
        do { let ok = !vt.t3PendingWrap; #expect(ok) }
        vt.feed("X")
        #expect(vt.t3Plain == "   ABX")
    }

    @Test func `insertBlanks left/right scroll region large count`() {
        var vt = VT(10, 10)
        vt.feed("\(CSI)?6h\(CSI)?69h")
        vt.feed("\(CSI)3;5s")
        vt.feed("\(CSI)1;1H")
        vt.feed("\(CSI)140@")
        vt.feed("X")
        #expect(vt.t3Plain == "  X")
    }

    @Test func `insertBlanks deleting graphemes`() {
        var vt = VT(5, 5)
        vt.feed("\(CSI)?2027h")
        vt.feed("ABC")
        vt.feed(t3Family)
        vt.feed("\(CSI)1;1H")
        vt.feed("\(CSI)4@")
        #expect(vt.t3Plain == "    A")
    }

    @Test func `insertBlanks shift graphemes`() {
        var vt = VT(5, 5)
        vt.feed("\(CSI)?2027h")
        vt.feed("A")
        vt.feed(t3Family)
        vt.feed("\(CSI)1;1H")
        vt.feed("\(CSI)1@")
        #expect(vt.t3Plain == " A\(t3Family)")
    }

    @Test func `insertBlanks split multi-cell character from tail`() {
        var vt = VT(5, 10)
        vt.feed("\u{6A4B}123")
        vt.feed("\(CSI)1;2H")
        vt.feed("\(CSI)1@")
        #expect(vt.t3Plain == "   12")
    }

    @Test func `insertBlanks shifts hyperlinks`() {
        var vt = VT(10, 2)
        vt.feed("\(ESC)]8;;http://example.com\(ESC)\\")
        vt.feed("ABC")
        vt.feed("\(CSI)1;1H")
        vt.feed("\(CSI)2@")
        #expect(vt.t3Plain == "  ABC")
        let link = vt.cell(2, 0).attributes.link
        #expect(link != 0)
        for x in 2 ..< 5 {
            #expect(vt.cell(x, 0).attributes.link == link, "x=\(x)")
        }
        for x in 0 ..< 2 {
            #expect(vt.cell(x, 0).attributes.link == 0, "x=\(x)")
        }
    }

    @Test func `insertBlanks pushes hyperlink off end completely`() {
        var vt = VT(3, 2)
        vt.feed("\(ESC)]8;;http://example.com\(ESC)\\")
        vt.feed("ABC")
        vt.feed("\(CSI)1;1H")
        vt.feed("\(CSI)3@")
        #expect(vt.t3Plain == "")
        for x in 0 ..< 3 {
            #expect(vt.cell(x, 0).attributes.link == 0, "x=\(x)")
        }
    }

    @Test func `insertBlanks wide char straddling right margin`() {
        var vt = VT(10, 5)
        vt.feed("\(CSI)1;1H")
        vt.feed("ABCD\u{6A4B}")
        vt.t3Margins(left: 0, right: 4)
        vt.feed("\(CSI)1;3H")
        vt.feed("\(CSI)1@")
        #expect(vt.t3Plain == "AB CD")
    }

    @Test func `insertBlanks wide char spacer_tail orphaned beyond right margin`() {
        var vt = VT(10, 5)
        vt.feed(String(repeating: "\u{4E2D}", count: 5))
        vt.feed("\(CSI)?69h")
        vt.feed("\(CSI)1;9s")
        vt.feed("a")
        vt.feed("\(CSI)8@")
        #expect(vt.t3Plain == "a")
    }

    // MARK: insert mode

    @Test func `insert mode with space`() {
        var vt = VT(10, 2)
        vt.feed("hello")
        vt.feed("\(CSI)1;2H")
        vt.feed("\(CSI)4h")
        vt.feed("X")
        #expect(vt.t3Plain == "hXello")
    }

    @Test func `insert mode doesn't wrap pushed characters`() {
        var vt = VT(5, 2)
        vt.feed("hello")
        vt.feed("\(CSI)1;2H")
        vt.feed("\(CSI)4h")
        vt.feed("X")
        #expect(vt.t3Plain == "hXell")
    }

    @Test func `insert mode does nothing at the end of the line`() {
        var vt = VT(5, 2)
        vt.feed("hello")
        vt.feed("\(CSI)4h")
        vt.feed("X")
        #expect(vt.t3Plain == "hello\nX")
    }

    @Test func `insert mode with wide characters`() {
        var vt = VT(5, 2)
        vt.feed("hello")
        vt.feed("\(CSI)1;2H")
        vt.feed("\(CSI)4h")
        vt.feed("\u{1F600}")
        #expect(vt.t3Plain == "h\u{1F600}el")
    }

    @Test func `insert mode with wide characters at end`() {
        var vt = VT(5, 2)
        vt.feed("well")
        vt.feed("\(CSI)4h")
        vt.feed("\u{1F600}")
        #expect(vt.t3Plain == "well\n\u{1F600}")
    }

    @Test func `insert mode pushing off wide character`() {
        var vt = VT(5, 2)
        vt.feed("123\u{1F600}")
        vt.feed("\(CSI)4h")
        vt.feed("\(CSI)1;1H")
        vt.feed("X")
        #expect(vt.t3Plain == "X123")
    }

    // MARK: deleteChars

    @Test func `deleteChars`() {
        var vt = VT(5, 5)
        vt.feed("ABCDE")
        vt.feed("\(CSI)1;2H")
        vt.feed("\(CSI)2P")
        #expect(vt.t3Plain == "ADE")
    }

    @Test func `deleteChars more than half`() {
        var vt = VT(5, 5)
        vt.feed("ABCDE")
        vt.feed("\(CSI)1;2H")
        vt.feed("\(CSI)3P")
        #expect(vt.t3Plain == "AE")
    }

    @Test func `deleteChars more than line width`() {
        var vt = VT(5, 5)
        vt.feed("ABCDE")
        vt.feed("\(CSI)1;2H")
        vt.feed("\(CSI)10P")
        #expect(vt.t3Plain == "A")
    }

    @Test func `deleteChars should shift left`() {
        var vt = VT(5, 5)
        vt.feed("ABCDE")
        vt.feed("\(CSI)1;2H")
        vt.feed("\(CSI)1P")
        #expect(vt.t3Plain == "ACDE")
    }

    @Test func `deleteChars resets pending wrap`() {
        var vt = VT(5, 5)
        vt.feed("ABCDE")
        do { let ok = vt.t3PendingWrap; #expect(ok) }
        vt.feed("\(CSI)1P")
        do { let ok = !vt.t3PendingWrap; #expect(ok) }
        vt.feed("X")
        #expect(vt.t3Plain == "ABCDX")
    }

    @Test func `deleteChars resets wrap`() {
        var vt = VT(5, 5)
        vt.feed("ABCDE123")
        do { let ok = vt.t3Wrapped(0); #expect(ok) }
        vt.feed("\(CSI)1;1H")
        vt.feed("\(CSI)1P")
        do { let ok = !vt.t3Wrapped(0); #expect(ok) }
        vt.feed("X")
        #expect(vt.t3Plain == "XCDE\n123")
    }

    @Test func `deleteChars simple operation`() {
        var vt = VT(10, 10)
        vt.feed("ABC123")
        vt.feed("\(CSI)1;3H")
        vt.feed("\(CSI)2P")
        #expect(vt.t3Plain == "AB23")
    }

    @Test func `deleteChars preserves background sgr`() {
        var vt = VT(10, 10)
        vt.feed("ABC123")
        vt.feed("\(CSI)1;3H")
        vt.feed(t3BgRed)
        vt.feed("\(CSI)2P")
        #expect(vt.t3Plain == "AB23")
        for x in 8 ..< 10 {
            #expect(vt.cell(x, 0).attributes.background == t3Red, "x=\(x)")
        }
    }

    @Test func `deleteChars outside scroll region`() {
        var vt = VT(6, 10)
        vt.feed("ABC123")
        vt.t3Margins(left: 2, right: 4)
        do { let ok = vt.t3PendingWrap; #expect(ok) }
        vt.feed("\(CSI)2P")
        do { let ok = vt.t3PendingWrap; #expect(ok) }
        #expect(vt.t3Plain == "ABC123")
    }

    @Test func `deleteChars inside scroll region`() {
        var vt = VT(6, 10)
        vt.feed("ABC123")
        vt.t3Margins(left: 2, right: 4)
        vt.feed("\(CSI)1;4H")
        vt.feed("\(CSI)1P")
        #expect(vt.t3Plain == "ABC2 3")
    }

    @Test func `deleteChars split wide character from spacer tail`() {
        var vt = VT(6, 10)
        vt.feed("A\u{6A4B}123")
        vt.feed("\(CSI)1;3H")
        vt.feed("\(CSI)1P")
        #expect(vt.t3Plain == "A 123")
    }

    @Test func `deleteChars split wide character from wide`() {
        var vt = VT(6, 10)
        vt.feed("\u{6A4B}123")
        vt.feed("\(CSI)1;1H")
        vt.feed("\(CSI)1P")
        let c0 = vt.cell(0, 0)
        #expect(c0.glyph == 0)
        #expect(c0.width == 1 && !c0.isSpacer)
        let c1 = vt.cell(1, 0)
        #expect(c1.glyph == 0x31)
        #expect(c1.width == 1 && !c1.isSpacer)
    }

    @Test func `deleteChars split wide character from end`() {
        var vt = VT(6, 10)
        vt.feed("A\u{6A4B}123")
        vt.feed("\(CSI)1;1H")
        vt.feed("\(CSI)1P")
        let c0 = vt.cell(0, 0)
        #expect(c0.glyph == 0x6A4B)
        #expect(c0.width == 2)
        let c1 = vt.cell(1, 0)
        #expect(c1.glyph == 0)
        #expect(c1.flags.contains(.spacerTail))
    }

    @Test func `deleteChars with a spacer head at the end`() {
        var vt = VT(5, 10)
        vt.feed("0123\u{6A4B}123")
        #expect(vt.cell(4, 0).flags.contains(.spacerHead))
        do { let ok = vt.t3Wrapped(0); #expect(ok) }
        vt.feed("\(CSI)1;1H")
        vt.feed("\(CSI)1P")
        let c = vt.cell(3, 0)
        #expect(c.glyph == 0)
        #expect(c.width == 1 && !c.isSpacer)
    }

    @Test func `deleteChars split wide character tail`() {
        var vt = VT(5, 5)
        vt.feed("\(CSI)1;4H")
        vt.feed("\u{6A4B}")
        vt.feed("\r")
        vt.feed("\(CSI)4P")
        vt.feed("0")
        #expect(vt.t3Plain == "0")
    }

    @Test func `deleteChars wide char boundary conditions`() {
        var vt = VT(8, 1)
        vt.feed("\u{1F600}a\u{1F600}b\u{1F600}")
        #expect(vt.t3Plain == "\u{1F600}a\u{1F600}b\u{1F600}")
        vt.feed("\(CSI)1;2H")
        vt.feed("\(CSI)3P")
        #expect(vt.t3Plain == "  b\u{1F600}")
    }

    @Test func `deleteChars wide char wrap boundary conditions`() {
        var vt = VT(8, 3)
        vt.feed(".......\u{1F600}abcde\u{1F600}......")
        #expect(vt.t3Plain == ".......\n\u{1F600}abcde\n\u{1F600}......")
        #expect(vt.t3Unwrapped == ".......\u{1F600}abcde\u{1F600}......")
        vt.feed("\(CSI)2;2H")
        vt.feed("\(CSI)3P")
        #expect(vt.t3Plain == ".......\n cde\n\u{1F600}......")
        #expect(vt.t3Unwrapped == ".......  cde\n\u{1F600}......")
    }

    @Test func `deleteChars wide char across right margin`() {
        var vt = VT(8, 3)
        vt.feed("123456\u{6A4B}")
        vt.feed("\(CSI)?69h")
        vt.feed("\(CSI)2;7s")
        #expect(vt.t3Plain == "123456\u{6A4B}")
        vt.feed("\(CSI)1;2H")
        vt.feed("\(CSI)1P")
        #expect(vt.t3Plain == "13456")
    }

    // MARK: saveCursor / restoreCursor

    @Test func `saveCursor`() {
        var vt = VT(3, 3)
        vt.feed("\(CSI)1m")
        vt.feed("\(CSI)?6h")
        vt.feed("\(ESC)7")
        vt.feed("\(CSI)0m")
        vt.feed("\(CSI)?6l")
        vt.feed("\(ESC)8")
        do { let ok = vt.state.cursor.pen.flags.contains(.bold); #expect(ok) }
        do { let ok = vt.state.modes.contains(.origin); #expect(ok) }
    }

    @Test func `saveCursor position`() {
        var vt = VT(10, 5)
        vt.feed("\(CSI)1;5H")
        vt.feed("A")
        vt.feed("\(ESC)7")
        vt.feed("\(CSI)1;1H")
        vt.feed("B")
        vt.feed("\(ESC)8")
        vt.feed("X")
        #expect(vt.t3Plain == "B   AX")
    }

    @Test func `saveCursor pending wrap state`() {
        var vt = VT(5, 5)
        vt.feed("\(CSI)1;5H")
        vt.feed("A")
        vt.feed("\(ESC)7")
        vt.feed("\(CSI)1;1H")
        vt.feed("B")
        vt.feed("\(ESC)8")
        vt.feed("X")
        #expect(vt.t3Plain == "B   A\nX")
    }

    @Test func `saveCursor origin mode`() {
        var vt = VT(10, 5)
        vt.feed("\(CSI)?6h")
        vt.feed("\(ESC)7")
        vt.feed("\(CSI)?69h")
        vt.feed("\(CSI)3;5s")
        vt.feed("\(CSI)2;4r")
        vt.feed("\(ESC)8")
        vt.feed("X")
        #expect(vt.t3Plain == "X")
    }

    @Test func `saveCursor resize`() {
        var vt = VT(10, 5)
        vt.feed("\(CSI)1;10H")
        vt.feed("\(ESC)7")
        vt.state.resize(columns: 5, rows: 5)
        vt.feed("\(ESC)8")
        vt.feed("X")
        #expect(vt.t3Plain == "    X")
    }

    @Test func `saveCursor protected pen`() {
        var vt = VT(10, 5)
        vt.feed("\(ESC)V") // setProtectedMode(.iso)
        vt.feed("\(CSI)1;10H")
        vt.feed("\(ESC)7")
        vt.feed("\(ESC)W") // setProtectedMode(.off)
        vt.feed("\(ESC)8")
        // cursor.protected must be restored: the next printed cell survives
        // a plain EL (ISO protection is still the active mode).
        vt.feed("A\(CSI)1;1H\(CSI)K")
        #expect(vt.lines[0] == "         A")
    }

    @Test func `saveCursor doesn't modify hyperlink state`() {
        var vt = VT(3, 3)
        vt.feed("\(ESC)]8;;http://example.com\(ESC)\\")
        vt.feed("\(ESC)7")
        vt.feed("\(ESC)8")
        vt.feed("A")
        #expect(vt.cell(0, 0).attributes.link != 0)
        do { let ok = vt.state.cursor.pen.link != 0; #expect(ok) }
    }

    @Test func `setProtectedMode`() {
        var vt = VT(3, 3)
        // Observes cursor.protected: print at home then DECSEL (always
        // respects protected cells).
        func probe(_ vt: inout VT) -> Bool {
            vt.feed("\(CSI)1;1HA\(CSI)1;1H\(CSI)?2K")
            return vt.lines[0] == "A"
        }
        do { let ok = !probe(&vt); #expect(ok) }
        vt.feed("\(CSI)0\"q") // off
        do { let ok = !probe(&vt); #expect(ok) }
        vt.feed("\(ESC)V") // iso
        do { let ok = probe(&vt); #expect(ok) }
        vt.feed("\(CSI)1\"q") // dec
        do { let ok = probe(&vt); #expect(ok) }
        vt.feed("\(CSI)0\"q") // off
        do { let ok = !probe(&vt); #expect(ok) }
    }

    // MARK: eraseLine

    @Test func `eraseLine simple erase right`() {
        var vt = VT(5, 5)
        vt.feed("ABCDE")
        vt.feed("\(CSI)1;3H")
        vt.feed("\(CSI)K")
        #expect(vt.t3Plain == "AB")
    }

    @Test func `eraseLine resets pending wrap`() {
        var vt = VT(5, 5)
        vt.feed("ABCDE")
        do { let ok = vt.t3PendingWrap; #expect(ok) }
        vt.feed("\(CSI)K")
        do { let ok = !vt.t3PendingWrap; #expect(ok) }
        vt.feed("B")
        #expect(vt.t3Plain == "ABCDB")
    }

    @Test func `eraseLine resets wrap`() {
        var vt = VT(5, 5)
        vt.feed("ABCDE123")
        do { let ok = vt.t3Wrapped(0); #expect(ok) }
        vt.feed("\(CSI)1;1H")
        vt.feed("\(CSI)K")
        do { let ok = !vt.t3Wrapped(0); #expect(ok) }
        vt.feed("X")
        #expect(vt.t3Plain == "X\n123")
    }

    @Test func `eraseLine right preserves background sgr`() {
        var vt = VT(5, 5)
        vt.feed("ABCDE")
        vt.feed("\(CSI)1;2H")
        vt.feed(t3BgRed)
        vt.feed("\(CSI)K")
        #expect(vt.t3Plain == "A")
        for x in 1 ..< 5 {
            #expect(vt.cell(x, 0).attributes.background == t3Red, "x=\(x)")
        }
    }

    @Test func `eraseLine right wide character`() {
        var vt = VT(10, 5)
        vt.feed("AB\u{6A4B}DE")
        vt.feed("\(CSI)1;4H")
        vt.feed("\(CSI)K")
        #expect(vt.t3Plain == "AB")
    }

    @Test func `eraseLine right protected attributes respected with iso`() {
        var vt = VT(5, 5)
        vt.feed("\(ESC)V")
        vt.feed("ABC")
        vt.feed("\(CSI)1;1H")
        vt.feed("\(CSI)K")
        #expect(vt.t3Plain == "ABC")
    }

    @Test func `eraseLine right protected attributes ignored with dec most recent`() {
        var vt = VT(5, 5)
        vt.feed("\(ESC)V")
        vt.feed("ABC")
        vt.feed("\(CSI)1\"q")
        vt.feed("\(CSI)0\"q")
        vt.feed("\(CSI)1;2H")
        vt.feed("\(CSI)K")
        #expect(vt.t3Plain == "A")
    }

    @Test func `eraseLine right protected attributes ignored with dec set`() {
        var vt = VT(5, 5)
        vt.feed("\(CSI)1\"q")
        vt.feed("ABC")
        vt.feed("\(CSI)1;2H")
        vt.feed("\(CSI)K")
        #expect(vt.t3Plain == "A")
    }

    @Test func `eraseLine right protected requested`() {
        var vt = VT(10, 5)
        vt.feed("12345678")
        vt.feed("\(CSI)1;6H")
        vt.feed("\(CSI)1\"q")
        vt.feed("X")
        vt.feed("\(CSI)1;4H")
        vt.feed("\(CSI)?0K")
        #expect(vt.t3Plain == "123  X")
    }

    @Test func `eraseLine simple erase left`() {
        var vt = VT(5, 5)
        vt.feed("ABCDE")
        vt.feed("\(CSI)1;3H")
        vt.feed("\(CSI)1K")
        #expect(vt.t3Plain == "   DE")
    }

    @Test func `eraseLine left resets wrap`() {
        var vt = VT(5, 5)
        vt.feed("ABCDE")
        do { let ok = vt.t3PendingWrap; #expect(ok) }
        vt.feed("\(CSI)1K")
        do { let ok = !vt.t3PendingWrap; #expect(ok) }
        vt.feed("B")
        #expect(vt.t3Plain == "    B")
    }

    @Test func `eraseLine left preserves background sgr`() {
        var vt = VT(5, 5)
        vt.feed("ABCDE")
        vt.feed("\(CSI)1;2H")
        vt.feed(t3BgRed)
        vt.feed("\(CSI)1K")
        #expect(vt.t3Plain == "  CDE")
        for x in 0 ..< 2 {
            #expect(vt.cell(x, 0).attributes.background == t3Red, "x=\(x)")
        }
    }
}
