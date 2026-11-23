import Foundation
@testable import ScreenProtocol
import SessionCore
import Testing
import TestSupport

func sampleSnapshot(
  columns: Int = 8,
  rows: Int = 3,
  revision: UInt64 = 1,
  epoch: UInt64 = 1,
  session: SessionID = SessionID(bytes: Array(repeating: 7, count: 16))!
) -> ScreenSnapshot {
  var s = ScreenSnapshot.blank(sessionID: session, columns: columns, rows: rows)
  s.screenRevision = revision
  s.attachmentEpoch = epoch
  s.styles = [
    .plain, CellStyle(foreground: RGBColor(0xFF0000), attributes: [.bold]),
  ]
  s.cells[0][0] = ScreenCell("e\u{301}", width: 1, style: 1)
  s.cells[0][1] = ScreenCell("界", width: 2, style: 0)
  s.cells[0][2] = .continuation
  s.cells[1][0] = ScreenCell("👩‍👩‍👧", width: 2, style: 1)
  s.cells[1][1] = ScreenCell("", width: 0, style: 1)
  s.wrapped[0] = true
  s.title = "title"
  return s
}

struct FramingTests {
  @Test
  func directControlDecoderRejectsOversizedValidJSON() throws {
    let record = try ControlRecord.encode(.ping(epoch: 1, nonce: 1))
    var body = Array(record.dropFirst(4))
    body.append(
      contentsOf: repeatElement(
        0x20,
        count: RSTLimits.maxControlRecordBytes + 1 - body.count
      )
    )
    #expect(throws: FramingError.recordTooLarge(body.count)) {
      try ControlRecord.decodeBody(body)
    }
    #expect(
      try ControlRecord.decodeBody(record.dropFirst(4))
        == .ping(epoch: 1, nonce: 1)
    )
  }

  @Test
  func directControlDecoderRejectsOversizeBeforeReadingElements() {
    let count = RSTLimits.maxControlRecordBytes + 1
    let input = ReadCountingBytes(prefix: [], count: count)
    #expect(throws: FramingError.recordTooLarge(count)) {
      try ControlRecord.decodeBody(input)
    }
    #expect(input.elementReads == 0)
  }

  @Test(arguments: 0 ..< 4)
  func controlReaderRejectsLengthBeforeReadingBody(_ prefixBytes: Int) throws {
    let header: [UInt8] = [0, 16, 0, 0]
    let input = ReadCountingBytes(
      prefix: Array(header.dropFirst(prefixBytes)),
      count: 1024 * 1024
    )
    var reader = ControlRecordReader()
    #expect(try reader.append(header.prefix(prefixBytes)).isEmpty)
    #expect(throws: FramingError.recordTooLarge(1024 * 1024)) {
      try reader.append(input)
    }
    #expect(input.elementReads == 4 - prefixBytes)
    #expect(reader.bufferedBytes == 4)
  }

  @Test
  func controlReaderSupportsCoalescedRecordsBeyondOneRecordLimit() throws {
    let messages: [ControlMessage] = [
      .ping(epoch: 1, nonce: 1), .pong(epoch: 1, nonce: 2),
    ]
    let first = try ControlRecord.encode(messages[0])
    let second = try ControlRecord.encode(messages[1])
    let limit = max(first.count, second.count) - 4
    var reader = ControlRecordReader(limit: limit)
    let batch = first + second + Array(first.prefix(3))
    #expect(batch.count > limit)
    #expect(try reader.append(batch) == messages)
    #expect(reader.bufferedBytes == 3)
    #expect(try reader.append([UInt8]()).isEmpty)
    #expect(reader.bufferedBytes == 3)
    #expect(try reader.append(first.dropFirst(3)) == [messages[0]])
    #expect(reader.bufferedBytes == 0)
  }

  @Test
  func snapshotReaderRejectsExcessBeforeReadingBody() {
    let input = ReadCountingBytes(
      prefix: [SnapshotFrame.Encoding.smxb.rawValue, 0, 0, 0, 1, 0, 0, 0, 1],
      count: 1024 * 1024
    )
    var reader = SnapshotStreamReader()
    #expect(throws: FramingError.trailingData) { try reader.append(input) }
    #expect(input.elementReads == SnapshotFrame.headerLength)
    #expect(reader.bufferedBytes == SnapshotFrame.headerLength)
  }

  @Test
  func `zlib round trip and RFC 1950 header`() throws {
    let input = Array(String(repeating: "hello terminal ", count: 1000).utf8)
    let compressed = Zlib.compress(input)
    #expect(compressed[0] == 0x78)
    #expect((UInt16(compressed[0]) << 8 | UInt16(compressed[1])) % 31 == 0)
    #expect(compressed.count < input.count / 4)
    #expect(try Zlib.decompress(compressed, limit: input.count) == input)
    #expect(Zlib.adler32(Array("Wikipedia".utf8)) == 0x11E6_0398)
  }

  @Test
  func `zlib enforces output limit, checksum and header`() {
    let input = [UInt8](repeating: 0, count: 100_000)
    let compressed = Zlib.compress(input)
    #expect(throws: Zlib.Error.outputLimit) {
      try Zlib.decompress(compressed, limit: 99_999)
    }
    var corrupt = compressed
    corrupt[corrupt.count - 1] ^= 1
    #expect(throws: Zlib.Error.checksum) {
      try Zlib.decompress(corrupt, limit: 200_000)
    }
    var header = compressed
    header[1] ^= 1
    #expect(throws: Zlib.Error.header) {
      try Zlib.decompress(header, limit: 200_000)
    }
    #expect(throws: Zlib.Error.truncated) {
      try Zlib.decompress(Array(compressed.prefix(3)), limit: 200_000)
    }
  }

  @Test
  func `zlib rejects unused bytes before the checksum`() throws {
    let input = Array("terminal output".utf8)
    let compressed = Zlib.compress(input)
    for extra in [[UInt8(0)], Array(compressed.dropFirst(2).dropLast(4))] {
      var malformed = Array(compressed.dropLast(4))
      malformed.append(contentsOf: extra)
      malformed.append(contentsOf: compressed.suffix(4))
      #expect(throws: Zlib.Error.corrupt) {
        try Zlib.decompress(malformed, limit: input.count)
      }
    }
  }

  @Test(arguments: [0, 1, 65_536, 65_537])
  func `zlib decoding handles empty input and output chunk boundaries`(
    count: Int
  ) throws {
    let input = [UInt8](repeating: 0x78, count: count)
    let compressed = Zlib.compress(input)
    #expect(try Zlib.decompress(compressed, limit: count) == input)
    #expect(throws: Zlib.Error.outputLimit) {
      try Zlib.decompress(compressed, limit: count - 1)
    }
    // Keep the checksum but cut the DEFLATE body short.
    let truncated = Array(compressed.dropLast(5)) + compressed.suffix(4)
    #expect(throws: Zlib.Error.truncated) {
      try Zlib.decompress(truncated, limit: count)
    }
  }

  @Test(arguments: [SnapshotFrame.Encoding.smxb, .smxbZlib])
  func `screen record round trip`(encoding: SnapshotFrame.Encoding) throws {
    let payload = frameRecord(encoding: encoding)
    #expect(payload[0] == encoding.rawValue)
    guard
      case let .frame(decoded, header) = try SnapshotFrame.decodeRecord(payload)
    else {
      Issue.record("not a frame")
      return
    }
    #expect(decoded == FrameWireTests.frame())
    #expect(header == FrameWireTests.header)

    var reader = SnapshotStreamReader()
    for chunk in stride(from: 0, to: payload.count, by: 7) {
      try reader.append(payload[chunk ..< min(chunk + 7, payload.count)])
    }
    guard case let .frame(streamed, _) = try reader.finishRecord() else {
      Issue.record("not a frame")
      return
    }
    #expect(streamed == decoded)
  }

  @Test
  func `screen records reject bad headers and bodies`() throws {
    let payload = frameRecord()
    for bad: UInt8 in [0, 1, 9] {
      var badEncoding = payload
      badEncoding[0] = bad
      #expect(throws: FramingError.unsupportedEncoding(bad)) {
        try SnapshotFrame.decodeRecord(badEncoding)
      }
    }
    var huge = payload
    huge[1] = 0xFF
    #expect(throws: FramingError.snapshotTooLarge) {
      try SnapshotFrame.decodeRecord(huge)
    }
    #expect(throws: FramingError.trailingData) {
      try SnapshotFrame.decodeRecord(payload + [0])
    }
    #expect(throws: FramingError.truncated) {
      try SnapshotFrame.decodeRecord(Array(payload.dropLast()))
    }
    var reader = SnapshotStreamReader()
    try reader.append(payload)
    #expect(throws: FramingError.trailingData) { try reader.append([1]) }
  }

  @Test
  func `control records round trip incrementally`() throws {
    let token = ApplicationToken.random()
    let messages: [ControlMessage] = [
      .attach(
        .init(
          sessionID: .random(),
          serverInstanceID: .random(),
          writerID: .random(),
          applicationToken: token
        )
      ),
      .attached(
        .init(
          attachmentEpoch: 3,
          writerID: .random(),
          lastFullyAppliedInputSequence: UInt64.max,
          partialInputSequence: 4,
          resizeRevision: 2
        )
      ),
      .input(.init(attachmentEpoch: 3, sequence: 5, operation: .paste("x\ny"))),
      .input(
        .init(
          attachmentEpoch: 3,
          sequence: 6,
          operation: .key(SemanticKey(.character("c"), modifiers: [.control]))
        )
      ),
      .input(
        .init(
          attachmentEpoch: 3,
          sequence: 7,
          operation: .resize(columns: 100, rows: 30, resizeRevision: 9)
        )
      ), .inputAck(epoch: 3, sequence: 5),
      .screenAck(epoch: 3, screenRevision: 77), .ping(epoch: 3, nonce: 1),
      .pong(epoch: 3, nonce: 1), .detach(epoch: 3), .detached(epoch: 3),
      .terminate(epoch: 3), .terminated(epoch: 3),
      .sessionExited(epoch: 3, status: 0, finalScreenRevision: 80),
      .error(.init(.inputGap, sequence: 9, message: "gap")),
    ]
    var bytes: [UInt8] = []
    for m in messages { bytes += try ControlRecord.encode(m) }
    var reader = ControlRecordReader()
    var decoded: [ControlMessage] = []
    for b in bytes { decoded += try reader.append([b]) }
    #expect(decoded == messages)
    #expect(reader.bufferedBytes == 0)
    // 64-bit counters are decimal strings; tokens never print.
    let json = String(
      decoding: try ControlRecord.encode(messages[1]).dropFirst(4),
      as: UTF8.self
    )
    #expect(json.contains("\"18446744073709551615\""))
    #expect(!"\(messages[0])".contains(Data(token.bytes).base64EncodedString()))
  }

  @Test
  func `control reader rejects oversized, unknown and malformed records`()
    throws
  {
    var reader = ControlRecordReader()
    #expect(throws: FramingError.recordTooLarge(0x10_0000)) {
      try reader.append([0x00, 0x10, 0x00, 0x00])
    }
    for body in [
      #"{"type":"Bogus"}"#,
      #"{"type":"InputAck","attachmentEpoch":"01","sequence":"1"}"#,
      #"{"type":"InputAck","attachmentEpoch":1,"sequence":"1"}"#, "not json",
      #"{"type":"Input","attachmentEpoch":"1","sequence":"1","operation":{"op":"exec"}}"#,
    ] {
      var r = ControlRecordReader()
      var bytes: [UInt8] = []
      appendUInt32(UInt32(body.utf8.count), to: &bytes)
      bytes += Array(body.utf8)
      #expect(throws: FramingError.malformedJSON) { try r.append(bytes) }
    }
    // Unknown optional fields are ignored.
    let body =
      #"{"type":"Ping","attachmentEpoch":"1","nonce":"2","extra":true}"#
    var bytes: [UInt8] = []
    appendUInt32(UInt32(body.utf8.count), to: &bytes)
    bytes += Array(body.utf8)
    var fresh = ControlRecordReader()
    #expect(try fresh.append(bytes) == [.ping(epoch: 1, nonce: 2)])
  }

  @Test
  func `bootstrap envelope round trip and bounds`() throws {
    let request = BootstrapRequest(
      operation: .create,
      initialGrid: GridSize(columns: 80, rows: 24)
    )
    try request.validate()
    let bytes = try BootstrapEnvelope.encode(request)
    #expect(
      try BootstrapEnvelope.decode(BootstrapRequest.self, from: bytes)
        == request
    )
    #expect(throws: FramingError.trailingData) {
      try BootstrapEnvelope.decode(BootstrapRequest.self, from: bytes + [0])
    }
    #expect(throws: BootstrapRequest.ValidationError.unsupportedProtocol) {
      try BootstrapRequest(operation: .list, protocols: ["RST/2"]).validate()
    }
    #expect(throws: BootstrapRequest.ValidationError.invalidGrid) {
      try BootstrapRequest(
        operation: .create,
        initialGrid: GridSize(columns: 201, rows: 24)
      )
      .validate()
    }
    let grant = BootstrapGrant(
      serverInstanceID: .random(),
      sessionID: .random(),
      writerID: .random(),
      endpoint: BootstrapEndpoint(host: "mac.local", port: 51222),
      serverCertificateDER: Data([1, 2, 3]),
      serverCertificateSHA256: String(repeating: "a", count: 64),
      applicationToken: .random(),
      tokenExpiresAt: 1_000,
      initialGrid: GridSize(columns: 80, rows: 24)
    )
    var pinned = grant
    pinned.serverSPKISHA256 = String(repeating: "b", count: 64)
    for response in [
      BootstrapResponse.granted(grant), .granted(pinned), .sessions([]),
      .failure(.writerBusy), .terminated(grant.sessionID),
    ] {
      let data = try BootstrapEnvelope.encode(response)
      #expect(
        try BootstrapEnvelope.decode(BootstrapResponse.self, from: data)
          == response
      )
    }
    #expect(
      !grant.description.contains(
        Data(grant.applicationToken.bytes).base64EncodedString()
      )
    )
    // The SPKI pin is optional on the wire: a grant from an older host
    // omits the key and decodes with no pin.
    let legacy = try BootstrapEnvelope.encode(BootstrapResponse.granted(grant))
    #expect(
      !String(decoding: legacy.dropFirst(4), as: UTF8.self)
        .contains("serverSPKISHA256")
    )
    let modern = try BootstrapEnvelope.encode(BootstrapResponse.granted(pinned))
    #expect(
      String(decoding: modern.dropFirst(4), as: UTF8.self)
        .contains("serverSPKISHA256")
    )
  }
}
