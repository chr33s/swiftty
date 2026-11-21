#if os(macOS)
import Foundation
@testable import RoamingKit
import ScreenProtocol
import SessionCore
import SwiftMuxProtocol
import SwifttyCore
import SwifttyEngine
@testable import TerminalHost
import Testing

/// A22 (spec.roaming.md §7.5, §13): `copySelection` across unfetched
/// history between a real host and a real `RoamingClient` over the A3
/// impaired path.
@Suite(.serialized, .timeLimit(.minutes(5)))
struct ImpairedCopySelectionTests {
  static let seeds: [UInt64] = [0xA22_0001, 0xA22_0002, 0xA22_0003]
  static let grid = GridSize(columns: 80, rows: 24)

  /// A selection from absolute row `start` to `end` of `frame`'s history
  /// addressing, carrying the versions of the screen rows it covers.
  static func request(
    _ frame: PaneFrame,
    rows: ClosedRange<Int>,
    endColumn: Int = 79
  ) -> CopySelectionRequest {
    let h = frame.history
    let screenTop = h.viewportTop + h.viewportOffset
    let versions = (0 ..< frame.grid.rows).compactMap { frame.rowIdentity($0) }
      .filter { $0.address.row >= screenTop && rows.contains($0.address.row) }
    func point(_ row: Int, _ column: Int) -> SelectionPoint {
      SelectionPoint(
        address: HistoryAddress(
          generation: h.generation,
          alternateScreen: false,
          row: row
        ),
        column: column
      )
    }
    return CopySelectionRequest(
      pane: PaneID(),
      start: point(rows.lowerBound, 0),
      end: point(rows.upperBound, endColumn),
      unit: .character,
      screenRowVersions: versions
    )
  }

  /// The newest installed frame with the absolute row of the line equal
  /// to `line`.
  static func frame(
    _ rig: some RoamingTestRig,
    showing line: String,
    where predicate: @escaping @Sendable ([String]) -> Bool = { _ in true }
  ) async throws -> (PaneFrame, row: Int) {
    try await hostEventuallyAsync("frame with \(line)") {
      guard let frame = await rig.client.currentPaneFrame,
        case let lines = frame.lines.map(Self.trimmed), predicate(lines),
        let y = lines.lastIndex(where: { $0.hasPrefix(line) })
      else { return nil }
      return (
        frame, frame.history.address(viewportRow: y, alternateScreen: false).row
      )
    }
  }

  static func trimmed(_ line: String) -> String {
    var line = line
    while line.last == " " { line.removeLast() }
    return line
  }

  static func expectFailure(
    _ code: RSTErrorCode,
    _ rig: some RoamingTestRig,
    _ request: CopySelectionRequest,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async throws {
    try await rig.active()
    do {
      let text = try await rig.client.copySelection(request)
      let copied =
        "\(text.utf8.count) bytes: \(text.prefix(80).debugDescription)"
      Issue.record(
        "\(rig.label): expected \(code), copied \(copied)",
        sourceLocation: sourceLocation
      )
    } catch let error as RoamingClient.CopyError {
      #expect(
        error.code == code,
        "\(rig.label)",
        sourceLocation: sourceLocation
      )
    }
  }

  @Test(arguments: seeds)
  func `history copy during output, edits and eviction`(
    seed: UInt64
  ) async throws {
    try await withRegistry { registry in
      let rig = ImpairedRoamingRig(
        registry: registry,
        seed: seed,
        profile: .a3,
        grid: Self.grid
      )
      try await rig.start(Self.grid)
      try await rig.run("seq -f 'row %06g' 1 6000; echo mark-$((1+2))")
      let (marked, markRow) = try await Self.frame(rig, showing: "mark-3")
      let h = marked.history
      // From the oldest retained row, which the client never received, to
      // the marker on its screen.
      let selection = Self.request(marked, rows: h.firstRow ... markRow)

      // Output keeps running while the copy crosses the impaired path.
      try await rig.run(
        "(i=0; while [ $i -lt 150 ]; do i=$((i+1)); echo tick-$i; "
          + "sleep 0.02; done; echo tock-$((2+5))) &"
      )
      try await rig.shows("tick-")
      let text = try await rig.client.copySelection(selection)
      let host = try await rig.hostText(
        from: TerminalPoint(row: h.firstRow, column: 0),
        to: TerminalPoint(row: markRow, column: 79)
      )
      #expect(text == host, "seed \(seed)")
      let seq = (1 ... 6000).map { "row " + String(format: "%06d", $0) }
        .joined(separator: "\n")
      #expect(text.hasSuffix(seq + "\nmark-3"), "seed \(seed)")
      #expect(
        text.utf8.count > ControlMessage.maxCopyChunkBytes,
        "more than one chunk"
      )
      try await rig.shows("tock-7")

      // An edit under the selection: the row the client saw changed.
      try await rig.run("echo calm-$((3+3))")
      // The finished output and the empty prompt below it.
      let (calm, calmRow) = try await Self.frame(rig, showing: "$") { lines in
        lines.contains("calm-6") && lines.last(where: { !$0.isEmpty }) == "$"
      }
      let prompt = calmRow
      let edited = Self.request(calm, rows: prompt - 1 ... prompt)
      try await rig.submit(.text("echo edited-x"))
      try await rig.shows("$ echo edited-x")
      try await Self.expectFailure(.selectionChanged, rig, edited)
      try await rig.submit(.key(SemanticKey(.enter)))

      // Eviction: the selection's rows leave the bounded history.
      let (oldest, _) = try await Self.frame(rig, showing: "edited-x")
      let first = oldest.history.firstRow
      let evicted = Self.request(oldest, rows: first ... first + 5)
      try await rig.run("seq 1 10500; echo evict-$((4+4))")
      try await rig.shows("evict-8")
      try await Self.expectFailure(.historyUnavailable, rig, evicted)

      // Failures carried no text: no chunk for a failed request.
      let failed = Set(
        rig.link.messages(.toClient)
          .compactMap { m -> UInt64? in
            if case let .copyResult(_, id, _, error?) = m, error != .busy {
              return id
            }
            return nil
          }
      )
      #expect(failed.count == 2)
      #expect(
        !rig.link.messages(.toClient)
          .contains {
            if case let .copyChunk(_, id, _, _) = $0 {
              failed.contains(id)
            } else {
              false
            }
          }
      )
      await rig.client.close(.detach)
    }
  }

  @Test(arguments: seeds)
  func `large copies, typing during a copy and reattachment mid-copy`(
    seed: UInt64
  ) async throws {
    try await withRegistry { registry in
      let display = TerminalSession(presentationColumns: 80, rows: 24)
      let rig = ImpairedRoamingRig(
        registry: registry,
        seed: seed,
        profile: .a3,
        grid: Self.grid,
        display: display
      )
      let client = rig.client
      display.remoteCopyHandler = { selection, done in
        Task { done(try? await client.copySelection(selection)) }
      }
      try await rig.start(Self.grid)
      let link = rig.link
      let row = String(repeating: "─", count: 79)

      // Escape-heavy text: every quote encodes as two bytes of JSON.
      try await rig.run(
        "head -c 120000 /dev/zero | tr '\\0' '\"' | fold -w 78; echo; "
          + "echo quotes-$((2+2))"
      )
      let (quoted, quotesRow) = try await Self.frame(rig, showing: "quotes-4")
      let quoteLines = 120_000 / 78 + 1
      let quotes = try await rig.client.copySelection(
        Self.request(quoted, rows: quotesRow - quoteLines ... quotesRow - 1)
      )
      let expectedQuotes =
        Array(repeating: String(repeating: "\"", count: 78), count: 1538)
        .joined(separator: "\n") + "\n" + String(repeating: "\"", count: 36)
      #expect(quotes == expectedQuotes, "seed \(seed)")

      // 9,500 rows of three-byte characters: over 2 MiB in all.
      try await rig.run(
        "awk 'BEGIN{s=\"\";for(i=0;i<79;i++)s=s\"─\";"
          + "for(n=0;n<9500;n++)print s}'; echo big-$((4+5))"
      )
      let (big, bigRow) = try await Self.frame(rig, showing: "big-9")
      try await Self.expectFailure(
        .limitExceeded,
        rig,
        Self.request(big, rows: bigRow - 9500 ... bigRow - 1)
      )

      // Just under 2 MiB, on a slow return path, with a key typed
      // mid-copy: its acknowledgement waits behind at most one chunk.
      let rows = bigRow - 8700 ... bigRow - 1
      let expected = Array(repeating: row, count: 8700).joined(separator: "\n")
      #expect(expected.utf8.count > 2_000_000)
      #expect(expected.utf8.count <= ControlMessage.maxCopyBytes)
      link.pace(.milliseconds(20))
      try await rig.active()
      let copy = Task {
        try await client.copySelection(Self.request(big, rows: rows))
      }
      try await hostEventually("copy under way") {
        link.messages(.toClient)
          .contains {
            if case .copyChunk(_, _, 2, _) = $0 { true } else { false }
          } ? true : nil
      }
      let typed = try await rig.submit(.text("t"))
      let text = try await copy.value
      link.pace(nil)
      #expect(text == expected, "seed \(seed)")
      let host = try await rig.hostText(
        from: TerminalPoint(row: rows.lowerBound, column: 0),
        to: TerminalPoint(row: rows.upperBound, column: 79)
      )
      #expect(text == host, "seed \(seed)")
      let log = link.control
      let input = log.firstIndex {
        if case let .input(i) = $0.message {
          i.sequence == typed
        } else {
          false
        }
      }
      let ack = log.firstIndex {
        if case let .inputAck(_, s) = $0.message, s >= typed {
          true
        } else {
          false
        }
      }
      let copyID = log.lazy
        .compactMap { event -> UInt64? in
          if case let .copyChunk(_, id, 2, _) = event.message {
            id
          } else {
            nil
          }
        }
        .last
      let result = log.firstIndex {
        if case let .copyResult(_, id, _, _) = $0.message {
          id == copyID
        } else {
          false
        }
      }
      let (i, a, r) = try (#require(input), #require(ack), #require(result))
      // Applied before the copy completed, and behind at most one chunk
      // queued ahead of it plus one sent while the PTY applied it.
      #expect(a < r, "seed \(seed): input ack \(a) after copy result \(r)")
      let between = log[i ..< a]
        .filter { if case .copyChunk = $0.message { true } else { false } }
        .count
      #expect(between <= 2, "seed \(seed): \(between) chunks ahead of input")
      try await rig.submit(.key(SemanticKey(.backspace)))

      // Reattachment mid-copy: partial text is discarded, never returned.
      link.pace(.milliseconds(2))
      link.killAt(.copyChunk(index: 3, afterForward: true))
      let connections = link.connections
      try await Self.expectFailure(
        .staleEpoch,
        rig,
        Self.request(big, rows: rows)
      )
      link.pace(nil)
      #expect(link.killed.contains(.copyChunk(index: 3, afterForward: true)))
      try await rig.active()
      #expect(link.connections > connections)
      // The same rows copy in full on the new attachment, with the row
      // versions it assigned (versions belong to an attachment).
      let current = try #require(await client.currentPaneFrame)
      #expect(
        try await client.copySelection(Self.request(current, rows: rows))
          == expected,
        "seed \(seed)"
      )

      // Through the display: a selection beyond the shown rows, copied
      // from the host and cut off by reattachment, writes nothing.
      try await rig.run("echo last-$((5+5))")
      try await rig.shows("last-10")
      try await hostEventually("display caught up") {
        display.withState { $0.screenLines }
          .contains { $0.hasPrefix("last-10") } ? true : nil
      }
      display.mutate { state in
        state.setSelection(
          Selection(
            anchor: state.viewportPoint(row: 0, column: 0),
            head: state.viewportPoint(row: state.rows - 1, column: 79)
          )
        )
      }
      try await ImpairedScreenDeltaTests.until(rig, "selection beyond view") {
        await client.scrollViewport(by: 3)
      } where: { _ in
        display.withState { $0.presentationSelectionBeyondView } != nil
      }
      link.killAt(.copyChunk(index: 0, afterForward: false))
      let written: String? = await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
          display.copySelectedText { continuation.resume(returning: $0) }
        }
      }
      #expect(written == nil, "seed \(seed)")
      #expect(link.killed.contains(.copyChunk(index: 0, afterForward: false)))
      _ = rig.expectInstallsMatchHost()
      await client.close(.detach)
    }
  }
}
#endif
