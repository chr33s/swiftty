#if os(macOS)
import Darwin
import Foundation
import ScreenProtocol
import SessionCore
import SwiftMuxProtocol
import Synchronization
@testable import TerminalHost
import TestSupport
import Testing

private func input(
  _ epoch: UInt64,
  _ sequence: UInt64,
  _ operation: InputOperation
) -> ControlMessage {
  .input(
    .init(attachmentEpoch: epoch, sequence: sequence, operation: operation)
  )
}

@Suite(.timeLimit(.minutes(1)))
struct HostSessionTests {
  @Test(arguments: [false, true])
  func exhaustedResizeRevisionIsRejectedBeforeChangingGeometry(
    _ pending: Bool
  ) async throws {
    try await withRegistry { registry in
      let grant = try await registry.create(
        grid: GridSize(columns: 80, rows: 24)
      )
      let session = try #require(registry.session(grant.sessionID))
      let client = TestClient(registry)
      defer { client.connection.close() }
      _ = try await client.attached(grant)
      _ = try await client.snapshot("initial prompt") {
        screenText($0).contains("$")
      }
      let pid = try #require(await shellPID(registry, session))
      let release = DispatchSemaphore(value: 0)
      defer { release.signal() }
      if pending {
        let blocked = Mutex(false)
        registry.service.queue.async {
          blocked.withLock { $0 = true }
          if release.wait(timeout: .now() + 10) == .timedOut {
            Issue.record("resize service gate timed out")
          }
        }
        try await hostEventually("resize service gate") {
          blocked.withLock { $0 } ? true : nil
        }
      }
      let resize = input(
        1,
        1,
        .resize(columns: 90, rows: 30, resizeRevision: UInt64.max)
      )
      try await client.send(resize)
      if !pending {
        _ = try await client.message("maximum resize ack") {
          if case .inputAck(1, 1) = $0 { true } else { false }
        }
      }
      try await client.send(
        input(1, 2, .resize(columns: 100, rows: 35, resizeRevision: UInt64.max))
      )
      _ = try await client.message("exhausted resize refused") {
        if case let .error(error) = $0 {
          error.code == .limitExceeded && error.sequence == 2
        } else {
          false
        }
      }
      if pending {
        #expect(session.diagnostics.lastAppliedInput == 0)
        #expect(session.diagnostics.pendingInputOperations == 1)
        #expect(session.diagnostics.resizeRevision == 0)
        release.signal()
      }
      _ = try await client.message("maximum resize ack") {
        if case .inputAck(1, 1) = $0 { true } else { false }
      }
      #expect(session.diagnostics.lastAppliedInput == 1)
      #expect(session.diagnostics.pendingInputOperations == 0)
      #expect(!session.diagnostics.writerFailed)
      try await client.send(resize)
      try await hostEventually("duplicate resize acknowledged") {
        client.messages
          .filter { if case .inputAck(1, 1) = $0 { true } else { false } }.count
          == 2 ? true : nil
      }
      try await client.send(
        input(1, 2, .committedText("echo retained-$((40+2))"))
      )
      try await client.send(input(1, 3, .key(SemanticKey(.enter))))
      _ = try await client.message("input after refused resize") {
        if case .inputAck(1, 3) = $0 { true } else { false }
      }
      let shown = try await client.snapshot("retained shell output") {
        $0.textLines.contains("retained-42")
      }
      #expect(shown.columns == 90 && shown.rows == 30)
      #expect(shown.resizeRevision == UInt64.max)
      #expect(await shellPID(registry, session) == pid)
    }
  }

  @Test
  func `typed input appears in a snapshot after attaching`() async throws {
    try await withRegistry { registry in
      let grant = try await registry.create(
        grid: GridSize(columns: 80, rows: 24)
      )
      let session = try #require(registry.session(grant.sessionID))
      // The SwiftMux service owns the shell from creation; the grant is
      // reserved until the first attachment.
      #expect(session.status.state == .reserved)

      let client = TestClient(registry)
      let attached = try await client.attached(grant)
      #expect(attached.attachmentEpoch == 1)
      #expect(attached.writerID == grant.writerID)
      #expect(attached.lastFullyAppliedInputSequence == 0)
      #expect(attached.partialInputSequence == nil)
      #expect(await shellPID(registry, session) != nil)
      #expect(session.status.state == .attached)
      // The remote attachment holds the workspace lease.
      let list = try await registry.workspaces()
      #expect(list.first?.leaseHolder?.transport == .remote)
      _ = try await client.snapshot("prompt") { screenText($0).contains("$") }

      try await client.send(input(1, 1, .committedText("echo hello-$((40+2))")))
      try await client.send(input(1, 2, .key(SemanticKey(.enter))))
      _ = try await client.message("InputAck 2") {
        if case .inputAck(1, 2) = $0 { return true }
        return false
      }
      let shown = try await client.snapshot("command output") {
        $0.textLines.contains("hello-42")
      }
      #expect(shown.attachmentEpoch == 1)
      #expect(shown.lastFullyAppliedInputSequence <= 2)
      #expect(client.badFrames == 0)

      try await client.send(.ping(epoch: 1, nonce: 77))
      _ = try await client.message("Pong") {
        if case .pong(1, 77) = $0 { return true }
        return false
      }
      // Duplicate of an applied operation: acknowledged, not rewritten.
      try await client.send(input(1, 1, .committedText("echo hello-$((40+2))")))
      try await hostEventually("second ack") {
        client.messages
          .filter {
            if case .inputAck(1, 1) = $0 { return true }
            return false
          }
          .count == 2 ? true : nil
      }
    }
  }

  @Test
  func
    `losing the connection keeps the shell and reattach fences the old epoch`()
    async throws
  {
    try await withRegistry { registry in
      let grant = try await registry.create(
        grid: GridSize(columns: 80, rows: 24)
      )
      let session = try #require(registry.session(grant.sessionID))
      let first = TestClient(registry)
      _ = try await first.attached(grant)
      try await first.send(input(1, 1, .committedText("echo marker-$((1+1))")))
      try await first.send(input(1, 2, .key(SemanticKey(.enter))))
      _ = try await first.snapshot("marker") {
        $0.textLines.contains("marker-2")
      }
      let pid = try #require(await shellPID(registry, session))

      // A1: abrupt loss never signals the shell.
      first.connection.sever()
      try await hostEventually("detached") {
        session.status.state == .detached ? true : nil
      }
      try await Task.sleep(for: .milliseconds(200))
      #expect(isAlive(pid))
      #expect(await shellPID(registry, session) == pid)

      let second = TestClient(registry)
      let attached = try await second.attached(grant)
      #expect(attached.attachmentEpoch == 2)
      #expect(attached.lastFullyAppliedInputSequence == 2)
      let current = try await second.snapshot("current screen") {
        $0.attachmentEpoch == 2
      }
      #expect(current.textLines.contains("marker-2"))

      // Input scoped to the old epoch is rejected and never applied.
      try await second.send(input(1, 3, .committedText("echo stale")))
      #expect(try await second.errorCode() == .staleEpoch)
      #expect(session.diagnostics.lastAppliedInput == 2)

      // A newer attachment fences (closes) the current one.
      let third = TestClient(registry)
      let latest = try await third.attached(grant)
      #expect(latest.attachmentEpoch == 3)
      try await hostEventually("fenced connection closed") {
        second.isClosed ? true : nil
      }
      await #expect(throws: (any Error).self) {
        try await second.send(input(2, 3, .committedText("x")))
      }
      #expect(isAlive(pid))

      // Detach keeps the session.
      try await third.send(.detach(epoch: 3))
      _ = try await third.message("Detached") {
        if case .detached(3) = $0 { return true }
        return false
      }
      try await hostEventually("detached state") {
        session.status.state == .detached ? true : nil
      }
      #expect(isAlive(pid))
    }
  }

  @Test
  func `viewport requests show this client's history window only`() async throws
  {
    try await withRegistry { registry in
      let grant = try await registry.create(
        grid: GridSize(columns: 40, rows: 8)
      )
      let session = try #require(registry.session(grant.sessionID))
      let client = TestClient(registry)
      let attached = try await client.attached(grant)
      #expect(attached.features.contains(.historyViewport))
      _ = try await client.snapshot("prompt") { screenText($0).contains("$") }
      try await client.send(
        input(
          1,
          1,
          .committedText(
            "i=0; while [ $i -lt 200 ]; do echo hist-$i; i=$((i+1)); done"
          )
        )
      )
      try await client.send(input(1, 2, .key(SemanticKey(.enter))))
      _ = try await client.snapshot("output") {
        $0.textLines.contains("hist-199")
      }
      // Scroll this attachment back through the pane's history.
      try await client.send(.viewport(epoch: 1, lines: 100))
      let window = try await client.snapshot("history window") { shot in
        shot.textLines.contains { $0.hasPrefix("hist-") }
          && !shot.textLines.contains("hist-199")
      }
      let shownRows = window.textLines.compactMap {
        $0.hasPrefix("hist-") ? Int($0.dropFirst(5)) : nil
      }
      #expect(!shownRows.isEmpty && shownRows.max()! < 199)
      #expect(!window.cursor.visible)
      // The host's own view stays at live output.
      let live = try #require(await session.currentSnapshot())
      #expect(live.textLines.contains { $0.contains("$") })
      // Moving past the newest line returns to live output.
      try await client.send(.viewport(epoch: 1, lines: -1_000))
      _ = try await client.snapshot("back to live") { shot in
        shot.cursor.visible && shot.textLines.contains { $0.contains("$") }
      }
      // Input also returns a window to live output.
      try await client.send(.viewport(epoch: 1, lines: 50))
      _ = try await client.snapshot("window again") { !$0.cursor.visible }
      try await client.send(input(1, 3, .committedText("echo after-$((1+1))")))
      try await client.send(input(1, 4, .key(SemanticKey(.enter))))
      _ = try await client.snapshot("live after input") {
        $0.cursor.visible && $0.textLines.contains("after-2")
      }
      #expect(client.badFrames == 0)
    }
  }

  @Test
  func `a burst of viewport requests moves by its whole distance`() async throws {
    try await withRegistry { registry in
      let grant = try await registry.create(
        grid: GridSize(columns: 40, rows: 8)
      )
      let client = TestClient(registry)
      _ = try await client.attached(grant)
      _ = try await client.snapshot("prompt") { screenText($0).contains("$") }
      try await client.send(
        input(
          1,
          1,
          .committedText(
            "i=0; while [ $i -lt 300 ]; do echo row-$i; i=$((i+1)); done"
          )
        )
      )
      try await client.send(input(1, 2, .key(SemanticKey(.enter))))
      let live = try await client.snapshot("output") {
        $0.textLines.contains("row-299")
      }
      func rows(_ shot: ScreenSnapshot) -> [Int] {
        shot.textLines.compactMap {
          $0.hasPrefix("row-") ? Int($0.dropFirst(4)) : nil
        }
      }
      let newest = try #require(rows(live).max())
      // Twenty small steps, as a swipe sends them, without waiting.
      for _ in 0 ..< 20 { try await client.send(.viewport(epoch: 1, lines: 5)) }
      let window = try await client.snapshot("moved 100 lines") { shot in
        guard let top = rows(shot).min() else { return false }
        return top <= newest - 100
      }
      #expect(!window.cursor.visible)
      #expect(client.badFrames == 0)
    }
  }

  @Test
  func `output keeps draining while detached and reattach shows current state`()
    async throws
  {
    try await withRegistry { registry in
      let grant = try await registry.create(
        grid: GridSize(columns: 80, rows: 24)
      )
      let session = try #require(registry.session(grant.sessionID))
      let client = TestClient(registry)
      _ = try await client.attached(grant)
      _ = try await client.snapshot("prompt") { screenText($0).contains("$") }
      try await client.send(
        input(
          1,
          1,
          .committedText(
            "i=0; while [ $i -lt 150000 ]; do i=$((i+1)); echo \"tick $i\"; "
              + "done; echo DONE-$i"
          )
        )
      )
      try await client.send(input(1, 2, .key(SemanticKey(.enter))))
      _ = try await client.message("ack") {
        if case .inputAck(1, 2) = $0 { return true }
        return false
      }
      client.connection.sever()
      // A5: the service keeps parsing about 1.6 MB while detached.
      let deadline = ContinuousClock.now + .seconds(45)
      while await
        !(session.currentSnapshot()?.textLines.contains("DONE-150000") ?? false)
      {
        guard ContinuousClock.now < deadline else {
          throw HostTestTimeout(what: "loop finished")
        }
        try await Task.sleep(for: .milliseconds(50))
      }
      #expect(session.diagnostics.pendingInputOperations == 0)

      let again = TestClient(registry)
      _ = try await again.attached(grant)
      let current = try await again.snapshot("current state") {
        $0.attachmentEpoch == 2
      }
      #expect(current.textLines.contains("DONE-150000"))
      #expect(current.textLines.contains("tick 150000"))
      #expect(!current.textLines.contains("tick 1"))
      #expect(current.rows == 24)
    }
  }

  @Test
  func `resizes during alternate screen survive reattachment`() async throws {
    try await withRegistry { registry in
      let grant = try await registry.create(
        grid: GridSize(columns: 80, rows: 24)
      )
      let client = TestClient(registry)
      _ = try await client.attached(grant)
      _ = try await client.snapshot("prompt") { screenText($0).contains("$") }
      try await client.send(
        input(1, 1, .committedText("printf '\\033[?1049h'"))
      )
      try await client.send(input(1, 2, .key(SemanticKey(.enter))))
      _ = try await client.snapshot("alternate") {
        $0.activeBuffer == .alternate
      }

      let sizes = [(100, 30), (60, 20), (150, 50), (120, 40)]
      for (i, size) in sizes.enumerated() {
        try await client.send(
          input(
            1,
            UInt64(3 + i),
            .resize(
              columns: size.0,
              rows: size.1,
              resizeRevision: UInt64(i + 1)
            )
          )
        )
      }
      _ = try await client.message("resize ack") {
        if case .inputAck(1, 6) = $0 { return true }
        return false
      }
      try await client.send(input(1, 7, .committedText("stty size")))
      try await client.send(input(1, 8, .key(SemanticKey(.enter))))
      let resized = try await client.snapshot("stty size") {
        $0.textLines.contains("40 120")
      }
      #expect(resized.columns == 120 && resized.rows == 40)
      #expect(resized.activeBuffer == .alternate)
      #expect(resized.resizeRevision == 4)
      #expect(resized.cursor.row < 40 && resized.cursor.column <= 120)

      client.connection.sever()
      let again = TestClient(registry)
      let attached = try await again.attached(grant)
      #expect(attached.resizeRevision == 4)
      let current = try await again.snapshot("reattached") {
        $0.attachmentEpoch == 2
      }
      #expect(current.columns == 120 && current.rows == 40)
      #expect(current.activeBuffer == .alternate)
      #expect(current.resizeRevision == 4)
      #expect(current.textLines.contains("40 120"))
    }
  }

  @Test
  func
    `terminal queries are answered once on the host and not sent to the client`()
    async throws
  {
    let script =
      "stty -echo -icanon min 1; printf 'Q\\033[6n'; "
      + "r=$(dd bs=1 count=6 2>/dev/null | od -An -c | tr -d ' \\n'); "
      + "echo; echo \"GOT:$r\"; sleep 30"
    try await withRegistry(
      launch: { shellLaunch(script) },
      { registry in
        let grant = try await registry.create(
          grid: GridSize(columns: 40, rows: 10)
        )
        let client = TestClient(registry)
        _ = try await client.attached(grant)
        _ = try await client.snapshot("reply read by the program") {
          $0.textLines.contains("GOT:033[1;2R")
        }
        try await Task.sleep(for: .milliseconds(200))
        // Answered by the pane's engine; no user input was sent. Nothing
        // reached the client except attachment metadata and screens.
        for message in client.messages {
          if case .attached = message { continue }
          Issue.record("unexpected message \(message.typeName)")
        }
      }
    )
  }

  @Test
  func `shell exit retains the final screen and status`() async throws {
    try await withRegistry(
      launch: { shellLaunch("echo FINAL-OUTPUT; exit 3") },
      { registry in
        let grant = try await registry.create(
          grid: GridSize(columns: 40, rows: 10)
        )
        let session = try #require(registry.session(grant.sessionID))
        let client = TestClient(registry)
        _ = try await client.attached(grant)
        let exited = try await client.message("SessionExited") {
          if case .sessionExited = $0 { return true }
          return false
        }
        guard case let .sessionExited(epoch, status, revision) = exited else {
          return
        }
        #expect(epoch == 1 && status == 3)
        let final = try await client.snapshot("final screen") {
          $0.screenRevision == revision
        }
        #expect(final.textLines.contains("FINAL-OUTPUT"))
        #expect(session.status.state == .exited)
        #expect(try await registry.list().first?.state == .exited)
        #expect(try await registry.list().first?.exitStatus == 3)

        try await client.send(input(1, 1, .committedText("x")))
        #expect(try await client.errorCode() == .sessionExited)

        // Reattaching within the retention window shows the final screen.
        let again = TestClient(registry)
        _ = try await again.attached(grant)
        let shown = try await again.snapshot("retained") {
          $0.attachmentEpoch == 2
        }
        #expect(shown.textLines.contains("FINAL-OUTPUT"))
        _ = try await again.message("SessionExited again") {
          if case .sessionExited(2, 3, _) = $0 { return true }
          return false
        }

        // Never swept while a client is attached to it.
        #expect(await registry.sweep(now: .now + .seconds(301)).isEmpty)
        again.connection.sever()
        try await hostEventually("detached") {
          session.status.isAttached ? nil : true
        }
        #expect(await registry.sweep(now: .now + .seconds(240)).isEmpty)
        #expect(
          await registry.sweep(now: .now + .seconds(301)) == [grant.sessionID]
        )
        // This host created the workspace and its shell exited: it ends.
        #expect(try await registry.list().isEmpty)
      }
    )
  }

  @Test
  func `terminate kills the process group with escalation`() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let script =
      "trap '' HUP TERM; sleep 300 & echo $! > \"$HOME/bg\"; echo READY; wait"
    try await withRegistry(
      launch: { shellLaunch(script, in: directory) },
      { registry in
        let grant = try await registry.create(
          grid: GridSize(columns: 40, rows: 10)
        )
        let session = try #require(registry.session(grant.sessionID))
        let client = TestClient(registry)
        _ = try await client.attached(grant)
        _ = try await client.snapshot("ready") {
          $0.textLines.contains("READY")
        }
        let shell = try #require(await shellPID(registry, session))
        let background = try await hostEventually("background pid") {
          (try? String(
            contentsOf: directory.appendingPathComponent("bg"),
            encoding: .utf8
          ))
          .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        #expect(isAlive(shell) && isAlive(background))

        try await client.send(.terminate(epoch: 1))
        _ = try await client.message("Terminated") {
          if case .terminated(1) = $0 { return true }
          return false
        }
        // SIGHUP is ignored; the pane's SIGKILL ends the group.
        try await hostEventually("process group gone", timeout: .seconds(10)) {
          !isAlive(shell) && !isAlive(background) ? true : nil
        }
        try await hostEventually("session removed") {
          registry.session(grant.sessionID) == nil ? true : nil
        }
        #expect(session.status.state == .terminated)

        // The revoked capability no longer attaches.
        let late = TestClient(registry)
        try await late.attach(grant)
        #expect(try await late.errorCode() == .unknownSession)
      }
    )
  }
}
#endif
