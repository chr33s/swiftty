#if os(macOS)
import Dispatch
import ScreenProtocol
import SessionCore
import Synchronization
@testable import TerminalHost
import Testing

extension HostSnapshotEncodingTests {
  @Test(arguments: [false, true])
  func slowSendsKeepWorkBoundedThroughCancellationAndReplacement(
    replace: Bool
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
        let encoded = Mutex<[UInt64]>([])
        let session = RoamingSession(
          id: grant.sessionID,
          service: registry.service,
          grid: grant.initialGrid,
          screenEncoder: { screen, record in
            encoded.withLock { $0.append(screen.screenRevision) }
            return record
          }
        )
        defer { _ = session.retire(when: { _ in true }) }
        try session.authorize(
          writer: grant.writerID,
          token: grant.applicationToken
        )
        var held: HeldSnapshotSends?
        let receiver = SnapshotReceiver(registry) { server in
          let transport = HeldSnapshotSends(server)
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
        var latest = try await driveFrames(
          registry,
          session,
          receiver,
          epoch: 1,
          startingAt: 1
        )
        try await hostEventually("two independent snapshot sends") {
          transport.count >= 2 ? true : nil
        }
        #expect(transport.count == 2)
        // A capture the scheduler supersedes while it encodes is discarded
        // without a send, so under load more than two encodes can precede
        // the two held sends. None may follow them: later checks require
        // these revisions to stay unchanged.
        let firstRevisions = encoded.withLock { $0 }
        #expect(firstRevisions.count >= 2)
        var destination = receiver
        var protected: UInt64 = 1
        if replace {
          let replacement = SnapshotReceiver(registry)
          destination = replacement
          guard
            case .success = await session.attach(
              replacement.attachment,
              writer: grant.writerID,
              token: grant.applicationToken
            )
          else {
            Issue.record("replacement attachment failed")
            return
          }
          protected = session.diagnostics.screenRevision
          latest = try await driveFrames(
            registry,
            session,
            replacement,
            epoch: 2,
            startingAt: 9
          )
          #expect(encoded.withLock { $0 } == firstRevisions)
          #expect(destination.snapshots.isEmpty)
        }
        defer { destination.connection.close() }
        transport.release()
        let final = try await hostEventually(
          "latest screen after send pressure"
        ) { destination.snapshots.first { $0.screenRevision == latest } }
        #expect(final.textLines.contains("OUTPUT-frame-\(replace ? 16 : 8)"))
        #expect(
          destination.snapshots.contains { $0.screenRevision == protected }
        )
        // Without a replacement the latest capture may already be one of the
        // held sends; releasing them then needs no further encoding.
        let after: [UInt64] =
          replace
          ? [protected, latest] : firstRevisions.last == latest ? [] : [latest]
        let allRevisions = encoded.withLock { $0 }
        #expect(
          allRevisions == firstRevisions + after,
          "first=\(firstRevisions) protected=\(protected) latest=\(latest)"
        )
        if replace { #expect(receiver.snapshots.isEmpty) }
      }
    )
  }

  @Test(arguments: [false, true])
  func slowEncodingKeepsProtectedAndLatestCapturesOnly(
    replace: Bool
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
        let encoded = Mutex<[UInt64]>([])
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let session = RoamingSession(
          id: grant.sessionID,
          service: registry.service,
          grid: grant.initialGrid,
          screenEncoder: { screen, record in
            let first = encoded.withLock {
              $0.append(screen.screenRevision)
              return $0.count == 1
            }
            if first, release.wait(timeout: .now() + 10) == .timedOut {
              Issue.record("encoding gate timed out")
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
        try await hostEventually("held encoder") {
          encoded.withLock { $0.count == 1 } ? true : nil
        }
        var latest = try await driveFrames(
          registry,
          session,
          receiver,
          epoch: 1,
          startingAt: 1
        )
        var destination = receiver
        var protected: UInt64 = 1
        if replace {
          let replacement = SnapshotReceiver(registry)
          destination = replacement
          guard
            case .success = await session.attach(
              replacement.attachment,
              writer: grant.writerID,
              token: grant.applicationToken
            )
          else {
            Issue.record("replacement attachment failed")
            return
          }
          protected = session.diagnostics.screenRevision
          latest = try await driveFrames(
            registry,
            session,
            replacement,
            epoch: 2,
            startingAt: 9
          )
        }
        defer { destination.connection.close() }
        #expect(latest >= 9)
        #expect(encoded.withLock { $0.count } == 1)
        release.signal()
        let latestScreen = try await hostEventually(
          "latest screen after encoding backlog"
        ) { destination.snapshots.first { $0.screenRevision == latest } }
        #expect(
          latestScreen.textLines.contains("OUTPUT-frame-\(replace ? 16 : 8)")
        )
        #expect(
          encoded.withLock { $0 }
            == (replace ? [1, protected, latest] : [1, latest])
        )
        #expect(
          destination.snapshots.contains { $0.screenRevision == protected }
        )
        if replace { #expect(receiver.snapshots.isEmpty) }
      }
    )
  }

}

/// Holds transport calls even after cancellation/close, modelling a delayed
/// asynchronous operation. Release resumes every waiter on all test outcomes.
final class HeldSnapshotSends: RSTConnection, Sendable {
  private struct State {
    var released = false
    var waiters: [CheckedContinuation<Void, Never>] = []
  }
  private let state = Mutex(State())
  private let base: InMemoryRSTConnection
  private let deliverBeforeHolding: Bool
  init(_ base: InMemoryRSTConnection, deliverBeforeHolding: Bool = false) {
    self.base = base
    self.deliverBeforeHolding = deliverBeforeHolding
  }
  var isClosed: Bool { base.isClosed }
  var count: Int { state.withLock { $0.waiters.count } }
  func start(_ handler: RSTConnectionHandler) { base.start(handler) }
  func sendControl(_ record: [UInt8]) async throws {
    try await base.sendControl(record)
  }
  func cancelSnapshot(stream: UInt64) { base.cancelSnapshot(stream: stream) }
  func close() { base.close() }
  func sendSnapshot(_ payload: [UInt8], stream: UInt64) async throws {
    if deliverBeforeHolding {
      try await base.sendSnapshot(payload, stream: stream)
    }
    await withCheckedContinuation { continuation in
      let released = state.withLock { state in
        guard !state.released else { return true }
        state.waiters.append(continuation)
        return false
      }
      if released { continuation.resume() }
    }
    if !deliverBeforeHolding {
      try await base.sendSnapshot(payload, stream: stream)
    }
  }
  func release() {
    let waiters = state.withLock { state in
      state.released = true
      defer { state.waiters.removeAll() }
      return state.waiters
    }
    for waiter in waiters { waiter.resume() }
  }
}

private func driveFrames(
  _ registry: SessionRegistry,
  _ session: RoamingSession,
  _ receiver: SnapshotReceiver,
  epoch: UInt64,
  startingAt first: Int
) async throws -> UInt64 {
  for index in first ..< first + 8 {
    let before = session.diagnostics.screenRevision
    await session.receive(
      .input(
        .init(
          attachmentEpoch: epoch,
          sequence: UInt64(index),
          operation: .committedText("frame-\(index)\n")
        )
      ),
      from: receiver.attachment
    )
    try await hostEventuallyAsync("PTY output and capture \(index)") {
      guard let lines = await liveLines(registry, session),
        lines.contains("OUTPUT-frame-\(index)"),
        session.diagnostics.screenRevision > before
      else { return nil as Bool? }
      return true
    }
  }
  return session.diagnostics.screenRevision
}
#endif
