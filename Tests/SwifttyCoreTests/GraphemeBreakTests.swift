@testable import SwifttyCore
import Testing
import TestSupport

/// Ports of Ghostty `src/unicode/grapheme.zig` tests and the uucode
/// grapheme tests Ghostty relies on, plus conformance and pre-filter checks.
struct GraphemeBreakTests {
    typealias GB = GraphemeBreak

    @Test(arguments: [false, true])
    func `widening after a charset change preserves the original character`(_ fragmented: Bool) {
        var vt = VT(3, 3)
        vt.feed("\u{1B}[?2027hAB#\u{1B}(A")
        let attributes = vt.cell(2, 0).attributes
        if fragmented {
            for byte in "\u{FE0F}".utf8 {
                vt.feed(bytes: [byte])
            }
        } else {
            vt.feed("\u{FE0F}")
        }
        #expect(vt.cell(2, 0).flags.contains(.spacerHead))
        #expect(vt.state.scalars(of: vt.cell(0, 1)) == Array("#\u{FE0F}".unicodeScalars))
        #expect(vt.cell(0, 1).width == 2)
        #expect(vt.cell(1, 1).flags.contains(.spacerTail))
        var expected = attributes
        expected.flags.insert(.grapheme)
        #expect(vt.cell(0, 1).attributes == expected)
        vt.feed("#")
        #expect(vt.cell(2, 1).glyph == 0xA3)
    }

    @Test(arguments: [false, true], ["", "x", "x\u{301}"])
    func `invalid variation selectors do not damage unchanged cells`(_ clustering: Bool, _ base: String) {
        var vt = VT(5, 3)
        vt.feed("\u{1B}[?2027\(clustering ? "h" : "l")" + base)
        let cells = (0 ..< 5).map { vt.cell($0, 0) }
        let cursor = vt.state.cursor
        _ = vt.state.takeDamage()
        vt.feed("\u{FE0F}")
        #expect(vt.state.takeDamage().isEmpty)
        #expect((0 ..< 5).map { vt.cell($0, 0) } == cells)
        #expect(vt.state.cursor == cursor)
    }

    @Test func `a retained variation selector damages its cell with clustering disabled`() {
        var vt = VT(5, 3)
        vt.feed("\u{1B}[?2027l❤")
        _ = vt.state.takeDamage()
        vt.feed("\u{FE0F}")
        #expect(vt.cell(0, 0).width == 1)
        #expect(vt.state.scalars(of: vt.cell(0, 0)) == Array("❤\u{FE0F}".unicodeScalars))
        let damage = vt.state.takeDamage()
        #expect(damage.contains(row: 0))
        #expect(!damage.contains(row: 1))
    }

    @Test func `each scalar of a ZWJ cluster damages its cell`() {
        var vt = VT(5, 3)
        vt.feed("\u{1B}[?2027h")
        var expected: [Unicode.Scalar] = []
        for scalar in "👨‍👩‍👧".unicodeScalars {
            _ = vt.state.takeDamage()
            expected.append(scalar)
            vt.feed(String(scalar))
            #expect(vt.state.scalars(of: vt.cell(0, 0)) == expected)
            let damage = vt.state.takeDamage()
            #expect(damage.contains(row: 0))
            #expect(!damage.contains(row: 1))
            #expect(vt.cursor.x == 2)
        }
    }

    @Test func `a widened cluster that cannot fit retains its original background`() {
        var vt = VT(1, 2)
        vt.feed("\u{1B}[31;44m❤")
        let original = vt.cell(0, 0).attributes
        vt.feed("\u{1B}[32;43m\u{FE0F}")
        #expect(vt.cell(0, 0).glyph == 0)
        #expect(vt.cell(0, 0).attributes == original)
        vt.feed("X")
        #expect(vt.cell(0, 1).attributes == vt.state.cursor.pen)
    }

    @Test(arguments: [false, true], [false, true])
    func `widening preserves the base attributes after the pen changes`(_ grouped: Bool, _ atEdge: Bool) {
        var vt = VT(3, 3)
        if atEdge {
            vt.feed("\u{1B}[2C")
        }
        vt.feed("\u{1B}[1;31;44;4;58;2;255;0;0m\u{1B}]8;;https://example.com/old\u{7}")
        vt.feed(grouped ? "☺\u{200D}" : "❤")
        let original = vt.cell(atEdge ? 2 : 0, 0).attributes
        vt.feed("\u{1B}[0;3;32;43m\u{1B}]8;;https://example.com/new\u{7}")
        let pen = vt.state.cursor.pen
        vt.feed(grouped ? "❤" : "\u{FE0F}")
        let y = atEdge ? 1 : 0
        var expected = original
        expected.flags.insert(.grapheme)
        #expect(vt.cell(0, y).attributes == expected)
        expected.flags.subtract(.structural)
        expected.flags.insert(.spacerTail)
        #expect(vt.cell(1, y).attributes == expected)
        if atEdge {
            expected.flags.subtract(.structural)
            expected.flags.insert(.spacerHead)
            #expect(vt.cell(2, 0).attributes == expected)
        }
        #expect(vt.state.cursor.pen == pen)
        vt.feed("X")
        #expect(vt.cell(2, y).attributes == pen)
    }

    @Test(arguments: [false, true], [false, true])
    func `a joined scalar discarded at the grapheme limit does not change its width`(_ wide: Bool, _ atEdge: Bool) {
        var vt = VT(3, 3)
        if atEdge {
            vt.feed("\u{1B}[2C")
        }
        let retained = "☺" + String(repeating: "\u{301}", count: 64 - (wide ? 2 : 1))
            + "\u{200D}" + (wide ? "❤" : "")
        vt.feed(retained)
        let x = wide ? 0 : (atEdge ? 2 : 0), y = vt.state.cursor.y
        let cell = vt.cell(x, y)
        #expect(vt.state.scalars(of: cell).count == TerminalState.graphemeMaxLength + 1)
        let cursor = vt.state.cursor
        let point = TerminalPoint(row: vt.state.absoluteRow(viewportRow: y), column: x)
        let selection = Selection(anchor: point, head: point)
        vt.state.setSelection(selection)
        vt.feed(wide ? "\u{FE0E}" : "❤")
        #expect(vt.cell(x, y) == cell)
        #expect(vt.state.cursor.x == cursor.x)
        #expect(vt.state.cursor.y == cursor.y)
        #expect(vt.state.cursor.pendingWrap == cursor.pendingWrap)
        #expect(vt.state.selection == selection)
        for byte in "é".utf8 {
            vt.feed(bytes: [byte])
        }
        #expect(vt.cell(cursor.pendingWrap ? 0 : cursor.x, cursor.pendingWrap ? y + 1 : y).glyph == 0xE9)
    }

    @Test(arguments: [false, true])
    func `the last available grapheme slot still applies its width change`(_ wide: Bool) {
        var vt = VT(4, 2)
        let retained = "☺" + String(repeating: "\u{301}", count: 63 - (wide ? 2 : 1))
            + "\u{200D}" + (wide ? "❤" : "")
        vt.feed(retained)
        #expect(vt.state.scalars(of: vt.cell(0, 0)).count == TerminalState.graphemeMaxLength)
        let final = wide ? "\u{FE0E}" : "❤"
        vt.feed(final)
        #expect(vt.state.scalars(of: vt.cell(0, 0)) == Array((retained + final).unicodeScalars))
        #expect(vt.cell(0, 0).width == (wide ? 1 : 2))
        #expect(vt.state.cursor.x == (wide ? 1 : 2))
    }

    @Test(arguments: [false, true], [1, 3])
    func `moving a widened grapheme invalidates selection on its former cell`(_ selectedBase: Bool, _ rows: Int) throws {
        var vt = VT(3, rows)
        vt.feed("a\u{1B}[2C☺\u{200D}")
        let point = TerminalPoint(row: 0, column: selectedBase ? 2 : 0)
        let selection = Selection(anchor: point, head: point)
        vt.state.setSelection(selection)
        vt.feed("❤")
        let formerLine = vt.state.line(absoluteRow: 0)
        let former = try #require(formerLine)
        #expect(former.cells[2].flags.contains(.spacerHead))
        #expect(vt.state.scalars(of: vt.cell(0, rows == 1 ? 0 : 1)) == Array("☺\u{200D}❤".unicodeScalars))
        #expect(vt.state.selection == (selectedBase ? nil : selection))
    }

    @Test(arguments: ["❤️", "©️", "#️"], [false, true])
    func `widening a grapheme in a one column terminal stays within the grid`(_ cluster: String, _ autowrap: Bool) {
        for split in [false, true] {
            var state = TerminalState(columns: 1, rows: 2)
            var parser = Parser()
            let neighboringRow = Array("\u{1B}[2;1HZ\u{1B}[1;1H".utf8)
            parser.consume(neighboringRow.span, into: &state)
            if !autowrap {
                let disable = Array("\u{1B}[?7l".utf8)
                parser.consume(disable.span, into: &state)
            }
            let bytes = Array(cluster.utf8)
            if split {
                for byte in bytes {
                    let chunk = [byte]
                    parser.consume(chunk.span, into: &state)
                }
            } else {
                parser.consume(bytes.span, into: &state)
            }
            #expect(state.cursor.x == 0)
            #expect(state.cursor.y == 0)
            #expect(state.grid.row(0)[0].width == 1)
            #expect(!state.grid.row(0)[0].isSpacer)
            #expect(state.grid.row(0)[0].glyph == 0)
            #expect(state.grid.row(1)[0].glyph == UInt32(Unicode.Scalar("Z").value))
            #expect(state.grid.row(1)[0].width == 1)
            let following = Array("X".utf8)
            parser.consume(following.span, into: &state)
            #expect(state.cursor.x == 0)
            #expect(state.cursor.y == (autowrap ? 1 : 0))
            #expect(state.grid.row(state.cursor.y)[0].glyph == Unicode.Scalar("X").value)
        }
    }

    /// Feeds `cps` through `isBreak`, returning the break decisions.
    static func breaks(_ cps: [UInt32]) -> [Bool] {
        var state = GB.State()
        return (1 ..< cps.count).map { GB.isBreak(cps[$0 - 1], cps[$0], &state) }
    }

    // MARK: Ghostty grapheme.zig

    @Test func `emoji modifier`() {
        var state = GB.State()
        #expect(!GB.isBreak(0x261D, 0x1F3FF, &state))
        state = GB.State()
        #expect(GB.isBreak(0x22, 0x1F3FF, &state))
    }

    @Test func `long emoji zwj sequences`() {
        // 👩‍👩‍👧‍👦 then "_"
        #expect(Self.breaks([0x1F469, 0x200D, 0x1F469, 0x200D, 0x1F467, 0x200D, 0x1F466, 0x5F])
            == [false, false, false, false, false, false, true])
    }

    @Test func `width effect variation selectors`() {
        #expect(GB.widthEffect(previous: 0x2764, 0xFE0F) == .wide)
        #expect(GB.widthEffect(previous: 0x23, 0xFE0E) == .narrow)
        #expect(GB.widthEffect(previous: 0x78, 0xFE0F) == .ignore)

        #expect(GB.graphemeWidth([0x2764, 0xFE0F]) == (2, 2))
        #expect(GB.graphemeWidth([0x23, 0xFE0F]) == (2, 2))
        #expect(GB.graphemeWidth([0x78, 0xFE0F]) == (2, 1))
        #expect(GB.graphemeWidth([0x78, 0xFE0F, 0xFE0F]) == (3, 1))
        #expect(GB.graphemeWidth([0x23, 0xFE0E]) == (2, 1))
        #expect(GB.graphemeWidth([0x231A, 0xFE0E]) == (2, 1))
        #expect(GB.graphemeWidth([0x231A, 0xFE0E, 0xFE0F]) == (3, 1))
        #expect(GB.graphemeWidth([0x1F3F4, 0x200D, 0x2620, 0xFE0F]) == (4, 2))
    }

    @Test func `width emoji sequences`() {
        #expect(GB.graphemeWidth([0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467]) == (5, 2))
        #expect(GB.graphemeWidth([0x23, 0xFE0F, 0x20E3]) == (3, 2))
        #expect(GB.graphemeWidth([0x31, 0x20E3]) == (2, 1))
        #expect(GB.graphemeWidth([0x1F44B, 0x1F3FF]) == (2, 2))
    }

    @Test func `spacing marks can widen narrow clusters`() throws {
        var mark: UInt32?
        for cp in UInt32(0) ..< 0x110000 {
            guard UnicodeWidth.table.lookup(cp) == 1, !GB.isZeroInGrapheme(cp) else { continue }
            var state = GB.State()
            if !GB.isBreak(0x61, cp, &state) {
                mark = cp; break
            }
        }
        let cp = try #require(mark)
        #expect(UnicodeWidth.table.lookup(cp) == 1)
        #expect(!GB.isZeroInGrapheme(cp))
        #expect(GB.graphemeWidth([0x61, cp]) == (2, 2))
    }

    @Test func `width segmentation`() {
        #expect(GB.graphemeWidth([0x61]) == (1, 1))
        #expect(GB.graphemeWidth([0x61, 0x62]) == (1, 1))
        #expect(GB.graphemeWidth([0x1F1E6, 0x1F1E7, 0x1F1E8]) == (2, 2))
        #expect(GB.graphemeWidth([0x1F1E8]) == (1, 2))
        #expect(GB.graphemeWidth([UInt32]()) == (0, 0))
        #expect(GB.graphemeWidth([0x0301, 0x0302]) == (2, 0))
    }

    @Test func `invalid codepoints stand alone`() {
        #expect(GB.graphemeWidth([0x110000, 0x0301]) == (1, 1))
        #expect(GB.graphemeWidth([0x61, 0x110000]) == (1, 1))
    }

    // MARK: uucode grapheme.zig

    @Test(arguments: [
        // GB9c no longer needs a leading consonant: Linker Extend* x Consonant
        ([0x094D, 0x0915], [false]),
        ([0x0061, 0x094D, 0x0915], [false, false]),
        ([0x094D, 0x0300, 0x200D, 0x0915], [false, false, false]),
        ([0x094D, 0x094D, 0x0915], [false, false]),
        // Extend without a linker doesn't join a consonant
        ([0x0915, 0x0300, 0x0915], [false, true]),
        // A consonant ends the linker sequence
        ([0x094D, 0x0915, 0x0300, 0x0915], [false, false, true]),
        // Only InCB=Extend continues: ZWNJ, SpacingMark and a modifier end it
        ([0x094D, 0x200C, 0x0300, 0x0915], [false, false, true]),
        ([0x094D, 0x0903, 0x0915], [false, true]),
        ([0x094D, 0x1F3FB, 0x0915], [true, true]),
        // InCB=Linker with GCB=Other: break before, still joins a consonant
        ([0x0061, 0x1CF5, 0x0300, 0x0915], [true, false, false]),
        ([0x0061, 0x1CF6, 0x0915], [true, false]),
        ([0x0061, 0x11A3A, 0x11A0B], [true, false]),
        ([0x11A3A, 0x0061], [true]),
        // GB9c and GB11 overlap
        ([0x1F600, 0x094D, 0x0300, 0x200D, 0x1F600], [false, false, false, false]),
        ([0x1F600, 0x094D, 0x0300, 0x0915], [false, false, false]),
        ([0x1F600, 0x094D, 0x200C, 0x200D, 0x1F600], [false, false, false, false]),
        ([0x1F600, 0x094D, 0x200C, 0x0915], [false, false, true]),
        // An emoji modifier sequence can lead into GB9c
        ([0x1F44D, 0x1F3FB, 0x094D, 0x0915], [false, false, false]),
        // A GCB=Other linker ends the emoji sequence
        ([0x1F600, 0x1CF5, 0x0915], [true, false]),
    ] as [([UInt32], [Bool])])
    func `unicode 18 indic linker and overlapping emoji`(cps: [UInt32], expected: [Bool]) {
        #expect(Self.breaks(cps) == expected)
    }

    @Test func `long emoji zwj sequence with modifiers`() {
        // 👨🏻‍❤️‍💋‍👨🏿 then "_"
        #expect(Self.breaks([0x1F468, 0x1F3FB, 0x200D, 0x2764, 0xFE0F, 0x200D, 0x1F48B, 0x200D, 0x1F468, 0x1F3FF, 0x5F])
            == [false, false, false, false, false, false, false, false, false, true])
        #expect(GB.graphemeWidth([0x1F468, 0x1F3FB, 0x200D, 0x2764, 0xFE0F, 0x200D, 0x1F48B, 0x200D, 0x1F468, 0x1F3FF, 0x5F]) == (10, 2))
    }

    @Test func `regional indicator sequence`() {
        // 🇺🇸🇦🇹🇼_🇳_
        let cps: [UInt32] = [0x1F1FA, 0x1F1F8, 0x1F1E6, 0x1F1F9, 0x1F1FC, 0x5F, 0x1F1F3, 0x5F]
        var state = GB.State()
        #expect(!GB.isBreak(cps[0], cps[1], &state))
        #expect(state.base == .regionalIndicator)
        #expect(GB.isBreak(cps[1], cps[2], &state))
        #expect(state.base == .default)
        #expect(Self.breaks(cps) == [false, true, false, true, true, true, true])
    }

    @Test func `hangul and prepend`() {
        #expect(GB.graphemeWidth([0x1100, 0x1161]) == (2, 2))
        #expect(GB.graphemeWidth([0x1100, 0x1161, 0x11A8]) == (3, 2))
        #expect(GB.graphemeWidth([0xAC00, 0x11A8]) == (2, 2))
        // L L V is one cluster; the second L contributes width.
        #expect(GB.graphemeWidth([0x1100, 0x1100, 0x1161]) == (3, 2))
        // Prepend doesn't contribute width inside a cluster.
        #expect(GB.graphemeWidth([0x0D4E, 0x0D39]).length == 2)
        // Devanagari conjunct with ZWJ is a single cluster.
        #expect(GB.graphemeWidth([0x0915, 0x094D, 0x200D, 0x0937]).length == 4)
        #expect(GB.graphemeWidth([0x0915, 0x094D, 0x0915, 0x094D, 0x0915]) == (5, 2))
    }

    @Test func `property spot checks`() {
        for cp: UInt32 in [0x0301, 0x20E3, 0x1F3FB, 0x0D4E, 0x1161, 0x11A8, 0x200B, 0x200D, 0xFE0F, 0x0000, 0x110000] {
            #expect(GB.isZeroInGrapheme(cp), Comment(rawValue: escapedTestText("U+\(String(cp, radix: 16))")))
        }
        for cp: UInt32 in [0x61, 0x00AD, 0x0903, 0x4E00, 0x1F600, 0x1100, 0xAC00] {
            #expect(!GB.isZeroInGrapheme(cp), Comment(rawValue: escapedTestText("U+\(String(cp, radix: 16))")))
        }
        #expect(GB.isEmojiVSBase(0x2764) && GB.isEmojiVSBase(0x23) && GB.isEmojiVSBase(0x231A))
        #expect(!GB.isEmojiVSBase(0x78) && !GB.isEmojiVSBase(0x1F600))
        #expect(GB.isExtendedPictographic(0xA9) && GB.isExtendedPictographic(0x1F600) && GB.isExtendedPictographic(0x261D))
        #expect(!GB.isExtendedPictographic(0x1F3FB) && !GB.isExtendedPictographic(0x41) && !GB.isExtendedPictographic(0x1F1E6))
        #expect(GB.property(0x1F3FB) == .emojiModifier)
        #expect(GB.property(0x261D) == .emojiModifierBase)
        #expect(GB.property(0x094D) == .indicConjunctBreakLinkerExtend)
        #expect(GB.property(0x0915) == .indicConjunctBreakConsonant)
        #expect(GB.property(0x200C) == .zwnj)
        #expect(GB.property(0x200D) == .zwj)
        #expect(GB.property(0x000A) == .other)
    }

    // MARK: Conformance

    /// GraphemeBreakTest.txt with Ghostty's tailoring: pairs involving
    /// Control/CR/LF end the line (Ghostty filters them), and an emoji
    /// modifier not preceded by an Emoji_Modifier_Base breaks.
    @Test func `graphemeBreakTest conformance`() throws {
        var checked = 0
        var failures: [String] = []
        lines: for line in GraphemeBreakTestData.cases {
            let tokens = line.split(separator: " ")
            var cps: [UInt32] = []
            var marks: [Bool] = [] // marks[i]: break between cps[i] and cps[i+1]
            for (i, tok) in tokens.enumerated() {
                if i % 2 == 0 {
                    if i > 0, i < tokens.count - 1 {
                        marks.append(tok == "/")
                    }
                } else {
                    try cps.append(#require(UInt32(tok, radix: 16)))
                }
            }
            if GraphemeBreakTestData.controls.contains(cps[0]) {
                continue
            }
            var state = GB.State()
            for i in 1 ..< cps.count {
                let cp1 = cps[i - 1], cp2 = cps[i]
                if GraphemeBreakTestData.controls.contains(cp2) {
                    continue lines
                }
                var expected = marks[i - 1]
                if GB.property(cp2) == .emojiModifier, GB.property(cp1) != .emojiModifierBase {
                    #expect(!expected)
                    expected = true
                }
                let actual = GB.isBreak(cp1, cp2, &state)
                checked += 1
                if actual != expected {
                    failures.append("\(line) @\(i): expected \(expected)")
                }
            }
        }
        #expect(failures.isEmpty, Comment(rawValue: escapedTestText("\(failures.prefix(20))")))
        #expect(checked > 1000)
    }

    /// Slow reference: uucode's rules evaluated directly.
    @Test func `precomputed table matches compute`() {
        for s in 0 ..< GB.State.count {
            for g1 in GB.Property.allCases {
                for g2 in GB.Property.allCases {
                    var a = GB.State(raw: UInt8(s))
                    let r = GB.compute(g1, g2, &a)
                    let v = GB.tables.breaks[(s * GB.Property.count + Int(g1.rawValue)) * GB.Property.count + Int(g2.rawValue)]
                    #expect((v & 1 != 0) == r)
                    #expect(v >> 1 == a.raw)
                }
            }
        }
    }

    // MARK: mayJoin

    /// `mayJoin == false` must imply `isBreak == true` for every state.
    @Test func `mayJoin false implies break`() {
        func check(_ prev: UInt32, _ cp: UInt32) -> Bool {
            guard !GB.mayJoin(previous: prev, cp) else { return true }
            for s in 0 ..< UInt8(GB.State.count) {
                var state = GB.State(raw: s)
                if !GB.isBreak(prev, cp, &state) {
                    return false
                }
            }
            return true
        }

        // Fast path region exhaustively.
        var bad: [(UInt32, UInt32)] = []
        for prev in UInt32(0) ..< 0x300 {
            for cp in UInt32(0) ..< 0x300 where !check(prev, cp) {
                bad.append((prev, cp))
            }
        }

        // One representative scalar per property: every (gb1, gb2) class pair.
        var reps: [UInt32] = []
        var seen = Set<GB.Property>()
        for cp in UInt32(0) ..< 0x110000 where seen.insert(GB.property(cp)).inserted {
            reps.append(cp)
        }
        #expect(seen.count == GB.Property.count)
        for prev in reps {
            for cp in reps where !check(prev, cp) {
                bad.append((prev, cp))
            }
        }

        // Broad sweep: common and per-property previous scalars against a
        // stride over the whole codespace (stride 5 keeps debug builds fast
        // while hitting every block).
        reps += [0x41, 0x20, 0xA9, 0x2FF, 0x300, 0x4E00, 0xAC00, 0x3000, 0x110000]
        for prev in reps {
            for cp in stride(from: UInt32(0), through: 0x110000, by: 5) where !check(prev, cp) {
                bad.append((prev, cp))
            }
        }
        #expect(bad.isEmpty, Comment(rawValue: escapedTestText("\(bad.prefix(10))")))

        // And mayJoin is precise at the property level: it is true for some
        // joining pair in each (gb1, gb2) class it admits.
        #expect(!GB.mayJoin(previous: 0x41, 0x42))
        #expect(!GB.mayJoin(previous: 0x4E00, 0x4E01))
        #expect(GB.mayJoin(previous: 0x65, 0x0301))
        #expect(GB.mayJoin(previous: 0x200D, 0x1F600))
        #expect(GB.mayJoin(previous: 0x1F1E6, 0x1F1E7))
    }
}
