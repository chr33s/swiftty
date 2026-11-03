import Darwin
import Dispatch
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
@testable import Swiftty
import SwiftMuxXPC
import Synchronization
import Testing

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct MuxGatewayApplicationTests {
  @Test
  func gatewayLaunchOptionsCannotInvokeLegacyRegistration() throws {
    #expect(try GatewayLaunchOptions.service(arguments: []) == nil)
    #expect(
      try GatewayLaunchOptions.service(arguments: [
        "--gateway-service", "test.gateway",
      ]) == "test.gateway"
    )
    for arguments in [
      ["--gateway-service"], ["--gateway-service", ""],
      ["--gateway-service", "bad/service"],
      ["--gateway-service", "test.gateway", "--gateway-service", "other"],
      ["--swiftmux-agent", "unregister", "--gateway-service", "test.gateway"],
      ["--gateway-service", "test.gateway", "--swiftmux-agent", "register"],
    ] {
      #expect(throws: MuxError.self) {
        try GatewayLaunchOptions.service(arguments: arguments)
      }
    }
  }

  @Test
  func
    sharedConnectionHasBoundedWaitersAndCancellationDoesNotCloseOtherCallers()
    async throws
  {
    let fixture = Fixture()
    defer { fixture.close() }
    let connection = try await fixture.connect()
    var calls = 0
    var release: CheckedContinuation<Void, Never>?
    let application = MuxGatewayApplication(connect: {
      calls += 1
      await withCheckedContinuation { release = $0 }
      return connection
    })
    let first = Task { try await application.connection() }
    try await wait { release != nil }
    let others = (0 ..< 63)
      .map { _ in Task { try await application.connection() } }
    try await wait { application.pendingCountForTesting == 64 }
    do {
      _ = try await application.connection()
      Issue.record("unbounded application connection waiters")
    } catch let error as MuxError { #expect(error.code == .resourceLimit) }
    first.cancel()
    release?.resume()
    await #expect(throws: CancellationError.self) { try await first.value }
    for other in others { #expect(try await other.value === connection) }
    #expect(calls == 1 && application.pendingCountForTesting == 0)
    #expect(try await application.connection() === connection)
    try await connection.checkOpen()
    await application.close()
    await #expect(throws: MuxError.self) { try await connection.checkOpen() }
    await #expect(throws: MuxError.self) {
      _ = try await application.connection()
    }
  }

  @Test
  func closeDisposesAConnectionThatArrivesAfterCancellation() async throws {
    let fixture = Fixture()
    defer { fixture.close() }
    let connection = try await fixture.connect()
    var release: CheckedContinuation<Void, Never>?
    let application = MuxGatewayApplication(connect: {
      // A connector may finish concurrently with shutdown.
      await withCheckedContinuation { release = $0 }
      return connection
    })
    let pending = Task { try await application.connection() }
    try await wait { release != nil }
    let closing = Task { await application.close() }
    try await wait { application.isClosed }
    release?.resume()
    await closing.value
    await #expect(throws: MuxError.self) { _ = try await pending.value }
    await #expect(throws: MuxError.self) { try await connection.checkOpen() }
    #expect(application.pendingCountForTesting == 0)
  }

  @Test
  func aLaterOperationCanConnectAgainWithoutRetryingTheFailedOperation()
    async throws
  {
    let fixture = Fixture()
    defer { fixture.close() }
    var calls = 0
    let application = MuxGatewayApplication(connect: {
      calls += 1
      if calls == 1 {
        throw MuxError(.connectionLost, "injected startup failure")
      }
      return try await fixture.connect()
    })
    await #expect(throws: MuxError.self) { _ = try await application.listing() }
    #expect(calls == 1)
    let connection = try await application.connection()
    #expect(calls == 2)
    await connection.close()
    let replacement = try await application.connection()
    #expect(calls == 3 && replacement !== connection)
    await application.close()
  }

  private func wait(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition() {
      guard ContinuousClock.now < deadline else {
        throw MuxError(.connectionLost, "app owner test timed out")
      }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  final class Fixture: Sendable {
    let listener: SMXListener
    let channels = Mutex<[SMXChannel]>([])
    let commands = Mutex(0)
    init() {
      let queue = DispatchQueue(label: "app-gateway-owner-test")
      listener = SMXListener(anonymousOn: queue)
      listener.activate(connectionQueue: queue) { [weak self] channel in
        self?.channels.withLock { $0.append(channel) }
        channel.activate { [weak self] event in
          guard case let .message(data) = event,
            let request = try? JSONDecoder()
              .decode(GatewayControlRequest.self, from: data)
          else { return }
          if case .command = request {
            self?.commands.withLock { $0 += 1 }
            return
          }
          guard case .hello = request else { return }
          channel.send(
            try! JSONEncoder()
              .encode(
                GatewayControlEvent.welcome(
                  version: GatewayControl.version,
                  gateway: ServerInstanceID()
                )
              )
          )
        }
      }
    }
    func connect() async throws -> MuxGatewayConnection {
      let endpoint = listener.endpoint
      return try await MuxGatewayConnection.connect(
        peerRequirement: nil,
        expectedPID: getpid(),
        channel: { .connect(endpoint: endpoint, queue: $0) }
      )
    }
    func close() {
      listener.cancel()
      channels.withLock { for channel in $0 { channel.cancel() } }
    }
  }
}
