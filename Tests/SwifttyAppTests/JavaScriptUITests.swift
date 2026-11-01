import AppKit
import SwiftMuxClient
import SwiftMuxProtocol
import SwifttyJS
@testable import Swiftty
import Testing
import TestSupport

extension MuxNativeTests {
  @Test(.enabled(if: hasMetal))
  func javaScriptReplaysHiddenWorkspaceIconThroughService() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    let config = try JavaScriptConfiguration.provision(at: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    try "swiftty.events.bindKey('cmd+i', () => swiftty.ui.setTabIcon('🧪'));"
      .write(to: config, atomically: true, encoding: .utf8)
    let fixture = try await open(javaScriptDirectory: directory)
    try await RuntimeFixture.withCleanup {
      let controller = fixture.controller
      #expect(await until { controller.automationKeys.contains("cmd+i") })
      _ = try await controller.connection.execute(.subscribeAutomation(false))
      let other = try await MuxConnection.connect(
        endpoint: fixture.endpoint,
        frontend: .native
      )
      try await RuntimeFixture.withCleanup {
        guard
          case let .created(workspace) = try await other.execute(
            .newWorkspace(
              NewWorkspaceRequest(
                launch: LaunchSpec(
                  command: ["/bin/sh"],
                  workingDirectory: "/tmp",
                  environment: [
                    "PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory(),
                  ]
                )
              )
            )
          )
        else { throw MuxError(.invalidRequest) }
        _ = try await other.execute(.attach(AttachRequest(.id(workspace.id))))
        _ = try await other.execute(.subscribeAutomation(true))
        let tab = try #require(workspace.activeTabSnapshot)
        _ = try await other.execute(
          .automationKey(pane: tab.activePane, shortcut: "cmd+i")
        )
        // Receiving the action on another real client proves that the service
        // has cached it before the original controller resubscribes.
        let icon = try await withThrowingTaskGroup(of: JavaScriptAction.self) {
          group in
          group.addTask {
            try await Task.sleep(for: .seconds(5))
            throw MuxError(.connectionLost, "Timed out waiting for tab icon")
          }
          group.addTask {
            while let event = try await other.nextEvent() {
              if case let .automation(data) = event,
                let action = try? JSONDecoder()
                  .decode(JavaScriptAction.self, from: data),
                action.kind == .tabIcon
              {
                return action
              }
            }
            throw MuxError(.connectionLost)
          }
          defer { group.cancelAll() }
          return try await group.next()!
        }
        #expect(icon.id == tab.id.description)
        #expect(icon.text == "🧪")
        #expect(controller.automationTabIcons[tab.id] == nil)
        _ = try await controller.connection.execute(.subscribeAutomation(true))
        #expect(await until { controller.automationTabIcons[tab.id] == "🧪" })
        #expect(controller.workspace?.id == fixture.workspace)
        _ = try await other.execute(.detach)
        controller.command(.switchWorkspace(.id(workspace.id)))
        #expect(await until { controller.workspace?.id == workspace.id })
        #expect(controller.window?.title.hasPrefix("🧪 ") == true)
      } cleanup: {
        await other.close()
      }
    } cleanup: {
      await retire(fixture)
    }
  }

  @Test(.enabled(if: hasMetal))
  func javaScriptTabIconsSurviveWorkspaceSwitches() async throws {
    try await withFixture { fixture in
      let controller = fixture.controller
      let launch = LaunchSpec(
        command: ["/bin/sh"],
        workingDirectory: "/tmp",
        environment: ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory()]
      )
      guard
        case let .created(workspace) = try await controller.connection.execute(
          .newWorkspace(NewWorkspaceRequest(launch: launch))
        )
      else {
        Issue.record("no second workspace")
        return
      }
      let tab = try #require(workspace.activeTabSnapshot?.id)
      @MainActor
      func setIcon(_ text: String?) throws {
        var action = ["kind": "tabIcon", "id": tab.description]
        action["text"] = text
        controller.handleAutomation(try JSONEncoder().encode(action))
      }
      try setIcon("🧪")
      controller.command(.switchWorkspace(.id(workspace.id)))
      #expect(await until { controller.workspace?.id == workspace.id })
      #expect(controller.window?.title.hasPrefix("🧪 ") == true)

      for icon: String? in ["⭐", nil] {
        controller.command(.switchWorkspace(.id(fixture.workspace)))
        #expect(await until { controller.workspace?.id == fixture.workspace })
        try setIcon(icon)
        controller.command(.switchWorkspace(.id(workspace.id)))
        #expect(await until { controller.workspace?.id == workspace.id })
        #expect(controller.automationTabIcons[tab] == icon)
        if let icon {
          #expect(controller.window?.title.hasPrefix(icon + " ") == true)
        } else {
          #expect(controller.window?.title.hasPrefix("⭐ ") == false)
        }
      }
    }
  }

  @Test(.enabled(if: hasMetal))
  func javaScriptUpdatesNativeChromeAndHandlesKeyEvents() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    let config = try JavaScriptConfiguration.provision(at: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    try """
    let count = 0;
    swiftty.ui.registerStatusItem('manual', {align: 'left', render: () => ({text: 'Count ' + count, color: '#ff0000'})});
    swiftty.ui.registerStatusItem('clock', {align: 'right', refreshInterval: 0.05, render: () => 'Clock ' + (++count)});
    swiftty.events.bindKey('cmd+k', () => {
      swiftty.ui.setBadge('JS');
      swiftty.ui.setTabIcon('🧪');
      swiftty.ui.notify('JavaScript', 'native notification');
      swiftty.ui.refreshStatusItem('manual');
      const child = swiftty.currentPane.split('horizontal');
      child.write("printf 'JS_NATIVE_READY\\n'\\n");
    });
    """
    .write(to: config, atomically: true, encoding: .utf8)
    let fixture = try await open(javaScriptDirectory: directory)
    try await RuntimeFixture.withCleanup {
      let controller = fixture.controller
      let parent = try #require(controller.activePane)
      var notifications: [String] = []
      controller.automationNotify = { notifications.append($0 + ":" + $1) }
      #expect(await until { controller.automationKeys.contains("cmd+k") })
      let labels = {
        controller.automationStatus.subviews.flatMap(\.subviews)
          .compactMap { $0 as? NSTextField }
      }
      #expect(
        await until { labels().contains { $0.stringValue.hasPrefix("Clock ") } }
      )
      let clock = try #require(
        labels().first { $0.stringValue.hasPrefix("Clock ") }
      )
      let initialClock = clock.stringValue
      #expect(await until { clock.stringValue != initialClock })
      let event = try #require(
        NSEvent.keyEvent(
          with: .keyDown,
          location: .zero,
          modifierFlags: [.command],
          timestamp: 0,
          windowNumber: controller.window?.windowNumber ?? 0,
          context: nil,
          characters: "k",
          charactersIgnoringModifiers: "k",
          isARepeat: false,
          keyCode: 40
        )
      )
      let view = try #require(controller.views[parent])
      controller.showSearch()
      #expect(controller.window?.firstResponder !== view)
      #expect(!view.performKeyEquivalent(with: event))
      controller.hideSearch()
      #expect(controller.window?.makeFirstResponder(view) == true)
      #expect(view.performKeyEquivalent(with: event))
      #expect(
        await until { controller.views.count == 2 && !notifications.isEmpty }
      )
      #expect(NSApp.dockTile.badgeLabel == "JS")
      let tab = try #require(controller.activeTab?.id)
      #expect(controller.automationTabIcons[tab] == "🧪")
      #expect(controller.window?.title.hasPrefix("🧪 ") == true)
      #expect(notifications == ["JavaScript:native notification"])
      let child = try #require(
        controller.views.first { $0.key != parent }?.value
      )
      #expect(controller.window?.makeFirstResponder(child) == true)
      #expect(!view.performKeyEquivalent(with: event))
      #expect(
        await waitPresented(child) { $0.lines.contains("JS_NATIVE_READY") }
          != nil
      )
      let manual = try #require(
        labels().first { $0.stringValue.hasPrefix("Count ") }
      )
      #expect(manual.textColor?.usingColorSpace(.sRGB)?.redComponent == 1)
      controller.window?.contentView?.layoutSubtreeIfNeeded()
      #expect(controller.automationStatus.frame.height == 24)
      #expect(manual.frame.width > 0)
      #expect(manual.stringValue != "Count 0")
      let manualRect = manual.convert(
        manual.bounds,
        to: controller.automationStatus
      )
      let clockRect = clock.convert(
        clock.bounds,
        to: controller.automationStatus
      )
      #expect(manualRect.midX < controller.automationStatus.bounds.midX)
      #expect(clockRect.midX > controller.automationStatus.bounds.midX)
    } cleanup: {
      NSApp.dockTile.badgeLabel = nil
      await retire(fixture)
    }
  }
}
