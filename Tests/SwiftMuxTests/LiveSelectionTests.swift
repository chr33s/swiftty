import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
import SwiftMuxService
import Testing

/// Deltas and live selection through a real service (gates C11, C12).
@Suite(.serialized, .timeLimit(.minutes(1)))
struct LiveSelectionTests {
  func create(_ c: MuxConnection) async throws -> (WorkspaceID, PaneID) {
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      )
    else { throw MuxError(.invalidRequest, "no workspace") }
    return (ws.id, ws.tabs[0].activePane)
  }

  @Test(arguments: [true, false])
  func typingArrivesAsAppliedDeltas(binary: Bool) async throws {
    let h = try Harness()
    var capabilities = ClientCapabilities.supported
    if !binary { capabilities.remove(.binaryFrames) }
    let c = try await MuxConnection.connect(
      endpoint: h.endpoint,
      frontend: .native,
      capabilities: capabilities
    )
    let (ws, pane) = try await create(c)
    try await c.attachAndShow(.id(ws), columns: 60, rows: 12)
    _ = try await c.frame(of: pane) { $0.lines.contains { $0.hasPrefix("$") } }
    for word in ["alpha", "beta", "gamma"] {
      try await c.send(.text("echo \(word)\r"), to: pane)
      let frame = try await c.frame(of: pane) { $0.lines.contains(word) }
      #expect(frame.rowVersions?.count == 12)
      try FrameValidator.validate(frame)
    }
    let stats = await c.deltaStatistics
    #expect(stats.applied > 0)
    #expect(stats.requestedFull == 0)
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
  }

  @Test
  func copySpansHistoryTheClientNeverFetched() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    try await c.attachAndShow(.id(ws), columns: 40, rows: 8)
    try await c.send(.text("seq 1 300; echo done-mark\r"), to: pane)
    let frame = try await c.frame(of: pane) { $0.lines.contains("done-mark") }
    let h0 = frame.history
    let first = SelectionPoint(
      address: HistoryAddress(
        generation: h0.generation,
        alternateScreen: false,
        row: h0.firstRow
      ),
      column: 0
    )
    let doneRow = try #require(frame.lines.firstIndex(of: "done-mark"))
    let last = SelectionPoint(
      address: h0.address(viewportRow: doneRow, alternateScreen: false),
      column: 39
    )
    let screenRows = (h0.viewportTop ... h0.viewportTop + doneRow)
      .compactMap { row in frame.rowIdentity(row - h0.viewportTop) }
    guard
      case let .copied(text) = try await c.execute(
        .copySelection(
          CopySelectionRequest(
            pane: pane,
            start: first,
            end: last,
            unit: .character,
            screenRowVersions: screenRows
          )
        )
      )
    else { throw MuxError(.invalidRequest, "copy reply") }
    let lines = text.split(separator: "\n").map(String.init)
    #expect(lines.contains("1"))
    #expect(lines.contains("150"))
    #expect(lines.contains("300"))
    #expect(lines.last == "done-mark")
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
  }

  @Test
  func changedOrStaleRowsRefuseToCopy() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    try await c.attachAndShow(.id(ws), columns: 40, rows: 8)
    try await c.send(.text("printf 'keep\\nedit-me\\n'\r"), to: pane)
    let frame = try await c.frame(of: pane) {
      $0.lines.contains { $0.hasPrefix("edit-me") }
    }
    let y = try #require(frame.lines.firstIndex { $0.hasPrefix("edit-me") })
    let identity = try #require(frame.rowIdentity(y))
    func copy(
      _ versions: [RowIdentity],
      generation: UInt64? = nil
    ) async throws -> MuxReply {
      var address = identity.address
      if let generation { address.generation = generation }
      return try await c.execute(
        .copySelection(
          CopySelectionRequest(
            pane: pane,
            start: SelectionPoint(address: address, column: 0),
            end: SelectionPoint(address: address, column: 6),
            unit: .character,
            screenRowVersions: versions
          )
        )
      )
    }
    #expect(try await copy([identity]) == .copied("edit-me"))
    var wrong = identity
    wrong.version &+= 1000
    await #expect { try await copy([wrong]) } throws: {
      ($0 as? MuxError)?.code == .selectionChanged
    }
    await #expect {
      try await copy([identity], generation: identity.address.generation + 7)
    } throws: { ($0 as? MuxError)?.code == .historyUnavailable }
    // An in-place edit of the row the client saw: from the output row,
    // up past the command line to `edit-me`.
    try await c.send(.text("printf '\\033[2A\\rEDITED!\\n\\n'\r"), to: pane)
    let edited = try await c.frame(of: pane) {
      $0.lines.indices.contains(y) && $0.lines[y].hasPrefix("EDITED!")
    }
    #expect(edited.rowIdentity(y) != identity)
    await #expect { try await copy([identity]) } throws: {
      ($0 as? MuxError)?.code == .selectionChanged
    }
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
  }

  @Test
  func observersCopyWithTheirOwnRowVersions() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    try await c.attachAndShow(.id(ws), columns: 40, rows: 8)
    try await c.send(.text("echo observed-text\r"), to: pane)
    _ = try await c.frame(of: pane) { $0.lines.contains("observed-text") }
    let observer = try await h.connect()
    guard
      case .attached = try await observer.execute(
        .attach(AttachRequest(.id(ws), role: .observer))
      )
    else { throw MuxError(.invalidRequest, "observe") }
    try await observer.execute(.setSubscriptions([pane]))
    let seen = try await observer.frame(of: pane) {
      $0.lines.contains("observed-text")
    }
    let y = try #require(seen.lines.firstIndex(of: "observed-text"))
    let identity = try #require(seen.rowIdentity(y))
    let reply = try await observer.execute(
      .copySelection(
        CopySelectionRequest(
          pane: pane,
          start: SelectionPoint(address: identity.address, column: 0),
          end: SelectionPoint(address: identity.address, column: 2),
          unit: .word,
          screenRowVersions: [identity]
        )
      )
    )
    #expect(reply == .copied("observed-text"))
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
    await observer.close()
  }
}
