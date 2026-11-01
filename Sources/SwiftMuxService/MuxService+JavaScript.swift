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
    switch action.kind {
    case .write, .split, .close, .tabIcon:
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
      case .close: endPane(pane)
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
