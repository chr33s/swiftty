import CoreGraphics
@testable import SwifttyCore
import Testing

struct BoxDrawingTests {
    static let w = 16, h = 32

    /// Coverage (alpha > 127) of `cp` drawn into one cell, row 0 at the top.
    func draw(_ cp: UInt32) -> [[Bool]] {
        let ctx = CGContext(
            data: nil, width: Self.w, height: Self.h, bitsPerComponent: 8, bytesPerRow: Self.w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        )!
        BoxDrawing.draw(cp, in: ctx, width: CGFloat(Self.w), height: CGFloat(Self.h))
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return (0 ..< Self.h).map { y in (0 ..< Self.w).map { x in data[(y * Self.w + x) * 4 + 3] > 127 } }
    }

    /// Runs of covered pixels along a row or column.
    func runs(_ line: [Bool]) -> Int {
        zip([false] + line, line).filter { !$0 && $1 }.count
    }

    @Test func `solid and dashed lines`() {
        let mid = Self.h / 2
        #expect(runs(draw(0x2500)[mid]) == 1)
        #expect(!draw(0x2500)[mid].contains(false)) // spans the whole cell
        #expect(runs(draw(0x2504)[mid]) == 3)
        #expect(runs(draw(0x2508)[mid]) == 4)
        #expect(runs(draw(0x254C)[mid]) == 2)
        #expect(runs(draw(0x2506).map { $0[Self.w / 2] }) == 3)
        #expect(runs(draw(0x250A).map { $0[Self.w / 2] }) == 4)
    }

    @Test func `diagonals reach the corners`() {
        let up = draw(0x2571), down = draw(0x2572), cross = draw(0x2573)
        #expect(up[0][Self.w - 1] && up[Self.h - 1][0] && !up[0][0])
        #expect(down[0][0] && down[Self.h - 1][Self.w - 1] && !down[0][Self.w - 1])
        #expect(cross[0][0] && cross[0][Self.w - 1])
        #expect(BoxDrawing.covers(0x2571))
    }

    @Test func `braille dots`() {
        func dots(_ cp: UInt32) -> Int {
            let g = draw(cp)
            return [(0, 0), (1, 0), (0, 1), (1, 1), (0, 2), (1, 2), (0, 3), (1, 3)].filter { c, r in
                g[r * Self.h / 4 + Self.h / 8][c * Self.w / 2 + Self.w / 4]
            }.count
        }
        #expect(dots(0x2800) == 0)
        #expect(dots(0x2801) == 1)
        #expect(dots(0x28FF) == 8)
        let left = draw(0x2847) // dots 1, 2, 3, 7: the left column
        #expect(left[Self.h / 8][Self.w / 4] && !left[Self.h / 8][3 * Self.w / 4])
    }

    @Test func `sextants skip the half blocks`() {
        func filled(_ cp: UInt32) -> [Bool] {
            let g = draw(cp)
            return (0 ..< 6).map { g[($0 / 2) * Self.h / 3 + Self.h / 6][($0 % 2) * Self.w / 2 + Self.w / 4] }
        }
        #expect(filled(0x1FB00) == [true, false, false, false, false, false])
        #expect(filled(0x1FB13) == [false, false, true, false, true, false]) // SEXTANT-35, mask 20
        #expect(filled(0x1FB14) == [false, true, true, false, true, false]) // SEXTANT-235, mask 22 after skipping 21
        #expect(filled(0x1FB3B) == [false, true, true, true, true, true]) // mask 62
    }

    @Test func `powerline triangles point the right way`() {
        let right = draw(0xE0B0), left = draw(0xE0B2)
        let mid = Self.h / 2
        #expect(right[1][0] && !right[1][Self.w - 1] && right[mid][Self.w - 2])
        #expect(left[1][Self.w - 1] && !left[1][0] && left[mid][1])
        let outline = draw(0xE0B1)
        #expect(!outline[mid][0] && outline[mid][Self.w - 2]) // hollow
        let circle = draw(0xE0B4)
        #expect(circle[mid][Self.w - 2] && circle[mid][0])
    }
}
