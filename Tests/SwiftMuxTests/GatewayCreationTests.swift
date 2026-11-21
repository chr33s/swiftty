import Darwin
import Dispatch
import Foundation
import SwiftMuxClient
import SwiftMuxGateway
@testable import SwiftMuxGuardian
import SwiftMuxProtocol
import SwiftMuxXPC
import Synchronization
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct GatewayCreationTests {
  @Test
  func creationIsExplicitAndExistingIdentityIsNeverReplayed() async throws {
    let fixture = Fixture(mode: .success)
    defer { fixture.close() }
    let supervisor = try await fixture.connect()
    let creator = GatewayWorkspaceCreator(
      supervisor: supervisor,
      peerRequirement: nil
    )
    let id = WorkspaceID()
    let owner = try await creator.create(
      id,
      request: NewWorkspaceRequest(name: "created")
    )
    #expect(owner.workspace == id)
    #expect(fixture.launches.withLock { $0 } == 1)
    do {
      _ = try await creator.create(id, request: NewWorkspaceRequest())
      Issue.record("existing identity was recreated")
    } catch let error as MuxError { #expect(error.code == .invalidRequest) }
    #expect(fixture.creates.withLock { $0 } == 1)
    #expect(fixture.launches.withLock { $0 } == 1)
    #expect(await creator.pendingCount == 0)
    await creator.close()
    await supervisor.close()
  }

  @Test
  func templateCreationSendsTheTemplateOnce() async throws {
    let fixture = Fixture(mode: .success)
    defer { fixture.close() }
    let supervisor = try await fixture.connect()
    let creator = GatewayWorkspaceCreator(
      supervisor: supervisor,
      peerRequirement: nil
    )
    let id = WorkspaceID()
    let launch = LaunchSpec(
      command: nil,
      workingDirectory: nil,
      environment: [:]
    )
    let created = try await creator.create(
      id,
      payload: .template(
        WorkspaceTemplate(
          name: "reopened",
          columns: 80,
          rows: 24,
          remainOnExit: false,
          launch: launch,
          panes: [launch, launch],
          tabs: [
            WorkspaceTemplateTab(
              name: "1",
              layout: .split(
                axis: .leftRight,
                ratio: 0.5,
                first: .pane(slot: 0),
                second: .pane(slot: 1)
              ),
              activeSlot: 0
            )
          ],
          activeTab: 0,
          outputOptOut: false
        )
      )
    )
    #expect(created.authority.workspace == id)
    #expect(created.outcome?.failedSlots == [1])
    #expect(fixture.launches.withLock { $0 } == 1)
    await creator.close()
    await supervisor.close()
  }

  @Test(arguments: [false, true])
  func uncertainLaunchIsNotRetriedOrEnded(cancelled: Bool) async throws {
    let fixture = Fixture(mode: .noReply)
    defer { fixture.close() }
    let supervisor = try await fixture.connect()
    let creator = GatewayWorkspaceCreator(
      supervisor: supervisor,
      peerRequirement: nil
    )
    let task = Task {
      try await creator.create(
        WorkspaceID(),
        request: NewWorkspaceRequest(),
        timeout: cancelled ? .seconds(5) : .seconds(1)
      )
    }
    try await waitUntil { fixture.launches.withLock { $0 } == 1 }
    if cancelled { task.cancel() }
    do {
      _ = try await task.value;
      Issue.record("uncertain creation succeeded")
    } catch is CancellationError { #expect(cancelled) } catch let error
      as MuxError
    { #expect(!cancelled && error.code == .connectionLost) }
    #expect(fixture.creates.withLock { $0 } == 1)
    #expect(fixture.launches.withLock { $0 } == 1)
    #expect(fixture.ends.withLock { $0 } == 0)
    #expect(try await supervisor.inventory().count == 1)
    #expect(await creator.pendingCount == 0)
    await creator.close()
    await supervisor.close()
  }

  @Test
  func creationWindowAndRetainedPayloadAreBoundedBeforeSideEffects()
    async throws
  {
    let fixture = Fixture(mode: .waitingForWorker)
    defer { fixture.close() }
    let supervisor = try await fixture.connect()
    let creator = GatewayWorkspaceCreator(
      supervisor: supervisor,
      peerRequirement: nil
    )
    let ids = (0 ..< 4).map { _ in WorkspaceID() }
    let pending = ids.map { id in
      Task { try await creator.create(id, request: NewWorkspaceRequest()) }
    }
    try await waitUntil {
      await creator.pendingCount == 4 && fixture.creates.withLock { $0 } == 4
    }
    for id in [ids[0], WorkspaceID()] {
      do {
        _ = try await creator.create(id, request: NewWorkspaceRequest());
        Issue.record("creation window overwritten")
      } catch let error as MuxError {
        #expect(error.code == (id == ids[0] ? .quiescing : .resourceLimit))
      }
    }
    await creator.close()
    for task in pending {
      await #expect(throws: CancellationError.self) { try await task.value }
    }
    #expect(await creator.pendingCount == 0)
    #expect(fixture.creates.withLock { $0 } == 4)
    #expect(fixture.ends.withLock { $0 } == 0)
    let another = GatewayWorkspaceCreator(
      supervisor: supervisor,
      peerRequirement: nil
    )
    do {
      _ = try await another.create(
        WorkspaceID(),
        request: NewWorkspaceRequest(
          launch: LaunchSpec(environment: [
            "oversized": String(repeating: "x", count: 4 << 20)
          ])
        )
      )
      Issue.record("oversized launch was retained")
    } catch let error as MuxError { #expect(error.code == .resourceLimit) }
    #expect(fixture.creates.withLock { $0 } == 4)
    let largeRequest = NewWorkspaceRequest(
      launch: LaunchSpec(environment: [
        "payload": String(repeating: "x", count: 2 << 20)
      ])
    )
    let large = Task {
      try await another.create(WorkspaceID(), request: largeRequest)
    }
    try await waitUntil { fixture.creates.withLock { $0 } == 5 }
    do {
      _ = try await another.create(WorkspaceID(), request: largeRequest)
      Issue.record("aggregate creation byte budget exceeded")
    } catch let error as MuxError { #expect(error.code == .resourceLimit) }
    #expect(fixture.creates.withLock { $0 } == 5)
    await another.close()
    await #expect(throws: CancellationError.self) { try await large.value }
    #expect(await another.pendingCount == 0)
    await supervisor.close()
  }

  @Test
  func workerLaunchFailureRemainsDiscoverableUntilExplicitEnd() async throws {
    let fixture = Fixture(mode: .failedWorker)
    defer { fixture.close() }
    let supervisor = try await fixture.connect()
    let creator = GatewayWorkspaceCreator(
      supervisor: supervisor,
      peerRequirement: nil
    )
    do {
      _ = try await creator.create(
        WorkspaceID(),
        request: NewWorkspaceRequest()
      )
      Issue.record("failed worker launch succeeded")
    } catch let error as MuxError { #expect(error.code == .launchFailed) }
    #expect(try await supervisor.inventory().count == 1)
    #expect(fixture.creates.withLock { $0 } == 1)
    #expect(fixture.launches.withLock { $0 } == 0)
    #expect(fixture.ends.withLock { $0 } == 0)
    #expect(await creator.pendingCount == 0)
    await creator.close()
    await supervisor.close()
  }

  private func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await condition()) {
      guard ContinuousClock.now < deadline else {
        throw MuxError(.connectionLost, "creation test timed out")
      }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  /// Mutable protocol state is confined to queue; test counters use mutexes.
  private final class Fixture: @unchecked Sendable {
    enum Mode { case success, noReply, waitingForWorker, failedWorker }
    let mode: Mode
    let queue = DispatchQueue(label: "gateway-creation-fixture")
    let control: SMXListener
    let worker: SMXListener
    let incarnation = UUID()
    let instance = ServerInstanceID()
    let creates = Mutex(0)
    let launches = Mutex(0)
    let ends = Mutex(0)
    private var authorities: [WorkspaceID: GuardianAuthority] = [:]
    private var channels: [SMXChannel] = []

    init(mode: Mode) {
      self.mode = mode
      control = SMXListener(anonymousOn: queue)
      worker = SMXListener(anonymousOn: queue)
      control.activate(connectionQueue: queue) { [weak self] channel in
        guard let self else {
          channel.cancel();
          return
        }
        self.channels.append(channel)
        channel.activate { [weak self] event in
          guard let self, case let .message(data) = event,
            let request = try? JSONDecoder()
              .decode(GuardianGatewayRequest.self, from: data)
          else { return }
          self.receive(request, channel: channel)
        }
      }
      worker.activate(connectionQueue: queue) { [weak self] channel in
        guard let self else {
          channel.cancel();
          return
        }
        self.channels.append(channel)
        channel.activate { [weak self] event in
          guard let self, case let .message(data) = event,
            let message = try? SMXCodec.decode(
              ClientMessage.self,
              from: data,
              limit: 4 << 20
            )
          else { return }
          switch message {
          case let .hello(hello):
            channel.send(
              try! SMXCodec.encode(
                ServerMessage.welcome(
                  Welcome(
                    protocolVersion: SMX.protocolVersion,
                    build: SMX.build,
                    server: self.instance,
                    acceptedProfile: nil,
                    limits: .standard,
                    innerTerm: SMX.fallbackInnerTerm,
                    features: .supported.union(.savedLayoutMetadata),
                    forwardedTransport: hello.forwardedTransport
                  )
                ),
                limit: 4 << 20
              )
            )
          case let .request(id, .newWorkspace(request)):
            self.launches.withLock { $0 += 1 }
            if self.mode == .success {
              let snapshot = WorkspaceSnapshot(
                id: self.authorities.keys.first!,
                name: request.name ?? "0",
                tabs: [],
                activeTab: TabID(),
                panes: [],
                layoutRevision: 1
              )
              channel.send(
                try! SMXCodec.encode(
                  ServerMessage.reply(
                    id: id,
                    result: .success(.created(snapshot))
                  ),
                  limit: 4 << 20
                )
              )
            }
          case let .request(id, .newWorkspaceFromTemplate(template)):
            self.launches.withLock { $0 += 1 }
            let snapshot = WorkspaceSnapshot(
              id: self.authorities.keys.first!,
              name: template.name ?? "0",
              tabs: [],
              activeTab: TabID(),
              panes: [],
              layoutRevision: 1
            )
            channel.send(
              try! SMXCodec.encode(
                ServerMessage.reply(
                  id: id,
                  result: .success(
                    .createdFromTemplate(
                      snapshot,
                      WorkspaceTemplateOutcome(
                        panes: [0: PaneID()],
                        failedSlots: [1],
                        directoryFallbackSlots: []
                      )
                    )
                  )
                ),
                limit: 4 << 20
              )
            )
          default: break
          }
        }
      }
    }

    func connect() async throws -> GatewaySupervisor {
      let endpoint = control.endpoint
      return try await GatewaySupervisor.connect(
        peerRequirement: nil,
        expectedGuardianPID: getpid(),
        channel: { .connect(endpoint: endpoint, queue: $0) }
      )
    }

    func close() {
      queue.sync {
        control.cancel();
        worker.cancel()
        for channel in channels { channel.cancel() }
        channels.removeAll()
      }
    }

    private func receive(_ request: GuardianGatewayRequest, channel: SMXChannel)
    {
      switch request {
      case .hello:
        channel.send(
          try! JSONEncoder()
            .encode(
              GuardianGatewayEvent.welcome(
                incarnation: incarnation,
                gateway: UUID()
              )
            )
        )
      case let .command(_, _, sequence, body):
        let result: GuardianGatewayResult
        var endpoint: SMXEndpoint?
        switch body {
        case .inventory:
          result = .inventory(
            authorities.values.map {
              .init(
                authority: $0,
                available: mode != .waitingForWorker && mode != .failedWorker,
                worker: nil,
                panes: [],
                starting: mode == .waitingForWorker,
                launchError: mode == .failedWorker
                  ? MuxError(.launchFailed, "worker startup failed") : nil
              )
            }
          )
        case let .create(id):
          creates.withLock { $0 += 1 }
          let authority = GuardianAuthority(
            incarnation: incarnation,
            workspace: id,
            generation: UInt64(authorities.count + 1)
          )
          authorities[id] = authority
          result = .creating(authority)
        case let .endpoint(id):
          if mode == .waitingForWorker || mode == .failedWorker {
            result = .rejected(.init(.notAttached))
          } else {
            result = .endpoint(
              authority: authorities[id]!,
              instance: instance,
              pid: getpid()
            )
            endpoint = worker.endpoint
          }
        case .end, .forget:
          ends.withLock { $0 += 1 }
          result = .rejected(.init(.invalidRequest))
        case .grantWriter, .ensureWriter, .admissionStatus, .setAdmissionPaused,
          .advanceAdmissionPhase, .workerSelection, .selectWorkerBuild,
          .clearWorkerRollback:
          result = .rejected(.init(.invalidRequest))
        }
        let data = try! JSONEncoder()
          .encode(
            GuardianGatewayEvent.result(sequence: sequence, value: result)
          )
        if let endpoint {
          channel.send(data, endpoint: endpoint)
        } else {
          channel.send(data)
        }
      case .acknowledge: break
      }
    }
  }
}
