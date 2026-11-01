import AppKit
import Dispatch
import MuxNavigation
import SwiftMuxClient
import SwiftMuxExport
import SwiftMuxProtocol
@testable import Swiftty
import SwifttyCore
import Synchronization
import Testing
import TestSupport

/// Delays a metadata reply independently of later requests on the same
/// authenticated channel, reproducing overlapping refresh completion.
final class InboxReplyService: Sendable {
  struct State {
    var pages: [InboxQuery.Section: InboxPage] = [:]
    var holdNext = false
    var held: (SMXChannel, ServerMessage)?
    var channels: [SMXChannel] = []
    var holdNextTab = false
    var tabReply: (SMXChannel, ServerMessage)?
    var newTabs = 0
    var tabLaunches: [LaunchSpec?] = []
    var splitLaunches: [LaunchSpec?] = []
    var ratios: [Double] = []
    var geometry: [GeometryBatch] = []
    var attentionRequested = false
    var attentionLocation: AttentionLocation?
    var workspaceLookup: (SMXChannel, UInt64)?
    var workspaceSwitch: (SMXChannel, UInt64)?
    var holdFocus = false
    var focusReply: (SMXChannel, ServerMessage)?
    var holdDetach = false
    var detachRequested = false
    var detachReply: (SMXChannel, ServerMessage)?
    var inputRecords: [InputRecord] = []
    var acknowledgeInputs = false
    var closedChannels = 0
  }
  let epoch = ServerInstanceID()
  let listener: SMXListener
  let state = Mutex(State())
  let workspace: WorkspaceSnapshot

  init(workspace: WorkspaceSnapshot? = nil) {
    self.workspace =
      workspace
      ?? WorkspaceSnapshot(
        id: WorkspaceID(),
        name: "Test",
        tabs: [],
        activeTab: TabID(),
        panes: [],
        layoutRevision: 1
      )
    let queue = DispatchQueue(label: "inbox-reply-service")
    listener = SMXListener(anonymousOn: queue)
    listener.activate(connectionQueue: queue) { [weak self] channel in
      guard let self else {
        channel.cancel();
        return
      }
      self.state.withLock { $0.channels.append(channel) }
      channel.activate { [weak self] event in
        if case .closed = event {
          self?.state.withLock { $0.closedChannels += 1 }
        }
        if case let .message(data) = event { self?.answer(data, on: channel) }
      }
    }
  }

  func script(revision: UInt64, cursor: String? = nil, holdNext: Bool = false) {
    state.withLock {
      $0.pages = Dictionary(
        uniqueKeysWithValues: MuxInboxModel.sections.map { section in
          (
            section,
            InboxPage(
              items: [],
              counts: .init(),
              revision: revision,
              nextCursor: section == .needsYou ? cursor : nil
            )
          )
        }
      )
      $0.holdNext = holdNext
    }
  }
  var holding: Bool { state.withLock { $0.held != nil } }
  func release(failure: Bool = false) {
    let held = state.withLock { s in
      let held = s.held
      s.held = nil
      return held
    }
    if let (channel, reply) = held {
      if failure, case let .reply(id, _) = reply {
        send(
          .reply(
            id: id,
            result: .failure(.init(.invalidRequest, "old cursor"))
          ),
          on: channel
        )
      } else {
        send(reply, on: channel)
      }
    }
  }
  func releaseTab() {
    let held = state.withLock { state in
      let held = state.tabReply
      state.tabReply = nil
      return held
    }
    if let (channel, reply) = held { send(reply, on: channel) }
  }
  func sendEvent(_ event: MuxEvent) {
    for channel in state.withLock({ $0.channels }) {
      send(.event(event), on: channel)
    }
  }
  func releaseFocus() {
    let pending = state.withLock { value in
      defer { value.focusReply = nil }
      return value.focusReply
    }
    if let (channel, reply) = pending { send(reply, on: channel) }
  }
  func failWorkspaceLookup() {
    let pending = state.withLock { value in
      defer { value.workspaceLookup = nil }
      return value.workspaceLookup
    }
    if let (channel, id) = pending {
      send(.reply(id: id, result: .failure(.init(.notFound))), on: channel)
    }
  }

  func failWorkspaceSwitch() {
    let pending = state.withLock { value in
      defer { value.workspaceSwitch = nil }
      return value.workspaceSwitch
    }
    if let (channel, id) = pending {
      send(.reply(id: id, result: .failure(.init(.notFound))), on: channel)
    }
  }

  func attentionItem(workspace target: WorkspaceID? = nil) -> AttentionItem {
    let source = AttentionSource(
      serviceEpoch: epoch,
      pane: PaneID(),
      terminalEpoch: TerminalEpochID(),
      recordPath: "",
      recordIncarnation: 1
    )
    let now = Date()
    return AttentionItem(
      occurrence: OccurrenceID(),
      source: source,
      workspace: target ?? workspace.id,
      tab: nil,
      category: .needsYou,
      resolution: .open,
      status: .init(
        source: source,
        state: .blocked,
        kind: .question,
        updatedAt: now
      ),
      createdAt: now,
      updatedAt: now,
      revision: 1
    )
  }

  func reject(_ error: MuxError) {
    for channel in state.withLock({ $0.channels }) {
      send(.rejected(error), on: channel)
    }
  }
  func acknowledgeHeldInputs() {
    let records = state.withLock {
      $0.acknowledgeInputs = true
      return $0.inputRecords
    }
    for record in records {
      for channel in state.withLock({ $0.channels }) {
        send(.inputAck(sequence: record.sequence, error: nil), on: channel)
      }
    }
  }
  func releaseDetach(failure: Bool = false) {
    let held = state.withLock { state in
      let held = state.detachReply
      state.detachReply = nil
      state.holdDetach = false
      return held
    }
    if let (channel, reply) = held {
      if failure, case let .reply(id, _) = reply {
        send(
          .reply(id: id, result: .failure(.init(.invalidRequest))),
          on: channel
        )
      } else {
        send(reply, on: channel)
      }
    }
  }
  private func answer(_ data: Data, on channel: SMXChannel) {
    guard
      let message = try? SMXCodec.decode(
        ClientMessage.self,
        from: data,
        limit: 1 << 20
      )
    else { return }
    let reply: ServerMessage
    switch message {
    case .hello:
      reply = .welcome(
        .init(
          protocolVersion: SMX.protocolVersion,
          build: SMX.build,
          server: epoch,
          acceptedProfile: nil,
          limits: .standard,
          innerTerm: "xterm-256color"
        )
      )
    case let .input(record):
      let acknowledge = state.withLock {
        $0.inputRecords.append(record)
        return $0.acknowledgeInputs
      }
      guard acknowledge else { return }
      reply = .inputAck(sequence: record.sequence, error: nil)
    case let .request(id, command):
      let result: MuxReply
      switch command {
      case .markSeen:
        let location = state.withLock {
          $0.attentionRequested = true
          return $0.attentionLocation
        }
        guard let location else { return }
        result = .attention(location)
      case .switchWorkspace:
        state.withLock { $0.workspaceSwitch = (channel, id) }
        return
      case .focusPane:
        let held = state.withLock { value in
          guard value.holdFocus else { return false }
          value.holdFocus = false
          value.focusReply = (channel, .reply(id: id, result: .success(.ok)))
          return true
        }
        if held { return }
        result = .ok
      case .listWorkspaces:
        state.withLock { $0.workspaceLookup = (channel, id) }
        return
      case let .setGeometry(batch):
        state.withLock { $0.geometry.append(batch) }
        result = .ok
      case let .setSplitRatio(_, _, ratio):
        state.withLock { $0.ratios.append(ratio) }
        result = .ok
      case let .split(_, _, launch):
        state.withLock { $0.splitLaunches.append(launch) }
        result = .ok
      case let .newTab(_, launch):
        let held = state.withLock { state -> Bool in
          state.newTabs += 1
          state.tabLaunches.append(launch)
          guard state.holdNextTab else { return false }
          state.holdNextTab = false
          state.tabReply = (channel, .reply(id: id, result: .success(.ok)))
          return true
        }
        if held { return }
        result = .ok
      case .detach:
        let held = state.withLock { state in
          state.detachRequested = true
          if state.holdDetach {
            state.detachReply = (channel, .reply(id: id, result: .success(.ok)))
          }
          return state.holdDetach
        }
        if held { return }
        result = .ok
      case .attach:
        result = .attached(attachment: AttachmentID(), workspace: workspace)
      case let .inbox(query):
        let held = state.withLock { state -> (InboxPage, Bool) in
          let page =
            state.pages[query.section]
            ?? .init(items: [], counts: .init(), revision: 0, nextCursor: nil)
          let shouldHold = state.holdNext
          state.holdNext = false
          if shouldHold {
            state.held = (
              channel, .reply(id: id, result: .success(.inbox(page)))
            )
          }
          return (page, shouldHold)
        }
        if held.1 { return }
        result = .inbox(held.0)
      default: result = .ok
      }
      reply = .reply(id: id, result: .success(result))
    default: return
    }
    send(reply, on: channel)
  }
  private func send(_ reply: ServerMessage, on channel: SMXChannel) {
    if let data = try? SMXCodec.encode(reply, limit: 1 << 20) {
      channel.send(data)
    }
  }
  deinit { listener.cancel() }
}
