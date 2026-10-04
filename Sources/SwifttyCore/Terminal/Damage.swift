/// Rows changed since the last snapshot.
///
/// Fixed inline storage covers 512 rows without allocating; taller grids
/// (or wholesale changes) degrade to `isFull`.
public struct DamageRegion: Sendable, Equatable {
    public static let maxTrackedRows = 512

    public private(set) var isFull: Bool
    private var bits: InlineArray<8, UInt64>

    public init(full: Bool = false) {
        isFull = full
        bits = InlineArray(repeating: 0)
    }

    public static let none = DamageRegion()
    public static let full = DamageRegion(full: true)

    @inline(__always)
    public mutating func insert(row: Int) {
        guard row < Self.maxTrackedRows else { isFull = true; return }
        bits[row >> 6] |= 1 << UInt64(row & 63)
    }

    public mutating func insert(rows: Range<Int>) {
        for row in rows {
            insert(row: row)
        }
    }

    public mutating func setFull() {
        isFull = true
    }

    public mutating func formUnion(_ other: DamageRegion) {
        if other.isFull {
            isFull = true
        }
        for i in 0 ..< 8 {
            bits[i] |= other.bits[i]
        }
    }

    @inline(__always)
    public func contains(row: Int) -> Bool {
        if isFull {
            return true
        }
        guard row < Self.maxTrackedRows else { return false }
        return bits[row >> 6] & (1 << UInt64(row & 63)) != 0
    }

    public var isEmpty: Bool {
        if isFull {
            return false
        }
        for i in 0 ..< 8 where bits[i] != 0 {
            return false
        }
        return true
    }

    public static func == (lhs: DamageRegion, rhs: DamageRegion) -> Bool {
        guard lhs.isFull == rhs.isFull else { return false }
        for i in 0 ..< 8 where lhs.bits[i] != rhs.bits[i] {
            return false
        }
        return true
    }
}
