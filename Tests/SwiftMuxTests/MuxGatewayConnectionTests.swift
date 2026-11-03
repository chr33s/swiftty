import Darwin
import Dispatch
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
import SwiftMuxXPC
import Synchronization
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct MuxGatewayConnectionTests {
  @Test
  func cancellationKeepsTransmittedSlotAndBoundsQueuedCommands() async throws {
    let fake = FakeGateway()
    defer { fake.close() }
    let client = try await MuxGatewayConnection.connect(
      peerRequirement: nil,
      expectedPID: getpid(),
      channel: { .connect(endpoint: fake.endpoint, queue: $0) }
    )
    let active = Task { try await client.listWorkspaces() }
    try await waitUntil { fake.received.withLock { $0 } == 1 }
    let waiting = (0 ..< 63)
      .map { _ in Task { try await client.listWorkspaces() } }
    try await waitUntil { await client.pendingCommandCount == 64 }
    do {
      _ = try await client.listWorkspaces()
      Issue.record("unbounded client admission")
    } catch let error as MuxError { #expect(error.code == .resourceLimit) }
    for task in waiting { task.cancel() }
    for task in waiting {
      await #expect(throws: CancellationError.self) { try await task.value }
    }
    active.cancel()
    await #expect(throws: CancellationError.self) { try await active.value }
    #expect(await client.pendingCommandCount == 1)
    let next = Task { try await client.listWorkspaces() }
    try await waitUntil { await client.pendingCommandCount == 2 }
    #expect(fake.received.withLock { $0 } == 1)
    fake.reply(sequence: 1)
    try await waitUntil { fake.received.withLock { $0 } == 2 }
    fake.reply(sequence: 2)
    #expect(try await next.value.isEmpty)
    #expect(await client.pendingCommandCount == 0)
    let lost = Task { try await client.listWorkspaces() }
    try await waitUntil { fake.received.withLock { $0 } == 3 }
    let queued = Task { try await client.listWorkspaces() }
    try await waitUntil { await client.pendingCommandCount == 2 }
    fake.disconnect()
    await #expect(throws: MuxError.self) { try await lost.value }
    await #expect(throws: MuxError.self) { try await queued.value }
    #expect(fake.received.withLock { $0 } == 3)
    #expect(await client.pendingCommandCount == 0)
  }

  @Test
  func payloadReservationsSurviveActiveCancellationAndRemoteFailure()
    async throws
  {
    let fake = FakeGateway()
    defer { fake.close() }
    let client = try await MuxGatewayConnection.connect(
      peerRequirement: nil,
      expectedPID: getpid(),
      channel: { .connect(endpoint: fake.endpoint, queue: $0) }
    )
    // Logical payload fits, but JSON escaping exceeds the wire record limit.
    // A synchronous local refusal must refund the actor slot without closing it.
    do {
      try await client.createWorkspace(
        WorkspaceID(),
        request: NewWorkspaceRequest(
          name: String(repeating: "\u{1}", count: 1 << 20)
        )
      )
      Issue.record("encoded record limit was bypassed")
    } catch let error as MuxError { #expect(error.code == .resourceLimit) }
    #expect(await client.pendingCommandCount == 0)
    #expect(await client.pendingBytes == 0)
    #expect(fake.received.withLock { $0 } == 0)
    let launch = NewWorkspaceRequest(
      name: String(repeating: "a", count: 3 << 20)
    )
    let active = Task {
      try await client.createWorkspace(WorkspaceID(), request: launch)
    }
    try await waitUntil { fake.received.withLock { $0 } == 1 }
    let reserved = await client.pendingBytes
    #expect(reserved > 3 << 20)
    active.cancel()
    await #expect(throws: CancellationError.self) { try await active.value }
    #expect(await client.pendingBytes == reserved)
    do {
      try await client.createWorkspace(
        WorkspaceID(),
        request: NewWorkspaceRequest(
          name: String(repeating: "b", count: 2 << 20)
        )
      )
      Issue.record("aggregate payload limit was bypassed")
    } catch let error as MuxError { #expect(error.code == .resourceLimit) }
    let queued = Task {
      try await client.createWorkspace(
        WorkspaceID(),
        request: NewWorkspaceRequest(
          name: String(repeating: "c", count: 512 << 10)
        )
      )
    }
    try await waitUntil { await client.pendingCommandCount == 2 }
    #expect(await client.pendingBytes > reserved)
    queued.cancel()
    await #expect(throws: CancellationError.self) { try await queued.value }
    #expect(await client.pendingBytes == reserved)
    #expect(fake.received.withLock { $0 } == 1)
    fake.reply(sequence: 1, result: .failure(MuxError(.notAttached)))
    try await waitUntil { await client.pendingCommandCount == 0 }
    #expect(await client.pendingBytes == 0)
    let rejected = Task {
      try await client.createWorkspace(WorkspaceID(), request: launch)
    }
    try await waitUntil { fake.received.withLock { $0 } == 2 }
    fake.reply(sequence: 2, result: .failure(MuxError(.notAttached)))
    await #expect(throws: MuxError.self) { try await rejected.value }
    let next = Task { try await client.listWorkspaces() }
    try await waitUntil { fake.received.withLock { $0 } == 3 }
    fake.reply(sequence: 3)
    #expect(try await next.value.isEmpty)
    #expect(await client.pendingBytes == 0)
    await client.close()
  }

  private func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await condition()) {
      guard ContinuousClock.now < deadline else {
        throw MuxError(.connectionLost, "test wait timed out")
      }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  private final class FakeGateway: Sendable {
    let queue = DispatchQueue(label: "gateway-client-fake")
    let listener: SMXListener
    let received = Mutex(0)
    let channel = Mutex<SMXChannel?>(nil)
    var endpoint: SMXEndpoint { listener.endpoint }

    init() {
      listener = SMXListener(anonymousOn: queue)
      listener.activate(connectionQueue: queue) { [weak self] channel in
        guard let self else { return }
        self.channel.withLock { $0 = channel }
        channel.activate { [weak self] event in
          guard let self, case let .message(data) = event,
            let request = try? JSONDecoder()
              .decode(GatewayControlRequest.self, from: data)
          else { return }
          switch request {
          case .hello:
            channel.send(
              try! JSONEncoder()
                .encode(
                  GatewayControlEvent.welcome(
                    version: GatewayControl.version,
                    gateway: ServerInstanceID()
                  )
                )
            )
          case .command: self.received.withLock { $0 += 1 }
          case .acknowledge: break
          }
        }
      }
    }

    func reply(
      sequence: UInt64,
      result: GatewayControlResult = .success(.workspaces([]))
    ) {
      queue.async { [self] in
        channel.withLock { $0 }?
          .send(
            try! JSONEncoder()
              .encode(
                GatewayControlEvent.result(sequence: sequence, value: result)
              )
          )
      }
    }

    func disconnect() { channel.withLock { $0 }?.cancel() }

    func close() {
      queue.sync {
        channel.withLock { $0 }?.cancel()
        listener.cancel()
      }
    }
  }
}
