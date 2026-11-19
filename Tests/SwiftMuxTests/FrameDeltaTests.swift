import Dispatch
import Foundation
import SwiftMuxBridge
import SwiftMuxClient
import SwiftMuxExport
import SwiftMuxProtocol
import SwiftMuxXPC
import SwifttyCore
import Synchronization
import Testing

/// Row versions, `SMXB/1` and frame deltas (spec.multiplexer.md §4, gate C11).
struct FrameDeltaTests {
  /// Exports frames of one session the way a pane does: one tracker, one
  /// revision sequence.
  struct Exporter {
    let session: TerminalSession
    var tracker = RowVersionTracker()
    var revision: UInt64 = 0
    var geometry: UInt64 = 1

    init(columns: Int = 20, rows: Int = 6) {
      session = TerminalSession(columns: columns, rows: rows)
    }

    func feed(_ text: String) { session.feed(Array(text.utf8)) }

    mutating func frame() throws -> PaneFrame {
      revision += 1
      let screen = session.withState { $0.captureOwnedScreen() }
      var identity = BridgeTests.identity()
      identity.revision = revision
      identity.geometryGeneration = geometry
      var frame = try FrameExporter.frame(from: screen, identity: identity)
      frame.rowVersions = tracker.stamp(screen)
      return frame
    }
  }

  /// Cell content with every table reference resolved, so frames with
  /// differently ordered tables compare equal.
  static func semantic(_ f: PaneFrame) -> [String] {
    var out: [String] = []
    for y in 0 ..< f.grid.rows {
      var row = "w\(f.grid.isWrapped(row: y) ? 1 : 0)"
      for x in 0 ..< f.grid.columns {
        let i = y * f.grid.columns + x
        let style = f.styles[f.grid.style(at: i)]
        let underline =
          style.underlineColor == 0
          ? 0 : f.underlineColors[Int(style.underlineColor) - 1]
        let glyph = f.grid.glyph(at: i)
        let text =
          glyph & FrameGrid.graphemeFlag != 0
          ? f.graphemes[Int(glyph & ~FrameGrid.graphemeFlag)].map(String.init)
            .joined(separator: "+") : String(glyph)
        row +=
          "|\(f.grid.kind(at: i).rawValue):\(text):\(style.foreground)"
          + ":\(style.background):\(style.flags):\(underline)"
      }
      out.append(row)
    }
    return out
  }

  static func expectSame(_ a: PaneFrame, _ b: PaneFrame) {
    #expect(semantic(a) == semantic(b))
    #expect(a.identity == b.identity)
    #expect(a.cursor == b.cursor)
    #expect(a.history == b.history)
    #expect(a.palette == b.palette)
    #expect(a.modes == b.modes)
    #expect(a.title == b.title)
    #expect(a.rowVersions == b.rowVersions)
    #expect(a.grid.alternateScreen == b.grid.alternateScreen)
  }

  // MARK: Row versions

  @Test
  func versionsChangeOnlyWithContent() throws {
    var e = Exporter()
    e.feed("one\r\ntwo\r\n")
    let first = try e.frame()
    let again = try e.frame()
    #expect(first.rowVersions == again.rowVersions)
    // A carriage-return overwrite keeps the address but not the version.
    e.feed("\rTWO")
    e.feed("\u{1B}[A\rTWO\r\n")
    let edited = try e.frame()
    #expect(edited.rowVersions![0] == first.rowVersions![0])
    #expect(edited.rowVersions![1] != first.rowVersions![1])
  }

  @Test
  func scrolledRowsKeepTheirIdentity() throws {
    var e = Exporter(rows: 4)
    for n in 1 ... 3 { e.feed("line\(n)\r\n") }
    let before = try e.frame()
    e.feed("line4\r\nline5\r\n")
    let after = try e.frame()
    let old = Set(before.rowIdentities!)
    // line3 moved up two rows but is the same row.
    let line3 = after.rowIdentities![0]
    #expect(after.lines[0] == "line3")
    #expect(old.contains(line3))
  }

  // MARK: Codec

  @Test
  func binaryAndJSONAgreeOnFullFrames() throws {
    var e = Exporter(columns: 12, rows: 6)
    e.session.feed(Array("\u{1B}[1;31mred\u{1B}[0m 漢字\r\n".utf8))
    e.feed("e\u{301} 👍🏽 👨‍👩‍👧\r\n\u{1B}[4:3;58:2::10:20:30mcurly\u{1B}[0m\r\n")
    e.feed("0123456789abcdefgh")
    var frame = try e.frame()
    frame.search = FrameSearch(
      matchCount: 3,
      selected: 1,
      visible: [
        FrameSpan(startRow: 0, startColumn: 0, endRow: 0, endColumn: 2)
      ],
      selectedVisible: 0
    )
    frame.dropTarget = FrameDropTarget(types: ["text/plain"], accepted: .copy)
    let binary = SMXB.encode(frame)
    guard case let .frame(decoded) = try SMXB.decode(binary).payload else {
      Issue.record("not a frame")
      return
    }
    #expect(decoded == frame)
    #expect(try BridgeTests.roundTrip(frame) == frame)
    // The binary form is much smaller than base64 JSON.
    let json = try SMXCodec.encode(
      ServerMessage.event(.frame(frame)),
      limit: 1 << 24
    )
    #expect(binary.count < json.count)
  }

  @Test
  func binaryAndJSONAgreeOnDeltas() throws {
    var e = Exporter()
    e.feed("a\r\nb\r\nc")
    let base = try e.frame()
    e.feed("d")
    let next = try e.frame()
    let baseline = try #require(FrameBaseline(base))
    let delta = try #require(
      FrameDeltaBuilder.delta(from: next, base: baseline)
    )
    guard case let .delta(decoded) = try SMXB.decode(SMXB.encode(delta)).payload
    else {
      Issue.record("not a delta")
      return
    }
    #expect(decoded == delta)
    let json = try SMXCodec.encode(
      ServerMessage.event(.frameDelta(delta)),
      limit: 1 << 24
    )
    guard
      case let .event(.frameDelta(fromJSON)) = try SMXCodec.decode(
        ServerMessage.self,
        from: json,
        limit: 1 << 24
      )
    else {
      Issue.record("not a JSON delta")
      return
    }
    #expect(fromJSON == delta)
  }

  @Test
  func truncatedAndCorruptRecordsFailSafely() throws {
    var e = Exporter(columns: 8, rows: 3)
    e.feed("ab漢\r\ncd")
    let data = SMXB.encode(try e.frame())
    for length in 0 ..< data.count {
      #expect(throws: MuxError.self) { try SMXB.decode(data.prefix(length)) }
    }
    // A flipped byte either fails or still decodes to a valid frame.
    var rng = SystemRandomNumberGenerator()
    for _ in 0 ..< 2000 {
      var bytes = [UInt8](data)
      let i = Int.random(in: 0 ..< bytes.count, using: &rng)
      bytes[i] ^= UInt8.random(in: 1 ... 255, using: &rng)
      if let record = try? SMXB.decode(Data(bytes)),
        case let .frame(frame) = record.payload
      {
        try FrameValidator.validate(frame)
      }
    }
    // Wrong envelope count and section order are malformed.
    var reordered = [UInt8](data)
    reordered[SMXB.headerBytes] = 3  // identity tag replaced by grid
    #expect(throws: MuxError.self) { try SMXB.decode(Data(reordered)) }
  }

  @Test
  func oversizedRecordsAreRejectedBeforeParsing() throws {
    var e = Exporter()
    let data = SMXB.encode(try e.frame())
    #expect(throws: MuxError.self) {
      try SMXB.decode(data, maxBytes: data.count - 1)
    }
  }

  // MARK: Deltas

  /// Each step's delta, applied to the previous frame, equals the full frame.
  static func replay(
    _ steps: [String],
    columns: Int = 20,
    rows: Int = 6,
    expectDelta: Bool = true
  ) throws -> [Int] {
    var e = Exporter(columns: columns, rows: rows)
    var previous = try e.frame()
    var replaced: [Int] = []
    for step in steps {
      e.feed(step)
      let full = try e.frame()
      let base = try #require(FrameBaseline(previous))
      if let delta = FrameDeltaBuilder.delta(from: full, base: base) {
        let applied = try FrameDeltaApplier.apply(delta, to: previous)
        expectSame(applied, full)
        replaced.append(delta.replacedCount)
      } else {
        #expect(!expectDelta, "expected a delta for \(step.debugDescription)")
      }
      previous = full
    }
    return replaced
  }

  @Test
  func typingEchoReplacesOneRow() throws {
    let replaced = try Self.replay(["$ ", "e", "c", "h", "o"])
    #expect(replaced.allSatisfy { $0 == 1 })
  }

  @Test
  func scrollingMovesRowsInsteadOfResending() throws {
    var steps = (1 ... 6).map { "line \($0)\r\n" }
    steps += (7 ... 30).map { "line \($0)\r\n" }
    let replaced = try Self.replay(steps, rows: 8)
    // A one-line scroll copies every surviving row.
    #expect(replaced.suffix(20).allSatisfy { $0 <= 2 })
  }

  @Test
  func carriageReturnProgressAndScrollRegions() throws {
    let progress = (0 ... 10).map { "\r[\(String(repeating: "#", count: $0))]" }
    _ = try Self.replay(["start\r\n"] + progress)
    // DECSTBM region: lines scroll inside rows 2-4 only.
    let region = ["\u{1B}[2;4r\u{1B}[4;1H"] + (1 ... 8).map { "r\($0)\n" }
    _ = try Self.replay(region, rows: 6, expectDelta: false)
  }

  @Test
  func screenSwitchAndResizeSendFullFrames() throws {
    var e = Exporter()
    e.feed("primary\r\n")
    let base = try e.frame()
    e.feed("\u{1B}[?1049h")
    let alternate = try e.frame()
    #expect(
      FrameDeltaBuilder.delta(from: alternate, base: FrameBaseline(base)!)
        == nil
    )
    e.geometry += 1
    let resized = try e.frame()
    #expect(
      FrameDeltaBuilder.delta(from: resized, base: FrameBaseline(alternate)!)
        == nil
    )
  }

  @Test
  func mismatchedBasesAndCorruptDeltasAreRejected() throws {
    var e = Exporter()
    e.feed("a\r\nb\r\nc")
    let base = try e.frame()
    e.feed("d")
    let next = try e.frame()
    let delta = try #require(
      FrameDeltaBuilder.delta(from: next, base: FrameBaseline(base)!)
    )
    // Another base revision.
    #expect(throws: MuxError.self) {
      try FrameDeltaApplier.apply(delta, to: next)
    }
    // A base with the same revision but different rows.
    var other = Exporter()
    other.feed("x\r\ny\r\nz")
    var foreign = try other.frame()
    foreign.identity = base.identity
    // Its own tracker numbered the same addresses; keep them distinct.
    foreign.rowVersions = foreign.rowVersions?.map { $0 + 100 }
    #expect(throws: MuxError.self) {
      try FrameDeltaApplier.apply(delta, to: foreign)
    }
    var badChecksum = delta
    badChecksum.identityChecksum ^= 1
    #expect(throws: MuxError.self) {
      try FrameDeltaApplier.apply(badChecksum, to: base)
    }
    var badSource = delta
    badSource.rowSources[0] = Int32(delta.rows)
    #expect(throws: MuxError.self) {
      try FrameDeltaApplier.apply(badSource, to: base)
    }
    #expect(try FrameDeltaApplier.apply(delta, to: base) != base)
  }

  // MARK: Hostile peers

  /// A delta whose history window puts its rows past `Int.max` is
  /// rejected before row addresses are computed, rather than trapping.
  @Test
  func overflowingHistoryWindowsAreRejected() throws {
    var e = Exporter()
    e.feed("a\r\nb\r\nc")
    let base = try e.frame()
    e.feed("d")
    let next = try e.frame()
    let delta = try #require(
      FrameDeltaBuilder.delta(from: next, base: FrameBaseline(base)!)
    )
    var hostile = delta
    hostile.history.viewportTop = Int.max - 1
    #expect(throws: MuxError.self) {
      try FrameDeltaApplier.apply(hostile, to: base)
    }
    var frame = next
    frame.history.viewportTop = Int.max - 1
    #expect(throws: MuxError.self) { try FrameValidator.validate(frame) }
    #expect(throws: MuxError.self) { try SMXB.decode(SMXB.encode(frame)) }
    frame.history.viewportTop = -1
    #expect(throws: MuxError.self) { try FrameValidator.validate(frame) }
  }

  /// Base and delta style tables each within a peer's `maxStyles` (at
  /// most `UInt16.max`) can merge into more styles than a cell's 16-bit
  /// style index holds; the delta is rejected instead of trapping.
  @Test
  func mergedStyleTablesBeyondTheLimitAreRejected() throws {
    var limits = MuxLimits.standard
    limits.maxStyles = Int(UInt16.max)
    let columns = limits.maxColumns
    let rows = limits.maxRows
    func grid(rows: Int, style: (Int) -> UInt16) -> FrameGrid {
      let count = rows * columns
      let glyphs = [UInt32](repeating: 0x41, count: count)
      let styles = (0 ..< count).map(style)
      return FrameGrid(
        columns: columns,
        rows: rows,
        alternateScreen: false,
        wrapped: Data(repeating: 0, count: rows),
        glyphs: glyphs.withUnsafeBytes { Data($0) },
        styles: styles.withUnsafeBytes { Data($0) },
        kinds: Data(repeating: CellKind.narrow.rawValue, count: count)
      )
    }
    func style(_ n: Int) -> FrameStyle {
      FrameStyle(
        foreground: 0x0200_0000 | UInt32(n),
        background: 0,
        flags: 0,
        underlineColor: 0
      )
    }
    let history = HistoryWindow(
      generation: 1,
      firstRow: 0,
      availableRows: rows,
      viewportTop: 0,
      viewportOffset: 0,
      scrollbackRows: 0
    )
    // Base: the first half of the rows use 65535 distinct styles.
    let baseStyles = Int(UInt16.max)
    let base = PaneFrame(
      identity: BridgeTests.identity(),
      grid: grid(rows: rows) { $0 < baseStyles ? UInt16($0) : 0 },
      graphemes: [],
      styles: (0 ..< baseStyles).map(style),
      underlineColors: [],
      palette: try BridgeTests.validFrame().palette,
      cursor: FrameCursor(x: 0, y: 0, visible: true, style: 0, blinking: false),
      modes: [],
      history: history,
      search: nil,
      title: "",
      rowVersions: (0 ..< rows).map { UInt64($0 + 1) }
    )
    try FrameValidator.validate(base, limits: limits)
    // Delta: keeps the first half, replaces just under half of the rows
    // with distinct styles of its own.
    let replacedRows = Array(rows / 2 ..< rows - 1)
    let replacedCells = replacedRows.count * columns
    var sources = (0 ..< rows).map { Int32($0) }
    for y in replacedRows { sources[y] = FrameDelta.replacedRow }
    var identity = base.identity
    identity.revision += 1
    var versions = base.rowVersions!
    for y in replacedRows { versions[y] = UInt64(1000 + y) }
    let identities = versions.enumerated()
      .map { y, version in
        RowIdentity(
          address: history.address(viewportRow: y, alternateScreen: false),
          version: version
        )
      }
    let delta = FrameDelta(
      identity: identity,
      baseRevision: base.identity.revision,
      columns: columns,
      rows: rows,
      alternateScreen: false,
      rowSources: sources,
      replaced: grid(rows: replacedRows.count) { UInt16($0) },
      graphemes: [],
      styles: (0 ..< replacedCells).map { style(0x10000 + $0) },
      underlineColors: [],
      replacedVersions: replacedRows.map { versions[$0] },
      palette: nil,
      cursor: base.cursor,
      modes: [],
      history: history,
      search: nil,
      title: "",
      dropTarget: nil,
      identityChecksum: RowChecksum.identities(identities)
    )
    #expect(throws: MuxError.self) {
      try FrameDeltaApplier.apply(delta, to: base, limits: limits)
    }
  }

  /// A delta's own tables are checked the same way whichever codec
  /// carried it: a malformed grapheme is rejected even when unreferenced.
  @Test
  func deltaTablesAreValidatedAlikeForBothCodecs() throws {
    var e = Exporter()
    e.feed("a\r\nb\r\nc")
    let base = try e.frame()
    e.feed("d")
    let next = try e.frame()
    var delta = try #require(
      FrameDeltaBuilder.delta(from: next, base: FrameBaseline(base)!)
    )
    delta.graphemes.append([])
    #expect(throws: MuxError.self) { try SMXB.decode(SMXB.encode(delta)) }
    #expect(throws: MuxError.self) {
      try FrameDeltaApplier.apply(delta, to: base)
    }
    delta.graphemes[delta.graphemes.count - 1] = [0xD800]
    #expect(throws: MuxError.self) { try SMXB.decode(SMXB.encode(delta)) }
    #expect(throws: MuxError.self) {
      try FrameDeltaApplier.apply(delta, to: base)
    }
  }

  /// A JSON frame is not validated on arrival, so an invalid one must not
  /// become a delta base: a delta naming it is answered with a full-frame
  /// request instead of indexing the invalid base.
  @Test(.timeLimit(.minutes(1)))
  func invalidJSONFramesAreNotDeltaBases() async throws {
    var e = Exporter()
    e.feed("a\r\nb\r\nc")
    let base = try e.frame()
    e.feed("d")
    let next = try e.frame()
    let delta = try #require(
      FrameDeltaBuilder.delta(from: next, base: FrameBaseline(base)!)
    )
    var invalid = base
    invalid.grid.kinds = Data()
    invalid.grid.styles = Data()
    let peer = ScriptedPeer(before: [.frame(invalid), .frameDelta(delta)])
    defer { peer.close() }
    var capabilities = ClientCapabilities.supported
    capabilities.remove(.binaryFrames)
    let connection = try await MuxConnection.connect(
      endpoint: peer.listener.endpoint,
      frontend: .native,
      capabilities: capabilities
    )
    let stats = await connection.deltaStatistics
    #expect(stats.applied == 0)
    #expect(stats.requestedFull == 1)
    await connection.close()
  }
}

/// Sends `events` ahead of its welcome, so the client handles them before
/// `connect` returns.
private final class ScriptedPeer: Sendable {
  let queue = DispatchQueue(label: "frame-delta-peer")
  let listener: SMXListener
  private let channels = Mutex<[SMXChannel]>([])

  init(before events: [MuxEvent]) {
    listener = SMXListener(anonymousOn: queue)
    listener.activate(connectionQueue: queue) { [self] channel in
      channels.withLock { $0.append(channel) }
      channel.activate { event in
        guard case let .message(data) = event,
          case .hello = try? SMXCodec.decode(
            ClientMessage.self,
            from: data,
            limit: 1 << 20
          )
        else { return }
        var messages = events.map { ServerMessage.event($0) }
        messages.append(
          .welcome(
            Welcome(
              protocolVersion: SMX.protocolVersion,
              build: SMX.build,
              server: ServerInstanceID(),
              acceptedProfile: nil,
              limits: .standard,
              innerTerm: "xterm-256color"
            )
          )
        )
        for message in messages {
          if let encoded = try? SMXCodec.encode(message, limit: 1 << 24) {
            channel.send(encoded)
          }
        }
      }
    }
  }

  func close() {
    channels.withLock { $0 }.forEach { $0.cancel() }
    listener.cancel()
  }
}
