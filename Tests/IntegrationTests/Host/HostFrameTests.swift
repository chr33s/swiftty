#if os(macOS)
import Foundation
import RoamingKit
import ScreenProtocol
import SessionCore
import SwiftMuxExport
import SwiftMuxProtocol
import SwifttyEngine
import Synchronization
@testable import TerminalHost
import Testing

/// Shared frames, deltas and copy between a real host session and a raw
/// RST/1 client (spec.roaming.md §7.4, §7.5; A20–A22).
@Suite(.timeLimit(.minutes(1)))
struct HostFrameTests {
  /// A client that negotiates `paneFrames`, `screenDeltas` and
  /// `copySelection`, applies deltas itself and can forget its bases.
  final class FrameClient: @unchecked Sendable {
    struct State {
      var reader = ControlRecordReader()
      var messages: [ControlMessage] = []
      var frames: [PaneFrame] = []
    }

    let connection: InMemoryRSTConnection
    let state = Mutex(State())
    /// Drop every base before applying a delta, as a client that lost them.
    let forgetBases = Atomic(false)
    let full = Atomic(0)
    let deltas = Atomic(0)
    let unresolved = Atomic(0)
    let bad = Atomic(0)
    /// Withhold screen acknowledgements until `releaseAcks()`.
    let holdAcks = Atomic(false)
    /// Leave the host's pings unanswered.
    let ignorePings = Atomic(false)
    let heldAcks = Mutex<[ControlMessage]>([])

    init(_ registry: SessionRegistry) {
      let (client, server) = InMemoryRSTConnection.pair()
      connection = client
      registry.accept(server)
      client.start(
        RSTConnectionHandler(
          onControl: { [self] bytes in
            let messages = state.withLock { s in
              let messages = (try? s.reader.append(bytes)) ?? []
              s.messages += messages
              return messages
            }
            // As RoamingClient: every ping is answered.
            guard !ignorePings.load(ordering: .acquiring) else { return }
            for case let .ping(epoch, nonce) in messages {
              try? await send(.pong(epoch: epoch, nonce: nonce))
            }
          },
          onSnapshot: { [self] bytes in await received(bytes) },
          onClosed: { _ in }
        )
      )
    }

    private func received(_ bytes: [UInt8]) async {
      let record = try? SnapshotFrame.decodeRecord(bytes)
      var refused = false
      let header: RSTFrameHeader
      switch record {
      case let .frame(frame, h)?:
        full.add(1, ordering: .relaxed)
        state.withLock { $0.frames.append(frame) }
        header = h
      case let .delta(delta, h)?:
        header = h
        if forgetBases.load(ordering: .acquiring) {
          state.withLock { $0.frames.removeAll() }
        }
        let base = state.withLock { s in
          s.frames.last { $0.identity.revision == delta.baseRevision }
        }
        if let base,
          let frame = try? FrameDeltaApplier.apply(
            delta,
            to: base,
            limits: SnapshotFrame.frameLimits
          )
        {
          deltas.add(1, ordering: .relaxed)
          state.withLock { $0.frames.append(frame) }
        } else {
          unresolved.add(1, ordering: .relaxed)
          refused = true
        }
      default:
        bad.add(1, ordering: .relaxed)
        return
      }
      // As RoamingClient: a refused delta is released by the request for
      // a complete screen, never acknowledged as a base.
      let reply: ControlMessage =
        refused
        ? .requestFullScreen(
          epoch: header.attachmentEpoch,
          screenRevision: header.screenRevision
        )
        : .screenAck(
          epoch: header.attachmentEpoch,
          screenRevision: header.screenRevision
        )
      if !refused, holdAcks.load(ordering: .acquiring) {
        heldAcks.withLock { $0.append(reply) }
        return
      }
      try? await send(reply)
    }

    func releaseAcks() async throws {
      holdAcks.store(false, ordering: .releasing)
      let acks = heldAcks.withLock { held in
        let acks = held
        held = []
        return acks
      }
      for ack in acks { try await send(ack) }
    }

    func chunks(_ request: UInt64) -> Int {
      state.withLock { s in
        s.messages
          .filter {
            if case .copyChunk(_, request, _, _) = $0 { true } else { false }
          }
          .count
      }
    }

    func send(_ message: ControlMessage) async throws {
      try await connection.sendControl(ControlRecord.encode(message))
    }

    func attached(
      _ grant: BootstrapGrant
    ) async throws -> ControlMessage.Attached {
      try await send(
        .attach(
          .init(
            sessionID: grant.sessionID,
            serverInstanceID: grant.serverInstanceID,
            writerID: grant.writerID,
            applicationToken: grant.applicationToken,
            features: .supported
          )
        )
      )
      let reply = try await message("Attached") {
        if case .attached = $0 { true } else { false }
      }
      guard case let .attached(attached) = reply else {
        throw CancellationError()
      }
      return attached
    }

    func message(
      _ what: String,
      where predicate: @escaping (ControlMessage) -> Bool
    ) async throws -> ControlMessage {
      try await hostEventually(what) {
        state.withLock { $0.messages.first(where: predicate) }
      }
    }

    func frame(
      _ what: String,
      where predicate: @escaping (PaneFrame) -> Bool
    ) async throws -> PaneFrame {
      try await hostEventually(what) {
        state.withLock { $0.frames.last(where: predicate) }
      }
    }
  }

  static func input(
    _ sequence: UInt64,
    _ operation: InputOperation
  ) -> ControlMessage {
    .input(.init(attachmentEpoch: 1, sequence: sequence, operation: operation))
  }

  @Test
  func `frames arrive as applied deltas and a lost base recovers in full`()
    async throws
  {
    try await withRegistry { registry in
      let grant = try await registry.create(
        grid: GridSize(columns: 40, rows: 8)
      )
      let client = FrameClient(registry)
      defer { client.connection.close() }
      let attached = try await client.attached(grant)
      #expect(attached.features.isSuperset(of: [.paneFrames, .screenDeltas]))
      _ = try await client.frame("prompt") {
        $0.lines.contains { $0.contains("$") }
      }
      for (n, word) in ["alpha", "beta", "gamma"].enumerated() {
        try await client.send(
          Self.input(UInt64(2 * n + 1), .committedText("echo \(word)"))
        )
        try await client.send(
          Self.input(UInt64(2 * n + 2), .key(SemanticKey(.enter)))
        )
        _ = try await client.frame(word) { $0.lines.contains(word) }
      }
      #expect(client.deltas.load(ordering: .relaxed) > 0)
      // Forget every base: the next delta cannot apply, the client asks
      // once, and a complete screen follows.
      client.forgetBases.store(true, ordering: .releasing)
      let fullBefore = client.full.load(ordering: .relaxed)
      try await client.send(Self.input(7, .committedText("echo recovered")))
      try await client.send(Self.input(8, .key(SemanticKey(.enter))))
      try await hostEventually("full screen after request") { () -> Bool? in
        client.full.load(ordering: .relaxed) > fullBefore ? true : nil
      }
      client.forgetBases.store(false, ordering: .releasing)
      #expect(client.unresolved.load(ordering: .relaxed) > 0)
      _ = try await client.frame("recovered") { $0.lines.contains("recovered") }
      #expect(client.bad.load(ordering: .relaxed) == 0)
    }
  }

  @Test
  func `copy spans unfetched history in ordered chunks`() async throws {
    try await withRegistry { registry in
      let grant = try await registry.create(
        grid: GridSize(columns: 40, rows: 8)
      )
      let client = FrameClient(registry)
      defer { client.connection.close() }
      let attached = try await client.attached(grant)
      #expect(attached.features.contains(.copySelection))
      _ = try await client.frame("prompt") {
        $0.lines.contains { $0.contains("$") }
      }
      try await client.send(
        Self.input(1, .committedText("seq 1 20000; echo done-mark"))
      )
      try await client.send(Self.input(2, .key(SemanticKey(.enter))))
      let frame = try await client.frame("output") {
        $0.lines.contains("done-mark")
      }
      let h = frame.history
      let done = try #require(frame.lines.firstIndex(of: "done-mark"))
      let screen = (0 ... done)
        .compactMap { y -> [UInt64]? in
          guard let id = frame.rowIdentity(y) else { return nil }
          return [UInt64(id.address.row), id.version]
        }
      func copy(_ id: UInt64, rows: [[UInt64]]) async throws {
        try await client.send(
          .copySelection(
            .init(
              attachmentEpoch: 1,
              requestID: id,
              generation: h.generation,
              alternateScreen: false,
              startRow: UInt64(h.firstRow),
              startColumn: 0,
              endRow: UInt64(h.viewportTop + done),
              endColumn: 39,
              unit: .character,
              screenRowVersions: rows
            )
          )
        )
      }
      try await copy(1, rows: screen)
      let result = try await client.message("copy result") {
        if case .copyResult(_, 1, _, _) = $0 { true } else { false }
      }
      guard case let .copyResult(_, _, total, error) = result else { return }
      #expect(error == nil)
      let chunks = client.state.withLock { s in
        s.messages.compactMap { m -> (UInt64, String)? in
          if case let .copyChunk(_, 1, index, text) = m {
            (index, text)
          } else {
            nil
          }
        }
      }
      // Over one control record of text, sent in order.
      #expect(chunks.count > 1)
      #expect(chunks.map(\.0) == Array(0 ..< UInt64(chunks.count)))
      let text = chunks.map(\.1).joined()
      #expect(UInt64(text.utf8.count) == total)
      let lines = text.split(separator: "\n")
      #expect(lines.contains("19999"))
      #expect(lines.last == "done-mark")
      // A changed row refuses rather than copying text the client never saw.
      var stale = screen
      stale[stale.count - 1][1] &+= 1000
      try await copy(2, rows: stale)
      let refused = try await client.message("stale copy") {
        if case .copyResult(_, 2, _, _) = $0 { true } else { false }
      }
      #expect(
        refused
          == .copyResult(
            epoch: 1,
            requestID: 2,
            totalBytes: nil,
            error: .selectionChanged
          )
      )
    }
  }

  @Test
  func `chunks always fit one control record`() throws {
    // Short lines and escaped characters at least double in JSON.
    for text in [
      String(repeating: "y\n", count: 60_000),
      String(repeating: "\\\"", count: 40_000),
      String(repeating: "\u{1}", count: 20_000),
      String(repeating: "漢", count: 40_000),
    ] {
      let chunks = RoamingSession.chunks(text)
      #expect(chunks.joined() == text)
      for (index, chunk) in chunks.enumerated() {
        let record = try ControlRecord.encode(
          .copyChunk(epoch: 1, requestID: 1, index: UInt64(index), text: chunk)
        )
        #expect(record.count <= RSTLimits.maxControlRecordBytes)
      }
    }
  }

  @Test
  func `a multi-chunk copy completes alongside typing`() async throws {
    try await withRegistry { registry in
      let grant = try await registry.create(
        grid: GridSize(columns: 200, rows: 8)
      )
      let client = FrameClient(registry)
      defer { client.connection.close() }
      _ = try await client.attached(grant)
      _ = try await client.frame("prompt") {
        $0.lines.contains { $0.contains("$") }
      }
      // As much history as the pane's budget keeps at 200 columns.
      try await client.send(
        Self.input(
          1,
          .committedText(
            "i=0; while [ $i -lt 9000 ]; do printf '%0190d\\n' $i; i=$((i+1)); done; echo done-mark"
          )
        )
      )
      try await client.send(Self.input(2, .key(SemanticKey(.enter))))
      let frame = try await client.frame("output") {
        $0.lines.contains("done-mark")
      }
      let h = frame.history
      let done = try #require(frame.lines.firstIndex(of: "done-mark"))
      try await client.send(
        .copySelection(
          .init(
            attachmentEpoch: 1,
            requestID: 7,
            generation: h.generation,
            alternateScreen: false,
            startRow: UInt64(h.firstRow),
            startColumn: 0,
            endRow: UInt64(h.viewportTop + done),
            endColumn: 199,
            unit: .character,
            screenRowVersions: []
          )
        )
      )
      // Typing during the copy is acknowledged between chunks.
      try await client.send(Self.input(3, .committedText("x")))
      let result = try await client.message("copy result") {
        if case .copyResult(_, 7, _, _) = $0 { true } else { false }
      }
      guard case let .copyResult(_, _, total, error) = result else { return }
      #expect(error == nil)
      // Several chunks, each sent only after the previous one left.
      #expect((total ?? 0) > 4 * ControlMessage.maxCopyChunkBytes)
      #expect(!client.connection.isClosed)
      _ = try await client.message("input acknowledged") {
        if case .inputAck(_, 3) = $0 { true } else { false }
      }
    }
  }

  /// Over QUIC, queued control data delays snapshot streams, so a copy
  /// chunk waits until the client has acknowledged the screens in flight
  /// (spec.roaming.md §7.5). Without that, a large copy held the echo of
  /// typing until the copy finished (spec.multiplexer.md §11, shaped QUIC).
  @Test(arguments: [false, true])
  func `copy chunks wait for the screens in flight`(
    acksResume: Bool
  ) async throws {
    try await withRegistry { registry in
      let grant = try await registry.create(
        grid: GridSize(columns: 200, rows: 8)
      )
      let client = FrameClient(registry)
      defer { client.connection.close() }
      _ = try await client.attached(grant)
      _ = try await client.frame("prompt") {
        $0.lines.contains { $0.contains("$") }
      }
      // About three chunks of history.
      try await client.send(
        Self.input(
          1,
          .committedText(
            "i=0; while [ $i -lt 700 ]; do printf '%0190d\\n' $i; i=$((i+1)); done; echo done-mark"
          )
        )
      )
      try await client.send(Self.input(2, .key(SemanticKey(.enter))))
      let frame = try await client.frame("output") {
        $0.lines.contains("done-mark")
      }
      let h = frame.history
      let done = try #require(frame.lines.firstIndex(of: "done-mark"))
      // A screen the client has received but not acknowledged.
      client.holdAcks.store(true, ordering: .releasing)
      try await client.send(Self.input(3, .committedText("echo held-$((3*3))")))
      try await client.send(Self.input(4, .key(SemanticKey(.enter))))
      _ = try await client.frame("held screen") { $0.lines.contains("held-9") }
      let requested = ContinuousClock.now
      try await client.send(
        .copySelection(
          .init(
            attachmentEpoch: 1,
            requestID: 9,
            generation: h.generation,
            alternateScreen: false,
            startRow: UInt64(h.firstRow),
            startColumn: 0,
            endRow: UInt64(h.viewportTop + done),
            endColumn: 199,
            unit: .character,
            screenRowVersions: []
          )
        )
      )
      try await Task.sleep(for: .milliseconds(800))
      #expect(
        client.chunks(9) == 0,
        "a chunk overtook an unacknowledged screen"
      )
      if acksResume { try await client.releaseAcks() }
      let result = try await client.message("copy result") {
        if case .copyResult(_, 9, _, _) = $0 { true } else { false }
      }
      guard case let .copyResult(_, _, total, error) = result else { return }
      #expect(error == nil)
      #expect((total ?? 0) > 2 * ControlMessage.maxCopyChunkBytes)
      #expect(client.chunks(9) > 2)
      if !acksResume {
        // Acknowledgements never came: every chunk waited out the cap.
        #expect(
          ContinuousClock.now - requested >= RoamingSession.copyScreenWait
            * client.chunks(9)
        )
      }
      try await client.releaseAcks()
    }
  }

  /// spec.roaming.md §7.5: one chunk in flight. Each chunk is followed by
  /// a ping, and the next waits for the pong that proves the client read
  /// it; a transport accepting more than a chunk ahead (QUIC buffered about
  /// a second's worth) otherwise put typing's acknowledgement behind it.
  @Test
  func `the next copy chunk waits for the client to read the last`()
    async throws
  {
    try await withRegistry { registry in
      let grant = try await registry.create(
        grid: GridSize(columns: 200, rows: 8)
      )
      let client = FrameClient(registry)
      defer { client.connection.close() }
      _ = try await client.attached(grant)
      _ = try await client.frame("prompt") {
        $0.lines.contains { $0.contains("$") }
      }
      try await client.send(
        Self.input(
          1,
          .committedText(
            "i=0; while [ $i -lt 700 ]; do printf '%0190d\\n' $i; i=$((i+1)); done; echo done-mark"
          )
        )
      )
      try await client.send(Self.input(2, .key(SemanticKey(.enter))))
      let frame = try await client.frame("output") {
        $0.lines.contains("done-mark")
      }
      let h = frame.history
      let done = try #require(frame.lines.firstIndex(of: "done-mark"))
      client.ignorePings.store(true, ordering: .releasing)
      try await client.send(
        .copySelection(
          .init(
            attachmentEpoch: 1,
            requestID: 5,
            generation: h.generation,
            alternateScreen: false,
            startRow: UInt64(h.firstRow),
            startColumn: 0,
            endRow: UInt64(h.viewportTop + done),
            endColumn: 199,
            unit: .character,
            screenRowVersions: []
          )
        )
      )
      _ = try await client.message("first chunk") {
        if case .copyChunk(_, 5, 0, _) = $0 { true } else { false }
      }
      try await Task.sleep(for: .milliseconds(600))
      #expect(
        client.chunks(5) == 1,
        "a chunk was sent before the last was read"
      )
      // The pong for the ping behind chunk 0 releases chunk 1 at once.
      let ping = try await client.message("ping after the chunk") {
        if case .ping = $0 { true } else { false }
      }
      guard case let .ping(epoch, nonce) = ping else { return }
      client.ignorePings.store(false, ordering: .releasing)
      let answered = ContinuousClock.now
      try await client.send(.pong(epoch: epoch, nonce: nonce))
      _ = try await client.message("second chunk") {
        if case .copyChunk(_, 5, 1, _) = $0 { true } else { false }
      }
      #expect(ContinuousClock.now - answered < RoamingSession.copyDeliveryWait)
      let result = try await client.message("copy result") {
        if case .copyResult(_, 5, _, _) = $0 { true } else { false }
      }
      guard case let .copyResult(_, _, _, error) = result else { return }
      #expect(error == nil)
      #expect(client.chunks(5) > 2)
    }
  }

  @Test
  func `worker frames are clipped to the rst grid with placeholder graphemes`()
    throws
  {
    var state = TerminalState(columns: 210, rows: 82)
    var parser = Parser()
    let text = "e" + String(repeating: "\u{301}", count: 80) + "\u{1B}[1;209H中"
    let bytes = Array(text.utf8)
    bytes.withUnsafeBufferPointer {
      parser.consume(Span(_unsafeElements: $0), into: &state)
    }
    var limits = MuxLimits.standard
    limits.maxGraphemeScalars = 128
    let worker = try FrameExporter.frame(
      from: state.captureOwnedWindow(top: nil),
      identity: .unbound,
      limits: limits
    )
    let (frame, header) = try #require(
      ScreenExporter.frame(
        from: worker,
        stamp: ScreenExporter.Stamp(sessionID: .random(), screenRevision: 4)
      )
    )
    #expect(frame.grid.columns == RSTLimits.maxColumns)
    #expect(frame.grid.rows == RSTLimits.maxRows)
    #expect(frame.identity == header.frameIdentity)
    #expect(frame.graphemes.isEmpty)
    #expect(
      frame.grid.glyph(at: 0)
        == RSTLimits.graphemePlaceholder.unicodeScalars.first!.value
    )
    try FrameValidator.validate(frame, limits: SnapshotFrame.frameLimits)
  }
}
#endif
