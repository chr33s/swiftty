import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
@testable import SwiftMuxService
import Synchronization
import Testing

/// Observer windows, search, scrolling and ready (continued).
extension SwiftMuxExtensionTests {
  @Test
  func anObserverDoesNotSeeTheControllersSearch() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    try await c.attachAndShow(.id(ws), columns: 80, rows: 24)
    try await c.send(.text("echo PRIVATE-QUERY-77\r"), to: pane)
    _ = try await c.frame(of: pane) {
      $0.lines.contains { $0.contains("PRIVATE-QUERY-77") }
    }
    guard
      case let .search(found) = try await c.execute(
        .search(pane: pane, query: "PRIVATE-QUERY-77")
      )
    else { throw MuxError(.invalidRequest, "search") }
    #expect(found.matchCount >= 1)
    let observer = try await observe(h, ws, panes: [pane])
    let seen = try await observer.frame(of: pane) {
      $0.lines.contains { $0.contains("PRIVATE-QUERY-77") }
    }
    #expect(seen.search == nil || seen.search?.matchCount == 0)
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
    await observer.close()
  }

  @Test
  func stalledObserversHoldOnlyTheirShareOfTheFrameBudget() async throws {
    // 40x8 cells: one capture reserves 10 KiB; observers may hold 10 KiB.
    let estimate = 40 * 8 * MuxService.frameBytesPerCell
    var limits = MuxLimits.standard
    limits.pendingFrameBudget = 4 * estimate
    let h = try Harness(limits: limits)
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    try await c.attachAndShow(.id(ws), columns: 40, rows: 8)
    var observers: [MuxConnection] = []
    for _ in 0 ..< SMX.maxObservers {
      let observer = try await h.connect()
      guard
        case .attached = try await observer.execute(
          .attach(AttachRequest(.id(ws), role: .observer))
        )
      else { throw MuxError(.invalidRequest, "observe") }
      await observer.setSuppressesFrameAcknowledgement(true)
      try await observer.execute(.setSubscriptions([pane]))
      observers.append(observer)
    }
    try await c.send(
      .text(
        "i=0; while [ $i -lt 60 ]; do echo tick-$i; i=$((i+1)); sleep 0.02; done\r"
      ),
      to: pane
    )
    var most = 0
    let deadline = ContinuousClock.now + .seconds(10)
    var last: PaneFrame?
    while ContinuousClock.now < deadline {
      most = max(most, await h.service.viewerFrameBytes)
      let next = try? await c.frame(of: pane, timeout: .milliseconds(50)) { _ in
        true
      }
      if let frame = next {
        last = frame
        if frame.lines.contains("tick-59") { break }
      }
    }
    // Stalled observers never starve the controller of fresh frames.
    #expect(last?.lines.contains("tick-59") == true)
    #expect(most > 0)
    #expect(most < (await h.service.viewerFrameBudget) + estimate)
    #expect(
      await h.service.pendingFrameBytes <= limits.pendingFrameBudget + estimate
    )
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
    for observer in observers { await observer.close() }
  }

  @Test
  func switchingToTheSameWorkspaceKeepsQueuedKeystrokes() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    try await c.attachAndShow(.id(ws), columns: 40, rows: 8)
    // Echo off and sleep: the shell stops reading while input backs up.
    try await c.send(.text("stty -echo; echo ECHO-OFF; sleep 3\r"), to: pane)
    _ = try await c.frame(of: pane, label: "echo-off") {
      $0.lines.contains("ECHO-OFF")
    }
    // Short comment lines fill the canonical input buffer and block the
    // writer; the command at the end stays queued behind them.
    let line = "#" + String(repeating: "q", count: 39) + "\n"
    let bulk = String(repeating: line, count: 2500) + "echo KEPT-KEYS-TOKEN\n"
    try await c.send(.text(bulk), to: pane)
    let runtime = try #require(await h.service.runtime(pane))
    let pending = runtime.outstandingInput.withLock { $0 }
    if pending <= 20_000 {
      throw MuxError(
        .notFound,
        "writer never backed up, outstanding=\(pending)"
      )
    }
    guard case .layout = try await c.execute(.switchWorkspace(.id(ws))) else {
      throw MuxError(.invalidRequest, "switch")
    }
    try await c.execute(.setSubscriptions([pane]))
    // The prompts of the comment lines wrap the output across rows. Slow CI
    // runners print the 2,500 prompts at ~150/s, so allow the full drain.
    let kept = try await c.frame(of: pane, timeout: .seconds(60), label: "kept")
    { $0.lines.joined().contains("KEPT-KEYS-TOKEN") }
    #expect(kept.lines.joined().contains("KEPT-KEYS-TOKEN"))
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
  }

  @Test
  func observerSearchStartsFromTheObserversOwnWindow() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    try await c.attachAndShow(.id(ws), columns: 40, rows: 8)
    try await c.send(
      .text(
        "i=0; while [ $i -lt 40 ]; do echo row-$i; i=$((i+1)); done; "
          + "printf 'OWN-NEEDLE\\na\\nb\\nc\\n'\r"
      ),
      to: pane
    )
    _ = try await c.frame(of: pane, label: "needle") {
      $0.lines.contains("OWN-NEEDLE") && $0.lines.contains("c")
    }
    // The controller sits at the top of history.
    try await c.execute(.scroll(pane: pane, .lines(1000)))
    _ = try await c.frame(of: pane, label: "controller-top") {
      $0.history.viewportTop == $0.history.firstRow
    }
    let observer = try await observe(h, ws, panes: [pane])
    _ = try await observer.frame(of: pane, label: "observer-tail") {
      $0.history.viewportOffset == 0 && $0.lines.contains("OWN-NEEDLE")
    }
    guard
      case let .search(found) = try await observer.execute(
        .search(pane: pane, query: "OWN-NEEDLE")
      )
    else { throw MuxError(.invalidRequest, "search") }
    #expect(found.matchCount >= 1)
    // The match is already on the observer's screen, so it stays put.
    let frame = try await observer.frame(of: pane, label: "observer-search") {
      $0.search?.selected == found.selected && $0.search?.selectedVisible != nil
    }
    #expect(frame.history.viewportOffset == 0)
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
    await observer.close()
  }

  @Test
  func sharedObserverSearchesFollowNewOutput() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    try await c.attachAndShow(.id(ws), columns: 80, rows: 24)
    try await c.send(.text("echo CACHED-NEEDLE-1\r"), to: pane)
    _ = try await c.frame(of: pane) { $0.lines.contains("CACHED-NEEDLE-1") }
    let a = try await observe(h, ws, panes: [pane])
    let b = try await observe(h, ws, panes: [pane])
    var counts: [Int] = []
    for observer in [a, b] {
      guard
        case let .search(found) = try await observer.execute(
          .search(pane: pane, query: "CACHED-NEEDLE-")
        )
      else { throw MuxError(.invalidRequest, "search") }
      #expect(found.matchCount > 0)
      counts.append(found.matchCount)
      _ = try await observer.frame(of: pane, label: "first") {
        $0.search?.matchCount == found.matchCount
      }
    }
    #expect(counts[0] == counts[1])
    // New output (the typed command and its result) must invalidate the
    // shared matches for both observers.
    try await c.send(.text("echo CACHED-NEEDLE-2\r"), to: pane)
    for observer in [a, b] {
      let frame = try await observer.frame(of: pane, label: "refreshed") {
        $0.lines.contains("CACHED-NEEDLE-2")
          && $0.search?.matchCount == counts[0] + 2
      }
      #expect(frame.search?.matchCount == counts[0] + 2)
    }
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
    await a.close()
    await b.close()
  }

  @Test
  func detachActiveReleasesObserversToo() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    try await c.attachAndShow(.id(ws), columns: 40, rows: 8)
    let observer = try await observe(h, ws, panes: [pane])
    await c.detach()
    let control = try await h.connect(.control)
    guard case let .status(before) = try await control.execute(.status) else {
      throw MuxError(.invalidRequest, "status")
    }
    #expect(before.attached)
    try await control.execute(.detachActive)
    guard case let .status(after) = try await control.execute(.status) else {
      throw MuxError(.invalidRequest, "status")
    }
    #expect(!after.attached)
    let deadline = ContinuousClock.now + .seconds(3)
    while await observer.attachment != nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await observer.attachment == nil)
    try await control.execute(.endWorkspace(.id(ws)))
    await c.close()
    await observer.close()
    await control.close()
  }

  @Test
  func anObserversOwnDetachIsNotAnnounced() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    let observer = try await observe(h, ws, panes: [pane])
    await observer.detach()
    #expect(await observer.attachment == nil)
    let deadline = ContinuousClock.now + .milliseconds(300)
    var announced = false
    while ContinuousClock.now < deadline {
      do {
        if case .detached = try await observer.nextEvent(
          timeout: .milliseconds(50)
        ) {
          announced = true
        }
      } catch is MuxConnection.EventWaitError { continue }
    }
    #expect(!announced)
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
    await observer.close()
  }

  @Test
  func theServiceRefusesUnnegotiatedRolesAndViewports() async throws {
    let h = try Harness()
    let owner = try await h.connect()
    let (ws, pane) = try await create(owner)
    let local = LocalController()
    _ = try await local.connect(h.service, capabilities: [])
    #expect(
      await rejection {
        _ = try await local.execute(
          .attach(AttachRequest(.id(ws), role: .observer))
        )
      } == .invalidRequest
    )
    let supported = LocalController()
    _ = try await supported.connect(h.service)
    #expect(
      await rejection {
        _ = try await supported.execute(
          .attach(AttachRequest(.id(ws), role: .observer))
        )
      } == .invalidRequest
    )
    await supported.close()
    _ = try await local.execute(.attach(AttachRequest(.id(ws))))
    #expect(
      await rejection {
        _ = try await local.execute(
          .setViewport(
            ViewportRequest(pane: pane, followTail: true, historyGeneration: 0)
          )
        )
      } == .invalidRequest
    )
    try await owner.execute(.endWorkspace(.id(ws)))
    await local.close()
    await owner.close()
  }

  @Test
  func switchingWorkspaceRearmsReady() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (first, firstPane) = try await create(c)
    try await c.attachAndShow(.id(first), columns: 40, rows: 8)
    _ = try await c.frame(of: firstPane) { _ in true }
    let old = try await waitReady(c)
    guard
      case let .created(second) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(name: "ext-2", launch: shellLaunch()))
      )
    else { throw MuxError(.invalidRequest, "create") }
    let pane = second.tabs[0].activePane
    guard
      case let .layout(switched) = try await c.execute(
        .switchWorkspace(.id(second.id))
      )
    else { throw MuxError(.invalidRequest, "switch") }
    #expect(await c.readiness == nil)
    try await c.execute(
      .setGeometry(
        GeometryBatch(
          layoutRevision: switched.layoutRevision,
          generation: 2,
          entries: [.init(pane: pane, columns: 40, rows: 8)]
        )
      )
    )
    try await c.execute(.setSubscriptions([pane]))
    _ = try await c.frame(of: pane) { _ in true }
    let ready = try await waitReady(c)
    #expect(ready.initialFrames.map(\.pane) == [pane])
    #expect(ready.initialFrames != old.initialFrames)
    try await c.execute(.endWorkspace(.id(first)))
    try await c.execute(.endWorkspace(.id(second.id)))
    await c.close()
  }
}
