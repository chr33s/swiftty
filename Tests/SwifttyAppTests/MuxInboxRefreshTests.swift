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

@MainActor
@Suite(.serialized)
struct MuxInboxRefreshTests {
  @Test
  func releasingInboxReplyServiceClosesItsPeer() async throws {
    var service: InboxReplyService? = InboxReplyService()
    weak let weakService = service
    defer { weakService?.listener.cancel() }
    let connection = try await MuxConnection.connect(
      endpoint: #require(service).listener.endpoint,
      frontend: .native
    )
    try await RuntimeFixture.withCleanup {
      service = nil
      for _ in 0 ..< 100 where weakService != nil {
        try await Task.sleep(for: .milliseconds(10))
      }
      try #require(weakService == nil)
      do {
        #expect(try await connection.nextEvent(timeout: .seconds(1)) == nil)
      } catch let error as MuxError { #expect(error.code == .connectionLost) }
    } cleanup: {
      await connection.close()
    }
  }

  @Test(arguments: [false, true])
  func takeoverLookupHasABoundedWaitWithoutClosingTheCurrentLease(
    _ respond: Bool
  ) async throws {
    _ = NSApplication.shared
    let service = InboxReplyService()
    let connection = try await MuxConnection.connect(
      endpoint: service.listener.endpoint,
      frontend: .native
    )
    let controller = try await MuxWorkspaceController.open(
      .id(service.workspace.id),
      configuration: Configuration(),
      connection: connection
    )
    defer { controller.close() }
    await controller.reloadInbox()
    let item = service.attentionItem(workspace: WorkspaceID())
    service.state.withLock {
      $0.attentionLocation = .init(
        availability: .available,
        item: item,
        workspace: item.workspace,
        pane: item.source.pane,
        leaseHeldElsewhere: true
      )
    }
    var notices: [String] = []
    controller.confirmDestructive = { message in
      notices.append(message);
      return false
    }
    controller.openAttention(item)
    try #require(
      await until { service.state.withLock { $0.workspaceLookup != nil } }
    )
    let (channel, id) = try #require(
      service.state.withLock { $0.workspaceLookup }
    )
    let reply = try SMXCodec.encode(
      ServerMessage.reply(id: id, result: .success(.workspaces([]))),
      limit: 1 << 20
    )
    if respond { channel.send(reply) }
    let deadline = ContinuousClock.now + .seconds(6)
    while notices.isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(
      notices.count == 1,
      "takeover lookup must complete its interactive wait"
    )
    #expect(controller.holdsLease)
    if notices.isEmpty {
      // Retire the old unbounded query without leaving its caller running.
      await controller.detach()
      controller.close()
      return
    }
    let error = respond ? MuxError(.notFound) : MuxError(.connectionLost)
    #expect(controller.inboxMessage == MuxInboxModel.describe(error))
    #expect(notices == [MuxInboxModel.describe(error)])
    if !respond {
      // Caller timeout must retain the on-wire reservation until its reply.
      #expect(await connection.pendingCommandCountForTesting == 1)
      channel.send(reply)
    }
    let retirementDeadline = ContinuousClock.now + .seconds(2)
    while await connection.pendingCommandCountForTesting != 0,
      ContinuousClock.now < retirementDeadline
    { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await connection.pendingCommandCountForTesting == 0)
    #expect(notices.count == 1)
    service.script(revision: 9)
    await controller.reloadInbox()
    #expect(controller.inbox.revision == 9)
    #expect(controller.holdsLease)
    await controller.detach()
  }

  @Test(arguments: [false, true])
  func takeoverLookupDistinguishesUnexpectedReplyFromMissingWorkspace(
    _ unexpected: Bool
  ) async throws {
    _ = NSApplication.shared
    let service = InboxReplyService()
    let connection = try await MuxConnection.connect(
      endpoint: service.listener.endpoint,
      frontend: .native
    )
    let controller = try await MuxWorkspaceController.open(
      .id(service.workspace.id),
      configuration: Configuration(),
      connection: connection
    )
    defer { controller.close() }
    await controller.reloadInbox()
    let item = service.attentionItem(workspace: WorkspaceID())
    service.state.withLock {
      $0.attentionLocation = .init(
        availability: .available,
        item: item,
        workspace: item.workspace,
        pane: item.source.pane,
        leaseHeldElsewhere: true
      )
    }
    var notices: [String] = []
    controller.confirmDestructive = { message in
      notices.append(message);
      return false
    }
    controller.openAttention(item)
    try #require(
      await until { service.state.withLock { $0.workspaceLookup != nil } }
    )
    let (channel, id) = try #require(
      service.state.withLock { $0.workspaceLookup }
    )
    try channel.send(
      SMXCodec.encode(
        ServerMessage.reply(
          id: id,
          result: .success(unexpected ? .ok : .workspaces([]))
        ),
        limit: 1 << 20
      )
    )
    try #require(await until { notices.count == 1 })
    let error =
      unexpected
      ? MuxError(.invalidRequest, "unexpected workspace-list reply")
      : MuxError(.notFound)
    #expect(controller.inboxMessage == MuxInboxModel.describe(error))
    #expect(notices == [MuxInboxModel.describe(error)])
    #expect(controller.holdsLease)
    await controller.detach()
  }

  @Test(arguments: [false, true])
  func workspaceListingRejectsAnUnexpectedReply(_ malformed: Bool) async throws
  {
    let service = InboxReplyService()
    let connection = try await MuxConnection.connect(
      endpoint: service.listener.endpoint,
      frontend: .native
    )
    let query = Task {
      try await MuxWorkspaceController.listWorkspaces(createConnection: {
        connection
      })
    }
    defer { query.cancel() }
    try #require(
      await until { service.state.withLock { $0.workspaceLookup != nil } }
    )
    let (channel, id) = try #require(
      service.state.withLock { $0.workspaceLookup }
    )
    try channel.send(
      SMXCodec.encode(
        ServerMessage.reply(
          id: id,
          result: .success(malformed ? .ok : .workspaces([]))
        ),
        limit: 1 << 20
      )
    )
    switch await query.result {
    case let .success(list):
      #expect(
        !malformed,
        "unexpected reply must not appear to be an empty workspace list"
      )
      #expect(list.isEmpty)
    case let .failure(error):
      #expect(malformed)
      #expect((error as? MuxError)?.code == .invalidRequest)
    }
    #expect(try await connection.nextEvent() == nil)
    #expect(await until { service.state.withLock { $0.closedChannels == 1 } })
  }

  @Test(arguments: [false, true])
  func workspaceListingTimesOutAndClosesItsMetadataChannel(
    _ respond: Bool
  ) async throws {
    let service = InboxReplyService()
    let connection = try await MuxConnection.connect(
      endpoint: service.listener.endpoint,
      frontend: .native
    )
    let finished = Mutex(false)
    let query = Task {
      defer { finished.withLock { $0 = true } }
      return try await MuxWorkspaceController.listWorkspaces(createConnection: {
        connection
      })
    }
    defer { query.cancel() }
    try #require(
      await until { service.state.withLock { $0.workspaceLookup != nil } }
    )
    if respond {
      let (channel, id) = try #require(
        service.state.withLock { $0.workspaceLookup }
      )
      try channel.send(
        SMXCodec.encode(
          ServerMessage.reply(id: id, result: .success(.workspaces([]))),
          limit: 1 << 20
        )
      )
    }
    let deadline = ContinuousClock.now + .seconds(6)
    while !finished.withLock({ $0 }), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let completed = finished.withLock { $0 }
    #expect(
      completed,
      "silent metadata query must retire within the interactive wait budget"
    )
    // Retire the unbounded old implementation without leaving a live query.
    if !completed { query.cancel() }
    switch await query.result {
    case let .success(list):
      if respond {
        #expect(list.isEmpty)
      } else {
        Issue.record("silent service unexpectedly returned a workspace list")
      }
    case let .failure(error):
      if respond {
        Issue.record("prompt workspace reply failed: \(error)")
      } else if completed {
        #expect((error as? MuxError)?.code == .connectionLost)
      }
    }
    #expect(try await connection.nextEvent() == nil)
    #expect(await until { service.state.withLock { $0.closedChannels == 1 } })
  }

  @Test
  func largeUnicodeInputIsDeliveredInBoundedAcknowledgedChunks() async throws {
    _ = NSApplication.shared
    let service = InboxReplyService()
    service.state.withLock { $0.acknowledgeInputs = true }
    let connection = try await MuxConnection.connect(
      endpoint: service.listener.endpoint,
      frontend: .native
    )
    let controller = try await MuxWorkspaceController.open(
      .id(service.workspace.id),
      configuration: Configuration(),
      connection: connection
    )
    defer { controller.close() }
    let text = String(repeating: "👩‍💻", count: 30_000)
    controller.send(.text(text), to: PaneID())
    try #require(
      await until {
        service.state.withLock { state in
          state.inputRecords.reduce(0) { bytes, record in
            if case let .input(.text(chunk)) = record.payload {
              return bytes + chunk.utf8.count
            }
            return bytes
          } == text.utf8.count
        }
      }
    )
    let chunks = service.state.withLock { state in
      state.inputRecords.compactMap { record -> String? in
        if case let .input(.text(chunk)) = record.payload { return chunk }
        return nil
      }
    }
    #expect(chunks.count > 1)
    #expect(
      chunks.allSatisfy {
        $0.utf8.count <= MuxLimits.standard.maxPasteChunkBytes
      }
    )
    #expect(chunks.joined() == text)
    #expect(controller.holdsLease)
    await controller.detach()
  }

  @Test(arguments: [false, true])
  func oversizedInputIsRefusedBeforeTransmission(_ paste: Bool) async throws {
    _ = NSApplication.shared
    let service = InboxReplyService()
    service.state.withLock { $0.acknowledgeInputs = true }
    let connection = try await MuxConnection.connect(
      endpoint: service.listener.endpoint,
      frontend: .native
    )
    let controller = try await MuxWorkspaceController.open(
      .id(service.workspace.id),
      configuration: Configuration(),
      connection: connection
    )
    defer { controller.close() }
    let pane = PaneID()
    let text = String(repeating: "x", count: (paste ? 1 << 20 : 4 << 20) + 1)
    if paste {
      controller.paste(text, to: pane)
    } else {
      controller.send(.text(text), to: pane)
    }
    #expect(controller.window?.subtitle.contains("too large") == true)
    #expect(service.state.withLock { $0.inputRecords.isEmpty })
    controller.send(.text("ok"), to: pane)
    try #require(
      await until {
        service.state.withLock {
          $0.inputRecords.contains { $0.payload == .input(.text("ok")) }
        }
      }
    )
    #expect(controller.holdsLease)
    await controller.detach()
  }

  @Test(arguments: [false, true])
  func stalledInputQueueRejectsOverflowAndPreservesAcceptedInput(
    _ bytes: Bool
  ) async throws {
    _ = NSApplication.shared
    let service = InboxReplyService()
    let connection = try await MuxConnection.connect(
      endpoint: service.listener.endpoint,
      frontend: .native
    )
    let controller = try await MuxWorkspaceController.open(
      .id(service.workspace.id),
      configuration: Configuration(),
      connection: connection
    )
    defer {
      service.acknowledgeHeldInputs();
      controller.close()
    }
    let pane = PaneID()
    let body = bytes ? String(repeating: "b", count: 1 << 20) : "held"
    controller.paste(body, to: pane)
    try #require(
      await until { service.state.withLock { $0.inputRecords.count } >= 2 }
    )
    if bytes {
      for _ in 0 ..< 3 { controller.paste(body, to: pane) }
      controller.paste("overflow", to: pane)
    } else {
      for index in 0 ..< 255 {
        controller.send(.text("queued-\(index)"), to: pane)
      }
      controller.send(.text("overflow"), to: pane)
    }
    #expect(
      await until {
        controller.window?.subtitle.contains("Input buffer is full") == true
      }
    )
    service.acknowledgeHeldInputs()
    try #require(
      await until {
        service.state.withLock { state in
          state.inputRecords.count {
            if bytes, case .pasteEnd = $0.payload { return true }
            if !bytes, case let .input(.text(text)) = $0.payload {
              return text.hasPrefix("queued-")
            }
            return false
          } >= (bytes ? 4 : 255)
        }
      }
    )
    controller.send(.text("recovered"), to: pane)
    try #require(
      await until {
        service.state.withLock {
          $0.inputRecords.contains { $0.payload == .input(.text("recovered")) }
        }
      }
    )
    let records = service.state.withLock { $0.inputRecords }
    #expect(
      !records.contains {
        if case let .pasteChunk(_, text) = $0.payload {
          return text == "overflow"
        }
        return $0.payload == .input(.text("overflow"))
      }
    )
    if bytes {
      #expect(
        records.count {
          if case .pasteBegin = $0.payload { true } else { false }
        } == 4
      )
    } else {
      let accepted = records.compactMap { record -> String? in
        if case let .input(.text(text)) = record.payload,
          text.hasPrefix("queued-")
        {
          return text
        }
        return nil
      }
      #expect(accepted == (0 ..< 255).map { "queued-\($0)" })
    }
    #expect(controller.holdsLease)
    await controller.detach()
  }

  @Test
  func postHandshakeRejectionRetiresEveryWaiter() async throws {
    _ = NSApplication.shared
    let service = InboxReplyService()
    let connection = try await MuxConnection.connect(
      endpoint: service.listener.endpoint,
      frontend: .native
    )
    let controller = try await MuxWorkspaceController.open(
      .id(service.workspace.id),
      configuration: Configuration(),
      connection: connection
    )
    defer {
      service.releaseTab();
      controller.close()
    }
    service.state.withLock { $0.holdNextTab = true }
    var inputFinished = false
    var commandFinished = false
    let input = Task {
      defer { inputFinished = true }
      try await connection.send(.text("key"), to: PaneID())
    }
    let command = Task {
      defer { commandFinished = true }
      return try await connection.execute(.newTab(name: nil, launch: nil))
    }
    defer {
      input.cancel();
      command.cancel()
    }
    try #require(
      await until {
        service.state.withLock {
          !$0.inputRecords.isEmpty && $0.tabReply != nil
        }
      }
    )
    let rejection = MuxError(.invalidRequest, "malformed record")
    service.reject(rejection)
    try #require(await until { !controller.holdsLease })
    #expect(await until { inputFinished && commandFinished })
    await #expect(throws: rejection) {
      _ = try await connection.execute(.listWorkspaces)
    }
    // Ensure a broken implementation also releases its owned tasks.
    await connection.close()
    await #expect(throws: rejection) { try await input.value }
    await #expect(throws: rejection) { _ = try await command.value }
    await controller.detach()
  }

  @Test(arguments: ["reply", "refusal", "timeout"])
  func anOldDetachCannotRetireANewerAttachment(_ outcome: String) async throws {
    _ = NSApplication.shared
    let service = InboxReplyService()
    let connection = try await MuxConnection.connect(
      endpoint: service.listener.endpoint,
      frontend: .native
    )
    let controller = try await MuxWorkspaceController.open(
      .id(service.workspace.id),
      configuration: Configuration(),
      connection: connection
    )
    defer {
      service.releaseDetach();
      controller.close()
    }
    service.state.withLock {
      $0.holdDetach = true;
      $0.acknowledgeInputs = true
    }
    let oldDetach = Task { await connection.detach() }
    defer { oldDetach.cancel() }
    try #require(
      await until { service.state.withLock { $0.detachReply != nil } }
    )
    _ = try await connection.execute(
      .attach(AttachRequest(.id(service.workspace.id)))
    )
    if outcome != "timeout" {
      service.releaseDetach(failure: outcome == "refusal")
    }
    await oldDetach.value
    service.releaseDetach()
    #expect(
      try await connection.paste("new attachment", to: PaneID()) == .completed
    )
    await controller.detach()
  }

  @Test(arguments: [false, true])
  func leaseLossRetiresInputAcknowledgmentsWithoutClosingMetadata(
    _ explicit: Bool
  ) async throws {
    _ = NSApplication.shared
    let service = InboxReplyService()
    let connection = try await MuxConnection.connect(
      endpoint: service.listener.endpoint,
      frontend: .native
    )
    let controller = try await MuxWorkspaceController.open(
      .id(service.workspace.id),
      configuration: Configuration(),
      connection: connection
    )
    defer { controller.close() }
    var inputFinished = false
    var pasteFinished = false
    let pane = PaneID()
    let input = Task {
      defer { inputFinished = true }
      try await connection.send(.text("key"), to: pane)
    }
    let paste = Task {
      defer { pasteFinished = true }
      return try await connection.paste("clipboard", to: pane)
    }
    defer {
      input.cancel();
      paste.cancel()
    }
    try #require(
      await until { service.state.withLock { $0.inputRecords.count } >= 3 }
    )
    if explicit {
      await connection.detach()
    } else {
      service.sendEvent(.detached(reason: "taken over"))
      try #require(await until { !controller.holdsLease })
    }
    #expect(await until { inputFinished && pasteFinished })
    if explicit {
      service.sendEvent(.detached(reason: "detached"))
      try #require(await until { !controller.holdsLease })
    }
    service.script(revision: 7)
    service.sendEvent(
      .inbox(
        .init(
          revision: 7,
          counts: .init(),
          changed: [],
          removed: [],
          resync: true
        )
      )
    )
    #expect(await until { controller.inbox.revision == 7 })
    if inputFinished && pasteFinished {
      service.state.withLock { $0.acknowledgeInputs = true }
      _ = try await connection.execute(
        .attach(AttachRequest(.id(service.workspace.id)))
      )
      #expect(try await connection.paste("fresh", to: pane) == .completed)
    }
    // Close only after checking retirement, so a broken implementation
    // still releases the owned tasks and their continuations.
    await connection.close()
    await #expect { try await input.value } throws: {
      ($0 as? MuxError)?.code == .notAttached
    }
    await #expect { try await paste.value } throws: {
      ($0 as? MuxError)?.code == .notAttached
    }
    await controller.detach()
  }

  @Test
  func stalledCommandQueueRejectsOverflowAndRecovers() async throws {
    _ = NSApplication.shared
    let service = InboxReplyService()
    let connection = try await MuxConnection.connect(
      endpoint: service.listener.endpoint,
      frontend: .native
    )
    let controller = try await MuxWorkspaceController.open(
      .id(service.workspace.id),
      configuration: Configuration(),
      connection: connection
    )
    defer {
      service.releaseTab();
      controller.close()
    }
    service.state.withLock { $0.holdNextTab = true }
    controller.newTab()
    try #require(await until { service.state.withLock { $0.tabReply != nil } })
    for _ in 0 ..< MuxWorkspaceController.maxQueuedCommands {
      controller.newTab()
    }
    var overflowStarted = false
    var overflowFinished = false
    let overflow = Task {
      overflowStarted = true
      defer { overflowFinished = true }
      try await controller.revealAttention(pane: PaneID(), tab: nil)
    }
    defer { overflow.cancel() }
    try #require(await until { overflowStarted })
    #expect(await until { overflowFinished })
    service.releaseTab()
    await #expect { try await overflow.value } throws: {
      ($0 as? MuxError)?.code == .resourceLimit
    }
    try #require(
      await until {
        service.state.withLock { $0.newTabs } == MuxWorkspaceController
          .maxQueuedCommands + 1
      }
    )
    try await controller.revealAttention(pane: PaneID(), tab: nil)
    #expect(controller.holdsLease)
    await controller.detach()
  }

  @Test
  func dividerProposalRetriesAfterCommandQueueOverflow() async throws {
    _ = NSApplication.shared
    let first = PaneID()
    let second = PaneID()
    let tab = TabID()
    let workspace = WorkspaceSnapshot(
      id: WorkspaceID(),
      name: "Split",
      tabs: [
        .init(
          id: tab,
          name: "split",
          layout: .split(
            axis: .leftRight,
            ratio: 0.5,
            first: .pane(first),
            second: .pane(second)
          ),
          activePane: first
        )
      ],
      activeTab: tab,
      panes: [],
      layoutRevision: 1
    )
    let service = InboxReplyService(workspace: workspace)
    let connection = try await MuxConnection.connect(
      endpoint: service.listener.endpoint,
      frontend: .native
    )
    let controller = try await MuxWorkspaceController.open(
      .id(workspace.id),
      configuration: Configuration(),
      connection: connection
    )
    defer {
      service.releaseTab();
      controller.close()
    }
    controller.layoutView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
    try await controller.revealAttention(pane: PaneID(), tab: nil)
    await controller.reloadInbox()
    service.state.withLock { $0.holdNextTab = true }
    controller.newTab()
    try #require(await until { service.state.withLock { $0.tabReply != nil } })
    for _ in 0 ..< MuxWorkspaceController.maxQueuedCommands {
      controller.newTab()
    }
    controller.setRatio(0.3, path: [])
    controller.setRatio(0.7, path: [])
    let latest = try #require(controller.ratio(at: []))
    #expect(service.state.withLock { $0.ratios.isEmpty })
    service.releaseTab()
    try #require(
      await until {
        service.state.withLock {
          $0.newTabs == MuxWorkspaceController.maxQueuedCommands + 1
        }
      }
    )
    #expect(await until { service.state.withLock { $0.ratios == [latest] } })
    controller.setRatio(0.6, path: [])
    let next = try #require(controller.ratio(at: []))
    #expect(
      await until { service.state.withLock { $0.ratios == [latest, next] } }
    )
    await controller.detach()
  }

  @Test
  func geometryRetriesTheLatestResizeAfterCommandQueueOverflow() async throws {
    _ = NSApplication.shared
    let pane = PaneID()
    let tab = TabID()
    let workspace = WorkspaceSnapshot(
      id: WorkspaceID(),
      name: "Resize",
      tabs: [
        .init(id: tab, name: "pane", layout: .pane(pane), activePane: pane)
      ],
      activeTab: tab,
      panes: [.init(id: pane, columns: 80, rows: 24)],
      layoutRevision: 1
    )
    let service = InboxReplyService(workspace: workspace)
    let connection = try await MuxConnection.connect(
      endpoint: service.listener.endpoint,
      frontend: .native
    )
    let controller = try await MuxWorkspaceController.open(
      .id(workspace.id),
      configuration: Configuration(),
      connection: connection
    )
    defer {
      service.releaseTab();
      controller.close()
    }
    let view = try #require(controller.views[pane])
    view.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
    controller.geometryChanged()
    try #require(
      await until { service.state.withLock { !$0.geometry.isEmpty } }
    )
    try await controller.revealAttention(pane: PaneID(), tab: nil)
    service.state.withLock { $0.holdNextTab = true }
    controller.newTab()
    try #require(await until { service.state.withLock { $0.tabReply != nil } })
    let previousCount = service.state.withLock { $0.geometry.count }
    for _ in 0 ..< MuxWorkspaceController.maxQueuedCommands {
      controller.newTab()
    }
    view.frame = NSRect(x: 0, y: 0, width: 500, height: 250)
    controller.geometryChanged()
    await controller.reloadInbox()
    view.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
    controller.geometryChanged()
    await controller.reloadInbox()
    let latest = view.gridSize
    #expect(service.state.withLock { $0.geometry.count } == previousCount)
    service.releaseTab()
    try #require(
      await until {
        service.state.withLock {
          $0.newTabs == MuxWorkspaceController.maxQueuedCommands + 1
        }
      }
    )
    #expect(
      await until {
        service.state.withLock { $0.geometry.count == previousCount + 1 }
      }
    )
    let final = try #require(
      service.state.withLock { $0.geometry.last?.entries.first }
    )
    #expect(final.columns == latest.columns)
    #expect(final.rows == latest.rows)
    controller.geometryChanged()
    await controller.reloadInbox()
    try await controller.revealAttention(pane: PaneID(), tab: nil)
    #expect(service.state.withLock { $0.geometry.count } == previousCount + 1)
    await controller.detach()
  }

  @Test(arguments: [false, true])
  func connectionClosureRetiresTheWorkspaceLease(
    _ deliberate: Bool
  ) async throws {
    _ = NSApplication.shared
    let service = InboxReplyService()
    let connection = try await MuxConnection.connect(
      endpoint: service.listener.endpoint,
      frontend: .native
    )
    let controller = try await MuxWorkspaceController.open(
      .id(service.workspace.id),
      configuration: Configuration(),
      connection: connection
    )
    defer { controller.close() }
    #expect(controller.holdsLease)
    if deliberate {
      await connection.close()
    } else {
      for channel in service.state.withLock({ $0.channels }) {
        channel.cancel()
      }
    }
    #expect(await until { !controller.holdsLease })
    #expect(controller.window?.title.contains("detached") == true)
    await #expect {
      try await controller.revealAttention(pane: PaneID(), tab: nil)
    } throws: { ($0 as? MuxError)?.code == .notAttached }
    await controller.detach()
  }

  @Test
  func leaseLossDropsQueuedCommandsAndKeepsInboxEvents() async throws {
    _ = NSApplication.shared
    let service = InboxReplyService()
    let connection = try await MuxConnection.connect(
      endpoint: service.listener.endpoint,
      frontend: .native
    )
    let controller = try await MuxWorkspaceController.open(
      .id(service.workspace.id),
      configuration: Configuration(),
      connection: connection
    )
    defer {
      service.releaseTab();
      controller.close()
    }
    service.state.withLock { $0.holdNextTab = true }
    controller.newTab()
    try #require(await until { service.state.withLock { $0.tabReply != nil } })
    for _ in 0 ..< 5 { controller.newTab() }
    var waiterStarted = false
    var waiterFinished = false
    let waiting = Task {
      waiterStarted = true
      defer { waiterFinished = true }
      try await controller.revealAttention(pane: PaneID(), tab: nil)
    }
    defer { waiting.cancel() }
    try #require(await until { waiterStarted })
    service.sendEvent(.detached(reason: "taken over"))
    try #require(await until { !controller.holdsLease })
    #expect(await until { waiterFinished })
    service.releaseTab()
    await #expect { try await waiting.value } throws: {
      ($0 as? MuxError)?.code == .notAttached
    }
    #expect(service.state.withLock { $0.newTabs } == 1)
    // Lease loss must leave the metadata subscription running.
    service.script(revision: 7)
    service.sendEvent(
      .inbox(
        .init(
          revision: 7,
          counts: .init(),
          changed: [],
          removed: [],
          resync: true
        )
      )
    )
    #expect(await until { controller.inbox.revision == 7 })
    await controller.detach()
  }

  @Test(arguments: [false, true])
  func leaseLossPreservesDetachedNoticeWhilePaneMetadataArrives(
    _ exited: Bool
  ) async throws {
    _ = NSApplication.shared
    let pane = PaneID()
    let tab = TabID()
    let workspace = WorkspaceSnapshot(
      id: WorkspaceID(),
      name: "Terminal",
      tabs: [.init(id: tab, name: "1", layout: .pane(pane), activePane: pane)],
      activeTab: tab,
      panes: [.init(id: pane, columns: 80, rows: 24, title: "original shell")],
      layoutRevision: 1
    )
    let service = InboxReplyService(workspace: workspace)
    let connection = try await MuxConnection.connect(
      endpoint: service.listener.endpoint,
      frontend: .native
    )
    let controller = try await MuxWorkspaceController.open(
      .id(workspace.id),
      configuration: Configuration(),
      connection: connection
    )
    defer { controller.close() }
    service.sendEvent(.detached(reason: "taken over"))
    try #require(await until { !controller.holdsLease })
    let notice = controller.window?.title
    let label = try #require(controller.tabStrip.buttons.first?.item?.title)
    service.sendEvent(
      exited
        ? .paneExited(pane, status: 0, truncated: false)
        : .title(pane, "late title")
    )
    service.script(revision: 12)
    service.sendEvent(
      .inbox(
        .init(
          revision: 12,
          counts: .init(),
          changed: [],
          removed: [],
          resync: true
        )
      )
    )
    try #require(await until { controller.inbox.revision == 12 })
    #expect(controller.window?.title == notice)
    #expect(controller.tabStrip.buttons.first?.item?.title == label)
    #expect(!controller.holdsLease)
    if exited {
      #expect(controller.workspace?.pane(pane)?.exitStatus == 0)
    } else {
      #expect(controller.title(of: pane) == "late title")
    }
    await controller.detach()
  }

  enum PaneNotice: CaseIterable, Sendable { case activity, bell, exit }

  @Test(arguments: [false, true], PaneNotice.allCases)
  func paneNoticesBelongToTheInteractiveAttachment(
    detached: Bool,
    notice: PaneNotice
  ) async throws {
    _ = NSApplication.shared
    let pane = PaneID()
    let other = PaneID()
    let tab = TabID()
    let otherTab = TabID()
    let workspace = WorkspaceSnapshot(
      id: WorkspaceID(),
      name: "Notices",
      tabs: [
        .init(id: tab, name: "active", layout: .pane(pane), activePane: pane),
        .init(
          id: otherTab,
          name: "other",
          layout: .pane(other),
          activePane: other
        ),
      ],
      activeTab: tab,
      panes: [
        .init(id: pane, columns: 80, rows: 24),
        .init(id: other, columns: 80, rows: 24),
      ],
      layoutRevision: 1
    )
    let service = InboxReplyService(workspace: workspace)
    let connection = try await MuxConnection.connect(
      endpoint: service.listener.endpoint,
      frontend: .native
    )
    let controller = try await MuxWorkspaceController.open(
      .id(workspace.id),
      configuration: Configuration(),
      connection: connection
    )
    defer { controller.close() }
    if detached {
      service.sendEvent(.detached(reason: "taken over"))
      try #require(await until { !controller.holdsLease })
    }
    let subtitle = controller.window?.subtitle
    switch notice {
    case .activity: service.sendEvent(.activity(other))
    case .bell: service.sendEvent(.bell(other))
    case .exit:
      service.sendEvent(.paneExited(other, status: 0, truncated: true))
    }
    service.script(revision: 14)
    service.sendEvent(
      .inbox(
        .init(
          revision: 14,
          counts: .init(),
          changed: [],
          removed: [],
          resync: true
        )
      )
    )
    try #require(await until { controller.inbox.revision == 14 })
    if detached {
      #expect(controller.activity.isEmpty)
      #expect(controller.window?.subtitle == subtitle)
    } else if notice == .exit {
      #expect(controller.window?.subtitle.contains("force-killed") == true)
    } else {
      #expect(controller.activity == [other])
      #expect(controller.tabStrip.buttons.last?.item?.hasActivity == true)
    }
    if notice == .exit {
      #expect(controller.workspace?.pane(other)?.exitStatus == 0)
    }
    await controller.detach()
  }

  func until(_ predicate: @MainActor () -> Bool) async -> Bool {
    for _ in 0 ..< 200 {
      if predicate() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return predicate()
  }
}
