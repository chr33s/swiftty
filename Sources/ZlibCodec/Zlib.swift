import Compression
import Foundation
import zlib

/// RFC 1950 framing with Compression for encoding and zlib for strict
/// decoding of raw DEFLATE. The header and Adler-32 trailer are handled
/// here.
public enum Zlib {
  public enum Error: Swift.Error, Equatable {
    case header
    case checksum
    case truncated
    case outputLimit
    case corrupt
  }

  public static func adler32(_ bytes: some Collection<UInt8>) -> UInt32 {
    var a: UInt32 = 1
    var b: UInt32 = 0
    var n = 0
    for byte in bytes {
      a += UInt32(byte)
      b += a
      n += 1
      if n == 5552 {
        a %= 65521
        b %= 65521
        n = 0
      }
    }
    return (b % 65521) << 16 | (a % 65521)
  }

  /// Compresses `input` into a complete RFC 1950 stream.
  public static func compress(_ input: [UInt8]) -> [UInt8] {
    // CMF 0x78: deflate, 32 KiB window. FLG 0x9C: default level, check bits.
    var out: [UInt8] = [0x78, 0x9C]
    guard
      case let .ok(body) = run(COMPRESSION_STREAM_ENCODE, input, limit: .max)
    else { preconditionFailure("deflate failed") }
    out.append(contentsOf: body)
    let checksum = adler32(input)
    out.append(contentsOf: [
      UInt8(checksum >> 24), UInt8(checksum >> 16 & 0xFF),
      UInt8(checksum >> 8 & 0xFF), UInt8(checksum & 0xFF),
    ])
    return out
  }

  /// Decompresses an RFC 1950 stream, failing as soon as output would
  /// exceed `limit` bytes.
  public static func decompress(
    _ input: [UInt8],
    limit: Int
  ) throws(Error) -> [UInt8] {
    guard input.count >= 6 else { throw .truncated }
    let cmf = input[0]
    let flg = input[1]
    // Reject preset dictionaries.
    guard cmf & 0x0F == 8, cmf >> 4 <= 7,
      (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0, flg & 0x20 == 0
    else { throw .header }
    let body = Array(input[2 ..< input.count - 4])
    let output: [UInt8]
    switch inflateBody(body, limit: limit) {
    case let .ok(bytes): output = bytes
    case .limit: throw .outputLimit
    case .truncated: throw .truncated
    case .failed: throw .corrupt
    }
    let t = input.suffix(4).map(UInt32.init)
    let expected =
      t[t.startIndex] << 24 | t[t.startIndex + 1] << 16 | t[t.startIndex + 2]
      << 8 | t[t.startIndex + 3]
    guard adler32(output) == expected else { throw .checksum }
    return output
  }

  private enum Outcome {
    case ok([UInt8])
    case limit
    case truncated
    case failed
  }

  /// Use zlib for decoding: Compression may consume bytes past the end
  /// of a DEFLATE stream, hiding trailing data from its caller.
  private static func inflateBody(_ input: [UInt8], limit: Int) -> Outcome {
    guard input.count <= UInt32.max else { return .failed }
    var stream = z_stream()
    guard
      inflateInit2_(
        &stream,
        -MAX_WBITS,
        ZLIB_VERSION,
        Int32(MemoryLayout<z_stream>.size)
      ) == Z_OK
    else { return .failed }
    defer { inflateEnd(&stream) }
    let chunk = 64 * 1024
    var output: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: chunk)
    return input.withUnsafeBufferPointer { src in
      stream.next_in = UnsafeMutablePointer(mutating: src.baseAddress)
      stream.avail_in = UInt32(src.count)
      while true {
        let status = buffer.withUnsafeMutableBufferPointer { dst in
          stream.next_out = dst.baseAddress!
          stream.avail_out = UInt32(chunk)
          return inflate(&stream, Z_NO_FLUSH)
        }
        let produced = chunk - Int(stream.avail_out)
        guard produced <= limit - output.count else { return .limit }
        output.append(contentsOf: buffer.prefix(produced))
        switch status {
        case Z_STREAM_END: return stream.avail_in == 0 ? .ok(output) : .failed
        case Z_OK: if stream.avail_in == 0, produced == 0 { return .truncated }
        case Z_BUF_ERROR: return .truncated
        default: return .failed
        }
      }
    }
  }

  /// Streams through `compression_stream`, stopping as soon as the output
  /// would exceed `limit`.
  private static func run(
    _ operation: compression_stream_operation,
    _ input: [UInt8],
    limit: Int
  ) -> Outcome {
    var stream = compression_stream(
      dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
      dst_size: 0,
      src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
      src_size: 0,
      state: nil
    )
    guard
      compression_stream_init(&stream, operation, COMPRESSION_ZLIB)
        == COMPRESSION_STATUS_OK
    else { return .failed }
    defer { compression_stream_destroy(&stream) }
    let chunk = 64 * 1024
    var output: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: chunk)
    return input.withUnsafeBufferPointer { src -> Outcome in
      stream.src_ptr = src.baseAddress ?? UnsafePointer(bitPattern: 1)!
      stream.src_size = src.count
      while true {
        let status = buffer.withUnsafeMutableBufferPointer { dst in
          stream.dst_ptr = dst.baseAddress!
          stream.dst_size = chunk
          return compression_stream_process(
            &stream,
            Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
          )
        }
        let produced = chunk - stream.dst_size
        if output.count + produced > limit { return .limit }
        output.append(contentsOf: buffer[0 ..< produced])
        switch status {
        case COMPRESSION_STATUS_OK:
          // Input consumed without reaching the end of the stream.
          if stream.src_size == 0, produced == 0 {
            return operation == COMPRESSION_STREAM_DECODE
              ? .truncated : .ok(output)
          }
        case COMPRESSION_STATUS_END: return .ok(output)
        default: return .failed
        }
      }
    }
  }
}
