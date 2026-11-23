#if os(macOS)
import Dispatch
import ScreenProtocol
import SessionCore
import Synchronization
@testable import TerminalHost
import Testing

final class SnapshotReceiver: Sendable {
  let connection: InMemoryRSTConnection
  let attachment: HostAttachment
  private let screens = Mutex<[ScreenSnapshot]>([])

  init(
    _ registry: SessionRegistry,
    wrapServer: (InMemoryRSTConnection) -> any RSTConnection = { $0 }
  ) {
    let (client, server) = InMemoryRSTConnection.pair()
    connection = client
    attachment = HostAttachment(
      connection: wrapServer(server),
      registry: registry
    )
    client.start(
      RSTConnectionHandler(
        onControl: { _ in },
        onSnapshot: { [weak self] bytes in
          guard let self else { return }
          do {
            let screen = try decodeScreen(bytes)
            screens.withLock { $0.append(screen) }
          } catch { Issue.record(error) }
        },
        onClosed: { _ in }
      )
    )
  }

  var snapshots: [ScreenSnapshot] { screens.withLock { $0 } }
}

@Suite(.timeLimit(.minutes(1)))
struct HostSnapshotEncodingTests {
  @Test(arguments: [1, 2, 4])
  func encodingFailureRetriesWithoutNewTerminalOutput(
    _ failures: Int
  ) async throws {
    // This child produces no PTY output to wake a stranded scheduler.
    try await withRegistry(
      launch: { shellLaunch("exec /bin/sleep 30") },
      { registry in
        let grant = try await registry.create(
          grid: .init(columns: 80, rows: 24)
        )
        let attempts = Mutex(0)
        let session = RoamingSession(
          id: grant.sessionID,
          service: registry.service,
          grid: grant.initialGrid,
          screenEncoder: { screen, record in
            let attempt = attempts.withLock {
              $0 += 1
              return $0
            }
            if attempt <= failures { throw FramingError.snapshotTooLarge }
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
        let screen = try await hostEventually("screen after encoding failures")
        { receiver.snapshots.first }
        #expect(attempts.withLock { $0 } == failures + 1)
        #expect(screen.screenRevision == UInt64(failures + 1))
        let streams = session.queue.sync {
          receiver.attachment.scheduler.streams
        }
        #expect(streams.count == 1)
        #expect(streams.first?.revision == screen.screenRevision)
        #expect(streams.first?.isProtected == true)
        await session.receive(
          .screenAck(
            epoch: screen.attachmentEpoch,
            screenRevision: screen.screenRevision
          ),
          from: receiver.attachment
        )
        let settled = session.queue.sync {
          receiver.attachment.scheduler.streams.isEmpty
            && !receiver.attachment.scheduler.isDirty
        }
        #expect(settled)
      }
    )
  }

  @Test(arguments: [false, true])
  func lateEncodingCannotRetireOrDeliverIntoReplacementStream(
    fails: Bool
  ) async throws {
    try await withRegistry(
      launch: { shellLaunch("exec /bin/sleep 30") },
      { registry in
        let grant = try await registry.create(
          grid: .init(columns: 80, rows: 24)
        )
        let attempts = Mutex(0)
        let started = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let session = RoamingSession(
          id: grant.sessionID,
          service: registry.service,
          grid: grant.initialGrid,
          screenEncoder: { screen, record in
            let attempt = attempts.withLock {
              $0 += 1
              return $0
            }
            if attempt == 1 {
              started.withLock { $0 = true }
              if release.wait(timeout: .now() + 10) == .timedOut {
                Issue.record("encoding gate timed out")
              }
              if fails { throw FramingError.snapshotTooLarge }
            }
            return record
          }
        )
        defer { _ = session.retire(when: { _ in true }) }
        try session.authorize(
          writer: grant.writerID,
          token: grant.applicationToken
        )
        let first = SnapshotReceiver(registry)
        let second = SnapshotReceiver(registry)
        defer {
          first.connection.close()
          second.connection.close()
        }
        guard
          case .success = await session.attach(
            first.attachment,
            writer: grant.writerID,
            token: grant.applicationToken
          )
        else {
          Issue.record("first attachment failed")
          return
        }
        try await hostEventually("held encoder") {
          started.withLock { $0 } ? true : nil
        }
        guard
          case .success = await session.attach(
            second.attachment,
            writer: grant.writerID,
            token: grant.applicationToken
          )
        else {
          Issue.record("replacement attachment failed")
          return
        }
        // Stream IDs restart per attachment. The late error is for ID 1,
        // which is also the replacement's protected stream.
        #expect(
          session.queue.sync { second.attachment.scheduler.streams.first?.id }
            == 1
        )
        release.signal()
        let screen = try await hostEventually("replacement screen") {
          second.snapshots.first
        }
        #expect(screen.attachmentEpoch == 2)
        #expect(screen.screenRevision == 2)
        #expect(first.snapshots.isEmpty)
        #expect(attempts.withLock { $0 } == 2)
        let streams = session.queue.sync { second.attachment.scheduler.streams }
        #expect(streams.count == 1)
        #expect(streams.first?.id == 1)
        #expect(streams.first?.revision == 2)
        #expect(streams.first?.isProtected == true)
      }
    )
  }
}
#endif
