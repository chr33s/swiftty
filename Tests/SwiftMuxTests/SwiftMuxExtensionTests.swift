import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
@testable import SwiftMuxService
import Synchronization
import Testing

/// Attach readiness, per-viewer viewports, and bounded read-only observers.
/// Drives `MuxService` through `MuxConnection`.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct SwiftMuxExtensionTests {
  @Test
  func readyWaitsForVisibleFramesOnly() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, hidden) = try await create(c)
    guard
      case let .attached(_, attached) = try await c.execute(
        .attach(AttachRequest(.id(ws)))
      )
    else { throw MuxError(.invalidRequest, "attach") }
    #expect(attached.attachmentRole == .controller)
    #expect(await c.readiness == nil)
    // Naming no panes while a pane is visible must not report Ready.
    try await c.execute(.setSubscriptions([]))
    try await Task.sleep(for: .milliseconds(200))
    #expect(await c.readiness == nil)

    guard
      case let .layout(split) = try await c.execute(
        .newTab(name: "other", launch: shellLaunch())
      ), let shown = split.activeTabSnapshot?.activePane
    else { throw MuxError(.invalidRequest, "tab") }
    #expect(shown != hidden)
    await c.setSuppressesFrameAcknowledgement(true)
    try await c.execute(.setSubscriptions([shown, hidden]))
    let installed = try await waitInstall(c, pane: shown)
    try await Task.sleep(for: .milliseconds(250))
    #expect(await c.readiness == nil)
    await c.acknowledgeFrame(installed)
    let ready = try await waitReady(c)
    let attachment = await c.attachment
    let server = await c.welcome?.server
    #expect(ready.attachment == attachment)
    #expect(ready.server == server)
    #expect(ready.initialFrames.map(\.pane) == [shown])
    #expect(ready.initialFrames.first?.frameRevision == installed.revision)
    #expect(
      ready.initialFrames.first?.geometryRevision
        == installed.geometryGeneration
    )
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
  }

  @Test
  func legacyAttachIsTheSoleController() async throws {
    let h = try Harness()
    let legacy = try await MuxConnection.connect(
      endpoint: h.endpoint,
      frontend: .native,
      capabilities: []
    )
    let (ws, pane) = try await create(legacy)
    let shown = try await legacy.attachAndShow(.id(ws))
    #expect(shown.attachmentRole == .controller)
    _ = try await legacy.frame(of: pane) { _ in true }
    let deadline = ContinuousClock.now + .milliseconds(400)
    while ContinuousClock.now < deadline {
      if await legacy.readiness != nil { break }
      do {
        let event = try await legacy.nextEvent(timeout: .milliseconds(50))
        if case .ready = event { break }
      } catch is MuxConnection.EventWaitError { continue }
    }
    #expect(await legacy.readiness == nil)
    let second = try await h.connect()
    #expect(
      await rejection {
        _ = try await second.execute(.attach(AttachRequest(.id(ws))))
      } == .leaseHeld
    )
    try await legacy.execute(.endWorkspace(.id(ws)))
    await legacy.close()
    await second.close()
  }

  @Test
  func reattachShowsOwnedCellsAndRejectsStaleFrames() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    try await c.attachAndShow(.id(ws), columns: 40, rows: 8, generation: 5)
    let pid = try #require(await h.service.panePID(pane))
    let wide = String(repeating: "W", count: 90)
    try await c.send(.text("echo owned-screen-42 \(wide)\r"), to: pane)
    let first = try await c.frame(of: pane) {
      $0.lines.contains { $0.contains("owned-screen-42") }
    }
    try FrameValidator.validate(first)
    let owned = try #require(await h.service.screenLines(pane))
    #expect(first.lines == owned)
    #expect(
      first.lines.contains { $0.count == 40 && $0.allSatisfy { $0 == "W" } }
    )
    await c.close()
    try await Task.sleep(for: .milliseconds(200))
    #expect(await h.service.panePID(pane) == pid)
    let again = try await h.connect()
    try await again.attachAndShow(.id(ws), columns: 40, rows: 8, generation: 6)
    let second = try await again.frame(of: pane) {
      $0.lines.contains { $0.contains("owned-screen-42") }
    }
    try FrameValidator.validate(second)
    let ownedAgain = try #require(await h.service.screenLines(pane))
    #expect(second.lines == ownedAgain)
    #expect(await h.service.panePID(pane) == pid)
    #expect(await again.readiness != nil)

    let shown = second
    var older = shown
    older.identity.revision = shown.identity.revision &- 1
    var foreignServer = shown
    foreignServer.identity.server = ServerInstanceID()
    foreignServer.identity.revision = shown.identity.revision &+ 3
    var foreignAttachment = shown
    foreignAttachment.identity.attachment = AttachmentID()
    foreignAttachment.identity.revision = shown.identity.revision &+ 3
    var staleGeometry = shown
    staleGeometry.identity.geometryGeneration =
      shown.identity.geometryGeneration &- 1
    staleGeometry.identity.revision = shown.identity.revision &+ 3
    var staleLayout = shown
    staleLayout.identity.layoutRevision = shown.identity.layoutRevision &- 1
    staleLayout.identity.revision = shown.identity.revision &+ 3
    for rejected in [
      older, foreignServer, foreignAttachment, staleGeometry, staleLayout,
    ] { #expect(await again.install(rejected) == false) }
    #expect(
      await again.installation.visible[pane]?.revision
        == shown.identity.revision
    )
    // A resubscription resends the installed revision; it is accepted.
    #expect(await again.install(shown))
    var newer = shown
    newer.identity.revision = shown.identity.revision &+ 1
    #expect(await again.install(newer))
    #expect(await again.installation.visible[pane] == newer.identity)
    try await again.execute(.endWorkspace(.id(ws)))
    await again.close()
  }

  @Test
  func inputBeforeTheLeaseIsNotWritten() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    #expect(
      await rejection {
        try await c.send(.text("echo leaked-before-lease\r"), to: pane)
      } == .notAttached
    )
    try await c.attachAndShow(.id(ws), columns: 40, rows: 8)
    try await c.send(.text("echo after-lease-ok\r"), to: pane)
    let frame = try await c.frame(of: pane) {
      $0.lines.contains("after-lease-ok")
    }
    #expect(!frame.lines.contains { $0.contains("leaked-before-lease") })
    let owned = try #require(await h.service.screenLines(pane))
    #expect(frame.lines == owned)
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
  }

  @Test
  func viewersHaveIndependentViewports() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    let shown = try await c.attachAndShow(.id(ws), columns: 40, rows: 8)
    try await c.send(
      .text("i=0; while [ $i -lt 40 ]; do echo row-$i; i=$((i+1)); done\r"),
      to: pane
    )
    let tail = try await c.frame(of: pane, label: "tail") {
      $0.lines.contains("row-39") && $0.history.scrollbackRows > 12
    }
    let generation = tail.history.generation
    let older = tail.history.firstRow
    let middle = tail.history.viewportTop - 8
    #expect(older != middle)

    let a = try await observe(h, ws, panes: [pane])
    let b = try await observe(h, ws, panes: [pane])
    try await pin(a, pane: pane, anchor: older, generation: generation)
    let frameA = try await a.frame(of: pane, label: "anchor-a") {
      $0.history.viewportTop == older && $0.history.viewportOffset > 0
    }
    try await pin(
      b,
      pane: pane,
      anchor: middle,
      generation: generation,
      rows: 4,
      columns: 12
    )
    let frameB = try await b.frame(of: pane, label: "anchor-b") {
      $0.history.viewportTop == middle && $0.grid.rows == 4
        && $0.grid.columns == 12
    }
    #expect(frameA.history.viewportTop != frameB.history.viewportTop)
    #expect(frameA.lines != frameB.lines)
    let frozen = frameA.lines.joined(separator: "\n")

    let runtime = try #require(await h.service.runtime(pane))
    let offset = await withCheckedContinuation { done in
      runtime.inspect {
        $0.viewportOffset
      } completion: {
        done.resume(returning: $0)
      }
    }
    #expect(offset == 0)
    #expect(runtime.size.columns == 40)
    #expect(runtime.size.rows == 8)
    // The tail frame was already consumed. A zero scroll republishes the
    // controller viewport without moving it or resizing the PTY.
    try await c.execute(.scroll(pane: pane, .lines(0)))
    let live = try await c.frame(of: pane, label: "controller-tail") {
      $0.history.viewportOffset == 0 && $0.grid.columns == 40
        && $0.grid.rows == 8 && $0.lines.contains("row-39")
    }
    #expect(live.lines.contains("row-39"))
    try await c.send(.text("stty size\r"), to: pane)
    _ = try await c.frame(of: pane, label: "stty-40") {
      $0.lines.contains("8 40")
    }

    try await c.send(.text("echo tail-marker-99\r"), to: pane)
    _ = try await c.frame(of: pane, label: "marker") {
      $0.lines.contains("tail-marker-99")
    }
    let pinned = try await a.frame(of: pane, label: "pinned") {
      $0.identity.revision > frameA.identity.revision
    }
    #expect(pinned.history.viewportTop == older)
    #expect(!pinned.lines.contains { $0.contains("tail-marker-99") })
    #expect(frozen == frameA.lines.joined(separator: "\n"))
    #expect(!frozen.contains("tail-marker-99"))
    let latestOwned = try #require(await h.service.screenLines(pane))
    #expect(latestOwned.contains { $0.contains("tail-marker-99") })
    #expect(frozen != latestOwned.joined(separator: "\n"))

    try await pin(b, pane: pane, followTail: true, generation: generation)
    let followed = try await b.frame(of: pane, label: "follow") {
      $0.lines.contains { $0.contains("tail-marker-99") }
        && $0.grid.columns == 40
    }
    #expect(followed.history.viewportOffset == 0)
    #expect(
      await rejection {
        try await pin(a, pane: pane, anchor: older, generation: generation &+ 9)
      } == .historyUnavailable
    )
    #expect(
      await rejection {
        try await pin(
          a,
          pane: pane,
          followTail: true,
          generation: generation,
          rows: 3
        )
      } == .invalidRequest
    )

    try await expectReflowDropsAnchor(
      controller: c,
      viewer: a,
      pane: pane,
      layoutRevision: shown.layoutRevision,
      generation: generation,
      anchor: older
    )
    try await pin(a, pane: pane, followTail: true, generation: 0)
    try await c.send(.text("stty size\r"), to: pane)
    _ = try await a.frame(of: pane, label: "stty-50") {
      $0.lines.contains("8 50")
    }
    #expect(runtime.size.columns == 50)
    #expect(runtime.size.rows == 8)

    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
    await a.close()
    await b.close()
  }

  @Test
  func observersAreBoundedAndCannotMutate() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    let shown = try await c.attachAndShow(.id(ws), columns: 40, rows: 8)
    let tab = try #require(shown.activeTabSnapshot?.id)
    #expect(
      await rejection {
        _ = try await c.execute(
          .attach(AttachRequest(.id(ws), role: .observer))
        )
      } == .alreadyAttached
    )
    var observers: [MuxConnection] = []
    for _ in 0 ..< SMX.maxObservers {
      observers.append(try await observe(h, ws, panes: [pane]))
    }
    let extra = try await h.connect()
    #expect(
      await rejection {
        _ = try await extra.execute(
          .attach(AttachRequest(.id(ws), role: .observer))
        )
      } == .resourceLimit
    )
    let other = try await h.connect()
    #expect(
      await rejection {
        _ = try await other.execute(.attach(AttachRequest(.id(ws))))
      } == .leaseHeld
    )
    let observer = observers[0]
    let generation = try await leaseGeneration(observer, ws)
    await expectObserverCannotMutate(
      observer,
      pane: pane,
      tab: tab,
      workspace: ws,
      generation: generation
    )
    guard case .status = try await observer.execute(.status) else {
      throw MuxError(.invalidRequest, "status")
    }
    guard case .workspaces = try await observer.execute(.listWorkspaces) else {
      throw MuxError(.invalidRequest, "list")
    }
    try await c.send(.text("echo controller-still-writes\r"), to: pane)
    let frame = try await c.frame(of: pane) {
      $0.lines.contains("controller-still-writes")
    }
    #expect(!frame.lines.contains { $0.contains("observer-write") })
    #expect(!frame.lines.contains { $0.contains("observer-paste") })
    let watched = try await observer.frame(of: pane) {
      $0.lines.contains("controller-still-writes")
    }
    #expect(watched.lines == frame.lines)

    let pid = try #require(await h.service.panePID(pane))
    try await c.send(.text("sleep 1; echo observer-still-sees\r"), to: pane)
    await c.close()
    try await Task.sleep(for: .milliseconds(150))
    #expect(await h.service.panePID(pane) == pid)
    let later = try await observer.frame(of: pane, timeout: .seconds(8)) {
      $0.lines.contains("observer-still-sees")
    }
    #expect(await observer.attachment != nil)
    #expect(
      await rejection {
        try await observer.send(.text("echo promoted\r"), to: pane)
      } == .unauthorized
    )
    #expect(!later.lines.contains { $0.contains("promoted") })
    #expect(await h.service.panePID(pane) == pid)

    try await other.execute(.endWorkspace(.id(ws)))
    await other.close()
    await extra.close()
    for observer in observers { await observer.close() }
  }

  @Test
  func takeoverCancelsPendingInputWithoutPromotingAnObserver() async throws {
    let h = try Harness()
    let controller = try await h.connect()
    let (ws, pane) = try await create(controller)
    try await controller.attachAndShow(.id(ws), columns: 40, rows: 8)
    let observer = try await observe(h, ws, panes: [pane])
    let observerAttachment = await observer.attachment
    await controller.setPasteRetry(attempts: 40, delay: .milliseconds(25))
    // Echo off so the queued paste does not flood the screen. Sleep keeps
    // the shell from reading while the writer still holds the tail.
    try await controller.send(
      .text("stty -echo; echo ECHO-OFF; sleep 3\r"),
      to: pane
    )
    _ = try await controller.frame(of: pane, label: "echo-off") {
      $0.lines.contains("ECHO-OFF")
    }
    // Short lines fill the canonical input buffer. A single oversize line
    // is discarded by the tty without ever blocking the writer, so the
    // tail would already be gone before takeover. The token sits past
    // the first chunk and must still be queued when the lease ends.
    let line = String(repeating: "q", count: 40) + "\n"
    let paste = Task {
      try await controller.paste(
        String(repeating: line, count: 2500) + "GHOST-TAIL-TOKEN\n",
        to: pane
      )
    }
    let runtime = try #require(await h.service.runtime(pane))
    let backlogDeadline = ContinuousClock.now + .seconds(2)
    var pending = 0
    while ContinuousClock.now < backlogDeadline {
      pending = runtime.outstandingInput.withLock { $0 }
      if pending > 20_000 { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    if pending <= 20_000 {
      throw MuxError(
        .notFound,
        "writer never backed up, outstanding=\(pending)"
      )
    }
    // Admitted only after the paste has filled the tty buffer, so this
    // command is pending behind that paste and still unwritten.
    try await controller.send(.text("echo ghost-cmd-token\r"), to: pane)
    pending = runtime.outstandingInput.withLock { $0 }
    if pending <= 20_000 {
      throw MuxError(
        .notFound,
        "writer drained before takeover, outstanding=\(pending)"
      )
    }
    #expect(
      await rejection {
        _ = try await observer.execute(
          .takeover(
            .id(ws),
            expectedLease: try await leaseGeneration(observer, ws)
          )
        )
      } == .unauthorized
    )
    let taker = try await h.connect()
    let generation = try await leaseGeneration(taker, ws)
    guard
      case let .attached(_, snap) = try await taker.execute(
        .takeover(.id(ws), expectedLease: generation)
      )
    else { throw MuxError(.invalidRequest, "takeover") }
    #expect(snap.attachmentRole == .controller)
    #expect(await observer.attachment == observerAttachment)
    #expect(await taker.attachment != observerAttachment)
    _ = try? await paste.value
    try await taker.execute(
      .setGeometry(
        GeometryBatch(
          layoutRevision: snap.layoutRevision,
          generation: 2,
          entries: [.init(pane: pane, columns: 40, rows: 8)]
        )
      )
    )
    try await taker.execute(.setSubscriptions([pane]))
    // The discarded paste can leave a partial canonical line in the
    // kernel. Kill that editing line (not the shell) and then prove the
    // new writer. Completed lines already in the kernel still run; a
    // cancelled tail must not.
    try await taker.send(.text("\u{15}printf 'KEPT-LINE-OK\\n'\r"), to: pane)
    let leaked = LeakFlag()
    let frame = try await taker.frame(
      of: pane,
      timeout: .seconds(15),
      label: "kept"
    ) { frame in
      if frame.lines.contains(where: {
        $0.contains("GHOST-TAIL-TOKEN") || $0.contains("ghost-cmd-token")
      }) {
        leaked.value = true
      }
      return frame.lines.contains { $0.contains("KEPT-LINE-OK") }
    }
    #expect(!leaked.value)
    #expect(frame.lines.filter { $0.contains("KEPT-LINE-OK") }.count == 1)
    #expect(!frame.lines.contains { $0.contains("GHOST-TAIL-TOKEN") })
    #expect(!frame.lines.contains { $0.contains("ghost-cmd-token") })
    let seen = try await observer.frame(of: pane, label: "observer-kept") {
      $0.lines.contains { $0.contains("KEPT-LINE-OK") }
    }
    #expect(
      await rejection {
        try await observer.send(.text("echo still-observer\r"), to: pane)
      } == .unauthorized
    )
    #expect(!seen.lines.contains { $0.contains("still-observer") })
    try await taker.execute(.endWorkspace(.id(ws)))
    await taker.close()
    await observer.close()
    await controller.close()
  }

  @Test
  func aSlowObserverDoesNotStallTheController() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    try await c.attachAndShow(.id(ws), columns: 40, rows: 8)
    let observer = try await h.connect()
    guard
      case .attached = try await observer.execute(
        .attach(AttachRequest(.id(ws), role: .observer))
      )
    else { throw MuxError(.invalidRequest, "observe") }
    await observer.setSuppressesFrameAcknowledgement(true)
    try await observer.execute(.setSubscriptions([pane]))
    let status = Task { try await observer.execute(.status) }
    try await c.send(
      .text("i=0; while [ $i -lt 30 ]; do echo burst-$i; i=$((i+1)); done\r"),
      to: pane
    )
    let deadline = ContinuousClock.now + .seconds(5)
    while await h.service.observerQueuedFrames(pane) < 1,
      ContinuousClock.now < deadline
    { try await Task.sleep(for: .milliseconds(20)) }
    let frame = try await c.frame(of: pane) { $0.lines.contains("burst-29") }
    guard case .status = try await status.value else {
      throw MuxError(.invalidRequest, "status")
    }
    guard case .status = try await c.execute(.status) else {
      throw MuxError(.invalidRequest, "controller status")
    }
    try await Task.sleep(for: .milliseconds(100))
    let budget = await c.welcome?.limits.pendingFrameBudget ?? 0
    #expect(await h.service.observerQueuedFrames(pane) >= 1)
    #expect(await h.service.observerQueuedFrames(pane) <= 2)
    #expect(await h.service.pendingFrameBytes <= budget)
    #expect(frame.lines.contains("burst-29"))
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
    await observer.close()
  }

  @Test
  func localControllerOutputReachesAnAckingObserver() async throws {
    let h = try Harness()
    let local = LocalController()
    _ = try await local.connect(h.service)
    guard
      case let .created(ws) = try await local.execute(
        .newWorkspace(NewWorkspaceRequest(name: "local", launch: shellLaunch()))
      )
    else { throw MuxError(.invalidRequest, "create") }
    let pane = try #require(ws.tabs.first).activePane
    guard
      case let .attached(attachment, attached) = try await local.execute(
        .attach(AttachRequest(.id(ws.id)))
      )
    else { throw MuxError(.invalidRequest, "attach") }
    #expect(attached.attachmentRole == .controller)
    _ = try await local.execute(
      .setGeometry(
        GeometryBatch(
          layoutRevision: attached.layoutRevision,
          generation: 1,
          entries: [.init(pane: pane, columns: 40, rows: 8)]
        )
      )
    )
    let observer = try await observe(h, ws.id, panes: [pane])
    let first = try await observer.frame(of: pane, label: "observer-initial") {
      !$0.lines.contains { $0.contains("LOCAL-PUMP-TOKEN") }
    }
    try FrameValidator.validate(first)
    // The status request follows the frame ack on this connection, so the
    // service has retired the in-flight frame before the next write.
    guard case .status = try await observer.execute(.status) else {
      throw MuxError(.invalidRequest, "status")
    }
    try await local.send(
      .text("echo LOCAL-PUMP-TOKEN\r"),
      attachment: attachment,
      pane: pane
    )
    let next = try await observer.frame(of: pane, label: "observer-pumped") {
      $0.identity.revision > first.identity.revision
        && $0.lines.contains { $0.contains("LOCAL-PUMP-TOKEN") }
    }
    try FrameValidator.validate(next)
    #expect(next.identity.revision > first.identity.revision)
    #expect(next.lines.contains { $0.contains("LOCAL-PUMP-TOKEN") })
    _ = try await local.execute(.endWorkspace(.id(ws.id)))
    await local.close()
    await observer.close()
  }

  @Test
  func observerSearchFrameMatchesTheSearchReply() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    try await c.attachAndShow(.id(ws), columns: 80, rows: 24)
    try await c.send(
      .text(
        "printf 'ALPHA-MATCH one\\nALPHA-MATCH two\\nALPHA-MATCH three\\n'\r"
      ),
      to: pane
    )
    _ = try await c.frame(of: pane) {
      $0.lines.contains { $0.contains("ALPHA-MATCH three") }
    }
    let observer = try await observe(h, ws, panes: [pane])
    _ = try await observer.frame(of: pane) { _ in true }
    guard
      case let .search(found) = try await observer.execute(
        .search(pane: pane, query: "ALPHA-MATCH")
      )
    else { throw MuxError(.invalidRequest, "search") }
    #expect(found.matchCount >= 3)
    #expect(found.selected == found.matchCount - 1)
    let highlighted = try await observer.frame(of: pane, label: "search") {
      $0.search?.selected == found.selected && $0.search?.selectedVisible != nil
    }
    try FrameValidator.validate(highlighted)
    #expect(highlighted.search?.matchCount == found.matchCount)
    #expect(highlighted.search?.selected == found.selected)
    let visible = try #require(highlighted.search?.selectedVisible)
    let spans = try #require(highlighted.search?.visible)
    #expect(spans.indices.contains(visible))
    #expect(highlighted.lines[spans[visible].startRow].contains("ALPHA-MATCH"))

    guard
      case let .search(stepped) = try await observer.execute(
        .searchStep(pane: pane, forward: false)
      )
    else { throw MuxError(.invalidRequest, "step") }
    #expect(stepped.selected == (found.selected ?? 0) - 1)
    let steppedFrame = try await observer.frame(of: pane, label: "search-step")
    {
      $0.search?.selected == stepped.selected
        && $0.search?.selectedVisible != nil
    }
    try FrameValidator.validate(steppedFrame)
    #expect(steppedFrame.search?.selected == stepped.selected)
    #expect(steppedFrame.search?.selected != found.selected)
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
    await observer.close()
  }

  @Test
  func observerEndSearchClearsHighlights() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    try await c.attachAndShow(.id(ws), columns: 80, rows: 24)
    try await c.send(.text("echo END-SEARCH-TOKEN\r"), to: pane)
    _ = try await c.frame(of: pane) {
      $0.lines.contains { $0.contains("END-SEARCH-TOKEN") }
    }
    let observer = try await observe(h, ws, panes: [pane])
    _ = try await observer.frame(of: pane) { _ in true }
    guard
      case .search = try await observer.execute(
        .search(pane: pane, query: "END-SEARCH-TOKEN")
      )
    else { throw MuxError(.invalidRequest, "search") }
    let highlighted = try await observer.frame(of: pane, label: "highlighted") {
      !($0.search?.visible.isEmpty ?? true)
    }
    #expect(highlighted.search?.visible.isEmpty == false)
    guard
      case let .search(ended) = try await observer.execute(
        .endSearch(pane: pane)
      )
    else { throw MuxError(.invalidRequest, "end search") }
    #expect(ended.matchCount == 0)
    #expect(ended.selected == nil)
    let cleared = try await observer.frame(of: pane, label: "end-search") {
      $0.search == nil || $0.search?.visible.isEmpty == true
    }
    try FrameValidator.validate(cleared)
    #expect(cleared.identity.revision > highlighted.identity.revision)
    #expect(cleared.search == nil || cleared.search?.visible.isEmpty == true)
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
    await observer.close()
  }

  @Test
  func aNewControllerDoesNotFreezeAnObserver() async throws {
    let h = try Harness()
    let a = try await h.connect()
    let (ws, pane) = try await create(a)
    // The first controller's own batch counter runs far ahead.
    try await a.attachAndShow(.id(ws), columns: 40, rows: 8, generation: 40)
    let observer = try await observe(h, ws, panes: [pane])
    let first = try await observer.frame(of: pane) { $0.grid.columns == 40 }
    await a.close()
    let b = try await h.connect()
    try await b.attachAndShow(.id(ws), columns: 50, rows: 8, generation: 1)
    let resized = try await observer.frame(of: pane, label: "new-controller") {
      $0.grid.columns == 50
    }
    #expect(
      resized.identity.geometryGeneration > first.identity.geometryGeneration
    )
    try await b.execute(.endWorkspace(.id(ws)))
    await b.close()
    await observer.close()
  }

  @Test
  func anObserverRoleIsNeverWidenedToController() async throws {
    let h = try Harness()
    let owner = try await h.connect()
    let (ws, _) = try await create(owner)
    let legacy = try await MuxConnection.connect(
      endpoint: h.endpoint,
      frontend: .native,
      capabilities: []
    )
    #expect(
      await rejection {
        _ = try await legacy.execute(
          .attach(AttachRequest(.id(ws), role: .observer))
        )
      } == .invalidRequest
    )
    #expect(await legacy.attachment == nil)
    try await owner.execute(.endWorkspace(.id(ws)))
    await owner.close()
    await legacy.close()
  }

  @Test
  func reattachingOnOneConnectionInstallsNewFrames() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    try await c.attachAndShow(.id(ws), columns: 40, rows: 8)
    _ = try await c.frame(of: pane) { _ in true }
    _ = try await waitReady(c)
    let old = await c.attachment
    await c.detach()
    #expect(await c.readiness == nil)
    try await c.attachAndShow(.id(ws), columns: 40, rows: 8, generation: 2)
    let renewed = await c.attachment
    #expect(renewed != old)
    let frame = try await c.frame(of: pane, label: "reattached") {
      $0.identity.attachment == renewed
    }
    #expect(await c.installation.visible[pane] == frame.identity)
    let ready = try await waitReady(c)
    #expect(ready.attachment == renewed)
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
  }

  @Test
  func readyFollowsWhenTheLastMissingPaneExits() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, a) = try await create(c)
    _ = try await c.attachAndShow(.id(ws))
    guard
      case let .layout(split) = try await c.execute(
        .split(pane: a, axis: .leftRight, launch: shellLaunch())
      ),
      let b = split.activeTabSnapshot?.layout?.panes.first(where: { $0 != a })
    else { throw MuxError(.invalidRequest, "split") }
    await c.setSuppressesFrameAcknowledgement(true)
    try await c.execute(.setSubscriptions([a, b]))
    let installed = try await waitInstall(c, pane: a)
    await c.acknowledgeFrame(installed)
    try await Task.sleep(for: .milliseconds(200))
    #expect(await c.readiness == nil)
    try await c.execute(.endPane(b))
    let ready = try await waitReady(c)
    #expect(ready.initialFrames.map(\.pane) == [a])
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
  }

  @Test
  func readyFollowsTheNewlyVisiblePanesWhenAZoomedPaneExits() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, a) = try await create(c)
    _ = try await c.attachAndShow(.id(ws))
    guard
      case let .layout(split) = try await c.execute(
        .split(pane: a, axis: .leftRight, launch: shellLaunch())
      ), let tab = split.activeTabSnapshot,
      let b = tab.layout?.panes.first(where: { $0 != a })
    else { throw MuxError(.invalidRequest, "split") }
    guard case let .layout(zoomed) = try await c.execute(.toggleZoom(tab.id)),
      let shown = zoomed.activeTabSnapshot?.zoomedPane
    else { throw MuxError(.invalidRequest, "zoom") }
    let hidden = shown == a ? b : a
    await c.setSuppressesFrameAcknowledgement(true)
    try await c.execute(.setSubscriptions([a, b]))
    // The hidden pane's frame is acknowledged before it becomes visible.
    await c.acknowledgeFrame(try await waitInstall(c, pane: hidden))
    try await Task.sleep(for: .milliseconds(200))
    #expect(await c.readiness == nil)
    try await c.execute(.endPane(shown))
    let ready = try await waitReady(c)
    #expect(ready.initialFrames.map(\.pane) == [hidden])
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
  }

  @Test
  func readyFollowsATabSwitchBeforeItIsSent() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, a) = try await create(c)
    let first = try await c.attachAndShow(.id(ws))
    let firstTab = try #require(first.activeTabSnapshot?.id)
    guard
      case let .layout(added) = try await c.execute(
        .newTab(name: "second", launch: shellLaunch())
      ), let second = added.activeTabSnapshot, second.id != firstTab
    else { throw MuxError(.invalidRequest, "tab") }
    let b = second.activePane
    guard case .layout = try await c.execute(.selectTab(firstTab)) else {
      throw MuxError(.invalidRequest, "select")
    }
    await c.setSuppressesFrameAcknowledgement(true)
    try await c.execute(.setSubscriptions([a, b]))
    // Only the hidden tab's pane is acknowledged.
    await c.acknowledgeFrame(try await waitInstall(c, pane: b))
    try await Task.sleep(for: .milliseconds(200))
    #expect(await c.readiness == nil)
    guard case .layout = try await c.execute(.selectTab(second.id)) else {
      throw MuxError(.invalidRequest, "select")
    }
    let ready = try await waitReady(c)
    #expect(ready.initialFrames.map(\.pane) == [b])
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
  }

  @Test
  func readySurvivesATabFlipAwayAndBack() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, a) = try await create(c)
    let first = try await c.attachAndShow(.id(ws))
    let firstTab = try #require(first.activeTabSnapshot?.id)
    guard
      case let .layout(added) = try await c.execute(
        .newTab(name: "second", launch: shellLaunch())
      ), let second = added.activeTabSnapshot?.id, second != firstTab
    else { throw MuxError(.invalidRequest, "tab") }
    _ = try await c.execute(.selectTab(firstTab))
    await c.setSuppressesFrameAcknowledgement(true)
    try await c.execute(.setSubscriptions([a]))
    let installed = try await waitInstall(c, pane: a)
    // Nothing subscribed is visible on the second tab; flipping back
    // needs no new subscription for Ready to follow.
    _ = try await c.execute(.selectTab(second))
    _ = try await c.execute(.selectTab(firstTab))
    await c.acknowledgeFrame(installed)
    let ready = try await waitReady(c)
    #expect(ready.initialFrames.map(\.pane) == [a])
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
  }

  @Test
  func aResentSameSizeBatchKeepsAcknowledgedFrames() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, a) = try await create(c)
    _ = try await c.attachAndShow(.id(ws), columns: 40, rows: 8)
    guard
      case let .layout(split) = try await c.execute(
        .split(pane: a, axis: .leftRight, launch: shellLaunch())
      ),
      let b = split.activeTabSnapshot?.layout?.panes.first(where: { $0 != a })
    else { throw MuxError(.invalidRequest, "split") }
    let sizes = [a, b]
      .map { GeometryBatch.Entry(pane: $0, columns: 40, rows: 8) }
    try await c.execute(
      .setGeometry(
        GeometryBatch(
          layoutRevision: split.layoutRevision,
          generation: 2,
          entries: sizes
        )
      )
    )
    await c.setSuppressesFrameAcknowledgement(true)
    try await c.execute(.setSubscriptions([a, b]))
    let first = try await waitInstall(c, pane: a)
    await c.acknowledgeFrame(first)
    // The client resends unchanged sizes on every layout revision.
    try await c.execute(
      .setGeometry(
        GeometryBatch(
          layoutRevision: split.layoutRevision,
          generation: 3,
          entries: sizes
        )
      )
    )
    await c.acknowledgeFrame(try await waitInstall(c, pane: b))
    let ready = try await waitReady(c)
    #expect(Set(ready.initialFrames.map(\.pane)) == [a, b])
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
  }

  @Test
  func endingTheLastPanePublishesTheListOnce() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, a) = try await create(c)
    _ = try await c.attachAndShow(.id(ws))
    let watcher = try await h.connect(.control)
    _ = try await watcher.execute(.observeWorkspaces(true))
    _ = try await c.execute(.endPane(a))
    let lists = try await workspaceLists(watcher)
    #expect(lists.count == 1)
    #expect(lists.first?.contains { $0.id == ws } == false)
    await c.close()
    await watcher.close()
  }

  @Test
  func endingAWorkspacePublishesTheListOnce() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, a) = try await create(c)
    _ = try await c.attachAndShow(.id(ws))
    _ = try await c.execute(
      .split(pane: a, axis: .leftRight, launch: shellLaunch())
    )
    let watcher = try await h.connect(.control)
    _ = try await watcher.execute(.observeWorkspaces(true))
    try await c.execute(.endWorkspace(.id(ws)))
    let lists = try await workspaceLists(watcher)
    #expect(lists.count == 1)
    #expect(lists.first?.contains { $0.id == ws } == false)
    await c.close()
    await watcher.close()
  }

  @Test
  func aControllersReadyWaitsForItsScrolledWindow() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    await c.setSuppressesFrameAcknowledgement(true)
    _ = try await c.attachAndShow(.id(ws), columns: 40, rows: 8)
    let before = try await waitInstall(c, pane: pane)
    // Scrolling moves the window: the earlier frame no longer counts.
    try await c.execute(.scroll(pane: pane, .lines(0)))
    await c.acknowledgeFrame(before)
    var scrolled: PaneFrame?
    let deadline = ContinuousClock.now + .seconds(10)
    while scrolled == nil, ContinuousClock.now < deadline {
      guard
        case let .frame(frame)? = try? await c.nextEvent(
          timeout: .milliseconds(100)
        ), frame.identity.pane == pane
      else { continue }
      if frame.identity.viewportRevision > before.viewportRevision {
        scrolled = frame
      } else {
        await c.acknowledgeFrame(frame.identity)
        #expect(await c.readiness == nil)
      }
    }
    let shown = try #require(scrolled)
    // Give the service time to (wrongly) publish on the stale acks.
    try await Task.sleep(for: .milliseconds(200))
    #expect(await c.readiness == nil)
    await c.acknowledgeFrame(shown.identity)
    let ready = try await waitReady(c)
    #expect(ready.initialFrames.first?.frameRevision == shown.identity.revision)
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
  }

  @Test
  func anObserversStepContinuesTheSearchSentBeforeIt() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    try await c.attachAndShow(.id(ws), columns: 40, rows: 8)
    try await c.send(
      .text("for i in 1 2 3; do echo STEP-NEEDLE-$i; done\r"),
      to: pane
    )
    _ = try await c.frame(of: pane) { $0.lines.contains("STEP-NEEDLE-3") }
    let o = try await observe(h, ws, panes: [pane])
    // Sent back to back, without waiting for the search's reply.
    let results = Mutex<[SearchResult]>([])
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      o.enqueue(.search(pane: pane, query: "STEP-NEEDLE-")) { result in
        if case let .success(.search(found)) = result {
          results.withLock { $0.append(found) }
        }
      }
      o.enqueue(.searchStep(pane: pane, forward: false)) { result in
        if case let .success(.search(found)) = result {
          results.withLock { $0.append(found) }
        }
        done.resume()
      }
    }
    let replies = results.withLock { $0 }
    try #require(replies.count == 2)
    #expect(replies[0].matchCount >= 3)
    // The search selects the newest match; the step moves past it.
    #expect(replies[1].selected == replies[0].selected.map { $0 - 1 })
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
    await o.close()
  }

  @Test
  func observerWindowIdsNeverRepeatAcrossReattach() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    let o = try await observe(h, ws, panes: [pane])
    let first = await h.service.observerWindow(ws, pane)
    await o.detach()
    _ = try await o.execute(.attach(AttachRequest(.id(ws), role: .observer)))
    try await o.execute(.setSubscriptions([pane]))
    let second = await h.service.observerWindow(ws, pane)
    #expect(first != nil)
    #expect(second != nil)
    #expect(first != second)
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
    await o.close()
  }

  @Test
  func waitingWindowCommandsFailWhenThePaneEndsOrTheObserverLeaves()
    async throws
  {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, a) = try await create(c)
    _ = try await c.attachAndShow(.id(ws))
    guard
      case let .layout(split) = try await c.execute(
        .split(pane: a, axis: .leftRight, launch: shellLaunch())
      ),
      let b = split.activeTabSnapshot?.layout?.panes.first(where: { $0 != a })
    else { throw MuxError(.invalidRequest, "split") }
    let o = try await observe(h, ws, panes: [a, b])
    let client = try #require(await h.service.observerClient(ws))
    let log = FailureLog()
    // One stalled command in progress and two waiting, on each pane.
    for pane in [a, b] {
      await h.service.queueStalledWindowCommands(
        3,
        client: client,
        workspace: ws,
        pane: pane,
        log: log
      )
    }
    #expect(log.take().isEmpty)
    _ = try await c.execute(.endPane(a))
    #expect(log.take() == [.notFound, .notFound])
    await o.detach()
    #expect(log.take() == [.notAttached, .notAttached])
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
    await o.close()
  }

  @Test
  func unsubscribingKeepsAPanesResizeFloorForReady() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    try await c.attachAndShow(.id(ws), columns: 40, rows: 8)
    guard
      case let .layout(split) = try await c.execute(
        .split(pane: pane, axis: .leftRight, launch: shellLaunch())
      ),
      let other = split.activeTabSnapshot?.layout?.panes
        .first(where: { $0 != pane })
    else { throw MuxError(.invalidRequest, "split") }
    // Not acknowledging keeps the observer's Ready pending.
    let o = try await h.connect()
    _ = try await o.execute(.attach(AttachRequest(.id(ws), role: .observer)))
    await o.setSuppressesFrameAcknowledgement(true)
    try await o.execute(.setSubscriptions([pane, other]))
    try await c.execute(
      .setGeometry(
        GeometryBatch(
          layoutRevision: split.layoutRevision,
          generation: 2,
          entries: [.init(pane: pane, columns: 30, rows: 8)]
        )
      )
    )
    let floor = try #require(await h.service.observerFloor(ws, pane))
    // Unsubscribing and resubscribing keeps the geometry its frames must
    // reach to count for Ready.
    try await o.execute(.setSubscriptions([other]))
    try await o.execute(.setSubscriptions([pane, other]))
    #expect(await h.service.observerFloor(ws, pane) == floor)
    _ = try await c.execute(.endPane(pane))
    #expect(await h.service.observerFloor(ws, pane) == nil)
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
    await o.close()
  }

  @Test
  func anObserverPaneQueuesAtMostTheWaitingLimit() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    let o = try await observe(h, ws, panes: [pane])
    let client = try #require(await h.service.observerClient(ws))
    let log = FailureLog()
    // One running (it never finishes) plus a full queue, then one more.
    let limit = MuxService.maxWaitingCommands
    await h.service.queueStalledWindowCommands(
      limit + 2,
      client: client,
      workspace: ws,
      pane: pane,
      log: log
    )
    #expect(log.take() == [.resourceLimit])
    // Unsubscribing fails the waiting ones; the stalled one keeps its turn,
    // and a resubscribe does not open a second queue beside it: if it did,
    // the first command below would run and none would be refused.
    try await o.execute(.setSubscriptions([]))
    #expect(log.take() == Array(repeating: .notFound, count: limit))
    try await o.execute(.setSubscriptions([pane]))
    await h.service.queueStalledWindowCommands(
      limit + 1,
      client: client,
      workspace: ws,
      pane: pane,
      log: log
    )
    #expect(log.take() == [.resourceLimit])
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
    await o.close()
  }

  @Test
  func anInvalidWindowCommandRepliesAfterTheOneAheadOfIt() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    let o = try await observe(h, ws, panes: [pane])
    let replies = Mutex<[(String, Result<MuxReply, MuxError>)]>([])
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      o.enqueue(.search(pane: pane, query: "$")) { result in
        replies.withLock { $0.append(("search", result)) }
      }
      // Rows without columns: refused, but in turn.
      o.enqueue(
        .setViewport(
          ViewportRequest(
            pane: pane,
            followTail: true,
            historyGeneration: 0,
            rows: 4
          )
        )
      ) { result in
        replies.withLock { $0.append(("viewport", result)) }
        done.resume()
      }
    }
    let got = replies.withLock { $0 }
    #expect(got.map(\.0) == ["search", "viewport"])
    if case .success(.search) = got.first?.1 {
    } else {
      Issue.record(
        "search did not run its turn: \(String(describing: got.first?.1))"
      )
    }
    if case let .failure(error) = got.last?.1 {
      #expect(error.code == .invalidRequest)
    } else {
      Issue.record("viewport was not refused")
    }
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
    await o.close()
  }

  @Test
  func anEndSentBehindASearchLeavesNoSearch() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    try await c.attachAndShow(.id(ws), columns: 40, rows: 8)
    let o = try await observe(h, ws, panes: [pane])
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      o.enqueue(.search(pane: pane, query: "$"))
      o.enqueue(.endSearch(pane: pane)) { _ in done.resume() }
    }
    // No search survives to step through.
    #expect(
      await rejection {
        _ = try await o.execute(.searchStep(pane: pane, forward: true))
      } == .invalidRequest
    )
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
    await o.close()
  }

  @Test
  func observerSearchCommandsNeedASubscribedPane() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    let o = try await observe(h, ws, panes: [])
    for command: MuxCommand in [
      .endSearch(pane: pane), .searchStep(pane: pane, forward: true),
      .search(pane: pane, query: "x"),
    ] {
      #expect(await rejection { _ = try await o.execute(command) } == .notFound)
    }
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
    await o.close()
  }

  @Test
  func anObserversReadyWaitsForItsMovedWindow() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, a) = try await create(c)
    _ = try await c.attachAndShow(.id(ws), columns: 40, rows: 8)
    guard
      case let .layout(split) = try await c.execute(
        .split(pane: a, axis: .leftRight, launch: shellLaunch())
      ),
      let b = split.activeTabSnapshot?.layout?.panes.first(where: { $0 != a })
    else { throw MuxError(.invalidRequest, "split") }
    let o = try await h.connect()
    _ = try await o.execute(.attach(AttachRequest(.id(ws), role: .observer)))
    await o.setSuppressesFrameAcknowledgement(true)
    try await o.execute(.setSubscriptions([a, b]))
    let before = try await waitInstall(o, pane: a)
    await o.acknowledgeFrame(before)
    // Moving A's window makes its acknowledged frame stale for Ready.
    try await pin(o, pane: a, followTail: true, generation: 0)
    await o.acknowledgeFrame(try await waitInstall(o, pane: b))
    try await Task.sleep(for: .milliseconds(200))
    #expect(await o.readiness == nil)
    // Acknowledge every A frame: old-window ones must not complete Ready.
    var moved: PaneFrame?
    let deadline = ContinuousClock.now + .seconds(10)
    while moved == nil, ContinuousClock.now < deadline {
      guard
        case let .frame(frame)? = try? await o.nextEvent(
          timeout: .milliseconds(100)
        ), frame.identity.pane == a
      else { continue }
      await o.acknowledgeFrame(frame.identity)
      if frame.identity.viewportRevision > before.viewportRevision {
        moved = frame
      } else {
        #expect(await o.readiness == nil)
      }
    }
    let shown = try #require(moved)
    let ready = try await waitReady(o)
    #expect(
      ready.initialFrames.first { $0.pane == a }?.frameRevision
        == shown.identity.revision
    )
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
    await o.close()
  }

  @Test
  func viewerScrollsClampAndRecoverFromAStaleAnchor() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    let shown = try await c.attachAndShow(.id(ws), columns: 40, rows: 8)
    try await c.send(
      .text("i=0; while [ $i -lt 40 ]; do echo row-$i; i=$((i+1)); done\r"),
      to: pane
    )
    let tail = try await c.frame(of: pane, label: "tail") {
      $0.lines.contains("row-39") && $0.history.scrollbackRows > 12
    }
    let observer = try await observe(h, ws, panes: [pane])
    // Past the oldest row stops at the top instead of failing.
    try await observer.execute(.scroll(pane: pane, .lines(1000)))
    let top = try await observer.frame(of: pane, label: "top") {
      $0.history.viewportTop == $0.history.firstRow
        && $0.history.viewportOffset > 0
    }
    #expect(top.history.firstRow == tail.history.firstRow)
    // Past the live screen resumes the tail.
    try await observer.execute(.scroll(pane: pane, .lines(-1000)))
    _ = try await observer.frame(of: pane, label: "bottom") {
      $0.history.viewportOffset == 0 && $0.lines.contains("row-39")
    }
    // A reflow makes a pinned anchor stale; `.bottom` still recovers.
    try await pin(
      observer,
      pane: pane,
      anchor: tail.history.firstRow,
      generation: tail.history.generation
    )
    try await c.execute(
      .setGeometry(
        GeometryBatch(
          layoutRevision: shown.layoutRevision,
          generation: 2,
          entries: [.init(pane: pane, columns: 50, rows: 8)]
        )
      )
    )
    _ = try await c.frame(of: pane, label: "reflowed") {
      $0.history.generation != tail.history.generation
    }
    try await observer.execute(.scroll(pane: pane, .bottom))
    let recovered = try await observer.frame(of: pane, label: "recovered") {
      $0.history.viewportOffset == 0 && $0.grid.columns == 50
    }
    #expect(recovered.history.generation != tail.history.generation)
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
    await observer.close()
  }

}
