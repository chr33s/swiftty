/// Owns cluster keys only after a cache miss. Borrowed probes avoid copying
/// every grapheme when rebuilding rows whose glyphs are already cached.
struct GlyphClusterCache {
  struct Record {
    private let scalars: [UInt32]
    private let style: UInt8
    let value: GlyphAtlas.Entry

    init(scalars: borrowing Span<UInt32>, style: UInt8, value: GlyphAtlas.Entry)
    {
      self.scalars = scalars.withUnsafeBufferPointer { Array($0) }
      self.style = style
      self.value = value
    }

    var scalarCapacity: Int { scalars.capacity }

    @inline(__always)
    fileprivate func matches(
      _ other: borrowing Span<UInt32>,
      style: UInt8
    ) -> Bool {
      guard self.style == style, scalars.count == other.count else {
        return false
      }
      for i in 0 ..< scalars.count where scalars[i] != other[i] { return false }
      return true
    }
  }

  // Dictionary entries and collision-bucket storage, excluding scalar buffers.
  static let metadataOverhead = 192
  private var buckets: [Int: [Record]] = [:]

  @inline(__always)
  static func hash(_ scalars: borrowing Span<UInt32>, style: UInt8) -> Int {
    scalars.withUnsafeBufferPointer { buffer in
      var hasher = Hasher()
      hasher.combine(style)
      hasher.combine(buffer.count)
      hasher.combine(bytes: UnsafeRawBufferPointer(buffer))
      return hasher.finalize()
    }
  }

  @inline(__always)
  func entry(
    for scalars: borrowing Span<UInt32>,
    style: UInt8,
    hash: Int
  ) -> GlyphAtlas.Entry? {
    guard let bucket = buckets[hash] else { return nil }
    // A hash selects candidates; only the complete key identifies a glyph.
    for i in 0 ..< bucket.count {
      let record = bucket[i]
      if record.matches(scalars, style: style) { return record.value }
    }
    return nil
  }

  mutating func insert(_ record: Record, hash: Int) {
    buckets[hash, default: []].append(record)
  }

  mutating func removeAll(keepingCapacity: Bool) {
    buckets.removeAll(keepingCapacity: keepingCapacity)
  }
}
