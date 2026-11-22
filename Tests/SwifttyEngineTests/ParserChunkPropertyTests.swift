@testable import SwifttyEngine
import Testing
import TestSupport

/// The parser is chunk invariant: a byte stream fed whole, byte by byte
/// or in random chunks leaves the same replies, events, status journal
/// and canonical checkpoint.
struct ParserChunkPropertyTests {
  /// The checkpoint fragments, plus queries that reply, status reports,
  /// string terminators and malformed UTF-8 that must recover alike.
  static let fragments: [[UInt8]] =
    CheckpointTests.fragments.map { Array($0.utf8) }
    + [
      "\u{1B}[c", "\u{1B}[>c", "\u{1B}[5n", "\u{1B}[6n", "\u{1B}[?6n",
      "\u{1B}[?2004$p", "\u{1B}[>q", "\u{1B}[?u", "\u{1B}]10;?\u{07}",
      "\u{1B}]11;?\u{1B}\\", "\u{1B}]4;3;?\u{07}", "\u{1B}]2;st title\u{1B}\\",
      "\u{07}", "\u{1B}]7501;state=working:id=build:progress=20\u{07}",
      "\u{1B}]7501;state=blocked:id=build/test\u{1B}\\",
      "\u{1B}]7501;state=clear:id=build\u{07}", "\u{1B}]7501;?\u{07}",
      "\u{1B}[38;5;", "1m", "\u{1B}]2;unterminated", "\u{1B}\\",
    ]
    .map { Array($0.utf8) } + [
      [0xC3], [0xE6, 0xBC], [0xFF], [0xF0, 0x9F], [0x80],
    ]

  struct Input: CustomStringConvertible {
    /// Indexes into `fragments`.
    var pieces: [Int]
    /// Chunk lengths, reused cyclically.
    var lengths: [Int]

    var bytes: [UInt8] { pieces.flatMap { fragments[$0] } }

    var description: String {
      let text = pieces.map { index in
        let bytes = fragments[index]
        guard let text = String(validating: bytes, as: UTF8.self) else {
          return "<" + bytes.map { String($0, radix: 16) }.joined() + ">"
        }
        return text.debugDescription
      }
      return "chunks \(lengths) of \(text.joined(separator: " "))"
    }
  }

  static func generate(_ random: inout PropertyRandom) -> Input {
    let count = random.int(in: 1 ... 300)
    return Input(
      pieces: random.array(count: count) { $0.int(fragments.count) },
      lengths: random.array(count: random.int(in: 1 ... 12)) {
        $0.int(in: 1 ... 97)
      }
    )
  }

  static func shrink(_ input: Input) -> [Input] {
    Property.shrinkList(input.pieces)
      .map { Input(pieces: $0, lengths: input.lengths) }
      + Property.shrinkList(input.lengths) { $0 > 1 ? [1, $0 / 2] : [] }
      .filter { !$0.isEmpty }.map { Input(pieces: input.pieces, lengths: $0) }
  }

  struct Outcome {
    var replies: [UInt8]
    var events: [TerminalEvent]
    var status: [ProgramStatusChange]
    var statusTruncated: Bool
    var lines: [String]
    var dump: [UInt8]
    var checkpoint: [UInt8]
  }

  /// Feeds `bytes` in chunks of `length(n)` for the nth chunk.
  static func outcome(_ bytes: [UInt8], length: (Int) -> Int) throws -> Outcome
  {
    var state = TerminalState(columns: 30, rows: 8, scrollbackLimitRows: 60)
    var parser = Parser()
    var index = 0
    var n = 0
    while index < bytes.count {
      let end = min(bytes.count, index + max(1, length(n)))
      parser.consume(Array(bytes[index ..< end]).span, into: &state)
      index = end
      n += 1
    }
    let replies = state.output
    let events = state.takeEvents()
    let status = state.programStatus.takeJournal()
    state.output.removeAll()
    return Outcome(
      replies: replies,
      events: events,
      status: status.changes,
      statusTruncated: status.truncated,
      lines: state.screenLines,
      dump: state.dumpPrimaryANSI(),
      checkpoint: try CheckpointTests.snapshot(parser, &state)
    )
  }

  /// What differs; empty when nothing does. `canonical` includes the
  /// checkpoint bytes.
  static func difference(
    _ a: Outcome,
    _ b: Outcome,
    canonical: Bool
  ) -> [String] {
    var fields: [String] = []
    if a.replies != b.replies {
      fields.append(
        "replies \(String(decoding: a.replies, as: UTF8.self).debugDescription)"
          + " vs \(String(decoding: b.replies, as: UTF8.self).debugDescription)"
      )
    }
    if a.events != b.events {
      fields.append("events \(a.events) vs \(b.events)")
    }
    if a.status != b.status || a.statusTruncated != b.statusTruncated {
      fields.append("status journal")
    }
    if a.lines != b.lines { fields.append("screen \(a.lines) vs \(b.lines)") }
    if a.dump != b.dump { fields.append("primary screen and history dump") }
    if canonical, a.checkpoint != b.checkpoint {
      fields.append("checkpoint bytes")
    }
    return fields
  }

  static func check(_ input: Input, canonical: Bool) throws -> String? {
    let bytes = input.bytes
    let whole = try outcome(bytes) { _ in bytes.count }
    let single = try outcome(bytes) { _ in 1 }
    let lengths = input.lengths
    let chunked = try outcome(bytes) { lengths[$0 % lengths.count] }
    for (name, other) in [("byte by byte", single), ("in chunks", chunked)] {
      let fields = difference(whole, other, canonical: canonical)
      if !fields.isEmpty {
        return "whole vs \(name): " + fields.joined(separator: "; ")
      }
    }
    return nil
  }

  @Test
  func chunkingKeepsRepliesEventsAndScreen() {
    let failure = Property.check(
      seeds: Property.seeds(60),
      generate: Self.generate,
      shrink: Self.shrink,
      property: { try Self.check($0, canonical: false) }
    )
    #expect(failure == nil, "\(failure?.description ?? "")")
  }

  /// Checkpoint bytes are canonical: fields the parser state cannot read
  /// (`codepoint`/`utf8Minimum` after a scalar, `escIntermediate` after its
  /// sequence) and the grapheme tail's break cache are not carried, so the
  /// bytes do not depend on read boundaries.
  @Test
  func chunkingKeepsTheCanonicalCheckpoint() {
    let failure = Property.check(
      seeds: Property.seeds(60),
      generate: Self.generate,
      shrink: Self.shrink,
      property: { try Self.check($0, canonical: true) }
    )
    #expect(failure == nil, "\(failure?.description ?? "")")
  }

  /// The minimal counterexamples, fed whole and byte by byte: a UTF-8
  /// scalar, a combining mark, and a designation followed by a CSI.
  @Test(
    arguments: ["漢", "e\u{301}", "\u{1B}(B\u{1B}[?25l"].map(TestFixture.init)
  )
  func minimalCheckpointCounterexamples(_ text: TestFixture<String>) throws {
    let bytes = Array(text.value.utf8)
    let whole = try Self.outcome(bytes) { _ in bytes.count }
    let single = try Self.outcome(bytes) { _ in 1 }
    #expect(Self.difference(whole, single, canonical: false).isEmpty)
    #expect(whole.checkpoint == single.checkpoint)
  }
}
