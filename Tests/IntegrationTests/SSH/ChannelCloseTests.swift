import NIOCore
import NIOSSH
@testable import SSHClient
import Synchronization
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct ChannelCloseTests {
  @Test
  func rejectedChannelDoesNotDisconnectSSHAfterTheDeadline() async throws {
    let server = try await TestSSHServer.start()
    do {
      let connection = try await server.connect()
      server.state.faults.withLock { $0.rejectSessionChannel = true }
      await #expect(throws: SSHClientError.channelRequestRejected("session")) {
        _ = try await connection.openSFTP()
      }
      try await Task.sleep(for: .milliseconds(5200))
      #expect(connection.isActive)
      server.state.faults.withLock { $0.rejectSessionChannel = false }
      let client = try await connection.openSFTP()
      #expect(client.isActive)
      await client.close()
      await connection.close()
    } catch {
      await server.shutdown()
      throw error
    }
    await server.shutdown()
  }

  @Test(arguments: [false, true])
  func failedActiveChannelsReleaseSSHWithoutPeerAcknowledgement(
    localClose: Bool,
  ) async throws {
    let server = try await TestSSHServer.start()
    do {
      let connection = try await server.connect()
      let child = try await connection.withSessionChannel(
        timeout: .seconds(30),
        timeoutError: SSHClientError.channelSetupTimeout,
        initialize: { _ in },
        operation: { child, _ in child },
      )
      server.state.faults.withLock { $0.dropAllServerWrites = true }
      try await child.eventLoop
        .submit {
          if localClose {
            // Exec success after cancellation sends EOF after CHANNEL_CLOSE.
            child.close(promise: nil)
          } else {
            // A local protocol error can also fail the child without any .all
            // close to arm the watchdog first. Excess EOFs exercise that path.
            child.close(mode: .output, promise: nil)
            child.close(mode: .output, promise: nil)
          }
          child.close(mode: .output, promise: nil)
        }
        .get()
      do {
        try await child.closeFuture.get()
        Issue.record("Expected the SDK to fail the out-of-sequence EOF")
      } catch let error as NIOSSHError {
        #expect(error.type == .protocolViolation)
      }
      // Failed close drops SSH immediately; the peer need not have had time
      // to write its acknowledgement. Normal close tests observe the dropped
      // writes while waiting for the five-second fallback.
      #expect(
        try await waitUntil(timeout: .seconds(7)) { !connection.isActive }
      )
      await connection.close()
    } catch {
      await server.shutdown()
      throw error
    }
    await server.shutdown()
  }

  @Test(arguments: [false, true])
  func execCleanupReleasesTheConnectionWithoutAnAcknowledgement(
    timeout: Bool,
  ) async throws {
    let server = try await TestSSHServer.start()
    do {
      let connection = try await server.connect()
      let request = Task {
        try await connection.execute(
          command: "wait-forever",
          limits: .init(timeout: timeout ? .seconds(1) : .seconds(30)),
        )
      }
      #expect(
        try await waitUntil {
          server.state.lastExecCommand.withLock { $0 == "wait-forever" }
            && server.state.execStdinFinished.withLock { $0 }
        }
      )
      // Receiving stdin EOF proves the client handled exec success and
      // completed its output half-close before we withhold close replies.
      server.state.faults.withLock { $0.dropAllServerWrites = true }
      if !timeout { request.cancel() }
      if timeout {
        await #expect(throws: SSHClientError.execTimeout) {
          _ = try await request.value
        }
      } else {
        await #expect(throws: CancellationError.self) {
          _ = try await request.value
        }
      }
      #expect(
        try await waitUntil {
          server.state.droppedServerWrites.withLock { $0 > 0 }
        }
      )
      #expect(
        try await waitUntil(timeout: .seconds(7)) { !connection.isActive }
      )
      await connection.close()
    } catch {
      await server.shutdown()
      throw error
    }
    await server.shutdown()
  }

  @Test
  func acknowledgedCloseAndStdinEOFDoNotDisconnectSSH() async throws {
    let server = try await TestSSHServer.start()
    do {
      let connection = try await server.connect()
      let client = try await connection.openSFTP()
      await client.close()
      let finished = Mutex(false)
      let request = Task {
        defer { finished.withLock { $0 = true } }
        return try await connection.execute(command: "wait-forever")
      }
      #expect(
        try await waitUntil {
          server.state.lastExecCommand.withLock { $0 == "wait-forever" }
        }
      )
      // The first close timer must be disarmed; exec's stdin EOF must
      // not arm one.
      try await Task.sleep(for: .milliseconds(5200))
      #expect(connection.isActive)
      #expect(!finished.withLock { $0 })
      request.cancel()
      await #expect(throws: CancellationError.self) {
        _ = try await request.value
      }
      let next = try await connection.openSFTP()
      #expect(next.isActive)
      await next.close()
      await connection.close()
    } catch {
      await server.shutdown()
      throw error
    }
    await server.shutdown()
  }

  @Test(arguments: [false, true])
  func publicCloseReleasesTheChannelWhenThePeerDoesNotReply(
    sftp: Bool,
  ) async throws {
    let server = try await TestSSHServer.start()
    do {
      let connection = try await server.connect()
      let finished = Mutex(false)
      let closing: Task<Void, Never>
      if sftp {
        let client = try await connection.openSFTP()
        server.state.faults.withLock { $0.dropAllServerWrites = true }
        closing = Task {
          await client.close()
          finished.withLock { $0 = true }
        }
      } else {
        let shell = try await connection.openShell(columns: 80, rows: 24) { _ in
        }
        server.state.faults.withLock { $0.dropAllServerWrites = true }
        closing = Task {
          await shell.close()
          finished.withLock { $0 = true }
        }
      }
      #expect(
        try await waitUntil {
          server.state.droppedServerWrites.withLock { $0 > 0 }
        }
      )
      #expect(
        try await waitUntil(timeout: .seconds(7)) { finished.withLock { $0 } }
      )
      #expect(!connection.isActive)
      // Also release the old implementation: no close task escapes.
      await connection.close()
      await closing.value
    } catch {
      await server.shutdown()
      throw error
    }
    await server.shutdown()
  }

  @Test
  func cancelledSetupStillReleasesItsAcceptedChannelWithoutAReply() async throws
  {
    let server = try await TestSSHServer.start()
    do {
      let connection = try await server.connect()
      server.state.faults.withLock { $0.withholdPTYReply = true }
      let physicallyClosed = Mutex(false)
      let request = Task {
        try await connection.openShell(columns: 80, rows: 24) { event in
          if case .closed = event { physicallyClosed.withLock { $0 = true } }
        }
      }
      #expect(
        try await waitUntil { server.state.ptyRequest.withLock { $0 != nil } }
      )
      server.state.faults.withLock { $0.dropAllServerWrites = true }
      request.cancel()
      await #expect(throws: CancellationError.self) {
        _ = try await request.value
      }
      #expect(
        try await waitUntil {
          server.state.droppedServerWrites.withLock { $0 > 0 }
        }
      )
      #expect(
        try await waitUntil(timeout: .seconds(7)) {
          physicallyClosed.withLock { $0 }
        }
      )
      #expect(!connection.isActive)
      await connection.close()
    } catch {
      await server.shutdown()
      throw error
    }
    await server.shutdown()
  }
}
