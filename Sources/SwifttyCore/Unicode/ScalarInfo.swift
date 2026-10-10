/// Width and grapheme break class packed into one lookup per scalar.
/// BMP scalars use a direct 64 KiB cache; others use a two-stage table.
///
/// Each entry is `class | width << 5` (class: `GraphemeBreak.Property`,
/// width 0...2). Built once from `UnicodeWidth.table` and
/// `GraphemeBreak.tables` by combining distinct source-block slices.
struct ScalarInfoTable: @unchecked Sendable {
  private let stage1: UnsafeMutablePointer<UInt16>
  private let stage2: UnsafeMutablePointer<UInt8>
  private let bmp: UnsafeMutablePointer<UInt8>

  private static let shift = min(8, GraphemeBreakTables.shift)
  static let shared = ScalarInfoTable()

  init() {
    let widths = UnicodeWidth.table
    let grapheme = GraphemeBreak.tables
    let blockSize = 1 << Self.shift
    let blockCount = 0x110000 >> Self.shift
    bmp = .allocate(capacity: 0x10000)
    stage1 = .allocate(capacity: blockCount)
    var blocks: [UInt8] = []
    var index: [[UInt8]: UInt16] = [:]
    var sourcePairs: [UInt64: UInt16] = [:]
    var block = [UInt8](repeating: 0, count: blockSize)
    for b in 0 ..< blockCount {
      let start = b << Self.shift
      // Each slice fits within one block of both source tables.
      // Equal source offsets therefore produce identical combined bytes.
      let widthOffset =
        Int(UnicodeTables.stage1[start >> 8]) << 8 | start & 0xFF
      let propertyOffset =
        Int(GraphemeBreakTables.stage1[start >> GraphemeBreakTables.shift])
        << GraphemeBreakTables.shift | start
        & ((1 << GraphemeBreakTables.shift) - 1)
      let key = UInt64(widthOffset) << 32 | UInt64(propertyOffset)
      let combined: UInt16
      if let cached = sourcePairs[key] {
        combined = cached
      } else {
        for k in 0 ..< blockSize {
          let cp = UInt32(start | k)
          block[k] = grapheme.props(cp) & 0x1F | widths.lookup(cp) << 5
        }
        if let existing = index[block] {
          combined = existing
        } else {
          combined = UInt16(index.count)
          index[block] = combined
          blocks.append(contentsOf: block)
        }
        sourcePairs[key] = combined
      }
      stage1[b] = combined
      if start < 0x10000 {
        let destination = bmp.advanced(by: start)
        let offset = Int(combined) << Self.shift
        blocks.withUnsafeBufferPointer { source in
          destination.initialize(
            from: source.baseAddress! + offset,
            count: blockSize
          )
        }
      }
    }
    stage2 = .allocate(capacity: blocks.count)
    stage2.initialize(from: blocks, count: blocks.count)
  }

  /// `(width, break class)` packed as described above; scalars past
  /// U+10FFFF are width 1, class Other.
  @inline(__always)
  func lookup(_ cp: UInt32) -> UInt8 {
    if cp < 0x10000 { return bmp[Int(cp)] }
    guard cp < 0x110000 else { return 1 << 5 }
    return stage2[
      Int(stage1[Int(cp >> Self.shift)]) << Self.shift
        | Int(cp & UInt32((1 << Self.shift) - 1))
    ]
  }
}
