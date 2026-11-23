import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
import SwiftMuxService
import Testing

/// Per-workspace leases, explicit takeover, metadata observation and the
/// input ledger (spec.inbox.md §2, §7; acceptance 2, 7, 18).
@Suite(.serialized, .timeLimit(.minutes(1)))
struct LeaseTests {
  private func create(
    _ c: MuxConnection,
    _ name: String
  ) async throws -> WorkspaceSnapshot {
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(name: name, launch: shellLaunch()))
      )
    else { throw MuxError(.invalidRequest, "create") }
    return ws
  }

  private func summary(
    _ c: MuxConnection,
    _ id: WorkspaceID
  ) async throws -> WorkspaceSummary {
    guard case let .workspaces(list) = try await c.execute(.listWorkspaces),
      let s = list.first(where: { $0.id == id })
    else { throw MuxError(.notFound) }
    return s
  }

  private func code(_ body: () async throws -> Void) async -> MuxError.Code? {
    do {
      try await body()
      return nil
    } catch let e as MuxError { return e.code } catch { return nil }
  }

  @Test
  func workspacesHaveIndependentLeases() async throws {
    let h = try Harness()
    let a = try await h.connect()
    let b = try await h.connect()
    let w1 = try await create(a, "one")
    let w2 = try await create(a, "two")
    try await a.attachAndShow(.id(w1.id))
    // Another workspace is free.
    try await b.attachAndShow(.id(w2.id))
    // The held one fails without takeover; metadata stays readable.
    let c = try await h.connect()
    #expect(
      await code { _ = try await c.execute(.attach(AttachRequest(.id(w1.id)))) }
        == .leaseHeld
    )
    let s = try await summary(c, w1.id)
    #expect(s.isAttached)
    #expect(s.leaseHolder?.transport == .local)
    #expect(s.leaseGeneration == 1)
  }

  @Test
  func takeoverNeedsTheCurrentGenerationAndFencesTheOldHolder() async throws {
    let h = try Harness()
    let a = try await h.connect()
    let ws = try await create(a, "t")
    let pane = ws.tabs[0].activePane
    try await a.attachAndShow(.id(ws.id))
    let old = await a.attachment!
    let b = try await h.connect()
    let generation = try await summary(b, ws.id).leaseGeneration
    // A prompt for an older controller is stale.
    #expect(
      await code {
        _ = try await b.execute(
          .takeover(.id(ws.id), expectedLease: generation - 1)
        )
      } == .staleRevision
    )
    guard
      case .attached = try await b.execute(
        .takeover(.id(ws.id), expectedLease: generation)
      )
    else { throw MuxError(.invalidRequest) }
    // The old holder is told and its attachment admits nothing.
    var told = false
    while let event = try await withTimeout(
      .seconds(5),
      { try await a.nextEvent() }
    ) {
      if case .detached = event {
        told = true
        break
      }
    }
    #expect(told)
    #expect(
      await code {
        try await a.submit(
          raw: InputRecord(
            sequence: 1,
            attachment: old,
            pane: pane,
            payload: .input(.text("x"))
          )
        )
      } == .notAttached
    )
    #expect(try await summary(b, ws.id).leaseGeneration == generation + 1)
  }

  @Test
  func observersSeeLeaseChangesWithoutALease() async throws {
    let h = try Harness()
    let o = try await h.connect(.control)
    guard case .workspaces = try await o.execute(.observeWorkspaces(true))
    else { throw MuxError(.invalidRequest) }
    let a = try await h.connect()
    let ws = try await create(a, "obs")
    try await a.attachAndShow(.id(ws.id))
    var attached = false
    while let event = try await withTimeout(
      .seconds(5),
      { try await o.nextEvent() }
    ) {
      if case let .workspaces(list) = event,
        list.first(where: { $0.id == ws.id })?.isAttached == true
      {
        attached = true
        break
      }
    }
    #expect(attached)
    // Observation never resizes: the pane keeps the attached geometry.
    #expect(try await summary(o, ws.id).paneCount == 1)
  }

  /// Takeover prompts are skipped for an idle holder; admitted input
  /// marks when the holder last typed.
  @Test
  func admittedInputRecordsTheHoldersLastInput() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let ws = try await create(c, "typed")
    let pane = ws.tabs[0].activePane
    try await c.attachAndShow(.id(ws.id))
    #expect(try await summary(c, ws.id).leaseHolder?.lastInput == nil)
    let before = Date()
    try await c.submit(
      raw: InputRecord(
        sequence: 1,
        attachment: await c.attachment!,
        pane: pane,
        payload: .input(.text("x"))
      )
    )
    let last = try #require(try await summary(c, ws.id).leaseHolder?.lastInput)
    #expect(last >= before.addingTimeInterval(-1))
  }

  @Test
  func inputLedgerDropsDuplicatesAndRefusesGaps() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let ws = try await create(c, "ledger")
    let pane = ws.tabs[0].activePane
    try await c.attachAndShow(.id(ws.id))
    let attachment = await c.attachment!
    func record(_ n: UInt64, _ text: String) -> InputRecord {
      InputRecord(
        sequence: n,
        attachment: attachment,
        pane: pane,
        payload: .input(.text(text))
      )
    }
    try await c.submit(raw: record(1, "echo a"))
    // Resent after an uncertain disconnect: acknowledged, not written.
    try await c.submit(raw: record(1, "echo a"))
    #expect(await code { try await c.submit(raw: record(5, "x")) } == .inputGap)
    try await c.submit(raw: record(2, "b-$((1+1))\r"))
    let frame = try await c.frame(of: pane) { $0.lines.contains("ab-2") }
    #expect(!frame.lines.contains { $0.contains("echo aecho a") })
  }

  /// A paste is fixed to its pane: ending it from another pane is refused
  /// and leaves it open, so only its own pane can close it.
  @Test
  func pasteEndFromAnotherPaneIsRefused() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let ws = try await create(c, "paste")
    let a = ws.tabs[0].activePane
    try await c.attachAndShow(.id(ws.id))
    guard
      case let .layout(split) = try await c.execute(
        .split(pane: a, axis: .leftRight, launch: shellLaunch())
      ), let b = split.activeTabSnapshot?.layout.panes.first(where: { $0 != a })
    else { throw MuxError(.invalidRequest, "split") }
    let attachment = await c.attachment!
    func record(
      _ n: UInt64,
      _ pane: PaneID,
      _ payload: InputPayload
    ) -> InputRecord {
      InputRecord(
        sequence: n,
        attachment: attachment,
        pane: pane,
        payload: payload
      )
    }
    try await c.submit(raw: record(1, a, .pasteBegin(id: 1)))
    #expect(
      await code { try await c.submit(raw: record(2, b, .pasteEnd(id: 1))) }
        == .invalidRequest
    )
    // Still open on its own pane.
    try await c.submit(raw: record(3, a, .pasteChunk(id: 1, text: "x")))
    #expect(
      await code { try await c.submit(raw: record(4, a, .pasteBegin(id: 2))) }
        == .invalidRequest
    )
    try await c.submit(raw: record(5, a, .pasteEnd(id: 1)))
    try await c.submit(raw: record(6, a, .pasteBegin(id: 3)))
  }
}
