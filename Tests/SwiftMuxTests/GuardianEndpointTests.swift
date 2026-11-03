import Darwin
import Dispatch
import Foundation
import SwiftMuxGuardian
import SwiftMuxProtocol
import SwiftMuxXPC
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct GuardianEndpointTests {
  @Test
  func
    publishedEndpointSurvivesPublisherConnectionAndReachesReplacementGateway()
    throws
  {
    let state = State()
    let queue = DispatchQueue(label: "guardian-endpoint-relay")
    let worker = SMXListener(anonymousOn: queue)
    let guardian = SMXListener(anonymousOn: queue)
    defer {
      state.channels.withLock { for channel in $0 { channel.cancel() } }
      worker.cancel()
      guardian.cancel()
    }
    worker.activate(connectionQueue: queue) { channel in
      state.channels.withLock { $0.append(channel) }
      channel.activate { [weak channel] event in
        if case let .message(data) = event { channel?.send(data) }
      }
    }
    let published = DispatchSemaphore(value: 0)
    guardian.activate(connectionQueue: queue) { channel in
      state.channels.withLock { $0.append(channel) }
      channel.activate(endpointHandler: { [weak channel] data, endpoint in
        #expect(channel?.peerEUID == geteuid())
        #expect(data == Data("workspace".utf8))
        state.endpoint.withLock { $0 = endpoint }
        published.signal()
      }) { [weak channel] event in
        guard case let .message(data) = event, data == Data("discover".utf8),
          let endpoint = state.endpoint.withLock({ $0 })
        else { return }
        channel?.send(Data("workspace".utf8), endpoint: endpoint)
      }
    }
    let publisher = SMXChannel.connect(
      endpoint: guardian.endpoint,
      queue: queue
    )
    publisher.activate { _ in }
    publisher.send(Data("workspace".utf8), endpoint: worker.endpoint)
    #expect(published.wait(timeout: .now() + 3) == .success)
    publisher.cancel()

    let replied = DispatchSemaphore(value: 0)
    let gateway = SMXChannel.connect(endpoint: guardian.endpoint, queue: queue)
    defer { gateway.cancel() }
    gateway.activate(endpointHandler: { data, endpoint in
      #expect(data == Data("workspace".utf8))
      let connection = SMXChannel.connect(endpoint: endpoint, queue: queue)
      state.channels.withLock { $0.append(connection) }
      connection.activate { [weak connection] event in
        if case let .message(reply) = event {
          #expect(connection?.peerPID == getpid())
          #expect(reply == Data("same worker".utf8))
          replied.signal()
        }
      }
      connection.send(Data("same worker".utf8))
    }) { _ in }
    gateway.send(Data("discover".utf8))
    #expect(replied.wait(timeout: .now() + 3) == .success)
  }

  @Test(arguments: [false, true])
  func endpointRecordsRequireOptInAndRespectReceiveLimits(oversized: Bool) {
    let state = State()
    let queue = DispatchQueue(label: "guardian-endpoint-rejection")
    let listener = SMXListener(anonymousOn: queue)
    let worker = SMXListener(anonymousOn: queue)
    worker.activate(connectionQueue: queue) { $0.cancel() }
    let closed = DispatchSemaphore(value: 0)
    listener.activate(connectionQueue: queue) { channel in
      state.channels.withLock { $0.append(channel) }
      let endpointHandler: (@Sendable (Data, SMXEndpoint) -> Void)?
      if oversized {
        endpointHandler = { _, _ in
          _ = Issue.record("oversized endpoint record reached handler")
        }
      } else {
        endpointHandler = nil
      }
      channel.activate(
        recordLimit: { oversized ? 3 : 1024 },
        endpointHandler: endpointHandler
      ) { event in
        switch event {
        case .message:
          Issue.record("endpoint record was downgraded to an ordinary command")
        case .closed: closed.signal()
        }
      }
    }
    defer {
      state.channels.withLock { for channel in $0 { channel.cancel() } }
      listener.cancel()
      worker.cancel()
    }
    let sender = SMXChannel.connect(endpoint: listener.endpoint, queue: queue)
    defer { sender.cancel() }
    sender.activate { _ in }
    sender.send(Data("four".utf8), endpoint: worker.endpoint)
    #expect(closed.wait(timeout: .now() + 3) == .success)
  }

  @Test
  func guardianDiscoverySurvivesGatewayReplacementAndEndsWithWorkerAuthority()
    throws
  {
    let server = try GuardianServer(
      launcherPath: launcherPath(),
      peerRequirement: nil
    )
    defer {
      let stopped = DispatchSemaphore(value: 0)
      server.shutdown { stopped.signal() }
      #expect(stopped.wait(timeout: .now() + 5) == .success)
    }
    let workspace = WorkspaceID()
    let endpoint = server.listenAnonymously()
    let token = try server.provisionWorker(workspace: workspace, pid: getpid())
    let queue = DispatchQueue(label: "endpoint-publishing-worker")
    let service = SMXListener(anonymousOn: queue)
    service.activate(connectionQueue: queue) { $0.cancel() }
    defer { service.cancel() }
    let ready = DispatchSemaphore(value: 0)
    let published = DispatchSemaphore(value: 0)
    let instance = ServerInstanceID()
    let worker = try GuardianWorkerConnection(
      channel: .connect(endpoint: endpoint, queue: queue),
      workspace: workspace,
      token: token,
      peerRequirement: nil,
      handlers: .init(
        ready: { _ in ready.signal() },
        endpointPublished: { value in
          #expect(value == instance);
          published.signal()
        },
        output: { _, _, _ in },
        inputReleased: { _, _ in },
        exited: { _, _, _ in },
        progress: { $0() },
        closed: { _ in }
      )
    )
    defer { queue.sync { worker.close() } }
    #expect(ready.wait(timeout: .now() + 3) == .success)
    #expect(server.workerEndpoint(workspace: workspace) == nil)
    try queue.sync {
      try worker.publishEndpoint(service.endpoint, instance: instance)
    }
    #expect(published.wait(timeout: .now() + 3) == .success)
    let first = try #require(server.workerEndpoint(workspace: workspace))
    #expect(first.instance == instance && first.pid == getpid())
    server.replaceGateway(UUID())
    server.replaceGateway(UUID())
    let second = try #require(server.workerEndpoint(workspace: workspace))
    #expect(
      second.instance == first.instance && second.authority == first.authority
    )
    queue.sync {
      #expect(throws: MuxError.self) {
        try worker.publishEndpoint(
          service.endpoint,
          instance: ServerInstanceID()
        )
      }
    }
    #expect(server.workerEndpoint(workspace: workspace)?.instance == instance)
    queue.sync { worker.close() }
    let deadline = ContinuousClock.now + .seconds(3)
    while server.workerEndpoint(workspace: workspace) != nil {
      try #require(ContinuousClock.now < deadline)
      Thread.sleep(forTimeInterval: 0.01)
    }
  }

  @Test
  func unadmittedConnectionCannotPublishAnEndpoint() throws {
    let server = try GuardianServer(
      launcherPath: launcherPath(),
      peerRequirement: nil
    )
    defer {
      let stopped = DispatchSemaphore(value: 0)
      server.shutdown { stopped.signal() }
      #expect(stopped.wait(timeout: .now() + 5) == .success)
    }
    let endpoint = server.listenAnonymously()
    let queue = DispatchQueue(label: "unadmitted-publisher")
    let service = SMXListener(anonymousOn: queue)
    service.activate(connectionQueue: queue) { $0.cancel() }
    defer { service.cancel() }
    let rejected = DispatchSemaphore(value: 0)
    let channel = SMXChannel.connect(endpoint: endpoint, queue: queue)
    defer { channel.cancel() }
    channel.activate { event in
      if case let .message(data) = event,
        let response = try? JSONDecoder()
          .decode(GuardianEvent.self, from: data),
        case let .refused(error) = response
      {
        #expect(error.code == .unauthorized)
        rejected.signal()
      }
    }
    channel.send(Data("{}".utf8), endpoint: service.endpoint)
    #expect(rejected.wait(timeout: .now() + 3) == .success)
    #expect(server.inventory().isEmpty)
  }

  @Test(arguments: [false, true])
  func gatewayUpdatesCoalesceUntilAppliedAndFailureFencesTheWorker(
    timeout: Bool
  ) throws {
    let server = try GuardianServer(
      launcherPath: launcherPath(),
      peerRequirement: nil
    )
    defer {
      let stopped = DispatchSemaphore(value: 0)
      server.shutdown { stopped.signal() }
      #expect(stopped.wait(timeout: .now() + 5) == .success)
    }
    let workspace = WorkspaceID()
    let endpoint = server.listenAnonymously()
    let token = try server.provisionWorker(workspace: workspace, pid: getpid())
    let queue = DispatchQueue(label: "gateway-application-test")
    let service = SMXListener(anonymousOn: queue)
    service.activate(connectionQueue: queue) { $0.cancel() }
    defer { service.cancel() }
    let state = Bindings()
    let ready = DispatchSemaphore(value: 0)
    let updated = DispatchSemaphore(value: 0)
    let closed = DispatchSemaphore(value: 0)
    let worker = try GuardianWorkerConnection(
      channel: .connect(endpoint: endpoint, queue: queue),
      workspace: workspace,
      token: token,
      peerRequirement: nil,
      handlers: .init(
        ready: { _ in ready.signal() },
        gatewayChanged: { binding, completion in
          state.values.append(binding)
          state.completions.append(completion)
          updated.signal()
        },
        output: { _, _, _ in },
        inputReleased: { _, _ in },
        exited: { _, _, _ in },
        progress: { $0() },
        closed: { error in
          state.error.withLock { $0 = error };
          closed.signal()
        }
      )
    )
    defer { queue.sync { worker.close() } }
    #expect(ready.wait(timeout: .now() + 3) == .success)
    try queue.sync {
      try worker.publishEndpoint(service.endpoint, instance: ServerInstanceID())
    }
    #expect(updated.wait(timeout: .now() + 3) == .success)
    var latest = UUID()
    for _ in 0 ..< 100 {
      latest = UUID()
      server.replaceGateway(latest)
    }
    let writer = try server.grantWriter(workspace: workspace, gateway: latest)
    #expect(!server.gatewayReady(workspace: workspace, gateway: latest))
    queue.sync {
      #expect(state.values.count == 1)
      #expect(state.values[0].gateway == nil)
      state.completions.removeFirst()(nil)
    }
    #expect(updated.wait(timeout: .now() + 3) == .success)
    #expect(!server.gatewayReady(workspace: workspace, gateway: latest))
    queue.sync {
      #expect(state.values.count == 2)
      #expect(state.values[1].revision == 102)
      #expect(state.values[1].gateway == latest)
      #expect(state.values[1].writer == writer)
      state.completions.removeFirst()(nil)
    }
    let deadline = ContinuousClock.now + .seconds(3)
    while !server.gatewayReady(workspace: workspace, gateway: latest) {
      try #require(ContinuousClock.now < deadline)
      Thread.sleep(forTimeInterval: 0.01)
    }
    server.revokeGateway(latest)
    #expect(updated.wait(timeout: .now() + 3) == .success)
    queue.sync {
      #expect(state.values.count == 3)
      #expect(state.values[2].gateway == nil && state.values[2].writer == nil)
      if !timeout {
        state.completions.removeFirst()(
          MuxError(.unauthorized, "injected binding rejection")
        )
      }
    }
    #expect(closed.wait(timeout: .now() + 8) == .success)
    #expect(
      state.error.withLock { $0?.code }
        == (timeout ? .connectionLost : .unauthorized)
    )
    if timeout {
      #expect(
        state.error.withLock {
          $0?.description.contains("gateway binding timed out")
        } == true
      )
    }
    #expect(!server.gatewayReady(workspace: workspace, gateway: nil))
  }

  private final class Bindings: @unchecked Sendable {
    var values: [GuardianGatewayBinding] = []
    var completions: [@Sendable (MuxError?) -> Void] = []
    let error = Mutex<MuxError?>(nil)
  }

  private final class State: Sendable {
    let endpoint = Mutex<SMXEndpoint?>(nil)
    let channels = Mutex<[SMXChannel]>([])
  }
}
