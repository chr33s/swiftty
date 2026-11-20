import Darwin
import Dispatch
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
import SwiftMuxService
import Synchronization
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct ServiceTests {
  @Test
  func createAttachRenderAndType() async throws {
    let h = try Harness()
    let c = try await h.connect()
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(name: "t", launch: shellLaunch()))
      )
    else {
      Issue.record("no workspace");
      return
    }
    let pane = ws.tabs[0].activePane
    try await c.attachAndShow(.id(ws.id))
    try await c.send(.text("echo mux-$((40+2))\r"), to: pane)
    let frame = try await c.frame(of: pane) { $0.lines.contains("mux-42") }
    #expect(frame.grid.columns == 80)
    #expect(frame.identity.geometryGeneration == 1)
    let server = await c.welcome?.server
    #expect(frame.identity.server == server)
    try FrameValidator.validate(frame)
  }

  @Test
  func reattachKeepsSameShell() async throws {
    let h = try Harness()
    let c1 = try await h.connect()
    guard
      case let .created(ws) = try await c1.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      )
    else { throw MuxError(.invalidRequest, "unexpected reply") }
    let pane = ws.tabs[0].activePane
    try await c1.attachAndShow(.id(ws.id))
    try await c1.send(.text("X=persist; echo pid=$$\r"), to: pane)
    let first = try await c1.frame(of: pane) { f in
      f.lines.contains { $0.hasPrefix("pid=") }
    }
    let pid = first.lines.first { $0.hasPrefix("pid=") }!
    // A second interactive attachment is rejected while the first lives.
    let c2 = try await h.connect()
    await #expect(throws: MuxError.self) {
      try await c2.execute(.attach(AttachRequest(.id(ws.id))))
    }
    // Client death releases the lease; the shell keeps running.
    await c1.close()
    try await Task.sleep(for: .milliseconds(200))
    try await c2.attachAndShow(.id(ws.id))
    try await c2.send(.text("echo again=$X pid=$$\r"), to: pane)
    let again = try await c2.frame(of: pane) { f in
      f.lines.contains { $0.hasPrefix("again=persist") }
    }
    #expect(again.lines.contains("again=persist \(pid)"))
  }

  @Test
  func staleGeometryAndAttachmentAreRejected() async throws {
    let h = try Harness()
    let c = try await h.connect()
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      )
    else { throw MuxError(.invalidRequest, "unexpected reply") }
    let pane = ws.tabs[0].activePane
    let shown = try await c.attachAndShow(.id(ws.id), generation: 5)
    // Older generation.
    await #expect(throws: MuxError.self) {
      try await c.execute(
        .setGeometry(
          GeometryBatch(
            layoutRevision: shown.layoutRevision,
            generation: 4,
            entries: [.init(pane: pane, columns: 40, rows: 10)]
          )
        )
      )
    }
    // Stale layout revision after a split.
    _ = try await c.execute(
      .split(pane: pane, axis: .leftRight, launch: shellLaunch())
    )
    do {
      try await c.execute(
        .setGeometry(
          GeometryBatch(
            layoutRevision: shown.layoutRevision,
            generation: 6,
            entries: [.init(pane: pane, columns: 40, rows: 10)]
          )
        )
      )
      Issue.record("stale layout accepted")
    } catch let e as MuxError { #expect(e.code == .staleGeometry) }
    // Zero-sized panes are never applied.
    await #expect(throws: MuxError.self) {
      try await c.execute(
        .setGeometry(
          GeometryBatch(
            layoutRevision: 99,
            generation: 7,
            entries: [.init(pane: pane, columns: 0, rows: 0)]
          )
        )
      )
    }
  }

  @Test
  func splitZoomAndEndPane() async throws {
    let h = try Harness()
    let c = try await h.connect()
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      )
    else { throw MuxError(.invalidRequest, "unexpected reply") }
    let first = ws.tabs[0].activePane
    try await c.attachAndShow(.id(ws.id))
    guard
      case let .layout(after) = try await c.execute(
        .split(pane: first, axis: .topBottom, launch: shellLaunch())
      )
    else { throw MuxError(.invalidRequest, "unexpected reply") }
    let tab = after.tabs[0]
    #expect(tab.layout.panes.count == 2)
    #expect(tab.activePane != first)
    guard case let .layout(zoomed) = try await c.execute(.toggleZoom(tab.id))
    else { throw MuxError(.invalidRequest, "unexpected reply") }
    #expect(zoomed.tabs[0].zoomedPane == tab.activePane)
    guard
      case let .layout(ended) = try await c.execute(.endPane(tab.activePane))
    else { throw MuxError(.invalidRequest, "unexpected reply") }
    #expect(ended.tabs[0].layout == .pane(first))
    #expect(ended.tabs[0].zoomedPane == nil)
  }

  @Test(arguments: [false, true])
  func naturalExitDrainsFinalOutput(_ exitBeforeAttach: Bool) async throws {
    let h = try Harness()
    let c = try await h.connect()
    do {
      var spec = shellLaunch()
      spec.command = ["/bin/sh", "-c", "printf 'final-line\\n'; exit 3"]
      guard
        case let .created(ws) = try await c.execute(
          .newWorkspace(NewWorkspaceRequest(launch: spec, remainOnExit: true))
        )
      else { throw MuxError(.invalidRequest, "unexpected reply") }
      let pane = ws.tabs[0].activePane
      if exitBeforeAttach {
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
          guard
            case let .workspaces(list) = try await c.execute(
              .listWorkspaces,
              timeout: .seconds(1)
            )
          else { throw MuxError(.invalidRequest, "workspace list") }
          if list.first(where: { $0.id == ws.id })?.livePaneCount == 0 { break }
          guard ContinuousClock.now < deadline else { throw TimeoutError() }
          try await Task.sleep(for: .milliseconds(10))
        }
      }
      let attachment = try await c.attachAndShow(.id(ws.id))
      if exitBeforeAttach { #expect(attachment.pane(pane)?.exitStatus == 3) }
      var status = attachment.pane(pane)?.exitStatus
      var sawFinal = false
      let deadline = ContinuousClock.now + .seconds(10)
      while ContinuousClock.now < deadline, status == nil || !sawFinal {
        let event = try await withTimeout(deadline - ContinuousClock.now) {
          try await c.nextEvent()
        }
        guard let event else {
          throw MuxError(.connectionLost, "closed before exit output")
        }
        switch event {
        case let .frame(f) where f.identity.pane == pane:
          sawFinal = sawFinal || f.lines.contains("final-line")
        case let .paneExited(id, s, _) where id == pane: status = s
        default: break
        }
      }
      #expect(status == 3)
      #expect(sawFinal)
      try await c.execute(.endAllWorkspaces, timeout: .seconds(1))
      await c.close()
    } catch {
      _ = try? await c.execute(.endAllWorkspaces, timeout: .seconds(1))
      await c.close()
      throw error
    }
  }

  @Test
  func eventWaitTimeoutReleasesConsumerForLaterEvents() async throws {
    let h = try Harness()
    let c = try await h.connect()
    do {
      await #expect(throws: TimeoutError.self) {
        try await withTimeout(.milliseconds(50)) { try await c.nextEvent() }
      }
      try await c.execute(.observeWorkspaces(true), timeout: .seconds(1))
      var launch = shellLaunch()
      launch.command = ["/bin/sh", "-c", "exit 0"]
      guard
        case let .created(ws) = try await c.execute(
          .newWorkspace(
            NewWorkspaceRequest(launch: launch, remainOnExit: true)
          ),
          timeout: .seconds(1)
        )
      else { throw MuxError(.invalidRequest, "workspace creation") }
      let event = try await withTimeout(.seconds(1)) { try await c.nextEvent() }
      guard case let .workspaces(list)? = event else {
        throw MuxError(
          .invalidRequest,
          "workspace event missing after cancelled wait"
        )
      }
      #expect(list.contains { $0.id == ws.id })
      try await c.execute(.endAllWorkspaces, timeout: .seconds(1))
      await c.close()
    } catch {
      _ = try? await c.execute(.endAllWorkspaces, timeout: .seconds(1))
      await c.close()
      throw error
    }
  }

  @Test
  func launchFailureIsReported() async throws {
    let h = try Harness()
    let c = try await h.connect()
    var spec = shellLaunch()
    spec.command = ["/nonexistent/program"]
    do {
      try await c.execute(.newWorkspace(NewWorkspaceRequest(launch: spec)))
      Issue.record("launch should fail")
    } catch let e as MuxError { #expect(e.code == .launchFailed) }
    guard case let .workspaces(list) = try await c.execute(.listWorkspaces)
    else { throw MuxError(.invalidRequest, "unexpected reply") }
    #expect(list.isEmpty)
  }

  @Test
  func controllingTerminalAndJobControl() async throws {
    let h = try Harness()
    let c = try await h.connect()
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      )
    else { throw MuxError(.invalidRequest, "unexpected reply") }
    let pane = ws.tabs[0].activePane
    try await c.attachAndShow(.id(ws.id))
    // tty is the slave; /dev/tty opens; the shell leads its session.
    try await c.send(
      .text(
        "tty | sed 's/^/tty=/'; (echo ok > /dev/tty) && echo devtty-ok; ps -o sess= -o pgid= -p $$ | awk '{print ($1==$2)?\"leader\":\"no\"}'\r"
      ),
      to: pane
    )
    let f = try await c.frame(of: pane) { f in
      f.lines.contains("leader") || f.lines.contains("no")
    }
    #expect(f.lines.contains { $0.hasPrefix("tty=/dev/ttys") })
    #expect(f.lines.contains("devtty-ok"))
    // Ctrl-C reaches the foreground job through the line discipline.
    try await c.send(.text("sleep 30\r"), to: pane)
    try await Task.sleep(for: .milliseconds(300))
    try await c.send(.key(.character(0x63), .control), to: pane)
    try await c.send(.text("echo interrupted-$?\r"), to: pane)
    let g = try await c.frame(of: pane) { f in
      f.lines.contains { $0.contains("interrupted-130") }
    }
    #expect(g.lines.contains { $0.contains("interrupted-130") })
  }

  @Test
  func bracketedPasteAndCancelOnDisconnect() async throws {
    let h = try Harness()
    let c = try await h.connect()
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      )
    else { throw MuxError(.invalidRequest, "unexpected reply") }
    let pane = ws.tabs[0].activePane
    try await c.attachAndShow(.id(ws.id))
    // `cat -v` shows the envelope the program receives.
    try await c.send(
      .text("printf '\\033[?2004hMUX_PASTE_READY\\n'; cat -v\r"),
      to: pane
    )
    _ = try await c.frame(of: pane) { $0.lines.contains("MUX_PASTE_READY") }
    let state = try await c.paste("one\ntwo", to: pane)
    #expect(state == .completed)
    try await c.send(.text("\r"), to: pane)
    let f = try await c.frame(of: pane) { f in
      let text = f.lines.joined(separator: "\n")
      return text.contains("^[[200~one") && text.contains("two^[[201~")
    }
    let text = f.lines.joined(separator: "\n")
    #expect(text.contains("^[[200~one"))
    #expect(text.contains("two^[[201~"))
  }

  /// A paste that gives up waiting for writer credit closes its envelope
  /// on the service, so the pane's later input and pastes are admitted.
  @Test
  func abandonedPasteClosesItsEnvelope() async throws {
    let h = try Harness()
    let c = try await h.connect()
    await c.setPasteRetry(attempts: 3, delay: .milliseconds(10))
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      )
    else { throw MuxError(.invalidRequest, "unexpected reply") }
    let pane = ws.tabs[0].activePane
    try await c.attachAndShow(.id(ws.id))
    // Nothing reads the terminal while `sleep` runs, so the writer
    // stalls and its credit (256 KiB) fills.
    try await c.send(.text("sleep 3\r"), to: pane)
    try await Task.sleep(for: .milliseconds(300))
    let line = "#" + String(repeating: "p", count: 62) + "\n"
    let text = String(repeating: line, count: (320 << 10) / 64)
    #expect(try await c.paste(text, to: pane) == .partial)
    // Cancelling discarded the unstarted chunks and closed the paste.
    #expect(try await c.paste("# again\n", to: pane) == .completed)
    try await c.send(.text("echo after-cancel-$((1+1))\r"), to: pane)
    _ = try await c.frame(of: pane, timeout: .seconds(20)) {
      $0.lines.contains("after-cancel-2")
    }
  }

  /// Captures that complete after their pane was unsubscribed and
  /// subscribed again never leak frame budget.
  @Test
  func resubscribingNeverLeaksFrameBudget() async throws {
    let h = try Harness()
    let c = try await h.connect()
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: busyLaunch()))
      )
    else { throw MuxError(.invalidRequest, "unexpected reply") }
    let pane = ws.tabs[0].activePane
    try await c.attachAndShow(.id(ws.id), columns: 200, rows: 60)
    // Frames stay unacknowledged. Each burst leaves earlier captures in
    // flight; the pause lets them land in the resubscribed slot beside
    // that slot's own capture.
    for k in 0 ..< 40 {
      for _ in 0 ..< 1 + k % 3 {
        c.enqueue(.setSubscriptions([]))
        c.enqueue(.setSubscriptions([pane]))
      }
      try await Task.sleep(for: .milliseconds(10 + k % 4 * 5))
    }
    try await c.execute(.setSubscriptions([]))
    try await Task.sleep(for: .milliseconds(300))
    #expect(await h.service.pendingFrameBytes == 0)
    try await c.execute(.endWorkspace(.id(ws.id)))
    await c.close()
  }

  @Test
  func historyScrollAndSearch() async throws {
    let h = try Harness()
    let c = try await h.connect()
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      )
    else { throw MuxError(.invalidRequest, "unexpected reply") }
    let pane = ws.tabs[0].activePane
    try await c.attachAndShow(.id(ws.id), columns: 40, rows: 10)
    try await c.send(
      .text("i=0; while [ $i -lt 60 ]; do echo row-$i; i=$((i+1)); done\r"),
      to: pane
    )
    _ = try await c.frame(of: pane) { $0.lines.contains("row-59") }
    guard
      case let .search(result) = try await c.execute(
        .search(pane: pane, query: "row-7")
      )
    else { throw MuxError(.invalidRequest, "unexpected reply") }
    #expect(result.matchCount >= 1)
    let found = try await c.frame(of: pane) { $0.lines.contains("row-7") }
    #expect(found.history.viewportOffset > 0)
    let address = found.history.address(viewportRow: 0, alternateScreen: false)
    try await c.execute(.scroll(pane: pane, .bottom))
    _ = try await c.frame(of: pane) { $0.history.viewportOffset == 0 }
    // A valid address scrolls back exactly.
    try await c.execute(.scroll(pane: pane, .top(address)))
    let back = try await c.frame(of: pane) {
      $0.history.viewportTop == address.row
    }
    #expect(back.lines == found.lines)
    // A stale generation is refused rather than reinterpreted.
    var stale = address
    stale.generation &+= 99
    do {
      try await c.execute(.scroll(pane: pane, .top(stale)))
      Issue.record("stale address accepted")
    } catch let e as MuxError { #expect(e.code == .historyUnavailable) }
  }

  @Test
  func incompatibleVersionIsRejected() async throws {
    let h = try Harness()
    await #expect(throws: MuxError.self) {
      _ = try await MuxConnection.connect(
        endpoint: h.endpoint,
        frontend: .terminal,
        terminalProfile: "some-other-terminal"
      )
    }
  }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct LateSpawnTests {
  /// A split whose target pane ends while the new shell is starting: the
  /// successful late child is terminated and reaped, never attached.
  @Test
  func lateSpawnIntoEndedPaneIsReaped() async throws {
    let holdLaunch = Mutex(false)
    let started = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    var configuration = MuxServiceConfiguration(
      launcherPath: try launcherPath()
    )
    configuration.beforeLaunch = {
      if holdLaunch.withLock({ $0 }) {
        started.signal()
        proceed.wait()
      }
    }
    let service = try MuxService(configuration: configuration)
    let c = try await MuxConnection.connect(
      endpoint: service.listenAnonymously(),
      frontend: .native
    )
    defer { proceed.signal() }
    var keep = shellLaunch()
    keep.command = ["/bin/sh", "-c", "exec sleep 60"]
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: keep))
      )
    else { throw MuxError(.invalidRequest, "unexpected reply") }
    let target = ws.tabs[0].activePane
    try await c.attachAndShow(.id(ws.id))
    // A second tab keeps the workspace alive after the target ends.
    try await c.execute(.newTab(name: "other", launch: keep))
    var slow = shellLaunch()
    slow.command = ["/bin/sh", "-c", "exec sleep 60"]
    // Hold the admitted launch until ending the target commits, so this
    // always exercises the late-child cleanup rather than a scheduling race.
    holdLaunch.withLock { $0 = true }
    let split = Task {
      try await c.execute(.split(pane: target, axis: .leftRight, launch: slow))
    }
    let didStart = await withCheckedContinuation { done in
      DispatchQueue.global()
        .async {
          done.resume(returning: started.wait(timeout: .now() + 5) == .success)
        }
    }
    #expect(didStart)
    try await c.execute(.endPane(target))
    proceed.signal()
    do {
      _ = try await split.value
      Issue.record("A late child joined an ended target")
    } catch let e as MuxError { #expect(e.code == .notFound) }
    // Only the other tab's pane survives; the late child was reaped.
    var panes = -1
    for _ in 0 ..< 200 {
      guard case let .status(s) = try await c.execute(.status) else {
        throw MuxError(.invalidRequest, "unexpected reply")
      }
      panes = s.panes
      if panes == 1 { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    #expect(panes == 1)
    guard case let .workspaces(list) = try await c.execute(.listWorkspaces)
    else { throw MuxError(.invalidRequest, "unexpected reply") }
    #expect(list.first?.paneCount == 1)
    try await c.execute(.endWorkspace(.id(ws.id)))
    await c.close()
  }
}

@Suite(.timeLimit(.minutes(1)))
struct PeerIdentityTests {
  /// A peer failing the code-signing requirement is never served, and the
  /// client fails its handshake instead of waiting forever.
  @Test
  func refusedPeerFailsFast() async throws {
    var config = MuxServiceConfiguration(launcherPath: try launcherPath())
    config.peerRequirement = "identifier \"com.example.not-this-client\""
    let service = try MuxService(configuration: config)
    let endpoint = service.listenAnonymously()
    let start = ContinuousClock.now
    await #expect(throws: MuxError.self) {
      _ = try await MuxConnection.connect(
        endpoint: endpoint,
        frontend: .control
      )
    }
    #expect(
      ContinuousClock.now - start < .seconds(MuxConnection.handshakeTimeout + 2)
    )
  }
}

/// A shell printing continuously.
func busyLaunch() -> LaunchSpec {
  var spec = shellLaunch()
  spec.command = [
    "/bin/sh", "-c", "i=0; while :; do i=$((i+1)); echo $i; done",
  ]
  return spec
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct FrameFairnessTests {
  /// Two leases share a frame budget smaller than one frame; rotation
  /// keeps either from starving the other.
  @Test
  func leasesShareATinyFrameBudget() async throws {
    var limits = MuxLimits.standard
    limits.pendingFrameBudget = 1
    limits.frameIntervalNanoseconds = 0
    let h = try Harness(limits: limits)
    // Keep both leases producing small updates that internal validation can
    // process between frames. Each consumer must still acknowledge to free
    // the shared budget for its peer.
    var launch = shellLaunch()
    launch.command = [
      "/bin/sh", "-c",
      "i=0; while :; do i=$((i+1)); echo $i; /bin/sleep 0.01; done",
    ]
    var shown: [(MuxConnection, PaneID, WorkspaceID)] = []
    for name in ["one", "two"] {
      let c = try await h.connect()
      guard
        case let .created(ws) = try await c.execute(
          .newWorkspace(NewWorkspaceRequest(name: name, launch: launch))
        )
      else { throw MuxError(.invalidRequest, "unexpected reply") }
      try await c.attachAndShow(.id(ws.id))
      shown.append((c, ws.tabs[0].activePane, ws.id))
    }
    // Both consumers keep acknowledging until each has 20 frames: one
    // that stopped would hold the whole budget.
    let counts = Mutex([0, 0])
    let consumers = shown.enumerated()
      .map { i, entry in
        Task {
          let (c, pane, _) = entry
          while let event = try await c.nextEvent() {
            if case let .frame(f) = event, f.identity.pane == pane {
              counts.withLock { $0[i] += 1 }
              // Let another update queue; taking it next iteration releases
              // its budget, so both leases compete for the next admission.
              try await Task.sleep(for: .milliseconds(20))
            }
          }
        }
      }
    let deadline = ContinuousClock.now + .seconds(20)
    while counts.withLock({ $0.min()! }) < 20, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(counts.withLock { $0.allSatisfy { $0 >= 20 } })
    for (c, _, ws) in shown {
      try await c.execute(.endWorkspace(.id(ws)))
      await c.close()
    }
    for consumer in consumers { _ = try? await consumer.value }
  }
}
