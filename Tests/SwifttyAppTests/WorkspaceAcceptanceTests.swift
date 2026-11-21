import AppKit
import Foundation
import MuxNavigation
import SwiftMuxClient
import SwiftMuxProtocol
@testable import Swiftty
import SwifttyCore
import Testing

/// Startup when the service cannot be reached: recoverable, and never a
/// non-persistent shell in its place (plan acceptance test 11).
@MainActor
@Suite
struct WorkspaceServiceStartupTests {
  final class Probe {
    var opens = 0
    var retries: [String] = []
    var listings = 0
  }

  func coordinator(
    _ probe: Probe,
    failures: Int,
    error: any Error
  ) -> WorkspaceCoordinator {
    WorkspaceCoordinator(
      configuration: Configuration(),
      listWorkspaces: {
        probe.listings += 1
        if probe.listings <= failures { throw error }
        return WorkspaceListing(server: nil, workspaces: [])
      },
      openWorkspace: { _, _, _ in
        probe.opens += 1
        throw CancellationError()
      },
      reportListError: { Issue.record($0) },
      reportOpenError: { Issue.record($0) },
      defaults: UserDefaults(suiteName: "swiftty.tests.\(UUID())")!
    )
  }

  func until(_ predicate: () -> Bool) async -> Bool {
    for _ in 0 ..< 200 {
      if predicate() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return predicate()
  }

  nonisolated static let unavailable: [any Error & Sendable] = [
    MuxUnavailable(
      message: "Allow the SwiftMux helper in System Settings › Login Items."
    ), MuxUnavailable(message: "The SwiftMux helper is missing."),
    MuxUnavailable(
      message: "The running SwiftMux service is a different version."
    ), MuxError(.connectionLost),
  ]

  @Test(arguments: 0 ..< unavailable.count)
  func `an unavailable service offers retry and opens nothing on cancel`(
    _ index: Int
  ) async {
    let probe = Probe()
    let workspaces = coordinator(
      probe,
      failures: .max,
      error: Self.unavailable[index]
    )
    workspaces.launch { error in
      probe.retries.append(error.localizedDescription)
      return false
    }
    #expect(await until { probe.retries.count == 1 })
    try? await Task.sleep(for: .milliseconds(50))
    #expect(probe.opens == 0)
    #expect(workspaces.controllers.isEmpty)
  }

  @Test
  func `retrying after the service recovers creates one workspace`() async {
    let probe = Probe()
    let workspaces = coordinator(
      probe,
      failures: 2,
      error: MuxUnavailable(message: "unavailable")
    )
    workspaces.launch { error in
      probe.retries.append(error.localizedDescription)
      return true
    }
    #expect(await until { probe.opens == 1 })
    #expect(probe.retries == ["unavailable", "unavailable"])
    #expect(probe.listings == 3)
  }

  @Test
  func `connection failures become recoverable service errors`() async {
    for error in [
      MuxError(.incompatibleVersion, "SMX/2"), MuxError(.connectionLost),
    ] {
      await #expect(throws: MuxUnavailable.self) {
        _ = try await MuxWorkspaceController.connect { throw error }
      }
    }
    // Alerts show the service's message, not a bridged error number.
    #expect(
      MuxError(.invalidRequest, "decode").localizedDescription
        == "invalidRequest: decode"
    )
    await #expect(throws: CancellationError.self) {
      _ = try await MuxWorkspaceController.connect { throw CancellationError() }
    }
  }
}

extension MuxNativeTests {
  /// Plan acceptance tests 13 to 15: configuration reaches every window,
  /// stale frames from another service instance are ignored, and an
  /// attention link opens its target without detaching another window.
  @Test(.enabled(if: hasMetal))
  func `reload, stale servers and attention links respect every window`()
    async throws
  {
    try await withFixture { f in
      let workspaces = coordinator(f.endpoint, defaults: try scratchDefaults())
      workspaces.install(f.controller)
      workspaces.create()
      try #require(await until { workspaces.controllers.count == 2 })
      let a = f.controller
      let b = workspaces.controllers[1]
      try #require(await until { b.workspace != nil && b.activePane != nil })

      // 13: a reload reaches every registered window's panes.
      var config = Configuration()
      config.copyOnSelect = true
      config.fontSize = 17
      workspaces.apply(config)
      for c in [a, b] {
        for view in c.views.values {
          #expect(view.config.copyOnSelect)
          #expect(view.config.fontSize == 17)
        }
      }

      // 14: a frame from another service instance never installs.
      let view = try #require(activeView(a))
      let frame = try #require(await waitPresented(view) { _ in true })
      var foreign = frame
      foreign.identity.server = ServerInstanceID()
      foreign.identity.revision &+= 1_000
      let imported = MuxPaneView.importFrame(foreign, limits: .standard)
      view.receive(imported, server: a.server)
      view.draw(in: view)
      #expect(view.presented?.frame.identity.server == a.server)

      // 15: an attention link to the second workspace reveals that window
      // and leaves the first attached.
      let bWorkspace = try #require(b.attachedWorkspace)
      let bPane = try #require(b.activePane)
      try await workspaces.reveal(
        PaneTarget(workspace: bWorkspace, tab: nil, pane: bPane),
        takeover: nil
      )
      #expect(workspaces.controllers.count == 2)
      #expect(a.holdsLease && b.holdsLease)
      #expect(b.activePane == bPane)
      await b.detach()
      b.close()
    }
  }
}
