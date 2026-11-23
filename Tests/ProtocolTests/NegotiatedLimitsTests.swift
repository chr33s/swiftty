import ScreenProtocol
import SessionCore
import Testing

struct NegotiatedLimitsTests {
  @Test(arguments: [
    SemanticKey(.function(0)), SemanticKey(.function(13)),
    SemanticKey(.function(.min)), SemanticKey(.function(.max)),
    SemanticKey(.enter, modifiers: .init(rawValue: 8)),
    SemanticKey(.enter, modifiers: .init(rawValue: 255)),
  ])
  func unsupportedKeysCannotConsumeASequence(_ key: SemanticKey) throws {
    let operation = InputOperation.key(key)
    #expect(throws: InputOperation.ValidationError.invalidKey) {
      try operation.validate()
    }
    #expect(!NegotiatedLimits().permits(operation))
    var queue = ClientInputQueue(writerID: .random())
    #expect(throws: ClientInputQueue.EnqueueError.invalid(.invalidKey)) {
      try queue.enqueue(operation)
    }
    #expect(queue.entries.isEmpty)
    #expect(queue.pendingBytes == 0)
    let supported = SemanticKey(
      .function(12),
      modifiers: [.shift, .alt, .control]
    )
    #expect(try queue.enqueue(.key(supported)).sequence == 1)
  }

  @Test
  func perOperationChecksBoundHostExpansionAndResize() {
    var limits = NegotiatedLimits()
    limits.maxColumns = 20
    limits.maxRows = 4
    limits.maxPendingInputBytes = 32
    limits.maxPasteBytes = 32
    #expect(limits.permits(.paste("1234567890")))
    #expect(!limits.permits(.paste("12345678901")))
    #expect(limits.permits(.committedText(String(repeating: "x", count: 32))))
    #expect(!limits.permits(.key(.init(.enter))))
    #expect(limits.permits(.resize(columns: 20, rows: 4, resizeRevision: 1)))
    #expect(!limits.permits(.resize(columns: 21, rows: 4, resizeRevision: 1)))
  }
  @Test(arguments: 0 ..< 7)
  func invalidBoundsAreRejected(_ index: Int) {
    let fields: [WritableKeyPath<NegotiatedLimits, Int>] = [
      \.maxColumns, \.maxRows, \.maxControlRecordBytes,
      \.maxSnapshotEncodedBytes, \.maxSnapshotDecodedBytes,
      \.maxPendingInputBytes, \.maxPasteBytes,
    ]
    var limits = NegotiatedLimits()
    limits[keyPath: fields[index]] = .min
    #expect(!limits.isValid)
    limits[keyPath: fields[index]] = 0
    #expect(limits.isValid == (index >= 5))
    limits[keyPath: fields[index]] = .max
    #expect(limits.isValid)
    #expect(limits.effective == NegotiatedLimits())
  }

  @Test
  func queueBudgetReductionPreservesAcceptedSequences() throws {
    var queue = ClientInputQueue(writerID: .random(), byteLimit: 64)
    _ = try queue.enqueue(.committedText(String(repeating: "x", count: 16)))
    _ = try queue.enqueue(.committedText(String(repeating: "y", count: 16)))
    let accepted = queue.entries
    queue.updateByteLimit(32)
    #expect(queue.entries == accepted)
    #expect(queue.pendingBytes == 64)
    #expect(throws: ClientInputQueue.EnqueueError.full) {
      try queue.enqueue(.committedText("z"))
    }
    queue.acknowledge(through: 1)
    #expect(throws: ClientInputQueue.EnqueueError.full) {
      try queue.enqueue(.committedText("z"))
    }
    queue.acknowledge(through: 2)
    #expect(try queue.enqueue(.committedText("z")).sequence == 3)
  }

  @Test
  func controlEncoderHonorsExactNegotiatedByteBoundary() throws {
    let message = ControlMessage.input(
      .init(
        attachmentEpoch: .max,
        sequence: .max,
        operation: .key(.init(.enter))
      )
    )
    let record = try ControlRecord.encode(message)
    let bounded = try ControlRecord.encode(message, limit: record.count - 4)
    #expect(bounded.count == record.count)
    #expect(try ControlRecord.decodeBody(bounded.dropFirst(4)) == message)
    #expect(throws: FramingError.recordTooLarge(record.count - 4)) {
      try ControlRecord.encode(message, limit: record.count - 5)
    }
  }

  @Test
  func snapshotBoundsPrecedeDecompressionAndRendering() throws {
    let frame = FrameWireTests.frame()
    let payload = frameRecord(frame, encoding: .smxbZlib)
    let header = try #require(try SnapshotFrame.header(payload))
    var limits = NegotiatedLimits()
    limits.maxColumns = frame.grid.columns
    limits.maxRows = frame.grid.rows
    limits.maxSnapshotEncodedBytes = header.encodedLength
    limits.maxSnapshotDecodedBytes = header.decodedLength
    guard
      case let .frame(decoded, _) = try SnapshotFrame.decodeRecord(
        payload,
        limits: limits
      )
    else {
      Issue.record("not a frame")
      return
    }
    #expect(decoded == frame)
    // The corrupt zlib body must not be inspected when the header alone
    // exceeds either negotiated byte cap.
    var corrupted = payload
    corrupted[SnapshotFrame.headerLength] = 0
    var encoded = limits
    encoded.maxSnapshotEncodedBytes -= 1
    #expect(throws: FramingError.snapshotTooLarge) {
      try SnapshotFrame.decodeRecord(corrupted, limits: encoded)
    }
    var decodedLimit = limits
    decodedLimit.maxSnapshotDecodedBytes -= 1
    #expect(throws: FramingError.snapshotTooLarge) {
      try SnapshotFrame.decodeRecord(corrupted, limits: decodedLimit)
    }
    limits.maxColumns -= 1
    #expect(throws: FramingError.self) {
      try SnapshotFrame.decodeRecord(payload, limits: limits)
    }
  }
}
