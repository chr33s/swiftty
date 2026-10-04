import CAllocCounter
@testable import SwifttyCore
import Testing

/// Hot paths must not touch the heap once warmed up (spec §13).
@Suite(.serialized) struct AllocationTests {
    static func ascii(_ count: Int) -> [UInt8] {
        let line = Array("The quick brown fox jumps over the lazy dog 0123456789 ~!@#$%^&*()\r\n".utf8)
        return Array((0 ..< count / line.count + 1).lazy.flatMap { _ in line }.prefix(count))
    }

    static let utf8 = Array(String(repeating: "héllo wörld — 中文字符 😀 ünïcödé\r\n", count: 2000).utf8)
    static let csi = Array(String(
        repeating: "\u{1B}[1;31mred\u{1B}[0m \u{1B}[38;2;10;20;30mrgb\u{1B}[m\u{1B}[5;10H\u{1B}[K\u{1B}[2Ax\u{1B}[?25l\u{1B}[?25h\r\n",
        count: 2000,
    ).utf8)

    /// Warm-up fills the scrollback (one block) and its line ring so the
    /// measured pass is steady state.
    func allocations(_ input: [UInt8], warmups: Int = 3) -> UInt64 {
        // One scrollback block so warm-up reaches steady state.
        var state = TerminalState(columns: 120, rows: 40, scrollbackLimitBytes: 1)
        var parser = Parser()
        let span = input.span
        for _ in 0 ..< warmups {
            parser.consume(span, into: &state)
        }
        alloc_counter_start()
        parser.consume(span, into: &state)
        _ = state.takeDamage()
        return alloc_counter_stop()
    }

    @Test func `counter works`() {
        alloc_counter_start()
        let array = [Int](repeating: 1, count: 1000)
        let count = alloc_counter_stop()
        #expect(array.count == 1000 && count >= 1)
    }

    @Test func `ascii stream does not allocate`() {
        #expect(allocations(Self.ascii(1 << 20)) == 0)
    }

    @Test func `utf 8 stream does not allocate`() {
        #expect(allocations(Self.utf8) == 0)
    }

    @Test func `csi stream does not allocate`() {
        #expect(allocations(Self.csi) == 0)
    }

    @Test func `cell updates do not allocate`() {
        let grid = Grid(columns: 200, rows: 60)
        let cell = Cell(glyph: 0x41, attributes: CellAttributes(foreground: .palette(3)), width: 1)
        alloc_counter_start()
        for y in 0 ..< 60 {
            for x in 0 ..< 200 {
                grid[x, y] = cell
            }
            grid.scrollUp(top: 0, bottom: 59, count: 1, fill: .blank)
            grid.insertCells(row: y, at: 3, count: 4, fill: .blank)
        }
        #expect(alloc_counter_stop() == 0)
    }
}
