import Darwin
import Dispatch
import Foundation
import SwiftMuxClient
import SwiftMuxGuardian
import SwiftMuxProtocol
import SwiftMuxService
import SwiftMuxXPC
import Synchronization
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct GuardianGatewayTests {
  @Test
  func duplicateSelectionDuringPublicationRunsOnce() throws {
    let fixture = try GuardianBuildRegistryTests.Fixture()
    defer { fixture.remove() }
    let registry = try fixture.registry()
    try registry.select("one")
    let io = DispatchQueue(label: "duplicate-selection-storage")
    let release = DispatchSemaphore(value: 0)
    io.async { release.wait() }
    let guardian = try GuardianServer(
      launcherPath: launcherPath(),
      peerRequirement: nil,
      buildSelectionQueue: io
    )
    let control = GuardianGatewayServer(
      guardian: guardian,
      peerRequirement: nil,
      buildRegistry: registry,
      workerMachService: "qualification.unused"
    )
    let endpoint = control.listenAnonymously()
    defer {
      release.signal()
      control.close()
      let stopped = DispatchSemaphore(value: 0)
      guardian.shutdown { stopped.signal() }
      #expect(waitFor(stopped, seconds: 8))
    }
    let gateway = try Gateway(endpoint)
    defer { gateway.channel.cancel() }
    _ = try gateway.command(.setAdmissionPaused(true, expectedRevision: 0))
    let request = gateway.request(
      .selectWorkerBuild("two", expectedRevision: 1)
    )
    gateway.send(request)
    gateway.send(request)
    let deadline = Date().addingTimeInterval(5)
    while try guardian.admissionStatus(gateway: gateway.identity)
      .selectionPending != true && Date() < deadline
    { Thread.sleep(forTimeInterval: 0.01) }
    #expect(
      try guardian.admissionStatus(gateway: gateway.identity).selectionPending
        == true
    )
    release.signal()
    guard case let .admission(committed) = try gateway.result().0 else {
      throw MuxError(.invalidRequest, "missing selection result")
    }
    #expect(committed.revision == 2 && committed.selectionPending == false)
    gateway.send(request)
    guard case let .admission(repeated) = try gateway.result().0 else {
      throw MuxError(.invalidRequest, "missing repeated result")
    }
    #expect(repeated == committed)
    gateway.acknowledge()
    guard
      case let .workerSelection(selected) =
        try gateway.command(.workerSelection).0
    else { throw MuxError(.invalidRequest, "missing selection inventory") }
    #expect(selected.selected == "two" && selected.rollback == "one")
    #expect(
      try guardian.admissionStatus(gateway: gateway.identity).revision == 2
    )
  }

  @Test
  func admissionBarrierSurvivesReplacementAndFencesDelayedResume() throws {
    let guardian = try GuardianServer(
      launcherPath: launcherPath(),
      peerRequirement: nil
    )
    let workspace = WorkspaceID()
    _ = try guardian.provisionWorker(workspace: workspace, pid: getpid())
    let control = GuardianGatewayServer(
      guardian: guardian,
      peerRequirement: nil
    )
    let endpoint = control.listenAnonymously()
    defer {
      control.close()
      let stopped = DispatchSemaphore(value: 0)
      guardian.shutdown { stopped.signal() }
      #expect(waitFor(stopped, seconds: 8))
    }
    let first = try Gateway(endpoint)
    defer { first.channel.cancel() }
    guard case let .admission(initial) = try first.command(.admissionStatus).0
    else { throw MuxError(.invalidRequest, "missing admission status") }
    #expect(
      !initial.paused && initial.revision == 0 && initial.pendingWorkers == 1
    )
    let pause = first.request(.setAdmissionPaused(true, expectedRevision: 0))
    first.send(pause)
    guard case let .admission(paused) = try first.result().0 else {
      throw MuxError(.invalidRequest, "missing pause result")
    }
    first.send(pause)
    guard case let .admission(repeated) = try first.result().0 else {
      throw MuxError(.invalidRequest, "missing duplicate result")
    }
    #expect(paused == repeated && paused.revision == 1 && paused.paused)
    first.acknowledge()
    do {
      _ = try guardian.provisionWorker(workspace: WorkspaceID(), pid: getpid())
      Issue.record("paused admission succeeded")
    } catch let error as MuxError { #expect(error.code == .quiescing) }
    #expect(guardian.inventory().count == 1)
    #expect(paused.phase == .settling)
    // Only a barrier in `replacing` outlives its gateway (§5.2).
    guard
      case let .admission(replacing) =
        try first.command(.advanceAdmissionPhase(expectedRevision: 1)).0
    else { throw MuxError(.invalidRequest, "missing replacing phase") }
    #expect(replacing.revision == 2 && replacing.phase == .replacing)
    let second = try Gateway(endpoint)
    defer { second.channel.cancel() }
    guard
      case let .admission(inherited) = try second.command(.admissionStatus).0
    else { throw MuxError(.invalidRequest, "missing inherited barrier") }
    #expect(inherited == replacing)
    do {
      _ = try guardian.setAdmissionPaused(
        false,
        expectedRevision: 2,
        gateway: first.identity
      )
      Issue.record("old gateway resumed admission")
    } catch let error as MuxError { #expect(error.code == .staleAttachment) }
    guard
      case let .admission(reasserted) =
        try second.command(.setAdmissionPaused(true, expectedRevision: 2)).0
    else { throw MuxError(.invalidRequest, "missing reasserted pause") }
    #expect(reasserted.revision == 3 && reasserted.phase == .replacing)
    guard
      case let .rejected(stale) =
        try second.command(.setAdmissionPaused(false, expectedRevision: 2)).0
    else { throw MuxError(.invalidRequest, "stale resume accepted") }
    #expect(stale.code == .staleRevision)
    let authority = try #require(guardian.inventory().first?.authority)
    guard case .ending = try second.command(.end(authority: authority)).0 else {
      throw MuxError(.invalidRequest, "End refused while paused")
    }
    guard
      case let .admission(resumed) =
        try second.command(.setAdmissionPaused(false, expectedRevision: 3)).0
    else { throw MuxError(.invalidRequest, "missing resumed status") }
    #expect(
      !resumed.paused && resumed.revision == 4 && resumed.pendingWorkers == 0
    )
    #expect(resumed.phase == nil)
    _ = try guardian.provisionWorker(workspace: WorkspaceID(), pid: getpid())
  }

  @Test
  func externalGatewayDiscoveryReplacementAndTargetedEnd() async throws {
    let workspace = WorkspaceID()
    let guardian = try GuardianServer(
      launcherPath: launcherPath(),
      peerRequirement: nil
    )
    let workerEndpoint = guardian.listenAnonymously()
    let token = try guardian.provisionWorker(
      workspace: workspace,
      pid: getpid()
    )
    let published = DispatchSemaphore(value: 0)
    let host = try WorkspaceWorkerHost(
      workspace: workspace,
      launcherPath: launcherPath(),
      peerRequirement: nil,
      connect: { queue, handlers in
        try GuardianWorkerConnection(
          channel: .connect(endpoint: workerEndpoint, queue: queue),
          workspace: workspace,
          token: token,
          peerRequirement: nil,
          expectedGuardianPID: getpid(),
          handlers: handlers
        )
      },
      ready: { _ in published.signal() },
      unavailable: { _ in }
    )
    let control = GuardianGatewayServer(
      guardian: guardian,
      peerRequirement: nil
    )
    let endpoint = control.listenAnonymously()
    defer {
      control.close()
      host.close()
      let stopped = DispatchSemaphore(value: 0)
      guardian.shutdown { stopped.signal() }
      #expect(waitFor(stopped, seconds: 8))
    }
    #expect(await Task.detached { waitFor(published, seconds: 5) }.value)
    let first = try Gateway(endpoint)
    defer { first.channel.cancel() }
    let grant = first.request(.grantWriter(workspace: workspace))
    first.send(grant)
    let initial = try first.result()
    first.send(grant)
    let repeated = try first.result()
    guard case let .writer(a) = initial.0, case let .writer(b) = repeated.0
    else { throw MuxError(.invalidRequest, "missing writer grant") }
    #expect(a == b)
    first.acknowledge()
    try await waitReady(guardian, workspace, first.identity)
    let discovered = try first.command(.endpoint(workspace: workspace))
    guard case let .endpoint(authority, instance, pid) = discovered.0 else {
      throw MuxError(.invalidRequest, "missing endpoint metadata")
    }
    #expect(pid == getpid())
    let client = try await MuxConnection.connect(
      endpoint: #require(discovered.1),
      frontend: .native
    )
    #expect(instance == guardian.workerEndpoint(workspace: workspace)?.instance)
    _ = try await client.execute(
      .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
    )
    let inventory = try first.command(.inventory)
    guard case let .inventory(items) = inventory.0 else {
      throw MuxError(.invalidRequest, "missing inventory")
    }
    let child = try #require(items.first?.panes.first?.pid)
    #expect(items.first?.authority == authority)

    let second = try ControlClient(endpoint)
    defer { second.close() }
    #expect(second.identity != first.identity)
    let firstClosed = first.closed
    #expect(await Task.detached { waitFor(firstClosed, seconds: 3) }.value)
    _ = try second.command(.grantWriter(workspace: workspace))
    try await waitReady(guardian, workspace, second.identity)
    await #expect(throws: MuxError.self) { try await client.execute(.status) }
    guard
      case let .endpoint(worker) = try second.command(
        .endpoint(workspace: workspace)
      )
    else { throw MuxError(.invalidRequest, "missing worker endpoint") }
    let attached = try await MuxConnection.connectWorker(
      endpoint: worker.endpoint,
      expectedPID: worker.pid,
      expectedServer: worker.instance,
      peerRequirement: nil,
      frontend: .native
    )
    _ = try await attached.execute(.status)
    await attached.close()
    for wrongPID in [true, false] {
      await #expect(throws: MuxError.self) {
        try await MuxConnection.connectWorker(
          endpoint: worker.endpoint,
          expectedPID: wrongPID ? worker.pid + 1 : worker.pid,
          expectedServer: wrongPID ? worker.instance : ServerInstanceID(),
          peerRequirement: nil,
          frontend: .native
        )
      }
    }
    #expect(kill(child, 0) == 0)
    var stale = authority
    stale.generation += 1
    let rejected = try second.command(.end(authority: stale))
    guard case let .rejected(error) = rejected else {
      throw MuxError(.invalidRequest, "stale End was accepted")
    }
    #expect(error.code == .staleAttachment)
    for (target, expected) in [
      (stale, MuxError.Code.staleAttachment),
      (authority, MuxError.Code.quiescing),
    ] {
      guard
        case let .rejected(error) = try second.command(
          .forget(authority: target)
        )
      else {
        throw MuxError(.invalidRequest, "premature retirement was accepted")
      }
      #expect(error.code == expected)
    }
    #expect(kill(child, 0) == 0)
    second.close()
    try await waitReady(guardian, workspace, nil)
    #expect(kill(child, 0) == 0)
    let third = try Gateway(endpoint)
    defer { third.channel.cancel() }
    let ending = try third.command(.end(authority: authority))
    guard case .ending = ending.0 else {
      throw MuxError(.invalidRequest, "End was not accepted")
    }
    let deadline = ContinuousClock.now + .seconds(5)
    while guardian.inventory().first?.panes.first?.finished != true {
      guard ContinuousClock.now < deadline else {
        throw MuxError(.connectionLost, "End did not reap child")
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    let forget = third.request(.forget(authority: authority))
    third.send(forget)
    guard case .forgotten = try third.result().0 else {
      throw MuxError(.invalidRequest, "ended workspace was not retired")
    }
    #expect(guardian.inventory().isEmpty)
    third.send(forget)
    guard case .forgotten = try third.result().0 else {
      throw MuxError(.invalidRequest, "lost retirement result was not retained")
    }
    third.acknowledge()
    let fourth = try ControlClient(endpoint)
    defer { fourth.close() }
    _ = try guardian.provisionWorker(workspace: workspace, pid: getpid())
    let replacement = try #require(guardian.inventory().first?.authority)
    #expect(replacement.generation > authority.generation)
    guard
      case let .rejected(staleEnd) = try fourth.command(
        .end(authority: authority)
      )
    else {
      throw MuxError(.invalidRequest, "retired authority ended a replacement")
    }
    #expect(staleEnd.code == .staleAttachment)
    guard
      case let .rejected(error) = try fourth.command(
        .forget(authority: authority)
      )
    else { throw MuxError(.invalidRequest, "retired authority was accepted") }
    #expect(error.code == .staleAttachment)
    _ = try fourth.command(.end(authority: replacement))
    guard case .forgotten = try fourth.command(.forget(authority: replacement))
    else { throw MuxError(.invalidRequest, "replacement retirement failed") }
    #expect(guardian.inventory().isEmpty)
    await client.close()
  }

  @Test(arguments: [
    "conflict", "incarnation", "identity", "sequence", "retired", "hello",
    "oversized",
  ])
  func invalidAuthorityOrSequenceFencesGateway(violation: String) throws {
    let guardian = try GuardianServer(
      launcherPath: launcherPath(),
      peerRequirement: nil
    )
    let control = GuardianGatewayServer(
      guardian: guardian,
      peerRequirement: nil
    )
    defer { control.close() }
    let gateway = try Gateway(control.listenAnonymously())
    defer { gateway.channel.cancel() }
    gateway.send(gateway.request(.inventory))
    _ = try gateway.result()
    switch violation {
    case "conflict":
      gateway.send(gateway.request(.grantWriter(workspace: WorkspaceID())))
    case "incarnation":
      gateway.send(
        .command(
          incarnation: UUID(),
          gateway: gateway.identity,
          sequence: 1,
          body: .inventory
        )
      )
    case "identity":
      gateway.send(
        .command(
          incarnation: gateway.incarnation,
          gateway: UUID(),
          sequence: 1,
          body: .inventory
        )
      )
    case "sequence":
      gateway.send(
        .command(
          incarnation: gateway.incarnation,
          gateway: gateway.identity,
          sequence: 2,
          body: .inventory
        )
      )
    case "retired":
      let old = gateway.request(.inventory)
      gateway.acknowledge()
      gateway.send(old)
    case "hello": gateway.send(.hello(version: GuardianWire.version))
    default:
      gateway.channel.send(
        Data(repeating: 0, count: GuardianWire.recordLimit + 1)
      )
    }
    #expect(gateway.closed.wait(timeout: .now() + 3) == .success)
  }

  private func waitFor(_ semaphore: DispatchSemaphore, seconds: Double) -> Bool
  { semaphore.wait(timeout: .now() + seconds) == .success }

  private func waitReady(
    _ guardian: GuardianServer,
    _ workspace: WorkspaceID,
    _ identity: UUID?
  ) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !guardian.gatewayReady(workspace: workspace, gateway: identity) {
      guard ContinuousClock.now < deadline else {
        throw MuxError(.connectionLost, "gateway binding timed out")
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private final class ControlClient {
    let identity: UUID
    private let queue = DispatchQueue(label: "guardian-control-test-client")
    private let connection: GuardianGatewayConnection
    private final class State: Sendable {
      let ready = DispatchSemaphore(value: 0)
      let identity = Mutex<UUID?>(nil)
      let result = Mutex<Result<GuardianGatewayConnection.Reply, MuxError>?>(
        nil
      )
      let completed = DispatchSemaphore(value: 0)
    }
    private let state = State()
    init(_ endpoint: SMXEndpoint) throws {
      let state = state
      let queue = queue
      connection = try queue.sync {
        try GuardianGatewayConnection(
          channel: .connect(endpoint: endpoint, queue: queue),
          peerRequirement: nil,
          expectedGuardianPID: getpid(),
          ready: { value in
            state.identity.withLock { $0 = value.gateway }
            state.ready.signal()
          },
          closed: { _ in }
        )
      }
      guard state.ready.wait(timeout: .now() + 5) == .success,
        let identity = state.identity.withLock({ $0 })
      else { throw MuxError(.connectionLost, "control client did not connect") }
      self.identity = identity
    }
    func close() { queue.sync { connection.close() } }
    func command(
      _ body: GuardianGatewayCommand
    ) throws -> GuardianGatewayConnection.Reply {
      let state = state
      guard
        queue.sync(execute: {
          connection.submit(body) { value in
            state.result.withLock { $0 = value }
            state.completed.signal()
          }
        })
      else { throw MuxError(.resourceLimit, "control request not admitted") }
      guard state.completed.wait(timeout: .now() + 6) == .success,
        let result = state.result.withLock({ $0 })
      else { throw MuxError(.connectionLost, "control result did not arrive") }
      return try result.get()
    }
  }

  private final class Gateway {
    private final class Inbox: Sendable {
      let values = Mutex<[(GuardianGatewayEvent, SMXEndpoint?)]>([])
      let received = DispatchSemaphore(value: 0)
      let closed = DispatchSemaphore(value: 0)
      func append(_ data: Data, _ endpoint: SMXEndpoint?) {
        guard
          let event = try? JSONDecoder()
            .decode(GuardianGatewayEvent.self, from: data)
        else { return }
        values.withLock { $0.append((event, endpoint)) }
        received.signal()
      }
      func next() throws -> (GuardianGatewayEvent, SMXEndpoint?) {
        guard received.wait(timeout: .now() + 5) == .success else {
          throw MuxError(.connectionLost, "gateway response timed out")
        }
        return values.withLock { $0.removeFirst() }
      }
    }
    let channel: SMXChannel
    let identity: UUID
    let incarnation: UUID
    private let inbox = Inbox()
    private var sequence: UInt64 = 1
    var closed: DispatchSemaphore { inbox.closed }
    init(_ endpoint: SMXEndpoint) throws {
      channel = .connect(
        endpoint: endpoint,
        queue: DispatchQueue(label: "gateway-test")
      )
      let inbox = inbox
      channel.activate(endpointHandler: { inbox.append($0, $1) }) { event in
        switch event {
        case let .message(data): inbox.append(data, nil)
        case .closed: inbox.closed.signal()
        }
      }
      channel.send(
        try JSONEncoder()
          .encode(GuardianGatewayRequest.hello(version: GuardianWire.version))
      )
      guard
        case let .welcome(incarnation, gateway, _, _, _, _) = try inbox.next().0
      else { throw MuxError(.unauthorized, "gateway admission failed") }
      self.incarnation = incarnation
      identity = gateway
    }
    func request(_ command: GuardianGatewayCommand) -> GuardianGatewayRequest {
      .command(
        incarnation: incarnation,
        gateway: identity,
        sequence: sequence,
        body: command
      )
    }
    func send(_ request: GuardianGatewayRequest) {
      channel.send(try! JSONEncoder().encode(request))
    }
    func result() throws -> (GuardianGatewayResult, SMXEndpoint?) {
      let value = try inbox.next()
      guard case let .result(number, result) = value.0, number == sequence
      else { throw MuxError(.invalidRequest, "unexpected gateway result") }
      return (result, value.1)
    }
    func acknowledge() {
      send(.acknowledge(sequence: sequence))
      sequence += 1
    }
    func command(
      _ body: GuardianGatewayCommand
    ) throws -> (GuardianGatewayResult, SMXEndpoint?) {
      send(request(body))
      let value = try result()
      acknowledge()
      return value
    }
  }
}
