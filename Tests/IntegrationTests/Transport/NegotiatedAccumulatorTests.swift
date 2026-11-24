import AppleTransport
import ScreenProtocol
import TestSupport
import Testing

struct NegotiatedAccumulatorTests {
  @Test(arguments: [0, 4, 8], [false, true])
  func headerExceedingEitherCapNeverReadsBody(
    _ split: Int,
    _ decoded: Bool
  ) throws {
    var limits = NegotiatedLimits()
    limits.maxSnapshotEncodedBytes = decoded ? 128 : 32
    limits.maxSnapshotDecodedBytes = decoded ? 32 : 128
    let header: [UInt8] = [3, 0, 0, 0, 64, 0, 0, 0, 64]
    var accumulator = SnapshotStreamAccumulator(limits: limits)
    try accumulator.append(header.prefix(split))
    let input = ReadCountingBytes(
      prefix: Array(header.dropFirst(split)),
      count: header.count - split + 1
    )
    #expect(throws: FramingError.snapshotTooLarge) {
      try accumulator.append(input)
    }
    #expect(input.elementReads == header.count - split)
    #expect(accumulator.bytes.count == header.count)
    #expect(accumulator.expectedLength == nil)
  }

  @Test
  func exactNegotiatedBoundaryAndReadCreditStayBounded() throws {
    var limits = NegotiatedLimits()
    limits.maxSnapshotEncodedBytes = 32
    limits.maxSnapshotDecodedBytes = 32
    let payload: [UInt8] =
      [2, 0, 0, 0, 32, 0, 0, 0, 32] + Array(repeating: 7, count: 32)
    var accumulator = SnapshotStreamAccumulator(limits: limits)
    #expect(accumulator.nextReadLimit == payload.count + 1)
    try accumulator.append(payload.prefix(4))
    #expect(accumulator.nextReadLimit == payload.count - 4 + 1)
    try accumulator.append(payload.dropFirst(4))
    #expect(try accumulator.finish() == payload)
    #expect(accumulator.nextReadLimit == 1)
    let input = ReadCountingBytes(prefix: [], count: Int.max)
    #expect(throws: FramingError.snapshotTooLarge) {
      try accumulator.append(input)
    }
    #expect(input.elementReads == 0)
    #expect(accumulator.bytes == payload)
  }
}
