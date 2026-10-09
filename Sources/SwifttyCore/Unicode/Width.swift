/// Terminal column widths for Unicode scalars (wcwidth semantics).
///
/// Lookups use the generated two-stage table in `Tables.swift`.
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

    /// Scalar count and column width of the first printable grapheme.
    /// Uses the terminal's Unicode segmentation and emoji width rules.
    /// An empty collection returns `(0, 0)`; standalone combining and format
    /// characters can have width zero. Callers must filter control characters.
    public static func graphemeWidth<C: RandomAccessCollection>(_ scalars: C) -> (length: Int, width: Int)
        where C.Element == UInt32 {
        GraphemeBreak.graphemeWidth(scalars)
    }

    @usableFromInline static let table = WidthTable()

    /// ZERO WIDTH JOINER: glues the next scalar onto the current cluster.
    public static let zeroWidthJoiner: UInt32 = 0x200D
}

/// Two-stage width lookup over the generated tables in `Tables.swift`.
/// Stage 2 is a StaticString in constant data, so building this costs only
/// the 4,352-entry stage-1 copy; a lookup is two loads.
@usableFromInline
struct WidthTable: @unchecked Sendable {
    private let stage1: UnsafeMutableBufferPointer<UInt16>
    private let stage2: UnsafePointer<UInt8> // ASCII '0'/'1'/'2'

    init() {
        stage1 = .allocate(capacity: UnicodeTables.stage1.count)
        _ = stage1.initialize(from: UnicodeTables.stage1)
        stage2 = UnicodeTables.stage2.utf8Start
    }

    @usableFromInline @inline(__always)
    func lookup(_ scalar: UInt32) -> UInt8 {
        guard scalar < 0x110000 else { return 1 }
        return stage2[Int(stage1[Int(scalar >> 8)]) << 8 | Int(scalar & 0xFF)] &- 0x30
    }
}
