import Darwin
import Dispatch
import Foundation
import SwiftMuxClient
import SwiftMuxGuardian
import SwiftMuxProtocol
@testable import SwiftMuxService
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct WorkspaceWorkerHostTests {
  @Test
  func gatewayReplacementFencesOldConnectionsAndPreservesWorkspaceState()
    async throws
  {
    let fixture = try Fixture()
    defer { fixture.stop() }
    let discovered = try #require(
      fixture.server.workerEndpoint(workspace: fixture.workspace)
    )
    // The published endpoint has no default gateway or writer authority.
    await #expect(throws: MuxError.self) {
      try await MuxConnection.connect(
        endpoint: discovered.endpoint,
        frontend: .native
      )
    }
    let identity = UUID()
    _ = try fixture.grant(identity)
    try await fixture.awaitGateway(identity)
    let first = try await MuxConnection.connect(
      endpoint: discovered.endpoint,
      frontend: .native
    )
    guard
      case let .created(workspace) = try await first.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      )
    else {
      throw MuxError(.invalidRequest, "worker did not create its workspace")
    }
    #expect(workspace.id == fixture.workspace)
    let pane = workspace.tabs[0].activePane
    try await first.attachAndShow(.id(workspace.id))
    try await first.send(.text("VALUE=durable; echo first=$VALUE\r"), to: pane)
    _ = try await first.frame(of: pane) { $0.lines.contains("first=durable") }
    let pid = try #require(fixture.server.inventory().first?.panes.first?.pid)
    // Resolving a lost binding acknowledgement is idempotent.
    fixture.server.replaceGateway(identity)
    try await fixture.awaitGateway(identity)
    _ = try await first.execute(.status)

    // Writer renewal clears old queued input without replacing the gateway.
    _ = try fixture.server.grantWriter(
      workspace: fixture.workspace,
      gateway: identity
    )
    try await fixture.awaitGateway(identity)
    _ = try await first.execute(.status)
    try await first.send(.text("echo renewed=$VALUE\r"), to: pane)
    _ = try await first.frame(of: pane) { $0.lines.contains("renewed=durable") }

    let replacement = UUID()
    _ = try fixture.grant(replacement)
    try await fixture.awaitGateway(replacement)
    await #expect(throws: MuxError.self) { try await first.execute(.status) }
    let again = try #require(
      fixture.server.workerEndpoint(workspace: fixture.workspace)
    )
    #expect(again.instance == discovered.instance)
    let second = try await MuxConnection.connect(
      endpoint: again.endpoint,
      frontend: .native
    )
    try await second.attachAndShow(.id(workspace.id))
    try await second.send(.text("echo second=$VALUE\r"), to: pane)
    _ = try await second.frame(of: pane) { $0.lines.contains("second=durable") }
    #expect(fixture.server.inventory().first?.panes.first?.pid == pid)

    fixture.server.revokeGateway(replacement)
    try await fixture.awaitGateway(nil)
    await #expect(throws: MuxError.self) { try await second.execute(.status) }
    await #expect(throws: MuxError.self) {
      try await MuxConnection.connect(
        endpoint: again.endpoint,
        frontend: .native
      )
    }
    #expect(kill(pid, 0) == 0)
    await first.close()
    await second.close()
  }

  @Test
  func differentPeerPIDCannotUsePublishedEndpoint() async throws {
    let fixture = try Fixture()
    defer { fixture.stop() }
    let identity = UUID()
    _ = try fixture.grant(identity, pid: getpid() + 1)
    try await fixture.awaitGateway(identity)
    let endpoint = try #require(
      fixture.server.workerEndpoint(workspace: fixture.workspace)
    )
    await #expect(throws: MuxError.self) {
      try await MuxConnection.connect(
        endpoint: endpoint.endpoint,
        frontend: .native
      )
    }
    #expect(fixture.server.inventory().first?.panes.isEmpty == true)
  }

  private final class Fixture: @unchecked Sendable {
    let workspace = WorkspaceID()
    let server: GuardianServer
    let host: WorkspaceWorkerHost
    init() throws {
      let path = try launcherPath()
      server = try GuardianServer(launcherPath: path, peerRequirement: nil)
      let endpoint = server.listenAnonymously()
      let token = try server.provisionWorker(
        workspace: workspace,
        pid: getpid()
      )
      let workspaceID = workspace
      let ready = DispatchSemaphore(value: 0)
      host = try WorkspaceWorkerHost(
        workspace: workspace,
        launcherPath: path,
        peerRequirement: nil,
        connect: { queue, handlers in
          try GuardianWorkerConnection(
            channel: .connect(endpoint: endpoint, queue: queue),
            workspace: workspaceID,
            token: token,
            peerRequirement: nil,
            expectedGuardianPID: getpid(),
            handlers: handlers
          )
        },
        ready: { _ in ready.signal() },
        unavailable: { _ in }
      )
      guard ready.wait(timeout: .now() + 5) == .success else {
        throw MuxError(.connectionLost, "worker host did not publish")
      }
    }
    func grant(_ identity: UUID, pid: Int32 = getpid()) throws -> UUID {
      server.replaceGateway(identity, pid: pid)
      return try server.grantWriter(workspace: workspace, gateway: identity)
    }
    func awaitGateway(_ identity: UUID?) async throws {
      let deadline = ContinuousClock.now + .seconds(5)
      while !server.gatewayReady(workspace: workspace, gateway: identity) {
        guard ContinuousClock.now < deadline else {
          throw MuxError(
            .connectionLost,
            "gateway binding was not acknowledged"
          )
        }
        try await Task.sleep(for: .milliseconds(10))
      }
    }
    func stop() {
      host.close()
      let stopped = DispatchSemaphore(value: 0)
      server.shutdown { stopped.signal() }
      #expect(stopped.wait(timeout: .now() + 8) == .success)
    }
  }
}
