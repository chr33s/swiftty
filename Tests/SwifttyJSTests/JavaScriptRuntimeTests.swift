import Foundation
import Testing
import Synchronization
@testable import SwifttyJS

@Suite
struct JavaScriptRuntimeTests {
  @Test
  func configurationPreservesUserFilesAndRefreshesTypes() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = try JavaScriptConfiguration.provision(at: directory)
    #expect(
      try String(contentsOf: config, encoding: .utf8).contains("/// <reference")
    )
    try Data("custom script".utf8).write(to: config)
    let project = directory.appendingPathComponent("jsconfig.json")
    try Data("custom project".utf8).write(to: project)
    let types = directory.appendingPathComponent("swiftty.d.ts")
    try Data("old declarations".utf8).write(to: types)
    _ = try JavaScriptConfiguration.provision(at: directory)
    #expect(try String(contentsOf: config, encoding: .utf8) == "custom script")
    #expect(
      try String(contentsOf: project, encoding: .utf8) == "custom project"
    )
    #expect(
      try String(contentsOf: types, encoding: .utf8).contains("declare global")
    )
  }

  @Test
  func filtersPreserveBytesAndRecoverAfterExceptions() throws {
    let runtime = JavaScriptRuntime(environment: [:])
    try runtime.evaluate(
      "swiftty.filter.onStdout(s => s.replace('secret', '[hidden]'))"
    )
    #expect(
      runtime.filter(Data("a secret".utf8), stream: .stdout)
        == Data("a [hidden]".utf8)
    )
    let binary = Data([0xFF, 0xE2, 0x82])
    #expect(runtime.filter(binary, stream: .stdout) == binary)
    for body in ["null", "undefined", "42", "(() => { throw Error('bad') })()"]
    {
      try runtime.evaluate("swiftty.filter.onStdin(() => \(body))")
      #expect(
        runtime.filter(Data("input".utf8), stream: .stdin) == Data("input".utf8)
      )
    }
    try runtime.evaluate("swiftty.filter.onStdin(() => '')")
    #expect(runtime.filter(Data("input".utf8), stream: .stdin).isEmpty)
  }

  @Test
  func eventsEnvironmentAndKeys() throws {
    let runtime = JavaScriptRuntime(environment: ["FOO": "bar"])
    try runtime.evaluate(
      """
      let observed = [];
      swiftty.events.onCommandFinished(() => { throw Error('isolated'); });
      swiftty.events.onCommandFinished((cmd, code) => observed.push(cmd + ':' + code));
      swiftty.events.onDirectoryChanged(path => observed.push(path));
      swiftty.events.bindKey('cmd+shift+d', () => observed.push(swiftty.env('FOO')));
      swiftty.filter.onStdout(() => observed.join('|') + swiftty.env('MISSING', '!'));
      """
    )
    runtime.commandFinished(command: "false", exitCode: 1)
    runtime.directoryChanged("/tmp")
    #expect(runtime.handleKey("SHIFT + D + CMD"))
    #expect(!runtime.handleKey("cmd+x"))
    #expect(
      runtime.filter(Data(), stream: .stdout) == Data("false:1|/tmp|bar!".utf8)
    )
    #expect(throws: JavaScriptRuntime.ScriptError.self) {
      try runtime.evaluate("throw Error('configuration failure')")
    }
  }
}

private final class ActionRecorder: Sendable {
  let values = Synchronization.Mutex<[JavaScriptAction]>([])
  func append(_ action: JavaScriptAction) {
    values.withLock { $0.append(action) }
  }
  func take() -> [JavaScriptAction] {
    values.withLock {
      let result = $0;
      $0.removeAll();
      return result
    }
  }
}

extension JavaScriptRuntimeTests {
  @Test(arguments: [JavaScriptRuntime.Stream.stdin, .stdout])
  func filterReplacementLimitCountsUTF8Bytes(
    stream: JavaScriptRuntime.Stream
  ) throws {
    let runtime = JavaScriptRuntime()
    let method = stream == .stdin ? "onStdin" : "onStdout"
    try runtime.evaluate("swiftty.filter.\(method)(() => '🧪🧪')")
    let original = Data("original".utf8)
    #expect(
      runtime.filter(original, stream: stream, maximumBytes: 7) == original
    )
    #expect(
      runtime.filter(original, stream: stream, maximumBytes: 8)
        == Data("🧪🧪".utf8)
    )
    try runtime.evaluate("swiftty.filter.\(method)(() => 'x'.repeat(65537))")
    #expect(
      runtime.filter(original, stream: stream, maximumBytes: 65536) == original
    )
    // Rejection must leave the VM usable for subsequent chunks.
    try runtime.evaluate("swiftty.filter.\(method)(() => 'ok')")
    #expect(
      runtime.filter(original, stream: stream, maximumBytes: 8)
        == Data("ok".utf8)
    )
  }

  @Test
  func pollingStopsWhenRuntimeIsReleased() async throws {
    let actions = ActionRecorder()
    var runtime: JavaScriptRuntime? = JavaScriptRuntime(onAction: {
      actions.append($0)
    })
    weak let observed = runtime
    try runtime?
      .evaluate(
        """
        swiftty.ui.registerStatusItem('timer', {
          align: 'left', refreshInterval: 0.05, render: () => 'tick'
        });
        """
      )
    _ = actions.take()
    runtime?.startPolling()
    runtime?.startPolling()
    let deadline = ContinuousClock.now + .seconds(2)
    var ticked = false
    while !ticked && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
      ticked = actions.take().contains { $0.kind == .status }
    }
    try #require(ticked)
    runtime = nil
    let releaseDeadline = ContinuousClock.now + .seconds(2)
    while observed != nil && ContinuousClock.now < releaseDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(observed == nil)
    _ = actions.take()
    try await Task.sleep(for: .milliseconds(250))
    #expect(actions.take().isEmpty)
  }

  @Test
  func backgroundCallbacksRestoreFocusedPaneEvenOnFailure() throws {
    let actions = ActionRecorder()
    let runtime = JavaScriptRuntime(onAction: { actions.append($0) })
    runtime.setActivePane("focused")
    try runtime.evaluate(
      """
      swiftty.filter.onStdout(() => {
        swiftty.currentPane.write('background');
        throw Error('failed filter');
      });
      """
    )
    #expect(
      runtime.filter(
        Data("unchanged".utf8),
        stream: .stdout,
        pane: "background"
      ) == Data("unchanged".utf8)
    )
    try runtime.evaluate("swiftty.currentPane.write('foreground')")
    let recorded = actions.take()
    #expect(
      recorded.filter { $0.kind == .write }.map(\.pane) == [
        "background", "focused",
      ]
    )
    #expect(
      recorded.contains {
        $0.kind == .error && $0.text?.contains("failed filter") == true
      }
    )
  }

  @Test
  func paneOperationsKeepStableIdentity() throws {
    let actions = ActionRecorder()
    let runtime = JavaScriptRuntime(onAction: { actions.append($0) })
    runtime.setActivePane("original")
    try runtime.evaluate(
      """
      const original = swiftty.currentPane;
      const child = original.split('horizontal');
      child.write('top\\n');
      original.close();
      """
    )
    let recorded = actions.take()
    #expect(recorded.count == 3)
    let split = try #require(recorded.first)
    #expect(split.kind == .split)
    #expect(split.pane == "original")
    #expect(split.direction == "horizontal")
    #expect(recorded[1].pane == split.id)
    #expect(recorded[1].text == "top\n")
    #expect(recorded[2].pane == "original")
    runtime.setActivePane("other")
    try runtime.evaluate(
      "original.write('old'); swiftty.currentPane.write('new')"
    )
    #expect(actions.take().map(\.pane) == ["original", "other"])
  }

  @Test
  func statusReplacementManualRefreshAndColors() throws {
    let actions = ActionRecorder()
    let runtime = JavaScriptRuntime(onAction: { actions.append($0) })
    try runtime.evaluate(
      """
      let count = 0;
      swiftty.ui.registerStatusItem('clock', {align: 'right', refreshInterval: 1,
        render: () => ({text: String(++count), color: {red: 1, green: 0, blue: 0}, backgroundColor: '#123456'})});
      """
    )
    let first = try #require(actions.take().first?.status)
    #expect(first.text == "1")
    #expect(first.color == .components(red: 1, green: 0, blue: 0, alpha: 1))
    #expect(first.backgroundColor == .string("#123456"))
    runtime.refreshStatusItems(at: Date().addingTimeInterval(2))
    #expect(actions.take().first?.status?.text == "2")
    try runtime.evaluate(
      "swiftty.ui.registerStatusItem('clock', {align: 'left', render: () => 'manual'})"
    )
    #expect(actions.take().first?.status?.align == "left")
    runtime.refreshStatusItems(at: Date().addingTimeInterval(10))
    #expect(actions.take().isEmpty)
    try runtime.evaluate("swiftty.ui.refreshStatusItem('clock')")
    #expect(actions.take().first?.status?.text == "manual")
  }

  @Test
  func bundledStarterExecutesEveryAPI() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = try JavaScriptConfiguration.provision(at: directory)
    let actions = ActionRecorder()
    let runtime = JavaScriptRuntime(onAction: { actions.append($0) })
    runtime.setActivePane("pane")
    try runtime.evaluate(
      String(contentsOf: config, encoding: .utf8),
      sourceURL: config
    )
    #expect(actions.take().map(\.kind) == [.status, .keybinding])
    runtime.commandFinished(command: "false", exitCode: 1)
    #expect(actions.take().map(\.kind) == [.badge, .notification])
    #expect(runtime.handleKey("cmd+shift+d"))
    #expect(actions.take().map(\.kind) == [.split, .write])
    #expect(
      runtime.filter(Data("ghp_abcdef".utf8), stream: .stdout)
        == Data("[REDACTED_GH_TOKEN]".utf8)
    )
  }
}

extension JavaScriptRuntimeTests {
  @Test
  func statusRevisionDoesNotLoseUInt64Precision() throws {
    let runtime = JavaScriptRuntime()
    try runtime.evaluate(
      """
      let revision = '';
      swiftty.events.onStatusChanged(change => { if (change.type === 'report') revision = change.record.revision; });
      swiftty.filter.onStdout(() => revision);
      """
    )
    let record = JavaScriptProgramStatus(
      id: "",
      state: "done",
      kind: nil,
      progress: nil,
      app: nil,
      title: nil,
      message: nil,
      revision: String(UInt64.max)
    )
    runtime.statusChanged(
      JavaScriptStatusChange(
        type: .report,
        paneId: "pane",
        terminalEpoch: "epoch",
        record: record
      )
    )
    #expect(
      runtime.filter(Data(), stream: .stdout) == Data(String(UInt64.max).utf8)
    )
  }
}
