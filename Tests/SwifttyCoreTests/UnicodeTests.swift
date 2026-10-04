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

    @Test func `table is generated`() {
        #expect(!UnicodeTables.version.isEmpty)
        #expect(UnicodeTables.wide.count % 2 == 0 && UnicodeTables.zeroWidth.count % 2 == 0)
    }
}
