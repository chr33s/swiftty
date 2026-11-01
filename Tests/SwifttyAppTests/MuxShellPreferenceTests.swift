import AppKit
import SwiftMuxClient
import SwiftMuxProtocol
@testable import Swiftty
import SwifttyConfig
import SwifttyCore
import Testing

extension MuxInboxRefreshTests {
  @Test(arguments: [false, true])
  func resettingShellPreferenceResolvesFutureLaunches(
    initialProfile: Bool
  ) async throws {
    _ = NSApplication.shared
    let service = InboxReplyService()
    let connection = try await MuxConnection.connect(
      endpoint: service.listener.endpoint,
      frontend: .native
    )
    var config = Configuration.configured([
      ("command", "direct:/bin/echo configuration-default"),
      ("working-directory", "/tmp"),
    ])
    config.shellProfiles["bash"] = ShellLaunchProfile(
      arguments: ["--login"],
      environment: ["SWIFTTY_TEST_PROFILE": "selected"]
    )
    if initialProfile { config.preferredShell = .bash }
    let controller = try await MuxWorkspaceController.open(
      .id(service.workspace.id),
      configuration: config,
      connection: connection
    )
    defer { controller.close() }

    func launch() {
      controller.newTab()
      controller.split(.leftRight, pane: PaneID())
    }
    launch()
    try #require(
      await until { service.state.withLock { $0.splitLaunches.count == 1 } }
    )
    let first = service.state.withLock { $0.tabLaunches[0] }
    if initialProfile {
      #expect(first?.command == ["/bin/bash", "--login"])
    } else {
      #expect(first == nil)
      #expect(service.state.withLock { $0.splitLaunches[0] } == nil)
      config.preferredShell = .bash
      controller.apply(config)
      launch()
      try #require(
        await until { service.state.withLock { $0.splitLaunches.count == 2 } }
      )
    }

    config.preferredShell = nil
    controller.apply(config)
    // Repeated reloads must not revive the original workspace launch.
    controller.apply(config)
    let count = service.state.withLock { $0.tabLaunches.count }
    launch()
    launch()
    try #require(
      await until {
        service.state.withLock { $0.splitLaunches.count == count + 2 }
      }
    )
    let launches = service.state.withLock {
      Array($0.tabLaunches.suffix(2)) + Array($0.splitLaunches.suffix(2))
    }
    for launch in launches {
      let launch = try #require(launch)
      #expect(launch.command == ["/bin/echo", "configuration-default"])
      #expect(launch.workingDirectory == "/tmp")
      #expect(launch.environment["SWIFTTY_TEST_PROFILE"] == nil)
    }
    await controller.detach()
  }
}
