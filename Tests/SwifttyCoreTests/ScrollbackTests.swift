@testable import SwifttyCore
import Testing

struct ScrollbackTests {
    func row(_ s: String, width: Int = 8) -> [Cell] {
        var cells = s.unicodeScalars.map { Cell(glyph: $0.value, attributes: .default, width: 1) }
        while cells.count < width {
            cells.append(.blank)
        }
        return cells
    }

    @Test func `push trims and reads back`() {
        var sb = Scrollback()
        row("abc").withUnsafeBufferPointer { sb.push($0, wrapped: false) }
        row("wrapped!").withUnsafeBufferPointer { sb.push($0, wrapped: true) }
        do { let ok = sb.count == 2; #expect(ok, "sb.count == 2") }
        do { let ok = sb.line(0).cells.count == 3; #expect(ok, "sb.line(0).cells.count == 3") }
        do { let ok = sb.line(1).cells.count == 8 && sb.line(1).wrapped; #expect(ok, "sb.line(1).cells.count == 8 && sb.line(1).wrapped") }
    }

    @Test func `evicts oldest block at limit`() {
        let bytesPerBlock = Scrollback.blockCells * MemoryLayout<Cell>.stride
        var sb = Scrollback(limitBytes: 2 * bytesPerBlock)
        let full = row(String(repeating: "x", count: 1000), width: 1000)
        for _ in 0 ..< 100 {
            full.withUnsafeBufferPointer { sb.push($0, wrapped: false) }
        }
        // 16 lines per block, 2 blocks max.
        do { let ok = sb.count <= 32 && sb.count > 16; #expect(ok, "sb.count <= 32 && sb.count > 16") }
        do { let ok = sb.line(sb.count - 1).cells.count == 1000; #expect(ok, "sb.line(sb.count - 1).cells.count == 1000") }
    }

    @Test func `max lines`() {
        var sb = Scrollback(maxLines: 10)
        for i in 0 ..< 25 {
            row("\(i)").withUnsafeBufferPointer { sb.push($0, wrapped: false) }
        }
        do { let ok = sb.count == 10; #expect(ok, "sb.count == 10") }
        #expect(sb.line(0).cells.first?.glyph == UInt32(("1" as Unicode.Scalar).value)) // "15"
    }
}
