#if os(macOS)
import Dispatch
import ScreenProtocol
import SessionCore
import Synchronization
@testable import TerminalHost
import Testing

extension HostSessionTests {
  @Test
  func aCapturedButUnsentScreenCannotAdvanceAcknowledgment() async throws {
    try await withRegistry(
      launch: { shellLaunch("exec /bin/sleep 30") },
      { registry in
        let grant = try await registry.create(
          grid: .init(columns: 80, rows: 24)
        )
        let entered = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let session = RoamingSession(
          id: grant.sessionID,
          service: registry.service,
          grid: grant.initialGrid,
          screenEncoder: { screen, record in
            entered.withLock { $0 = true }
            if release.wait(timeout: .now() + 10) == .timedOut {
              Issue.record("snapshot encoding gate timed out")
            }
            return record
          }
        )
        defer { _ = session.retire(when: { _ in true }) }
        try session.authorize(
          writer: grant.writerID,
          token: grant.applicationToken
        )
        let receiver = SnapshotReceiver(registry)
        defer { receiver.connection.close() }
        guard
          case .success = await session.attach(
            receiver.attachment,
            writer: grant.writerID,
            token: grant.applicationToken
          )
        else {
          Issue.record("attachment failed")
          return
        }
        try await hostEventually("snapshot encoder held") {
          entered.withLock { $0 } ? true : nil
        }
        let captured = session.diagnostics.screenRevision
        try #require(captured > 0)
        #expect(receiver.snapshots.isEmpty)
        await session.receive(
          .screenAck(epoch: 1, screenRevision: 0),
          from: receiver.attachment
        )
        #expect(session.queue.sync { receiver.attachment.isCurrent })
        await session.receive(
          .screenAck(epoch: 1, screenRevision: captured),
          from: receiver.attachment
        )
        let state = session.queue.sync {
          (
            receiver.attachment.isCurrent,
            receiver.attachment.scheduler.acknowledgedRevision
          )
        }
        #expect(!state.0)
        #expect(state.1 == 0)
      }
    )
  }

  @Test
  func screenAcknowledgmentCanPrecedeSendCompletion() async throws {
    try await withRegistry(
      launch: { shellLaunch("exec /bin/sleep 30") },
      { registry in
        let grant = try await registry.create(
          grid: .init(columns: 80, rows: 24)
        )
        let session = RoamingSession(
          id: grant.sessionID,
          service: registry.service,
          grid: grant.initialGrid
        )
        defer { _ = session.retire(when: { _ in true }) }
        try session.authorize(
          writer: grant.writerID,
          token: grant.applicationToken
        )
        var held: HeldSnapshotSends?
        let receiver = SnapshotReceiver(registry) { base in
          let transport = HeldSnapshotSends(base, deliverBeforeHolding: true)
          held = transport
          return transport
        }
        let transport = try #require(held)
        defer {
          transport.release()
          receiver.connection.close()
        }
        guard
          case .success = await session.attach(
            receiver.attachment,
            writer: grant.writerID,
            token: grant.applicationToken
          )
        else {
          Issue.record("attachment failed")
          return
        }
        let shown = try await hostEventually(
          "screen delivered before send returns"
        ) { transport.count == 1 ? receiver.snapshots.first : nil }
        await session.receive(
          .screenAck(
            epoch: shown.attachmentEpoch,
            screenRevision: shown.screenRevision
          ),
          from: receiver.attachment
        )
        let state = session.queue.sync {
          (
            receiver.attachment.isCurrent,
            receiver.attachment.scheduler.acknowledgedRevision,
            receiver.attachment.scheduler.streams.isEmpty
          )
        }
        #expect(state.0)
        #expect(state.1 == shown.screenRevision)
        #expect(state.2)
        #expect(transport.count == 1)
        #expect(!receiver.connection.isClosed)
      }
    )
  }

  @Test(arguments: [false, true])
  func futureScreenAcknowledgmentPreservesTheRetainedShell(
    maximum: Bool
  ) async throws {
    try await withRegistry(
      launch: {
        shellLaunch(
          "stty -echo; while IFS= read -r line; do printf 'OUTPUT-%s\\n' \"$line\"; done"
        )
      },
      { registry in
        let grant = try await registry.create(
          grid: .init(columns: 80, rows: 24)
        )
        let session = try #require(registry.session(grant.sessionID))
        let client = TestClient(registry, autoAck: false)
        defer { client.connection.close() }
        let attached = try await client.attached(grant)
        _ = try await client.snapshot("initial screen") { _ in true }
        let pid = try #require(await shellPID(registry, session))
        let revision =
          maximum ? UInt64.max : session.diagnostics.screenRevision + 1
        try await client.send(
          .screenAck(epoch: attached.attachmentEpoch, screenRevision: revision)
        )
        // A following ping provides a processing barrier on the buggy host:
        // it answers instead of rejecting the impossible acknowledgment.
        try? await client.send(
          .ping(epoch: attached.attachmentEpoch, nonce: 71)
        )
        let response = try await client.message(
          "future acknowledgment decision",
          timeout: .seconds(2)
        ) {
          if case .error = $0 {
            true
          } else if case .pong(_, 71) = $0 {
            true
          } else {
            false
          }
        }
        try #require(response == .error(.init(.malformed)))
        try await hostEventually(
          "invalid attachment closed",
          timeout: .seconds(2)
        ) { client.isClosed && session.status.state == .detached ? true : nil }
        #expect(await shellPID(registry, session) == pid)

        let replacement = TestClient(registry)
        defer { replacement.connection.close() }
        let resumed = try await replacement.attached(grant)
        #expect(resumed.attachmentEpoch > attached.attachmentEpoch)
        _ = try await replacement.snapshot("reattached screen") { _ in true }
        try await replacement.send(
          .input(
            .init(
              attachmentEpoch: resumed.attachmentEpoch,
              sequence: 1,
              operation: .committedText("retained\n")
            )
          )
        )
        _ = try await replacement.snapshot(
          "output after invalid acknowledgment"
        ) { $0.textLines.contains("OUTPUT-retained") }
        #expect(await shellPID(registry, session) == pid)
        #expect(!replacement.isClosed)
      }
    )
  }

  @Test
  func zeroDuplicateAndOlderScreenAcknowledgmentsRemainValid() async throws {
    try await withRegistry(
      launch: {
        shellLaunch(
          "stty -echo; while IFS= read -r line; do printf 'OUTPUT-%s\\n' \"$line\"; done"
        )
      },
      { registry in
        let grant = try await registry.create(
          grid: .init(columns: 80, rows: 24)
        )
        let client = TestClient(registry, autoAck: false)
        defer { client.connection.close() }
        let attached = try await client.attached(grant)
        let first = try await client.snapshot("initial screen") { _ in true }
        for revision in [0, first.screenRevision, first.screenRevision] {
          try await client.send(
            .screenAck(
              epoch: attached.attachmentEpoch,
              screenRevision: revision
            )
          )
        }
        for sequence in UInt64(1) ... 2 {
          try await client.send(
            .input(
              .init(
                attachmentEpoch: attached.attachmentEpoch,
                sequence: sequence,
                operation: .committedText("step-\(sequence)\n")
              )
            )
          )
          let current = try await client.snapshot(
            "screen after valid acknowledgment"
          ) {
            $0.screenRevision > first.screenRevision
              && $0.textLines.contains("OUTPUT-step-\(sequence)")
          }
          for revision in [
            current.screenRevision, first.screenRevision, 0,
            current.screenRevision,
          ] {
            try await client.send(
              .screenAck(
                epoch: attached.attachmentEpoch,
                screenRevision: revision
              )
            )
          }
        }
        try await client.send(.ping(epoch: attached.attachmentEpoch, nonce: 72))
        _ = try await client.message("valid acknowledgments processed") {
          if case .pong(_, 72) = $0 { true } else { false }
        }
        #expect(!client.isClosed)
        #expect(
          !client.messages.contains {
            if case .error = $0 { true } else { false }
          }
        )
      }
    )
  }
}
#endif
