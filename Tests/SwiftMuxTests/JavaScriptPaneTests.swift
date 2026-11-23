import SwiftMuxGuardian
import Dispatch
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
@testable import SwiftMuxService
import SwifttyJS
import Synchronization
import Testing
import TestSupport

@Suite(.serialized, .timeLimit(.minutes(1)))
struct JavaScriptPaneTests {
  @Test(arguments: [1, 8])
  func shrinkingStdoutFiltersKeepReadTurnsBounded(replacementBytes: Int) throws
  {
    let javascript = JavaScriptRuntime()
    try javascript.evaluate(
      "swiftty.filter.onStdout(s => 'x'.repeat(\(replacementBytes)));"
    )
    var limits = MuxLimits.standard
    limits.readTurnBytes = 64
    let bytesRead = Mutex(0)
    let firstPublishedRead = Mutex<Int?>(nil)
    let published = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let runtime = PaneRuntime(
      id: PaneID(),
      workspace: WorkspaceID(),
      columns: 80,
      rows: 24,
      historyBytes: 0,
      limits: limits,
      javaScriptRuntime: javascript,
      observingIO: { _, observation in
        if observation.phase == .read {
          bytesRead.withLock { $0 += observation.byteCount }
        }
      }
    )
    runtime.onChange = {
      firstPublishedRead.withLock { value in
        if value == nil { value = bytesRead.withLock { $0 } }
      }
      published.signal()
    }
    runtime.onEvent = { event in if case .finished = event { finished.signal() }
    }
    defer {
      runtime.terminate()
      #expect(finished.wait(timeout: .now() + 5) == .success)
    }
    let launcher = PaneLauncher(
      launcherPath: try launcherPath(),
      innerTerm: SMX.fallbackInnerTerm
    )
    let launched = DispatchSemaphore(value: 0)
    let launchResult = Mutex<Result<Void, MuxError>?>(nil)
    runtime.queue.async {
      runtime.launch(
        LaunchSpec(command: [
          "/usr/bin/python3", "-c",
          "import os,tty; tty.setraw(0); os.write(1,b'a'*4096)",
        ]),
        launcher: launcher
      ) { result in
        launchResult.withLock { $0 = result }
        launched.signal()
      }
    }
    try #require(launched.wait(timeout: .now() + 5) == .success)
    try #require(launchResult.withLock { $0 }).get()
    try #require(published.wait(timeout: .now() + 5) == .success)
    let firstRead = try #require(firstPublishedRead.withLock { $0 })
    #expect(firstRead > 0)
    #expect(firstRead <= limits.readTurnBytes)
  }

  /// Awaits shutdown instead of blocking a cooperative thread: on small CI
  /// runners a blocked thread can starve the work that finishes the exit.
  private func retire(_ service: MuxService) async {
    await withCheckedContinuation { continuation in
      service.prepareToExit { continuation.resume() }
    }
  }

  @Test
  func filtersRunAtThePTYBoundary() async throws {
    let javascript = JavaScriptRuntime()
    try javascript.evaluate(
      """
      swiftty.filter.onStdout(s => s.replaceAll('SECRET', '[hidden]'));
      swiftty.filter.onStdin(s => s.replaceAll('hello', 'expanded-input'));
      """
    )
    var configuration = MuxServiceConfiguration(
      launcherPath: try launcherPath()
    )
    configuration.javaScriptRuntime = javascript
    let harness = try Harness(configuration: configuration)
    try await RuntimeFixture.withCleanup {
      let connection = try await harness.connect(.control)
      let program = """
        import os, tty
        tty.setraw(0)
        os.write(1, b'SECRET READY\\r\\n')
        data = b''
        while not data.endswith(b'\\n'):
            data += os.read(0, 1)
        os.write(1, b'GOT:' + data + b'\\r\\n')
        """
      let request = NewWorkspaceRequest(
        launch: LaunchSpec(command: ["/usr/bin/python3", "-u", "-c", program]),
        remainOnExit: true
      )
      guard
        case let .created(workspace) = try await connection.execute(
          .newWorkspace(request)
        )
      else {
        Issue.record("Missing workspace")
        return
      }
      let runtime = try #require(
        await harness.service.runtime(workspace.tabs[0].activePane)
      )
      let readyDeadline = ContinuousClock.now + .seconds(5)
      while !runtime.screenLines()
        .contains(where: { $0.contains("[hidden] READY") }),
        ContinuousClock.now < readyDeadline
      { try await Task.sleep(for: .milliseconds(10)) }
      try #require(
        runtime.screenLines().contains(where: { $0.contains("[hidden] READY") })
      )
      try #require(runtime.reserve(6))
      runtime.write(.text("hello\n"), estimate: 6)
      let outputDeadline = ContinuousClock.now + .seconds(5)
      while !runtime.screenLines()
        .contains(where: { $0.contains("GOT:expanded-input") }),
        ContinuousClock.now < outputDeadline
      { try await Task.sleep(for: .milliseconds(10)) }
      #expect(
        runtime.screenLines()
          .contains(where: { $0.contains("GOT:expanded-input") })
      )
      #expect(runtime.outstandingInput.withLock { $0 } == 0)
      await connection.close()
    } cleanup: {
      await retire(harness.service)
    }
  }
}

extension JavaScriptPaneTests {
  @Test
  func subscriptionsReplayLatestStateAndDisconnectRemovesSubscribers()
    async throws
  {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    let configFile = try JavaScriptConfiguration.provision(at: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    try """
    let count = 0;
    swiftty.events.bindKey('cmd+b', () => {
      swiftty.ui.setBadge(String(++count));
      swiftty.ui.notify('event', String(count));
    });
    """
    .write(to: configFile, atomically: true, encoding: .utf8)
    var config = MuxServiceConfiguration(launcherPath: try launcherPath())
    config.javaScriptDirectory = directory
    let harness = try Harness(configuration: config)
    try await RuntimeFixture.withCleanup {
      let controller = try await harness.connect()
      guard
        case let .created(ws) = try await controller.execute(
          .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
        )
      else { throw MuxError(.invalidRequest) }
      _ = try await controller.attachAndShow(.id(ws.id))
      let subscriber = try await harness.connect()
      _ = try await subscriber.execute(.subscribeAutomation(true))
      _ = try await automationEvent(subscriber, kind: .keybinding)
      #expect(await harness.service.automation.subscribers.count == 1)
      _ = try await controller.execute(
        .automationKey(pane: ws.tabs[0].activePane, shortcut: "cmd+b")
      )
      #expect(try await automationEvent(subscriber, kind: .badge).text == "1")
      #expect(
        try await automationEvent(subscriber, kind: .notification).text == "1"
      )
      _ = try await subscriber.execute(.subscribeAutomation(false))
      #expect(await harness.service.automation.subscribers.isEmpty)
      _ = try await controller.execute(
        .automationKey(pane: ws.tabs[0].activePane, shortcut: "cmd+b")
      )
      // The notification is queued when there are no subscribers. Await that
      // service-side barrier before requesting replay on a different connection.
      let queuedDeadline = ContinuousClock.now + .seconds(5)
      while await harness.service.automation.notifications.isEmpty,
        ContinuousClock.now < queuedDeadline
      { try await Task.sleep(for: .milliseconds(10)) }
      try #require(await harness.service.automation.notifications.count == 1)
      _ = try await subscriber.execute(.subscribeAutomation(true))
      let replayedNotification = try await automationEvent(subscriber)
      #expect(replayedNotification.kind == .notification)
      #expect(replayedNotification.text == "2")
      #expect(try await automationEvent(subscriber, kind: .badge).text == "2")
      _ = try await automationEvent(subscriber, kind: .keybinding)
      #expect(await harness.service.automation.notifications.isEmpty)
      await subscriber.close()
      let disconnectedDeadline = ContinuousClock.now + .seconds(5)
      while !(await harness.service.automation.subscribers.isEmpty),
        ContinuousClock.now < disconnectedDeadline
      { try await Task.sleep(for: .milliseconds(10)) }
      #expect(await harness.service.automation.subscribers.isEmpty)
      let replacement = try await harness.connect()
      _ = try await replacement.execute(.subscribeAutomation(true))
      let replayedBadge = try await automationEvent(replacement)
      #expect(replayedBadge.kind == .badge)
      #expect(replayedBadge.text == "2")
      // Replay is presentation only: the previously delivered notification is gone.
      #expect(await harness.service.automation.notifications.isEmpty)
      await replacement.close()
      await controller.close()
    } cleanup: {
      await retire(harness.service)
    }
  }

  private func automationEvent(
    _ connection: MuxConnection,
    kind: JavaScriptAction.Kind? = nil
  ) async throws -> JavaScriptAction {
    try await withTimeout(.seconds(5)) {
      while let event = try await connection.nextEvent() {
        if case let .automation(data) = event,
          let action = try? JSONDecoder()
            .decode(JavaScriptAction.self, from: data),
          kind == nil || action.kind == kind
        {
          return action
        }
      }
      throw MuxError(.connectionLost)
    }
  }

  @Test
  func productionConfigReplaysUIAndCreatesRealSplitPanes() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    let config = try JavaScriptConfiguration.provision(at: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(#"{/* automation data */"badge":"ready",}"#.utf8)
      .write(to: directory.appendingPathComponent("automation.jsonc"))
    try """
    const settings = swiftty.jsonc.read('automation.jsonc');
    swiftty.ui.setBadge(settings.badge);
    swiftty.ui.registerStatusItem('left', {align: 'left', render: () => 'hello'});
    swiftty.events.bindKey('cmd+k', () => {
      const child = swiftty.currentPane.split('horizontal');
      child.write("printf 'JS_CHILD_OK\\n'\\n");
    });
    swiftty.events.bindKey('cmd+w', () => swiftty.currentPane.close());
    """
    .write(to: config, atomically: true, encoding: .utf8)
    var configuration = MuxServiceConfiguration(
      launcherPath: try launcherPath()
    )
    configuration.javaScriptDirectory = directory
    let harness = try Harness(configuration: configuration)
    try await RuntimeFixture.withCleanup {
      let connection = try await harness.connect()
      guard
        case let .created(ws) = try await connection.execute(
          .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
        )
      else { throw MuxError(.invalidRequest) }
      _ = try await connection.attachAndShow(.id(ws.id))
      _ = try await connection.execute(.subscribeAutomation(true))
      #expect(
        try await automationEvent(connection, kind: .badge).text == "ready"
      )
      #expect(
        try await automationEvent(connection, kind: .status).status?.text
          == "hello"
      )
      let parent = ws.tabs[0].activePane
      _ = try await connection.execute(
        .automationKey(pane: parent, shortcut: "cmd+k")
      )
      let split = try await withTimeout(.seconds(5)) {
        while let event = try await connection.nextEvent() {
          if case let .layout(layout) = event, layout.panes.count == 2 {
            return layout
          }
        }
        throw MuxError(.connectionLost)
      }
      let child = try #require(split.panes.first { $0.id != parent }?.id)
      let runtime = try #require(await harness.service.runtime(child))
      let deadline = ContinuousClock.now + .seconds(5)
      while !runtime.screenLines()
        .contains(where: {
          $0.trimmingCharacters(in: .whitespaces) == "JS_CHILD_OK"
        }), ContinuousClock.now < deadline
      { try await Task.sleep(for: .milliseconds(10)) }
      #expect(
        runtime.screenLines()
          .contains(where: {
            $0.trimmingCharacters(in: .whitespaces) == "JS_CHILD_OK"
          })
      )
      _ = try await connection.execute(
        .automationKey(pane: child, shortcut: "cmd+w")
      )
      let remaining = try await withTimeout(.seconds(5)) {
        while let event = try await connection.nextEvent() {
          if case let .layout(layout) = event, layout.panes.count == 1 {
            return layout
          }
        }
        throw MuxError(.connectionLost)
      }
      #expect(remaining.panes.first?.id == parent)
      await connection.close()
    } cleanup: {
      await retire(harness.service)
    }
  }

  @Test
  func shellCompletionAndDirectoryHooksReachTheNativeSubscriber() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    let config = try JavaScriptConfiguration.provision(at: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    try """
    swiftty.events.onCommandFinished((command, code) => swiftty.ui.notify(command, String(code)));
    swiftty.events.onDirectoryChanged(path => swiftty.ui.setBadge(path));
    """
    .write(to: config, atomically: true, encoding: .utf8)
    var configuration = MuxServiceConfiguration(
      launcherPath: try launcherPath()
    )
    configuration.javaScriptDirectory = directory
    let harness = try Harness(configuration: configuration)
    try await RuntimeFixture.withCleanup {
      let connection = try await harness.connect()
      let program = #"""
        import os
        os.write(1,b'\x1b]7;file://localhost/tmp\x07\x1b]133;A\x07$ \x1b]133;B\x07false\r\n\x1b]133;C\x07\x1b]133;D;1\x07')
        """#
      let request = NewWorkspaceRequest(
        launch: LaunchSpec(command: ["/usr/bin/python3", "-c", program]),
        remainOnExit: true
      )
      _ = try await connection.execute(.newWorkspace(request))
      _ = try await connection.execute(.subscribeAutomation(true))
      let notification = try await automationEvent(
        connection,
        kind: .notification
      )
      #expect(notification.title == "false")
      #expect(notification.text == "1")
      #expect(
        try await automationEvent(connection, kind: .badge).text == "/tmp"
      )
      await connection.close()
    } cleanup: {
      await retire(harness.service)
    }
  }
}

extension JavaScriptPaneTests {
  @Test
  func lifecycleEventsFollowTheWorkspaceGraph() async throws {
    let javascript = JavaScriptRuntime()
    try javascript.evaluate(
      """
      const log = [];
      const hooks = ['ClientConnected', 'WorkspaceCreated', 'TabCreated',
        'PaneCreated', 'ActiveTabChanged', 'ProcessExited', 'PaneClosed',
        'TabClosed', 'WorkspaceClosed', 'ClientDisconnected'];
      for (const hook of hooks) {
        swiftty.events['on' + hook]((...args) => {
          let pane = '';
          if (hook === 'PaneCreated' || hook === 'ProcessExited') {
            pane = '@' + (swiftty.currentPane.id === (args[0]?.paneId ?? exited) ? 'source' : 'other');
          }
          log.push(hook + pane + (hook === 'ProcessExited' ? ':' + args[0] : ''));
        });
      }
      let exited = '';
      swiftty.events.onPaneCreated(e => { exited = e.paneId; });
      swiftty.filter.onStdout(s => s === '\\u0001log' ? log.join(',') : s);
      """
    )
    var configuration = MuxServiceConfiguration(
      launcherPath: try launcherPath()
    )
    configuration.javaScriptRuntime = javascript
    let harness = try Harness(configuration: configuration)
    func log() -> String {
      String(
        decoding: javascript.filter(Data("\u{1}log".utf8), stream: .stdout),
        as: UTF8.self
      )
    }
    func waitFor(_ suffix: String) async throws {
      let deadline = ContinuousClock.now + .seconds(5)
      while !log().hasSuffix(suffix), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
    }
    try await RuntimeFixture.withCleanup {
      let connection = try await harness.connect(.control)
      let request = NewWorkspaceRequest(
        launch: LaunchSpec(command: ["/bin/sh", "-c", "read x; exit 3"])
      )
      guard
        case let .created(workspace) = try await connection.execute(
          .newWorkspace(request)
        )
      else {
        Issue.record("Missing workspace")
        return
      }
      try await waitFor("ActiveTabChanged")
      #expect(
        log()
          == "ClientConnected,WorkspaceCreated,TabCreated,PaneCreated@source,ActiveTabChanged"
      )
      let pane = try #require(
        await harness.service.runtime(workspace.tabs[0].activePane)
      )
      try #require(pane.reserve(1))
      pane.write(.text("\n"), estimate: 1)
      try await waitFor("WorkspaceClosed")
      #expect(
        log()
          .hasSuffix(
            "ProcessExited@source:3,PaneClosed,TabClosed,WorkspaceClosed"
          )
      )
      await connection.close()
      try await waitFor("ClientDisconnected")
      #expect(log().hasSuffix("WorkspaceClosed,ClientDisconnected"))
    } cleanup: {
      await retire(harness.service)
    }
  }
}

extension JavaScriptPaneTests {
  /// A script runtime whose `log` is read back through a stdout filter.
  private func recordingRuntime(_ hooks: [String]) throws -> JavaScriptRuntime {
    let javascript = JavaScriptRuntime()
    let names = hooks.map { "'\($0)'" }.joined(separator: ",")
    try javascript.evaluate(
      """
      const log = [];
      for (const hook of [\(names)]) {
        swiftty.events['on' + hook]((...args) => log.push(hook + ':' + JSON.stringify(args)));
      }
      swiftty.filter.onStdout(s => s === '\\u0001log' ? log.join('\\n') : s);
      """
    )
    return javascript
  }

  private func log(_ javascript: JavaScriptRuntime) -> [String] {
    String(
      decoding: javascript.filter(Data("\u{1}log".utf8), stream: .stdout),
      as: UTF8.self
    )
    .split(separator: "\n").map(String.init)
  }

  private func waitFor(
    _ javascript: JavaScriptRuntime,
    _ predicate: ([String]) -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate(log(javascript)), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  @Test
  func foregroundChangesFollowExecWithoutOutput() async throws {
    let javascript = try recordingRuntime(["ForegroundProcessChanged"])
    var configuration = MuxServiceConfiguration(
      launcherPath: try launcherPath()
    )
    configuration.javaScriptRuntime = javascript
    let harness = try Harness(configuration: configuration)
    try await RuntimeFixture.withCleanup {
      let connection = try await harness.connect(.control)
      let request = NewWorkspaceRequest(
        launch: LaunchSpec(command: [
          "/bin/sh", "-c", "echo ready; read x; exec /bin/sleep 2",
        ])
      )
      guard
        case let .created(workspace) = try await connection.execute(
          .newWorkspace(request)
        )
      else {
        Issue.record("Missing workspace")
        return
      }
      try await waitFor(javascript) { !$0.isEmpty }
      let first = log(javascript)
      #expect(first.count == 1)
      #expect(first.first?.contains(#""generation":"1""#) == true)
      // At a prompt the pane's own program is the foreground.
      #expect(first.first?.contains(#""ancestors":[]"#) == true)
      #expect(first.first?.contains(#""name":"bash""#) == true)
      let pane = try #require(
        await harness.service.runtime(workspace.tabs[0].activePane)
      )
      try #require(pane.reserve(1))
      pane.write(.text("\n"), estimate: 1)
      // The echo is the last output: only the trailing read can see exec.
      try await waitFor(javascript) { $0.count >= 2 }
      let second = try #require(log(javascript).dropFirst().first)
      #expect(second.contains(#""name":"sleep""#))
      #expect(second.contains(#""generation":"2""#))
      await connection.close()
    } cleanup: {
      await retire(harness.service)
    }
  }

  @Test
  func admissionAndRoamingStateReachScripts() async throws {
    let javascript = try recordingRuntime([
      "AdmissionChanged", "ClientConnectionChanged",
    ])
    var configuration = MuxServiceConfiguration(
      launcherPath: try launcherPath()
    )
    configuration.javaScriptRuntime = javascript
    let harness = try Harness(configuration: configuration)
    let workspace = WorkspaceID()
    harness.service.roamingSessionChanged(
      "session",
      workspace: workspace,
      state: "detached"
    )
    try await waitFor(javascript) { $0.count == 1 }
    await retire(harness.service)
    try await waitFor(javascript) { $0.count == 2 }
    #expect(
      log(javascript) == [
        #"ClientConnectionChanged:[{"sessionId":"session","state":"detached","workspaceId":"\#(workspace)"}]"#,
        #"AdmissionChanged:[{"accepting":false,"reason":"update"}]"#,
      ]
    )
  }

  @Test
  func tailscaleAddressesAreRecognizedByRange() {
    func check(_ text: String, family: Int32) -> String? {
      if family == AF_INET {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        inet_pton(AF_INET, text, &address.sin_addr)
        return withUnsafeMutablePointer(to: &address) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            AutomationMonitors.tailscaleAddress($0)
          }
        }
      }
      var address = sockaddr_in6()
      address.sin6_family = sa_family_t(AF_INET6)
      inet_pton(AF_INET6, text, &address.sin6_addr)
      return withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          AutomationMonitors.tailscaleAddress($0)
        }
      }
    }
    #expect(check("100.101.2.3", family: AF_INET) == "100.101.2.3")
    #expect(check("100.128.0.1", family: AF_INET) == nil)
    #expect(check("192.168.1.8", family: AF_INET) == nil)
    #expect(check("fd7a:115c:a1e0::1", family: AF_INET6) == "fd7a:115c:a1e0::1")
    #expect(check("fd00::1", family: AF_INET6) == nil)
  }

  @Test
  func configurationDigestTracksContents() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".jsonc"
    )
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(AutomationMonitors.digest(url) == "")
    try Data("{}".utf8).write(to: url)
    let first = AutomationMonitors.digest(url)
    #expect(first.count == 64)
    try Data("{ }".utf8).write(to: url)
    #expect(AutomationMonitors.digest(url) != first)
  }
}
