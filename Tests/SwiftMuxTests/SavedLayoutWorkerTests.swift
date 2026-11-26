import Darwin
import Foundation
import SwiftMuxClient
import SwiftMuxGuardian
import SwiftMuxProtocol
@testable import SwiftMuxService
import SwifttyEngine
import Testing

/// Worker side of saved layouts (spec.durability.md §12.2.3, §12.2.6,
/// §12.2.7): metadata, causes, End dispositions and template creation.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SavedLayoutWorkerTests {
  /// `bound` false is an ordinary (unscoped-gateway) service.
  private func worker(bound: Bool = true) async throws -> (Harness, WorkspaceID)
  {
    let workspace = WorkspaceID()
    var configuration = MuxServiceConfiguration(
      launcherPath: try launcherPath()
    )
    configuration.workerWorkspace = workspace
    configuration.requiresGatewayBinding = bound
    configuration.paneProcessFactory = { id, workspace, queue, limits in
      GuardianPTY(id: id, workspace: workspace, queue: queue, limits: limits)
    }
    let harness = try Harness(configuration: configuration)
    if bound {
      await withCheckedContinuation { continuation in
        harness.service.setGatewayPeer(getpid()) { continuation.resume() }
      }
    }
    return (harness, workspace)
  }

  private func state(_ client: MuxConnection) async throws -> SavedLayoutState {
    guard
      case let .savedLayoutState(value) = try await client.execute(
        .savedLayoutState
      )
    else { throw MuxError(.invalidRequest, "missing saved layout state") }
    return value
  }

  @Test
  func stateReportsLaunchCausesAndExplicitDisposition() async throws {
    let (harness, workspace) = try await worker()
    let gateway = try await harness.connect()
    defer { Task { await gateway.close() } }
    #expect(
      await gateway.welcome?.features.contains(.savedLayoutMetadata) == true
    )
    var launch = shellLaunch()
    launch.workingDirectory = "/tmp"
    _ = try await gateway.execute(
      .newWorkspace(NewWorkspaceRequest(launch: launch))
    )
    let created = try await state(gateway)
    #expect(created.causes.contains(.command))
    #expect(created.graph?.id == workspace && created.end == nil)
    #expect(created.panes.count == 1)
    #expect(created.panes.first?.launch == .command(["/bin/sh"]))
    #expect(created.panes.first?.reopen?.argv == ["/bin/sh"])
    #expect(created.panes.first?.reopen?.origin == .launch)
    #expect(created.panes.first?.reopen?.directoryRequired == false)
    #expect(created.panes.first?.localDirectory == "/tmp")
    #expect(created.panes.first?.directoryFallback == false)
    // Reading clears the causes.
    #expect(try await state(gateway).causes.isEmpty)
    _ = try await gateway.execute(
      .renameWorkspace(.id(workspace), name: "kept")
    )
    #expect(try await state(gateway).causes == .command)
    _ = try await gateway.execute(
      .endWorkspace(.id(workspace), disposition: .retained)
    )
    let ended = try await state(gateway)
    #expect(ended.graph == nil && ended.end == .ended(.retained))
  }

  @Test
  func lastPaneExitReportsExitedWithExitCause() async throws {
    let (harness, _) = try await worker()
    let gateway = try await harness.connect()
    defer { Task { await gateway.close() } }
    var launch = shellLaunch()
    launch.command = ["/bin/sh", "-c", "exit 0"]
    _ = try await gateway.execute(
      .newWorkspace(NewWorkspaceRequest(launch: launch))
    )
    // Each read clears causes, so collect them across reads.
    var causes: SavedLayoutCauses = []
    var ended: SavedLayoutState?
    for _ in 0 ..< 200 {
      let value = try await state(gateway)
      causes.formUnion(value.causes)
      if value.end != nil {
        ended = value
        break
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(ended?.end == .exited)
    #expect(causes.contains(.exit))
  }

  @Test
  func userEndDefaultsToEnded() async throws {
    let (harness, workspace) = try await worker()
    let gateway = try await harness.connect()
    defer { Task { await gateway.close() } }
    _ = try await gateway.execute(
      .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
    )
    _ = try await gateway.execute(.endWorkspace(.id(workspace)))
    #expect(try await state(gateway).end == .ended(.ended))
  }

  @Test
  func onlyTheCurrentGatewayReadsOrCreatesFromTemplates() async throws {
    // A gateway-bound worker admits only its gateway at all; an ordinary
    // service refuses the gateway-only commands to every client.
    let (harness, _) = try await worker(bound: false)
    let client = try await harness.connect()
    defer { Task { await client.close() } }
    for command: MuxCommand in [
      .savedLayoutState,
      .newWorkspaceFromTemplate(
        WorkspaceTemplate(
          name: nil,
          columns: 80,
          rows: 24,
          remainOnExit: false,
          launch: shellLaunch(),
          panes: [shellLaunch()],
          tabs: [
            WorkspaceTemplateTab(
              name: "1",
              layout: .pane(slot: 0),
              activeSlot: 0
            )
          ],
          activeTab: 0,
          outputOptOut: false
        )
      ),
    ] {
      do {
        _ = try await client.execute(command)
        Issue.record("non-gateway client used \(command)")
      } catch let error as MuxError { #expect(error.code == .unauthorized) }
    }
  }

  @Test
  func templateBuildsTreeAndDropsFailedSlots() async throws {
    let (harness, workspace) = try await worker()
    let gateway = try await harness.connect()
    defer { Task { await gateway.close() } }
    var missing = shellLaunch()
    missing.command = ["swiftty-no-such-program-for-template-tests"]
    var fallback = shellLaunch()
    fallback.workingDirectory = "/nonexistent-swiftty-template-directory"
    let template = WorkspaceTemplate(
      name: "reopened",
      columns: 80,
      rows: 24,
      remainOnExit: false,
      launch: shellLaunch(),
      panes: [shellLaunch(), missing, fallback, shellLaunch()],
      tabs: [
        WorkspaceTemplateTab(
          name: "first",
          layout: .split(
            axis: .leftRight,
            ratio: 0.3,
            first: .pane(slot: 0),
            second: .pane(slot: 1)
          ),
          activeSlot: 1
        ),
        WorkspaceTemplateTab(
          name: "second",
          layout: .split(
            axis: .topBottom,
            ratio: 0.6,
            first: .pane(slot: 2),
            second: .pane(slot: 3)
          ),
          activeSlot: 3,
          zoomedSlot: 3
        ),
      ],
      activeTab: 1,
      outputOptOut: true
    )
    guard
      case let .createdFromTemplate(snapshot, outcome) =
        try await gateway.execute(.newWorkspaceFromTemplate(template))
    else { throw MuxError(.invalidRequest, "missing template result") }
    #expect(snapshot.id == workspace && snapshot.name == "reopened")
    #expect(outcome.failedSlots == [1])
    #expect(outcome.directoryFallbackSlots == [2])
    #expect(snapshot.tabs.map(\.name) == ["first", "second"])
    let first = snapshot.tabs[0]
    #expect(first.layout == .pane(try #require(outcome.panes[0])))
    #expect(first.activePane == outcome.panes[0])
    let second = snapshot.tabs[1]
    guard case let .split(axis, ratio, _, _) = second.layout else {
      throw MuxError(.invalidRequest, "second tab lost its split")
    }
    #expect(axis == .topBottom && ratio == 0.6)
    #expect(snapshot.activeTab == second.id)
    #expect(second.zoomedPane == outcome.panes[3])
    let saved = try await state(gateway)
    #expect(saved.outputOptOut)
    #expect(
      saved.panes.first { $0.pane == outcome.panes[2] }?.directoryFallback
        == true
    )
    #expect(
      saved.panes.first { $0.pane == outcome.panes[2] }?.localDirectory == nil
    )
    // A template never repairs a claimed worker.
    do {
      _ = try await gateway.execute(.newWorkspaceFromTemplate(template))
      Issue.record("second template claimed the worker")
    } catch let error as MuxError { #expect(error.code == .invalidRequest) }
  }

  @Test
  func templateValidationAndLaunchBounds() throws {
    let tab = WorkspaceTemplateTab(
      name: "1",
      layout: .split(
        axis: .leftRight,
        ratio: 0.5,
        first: .pane(slot: 0),
        second: .pane(slot: 0)
      ),
      activeSlot: 0
    )
    let template = WorkspaceTemplate(
      name: nil,
      columns: 80,
      rows: 24,
      remainOnExit: false,
      launch: shellLaunch(),
      panes: [shellLaunch(), shellLaunch()],
      tabs: [tab],
      activeTab: 0,
      outputOptOut: false
    )
    #expect(throws: MuxError.self) { try template.validate(maxPanes: 32) }
    var badRatio = template
    badRatio.tabs = [
      WorkspaceTemplateTab(
        name: "1",
        layout: .split(
          axis: .leftRight,
          ratio: 1,
          first: .pane(slot: 0),
          second: .pane(slot: 1)
        ),
        activeSlot: 0
      )
    ]
    #expect(throws: MuxError.self) { try badRatio.validate(maxPanes: 32) }
    badRatio.tabs[0].layout = .split(
      axis: .leftRight,
      ratio: 0.5,
      first: .pane(slot: 0),
      second: .pane(slot: 1)
    )
    try badRatio.validate(maxPanes: 32)
    #expect(throws: MuxError.self) { try badRatio.validate(maxPanes: 1) }
    #expect(SavedPaneLaunch(command: nil) == .loginShell)
    #expect(
      SavedPaneLaunch(command: [String(repeating: "x", count: 5000)])
        == .commandTooLong
    )
  }

  @Test
  func onlyLocalDirectoriesAreSaved() {
    #expect(SavedLayoutHost.isLocal(nil))
    #expect(SavedLayoutHost.isLocal(""))
    #expect(SavedLayoutHost.isLocal("LOCALHOST", localName: "mbp.local"))
    #expect(SavedLayoutHost.isLocal("MBP", localName: "mbp.local"))
    #expect(SavedLayoutHost.isLocal("mbp.local.", localName: "mbp"))
    #expect(!SavedLayoutHost.isLocal("build.example.com", localName: "mbp"))
    var state = TerminalState(columns: 20, rows: 4)
    var parser = Parser()
    let report = Array("\u{1B}]7;file://build.example.com/srv/app\u{07}".utf8)
    parser.consume(report.span, into: &state)
    #expect(state.workingDirectoryHost == "build.example.com")
    #expect(state.takeEvents().contains { $0 == .workingDirectory("/srv/app") })
  }
}
