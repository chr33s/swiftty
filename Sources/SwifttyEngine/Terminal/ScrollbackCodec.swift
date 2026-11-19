import Checksum
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
