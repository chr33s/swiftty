/// Lines that scrolled off the top of the primary screen.
///
/// Cells live in fixed-size blocks; a line never straddles blocks. When the
/// byte limit is reached the oldest block is recycled together with every
/// line in it, so steady-state pushes never allocate. Trailing blank cells
/// of unwrapped lines are trimmed, which keeps typical shell output compact.
public struct Scrollback: ~Copyable {
    struct Line: BitwiseCopyable {
        var block: Int // absolute block sequence number
        var offset: Int32
        var count: Int32
        var wrapped: Bool
    }

    public static let blockCells = 16384 // 256 KiB per block

    public let maxLines: Int
    private let maxBlocks: Int

    // Ring of block pointers, oldest at `blockHead`. Slots past `blockCount`
    // may hold blocks kept from `removeAll()` for reuse.
    private let blocks: UnsafeMutablePointer<UnsafeMutablePointer<Cell>?>
    private var blockHead = 0
    private var blockCount = 0
    private var firstBlock = 0 // sequence number of the oldest block
    private var blockFill = Scrollback.blockCells // cells used in the newest block

    private var lines: UnsafeMutablePointer<Line>
    private var lineCapacity: Int
    private var head = 0
    public private(set) var count = 0

    /// - Parameters:
    ///   - limitBytes: cell memory budget (Ghostty's `scrollback-limit`).
    ///   - maxLines: upper bound on line count regardless of size.
    public init(limitBytes: Int = 10_000_000, maxLines: Int = 100_000) {
        let blockBytes = Self.blockCells * MemoryLayout<Cell>.stride
        maxBlocks = max(1, (limitBytes + blockBytes - 1) / blockBytes)
        self.maxLines = max(1, maxLines)
        lineCapacity = min(1024, self.maxLines)
        lines = .allocate(capacity: lineCapacity)
        blocks = .allocate(capacity: maxBlocks)
        blocks.initialize(repeating: nil, count: maxBlocks)
    }

    deinit {
        for i in 0 ..< maxBlocks {
            blocks[i]?.deallocate()
        }
        blocks.deallocate()
        lines.deallocate()
    }

    @inline(__always)
    private func block(_ sequence: Int) -> UnsafeMutablePointer<Cell> {
        blocks[(blockHead + sequence - firstBlock) % maxBlocks]!
    }

    public var isEmpty: Bool {
        count == 0
    }

    /// Line `index`, oldest first.
    public func line(_ index: Int) -> (cells: UnsafeBufferPointer<Cell>, wrapped: Bool) {
        let line = lines[(head + index) % lineCapacity]
        let base = block(line.block) + Int(line.offset)
        return (UnsafeBufferPointer(start: base, count: Int(line.count)), line.wrapped)
    }

    /// Mutable access for grapheme-table compaction.
    func mutableCells(_ index: Int) -> UnsafeMutableBufferPointer<Cell> {
        let line = lines[(head + index) % lineCapacity]
        return UnsafeMutableBufferPointer(start: block(line.block) + Int(line.offset), count: Int(line.count))
    }

    public mutating func push(_ row: UnsafeBufferPointer<Cell>, wrapped: Bool) {
        var length = min(row.count, Self.blockCells)
        if !wrapped {
            while length > 0, row[length - 1].isBlank {
                length -= 1
            }
        }
        if blockCount == 0 || blockFill + length > Self.blockCells {
            startBlock()
        }
        let newest = firstBlock + blockCount - 1
        let base = block(newest) + blockFill
        if length > 0 {
            base.initialize(from: row.baseAddress!, count: length)
        }

        if count == maxLines {
            dropOldestLine()
        }
        if count == lineCapacity {
            growLines()
        }
        lines[(head + count) % lineCapacity] = Line(
            block: newest,
            offset: Int32(blockFill),
            count: Int32(length),
            wrapped: wrapped,
        )
        count += 1
        blockFill += length
    }

    /// Removes and returns the newest line's cells via `body`.
    public mutating func popNewest<R>(_ body: (UnsafeBufferPointer<Cell>, Bool) -> R) -> R? {
        guard count > 0 else { return nil }
        let (cells, wrapped) = line(count - 1)
        let result = body(cells, wrapped)
        count -= 1
        return result
    }

    public mutating func removeAll() {
        blockCount = 0
        firstBlock = 0
        blockFill = Self.blockCells
        head = 0
        count = 0
    }

    private mutating func startBlock() {
        if blockCount == maxBlocks {
            // Recycle the oldest block: its slot becomes the newest.
            while count > 0, lines[head].block == firstBlock {
                dropOldestLine()
            }
            blockHead = (blockHead + 1) % maxBlocks
            blockCount -= 1
            firstBlock += 1
        }
        let slot = (blockHead + blockCount) % maxBlocks
        if blocks[slot] == nil {
            blocks[slot] = .allocate(capacity: Self.blockCells)
        }
        blockCount += 1
        blockFill = 0
    }

    private mutating func dropOldestLine() {
        head = (head + 1) % lineCapacity
        count -= 1
    }

    private mutating func growLines() {
        let newCapacity = min(maxLines, lineCapacity * 2)
        let fresh = UnsafeMutablePointer<Line>.allocate(capacity: newCapacity)
        for i in 0 ..< count {
            fresh[i] = lines[(head + i) % lineCapacity]
        }
        lines.deallocate()
        lines = fresh
        lineCapacity = newCapacity
        head = 0
    }
}
