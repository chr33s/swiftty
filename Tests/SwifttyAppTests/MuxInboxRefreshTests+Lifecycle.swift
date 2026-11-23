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

extension MuxInboxRefreshTests {
  @Test
  func closingAWindowDiscardsItsPendingInboxActionFailure() async throws {
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
    let item = service.attentionItem()
    var alerts = 0
    controller.confirmDestructive = { _ in
      alerts += 1;
      return false
    }
    controller.openAttention(item)
    try #require(
      await until { service.state.withLock { $0.attentionRequested } }
    )
    #expect(controller.inboxMessage == nil)
    await controller.detach()
    controller.close()
    // The transport retires the on-wire wait; allow its main-actor error
    // callback to run before checking that the closed window stays quiet.
    try await Task.sleep(for: .milliseconds(200))
    #expect(alerts == 0)
    #expect(controller.inboxMessage == nil)
    #expect(await connection.pendingCommandCountForTesting == 0)
  }

  @Test(arguments: [false, true])
  func takeoverLookupErrorsBelongOnlyToAnOpenWindow(
    _ closing: Bool
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
    var alerts = 0
    controller.confirmDestructive = { _ in
      alerts += 1;
      return false
    }
    controller.openAttention(item)
    try #require(
      await until { service.state.withLock { $0.workspaceLookup != nil } }
    )
    #expect(controller.inboxMessage == nil)
    if closing {
      await controller.detach()
      controller.close()
      try await Task.sleep(for: .milliseconds(200))
      #expect(alerts == 0)
      #expect(controller.inboxMessage == nil)
    } else {
      service.failWorkspaceLookup()
      #expect(await until { alerts == 1 })
      #expect(controller.inboxMessage != nil)
      await controller.detach()
    }
  }

  @Test(arguments: [false, true])
  func retiredCommandErrorsDoNotShowUIButStillCompleteWaiters(
    _ closing: Bool
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
        leaseHeldElsewhere: false
      )
    }
    var alerts = 0
    controller.confirmDestructive = { _ in
      alerts += 1;
      return false
    }
    controller.openAttention(item)
    try #require(
      await until { service.state.withLock { $0.workspaceSwitch != nil } }
    )
    var started = false
    var finished = false
    let waiter = Task {
      started = true
      defer { finished = true }
      try await controller.revealAttention(pane: PaneID(), tab: nil)
    }
    defer { waiter.cancel() }
    try #require(await until { started })
    if closing {
      await controller.detach()
      controller.close()
      #expect(await until { finished })
      await #expect { try await waiter.value } throws: {
        ($0 as? MuxError)?.code == .notAttached
      }
      try await Task.sleep(for: .milliseconds(100))
      #expect(alerts == 0)
      #expect(controller.inboxMessage == nil)
    } else {
      service.failWorkspaceSwitch()
      #expect(await until { alerts == 1 && finished })
      try await waiter.value
      #expect(controller.inboxMessage != nil)
      await controller.detach()
    }
  }

  @Test(arguments: [false, true], [false, true])
  func successfulReplyCannotRevealARetiredWindow(
    closing: Bool,
    throughStatic: Bool
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
      service.releaseFocus();
      controller.close()
    }
    await controller.reloadInbox()
    service.state.withLock { $0.holdFocus = true }
    var finished = false
    var connects = 0
    let pane = PaneID()
    let reveal = Task {
      defer { finished = true }
      if throughStatic {
        _ = try await MuxWorkspaceController.reveal(
          PaneTarget(workspace: service.workspace.id, tab: nil, pane: pane),
          in: controller,
          configuration: Configuration(),
          connect: {
            connects += 1
            throw MuxError(.connectionLost, "fallback connector probe")
          }
        )
      } else {
        try await controller.revealAttention(pane: pane, tab: nil)
      }
    }
    defer { reveal.cancel() }
    try #require(
      await until { service.state.withLock { $0.focusReply != nil } }
    )
    service.releaseFocus()
    // Block the main actor until a later wire reply is consumed. The
    // focus success is already delivered, but its UI completion cannot run.
    let consumed = DispatchSemaphore(value: 0)
    let succeeded = Mutex(false)
    connection.enqueue(.status) { result in
      if case .success = result { succeeded.withLock { $0 = true } }
      consumed.signal()
    }
    func consumeReply() -> Bool {
      consumed.wait(timeout: .now() + 2) == .success
    }
    try #require(consumeReply())
    try #require(succeeded.withLock { $0 })
    if closing {
      controller.close()
    } else {
      controller.handle(.detached(reason: "taken over"))
    }
    try #require(await until { finished })
    if throughStatic, closing {
      await #expect(throws: CancellationError.self) { try await reveal.value }
    } else {
      let code: MuxError.Code = throughStatic ? .connectionLost : .notAttached
      await #expect { try await reveal.value } throws: {
        ($0 as? MuxError)?.code == code
      }
    }
    #expect(connects == (throughStatic && !closing ? 1 : 0))
    #expect(controller.window?.isVisible == false)
    await controller.detach()
  }

  @Test
  func leaseLossFreezesWorkspaceLayoutWhileInboxUpdatesContinue() async throws {
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
    service.sendEvent(.detached(reason: "taken over"))
    try #require(await until { !controller.holdsLease })
    let previous = try #require(controller.workspace)
    let title = controller.window?.title
    var late = previous
    late.name = "late workspace"
    late.layoutRevision += 1
    service.sendEvent(.layout(late))
    // Subsequent metadata is a wire-order barrier for the stale layout.
    service.script(revision: 11)
    service.sendEvent(
      .inbox(
        .init(
          revision: 11,
          counts: .init(),
          changed: [],
          removed: [],
          resync: true
        )
      )
    )
    try #require(await until { controller.inbox.revision == 11 })
    #expect(controller.workspace == previous)
    #expect(controller.window?.title == title)
    #expect(!controller.holdsLease)
    await controller.detach()
  }

  @Test(.enabled(if: MuxNativeTests.hasMetal))
  func leaseLossDoesNotRestoreAPresentationFromALateFrame() async throws {
    _ = NSApplication.shared
    let pane = PaneID()
    let tab = TabID()
    let workspace = WorkspaceSnapshot(
      id: WorkspaceID(),
      name: "Frames",
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
    defer { controller.close() }
    controller.showWindow(nil)
    let view = try #require(controller.views[pane])
    let attachment = try #require(await connection.attachment)
    let session = TerminalSession(columns: 80, rows: 24)
    session.feed(Array("before detach".utf8))
    var frame = try FrameExporter.frame(
      from: session.withState { $0.captureOwnedScreen() },
      identity: .init(
        server: service.epoch,
        attachment: attachment,
        pane: pane,
        revision: 1,
        layoutRevision: 1,
        geometryGeneration: 0,
        viewportRevision: 0
      )
    )
    service.sendEvent(.frame(frame))
    try #require(
      await until {
        view.draw(in: view)
        return view.presented?.frame.identity.revision == 1
      }
    )
    service.sendEvent(.detached(reason: "taken over"))
    try #require(await until { !controller.holdsLease })
    // The last frame stays (dimmed, under the control bar); a late one
    // from the retired attachment never replaces it.
    #expect(view.presented?.frame.identity.revision == 1)
    frame.identity.revision = 2
    service.sendEvent(.frame(frame))
    service.script(revision: 13)
    service.sendEvent(
      .inbox(
        .init(
          revision: 13,
          counts: .init(),
          changed: [],
          removed: [],
          resync: true
        )
      )
    )
    try #require(await until { controller.inbox.revision == 13 })
    view.draw(in: view)
    #expect(view.presented?.frame.identity.revision == 1)
    #expect(
      (view.accessibilityValue() as? String)?.contains("before detach") == true
    )
    await controller.detach()
  }

  @Test(.enabled(if: MuxNativeTests.hasMetal), arguments: [false, true])
  func framesMustBelongToTheWindowsAttachment(_ stale: Bool) async throws {
    _ = NSApplication.shared
    let pane = PaneID()
    let tab = TabID()
    let workspace = WorkspaceSnapshot(
      id: WorkspaceID(),
      name: "Frame lease",
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
    defer { controller.close() }
    controller.showWindow(nil)
    let view = try #require(controller.views[pane])
    let attachment = try #require(await connection.attachment)
    let session = TerminalSession(columns: 80, rows: 24)
    session.feed(Array("valid attachment".utf8))
    var frame = try FrameExporter.frame(
      from: session.withState { $0.captureOwnedScreen() },
      identity: .init(
        server: service.epoch,
        attachment: attachment,
        pane: pane,
        revision: 1,
        layoutRevision: 1,
        geometryGeneration: 0,
        viewportRevision: 0
      )
    )
    service.sendEvent(.frame(frame))
    try #require(
      await until {
        view.draw(in: view)
        return view.presented?.frame.identity.revision == 1
      }
    )
    frame.identity.attachment = stale ? AttachmentID() : attachment
    frame.identity.revision = stale ? 100 : 2
    service.sendEvent(.frame(frame))
    service.script(revision: 15)
    service.sendEvent(
      .inbox(
        .init(
          revision: 15,
          counts: .init(),
          changed: [],
          removed: [],
          resync: true
        )
      )
    )
    try #require(await until { controller.inbox.revision == 15 })
    // Inbox delivery does not order the asynchronous frame presentation.
    #expect(
      await until {
        view.draw(in: view)
        return view.presented?.frame.identity.revision == (stale ? 1 : 2)
      }
    )
    frame.identity.attachment = attachment
    frame.identity.revision = 3
    service.sendEvent(.frame(frame))
    #expect(
      await until {
        view.draw(in: view)
        return view.presented?.frame.identity.revision == 3
      }
    )
    await controller.detach()
  }

  @Test
  func detachDropsCommandsThatHaveNotBeenDispatched() async throws {
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
    service.state.withLock {
      $0.holdNextTab = true
      $0.holdDetach = true
    }
    controller.newTab()
    try #require(await until { service.state.withLock { $0.tabReply != nil } })
    for _ in 0 ..< 5 { controller.newTab() }
    var waiterStarted = false
    let waiting = Task {
      waiterStarted = true
      try await controller.revealAttention(pane: PaneID(), tab: nil)
    }
    defer { waiting.cancel() }
    try #require(await until { waiterStarted })
    let detaching = Task { await controller.detach() }
    defer { detaching.cancel() }
    try #require(await until { service.state.withLock { $0.detachRequested } })
    // Complete the already-dispatched command while detach is still
    // awaiting its independent reply. Buffered commands must stay unsent.
    service.releaseTab()
    await detaching.value
    #expect(service.state.withLock { $0.newTabs } == 1)
    await #expect { try await waiting.value } throws: {
      ($0 as? MuxError)?.code == .notAttached
    }
  }

  @Test(arguments: [false, true], [false, true])
  func supersededMetadataReadsCannotReplaceTheCurrentCursor(
    loadMore: Bool,
    failure: Bool
  ) async throws {
    _ = NSApplication.shared
    let service = InboxReplyService()
    service.script(revision: 1, cursor: "initial")
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
      service.release();
      controller.close()
    }
    controller.confirmDestructive = { _ in true }
    #expect(await until { controller.inbox.revision == 1 })
    service.script(revision: 1, cursor: "old", holdNext: true)
    let old = Task {
      if loadMore {
        await controller.loadMoreInbox()
      } else {
        await controller.reloadInbox()
      }
    }
    #expect(await until { service.holding })
    // Same revision: pages alone cannot order repeated read operations.
    service.script(revision: 1, cursor: "current")
    await controller.reloadInbox()
    #expect(controller.inbox.cursors[.needsYou] == "current")
    service.release(failure: failure)
    await old.value
    #expect(controller.inbox.cursors[.needsYou] == "current")
    #expect(controller.inboxMessage == nil)
    await controller.detach()
  }

}
