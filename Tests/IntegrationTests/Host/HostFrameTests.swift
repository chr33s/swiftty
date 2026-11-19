#if os(macOS)
import Foundation
import RoamingKit
import ScreenProtocol
import SessionCore
import SwiftMuxProtocol
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

    init(_ registry: SessionRegistry) {
      let (client, server) = InMemoryRSTConnection.pair()
      connection = client
      registry.accept(server)
      client.start(
        RSTConnectionHandler(
          onControl: { [self] bytes in
            state.withLock { s in
              if let messages = try? s.reader.append(bytes) {
                s.messages += messages
              }
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
      // As RoamingClient: a refused delta is acknowledged, so its stream
      // retires, and a complete screen is requested after it.
      try? await send(
        .screenAck(
          epoch: header.attachmentEpoch,
          screenRevision: header.screenRevision
        )
      )
      if refused {
        try? await send(.requestFullScreen(epoch: header.attachmentEpoch))
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
}
#endif
