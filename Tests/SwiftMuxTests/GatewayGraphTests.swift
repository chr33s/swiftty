import Darwin
import SwiftMuxClient
import SwiftMuxGuardian
import SwiftMuxProtocol
@testable import SwiftMuxService
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct GatewayGraphTests {
  @Test
  func graphEventsHaveOneCreditAndRearmReturnsLatestSnapshot() async throws {
    let workspace = WorkspaceID()
    var configuration = MuxServiceConfiguration(
      launcherPath: try launcherPath()
    )
    configuration.workerWorkspace = workspace
    configuration.requiresGatewayBinding = true
    configuration.paneProcessFactory = { id, workspace, queue, limits in
      GuardianPTY(id: id, workspace: workspace, queue: queue, limits: limits)
    }
    let harness = try Harness(configuration: configuration)
    await withCheckedContinuation { continuation in
      harness.service.setGatewayPeer(getpid()) { continuation.resume() }
    }
    let observer = try await harness.connect()
    let writer = try await harness.connect()
    #expect(await observer.welcome?.features.contains(.workspaceGraph) == true)
    guard
      case .workspaceGraph(nil) = try await observer.execute(
        .observeWorkspaceGraph(true)
      )
    else { throw MuxError(.invalidRequest, "missing empty initial graph") }
    _ = try await writer.execute(
      .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
    )
    for number in 0 ..< 12 {
      _ = try await writer.execute(
        .renameWorkspace(.id(workspace), name: "name-\(number)")
      )
    }
    guard
      case .workspaceGraph = try await observer.nextEvent(timeout: .seconds(2))
    else { throw MuxError(.invalidRequest, "missing graph notification") }
    await #expect(throws: MuxConnection.EventWaitError.timedOut) {
      try await observer.nextEvent(timeout: .milliseconds(30))
    }
    guard
      case let .workspaceGraph(graph) = try await observer.execute(
        .observeWorkspaceGraph(true)
      )
    else { throw MuxError(.invalidRequest, "missing rearm snapshot") }
    #expect(graph?.name == "name-11")
    #expect(graph?.panes.count == 1)
    #expect(graph?.attachmentRole == nil)
    _ = try await writer.execute(.endWorkspace(.id(workspace)))
    guard
      case .workspaceGraph(nil) = try await observer.nextEvent(
        timeout: .seconds(2)
      )
    else { throw MuxError(.invalidRequest, "graph removal was not observed") }
    _ = try await observer.execute(.observeWorkspaceGraph(false))
    await observer.close()
    await writer.close()
  }
}
