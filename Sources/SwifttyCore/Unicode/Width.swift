/// Terminal column widths for Unicode scalars (wcwidth semantics).
///
/// Lookups use a two-stage table built once from the generated ranges in
/// `Tables.swift`: 256-entry blocks are deduplicated so the whole table is a
/// few KB and every lookup is two loads.
public enum UnicodeWidth {
    /// Width of a printable scalar: 0 (combining/format), 1, or 2 (wide).
    /// C0/C1 controls are the parser's business and report 1 here.
    @inlinable @inline(__always)
    public static func width(_ scalar: UInt32) -> Int {
        if scalar < 0x300 {
            return 1
        }
        return Int(table.lookup(scalar))
    }

    @usableFromInline static let table = WidthTable()

    /// ZERO WIDTH JOINER: glues the next scalar onto the current cluster.
    public static let zeroWidthJoiner: UInt32 = 0x200D
}

/// Plain pointers so lookups are two loads with no ARC or lazy-init checks
/// once a copy is held (TerminalState keeps one).
@usableFromInline
struct WidthTable: @unchecked Sendable {
    // Stage 1 maps `scalar >> 8` to a block; stage 2 holds widths. Both are
    // immutable after init and live for the process lifetime.
    private let stage1: UnsafeMutableBufferPointer<UInt16>
    private let stage2: UnsafeMutableBufferPointer<UInt8>

    init() {
        var widths = [UInt8](repeating: 1, count: 0x110000)
        func fill(_ ranges: [UInt32], _ value: UInt8) {
            var i = 0
            while i < ranges.count {
                for cp in ranges[i] ... ranges[i + 1] {
                    widths[Int(cp)] = value
                }
                i += 2
            }
        }
        fill(UnicodeTables.wide, 2)
        fill(UnicodeTables.zeroWidth, 0)

        var s1 = [UInt16](repeating: 0, count: 0x1100)
        var s2: [UInt8] = []
        var seen: [[UInt8]: UInt16] = [:]
        for block in 0 ..< 0x1100 {
            let slice = Array(widths[block << 8 ..< (block + 1) << 8])
            if let index = seen[slice] {
                s1[block] = index
            } else {
                let index = UInt16(s2.count >> 8)
                seen[slice] = index
                s1[block] = index
                s2.append(contentsOf: slice)
            }
        }
        stage1 = .allocate(capacity: s1.count)
        _ = stage1.initialize(from: s1)
        stage2 = .allocate(capacity: s2.count)
        _ = stage2.initialize(from: s2)
    }

    @usableFromInline @inline(__always)
    func lookup(_ scalar: UInt32) -> UInt8 {
        guard scalar < 0x110000 else { return 1 }
        return stage2[Int(stage1[Int(scalar >> 8)]) << 8 | Int(scalar & 0xFF)]
    }
}
