import Dispatch
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
@testable import SwiftMuxService
import SwifttyJS
import Synchronization
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct JavaScriptStatusTests {
  private func retire(_ service: MuxService) {
    let stopped = DispatchSemaphore(value: 0)
    service.prepareToExit { stopped.signal() }
    #expect(stopped.wait(timeout: .now() + 5) == .success)
  }

  @Test
  func validatedStatusChangesKeepSourceAndEpochThroughClearAndReset()
    async throws
  {
    let received = Mutex<[JavaScriptStatusChange]>([])
    let runtime = JavaScriptRuntime(onAction: { action in
      guard action.kind == .notification, let json = action.text,
        let change = try? JSONDecoder()
          .decode(JavaScriptStatusChange.self, from: Data(json.utf8))
      else { return }
      received.withLock { $0.append(change) }
    })
    try runtime.evaluate(
      """
      swiftty.events.onStatusChanged(() => { throw Error('isolated listener'); });
      swiftty.events.onStatusChanged(change => {
        if (swiftty.currentPane.id !== change.paneId) throw Error('wrong pane');
        swiftty.ui.notify('status', JSON.stringify(change));
      });
      """
    )
    var configuration = MuxServiceConfiguration(
      launcherPath: try launcherPath()
    )
    configuration.javaScriptRuntime = runtime
    let harness = try Harness(configuration: configuration)
    defer { retire(harness.service) }
    let connection = try await harness.connect(.control)
    let program = #"""
      import os,tty
      tty.setraw(0)
      def osc(body): return b'\x1b]7501;' + body + b'\x1b\\'
      data = osc(b'?') + osc(b'state=working:id=bad//id') + osc(b'state=unknown')
      data += osc(b'state=working:msg=' + b'A' * 5000)
      data += osc(b'state=working:id=job:progress=20:app=build:title=QnVpbGQ=')
      data += osc(b'state=blocked:id=job:kind=permission:msg=QXBwcm92ZT8=')
      data += osc(b'state=done:id=job')
      data += osc(b'state=working:id=job/child')
      data += osc(b'state=clear:id=job')
      data += osc(b'state=clear:id=nonexistent')
      data += osc(b'state=error') + b'\x1bc' + osc(b'state=done')
      data += b'STATUS_DONE\r\n'
      os.write(1,data)
      """#
    let request = NewWorkspaceRequest(
      launch: LaunchSpec(command: ["/usr/bin/python3", "-c", program]),
      remainOnExit: true
    )
    guard
      case let .created(workspace) = try await connection.execute(
        .newWorkspace(request)
      )
    else { throw MuxError(.invalidRequest) }
    let pane = workspace.tabs[0].activePane
    let terminal = try #require(await harness.service.runtime(pane))
    let deadline = ContinuousClock.now + .seconds(5)
    while !terminal.screenLines()
      .contains(where: { $0.contains("STATUS_DONE") }),
      ContinuousClock.now < deadline
    { try await Task.sleep(for: .milliseconds(10)) }
    try #require(
      terminal.screenLines().contains(where: { $0.contains("STATUS_DONE") })
    )
    let changes = received.withLock { $0 }
    #expect(
      changes.map(\.type) == [
        .report, .report, .report, .report, .removed, .report, .reset, .report,
      ]
    )
    try #require(changes.count == 8)
    #expect(changes.allSatisfy { $0.paneId == pane.description })
    #expect(changes[0].record?.state == "working")
    #expect(changes[0].record?.title == "Build")
    #expect(changes[0].record?.progress == 20)
    #expect(changes[1].record?.kind == "permission")
    #expect(changes[1].record?.message == "Approve?")
    #expect(changes[1].record?.progress == nil)
    #expect(changes[1].record?.app == nil)
    #expect(changes[2].record?.state == "done")
    #expect(Set(changes[4].ids ?? []) == ["job", "job/child"])
    #expect(changes[0].terminalEpoch == changes[5].terminalEpoch)
    #expect(changes[6].terminalEpoch != changes[5].terminalEpoch)
    #expect(changes[7].terminalEpoch == changes[6].terminalEpoch)
    #expect(changes[7].record?.id == "")
    await connection.close()
  }
}

extension JavaScriptStatusTests {
  @Test(arguments: [false, true])
  func overflowingJournalPublishesAnAuthoritativeSnapshot(
    empty: Bool
  ) async throws {
    let received = Mutex<[JavaScriptStatusChange]>([])
    let runtime = JavaScriptRuntime(onAction: { action in
      guard action.kind == .notification, let json = action.text,
        let change = try? JSONDecoder()
          .decode(JavaScriptStatusChange.self, from: Data(json.utf8))
      else { return }
      received.withLock { $0.append(change) }
    })
    try runtime.evaluate(
      """
      swiftty.events.onStatusChanged(change => swiftty.ui.notify('status', JSON.stringify(change)));
      swiftty.filter.onStdout(chunk => {
        if (!chunk.includes('FLOOD')) return;
        const osc = body => '\\x1b]7501;' + body + '\\x1b\\\\';
        return osc('state=working').repeat(4200) + '\\x1bc' +
          osc('state=error:id=final') + \(empty ? "osc('state=clear')" : "''") + 'STATUS_DONE';
      });
      """
    )
    var configuration = MuxServiceConfiguration(
      launcherPath: try launcherPath()
    )
    configuration.javaScriptRuntime = runtime
    configuration.limits.readTurnBytes = 1 << 20
    let harness = try Harness(configuration: configuration)
    defer { retire(harness.service) }
    let connection = try await harness.connect(.control)
    let launch = LaunchSpec(command: [
      "/usr/bin/python3", "-c",
      "import os,tty; tty.setraw(0); os.write(1,b'FLOOD')",
    ])
    guard
      case let .created(workspace) = try await connection.execute(
        .newWorkspace(NewWorkspaceRequest(launch: launch, remainOnExit: true))
      )
    else { throw MuxError(.invalidRequest) }
    let terminal = try #require(
      await harness.service.runtime(workspace.tabs[0].activePane)
    )
    let deadline = ContinuousClock.now + .seconds(5)
    while !terminal.screenLines()
      .contains(where: { $0.contains("STATUS_DONE") }),
      ContinuousClock.now < deadline
    { try await Task.sleep(for: .milliseconds(10)) }
    try #require(
      terminal.screenLines().contains(where: { $0.contains("STATUS_DONE") })
    )
    let changes = received.withLock { $0 }
    #expect(changes.map(\.type) == [.reset, .sync])
    try #require(changes.count == 2)
    #expect(changes[0].terminalEpoch == changes[1].terminalEpoch)
    #expect(changes[1].records?.map(\.id) == (empty ? [] : ["final"]))
    if !empty { #expect(changes[1].records?.first?.state == "error") }
    await connection.close()
  }
}

extension JavaScriptStatusTests {
  @Test
  func evictionPromptAndExitReportExactRemovedIDs() async throws {
    let received = Mutex<[JavaScriptStatusChange]>([])
    let runtime = JavaScriptRuntime(onAction: { action in
      guard action.kind == .notification, let json = action.text,
        let change = try? JSONDecoder()
          .decode(JavaScriptStatusChange.self, from: Data(json.utf8))
      else { return }
      received.withLock { $0.append(change) }
    })
    try runtime.evaluate(
      "swiftty.events.onStatusChanged(change => swiftty.ui.notify('status', JSON.stringify(change)))"
    )
    var configuration = MuxServiceConfiguration(
      launcherPath: try launcherPath()
    )
    configuration.javaScriptRuntime = runtime
    let harness = try Harness(configuration: configuration)
    defer { retire(harness.service) }
    let connection = try await harness.connect(.control)
    let program = #"""
      import os,tty
      tty.setraw(0)
      def osc(body): return b'\x1b]7501;' + body + b'\x1b\\'
      data = b''.join(osc(b'state=done:id=item' + str(i).encode()) for i in range(64))
      data += osc(b'state=working:id=item64') + osc(b'state=blocked:id=item65:kind=question')
      data += b'\x1b]133;A\x07' + osc(b'state=working')
      os.write(1,data)
      """#
    let request = NewWorkspaceRequest(
      launch: LaunchSpec(command: ["/usr/bin/python3", "-c", program]),
      remainOnExit: true
    )
    guard
      case let .created(workspace) = try await connection.execute(
        .newWorkspace(request)
      )
    else { throw MuxError(.invalidRequest) }
    let pane = workspace.tabs[0].activePane
    let deadline = ContinuousClock.now + .seconds(5)
    while await harness.service.snapshot(workspace.id)?.pane(pane)?.exitStatus
      == nil, ContinuousClock.now < deadline
    { try await Task.sleep(for: .milliseconds(10)) }
    try #require(
      await harness.service.snapshot(workspace.id)?.pane(pane)?.exitStatus
        != nil
    )
    let changes = received.withLock { $0 }
    #expect(changes.filter { $0.type == .report }.count == 67)
    let removals = changes.filter { $0.type == .removed }
      .map { Set($0.ids ?? []) }
    #expect(
      removals == [
        Set(["item0"]), Set(["item1"]), Set(["item64", "item65"]), Set([""]),
      ]
    )
    #expect(Set(changes.map(\.terminalEpoch)).count == 1)
    await connection.close()
  }
}
