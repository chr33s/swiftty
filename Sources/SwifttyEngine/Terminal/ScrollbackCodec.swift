import CScrollbackChecksum
import Compression

/// Process-local LZ4 encoding of cell bytes through Apple's buffer API.
/// The framed format has no persisted ABI and no external decoder.
enum ScrollbackCodec {
  static let algorithm = COMPRESSION_LZ4

  /// Whether `Cell` is a dense, bitwise-copyable 16-byte value with no
  /// padding, so its raw bytes are fully defined and safe to encode.
  static let cellLayoutIsDense: Bool = {
    typealias Layout = MemoryLayout<Cell>
    let fields: [(Int?, Int)] = [
      (Layout.offset(of: \Cell.glyph), 4),
      (Layout.offset(of: \Cell.packed.foregroundBits), 4),
      (Layout.offset(of: \Cell.packed.backgroundBits), 4),
      (Layout.offset(of: \Cell.packed.flags), 2),
      (Layout.offset(of: \Cell.packed.tail), 2),
    ]
    var covered = [Bool](repeating: false, count: Layout.stride)
    for (offset, size) in fields {
      guard let offset, offset + size <= Layout.stride else { return false }
      for i in offset ..< offset + size {
        if covered[i] { return false }
        covered[i] = true
      }
    }
    return Layout.size == Layout.stride && Layout.stride == 16
      && !covered.contains(false)
  }()

  static var encodeScratchBytes: Int {
    compression_encode_scratch_buffer_size(algorithm)
  }

  static var decodeScratchBytes: Int {
    compression_decode_scratch_buffer_size(algorithm)
  }

  /// Encoded byte count, or 0 on failure or insufficient capacity.
  static func encode(
    _ source: UnsafeRawPointer,
    _ count: Int,
    into destination: UnsafeMutableRawPointer,
    capacity: Int,
    scratch: UnsafeMutableRawPointer?
  ) -> Int {
    compression_encode_buffer(
      destination.assumingMemoryBound(to: UInt8.self),
      capacity,
      source.assumingMemoryBound(to: UInt8.self),
      count,
      scratch,
      algorithm
    )
  }

  enum DecodeResult: Equatable {
    case ok
    case lengthMismatch(Int)
    case checksumMismatch
  }

  /// Decodes into exactly `count` bytes and verifies their CRC-32C. On
  /// failure the destination contents are unspecified and must not be
  /// exposed.
  static func decode(
    _ payload: UnsafeRawPointer,
    _ payloadCount: Int,
    into destination: UnsafeMutableRawPointer,
    count: Int,
    checksum: UInt32,
    scratch: UnsafeMutableRawPointer?
  ) -> DecodeResult {
    if count == 0 {
      return payloadCount == 0 && checksum == 0 ? .ok : .lengthMismatch(0)
    }
    // Longer output is truncated to `count`; the checksum rejects it.
    let produced = compression_decode_buffer(
      destination.assumingMemoryBound(to: UInt8.self),
      count,
      payload.assumingMemoryBound(to: UInt8.self),
      payloadCount,
      scratch,
      algorithm
    )
    guard produced == count else { return .lengthMismatch(produced) }
    guard CRC32C.checksum(UnsafeRawPointer(destination), count) == checksum
    else { return .checksumMismatch }
    return .ok
  }
}

/// CRC-32C (Castagnoli): hardware instructions where available, else
/// slicing-by-8. An accidental-corruption check, not authentication.
enum CRC32C {
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

  static let accelerated = swiftty_crc32c_accelerated() != 0

  static func checksum(_ data: UnsafeRawPointer, _ count: Int) -> UInt32 {
    if accelerated { return ~swiftty_crc32c_update(0xFFFF_FFFF, data, count) }
    return software(data, count)
  }

  /// Portable slicing-by-8, used where the CPU lacks CRC32C instructions.
  static func software(_ data: UnsafeRawPointer, _ count: Int) -> UInt32 {
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
