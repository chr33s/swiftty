import CScrollbackChecksum

/// CRC-32C (Castagnoli): hardware instructions where available, else
/// slicing-by-8. An accidental-corruption check, not authentication.
public enum CRC32C {
  private static let tables: [UInt32] = {
    var t = [UInt32](repeating: 0, count: 8 * 256)
    for i in 0 ..< 256 {
      var c = UInt32(i)
      for _ in 0 ..< 8 { c = c & 1 != 0 ? 0x82F6_3B78 ^ (c >> 1) : c >> 1 }
      t[i] = c
    }
    for i in 0 ..< 256 {
      var c = t[i]
      for k in 1 ..< 8 {
        c = t[Int(c & 0xFF)] ^ (c >> 8)
        t[k * 256 + i] = c
      }
    }
    return t
  }()

  public static let accelerated = swiftty_crc32c_accelerated() != 0

  public static func checksum(_ data: UnsafeRawPointer, _ count: Int) -> UInt32
  {
    if accelerated { return ~swiftty_crc32c_update(0xFFFF_FFFF, data, count) }
    return software(data, count)
  }

  /// Portable slicing-by-8, used where the CPU lacks CRC32C instructions.
  public static func software(_ data: UnsafeRawPointer, _ count: Int) -> UInt32
  {
    tables.withUnsafeBufferPointer { t in
      let t = t.baseAddress!
      var crc: UInt32 = 0xFFFF_FFFF
      var p = data
      var n = count
      while n >= 8 {
        let word = p.loadUnaligned(as: UInt64.self).littleEndian
        let lo = UInt32(truncatingIfNeeded: word) ^ crc
        let hi = UInt32(truncatingIfNeeded: word >> 32)
        crc =
          t[7 &* 256 &+ Int(lo & 0xFF)] ^ t[6 &* 256 &+ Int(lo >> 8 & 0xFF)]
          ^ t[5 &* 256 &+ Int(lo >> 16 & 0xFF)] ^ t[4 &* 256 &+ Int(lo >> 24)]
          ^ t[3 &* 256 &+ Int(hi & 0xFF)] ^ t[2 &* 256 &+ Int(hi >> 8 & 0xFF)]
          ^ t[256 &+ Int(hi >> 16 & 0xFF)] ^ t[Int(hi >> 24)]
        p += 8
        n &-= 8
      }
      while n > 0 {
        crc = t[Int((crc ^ UInt32(p.load(as: UInt8.self))) & 0xFF)] ^ (crc >> 8)
        p += 1
        n &-= 1
      }
      return ~crc
    }
  }
}

extension CRC32C {
  /// Checksum of `bytes`.
  public static func checksum(_ bytes: [UInt8]) -> UInt32 {
    bytes.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return 0 }
      return checksum(base, raw.count)
    }
  }
}
