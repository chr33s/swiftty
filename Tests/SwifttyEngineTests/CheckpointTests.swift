@testable import SwifttyEngine
import Testing

/// Planned-replacement checkpoints (spec.durability.md §6, B0; MR2): a
/// terminal restored from a checkpoint at any cut behaves exactly like one
/// that never stopped.
struct CheckpointTests {
  /// Deterministic generator; seeds name failures.
  struct Random {
    var state: UInt64
    mutating func next() -> UInt64 {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return state >> 11
    }
    mutating func int(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
  }

  /// Text, wide and combined clusters, colour, links, titles, cursor and
  /// margin movement, modes, charsets, prompts, kitty keyboard flags,
  /// saved cursors, the alternate screen and enough lines for history.
  static let fragments: [String] = [
    "plain text ", "wide 漢字 ", "e\u{301}\u{302} ", "👨‍👩‍👧 ", "🇳🇿 ",
    "\u{1B}[1;31mred\u{1B}[0m ", "\u{1B}[38;2;10;20;30;48;5;200mrgb\u{1B}[m ",
    "\u{1B}[4:3;58:2::1:2:3mcurly\u{1B}[0m ",
    "\u{1B}]8;;https://example.invalid/a\u{07}link\u{1B}]8;;\u{07} ",
    "\u{1B}]8;id=x;https://example.invalid/b\u{07}idlink\u{1B}]8;;\u{07} ",
    "\u{1B}]8;id=x;https://example.invalid/b\u{07}again\u{1B}]8;;\u{07} ",
    "\u{1B}]2;title here\u{07}", "\u{1B}]7;file://localhost/tmp\u{07}",
    "\u{1B}[5;10H", "\u{1B}[2J", "\u{1B}[K", "\u{1B}[3;8r", "\u{1B}[r",
    "\u{1B}[?6h", "\u{1B}[?6l", "\u{1B}[?7l", "\u{1B}[?7h", "\u{1B}[?25l",
    "\u{1B}[?25h", "\u{1B}[4h", "\u{1B}[4l", "\u{1B}(0lqk\u{1B}(B ", "\u{1B}7",
    "\u{1B}8", "\u{1B}H", "\u{1B}[3g", "\u{1B}[2 q",
    "\u{1B}]133;A\u{07}$ \u{1B}]133;B\u{07}ls\r\n\u{1B}]133;C\u{07}",
    "out\r\n\u{1B}]133;D;0\u{07}", "\u{1B}[>1u", "\u{1B}[<u", "\u{1B}[#{",
    "\u{1B}[#}", "\u{1B}[22;0t", "\u{1B}[23;0t", "\u{1B}[?1049h",
    "\u{1B}[?1049l", "\u{1B}[?2004h", "\u{1B}[?1004h", "\u{1B}[?1000h",
    "\u{1B}[?1006h", "\u{1B}D", "\u{1B}M", "\u{1B}[2L", "\u{1B}[2M",
    "\u{1B}[3@", "\u{1B}[2P", "\u{1B}[5X", "\t", "\r\n", "\r\n", "\r\n",
    "line of output\r\n", "\u{1B}]4;1;rgb:12/34/56\u{07}",
    "\u{1B}]10;rgb:ff/ee/dd\u{07}", "\u{1B}P$qm\u{1B}\\",
  ]

  static func stream(seed: UInt64, pieces: Int = 400) -> [UInt8] {
    var random = Random(state: seed)
    var out: [UInt8] = []
    for _ in 0 ..< pieces {
      out.append(contentsOf: fragments[random.int(fragments.count)].utf8)
    }
    return out
  }

  /// Feeds `bytes` in uneven chunks, as reads arrive.
  static func feed(
    _ bytes: ArraySlice<UInt8>,
    _ parser: inout Parser,
    _ state: inout TerminalState,
    random: inout Random
  ) {
    var index = bytes.startIndex
    while index < bytes.endIndex {
      let end = min(bytes.endIndex, index + 1 + random.int(97))
      let chunk = Array(bytes[index ..< end])
      parser.consume(chunk.span, into: &state)
      index = end
    }
  }

  /// What a worker settles before a cut: events are delivered and replies
  /// handed to the writer.
  static func settle(_ state: inout TerminalState) {
    _ = state.takeEvents()
    state.output.removeAll()
    _ = state.programStatus.takeJournal()
  }

  static func snapshot(
    _ parser: borrowing Parser,
    _ state: inout TerminalState
  ) throws -> [UInt8] {
    var w = CheckpointWriter()
    parser.checkpoint(into: &w)
    return try state.checkpoint() + w.bytes
  }

  @Test(arguments: [UInt64(1), 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])
  func restoredTerminalContinuesExactly(seed: UInt64) throws {
    let bytes = Self.stream(seed: seed)
    var random = Random(state: seed &* 31)
    let cut = random.int(bytes.count)
    var straight = TerminalState(
      columns: 40,
      rows: 10,
      scrollbackLimitRows: 200
    )
    var straightParser = Parser()
    var feedRandom = Random(state: seed)
    Self.feed(bytes[..<cut], &straightParser, &straight, random: &feedRandom)
    Self.settle(&straight)

    // Checkpoint a second terminal at the same cut.
    var source = TerminalState(columns: 40, rows: 10, scrollbackLimitRows: 200)
    var sourceParser = Parser()
    var sourceRandom = Random(state: seed)
    Self.feed(bytes[..<cut], &sourceParser, &source, random: &sourceRandom)
    Self.settle(&source)
    let checkpoint = try source.checkpoint()
    var parserBytes = CheckpointWriter()
    sourceParser.checkpoint(into: &parserBytes)

    var restored = try TerminalState.restored(checkpoint: checkpoint)
    var restoredParser = Parser()
    var reader = CheckpointReader(parserBytes.bytes)
    try restoredParser.restore(from: &reader)
    try reader.finish()
    // Canonical: a restored terminal checkpoints to the same bytes.
    #expect(try restored.checkpoint() == checkpoint, "seed \(seed) cut \(cut)")
    #expect(try straight.checkpoint() == checkpoint, "seed \(seed)")

    // The rest of the stream gives identical state and output.
    var rest = Random(state: seed &+ 99)
    var restCopy = rest
    Self.feed(bytes[cut...], &straightParser, &straight, random: &rest)
    Self.feed(bytes[cut...], &restoredParser, &restored, random: &restCopy)
    #expect(straight.output == restored.output, "seed \(seed) replies")
    #expect(straight.takeEvents() == restored.takeEvents(), "seed \(seed)")
    Self.settle(&straight)
    Self.settle(&restored)
    #expect(straight.screenLines == restored.screenLines, "seed \(seed)")
    #expect(
      straight.dumpPrimaryANSI() == restored.dumpPrimaryANSI(),
      "seed \(seed)"
    )
    #expect(
      try Self.snapshot(straightParser, &straight)
        == Self.snapshot(restoredParser, &restored),
      "seed \(seed) final state"
    )
  }

  /// Many seeds, shorter streams, and a resize (reflow) after the cut.
  @Test
  func manySeedsSurviveACutAndAReflow() throws {
    for seed in UInt64(100) ..< 300 {
      let bytes = Self.stream(seed: seed, pieces: 120)
      var random = Random(state: seed)
      let cut = random.int(bytes.count)
      var a = TerminalState(columns: 30, rows: 8, scrollbackLimitRows: 60)
      var ap = Parser()
      ap.consume(Array(bytes[..<cut]).span, into: &a)
      Self.settle(&a)
      var b = try TerminalState.restored(checkpoint: try a.checkpoint())
      var bp = Parser()
      var w = CheckpointWriter()
      ap.checkpoint(into: &w)
      var reader = CheckpointReader(w.bytes)
      try bp.restore(from: &reader)
      let columns = 12 + random.int(40)
      let rows = 3 + random.int(12)
      a.resize(columns: columns, rows: rows)
      b.resize(columns: columns, rows: rows)
      ap.consume(Array(bytes[cut...]).span, into: &a)
      bp.consume(Array(bytes[cut...]).span, into: &b)
      #expect(a.output == b.output, "seed \(seed)")
      Self.settle(&a)
      Self.settle(&b)
      let left = try Self.snapshot(ap, &a)
      let right = try Self.snapshot(bp, &b)
      #expect(left == right, "seed \(seed) cut \(cut)")
      if left != right { break }
    }
  }

  /// MR2: compressed history and an active search anchor survive the cut,
  /// and a cut inside a UTF-8 sequence or an escape continues exactly.
  @Test(arguments: [UInt64(21), 22, 23])
  func compressedHistoryAndSearchSurviveACut(seed: UInt64) throws {
    var lines: [UInt8] = []
    for i in 0 ..< 3_000 {
      lines.append(contentsOf: "history line \(i) 漢字 é\r\n".utf8)
    }
    let tail = Array("\u{1B}[1;3".utf8) + Array("1mred 漢".utf8.prefix(5))
    func build(_ state: inout TerminalState, _ parser: inout Parser) {
      state.setScrollbackCompression(true)
      parser.consume(lines.span, into: &state)
      for _ in 0 ..< 200 where state.maintainScrollback() == .pending {}
      state.search("line 12")
      _ = state.selectSearchMatch(forward: false)
      // Cut inside an SGR and inside a multibyte character.
      parser.consume(tail.span, into: &state)
      Self.settle(&state)
    }
    var straight = TerminalState(
      columns: 32,
      rows: 8,
      scrollbackLimitRows: 4_000
    )
    var straightParser = Parser()
    build(&straight, &straightParser)
    var source = TerminalState(columns: 32, rows: 8, scrollbackLimitRows: 4_000)
    var sourceParser = Parser()
    build(&source, &sourceParser)
    #expect(source.scrollbackStatistics.compressedUnits > 0)
    let checkpoint = try source.checkpoint()
    var w = CheckpointWriter()
    sourceParser.checkpoint(into: &w)
    var restored = try TerminalState.restored(checkpoint: checkpoint)
    var restoredParser = Parser()
    var reader = CheckpointReader(w.bytes)
    try restoredParser.restore(from: &reader)
    #expect(restored.searchMatches == straight.searchMatches)
    #expect(restored.searchSelected == straight.searchSelected)
    let rest = Array("字\u{1B}[0m done\r\n".utf8) + Self.stream(seed: seed)
    straightParser.consume(rest.span, into: &straight)
    restoredParser.consume(rest.span, into: &restored)
    #expect(straight.output == restored.output)
    Self.settle(&straight)
    Self.settle(&restored)
    _ = straight.selectSearchMatch(forward: true)
    _ = restored.selectSearchMatch(forward: true)
    #expect(straight.searchSelected == restored.searchSelected)
    #expect(
      straight.dumpPrimaryANSI() == restored.dumpPrimaryANSI(),
      "seed \(seed)"
    )
    #expect(
      try Self.snapshot(straightParser, &straight)
        == Self.snapshot(restoredParser, &restored),
      "seed \(seed)"
    )
  }

  @Test
  func everyCutOfAShortStreamRoundTrips() throws {
    let bytes = Self.stream(seed: 77, pieces: 60)
    for cut in 0 ..< bytes.count {
      var state = TerminalState(columns: 20, rows: 5, scrollbackLimitRows: 50)
      var parser = Parser()
      parser.consume(Array(bytes[..<cut]).span, into: &state)
      Self.settle(&state)
      let checkpoint = try state.checkpoint()
      var restored = try TerminalState.restored(checkpoint: checkpoint)
      #expect(try restored.checkpoint() == checkpoint, "cut \(cut)")
    }
  }

  @Test
  func unsettledEffectsAreRefused() {
    var state = TerminalState(columns: 20, rows: 5)
    var parser = Parser()
    // A device attributes query leaves a reply pending.
    parser.consume(Array("\u{1B}[c".utf8).span, into: &state)
    #expect(throws: CheckpointError.self) { try state.checkpoint() }
    state.output.removeAll()
    parser.consume(Array("\u{1B}]2;t\u{07}".utf8).span, into: &state)
    #expect(throws: CheckpointError.self) { try state.checkpoint() }
    _ = state.takeEvents()
    #expect((try? state.checkpoint()) != nil)
  }

  @Test
  func corruptCheckpointsAreRefusedWithoutPartialState() throws {
    var state = TerminalState(columns: 20, rows: 5)
    var parser = Parser()
    parser.consume(Array(Self.stream(seed: 5, pieces: 80)).span, into: &state)
    Self.settle(&state)
    let checkpoint = try state.checkpoint()
    var random = Random(state: 5)
    for _ in 0 ..< 200 {
      var corrupt = checkpoint
      switch random.int(3) {
      case 0: corrupt.removeLast(1 + random.int(min(64, corrupt.count - 1)))
      case 1:
        let i = random.int(corrupt.count)
        corrupt[i] ^= UInt8(1 + random.int(255))
      default: corrupt.append(UInt8(random.int(256)))
      }
      // Either a clean refusal, or a valid terminal that checkpoints
      // canonically (a flipped colour byte is still a colour).
      if var restored = try? TerminalState.restored(checkpoint: corrupt) {
        #expect((try? restored.checkpoint()) != nil)
      }
    }
  }
}
