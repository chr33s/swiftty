import Foundation
import SwiftMuxBridge
import SwiftMuxClient
import SwiftMuxExport
import SwiftMuxProtocol
import SwiftMuxService
@testable import SwiftMuxTerminal
import TTYKit
import SwifttyCore
import Testing

/// Regression tests for the frame, delta and live-selection review.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ReviewFixTests {
  // MARK: Malformed history windows

  @Test
  func `history windows beyond the row bound are rejected without trapping`()
    throws
  {
    var e = FrameDeltaTests.Exporter()
    e.feed("a\r\nb\r\nc")
    let base = try e.frame()
    e.feed("d")
    let next = try e.frame()
    for field in 0 ..< 5 {
      var frame = next
      switch field {
      case 0: frame.history.viewportTop = Int.max
      case 1: frame.history.firstRow = Int.max
      case 2: frame.history.availableRows = Int.max
      case 3: frame.history.viewportOffset = -1
      default: frame.history.scrollbackRows = Int.max
      }
      #expect(throws: MuxError.self) { try FrameValidator.validate(frame) }
      #expect(throws: MuxError.self) { try SMXB.decode(SMXB.encode(frame)) }
    }
    let baseline = try #require(FrameBaseline(base))
    var delta = try #require(
      FrameDeltaBuilder.delta(from: next, base: baseline)
    )
    delta.history.viewportTop = Int.max
    #expect(throws: MuxError.self) {
      try FrameDeltaApplier.apply(delta, to: base)
    }
  }

  // MARK: Row versions

  @Test
  func `separate trackers never reissue a version`() throws {
    let session = TerminalSession(columns: 20, rows: 6)
    session.feed(Array("one\r\ntwo\r\n".utf8))
    let owned = session.withState { $0.captureOwnedScreen() }
    var first = RowVersionTracker()
    var second = RowVersionTracker()
    let a = first.stamp(owned)
    let b = second.stamp(owned)
    #expect(Set(a).isDisjoint(with: Set(b)))
  }

  @Test
  func `the tracker stays bounded while output streams`() throws {
    let session = TerminalSession(columns: 200, rows: 24)
    var tracker = RowVersionTracker()
    for n in 0 ..< 2_000 {
      session.feed(
        Array("line \(n) \(String(repeating: "x", count: 150))\r\n".utf8)
      )
      _ = tracker.stamp(session.withState { $0.captureOwnedScreen() })
    }
    // Content is kept for the screen and two screens above it at most.
    #expect(tracker.trackedRows.content <= 4 * 24)
  }

  // MARK: Service trackers and full-frame recovery

  func create(_ c: MuxConnection) async throws -> (WorkspaceID, PaneID) {
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      )
    else { throw MuxError(.invalidRequest, "no workspace") }
    return (ws.id, ws.tabs[0].activePane)
  }

  @Test
  func `observers coming and going keep the controller's row versions`()
    async throws
  {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    try await c.attachAndShow(.id(ws), columns: 40, rows: 8)
    try await c.send(.text("echo keep-me\r"), to: pane)
    let frame = try await c.frame(of: pane) { $0.lines.contains("keep-me") }
    let y = try #require(frame.lines.firstIndex(of: "keep-me"))
    let identity = try #require(frame.rowIdentity(y))
    // More attachments than the old wipe-everything bound of eight.
    for _ in 0 ..< 10 {
      let observer = try await h.connect()
      _ = try await observer.execute(
        .attach(AttachRequest(.id(ws), role: .observer))
      )
      try await observer.execute(.setSubscriptions([pane]))
      _ = try await observer.frame(of: pane) { $0.lines.contains("keep-me") }
      await observer.close()
    }
    let reply = try await c.execute(
      .copySelection(
        CopySelectionRequest(
          pane: pane,
          start: SelectionPoint(address: identity.address, column: 0),
          end: SelectionPoint(address: identity.address, column: 6),
          unit: .character,
          screenRowVersions: [identity]
        )
      )
    )
    #expect(reply == .copied("keep-me"))
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
  }

  @Test
  func `a refused delta recovers with one full frame`() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    try await c.attachAndShow(.id(ws), columns: 40, rows: 8)
    try await c.send(.text("echo before\r"), to: pane)
    _ = try await c.frame(of: pane) { $0.lines.contains("before") }
    await c.dropDeltaBasesForTesting()
    for word in ["one", "two", "three", "four"] {
      try await c.send(.text("echo \(word)-w\r"), to: pane)
      _ = try await c.frame(of: pane) { $0.lines.contains("\(word)-w") }
    }
    let stats = await c.deltaStatistics
    // The request itself releases the refused delta, so the service never
    // bases another delta on it.
    #expect(stats.requestedFull == 1)
    #expect(stats.applied > 0)
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
  }

  // MARK: TTY keyed diffing in copy mode

  @Test
  @MainActor
  func `copy mode keys rows with the palette it draws`() async throws {
    let h = try Harness()
    let connection = try await h.connect(.terminal)
    guard
      case let .created(ws) = try await connection.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      ),
      case let .attached(attachment, workspace) = try await connection.execute(
        .attach(AttachRequest(.id(ws.id)))
      )
    else {
      Issue.record("setup")
      return
    }
    let pane = ws.tabs[0].activePane
    let outer = try TerminalClientTests.Outer()
    let client = TerminalClient(
      connection: connection,
      attachment: attachment,
      workspace: workspace,
      limits: .standard,
      tty: RawTTY(input: outer.slave, output: outer.slave)
    )
    // Frames this test controls, in the client's own attachment.
    var e = FrameDeltaTests.Exporter(columns: 80, rows: 23)
    e.feed("\u{1B}[31mred text\u{1B}[0m\r\nplain\r\n")
    func frame(red: UInt32) throws -> PaneFrame {
      var f = try e.frame()
      f.identity.pane = pane
      f.identity.attachment = attachment
      f.palette.colors[1] = red
      return f
    }
    client.handle(.frame(try frame(red: 0xAA_0000)))
    var renderer = DiffRenderer()
    func draw() -> (keyed: [UInt8], unkeyed: [UInt8]) {
      let screen = client.compose()
      let out = (
        renderer.update(to: screen), renderer.update(to: screen, useKeys: false)
      )
      renderer.commit(screen)
      return out
    }
    _ = draw()
    client.feed(Array("\u{02}[".utf8))  // copy mode freezes this frame
    _ = draw()
    // The program changes its palette while copy mode shows the old one.
    client.handle(.frame(try frame(red: 0x00_00BB)))
    let frozen = draw()
    #expect(frozen.keyed == frozen.unkeyed)
    client.feed(Array("q".utf8))  // back to live rows in the new colors
    let live = draw()
    #expect(live.keyed == live.unkeyed)
    try await connection.execute(.endWorkspace(.id(ws.id)))
    await connection.close()
  }
}
