import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
@testable import SwiftMuxService
import Testing

/// Compressed pane history seen by a controller and independent viewers.
extension SwiftMuxExtensionTests {
  @Test
  func distantObserversReadCompressedHistoryWithoutDisturbingTheController()
    async throws
  {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    try await c.attachAndShow(.id(ws), columns: 40, rows: 8)
    try await c.send(
      .text(
        "i=0; while [ $i -lt 3000 ]; do echo row-$i; i=$((i+1)); done; "
          + "echo TAIL-MARK\r"
      ),
      to: pane
    )
    let live = try await c.frame(of: pane, timeout: .seconds(30), label: "tail")
    { $0.lines.contains("TAIL-MARK") }
    // The shell's prompt follows TAIL-MARK; let the controller settle so the
    // quiet check below sees only frames caused by observers or compression.
    while (try? await c.frame(
      of: pane,
      timeout: .milliseconds(300),
      label: "settle"
    ) { _ in true }) != nil {}
    let a = try await observe(h, ws, panes: [pane])
    let b = try await observe(h, ws, panes: [pane])
    try await a.execute(.scroll(pane: pane, .lines(2_700)))
    try await b.execute(.scroll(pane: pane, .lines(1_200)))
    func rows(_ frame: PaneFrame) -> [Int] {
      frame.lines.compactMap { line in
        line.hasPrefix("row-") ? Int(line.dropFirst(4)) : nil
      }
    }
    let far = try await a.frame(of: pane, label: "a-far") {
      $0.history.viewportOffset > 2_000
    }
    let mid = try await b.frame(of: pane, label: "b-mid") {
      $0.history.viewportOffset > 1_000 && $0.history.viewportOffset < 2_000
    }
    #expect(!rows(far).isEmpty && rows(mid).min()! > rows(far).max()!)

    let runtime = try #require(await h.service.runtime(pane))
    let stats = runtime.compressScrollbackForTesting()
    #expect(stats.compressedUnits > 0)
    #expect(stats.protectedUnitBytes > 0)
    // Compression alone publishes nothing to the controller.
    let unexpected = try? await c.frame(
      of: pane,
      timeout: .milliseconds(300),
      label: "quiet"
    ) { _ in true }
    #expect(unexpected == nil)

    // Each observer moves one line within compressed history; its window
    // shifts by exactly that line and the other windows are unaffected.
    try await a.execute(.scroll(pane: pane, .lines(-1)))
    let farNext = try await a.frame(of: pane, label: "a-next") {
      $0.history.viewportOffset == far.history.viewportOffset - 1
    }
    #expect(Array(farNext.lines.prefix(7)) == Array(far.lines.dropFirst()))
    try await b.execute(.scroll(pane: pane, .lines(1)))
    let midNext = try await b.frame(of: pane, label: "b-next") {
      $0.history.viewportOffset == mid.history.viewportOffset + 1
    }
    #expect(Array(midNext.lines.dropFirst()) == Array(mid.lines.prefix(7)))
    #expect(runtime.scrollbackStatistics.restores <= 4)

    // An observer's search scans compressed history in place, finds a far
    // row, and leaves the other observer's window and the controller alone.
    let restoresBeforeSearch = runtime.scrollbackStatistics.restores
    guard
      case let .search(found) = try await b.execute(
        .search(pane: pane, query: "row-17")
      )
    else { throw MuxError(.invalidRequest, "search") }
    #expect(found.matchCount >= 111)  // row-17, row-170…179, row-1700…1799
    let scan = runtime.scrollbackStatistics
    #expect(scan.scanDecodes > 0)
    #expect(scan.restores - restoresBeforeSearch <= 8)
    try await a.execute(.scroll(pane: pane, .lines(1)))
    let farBack = try await a.frame(of: pane, label: "a-back") {
      $0.history.viewportOffset == far.history.viewportOffset
    }
    #expect(farBack.lines == far.lines)
    #expect(farBack.search == nil || farBack.search?.matchCount == 0)

    // The controller is still at live output with unchanged text.
    try await c.send(.text("echo AFTER-MARK\r"), to: pane)
    let after = try await c.frame(of: pane, label: "after") {
      $0.lines.contains("AFTER-MARK")
    }
    #expect(after.history.viewportOffset == 0)
    #expect(after.lines.contains("TAIL-MARK") || live.lines.count == 8)
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
    await a.close()
    await b.close()
  }
}
