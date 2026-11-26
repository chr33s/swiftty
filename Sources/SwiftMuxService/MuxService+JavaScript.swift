import Foundation
import SwiftMuxProtocol
import SwifttyJS

struct ServiceAutomation {
  var initialized = false
  var runtime: JavaScriptRuntime?
  var subscribers: Set<UUID> = []
  var presentation: [String: Data] = [:]
  var notifications: [Data] = []
  var starting: Set<PaneID> = []
  var pending: [PaneID: [JavaScriptAction]] = [:]
  /// Actions raised while a planned replacement is frozen: replayed after
  /// an abort, retired with the old worker after a release.
  var frozen: [JavaScriptAction] = []
  /// What the last lifecycle diff reported; `nil` until it first runs.
  var topology = AutomationTopology()
  var topologyScheduled = false
  var monitors: AutomationMonitors?
}

/// The workspace, tab, pane and client graph as scripts last saw it.
/// Lifecycle events are the differences between two of these.
struct AutomationTopology {
  struct Space {
    var name: String
    var revision: UInt64
    var tabs: [(id: TabID, name: String)]
    var activeTab: TabID
    var panes: [(id: PaneID, tab: TabID)]
    var attached: [(client: UUID, role: String)]
  }

  var spaces: [(id: WorkspaceID, space: Space)] = []
  var clients: [UUID] = []
  /// Each connected client's attachment, as "workspace role".
  var attachments: [UUID: String] = [:]
  /// Nil while the service accepts new workspaces and panes.
  var refusal: String?
}

extension MuxService {
  func prepareAutomation(initialPane: PaneID, environment: [String: String]) {
    guard !automation.initialized else { return }
    automation.initialized = true
    guard let directory = configuration.javaScriptDirectory else { return }
    do {
      let file = try JavaScriptConfiguration.provision(at: directory)
      let runtime = JavaScriptRuntime(
        environment: ProcessInfo.processInfo.environment.merging(environment) {
          _,
          launch in launch
        },
        configurationDirectory: directory,
        onAction: { [weak self] action in
          self?.onQueue { $0.handleAutomation(action) }
        }
      )
      automation.runtime = runtime
      runtime.setActivePane(initialPane.description)
      try runtime.evaluate(
        String(contentsOf: file, encoding: .utf8),
        sourceURL: file
      )
      runtime.startPolling()
      // What already exists is reported as created, once listeners exist.
      scheduleAutomationTopology()
    } catch { NSLog("Swiftty JavaScript: %@", String(describing: error)) }
  }

  func subscribeAutomation(_ client: UUID, enabled: Bool) {
    if enabled {
      automation.subscribers.insert(client)
      for value in automation.notifications {
        send(.event(.automation(value)), to: client)
      }
      automation.notifications.removeAll()
      for key in automation.presentation.keys.sorted() {
        if let value = automation.presentation[key] {
          send(.event(.automation(value)), to: client)
        }
      }
    } else {
      automation.subscribers.remove(client)
    }
  }

  func automationPaneStarted(_ pane: PaneID, succeeded: Bool) {
    automation.starting.remove(pane)
    let pending = automation.pending.removeValue(forKey: pane) ?? []
    if succeeded { for action in pending { handleAutomation(action) } }
  }

  func handleAutomation(_ action: JavaScriptAction) {
    if migrationFrozen, action.kind != .error {
      if automation.frozen.count < 64 { automation.frozen.append(action) }
      return
    }
    switch action.kind {
    case .write, .split, .close, .float, .dock, .tabIcon, .paneIcon:
      guard let raw = action.pane, let pane = PaneID(raw) else { return }
      if automation.starting.contains(pane) {
        if automation.pending[pane, default: []].count < 64 {
          automation.pending[pane, default: []].append(action)
        }
        return
      }
      guard let record = panes[pane], !record.detachedFromLayout, !quiescing
      else { return }
      switch action.kind {
      case .write:
        guard let text = action.text,
          text.utf8.count <= limits.maxPasteChunkBytes
        else { return }
        let input = MuxInput.text(text)
        let estimate = Self.estimate(input)
        guard record.runtime.reserve(estimate) else {
          NSLog("Swiftty JavaScript: pane input buffer is full")
          return
        }
        record.runtime.write(input, estimate: estimate)
      case .tabIcon:
        guard let (w, t) = locate(pane: pane) else { return }
        var presentation = action
        presentation.id = workspaces[w].tabs[t].id.description
        publishAutomation(presentation)
      case .paneIcon:
        guard (action.text?.utf8.count ?? 0) <= 64 else { return }
        var presentation = action
        presentation.id = pane.description
        publishAutomation(presentation)
      case .close: endPane(pane)
      case .float:
        // No bounds from the script means the standard rectangle.
        let bounds: LayerRect? =
          if let text = action.text, !text.isEmpty {
            try? JSONDecoder().decode(LayerRect.self, from: Data(text.utf8))
          } else { .standard }
        guard let bounds, bounds.isValid else { return }
        floatPane(pane, bounds: bounds, in: record.workspace) { _ in }
      case .dock:
        let beside = action.id.flatMap { $0.isEmpty ? nil : PaneID($0) }
        let axis: SplitAxis =
          action.direction == "horizontal" ? .topBottom : .leftRight
        dockPane(pane, beside: beside, axis: axis, in: record.workspace) { _ in
        }
      case .split:
        guard let raw = action.id, let child = PaneID(raw), panes[child] == nil,
          !automation.starting.contains(child)
        else { return }
        split(
          pane,
          axis: action.direction == "horizontal" ? .topBottom : .leftRight,
          launch: nil,
          in: record.workspace,
          newPaneID: child
        ) { [weak self] result in
          if case let .failure(error) = result {
            self?
              .onQueue { service in
                service.automationPaneStarted(child, succeeded: false)
                NSLog("Swiftty JavaScript split: %@", error.message)
              }
          }
        }
      default: break
      }
    case .error: NSLog("Swiftty JavaScript: %@", action.text ?? "Unknown error")
    default: publishAutomation(action)
    }
  }

  private func publishAutomation(_ action: JavaScriptAction) {
    guard let data = try? JSONEncoder().encode(action), data.count <= 64 << 10
    else { return }
    if action.kind == .notification {
      if let client = automation.subscribers
        .sorted(by: { $0.uuidString < $1.uuidString }).first
      {
        send(.event(.automation(data)), to: client)
      } else if automation.notifications.count < 32 {
        automation.notifications.append(data)
      }
      return
    }
    let key: String?
    switch action.kind {
    case .badge: key = "badge"
    case .tabIcon: key = action.id.map { "icon:" + $0 }
    case .paneIcon: key = action.id.map { "paneIcon:" + $0 }
    case .status: key = action.status.map { "status:" + $0.id }
    case .keybinding: key = action.text.map { "key:" + $0 }
    default: key = nil
    }
    if let key,
      automation.presentation[key] != nil || automation.presentation.count < 512
    {
      automation.presentation[key] = data
    }
    for client in automation.subscribers {
      send(.event(.automation(data)), to: client)
    }
  }
}

// MARK: Lifecycle events

extension MuxService {
  /// The runtime panes use: the service's own, or one the host injected.
  var automationRuntime: JavaScriptRuntime? {
    automation.runtime ?? configuration.javaScriptRuntime
  }

  /// Diffs once per turn, so a change made in several steps (a split, a
  /// teardown) reports its final state.
  func scheduleAutomationTopology() {
    guard automationRuntime != nil, !automation.topologyScheduled else {
      return
    }
    automation.topologyScheduled = true
    onQueue { service in
      service.automation.topologyScheduled = false
      service.emitAutomationTopology()
    }
  }

  var automationTopology: AutomationTopology {
    var result = AutomationTopology()
    result.spaces = workspaces.map { ws in
      var attached: [(UUID, String)] = []
      if let lease = leases[ws.id] {
        attached.append((lease.client, "controller"))
      }
      for viewer in viewers[ws.id] ?? [] {
        attached.append((viewer.client, "observer"))
      }
      return (
        ws.id,
        AutomationTopology.Space(
          name: ws.name,
          revision: ws.layoutRevision,
          tabs: ws.tabs.map { ($0.id, $0.name) },
          activeTab: ws.activeTab,
          panes: ws.tabs.flatMap { tab in tab.panes.map { ($0, tab.id) } },
          attached: attached
        )
      )
    }
    result.clients = clients.values.filter { $0.hello != nil }.map(\.id)
      .sorted { $0.uuidString < $1.uuidString }
    for id in result.clients {
      if let ws = clientLeases[id] {
        result.attachments[id] = ws.description + " controller"
      } else if let ws = clientViewers[id] {
        result.attachments[id] = ws.description + " observer"
      }
    }
    result.refusal = quiescing ? "update" : migrationFrozen ? "migration" : nil
    return result
  }

  /// Reports creations before renames and focus, then removals innermost
  /// first; client connections bracket their attachments.
  func emitAutomationTopology() {
    guard let runtime = automationRuntime else { return }
    startAutomationMonitors(runtime)
    let old = automation.topology
    let new = automationTopology
    automation.topology = new
    var events: [(JavaScriptEvent, PaneID?)] = []
    if old.refusal != new.refusal {
      events.append(
        (
          .admissionChanged(accepting: new.refusal == nil, reason: new.refusal),
          nil
        )
      )
    }
    let oldClients = Set(old.clients)
    for id in new.clients where !oldClients.contains(id) {
      guard let client = clients[id], let hello = client.hello else { continue }
      events.append(
        (
          .clientConnected(
            client: id.uuidString,
            frontend: hello.frontend.rawValue,
            build: hello.build,
            remote: client.remote
          ), nil
        )
      )
    }
    let before = Dictionary(
      old.spaces.map { ($0.id, $0.space) },
      uniquingKeysWith: { a, _ in a }
    )
    let after = Dictionary(
      new.spaces.map { ($0.id, $0.space) },
      uniquingKeysWith: { a, _ in a }
    )
    for (id, space) in new.spaces {
      let w = id.description
      let previous = before[id]
      if previous == nil {
        events.append((.workspaceCreated(workspace: w, name: space.name), nil))
      } else if previous?.name != space.name {
        events.append((.workspaceRenamed(workspace: w, name: space.name), nil))
      }
      let oldTabs = Dictionary(
        (previous?.tabs ?? []).map { ($0.id, $0.name) },
        uniquingKeysWith: { a, _ in a }
      )
      for tab in space.tabs {
        let t = tab.id.description
        if let name = oldTabs[tab.id] {
          if name != tab.name {
            events.append(
              (.tabRenamed(workspace: w, tab: t, name: tab.name), nil)
            )
          }
        } else {
          events.append(
            (.tabCreated(workspace: w, tab: t, name: tab.name), nil)
          )
        }
      }
      let oldPanes = Set((previous?.panes ?? []).map(\.id))
      for pane in space.panes where !oldPanes.contains(pane.id) {
        events.append(
          (
            .paneCreated(
              workspace: w,
              tab: pane.tab.description,
              pane: pane.id.description
            ), pane.id
          )
        )
      }
      if previous?.activeTab != space.activeTab {
        events.append(
          (
            .activeTabChanged(workspace: w, tab: space.activeTab.description),
            nil
          )
        )
      }
      if let previous, previous.revision != space.revision {
        events.append(
          (.layoutChanged(workspace: w, revision: space.revision), nil)
        )
      }
      let oldAttached = Set((previous?.attached ?? []).map(\.client))
      for attachment in space.attached
      where !oldAttached.contains(attachment.client) {
        events.append(
          (
            .clientAttached(
              workspace: w,
              client: attachment.client.uuidString,
              role: attachment.role,
              frontend: clients[attachment.client]?.hello?.frontend.rawValue
                ?? ""
            ), nil
          )
        )
      }
    }
    for (id, space) in old.spaces {
      let w = id.description
      let current = after[id]
      let attached = Set((current?.attached ?? []).map(\.client))
      for attachment in space.attached
      where !attached.contains(attachment.client) {
        events.append(
          (
            .clientDetached(
              workspace: w,
              client: attachment.client.uuidString,
              role: attachment.role
            ), nil
          )
        )
      }
      let panes = Set((current?.panes ?? []).map(\.id))
      for pane in space.panes where !panes.contains(pane.id) {
        events.append(
          (
            .paneClosed(
              workspace: w,
              tab: pane.tab.description,
              pane: pane.id.description
            ), nil
          )
        )
      }
      let tabs = Set((current?.tabs ?? []).map(\.id))
      for tab in space.tabs where !tabs.contains(tab.id) {
        events.append((.tabClosed(workspace: w, tab: tab.id.description), nil))
      }
      if current == nil { events.append((.workspaceClosed(workspace: w), nil)) }
    }
    for id in new.clients
    where oldClients.contains(id) && old.attachments[id] != new.attachments[id]
    {
      guard let client = clients[id], let hello = client.hello else { continue }
      let parts = new.attachments[id]?.split(separator: " ").map(String.init)
      events.append(
        (
          .clientChanged(
            client: id.uuidString,
            frontend: hello.frontend.rawValue,
            build: hello.build,
            remote: client.remote,
            workspace: parts?.first,
            role: parts?.last
          ), nil
        )
      )
    }
    let newClients = Set(new.clients)
    for id in old.clients where !newClients.contains(id) {
      events.append((.clientDisconnected(client: id.uuidString), nil))
    }
    for (event, pane) in events { runtime.emit(event, pane: pane?.description) }
  }
}

extension MuxService {
  /// Starts the monitors behind events a script listens to. Listeners
  /// registered later are picked up at the next topology diff.
  func startAutomationMonitors(_ runtime: JavaScriptRuntime) {
    let wanted = Set(
      [JavaScriptEvent.Name.configuration, .hosts, .tailscale]
        .filter(runtime.listens(to:))
    )
    guard !wanted.isEmpty else { return }
    if automation.monitors == nil {
      automation.monitors = AutomationMonitors(service: self)
    }
    automation.monitors?.start(wanted)
  }

  /// A roaming device's connection to `session` changed. Sessions outlive
  /// connections, so a lost connection can be restored.
  package nonisolated func roamingSessionChanged(
    _ session: String,
    workspace: WorkspaceID,
    state: String
  ) {
    onQueue { service in
      service.automationRuntime?
        .emit(
          .clientConnectionChanged(
            session: session,
            workspace: workspace.description,
            state: state
          )
        )
    }
  }
}
