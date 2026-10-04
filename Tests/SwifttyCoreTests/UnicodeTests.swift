@testable import SwifttyCore
import Testing

struct UnicodeTests {
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
}

struct EmojiClusterTests {
    @Test func `skin tone and flags join`() {
        var vt = VT(10, 2)
        vt.feed("👍🏽🇯🇵x")
        let c = vt.cursor
        #expect(c == (5, 0))
        #expect(vt.lines[0] == "👍🏽🇯🇵x")
    }
}
