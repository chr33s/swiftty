@testable import SwifttyCore
import Testing
import TestSupport

struct UnicodeTests {
    @Test(arguments: [
        0x05C8, 0x05C9, 0x0B53, 0x0B54, 0x1ADE, 0x1ADF, 0x1AEC, 0x1AED, 0x1AEE, 0x1AEF, 0x1AF0,
        0x10ECB, 0x10ECC, 0x10ECD, 0x10ECE, 0x10ECF, 0x10EF0, 0x10EF1, 0x10EF2, 0x10EF3,
        0x10EF4, 0x10EF5, 0x10EF6, 0x10EF7, 0x10EF8, 0x10EF9, 0x11DF0, 0x1D127, 0x1D128, 0x1D25B, 0x1D25C,
    ] as [UInt32])
    func `unicode 18 combining marks have zero width`(_ scalar: UInt32) {
        #expect(UnicodeWidth.width(scalar) == 0)
    }

    @Test(arguments: [
        (0x41, 1), (0xE9, 1), (0x301, 0), (0x200B, 0), (0x200D, 0), (0xFE0F, 0),
        (0x4E2D, 2), (0xAC00, 2), (0x1F600, 2), (0xFF21, 2), (0x1160, 0), (0x00AD, 1),
        (0x2500, 1), (0x10FFFF, 1),
    ] as [(UInt32, Int)])
    func widths(scalar: UInt32, expected: Int) {
        #expect(UnicodeWidth.width(scalar) == expected)
    }

    /// The two-stage table must agree with the generated ranges everywhere.
    @Test func `staged table matches ranges`() {
        var expected = [UInt8](repeating: 1, count: 0x110000)
        for (ranges, value) in [(UnicodeTables.wide, UInt8(2)), (UnicodeTables.zeroWidth, 0)] {
            for i in stride(from: 0, to: ranges.count, by: 2) {
                for cp in ranges[i] ... ranges[i + 1] {
                    expected[Int(cp)] = value
                }
            }
        }
        let table = WidthTable()
        var mismatches = 0
        for cp in 0 ..< 0x110000 where table.lookup(UInt32(cp)) != expected[cp] {
            mismatches += 1
        }
        #expect(mismatches == 0)
        #expect(UnicodeTables.stage2.utf8CodeUnitCount % 256 == 0)
    }

    @Test func `table is generated`() {
        #expect(!UnicodeTables.version.isEmpty)
        #expect(UnicodeTables.wide.count % 2 == 0 && UnicodeTables.zeroWidth.count % 2 == 0)
    }

    @Test func `combined scalar table matches source tables everywhere`() {
        let table = ScalarInfoTable.shared
        let widths = UnicodeWidth.table
        let grapheme = GraphemeBreak.tables
        var mismatch: UInt32?
        for cp in UInt32(0) ..< 0x110000 {
            let expected = grapheme.props(cp) & 0x1F | widths.lookup(cp) << 5
            if table.lookup(cp) != expected {
                mismatch = cp
                break
            }
        }
        #expect(mismatch == nil)
        for cp in [UInt32(0x110000), 0x1FFFFF, .max] {
            #expect(table.lookup(cp) == 1 << 5)
        }
    }
}

struct EmojiClusterTests {
    @Test func `skin tone and flags join`() {
        var vt = VT(10, 2)
        vt.feed("👍🏽🇯🇵x")
        let c = vt.cursor
        #expect(c == (5, 0))
        #expect(TestFixture(vt.lines[0]) == TestFixture("👍🏽🇯🇵x"))
    }
}
