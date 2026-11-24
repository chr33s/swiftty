import Foundation
import SessionCore

public enum FramingError: Error, Equatable, Sendable {
  case recordTooLarge(Int)
  case malformedJSON
  case unsupportedEncoding(UInt8)
  case lengthMismatch
  case snapshotTooLarge
  case decompression(Zlib.Error)
  case invalidSnapshot(SnapshotValidationError)
  case trailingData
  case truncated
  /// An `SMXB/1` screen that fails decoding or the RST/1 frame limits.
  case invalidFrame(String)
}

func makeEncoder() -> JSONEncoder {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.withoutEscapingSlashes]
  return encoder
}

/// Control records: `UInt32BE(length)` + UTF-8 JSON object (spec §7.2).
public enum ControlRecord {
  public static func encode(
    _ message: ControlMessage,
    limit: Int = RSTLimits.maxControlRecordBytes
  ) throws -> [UInt8] {
    let json = try makeEncoder().encode(message)
    guard json.count <= min(limit, RSTLimits.maxControlRecordBytes) else {
      throw FramingError.recordTooLarge(json.count)
    }
    var out = [UInt8]()
    out.reserveCapacity(json.count + 4)
    appendUInt32(UInt32(json.count), to: &out)
    out.append(contentsOf: json)
    return out
  }

  public static func decodeBody(
    _ body: some Collection<UInt8>
  ) throws(FramingError) -> ControlMessage {
    try decodeBody(body, limit: RSTLimits.maxControlRecordBytes)
  }

  fileprivate static func decodeBody(
    _ body: some Collection<UInt8>,
    limit: Int
  ) throws(FramingError) -> ControlMessage {
    let count = body.count
    guard count <= limit else { throw .recordTooLarge(count) }
    do {
      return try JSONDecoder().decode(ControlMessage.self, from: Data(body))
    } catch { throw .malformedJSON }
  }
}

/// Incremental control-stream reader. Rejects a length prefix over the
/// limit before buffering the body.
public struct ControlRecordReader: Sendable {
  private var buffer: [UInt8] = []
  public let limit: Int

  public init(limit: Int = RSTLimits.maxControlRecordBytes) {
    self.limit = limit
  }

  public var bufferedBytes: Int { buffer.count }

  /// Appends received bytes and returns every complete message.
  public mutating func append(
    _ bytes: some Collection<UInt8>
  ) throws(FramingError) -> [ControlMessage] {
    var messages: [ControlMessage] = []
    var index = bytes.startIndex
    while !buffer.isEmpty || index != bytes.endIndex {
      if buffer.count < 4 {
        let next =
          bytes.index(
            index,
            offsetBy: 4 - buffer.count,
            limitedBy: bytes.endIndex
          ) ?? bytes.endIndex
        buffer.append(contentsOf: bytes[index ..< next])
        index = next
        guard buffer.count == 4 else { break }
      }
      let length = Int(readUInt32(buffer, at: 0))
      guard length <= limit else { throw .recordTooLarge(length) }
      let missing = length - (buffer.count - 4)
      let next =
        bytes.index(index, offsetBy: missing, limitedBy: bytes.endIndex)
        ?? bytes.endIndex
      buffer.append(contentsOf: bytes[index ..< next])
      index = next
      guard buffer.count - 4 == length else { break }
      messages.append(
        try ControlRecord.decodeBody(buffer.dropFirst(4), limit: limit)
      )
      buffer.removeAll(keepingCapacity: true)
    }
    return messages
  }
}

/// Screen stream payload: one record then FIN (spec §7.2).
///
///     UInt8     encoding: 2 = `SMXB/1`, 3 = `SMXB/1` in RFC 1950 zlib
///     UInt32BE  decodedLength
///     UInt32BE  encodedLength
///     Byte[]    encoded frame record with an `rstHeader` envelope
///
/// Encodings 0 and 1 (legacy JSON `ScreenSnapshot`) are no longer sent or
/// accepted.
public enum SnapshotFrame {
  public enum Encoding: UInt8, Sendable {
    /// `SMXB/1` with an `rstHeader` envelope.
    case smxb = 2
    case smxbZlib = 3
    /// A kitty graphics `KGIB/1` image (`ImageBlob`, spec.graphics.md §16.3).
    case imageBlob = 4

    var isCompressed: Bool { self == .smxbZlib }
  }
  public static let headerLength = 9

  /// Parsed header; lets a reader bound buffering before the body arrives.
  public struct Header: Equatable, Sendable {
    public var encoding: Encoding
    public var decodedLength: Int
    public var encodedLength: Int
  }

  public static func header(
    _ bytes: some Collection<UInt8>,
    limits: NegotiatedLimits = NegotiatedLimits()
  ) throws(FramingError) -> Header? {
    guard bytes.count >= headerLength else { return nil }
    let b = Array(bytes.prefix(headerLength))
    guard let encoding = Encoding(rawValue: b[0]) else {
      throw .unsupportedEncoding(b[0])
    }
    let decoded = Int(readUInt32(b, at: 1))
    let encoded = Int(readUInt32(b, at: 5))
    let limits = limits.effective
    guard decoded <= limits.maxSnapshotDecodedBytes,
      encoded <= limits.maxSnapshotEncodedBytes
    else { throw .snapshotTooLarge }
    if !encoding.isCompressed, decoded != encoded { throw .lengthMismatch }
    return Header(
      encoding: encoding,
      decodedLength: decoded,
      encodedLength: encoded
    )
  }
}

/// Accumulates one snapshot stream, enforcing the header's bounds while
/// bytes arrive.
public struct SnapshotStreamReader: Sendable {
  public var bufferedBytes: Int { buffer.count }
  private var buffer: [UInt8] = []
  private var header: SnapshotFrame.Header?

  public init() {}

  public mutating func append(
    _ bytes: some Collection<UInt8>
  ) throws(FramingError) {
    let incoming = bytes.count
    var consumed = 0
    if header == nil {
      consumed = min(incoming, SnapshotFrame.headerLength - buffer.count)
      buffer.append(contentsOf: bytes.prefix(consumed))
      header = try SnapshotFrame.header(buffer)
      guard header != nil else { return }
    }
    guard let header else { return }
    let cap = SnapshotFrame.headerLength + header.encodedLength
    guard incoming - consumed <= cap - buffer.count else { throw .trailingData }
    buffer.append(contentsOf: bytes.dropFirst(consumed))
  }

  /// Call at FIN.
  public func finishRecord() throws(FramingError) -> ScreenRecord {
    try SnapshotFrame.decodeRecord(buffer)
  }
}

@inline(__always)
func appendUInt32(_ value: UInt32, to out: inout [UInt8]) {
  out.append(UInt8(value >> 24))
  out.append(UInt8(value >> 16 & 0xFF))
  out.append(UInt8(value >> 8 & 0xFF))
  out.append(UInt8(value & 0xFF))
}

@inline(__always)
func readUInt32(_ bytes: [UInt8], at i: Int) -> UInt32 {
  UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16 | UInt32(bytes[i + 2])
    << 8 | UInt32(bytes[i + 3])
}
