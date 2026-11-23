@testable import ScreenProtocol
import SwiftMuxProtocol
import SessionCore
import Testing

/// Deterministic generator so failures reproduce.
struct SplitMix64: RandomNumberGenerator {
  var state: UInt64
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

/// A16: decoders and the input state machine under random and mutated
/// input never crash, over-allocate, or reach an invalid state.
struct FuzzTests {
  func mutate(_ bytes: [UInt8], _ rng: inout SplitMix64) -> [UInt8] {
    var out = bytes
    for _ in 0 ..< Int.random(in: 1 ... 6, using: &rng) {
      guard !out.isEmpty else { break }
      let i = Int.random(in: 0 ..< out.count, using: &rng)
      switch Int.random(in: 0 ..< 4, using: &rng) {
      case 0: out[i] = UInt8.random(in: 0 ... 255, using: &rng)
      case 1: out.remove(at: i)
      case 2: out.insert(UInt8.random(in: 0 ... 255, using: &rng), at: i)
      default: out[i] ^= 1 << UInt8.random(in: 0 ..< 8, using: &rng)
      }
    }
    return out
  }

  @Test
  func `control reader survives random and mutated records`() throws {
    var rng = SplitMix64(state: 1)
    let seeds: [[UInt8]] = try [
      ControlMessage.ping(epoch: 1, nonce: 2),
      .input(.init(attachmentEpoch: 1, sequence: 3, operation: .paste("hi"))),
      .attached(
        .init(
          attachmentEpoch: 2,
          writerID: .random(),
          lastFullyAppliedInputSequence: 4,
          resizeRevision: 1
        )
      ), .error(.init(.inputGap, sequence: 1)),
    ]
    .map { try ControlRecord.encode($0) }
    for round in 0 ..< 4000 {
      var reader = ControlRecordReader()
      let input =
        round % 2 == 0
        ? mutate(seeds[round % seeds.count], &rng)
        : (0 ..< Int.random(in: 0 ... 64, using: &rng))
          .map { _ in UInt8.random(in: 0 ... 255, using: &rng) }
      _ = try? reader.append(input)
      #expect(reader.bufferedBytes <= RSTLimits.maxControlRecordBytes + 4)
    }
  }

  @Test
  func `snapshot decoder rejects mutated frames without crashing`() throws {
    var rng = SplitMix64(state: 2)
    let frames = [SnapshotFrame.Encoding.smxb, .smxbZlib]
      .map { frameRecord(encoding: $0) }
    var accepted = 0
    for round in 0 ..< 3000 {
      let frame = mutate(frames[round % 2], &rng)
      if case let .frame(decoded, _)? = try? SnapshotFrame.decodeRecord(frame) {
        // Anything accepted is fully valid.
        #expect(throws: Never.self) {
          try FrameValidator.validate(
            decoded,
            limits: SnapshotFrame.frameLimits
          )
        }
        accepted += 1
      }
    }
    #expect(accepted < 3000)
  }

  @Test
  func `zlib bomb is stopped at the declared bound`() {
    let bomb = Zlib.compress([UInt8](repeating: 0, count: 8 * 1024 * 1024))
    #expect(bomb.count < 64 * 1024)
    #expect(throws: Zlib.Error.outputLimit) {
      try Zlib.decompress(bomb, limit: RSTLimits.maxSnapshotDecodedBytes)
    }
    // A header claiming a small size cannot smuggle a larger body.
    var frame: [UInt8] = [SnapshotFrame.Encoding.smxbZlib.rawValue]
    appendUInt32(100, to: &frame)
    appendUInt32(UInt32(bomb.count), to: &frame)
    frame += bomb
    #expect(throws: FramingError.decompression(.outputLimit)) {
      try SnapshotFrame.decodeRecord(frame)
    }
  }

  @Test
  func `bootstrap envelope decoder survives mutation`() throws {
    var rng = SplitMix64(state: 3)
    let seed = try BootstrapEnvelope.encode(
      BootstrapRequest(
        operation: .create,
        initialGrid: GridSize(columns: 80, rows: 24)
      )
    )
    for _ in 0 ..< 3000 {
      let bytes = mutate(seed, &rng)
      if let request = try? BootstrapEnvelope.decode(
        BootstrapRequest.self,
        from: bytes
      ) {
        _ = try? request.validate()
      }
    }
  }

  @Test
  func `random host ledger operations keep invariants`() throws {
    var rng = SplitMix64(state: 4)
    let writer = WriterID.random()
    for _ in 0 ..< 200 {
      var ledger = HostInputLedger(byteLimit: 256)
      try ledger.authorize(writer)
      var written: [UInt8] = []
      var expected: [UInt8] = []
      var ops: [UInt64: InputOperation] = [:]
      for _ in 0 ..< 100 {
        switch Int.random(in: 0 ..< 3, using: &rng) {
        case 0:
          // Submit a random sequence: next, retry, gap or stale.
          let seq = UInt64(
            max(
              1,
              Int(ledger.lastAdmitted) + Int.random(in: -2 ... 2, using: &rng)
            )
          )
          let op =
            ops[seq]
            ?? .committedText(String(repeating: "x", count: Int(seq % 7) + 1))
          let admission = ledger.classify(
            writer: writer,
            sequence: seq,
            operation: op
          )
          if admission == .admit {
            #expect(seq == ledger.lastAdmitted + 1)
            let bytes = Array("[\(seq)]".utf8)
            ledger.record(seq, operation: op, bytes: bytes)
            ops[seq] = op
            expected += bytes
          }
        default:
          if let next = ledger.nextWrite {
            let n = Int.random(in: 1 ... next.bytes.count, using: &rng)
            written += next.bytes.prefix(n)
            if let done = ledger.wrote(n) {
              #expect(done == ledger.lastApplied)
            }
          }
        }
        #expect(ledger.pendingBytes <= 256)
        #expect(ledger.lastApplied <= ledger.lastAdmitted)
      }
      while let next = ledger.nextWrite {
        written += next.bytes
        _ = ledger.wrote(next.bytes.count)
      }
      // Bytes reach the PTY in admission order, each exactly once.
      #expect(written == expected)
    }
  }
}
