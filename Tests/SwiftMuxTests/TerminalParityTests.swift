import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
@testable import SwiftMuxService
import Testing

/// Features the direct terminal view had that the service now provides to
/// workspace panes: mouse reports, history jumps, clear and reset, links,
/// command output and click-to-move.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct TerminalParityTests {
  private func create(
    _ c: MuxConnection,
    _ script: String
  ) async throws -> (WorkspaceSnapshot, PaneID) {
    var launch = shellLaunch()
    launch.command = ["/bin/sh", "-c", script]
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: launch))
      )
    else { throw MuxError(.invalidRequest, "create") }
    try await c.attachAndShow(.id(ws.id))
    return (ws, ws.tabs[0].activePane)
  }

  /// Prompts P1…P3 (OSC 133 A), each followed by marked output 1…40.
  // Every iteration ends in "40", so the title (invisible on screen) marks
  // when all output has arrived; slow runners can otherwise act mid-loop.
  private static let prompts = """
    for p in 1 2 3; do printf '\\033]133;A\\007P%s\\n\\033]133;C\\007' $p; \
    seq 1 40; done; printf '\\033]2;\(promptsDone)\\007'; exec sleep 30
    """
  private static let promptsDone = "prompts-done"

  @Test
  func welcomeListsTheFeatures() async throws {
    let h = try Harness()
    let c = try await h.connect()
    #expect(await c.welcome?.features == .supported)
  }

  @Test
  func mouseReportsReachTheProgramOnlyWhileItTracks() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (_, pane) = try await create(
      c,
      """
      stty raw -echo; printf 'READY\\033[?1000h\\033[?1006h'; \
      dd bs=1 count=9 2>/dev/null | od -An -c; exec sleep 30
      """
    )
    let ready = try await c.frame(of: pane, label: "tracking") {
      $0.modes.contains(.mouseTracking) && $0.text(row: 0).contains("READY")
    }
    #expect(!ready.modes.contains(.mouseAnyMotion))
    try await c.send(
      .mouse(MuxMouse(.press, .left, column: 0, row: 0)),
      to: pane
    )
    _ = try await c.frame(of: pane, label: "report") {
      $0.lines.joined().contains("<   0   ;   1   ;   1   M")
    }
  }

  @Test
  func mouseInputIsDroppedWithoutTracking() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (_, pane) = try await create(
      c,
      "stty raw -echo; printf 'READY'; dd bs=1 count=1 2>/dev/null | od -An -c; exec sleep 30"
    )
    _ = try await c.frame(of: pane) { $0.text(row: 0).contains("READY") }
    try await c.send(
      .mouse(MuxMouse(.press, .left, column: 0, row: 0)),
      to: pane
    )
    try await c.send(.text("z"), to: pane)
    // The first byte the program reads is the text, not a report.
    _ = try await c.frame(of: pane, label: "text") {
      $0.lines.joined().contains("z")
    }
  }

  @Test
  func promptJumpsAndOldestMoveTheViewport() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (_, pane) = try await create(c, Self.prompts)
    _ = try await c.frame(of: pane) {
      $0.title == Self.promptsDone && $0.lines.contains("40")
    }
    try await c.execute(.scroll(pane: pane, .prompt(-1)))
    _ = try await c.frame(of: pane, label: "P3") { $0.text(row: 0) == "P3" }
    try await c.execute(.scroll(pane: pane, .prompt(-1)))
    _ = try await c.frame(of: pane, label: "P2") { $0.text(row: 0) == "P2" }
    try await c.execute(.scroll(pane: pane, .prompt(1)))
    _ = try await c.frame(of: pane, label: "P3 again") {
      $0.text(row: 0) == "P3"
    }
    try await c.execute(.scroll(pane: pane, .oldest))
    _ = try await c.frame(of: pane, label: "oldest") {
      $0.text(row: 0) == "P1" && $0.history.viewportTop == $0.history.firstRow
    }
    // Nothing above the first prompt.
    await #expect(throws: MuxError.self) {
      try await c.execute(.scroll(pane: pane, .prompt(-1)))
    }
  }

  @Test
  func commandOutputIsFoundAndShown() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (_, pane) = try await create(c, Self.prompts)
    let live = try await c.frame(of: pane) {
      $0.title == Self.promptsDone && $0.lines.contains("40")
    }
    guard
      case let .commandOutput(found?) = try await c.execute(
        .commandOutput(pane: pane, at: nil)
      )
    else { throw MuxError(.notFound, "no output") }
    #expect(found.text == (1 ... 40).map(String.init).joined(separator: "\n"))
    #expect(found.end.row - found.start.row == 39)
    #expect(found.start.generation == live.history.generation)
    // Scrolled so the output's first row shows.
    _ = try await c.frame(of: pane, label: "shown") { frame in
      let top = frame.history.viewportTop
      return (top ..< top + frame.grid.rows).contains(found.start.row)
    }
  }

  @Test
  func linksAreFoundAtACell() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (_, pane) = try await create(
      c,
      """
      printf 'see https://example.com/x now\\n'; \
      printf '\\033]8;;https://example.org/y\\033\\\\label\\033]8;;\\033\\\\\\n'; \
      exec sleep 30
      """
    )
    let frame = try await c.frame(of: pane) { $0.text(row: 1) == "label" }
    let row0 = frame.history.address(viewportRow: 0, alternateScreen: false)
    let row1 = frame.history.address(viewportRow: 1, alternateScreen: false)
    func link(
      _ at: HistoryAddress,
      _ column: Int,
      detect: Bool = true
    ) async throws -> MuxLink? {
      guard
        case let .link(link) = try await c.execute(
          .link(pane: pane, at: at, column: column, detectURLs: detect)
        )
      else { throw MuxError(.invalidRequest, "link reply") }
      return link
    }
    let detected = try await link(row0, 8)
    #expect(detected?.url == "https://example.com/x")
    #expect(detected?.startColumn == 4)
    #expect(detected?.endColumn == 24)
    #expect(try await link(row0, 8, detect: false) == nil)
    #expect(try await link(row0, 1) == nil)
    #expect(
      try await link(row1, 2, detect: false)?.url == "https://example.org/y"
    )
    // A stale address finds nothing.
    var stale = row0
    stale.generation &+= 1
    #expect(try await link(stale, 8) == nil)
  }

  @Test
  func clickToMoveSendsArrowsOnlyWithinTheCommandLine() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (_, pane) = try await create(
      c,
      """
      stty raw -echo; \
      printf '\\033]133;A\\007$ \\033]133;B\\007abc'; \
      dd bs=1 count=6 2>/dev/null | od -An -c; exec sleep 30
      """
    )
    let frame = try await c.frame(of: pane) { $0.text(row: 0) == "$ abc" }
    let row = frame.history.address(viewportRow: 0, alternateScreen: false)
    // Before the input start: nothing is written.
    try await c.send(.moveCursor(row, column: 0), to: pane)
    try await c.send(.moveCursor(row, column: 3), to: pane)
    _ = try await c.frame(of: pane, label: "arrows") {
      $0.lines.joined().contains("033   [   D 033   [   D")
    }
  }

  @Test
  func clearAndResetKeepTheProcess() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (_, pane) = try await create(c, Self.prompts)
    let before = try await c.frame(of: pane) {
      $0.title == Self.promptsDone && $0.lines.contains("40")
    }
    try await c.execute(.clearScreen(pane))
    _ = try await c.frame(of: pane, label: "cleared") { frame in
      frame.lines.filter { !$0.isEmpty }.count <= 1
    }
    try await c.execute(.resetTerminal(pane))
    _ = try await c.frame(of: pane, label: "reset") { frame in
      frame.history.generation != before.history.generation
        && frame.history.scrollbackRows == 0
    }
    let runtime = try #require(await h.service.runtime(pane))
    #expect(runtime.pid > 0)
  }
}
