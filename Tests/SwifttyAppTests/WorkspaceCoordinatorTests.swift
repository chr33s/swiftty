import AppKit
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
@testable import Swiftty
import SwifttyCore
import Testing
import TestSupport

/// Configuration to launch spec, matching the direct-window rules.
@Suite
struct WorkspaceLaunchTests {

  @Test
  func `no command runs the login shell from the frontend's directory`() {
    let spec = WorkspaceLaunch.spec(
      Configuration.configured([("working-directory", "inherit")]),
      environment: ["A": "1"],
      currentDirectory: "/var/frontend"
    )
    #expect(spec.command == nil)
    #expect(spec.workingDirectory == "/var/frontend")
    #expect(spec.environment == ["A": "1"])
  }

  @Test
  func `explicit and home directories are kept`() {
    let home = WorkspaceLaunch.spec(
      Configuration.configured([("working-directory", "home")]),
      currentDirectory: "/var/frontend"
    )
    #expect(home.workingDirectory == NSHomeDirectory())
    let explicit = WorkspaceLaunch.spec(
      Configuration.configured([("working-directory", "/tmp")]),
      currentDirectory: "/var/frontend"
    )
    #expect(explicit.workingDirectory == "/tmp")
  }

  @Test
  func `configured commands keep shell and direct syntax`() {
    let direct = WorkspaceLaunch.spec(
      Configuration.configured([("command", "direct:/bin/echo a b")])
    )
    #expect(direct.command == ["/bin/echo", "a", "b"])
    let shell = WorkspaceLaunch.spec(
      Configuration.configured([("command", "vim ~/notes")])
    )
    #expect(
      shell.command == [
        "/bin/bash", "--noprofile", "--norc", "-c", "exec -l vim ~/notes",
      ]
    )
  }

  @Test
  func `new workspaces start as one shell at the window size`() {
    let request = WorkspaceLaunch.request(Configuration())
    #expect(request.columns == WorkspaceLaunch.columns)
    #expect(request.rows == WorkspaceLaunch.rows)
    #expect(request.name == nil)
  }
}

/// Which workspace, if any, a launch opens without asking.
@Suite
struct WorkspaceLaunchActionTests {
  func summary(_ id: WorkspaceID, attached: Bool = false) -> WorkspaceSummary {
    WorkspaceSummary(
      id: id,
      name: "w",
      tabCount: 1,
      paneCount: 1,
      createdAt: Date(),
      isAttached: attached
    )
  }

  let a = WorkspaceID()
  let b = WorkspaceID()

  @Test
  func `the last workspace reopens when free`() {
    let action = WorkspaceCoordinator.launchAction(
      [summary(a), summary(b)],
      last: b
    )
    #expect(action == .open(b))
  }

  @Test
  func `the only free workspace opens when the last is unknown or gone`() {
    let list = [summary(a), summary(b, attached: true)]
    #expect(WorkspaceCoordinator.launchAction(list, last: nil) == .open(a))
    #expect(
      WorkspaceCoordinator.launchAction(list, last: WorkspaceID()) == .open(a)
    )
  }

  @Test
  func `a last workspace in use elsewhere is offered, not replaced`() {
    let list = [summary(a), summary(b, attached: true)]
    #expect(WorkspaceCoordinator.launchAction(list, last: b) == .choose)
  }

  @Test
  func `several free workspaces are offered`() {
    let list = [summary(a), summary(b)]
    #expect(WorkspaceCoordinator.launchAction(list, last: nil) == .choose)
  }

  @Test
  func `no free workspace creates one`() {
    #expect(WorkspaceCoordinator.launchAction([], last: nil) == .create)
    #expect(
      WorkspaceCoordinator.launchAction([summary(a, attached: true)], last: a)
        == .create
    )
  }
}

extension MuxNativeTests {
  /// A coordinator whose opens attach over new connections to `endpoint`.
  func coordinator(
    _ endpoint: SMXEndpoint,
    opens: @escaping @MainActor () -> Void = {},
    defaults: UserDefaults
  ) -> WorkspaceCoordinator {
    WorkspaceCoordinator(
      configuration: Configuration(),
      listWorkspaces: { throw MuxError(.notFound) },
      openWorkspace: { selector, configuration, lease in
        opens()
        let connection = try await MuxConnection.connect(
          endpoint: endpoint,
          frontend: .native
        )
        do {
          let controller = try await MuxWorkspaceController.open(
            selector,
            configuration: configuration,
            connection: connection,
            takeover: lease
          )
          controller.window?.isReleasedWhenClosed = false
          return controller
        } catch {
          await connection.close()
          throw error
        }
      },
      reportListError: { Issue.record($0) },
      reportOpenError: { Issue.record($0) },
      defaults: defaults
    )
  }

  func scratchDefaults() throws -> UserDefaults {
    let suite = "swiftty.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }

  @Test(.enabled(if: hasMetal))
  func `opening a workspace this app shows reveals it without attaching again`()
    async throws
  {
    try await withFixture { f in
      var opens = 0
      let workspaces = coordinator(
        f.endpoint,
        opens: { opens += 1 },
        defaults: try scratchDefaults()
      )
      workspaces.install(f.controller)
      workspaces.open(f.workspace)
      workspaces.open(f.workspace, server: f.controller.server)
      #expect(!workspaces.isPending(.open(f.workspace)))
      #expect(opens == 0)
      #expect(workspaces.controllers.count == 1)
      #expect(
        workspaces.controller(
          for: .init(server: f.controller.server, workspace: f.workspace)
        ) === f.controller
      )
      // Another service instance's identity matches nothing.
      #expect(
        workspaces.controller(
          for: .init(server: ServerInstanceID(), workspace: f.workspace)
        ) == nil
      )
      workspaces.install(f.controller)
      #expect(workspaces.controllers.count == 1)
    }
  }

  @Test(.enabled(if: hasMetal))
  func
    `each New Workspace is its own one-shell workspace, and Quit detaches all`()
    async throws
  {
    try await withFixture { f in
      let workspaces = coordinator(f.endpoint, defaults: try scratchDefaults())
      workspaces.create()
      try #require(await until { workspaces.controllers.count == 1 })
      // A second create once the first is shown makes another workspace.
      workspaces.create()
      try #require(await until { workspaces.controllers.count == 2 })
      let a = workspaces.controllers[0]
      let b = workspaces.controllers[1]
      try #require(await until { a.workspace != nil && b.workspace != nil })
      #expect(a.attachedWorkspace != b.attachedWorkspace)
      for c in [a, b] {
        #expect(c.workspace?.tabs.count == 1)
        #expect(c.workspace?.panes.count == 1)
        // One tab: the strip is hidden, the title shown.
        #expect(!c.showsTabStrip)
      }
      // Growing one workspace leaves the other alone.
      a.newTab()
      try #require(await until { a.workspace?.tabs.count == 2 })
      #expect(a.showsTabStrip)
      #expect(b.workspace?.tabs.count == 1)
      #expect(a.holdsLease && b.holdsLease)
      // Closing one window detaches only that one.
      let ids = [a, b].compactMap(\.attachedWorkspace)
      b.close()
      try #require(await until { workspaces.controllers.count == 1 })
      #expect(a.holdsLease)
      await workspaces.terminate()
      #expect(!a.holdsLease)
      #expect(workspaces.controllers.isEmpty)
      // Nothing new is admitted after Quit began.
      workspaces.create()
      #expect(!workspaces.isPending(.create))
      a.close()
      // The service still owns both workspaces and their shells.
      let control = try await MuxConnection.connect(
        endpoint: f.endpoint,
        frontend: .control
      )
      try await RuntimeFixture.withCleanup {
        guard
          case let .workspaces(list) = try await control.execute(
            .listWorkspaces
          )
        else { throw MuxError(.invalidRequest) }
        for id in ids {
          let ws = try #require(list.first { $0.id == id })
          #expect(ws.livePaneCount != 0)
        }
      } cleanup: {
        await control.close()
      }
    }
  }

  @Test(.enabled(if: hasMetal))
  func `workspace commands validate against this window's lease`() async throws
  {
    try await withFixture { f in
      let c = f.controller
      @MainActor
      func enabled(_ selector: Selector) -> Bool {
        c.validateMenuItem(
          NSMenuItem(title: "", action: selector, keyEquivalent: "")
        )
      }
      #expect(enabled(#selector(c.newTerminalTab(_:))))
      #expect(enabled(#selector(c.splitRight(_:))))
      #expect(enabled(#selector(c.endCurrentWorkspace(_:))))
      // One tab and one pane: nothing to cycle or focus between.
      #expect(!enabled(#selector(c.selectNextTab(_:))))
      #expect(!enabled(#selector(c.focusPaneInDirection(_:))))
      await c.detach()
      #expect(!enabled(#selector(c.newTerminalTab(_:))))
      #expect(!enabled(#selector(c.endActivePane(_:))))
    }
  }
}
