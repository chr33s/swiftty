import Foundation
import SwifttyJS
import Testing

struct JavaScriptEventTests {
  /// Reads the script's `log` through a stdout filter keyed on a marker.
  private func log(_ runtime: JavaScriptRuntime) -> String {
    String(
      decoding: runtime.filter(Data("\u{1}log".utf8), stream: .stdout),
      as: UTF8.self
    )
  }

  private func recorder() throws -> JavaScriptRuntime {
    let runtime = JavaScriptRuntime()
    runtime.setActivePane("focused")
    try runtime.evaluate(
      """
      const log = [];
      const pane = () => { try { return swiftty.currentPane.id; } catch { return '-'; } };
      const record = name => (...args) => log.push(name + '@' + pane() + ':' + JSON.stringify(args));
      for (const method of Object.keys(swiftty.events)) {
        if (method.startsWith('on') && !['onStatusChanged', 'onCommandFinished', 'onDirectoryChanged'].includes(method)) {
          swiftty.events[method](record(method.slice(2)));
        }
      }
      swiftty.filter.onStdout(s => s === '\\u0001log' ? log.join('\\n') : s);
      """
    )
    return runtime
  }

  @Test
  func terminalEventsRunInTheirSourcePane() throws {
    let runtime = try recorder()
    runtime.emit(.titleChanged("vim — notes"), pane: "p1")
    runtime.emit(.bell, pane: "p1")
    runtime.emit(.notification(title: "Build", body: "done"), pane: "p2")
    runtime.emit(.progress(state: 1, percent: 140), pane: "p2")
    runtime.emit(.progress(state: 3, percent: nil), pane: "p2")
    runtime.emit(.progress(state: 9, percent: nil), pane: "p2")
    runtime.emit(.processExited(exitCode: 137), pane: "p3")
    #expect(
      log(runtime).split(separator: "\n") == [
        #"TitleChanged@p1:["vim — notes"]"#, "Bell@p1:[]",
        #"Notification@p2:["Build","done"]"#,
        #"ProgressChanged@p2:[{"percent":100,"state":"set"}]"#,
        #"ProgressChanged@p2:[{"state":"indeterminate"}]"#,
        // An unknown OSC 9;4 state reaches listeners without a payload.
        "ProgressChanged@p2:[]", "ProcessExited@p3:[137]",
      ]
    )
  }

  @Test
  func workspaceEventsKeepTheFocusedPaneExceptPaneCreated() throws {
    let runtime = try recorder()
    runtime.emit(.workspaceCreated(workspace: "w", name: "main"))
    runtime.emit(
      .paneCreated(workspace: "w", tab: "t", pane: "new"),
      pane: "new"
    )
    runtime.emit(.layoutChanged(workspace: "w", revision: .max))
    runtime.emit(
      .clientConnected(
        client: "c",
        frontend: "native",
        build: "b",
        remote: true
      )
    )
    #expect(
      log(runtime).split(separator: "\n") == [
        #"WorkspaceCreated@focused:[{"name":"main","workspaceId":"w"}]"#,
        #"PaneCreated@new:[{"paneId":"new","tabId":"t","workspaceId":"w"}]"#,
        // UInt64 revisions are strings: a JavaScript number would round.
        #"LayoutChanged@focused:[{"revision":"18446744073709551615","workspaceId":"w"}]"#,
        #"ClientConnected@focused:[{"build":"b","clientId":"c","frontend":"native","remote":true}]"#,
      ]
    )
  }

  @Test
  func everyEventNameHasAHook() throws {
    let runtime = try recorder()
    let events: [JavaScriptEvent] = [
      .titleChanged(""), .bell, .notification(title: "", body: ""),
      .progress(state: 0, percent: nil), .processExited(exitCode: 0),
      .workspaceCreated(workspace: "w", name: ""),
      .workspaceClosed(workspace: "w"),
      .workspaceRenamed(workspace: "w", name: ""),
      .layoutChanged(workspace: "w", revision: 1),
      .tabCreated(workspace: "w", tab: "t", name: ""),
      .tabClosed(workspace: "w", tab: "t"),
      .tabRenamed(workspace: "w", tab: "t", name: ""),
      .activeTabChanged(workspace: "w", tab: "t"),
      .paneCreated(workspace: "w", tab: "t", pane: "p"),
      .paneClosed(workspace: "w", tab: "t", pane: "p"),
      .clientAttached(
        workspace: "w",
        client: "c",
        role: "observer",
        frontend: ""
      ), .clientDetached(workspace: "w", client: "c", role: "observer"),
      .clientConnected(client: "c", frontend: "", build: "", remote: false),
      .clientDisconnected(client: "c"),
      .foregroundProcessChanged(generation: 1, foreground: nil, ancestors: []),
      .clipboardWritten(""),
      .clientChanged(
        client: "c",
        frontend: "",
        build: "",
        remote: false,
        workspace: nil,
        role: nil
      ),
      .clientConnectionChanged(session: "s", workspace: "w", state: "detached"),
      .admissionChanged(accepting: false, reason: "update"),
      .configurationChanged(generation: 1, hash: "", path: ""),
      .hostsChanged([], hash: ""),
      .tailscaleStatusChanged(running: false, addresses: []),
    ]
    #expect(Set(events.map(\.name)) == Set(JavaScriptEvent.Name.allCases))
    for event in events { runtime.emit(event) }
    #expect(log(runtime).split(separator: "\n").count == events.count)
  }

  @Test
  func throwingListenersDoNotStopOthers() throws {
    let runtime = JavaScriptRuntime()
    try runtime.evaluate(
      """
      let seen = '';
      swiftty.events.onBell(() => { throw Error('first'); });
      swiftty.events.onBell(() => { seen += 'second'; });
      swiftty.filter.onStdout(() => seen);
      """
    )
    runtime.emit(.bell, pane: "p")
    #expect(runtime.filter(Data(), stream: .stdout) == Data("second".utf8))
  }

  @Test
  func listenersAreVisibleToHostsWithoutEnteringTheVM() throws {
    let runtime = JavaScriptRuntime()
    #expect(!runtime.listens(to: .foreground))
    try runtime.evaluate("swiftty.events.onForegroundProcessChanged(() => {});")
    #expect(runtime.listens(to: .foreground))
    #expect(!runtime.listens(to: .hosts))
  }

  @Test
  func foregroundAndNullablePayloads() throws {
    let runtime = try recorder()
    runtime.emit(
      .foregroundProcessChanged(
        generation: 2,
        foreground: .init(pid: 42, name: "vim", cwd: "/tmp"),
        ancestors: [.init(pid: 7, name: "zsh")]
      ),
      pane: "p"
    )
    runtime.emit(
      .clientChanged(
        client: "c",
        frontend: "native",
        build: "b",
        remote: false,
        workspace: nil,
        role: nil
      )
    )
    #expect(
      log(runtime).split(separator: "\n") == [
        #"ForegroundProcessChanged@p:[{"ancestors":[{"name":"zsh","pid":7}],"foreground":{"cwd":"/tmp","name":"vim","pid":42},"generation":"2"}]"#,
        #"ClientChanged@focused:[{"build":"b","clientId":"c","frontend":"native","remote":false,"role":null,"workspaceId":null}]"#,
      ]
    )
  }
}
