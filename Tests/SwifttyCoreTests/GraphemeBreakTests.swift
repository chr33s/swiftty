@testable import SwifttyCore
import Testing

/// Ports of Ghostty `src/unicode/grapheme.zig` tests and the uucode
/// grapheme tests Ghostty relies on, plus conformance and pre-filter checks.
struct GraphemeBreakTests {
    typealias GB = GraphemeBreak

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

    @Test func `spacing marks can widen narrow clusters`() {
        var mark: UInt32?
        for cp in UInt32(0) ..< 0x110000 {
            guard UnicodeWidth.table.lookup(cp) == 1, !GB.isZeroInGrapheme(cp) else { continue }
            var state = GB.State()
            if !GB.isBreak(0x61, cp, &state) { mark = cp; break }
        }
        let cp = try! #require(mark)
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
            #expect(GB.isZeroInGrapheme(cp), "U+\(String(cp, radix: 16))")
        }
        for cp: UInt32 in [0x61, 0x00AD, 0x0903, 0x4E00, 0x1F600, 0x1100, 0xAC00] {
            #expect(!GB.isZeroInGrapheme(cp), "U+\(String(cp, radix: 16))")
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
    @Test func `GraphemeBreakTest conformance`() {
        var checked = 0
        var failures: [String] = []
        lines: for line in GraphemeBreakTestData.cases {
            let tokens = line.split(separator: " ")
            var cps: [UInt32] = []
            var marks: [Bool] = [] // marks[i]: break between cps[i] and cps[i+1]
            for (i, tok) in tokens.enumerated() {
                if i % 2 == 0 {
                    if i > 0, i < tokens.count - 1 { marks.append(tok == "/") }
                } else {
                    cps.append(UInt32(tok, radix: 16)!)
                }
            }
            if GraphemeBreakTestData.controls.contains(cps[0]) { continue }
            var state = GB.State()
            for i in 1 ..< cps.count {
                let cp1 = cps[i - 1], cp2 = cps[i]
                if GraphemeBreakTestData.controls.contains(cp2) { continue lines }
                var expected = marks[i - 1]
                if GB.property(cp2) == .emojiModifier, GB.property(cp1) != .emojiModifierBase {
                    #expect(!expected)
                    expected = true
                }
                let actual = GB.isBreak(cp1, cp2, &state)
                checked += 1
                if actual != expected { failures.append("\(line) @\(i): expected \(expected)") }
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(20))")
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
                if !GB.isBreak(prev, cp, &state) { return false }
            }
            return true
        }

        // Fast path region exhaustively.
        var bad: [(UInt32, UInt32)] = []
        for prev in UInt32(0) ..< 0x300 {
            for cp in UInt32(0) ..< 0x300 where !check(prev, cp) { bad.append((prev, cp)) }
        }

        // One representative scalar per property: every (gb1, gb2) class pair.
        var reps: [UInt32] = []
        var seen = Set<GB.Property>()
        for cp in UInt32(0) ..< 0x110000 where seen.insert(GB.property(cp)).inserted { reps.append(cp) }
        #expect(seen.count == GB.Property.count)
        for prev in reps {
            for cp in reps where !check(prev, cp) { bad.append((prev, cp)) }
        }

        // Broad sweep: common and per-property previous scalars against a
        // stride over the whole codespace (stride 5 keeps debug builds fast
        // while hitting every block).
        reps += [0x41, 0x20, 0xA9, 0x2FF, 0x300, 0x4E00, 0xAC00, 0x3000, 0x110000]
        for prev in reps {
            for cp in stride(from: UInt32(0), through: 0x110000, by: 5) where !check(prev, cp) { bad.append((prev, cp)) }
        }
        #expect(bad.isEmpty, "\(bad.prefix(10))")

        // And mayJoin is precise at the property level: it is true for some
        // joining pair in each (gb1, gb2) class it admits.
        #expect(!GB.mayJoin(previous: 0x41, 0x42))
        #expect(!GB.mayJoin(previous: 0x4E00, 0x4E01))
        #expect(GB.mayJoin(previous: 0x65, 0x0301))
        #expect(GB.mayJoin(previous: 0x200D, 0x1F600))
        #expect(GB.mayJoin(previous: 0x1F1E6, 0x1F1E7))
    }
}
