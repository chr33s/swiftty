import Foundation

/// One lifecycle event for `swiftty.events` listeners. Arguments are
/// encoded once, as a JSON array, so only a string crosses into the VM.
/// Program-supplied strings stay plain data.
public struct JavaScriptEvent: Sendable, Equatable {
  /// The listener list in `runtime.js` that receives the event.
  public enum Name: String, Sendable, CaseIterable {
    // Pane events: `currentPane` is the source pane.
    case title, bell, notification, progress, exit, foreground, clipboard
    // Workspace events.
    case workspaceCreated, workspaceClosed, workspaceRenamed, layout
    case tabCreated, tabClosed, tabRenamed, activeTab
    case paneCreated, paneClosed
    case clientAttached, clientDetached, clientConnection
    // Service events.
    case clientConnected, clientDisconnected, clientChanged
    case admission, configuration, hosts, tailscale
  }

  public let name: Name
  /// A JSON array of the listener's arguments.
  public let arguments: String

  init(_ name: Name, _ arguments: [Any]) {
    self.name = name
    let data = try? JSONSerialization.data(
      withJSONObject: arguments,
      options: [.fragmentsAllowed, .sortedKeys]
    )
    self.arguments = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
  }

  public static func titleChanged(_ title: String) -> Self {
    Self(.title, [title])
  }

  public static let bell = Self(.bell, [])

  public static func notification(title: String, body: String) -> Self {
    Self(.notification, [title, body])
  }

  /// OSC 9;4 states, as `TerminalEvent.progress` numbers them.
  public static func progress(state: Int, percent: Int?) -> Self {
    let names = ["removed", "set", "error", "indeterminate", "paused"]
    guard names.indices.contains(state) else { return Self(.progress, []) }
    var value: [String: Any] = ["state": names[state]]
    if let percent { value["percent"] = min(max(percent, 0), 100) }
    return Self(.progress, [value])
  }

  /// Shell-style status, as the guardian reports it: `128 + signal` for
  /// a signal, -1 when it was not collected.
  public static func processExited(exitCode: Int32) -> Self {
    Self(.exit, [Int(exitCode)])
  }

  /// One process in a foreground report.
  public struct Process: Sendable, Equatable {
    public var pid: Int32
    public var name: String
    public var cwd: String?
    public init(pid: Int32, name: String, cwd: String? = nil) {
      self.pid = pid
      self.name = name
      self.cwd = cwd
    }

    var json: [String: Any] {
      var value: [String: Any] = ["pid": Int(pid), "name": name]
      if let cwd { value["cwd"] = cwd }
      return value
    }
  }

  /// `foreground` is nil when no foreground process group can be read.
  /// `ancestors` run from the foreground process's parent up to the
  /// pane's own program.
  public static func foregroundProcessChanged(
    generation: UInt64,
    foreground: Process?,
    ancestors: [Process]
  ) -> Self {
    Self(
      .foreground,
      [
        [
          "generation": String(generation),
          "foreground": foreground?.json ?? NSNull(),
          "ancestors": ancestors.map(\.json),
        ]
      ]
    )
  }

  /// A clipboard write the frontend completed (kitty OSC 5522).
  public static func clipboardWritten(_ text: String) -> Self {
    Self(.clipboard, [text])
  }

  public static func workspaceCreated(workspace: String, name: String) -> Self {
    Self(.workspaceCreated, [["workspaceId": workspace, "name": name]])
  }

  public static func workspaceClosed(workspace: String) -> Self {
    Self(.workspaceClosed, [["workspaceId": workspace]])
  }

  public static func workspaceRenamed(workspace: String, name: String) -> Self {
    Self(.workspaceRenamed, [["workspaceId": workspace, "name": name]])
  }

  /// The revision is a decimal string so JavaScript never rounds it.
  public static func layoutChanged(workspace: String, revision: UInt64) -> Self
  { Self(.layout, [["workspaceId": workspace, "revision": String(revision)]]) }

  public static func tabCreated(
    workspace: String,
    tab: String,
    name: String
  ) -> Self {
    Self(.tabCreated, [["workspaceId": workspace, "tabId": tab, "name": name]])
  }

  public static func tabClosed(workspace: String, tab: String) -> Self {
    Self(.tabClosed, [["workspaceId": workspace, "tabId": tab]])
  }

  public static func tabRenamed(
    workspace: String,
    tab: String,
    name: String
  ) -> Self {
    Self(.tabRenamed, [["workspaceId": workspace, "tabId": tab, "name": name]])
  }

  public static func activeTabChanged(workspace: String, tab: String) -> Self {
    Self(.activeTab, [["workspaceId": workspace, "tabId": tab]])
  }

  public static func paneCreated(
    workspace: String,
    tab: String,
    pane: String
  ) -> Self {
    Self(
      .paneCreated,
      [["workspaceId": workspace, "tabId": tab, "paneId": pane]]
    )
  }

  public static func paneClosed(
    workspace: String,
    tab: String,
    pane: String
  ) -> Self {
    Self(
      .paneClosed,
      [["workspaceId": workspace, "tabId": tab, "paneId": pane]]
    )
  }

  /// `role` is `controller` (the lease holder) or `observer`.
  public static func clientAttached(
    workspace: String,
    client: String,
    role: String,
    frontend: String
  ) -> Self {
    Self(
      .clientAttached,
      [
        [
          "workspaceId": workspace, "clientId": client, "role": role,
          "frontend": frontend,
        ]
      ]
    )
  }

  public static func clientDetached(
    workspace: String,
    client: String,
    role: String
  ) -> Self {
    Self(
      .clientDetached,
      [["workspaceId": workspace, "clientId": client, "role": role]]
    )
  }

  public static func clientConnected(
    client: String,
    frontend: String,
    build: String,
    remote: Bool
  ) -> Self {
    Self(
      .clientConnected,
      [
        [
          "clientId": client, "frontend": frontend, "build": build,
          "remote": remote,
        ]
      ]
    )
  }

  public static func clientDisconnected(client: String) -> Self {
    Self(.clientDisconnected, [["clientId": client]])
  }

  /// A connected client's attachment changed: `workspace` and `role` are
  /// nil when it holds none.
  public static func clientChanged(
    client: String,
    frontend: String,
    build: String,
    remote: Bool,
    workspace: String?,
    role: String?
  ) -> Self {
    Self(
      .clientChanged,
      [
        [
          "clientId": client, "frontend": frontend, "build": build,
          "remote": remote, "workspaceId": workspace as Any? ?? NSNull(),
          "role": role as Any? ?? NSNull(),
        ]
      ]
    )
  }

  /// A roaming device's connection to its session was lost or restored.
  /// The session, unlike the SMX client, survives the connection.
  public static func clientConnectionChanged(
    session: String,
    workspace: String,
    state: String
  ) -> Self {
    Self(
      .clientConnection,
      [["sessionId": session, "workspaceId": workspace, "state": state]]
    )
  }

  /// Whether the service accepts new workspaces, tabs and panes. `reason`
  /// is `update` or `migration` while it does not.
  public static func admissionChanged(accepting: Bool, reason: String?) -> Self
  {
    Self(
      .admission,
      [["accepting": accepting, "reason": reason as Any? ?? NSNull()]]
    )
  }

  /// The settings file's contents changed; `hash` is a SHA-256 hex digest,
  /// empty when the file is missing.
  public static func configurationChanged(
    generation: UInt64,
    hash: String,
    path: String
  ) -> Self {
    Self(
      .configuration,
      [["generation": String(generation), "hash": hash, "path": path]]
    )
  }

  /// Swiftty Macs advertising Connect a Device on the local network.
  public static func hostsChanged(_ hosts: [String], hash: String) -> Self {
    Self(.hosts, [["hosts": hosts.map { ["name": $0] }, "hash": hash]])
  }

  public static func tailscaleStatusChanged(
    running: Bool,
    addresses: [String]
  ) -> Self {
    Self(.tailscale, [["running": running, "addresses": addresses]])
  }
}
