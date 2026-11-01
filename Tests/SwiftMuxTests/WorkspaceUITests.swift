import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
@testable import SwiftMuxService
import Testing

/// Pieces of the native workspace UI that live below AppKit: title
/// sanitizing, minimum split sizes and hidden-pane activity.
struct WorkspaceUITests {
  @Test
  func titlesAreSanitizedAndBounded() {
    #expect(DisplayText.sanitize("vim  main.swift") == "vim main.swift")
    // Controls, line breaks and bidi overrides never reach the chrome.
    #expect(DisplayText.sanitize("a\u{1b}[31mb\nc\td") == "a[31mb c d")
    #expect(DisplayText.sanitize("evil\u{202E}txt.exe") == "eviltxt.exe")
    #expect(DisplayText.sanitize("\u{200B}  lead  ") == "lead")
    #expect(DisplayText.sanitize("🐍 snake") == "🐍 snake")
    // Joiners and flag tags stay only where they shape an emoji.
    let family = "👨\u{200D}👩\u{200D}👧"
    let wales = "🏴\u{E0067}\u{E0062}\u{E0077}\u{E006C}\u{E0073}\u{E007F}"
    #expect(DisplayText.sanitize(family + wales) == family + wales)
    #expect(DisplayText.sanitize("\u{200D}a\u{200D} \u{200D}") == "a")
    #expect(DisplayText.sanitize("a\u{200D}b") == "ab")
    let rainbow = "🏳\u{FE0F}\u{200D}🌈"
    #expect(DisplayText.sanitize(rainbow) == rainbow)
    // Joining scripts keep their joiners.
    let persian = "می\u{200C}خواهم"
    #expect(DisplayText.sanitize(persian) == persian)
    #expect(DisplayText.sanitize("dev\u{E0041}\u{E007F}") == "dev")
    #expect(DisplayText.sanitize("🏴\u{E0067}") == "🏴")
    // Fillers and selectors that draw nothing are dropped; an emoji keeps
    // its presentation selector, a letter its accents.
    #expect(DisplayText.sanitize("a\u{3164}b\u{034F}") == "ab")
    #expect(DisplayText.sanitize("\u{FE0F}dev\u{FE0E}") == "dev")
    #expect(DisplayText.sanitize("❤\u{FE0F}") == "❤\u{FE0F}")
    #expect(DisplayText.sanitize("1\u{FE0F}\u{20E3}") == "1\u{FE0F}\u{20E3}")
    #expect(DisplayText.sanitize("build1\u{FE0F}") == "build1")
    #expect(DisplayText.sanitize("e\u{301}") == "e\u{301}")
    // One character joining many scalars cannot carry an unbounded title;
    // it shows as U+FFFD, which joins nothing around it.
    let chain = String(repeating: "👨\u{200D}", count: 500) + "👨"
    #expect(DisplayText.sanitize(chain) == "\u{FFFD}")
    let tags = "🏴" + String(repeating: "\u{E0061}", count: 5000) + "\u{E007F}"
    #expect(DisplayText.sanitize(tags) == "\u{FFFD}")
    let marks = String(repeating: "\u{301}", count: 31)
    let flags = "🇺🇸" + marks + "🇬🇧"
    #expect(DisplayText.sanitize(flags) == "\u{FFFD}🇬🇧")
    let jamo = "\u{1100}" + marks + "\u{301}\u{301}" + "\u{1161}" + marks
    let jamoShown = DisplayText.sanitize(jamo, limit: .max)
    #expect(jamoShown == "\u{FFFD}\u{1161}" + marks)
    #expect(DisplayText.isPlainName(jamoShown))
    // Names must be what every client shows.
    #expect(DisplayText.isPlainName(family + " " + wales))
    #expect(!DisplayText.isPlainName("\u{200D}"))
    #expect(!DisplayText.isPlainName("\u{FE0F}"))
    #expect(!DisplayText.isPlainName("a\u{200D}b"))
    #expect(DisplayText.plainName(" dev  api ") == "dev api")
    #expect(DisplayText.plainName(" \u{200B}") == nil)
    #expect(!DisplayText.isPlainName("dev\u{E0041}"))
    #expect(!DisplayText.isPlainName("a  b"))
    #expect(!DisplayText.isPlainName(" "))
    #expect(!DisplayText.isPlainName("a\u{00A0}b"))
    let long = DisplayText.sanitize(String(repeating: "x", count: 500))
    #expect(long.count == DisplayText.maxTitleCharacters)
    #expect(long.hasSuffix("…"))
  }

  /// The reference composition: a left stack of two panes beside one
  /// tall pane.
  static func reference() -> (LayoutNode, [PaneID]) {
    let (a, b, c) = (PaneID(), PaneID(), PaneID())
    let tree = LayoutNode.split(
      axis: .leftRight,
      ratio: 0.54,
      first: .split(
        axis: .topBottom,
        ratio: 0.47,
        first: .pane(a),
        second: .pane(b)
      ),
      second: .pane(c)
    )
    return (tree, [a, b, c])
  }

  @Test
  func referenceLayoutGeometry() {
    let (tree, ids) = Self.reference()
    let area = LayoutRect(x: 0, y: 0, width: 1000, height: 600)
    let frames = LayoutGeometry.frames(tree, in: area, divider: 4)
    let (a, b, c) = (frames[ids[0]]!, frames[ids[1]]!, frames[ids[2]]!)
    #expect(a.x == 0 && b.x == 0 && a.width == b.width)
    #expect(a.maxY < b.y && b.maxY == 600)
    #expect(c.x > a.maxX && c.height == 600 && c.maxX == 1000)
    #expect(abs(Double(a.width) / 996 - 0.54) < 0.01)
    #expect(
      LayoutGeometry.neighbor(
        of: ids[1],
        direction: .right,
        frames: frames,
        order: tree.panes
      ) == ids[2]
    )
    #expect(
      LayoutGeometry.neighbor(
        of: ids[2],
        direction: .left,
        frames: frames,
        order: tree.panes
      ) == ids[0]  // ties go to the pane overlapping the centre line
        || LayoutGeometry.neighbor(
          of: ids[2],
          direction: .left,
          frames: frames,
          order: tree.panes
        ) == ids[1]
    )
  }

  @Test
  func dividerRatiosKeepMinimumPaneSizes() {
    let (tree, _) = Self.reference()
    let area = LayoutRect(x: 0, y: 0, width: 1000, height: 600)
    let minimum = (columns: 100, rows: 50)
    #expect(
      LayoutGeometry.minimumExtent(
        tree,
        axis: .leftRight,
        pane: 100,
        divider: 4
      ) == 204
    )
    #expect(
      LayoutGeometry.minimumExtent(tree, axis: .topBottom, pane: 50, divider: 4)
        == 104
    )
    // Dragging the outer divider to an edge stops at the minimum.
    let left = LayoutGeometry.clampedRatio(
      0.01,
      at: [],
      of: tree,
      in: area,
      minimum: minimum,
      divider: 4
    )
    #expect(abs(left - 100.0 / 996) < 0.001)
    let right = LayoutGeometry.clampedRatio(
      0.99,
      at: [],
      of: tree,
      in: area,
      minimum: minimum,
      divider: 4
    )
    #expect(abs(right - (1 - 100.0 / 996)) < 0.001)
    // The nested split is clamped within its own (left) area.
    let inner = LayoutGeometry.clampedRatio(
      0.99,
      at: [false],
      of: tree,
      in: area,
      minimum: minimum,
      divider: 4
    )
    #expect(abs(inner - (1 - 50.0 / 596)) < 0.001)
    // Free ratios pass through unchanged.
    #expect(
      LayoutGeometry.clampedRatio(
        0.4,
        at: [],
        of: tree,
        in: area,
        minimum: minimum,
        divider: 4
      ) == 0.4
    )
  }

  @Test(.timeLimit(.minutes(1)), arguments: ["pane", "tab", "exit", "forced"])
  func endedPanesDoNotAccumulateActivityMarkers(_ removal: String) async throws
  {
    var limits = MuxLimits.standard
    limits.maxPanes = 3
    let h = try Harness(limits: limits)
    let c = try await h.connect()
    defer { Task { await c.close() } }
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      )
    else { throw MuxError(.invalidRequest, "unexpected reply") }
    let anchorTab = ws.tabs[0].id
    let anchor = ws.tabs[0].activePane
    try await c.attachAndShow(.id(ws.id))
    _ = try await c.frame(of: anchor) { $0.lines.first?.hasPrefix("$") == true }

    func hiddenPane() async throws -> (PaneID, TabID) {
      guard
        case let .layout(after) = try await c.execute(
          .newTab(name: nil, launch: shellLaunch())
        ), let tab = after.activeTabSnapshot
      else { throw MuxError(.invalidRequest, "unexpected reply") }
      let pane = tab.activePane
      try await c.execute(.setSubscriptions([pane]))
      _ = try await c.frame(of: pane) { $0.lines.first?.hasPrefix("$") == true }
      try await c.execute(.selectTab(anchorTab))
      try await c.execute(.setSubscriptions([anchor]))
      return (pane, tab.id)
    }

    func markActivity(_ pane: PaneID, ignoringHangup: Bool = false) async throws
    {
      let setup = ignoringHangup ? "trap '' HUP; " : ""
      try await c.send(.text(setup + "echo unseen-$((6*7))\r"), to: pane)
      let deadline = ContinuousClock.now + .seconds(2)
      while ContinuousClock.now < deadline,
        let event = try await c.nextEvent(
          timeout: deadline - ContinuousClock.now
        )
      {
        if case let .activity(id) = event, id == pane {
          if !ignoringHangup { return }
          // Input echo can report activity before the shell executes the
          // trap. Its evaluated output proves the handler is installed.
          while ContinuousClock.now < deadline {
            if await h.service.screenLines(pane)?
              .contains(where: { $0.contains("unseen-42") }) == true
            {
              return
            }
            try await Task.sleep(for: .milliseconds(10))
          }
          throw TimeoutError()
        }
      }
      throw TimeoutError()
    }

    let (keeper, _) = try await hiddenPane()
    try await markActivity(keeper)
    #expect(await h.service.activityMarkers(in: ws.id) == [keeper])
    for _ in 0 ..< 4 {
      let (pane, tab) = try await hiddenPane()
      try await markActivity(pane, ignoringHangup: removal == "forced")
      #expect(await h.service.activityMarkers(in: ws.id).contains(pane))
      let endedAt = ContinuousClock.now
      switch removal {
      case "pane", "forced": try await c.execute(.endPane(pane))
      case "tab": try await c.execute(.endTab(tab))
      default: try await c.send(.text("exit\r"), to: pane)
      }
      // Five seconds is the escalation grace, not the reaping bound.
      // Use the forced-termination fixture's bound and observe completion.
      let deadline = ContinuousClock.now + .seconds(8)
      var exited = false
      do {
        while ContinuousClock.now < deadline,
          let event = try await c.nextEvent(
            timeout: deadline - ContinuousClock.now
          )
        {
          if case let .paneExited(id, _, truncated) = event, id == pane {
            exited = true
            if removal == "forced" {
              #expect(truncated)
              #expect(ContinuousClock.now - endedAt >= .seconds(5))
            }
            break
          }
        }
      } catch {
        let termination = await h.service.terminationState(of: pane)
        Issue.record("Pane exit observation failed: \(termination)")
        throw error
      }
      #expect(exited)
      let remainingPID = await h.service.panePID(pane)
      let termination =
        remainingPID == nil
        ? "retired" : await h.service.terminationState(of: pane)
      #expect(remainingPID == nil, "\(termination)")
      // Four retired IDs exceed the three-live-pane cap. The other hidden
      // pane's existing marker must survive each targeted removal.
      let retained = await h.service.activityMarkers(in: ws.id)
      #expect(retained == [keeper])
    }
    try await c.execute(.endWorkspace(.id(ws.id)))
    await c.close()
  }

  /// Output arriving during a tab's subscription transition remains unseen
  /// when the former tab's subscription is removed.
  @Test(.timeLimit(.minutes(1)))
  func hiddenPaneTransitionOutputIsReportedAfterUnsubscription() async throws {
    let h = try Harness()
    let c = try await h.connect()
    defer { Task { await c.close() } }
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      )
    else { throw MuxError(.invalidRequest, "unexpected reply") }
    let firstTab = ws.tabs[0].id
    let pane = ws.tabs[0].activePane
    try await c.attachAndShow(.id(ws.id))
    _ = try await c.frame(of: pane) { $0.lines.first?.hasPrefix("$") == true }

    func activityUntilMarker(
      _ marker: String,
      in target: PaneID
    ) async throws -> [PaneID] {
      let deadline = ContinuousClock.now + .seconds(2)
      var reports: [PaneID] = []
      while ContinuousClock.now < deadline,
        let event = try await c.nextEvent(
          timeout: deadline - ContinuousClock.now
        )
      {
        if case let .activity(id) = event { reports.append(id) }
        if case let .frame(frame) = event, frame.identity.pane == target,
          frame.lines.contains(marker)
        {
          return reports
        }
      }
      throw TimeoutError()
    }

    try await c.send(.text("echo transition-$((3*7))\r"), to: pane)
    #expect(try await activityUntilMarker("transition-21", in: pane).isEmpty)
    guard
      case let .layout(after) = try await c.execute(
        .newTab(name: nil, launch: shellLaunch())
      )
    else { throw MuxError(.invalidRequest, "unexpected reply") }
    #expect(after.activeTab != firstTab)
    // Keep the former tab subscribed, as it is between layout delivery and
    // the frontend's next setSubscriptions command. A frame proves that
    // real hidden output has been processed, without a timing-only wait.
    try await c.send(.text("echo transition-$((6*7))\r"), to: pane)
    #expect(try await activityUntilMarker("transition-42", in: pane).isEmpty)
    try await c.send(.text("echo transition-$((9*7))\r"), to: pane)
    #expect(try await activityUntilMarker("transition-63", in: pane).isEmpty)
    let shown = try #require(after.activeTabSnapshot?.activePane)
    try await c.execute(.setSubscriptions([shown]))
    try await c.send(.text("echo transition-$((12*7))\r"), to: shown)
    let pending = try await activityUntilMarker("transition-84", in: shown)
    #expect(pending == [pane])
  }

  /// Output in a hidden tab is reported once, and again only after the
  /// pane has been shown.
  @Test(.timeLimit(.minutes(1)))
  func hiddenPaneActivityIsReportedOnce() async throws {
    let h = try Harness()
    let c = try await h.connect()
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      )
    else { throw MuxError(.invalidRequest, "unexpected reply") }
    let hidden = ws.tabs[0].activePane
    try await c.attachAndShow(.id(ws.id))
    _ = try await c.frame(of: hidden) { $0.lines.first?.hasPrefix("$") == true }
    guard
      case let .layout(after) = try await c.execute(
        .newTab(name: nil, launch: shellLaunch())
      )
    else { throw MuxError(.invalidRequest, "unexpected reply") }
    let shown = try #require(after.activeTabSnapshot?.activePane)
    try await c.execute(.setSubscriptions([shown]))
    try await c.send(
      .text("echo h1; sleep 0.2; echo h2; sleep 0.2; echo h3\r"),
      to: hidden
    )
    try await Task.sleep(for: .seconds(1))
    // Events are ordered: count reports until the visible pane's marker.
    try await c.send(.text("echo sentinel-$((1+1))\r"), to: shown)
    var reports = 0
    while let event = try await c.nextEvent() {
      if case let .activity(pane) = event {
        #expect(pane == hidden)
        reports += 1
      }
      if case let .frame(frame) = event, frame.identity.pane == shown,
        frame.lines.contains("sentinel-2")
      {
        break
      }
    }
    #expect(reports == 1)
    // Showing the pane resets the report.
    try await c.execute(.setSubscriptions([shown, hidden]))
    try await c.execute(.setSubscriptions([shown]))
    try await c.send(.text("echo again\r"), to: hidden)
    var again = false
    while !again, let event = try await c.nextEvent() {
      if case let .activity(pane) = event { again = pane == hidden }
    }
    #expect(again)
  }
}

extension MuxService {
  fileprivate func terminationState(of pane: PaneID) -> String {
    runtime(pane)?.terminationStateForTesting()
      ?? "retired after deadline snapshot"
  }

  fileprivate func activityMarkers(in workspace: WorkspaceID) -> Set<PaneID> {
    leases[workspace]?.reportedActivity ?? []
  }
}
