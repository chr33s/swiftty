import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
@testable import SwiftMuxService
import SwifttyJS
import Testing

/// Worker-side freeze (spec.durability.md §6, §7.2; MR6): automation raised
/// while frozen waits, then runs once after an abort.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct MigrationServiceTests {
  @Test
  func automationRaisedWhileFrozenRunsOnceAfterAbort() async throws {
    let h = try Harness()
    let c = try await h.connect()
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      )
    else { throw MuxError(.invalidRequest, "create") }
    let shown = try await c.attachAndShow(.id(ws.id))
    let pane = shown.tabs[0].activePane
    let frozen = AsyncStream<MuxError?>.makeStream()
    h.service.freezeForMigration(commandsIdle: { $0(true) }) {
      frozen.continuation.yield($0)
    }
    var it = frozen.stream.makeAsyncIterator()
    let error = await it.next()
    #expect(error == .some(nil))
    let action = try JSONDecoder()
      .decode(
        JavaScriptAction.self,
        from: Data(
          #"{"kind":"write","pane":"\#(pane.description)","text":"echo auto-$((20+3))\r"}"#
            .utf8
        )
      )
    h.service.onQueue { $0.handleAutomation(action) }
    // Typed input is refused and automation waits while frozen.
    await #expect(throws: MuxError.self) {
      try await c.send(.text("echo typed\r"), to: pane)
    }
    let early = try? await withTimeout(.milliseconds(800)) {
      try await c.frame(of: pane) { $0.lines.contains("auto-23") }
    }
    #expect(early == nil, "automation ran while frozen")
    let resumed = AsyncStream<Void>.makeStream()
    h.service.thawMigration { resumed.continuation.yield() }
    var r = resumed.stream.makeAsyncIterator()
    _ = await r.next()
    let ran = try await c.frame(of: pane) { $0.lines.contains("auto-23") }
    #expect(ran.lines.filter { $0 == "auto-23" }.count == 1)
    await c.close()
  }
}
