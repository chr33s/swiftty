import SwiftMuxGuardian
import Dispatch
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
@testable import SwiftMuxService
import Synchronization
import Testing

/// Regressions from code review: selectors, scroll bounds, the update
/// barrier during a launch, rename uniqueness, viewport reset on switch,
/// paste outcomes and the frame budget.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ReviewTests {
  @Test(arguments: [-1.0, -Double.infinity, Double.nan, Double.infinity])
  func invalidIdleDelaysDoNotTriggerAnExit(delay: Double) async throws {
    var configuration = MuxServiceConfiguration(launcherPath: "unused")
    configuration.idleExitDelay = delay
    let service = try MuxService(configuration: configuration)
    let exits = Mutex(0)
    service.setIdleHandler { exits.withLock { $0 += 1 } }
    #expect(await service.isEmpty)
    try await Task.sleep(for: .milliseconds(100))
    #expect(exits.withLock { $0 } == 0)
  }

  @Test
  func oversizedInboxReplyFailsPromptlyAndCanBePaged() async throws {
    var limits = MuxLimits.standard
    limits.maxFrameBytes = 1
    let h = try Harness(limits: limits)
    let c = try await h.connect(.control)
    let message = Data(String(repeating: "x", count: 2048).utf8)
      .base64EncodedString()
    var launch = shellLaunch()
    launch.command = [
      "/bin/sh", "-c",
      "i=0; while [ $i -lt 40 ]; do printf '\\033]7501;id=item-%s:state=blocked:msg=\(message)\\007' \"$i\"; i=$((i+1)); done; exec sleep 30",
    ]
    let ws = try await create(c, launch: launch)
    let deadline = ContinuousClock.now + .seconds(5)
    var count = 0
    while ContinuousClock.now < deadline {
      guard
        case let .inbox(page) = try await c.execute(
          .inbox(InboxQuery(limit: 1))
        )
      else { throw MuxError(.invalidRequest, "inbox reply") }
      count = page.counts.needsYou
      if count == 40 { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(count == 40)
    do {
      _ = try await withTimeout(.seconds(2)) {
        try await c.execute(.inbox(InboxQuery()))
      }
      Issue.record("Oversized inbox reply was accepted")
    } catch let error as MuxError {
      #expect(error.code == .resourceLimit)
    } catch {
      Issue.record("Oversized reply did not return a service error: \(error)")
    }
    guard case .status = try await c.execute(.status) else {
      throw MuxError(.invalidRequest, "status reply")
    }
    guard
      case let .inbox(page) = try await c.execute(.inbox(InboxQuery(limit: 1)))
    else { throw MuxError(.invalidRequest, "inbox reply") }
    #expect(page.items.count == 1)
    #expect(page.nextCursor != nil)
    try await c.execute(.endWorkspace(.id(ws.id)))
    await c.close()
  }

  private func create(
    _ c: MuxConnection,
    _ name: String? = nil,
    launch: LaunchSpec = shellLaunch()
  ) async throws -> WorkspaceSnapshot {
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(name: name, launch: launch))
      )
    else { throw MuxError(.invalidRequest, "create") }
    return ws
  }

  private func code(_ body: () async throws -> Void) async -> MuxError.Code? {
    do {
      try await body()
      return nil
    } catch let e as MuxError { return e.code } catch { return nil }
  }

  private func names(_ c: MuxConnection) async throws -> [String] {
    guard case let .workspaces(list) = try await c.execute(.listWorkspaces)
    else { throw MuxError(.invalidRequest) }
    return list.map(\.name)
  }

  /// A name selector matches a name exactly, or an unambiguous ID prefix
  /// of at least eight hex digits; never a short or empty one.
  @Test
  func nameSelectorsNeverMatchShortIDPrefixes() async throws {
    let h = try Harness()
    let c = try await h.connect(.control)
    let a = try await create(c, "keep")
    let id = a.id.description
    for text in ["", String(id.prefix(1)), String(id.prefix(7))] {
      #expect(
        await code { _ = try await c.execute(.endWorkspace(.name(text))) }
          == .notFound
      )
    }
    #expect(try await names(c) == ["keep"])
    // An ended default name stays not-found rather than reaching another
    // workspace through its ID.
    let b = try await create(c)
    try await c.execute(.endWorkspace(.name(b.name)))
    #expect(
      await code { _ = try await c.execute(.endWorkspace(.name(b.name))) }
        == .notFound
    )
    #expect(try await names(c) == ["keep"])
    // Eight hex digits (the short form), in either case, select it.
    try await c.execute(
      .renameWorkspace(.name(String(id.prefix(8)).lowercased()), name: "kept", )
    )
    #expect(try await names(c) == ["kept"])
    try await c.execute(.endWorkspace(.name(a.id.short)))
    #expect(try await names(c).isEmpty)
  }

  /// Relative scrolls are bounded at the service; the pane clamps an
  /// overflowing page count instead of trapping.
  @Test
  func hugeScrollsAreRefusedNotFatal() async throws {
    let progress = Mutex((stage: "fixture creation", finished: false))
    let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    watchdog.setEventHandler {
      let snapshot = progress.withLock { $0 }
      if !snapshot.finished {
        print("huge scroll observation at55s: pending stage=\(snapshot.stage)")
      }
    }
    // Observe before the existing suite deadline without changing it.
    watchdog.schedule(deadline: .now() + .seconds(55))
    watchdog.resume()
    var completed = false
    defer {
      let pending = progress.withLock { value in
        value.finished = true
        return value.stage
      }
      watchdog.cancel()
      if !completed {
        print(
          "huge scroll interrupted: stage=\(pending),cancelled=\(Task.isCancelled)"
        )
      }
    }
    let h = try Harness()
    progress.withLock { $0.stage = "connect" }
    let c = try await h.connect()
    progress.withLock { $0.stage = "create workspace" }
    let ws = try await create(c)
    let pane = ws.tabs[0].activePane
    progress.withLock { $0.stage = "attach, geometry and subscriptions" }
    try await c.attachAndShow(.id(ws.id))
    for request in [
      ScrollRequest.pages(.max / 2), .pages(.min), .lines(.max), .lines(.min),
    ] {
      progress.withLock { $0.stage = "reject scroll \(request)" }
      #expect(
        await code { try await c.execute(.scroll(pane: pane, request)) }
          == .invalidRequest
      )
    }
    progress.withLock { $0.stage = "valid service page scroll" }
    try await c.execute(.scroll(pane: pane, .pages(-3)))
    progress.withLock { $0.stage = "valid service line scroll" }
    try await c.execute(.scroll(pane: pane, .lines(5)))
    // Directly, past the service's bound.
    progress.withLock { $0.stage = "lookup pane runtime" }
    let runtime = try #require(await h.service.runtime(pane))
    for n in [Int.max, Int.min, .max / 2] {
      progress.withLock { $0.stage = "direct runtime page scroll \(n)" }
      await withCheckedContinuation { done in
        runtime.scroll(.pages(n)) { error in
          #expect(error == nil)
          done.resume()
        }
      }
    }
    progress.withLock { $0.stage = "final status" }
    guard case .status = try await c.execute(.status) else {
      throw MuxError(.invalidRequest)
    }
    completed = true
  }

  /// End-all while a workspace's first pane is launching: the workspace
  /// never appears and its pane is reaped.
  @Test
  func endAllDuringALaunchFailsTheLaunch() async throws {
    let started = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    var config = try MuxServiceConfiguration(launcherPath: launcherPath())
    config.beforeLaunch = {
      started.signal()
      proceed.wait()
    }
    let service = try MuxService(configuration: config)
    let endpoint = service.listenAnonymously()
    let c = try await MuxConnection.connect(
      endpoint: endpoint,
      frontend: .control
    )
    let creating = Task { try await create(c, "late") }
    await withCheckedContinuation { done in
      DispatchQueue.global()
        .async {
          started.wait()
          done.resume()
        }
    }
    try await c.execute(.endAllWorkspaces)
    proceed.signal()
    do {
      _ = try await creating.value
      Issue.record("a launch completed after end-all")
    } catch let e as MuxError { #expect(e.code == .quiescing) }
    #expect(try await names(c).isEmpty)
    var panes = -1
    for _ in 0 ..< 200 {
      guard case let .status(s) = try await c.execute(.status) else {
        throw MuxError(.invalidRequest, "unexpected reply")
      }
      panes = s.panes
      if panes == 0 { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    #expect(panes == 0)
    #expect(await service.isEmpty)
  }

  /// Names stay unique across rename, as on creation.
  @Test
  func renameRefusesAnotherWorkspacesName() async throws {
    let h = try Harness()
    let c = try await h.connect(.control)
    _ = try await create(c, "one")
    _ = try await create(c, "two")
    #expect(
      await code {
        _ = try await c.execute(.renameWorkspace(.name("two"), name: "one"))
      } == .invalidRequest
    )
    try await c.execute(.renameWorkspace(.name("two"), name: "two"))
    #expect(try await names(c) == ["one", "two"])
  }

  /// Names show in every client's chrome: bidi overrides, invisible
  /// scalars and blank names are refused; joiners and flag tags that shape
  /// an emoji are not.
  @Test
  func renameRefusesNamesThatDoNotShowAsGiven() async throws {
    let h = try Harness()
    let c = try await h.connect(.control)
    _ = try await create(c, "one")
    for name in [
      "a\u{202E}b", "a\u{200B}b", "a\u{2028}b", "a\u{E000}b", "\u{200D}",
      "a\u{E0041}", " ",
    ] {
      #expect(
        await code {
          _ = try await c.execute(.renameWorkspace(.name("one"), name: name))
        } == .invalidRequest
      )
    }
    let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
    let wales =
      "\u{1F3F4}\u{E0067}\u{E0062}\u{E0077}\u{E006C}\u{E0073}\u{E007F}"
    try await c.execute(.renameWorkspace(.name("one"), name: family + wales))
    #expect(try await names(c) == [family + wales])
    // A new tab's name follows the same rule.
    let ws = try await create(c, "tabs")
    let front = try await h.connect()
    try await front.attachAndShow(.id(ws.id))
    #expect(
      await code {
        _ = try await front.execute(.newTab(name: "a\u{202E}b", launch: nil))
      } == .invalidRequest
    )
  }

  /// Switching away returns the old workspace to live output and ends
  /// its search, as a detach does.
  @Test
  func switchingAwayResetsTheOldViewport() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let w1 = try await create(c, "one")
    let w2 = try await create(c, "two")
    let pane = w1.tabs[0].activePane
    try await c.attachAndShow(.id(w1.id), columns: 40, rows: 10)
    try await c.send(
      .text("i=0; while [ $i -lt 60 ]; do echo row-$i; i=$((i+1)); done\r"),
      to: pane
    )
    _ = try await c.frame(of: pane) { $0.lines.contains("row-59") }
    guard
      case .search = try await c.execute(.search(pane: pane, query: "row-7"))
    else { throw MuxError(.invalidRequest) }
    _ = try await c.frame(of: pane) { $0.history.viewportOffset > 0 }
    try await c.execute(.switchWorkspace(.id(w2.id)))
    // Read in the pane's order, after the reset the switch queued.
    let runtime = try #require(await h.service.runtime(pane))
    let (offset, matches) = await withCheckedContinuation { done in
      runtime.inspect {
        ($0.viewportOffset, $0.searchMatches.count)
      } completion: {
        done.resume(returning: $0)
      }
    }
    #expect(offset == 0)
    #expect(matches == 0)
  }

  /// Without frame acknowledgements (events are left unread, so the
  /// client acknowledges nothing), a one-byte budget admits exactly one
  /// capture across many subscribed panes, not one per pane.
  @Test
  func capturesInProgressCountAgainstTheFrameBudget() async throws {
    var limits = MuxLimits.standard
    limits.pendingFrameBudget = 1
    limits.frameIntervalNanoseconds = 0
    let h = try Harness(limits: limits)
    let c = try await h.connect()
    let ws = try await create(c, launch: busyLaunch())
    var panes = [ws.tabs[0].activePane]
    guard
      case .attached = try await c.execute(.attach(AttachRequest(.id(ws.id))))
    else { throw MuxError(.invalidRequest) }
    for _ in 0 ..< 3 {
      guard
        case let .layout(snap) = try await c.execute(
          .split(pane: panes[0], axis: .leftRight, launch: busyLaunch())
        )
      else { throw MuxError(.invalidRequest) }
      panes = try #require(snap.activeTabSnapshot?.layout.panes)
    }
    #expect(panes.count == 4)
    try await c.execute(.setSubscriptions(panes))
    var most = 0
    for _ in 0 ..< 40 {
      most = await max(most, h.service.outstandingFrames)
      try await Task.sleep(for: .milliseconds(25))
    }
    #expect(most == 1)
    // Unsubscribing returns both the frame and any reservation.
    try await c.execute(.setSubscriptions([]))
    try await Task.sleep(for: .milliseconds(200))
    #expect(await h.service.pendingFrameBytes == 0)
    try await c.execute(.endWorkspace(.id(ws.id)))
  }
}

/// A cancelled paste is reported by what reached the program.
struct PasteOutcomeTests {
  private func writer(chunks: [String]) -> PaneWriter {
    var w = PaneWriter(replyReserve: 1024)
    w.beginPaste(id: 1, bracketed: true)
    for chunk in chunks { w.appendPaste(id: 1, text: chunk) }
    return w
  }

  /// Accepts at most `limit` bytes in total.
  private func flush(_ w: inout PaneWriter, limit: Int) {
    var left = limit
    _ = w.flush { buffer in
      let n = min(left, buffer.count)
      left -= n
      return n
    }
  }

  @Test
  func nothingWrittenIsAborted() {
    var w = writer(chunks: ["abc", "def"])
    flush(&w, limit: 6)  // the opening marker only
    let r = w.cancelPaste(id: 1)
    #expect(r.discarded == 6)
    #expect(!r.wrote)
  }

  @Test
  func writtenThenDiscardedIsPartial() {
    var w = writer(chunks: ["abc", "def"])
    flush(&w, limit: 6 + 3)
    let r = w.cancelPaste(id: 1)
    #expect(r.discarded == 3)
    #expect(r.wrote)
  }

  @Test
  func aPartlyWrittenChunkCountsAsWritten() {
    var w = writer(chunks: ["abc"])
    flush(&w, limit: 6 + 1)
    let r = w.cancelPaste(id: 1)
    #expect(r.discarded == 0)
    #expect(r.wrote)
  }
}
