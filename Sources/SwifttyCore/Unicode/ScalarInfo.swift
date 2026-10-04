/// Width and grapheme break class of every scalar in one two-stage table,
/// so the batched print path pays a single lookup per scalar.
///
/// Each entry is `class | width << 5` (class: `GraphemeBreak.Property`,
/// width 0...2). Built once from `UnicodeWidth.table` and
/// `GraphemeBreak.tables` by deduplicating 256-scalar blocks.
struct ScalarInfoTable: @unchecked Sendable {
    private let stage1: UnsafeMutablePointer<UInt16>
    private let stage2: UnsafeMutablePointer<UInt8>

    static let shared = ScalarInfoTable()

    init() {
        let widths = UnicodeWidth.table
        let grapheme = GraphemeBreak.tables
        let blockCount = 0x110000 >> 8
        stage1 = .allocate(capacity: blockCount)
        var blocks: [UInt8] = []
        var index: [[UInt8]: UInt16] = [:]
        var block = [UInt8](repeating: 0, count: 256)
        for b in 0 ..< blockCount {
            for k in 0 ..< 256 {
                let cp = UInt32(b << 8 | k)
                block[k] = grapheme.props(cp) & 0x1F | widths.lookup(cp) << 5
            }
            if let i = index[block] {
                stage1[b] = i
            } else {
                let i = UInt16(index.count)
                index[block] = i
                blocks.append(contentsOf: block)
                stage1[b] = i
            }
        }
        stage2 = .allocate(capacity: blocks.count)
        stage2.initialize(from: blocks, count: blocks.count)
    }

    /// `(width, break class)` packed as described above; scalars past
    /// U+10FFFF are width 1, class Other.
    @inline(__always)
    func lookup(_ cp: UInt32) -> UInt8 {
        guard cp < 0x110000 else { return 1 << 5 }
        return stage2[Int(stage1[Int(cp >> 8)]) << 8 | Int(cp & 0xFF)]
    }
}
