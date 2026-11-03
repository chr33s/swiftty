import SwiftMuxClient
import SwiftMuxProtocol
@testable import Swiftty
import Testing

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct MuxGatewayRecoveryTests {
  @Test
  func authorizationFailureDoesNotRetry() async throws {
    var attempts = 0
    do {
      _ = try await MuxGatewayRecovery.waitForWorkspace(
        WorkspaceID(),
        reconnect: {
          attempts += 1
          throw MuxError(.unauthorized)
        }
      )
      Issue.record("unauthorized recovery succeeded")
    } catch let error as MuxError { #expect(error.code == .unauthorized) }
    #expect(attempts == 1)
  }

  @Test
  func retryDeadlineDoesNotStartAnotherConnection() async throws {
    var attempts = 0
    do {
      _ = try await MuxGatewayRecovery.waitForWorkspace(
        WorkspaceID(),
        reconnect: {
          attempts += 1
          throw MuxError(.connectionLost)
        },
        timeout: .milliseconds(20)
      )
      Issue.record("unavailable recovery succeeded")
    } catch let error as MuxError {
      #expect(error.code == .connectionLost)
      #expect(error.message.contains("deadline"))
    }
    #expect(attempts == 1)
  }

  @Test
  func cancellationStopsReadOnlyRetries() async throws {
    var attempts = 0
    let task = Task {
      try await MuxGatewayRecovery.waitForWorkspace(
        WorkspaceID(),
        reconnect: {
          attempts += 1
          throw MuxError(.connectionLost)
        }
      )
    }
    while attempts == 0 { await Task.yield() }
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("cancelled recovery succeeded")
    } catch is CancellationError {}
    #expect(attempts == 1)
  }

  @Test(arguments: [false, true])
  func blockedSharedHandshakeDoesNotHoldRecoveryOpen(cancel: Bool) async throws
  {
    var release: CheckedContinuation<Void, Never>?
    var finished = false
    var attempts = 0
    let task = Task {
      defer { finished = true }
      return try await MuxGatewayRecovery.waitForWorkspace(
        WorkspaceID(),
        reconnect: {
          attempts += 1
          // Deliberately ignore cancellation like a shared connection attempt.
          await withCheckedContinuation { release = $0 }
          throw MuxError(.unauthorized, "late handshake failure")
        },
        timeout: cancel ? .seconds(30) : .milliseconds(50)
      )
    }
    let setupDeadline = ContinuousClock.now + .seconds(2)
    while release == nil && ContinuousClock.now < setupDeadline {
      await Task.yield()
    }
    let unblock = try #require(release)
    if cancel { task.cancel() }
    let finishDeadline = ContinuousClock.now + .seconds(2)
    while !finished && ContinuousClock.now < finishDeadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(finished, "recovery waited for the shared handshake to settle")
    unblock.resume()
    do {
      _ = try await task.value
      Issue.record("abandoned recovery succeeded")
    } catch is CancellationError { #expect(cancel) } catch let error as MuxError
    {
      #expect(!cancel)
      #expect(error.code == .connectionLost)
      #expect(error.message.contains("deadline"))
    }
    #expect(attempts == 1)
  }

  @Test
  func stalledInventoryExpiresWithoutClosingSharedControl() async throws {
    let fixture = MuxGatewayApplicationTests.Fixture()
    defer { fixture.close() }
    let connection = try await fixture.connect()
    do {
      _ = try await MuxGatewayRecovery.waitForWorkspace(
        WorkspaceID(),
        reconnect: { connection },
        timeout: .milliseconds(50)
      )
      Issue.record("stalled inventory succeeded")
    } catch let error as MuxError {
      #expect(error.code == .connectionLost)
      #expect(error.message.contains("deadline"))
    }
    #expect(fixture.commands.withLock { $0 } == 1)
    try await connection.checkOpen()
    await connection.close()
  }

  @Test
  func lateSharedConnectionIsNotQueriedOrClosed() async throws {
    let fixture = MuxGatewayApplicationTests.Fixture()
    defer { fixture.close() }
    let connection = try await fixture.connect()
    var release: CheckedContinuation<Void, Never>?
    var returned = false
    let task = Task {
      try await MuxGatewayRecovery.waitForWorkspace(
        WorkspaceID(),
        reconnect: {
          await withCheckedContinuation { release = $0 }
          returned = true
          return connection
        },
        timeout: .milliseconds(50)
      )
    }
    while release == nil { await Task.yield() }
    do {
      _ = try await task.value
      Issue.record("blocked connection succeeded")
    } catch let error as MuxError {
      #expect(error.code == .connectionLost)
      #expect(error.message.contains("deadline"))
    }
    release?.resume()
    while !returned { await Task.yield() }
    try await connection.checkOpen()
    #expect(fixture.commands.withLock { $0 } == 0)
    await connection.close()
  }

}
