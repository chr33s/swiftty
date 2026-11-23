import AppKit
import MuxNavigation
import MuxNavigationSMX
import SwiftMuxClient
import SwiftMuxProtocol
@testable import Swiftty
import SwifttyCore
import Testing
import TestSupport

/// The native attention inbox: toolbar badge, popover rows, seen versus
/// resolved, and review of results (spec.inbox.md §3; acceptance 15).
extension MuxNativeTests {
  @Test(arguments: ["reset", "append", "update"])
  func `removal history overflow never resurrects an old occurrence`(
    _ delivery: String
  ) {
    let source = AttentionSource(
      serviceEpoch: ServerInstanceID(),
      pane: PaneID(),
      terminalEpoch: TerminalEpochID(),
      recordPath: "",
      recordIncarnation: 1
    )
    let item = AttentionItem(
      occurrence: OccurrenceID(),
      source: source,
      workspace: WorkspaceID(),
      tab: nil,
      category: .needsYou,
      resolution: .open,
      status: AttentionStatus(
        source: source,
        state: .blocked,
        updatedAt: Date()
      ),
      createdAt: Date(),
      updatedAt: Date(),
      revision: 1
    )
    let old = InboxPage(
      items: [item],
      counts: InboxCounts(needsYou: 1),
      revision: 1,
      nextCursor: "old"
    )
    var model = MuxInboxModel()
    model.reset([.needsYou: old])
    _ = model.apply(
      InboxUpdate(
        revision: 2,
        counts: InboxCounts(),
        changed: [],
        removed: [item.occurrence]
      )
    )
    for index in 0 ..< MuxInboxModel.tombstoneLimit {
      _ = model.apply(
        InboxUpdate(
          revision: UInt64(index + 3),
          counts: InboxCounts(),
          changed: [],
          removed: [OccurrenceID()]
        )
      )
    }
    switch delivery {
    case "reset": model.reset([.needsYou: old])
    case "append": model.append(old, section: .needsYou)
    default:
      _ = model.apply(
        InboxUpdate(
          revision: 1,
          counts: old.counts,
          changed: [item],
          removed: []
        )
      )
    }
    #expect(model.items.isEmpty)
    #expect(model.counts == InboxCounts())
    // A current authoritative page can still adopt the occurrence.
    let fresh = InboxPage(
      items: [item],
      counts: old.counts,
      revision: UInt64(MuxInboxModel.tombstoneLimit + 3),
      nextCursor: nil
    )
    model.reset([.needsYou: fresh])
    #expect(model.items[item.occurrence] == item)
    #expect(model.counts == old.counts)
  }

  static func osc(_ body: String) -> String {
    "printf '\\033]7501;\(body)\\007'\r"
  }

  @Test(.enabled(if: hasMetal))
  func `inbox badge, open marks seen and review clears results`() async throws {
    let f = try await open()
    defer { f.controller.close() }
    let c = f.controller
    let pane = try #require(c.activePane)
    c.send(
      .text(Self.osc("state=blocked:kind=question:app=tool:msg=T2s/")),
      to: pane
    )
    let request = try await waitForRequest(in: c, from: pane)
    #expect(c.workspaceToolbar.item.badge == .count(1))
    #expect(MuxInboxModel.text(request).heading == "Needs an answer: tool")
    #expect(MuxInboxModel.text(request).detail == "Ok?")

    // Opening marks seen; it stays a request (acceptance 15).
    c.openAttention(request)
    #expect(await until { c.inbox.sorted.first?.seen == true })
    #expect(c.inbox.counts.needsYou == 1)
    #expect(c.activePane == pane)

    // The program moving on resolves it; a result is kept for review.
    c.send(.text(Self.osc("state=working")), to: pane)
    c.send(.text(Self.osc("state=done:msg=ZmluaXNoZWQ=")), to: pane)
    #expect(
      await until { c.inbox.counts == InboxCounts(needsYou: 0, results: 1) }
    )
    #expect(c.workspaceToolbar.item.badge == nil)
    c.toggleInbox()
    let result = try #require(c.inbox.sorted.first)
    #expect(result.category == .result)
    c.markReviewed(result)
    #expect(await until { c.inbox.items.isEmpty })
    // Counts arrive with the service's coalesced update, after the item
    // leaves the local list.
    #expect(await until { c.inbox.counts == InboxCounts() })
  }

  @Test
  func `inbox model drops stale deltas and closed items`() {
    let source = AttentionSource(
      serviceEpoch: ServerInstanceID(),
      pane: PaneID(),
      terminalEpoch: TerminalEpochID(),
      recordPath: "",
      recordIncarnation: 1
    )
    let occurrence = OccurrenceID()
    func item(
      _ revision: UInt64,
      _ resolution: AttentionResolution
    ) -> AttentionItem {
      AttentionItem(
        occurrence: occurrence,
        source: source,
        workspace: WorkspaceID(),
        tab: nil,
        category: .needsYou,
        resolution: resolution,
        status: AttentionStatus(
          source: source,
          state: .blocked,
          message: "\u{202E}evil\u{1B}[31m",
          updatedAt: Date()
        ),
        createdAt: Date(),
        updatedAt: Date(),
        revision: revision
      )
    }
    var model = MuxInboxModel()
    let first = model.apply(
      InboxUpdate(
        revision: 2,
        counts: InboxCounts(needsYou: 1),
        changed: [item(2, .open)],
        removed: []
      )
    )
    #expect(!first)
    #expect(model.items.count == 1)
    // Program text is sanitized: no bidi overrides or escapes.
    #expect(MuxInboxModel.text(item(2, .open)).detail == "evil[31m")
    // An older delta never overwrites a newer item.
    _ = model.apply(
      InboxUpdate(
        revision: 1,
        counts: InboxCounts(),
        changed: [item(1, .resolved)],
        removed: []
      )
    )
    #expect(model.items.count == 1)
    #expect(model.counts.needsYou == 1)
    _ = model.apply(
      InboxUpdate(
        revision: 3,
        counts: InboxCounts(),
        changed: [item(3, .resolved)],
        removed: []
      )
    )
    #expect(model.items.isEmpty)
    let resync = model.apply(
      InboxUpdate(
        revision: 4,
        counts: InboxCounts(),
        changed: [],
        removed: [],
        resync: true
      )
    )
    #expect(resync)
  }

  @Test(.enabled(if: hasMetal))
  func `snooze hides a request from the badge until unsnoozed`() async throws {
    let f = try await open()
    defer { f.controller.close() }
    let c = f.controller
    let pane = try #require(c.activePane)
    c.send(.text(Self.osc("state=blocked:kind=permission:app=tool")), to: pane)
    let request = try await waitForRequest(in: c, from: pane)
    #expect(MuxInboxModel.canSnooze(request))
    #expect(MuxInboxModel.snoozeText(request, at: Date()) == nil)

    c.snooze(request, until: Date().addingTimeInterval(3600))
    #expect(
      await until {
        c.inbox.counts.needsYou == 0
          && c.inbox.sorted.first?.snoozedUntil != nil
      }
    )
    #expect(c.workspaceToolbar.item.badge == nil)
    let snoozed = try #require(c.inbox.sorted.first)
    #expect(
      MuxInboxModel.snoozeText(snoozed, at: Date())?.hasPrefix("Snoozed until ")
        == true
    )

    c.snooze(snoozed, until: nil)
    #expect(
      await until {
        c.inbox.counts.needsYou == 1
          && c.inbox.sorted.first?.snoozedUntil == nil
      }
    )
    #expect(c.inboxMessage == nil)
  }

  @Test(.enabled(if: hasMetal))
  func `stale and missing items are reported and the list reread`() async throws
  {
    let f = try await open()
    defer { f.controller.close() }
    let c = f.controller
    var told: [String] = []
    c.confirmDestructive = { message in
      told.append(message)
      return false
    }
    let pane = try #require(c.activePane)
    c.send(.text(Self.osc("state=blocked:kind=question:app=tool")), to: pane)
    let request = try await waitForRequest(in: c, from: pane)
    c.send(.text(Self.osc("state=working")), to: pane)
    #expect(await until { c.inbox.items.isEmpty })

    // A request the program already resolved: stale, never snoozed.
    c.snooze(request, until: Date().addingTimeInterval(900))
    #expect(await until { told.count == 1 })
    #expect(told.first == "The program has already moved on from this request.")
    #expect(c.inboxMessage == told.first)

    // An occurrence the service never had: missing.
    var unknown = request
    unknown.occurrence = OccurrenceID()
    unknown.category = .result
    c.markReviewed(unknown)
    #expect(await until { told.count == 2 })
    #expect(told.last == "This item is no longer available.")

    // Opening it reports the same, without touching any pane.
    c.openAttention(unknown)
    #expect(await until { told.count == 3 })
    #expect(told.last == "This item is no longer available.")
    #expect(c.activePane == pane)

    // While the popover is open, failures appear inline, not as alerts.
    c.toggleInbox()
    let view = try #require(c.inboxView)
    #expect(
      view.messageLabel.stringValue == "This item is no longer available."
    )
    c.snooze(request, until: Date().addingTimeInterval(900))
    #expect(
      await until {
        view.messageLabel.stringValue
          == "The program has already moved on from this request."
      }
    )
    #expect(view.messageLabel.superview != nil)
    #expect(told.count == 3)
    c.toggleInbox()
  }

  @Test(.enabled(if: hasMetal))
  func `load more reads the pages beyond the first`() async throws {
    let f = try await open()
    defer { f.controller.close() }
    let c = f.controller
    c.inboxPageLimit = 2
    let pane = try #require(c.activePane)
    for id in ["a", "b", "c"] {
      c.send(
        .text(Self.osc("id=\(id):state=blocked:kind=question:app=\(id)")),
        to: pane
      )
    }
    #expect(await until { c.inbox.counts.needsYou == 3 })
    // Items held before the reload depend on whether the window's first
    // page load (two rows) ran before or after the reports; the reload
    // below is the deterministic start.
    await c.reloadInbox()
    #expect(c.inbox.items.count == 2)
    #expect(c.inbox.hasMore)
    await c.loadMoreInbox()
    #expect(c.inbox.items.count == 3)
    #expect(!c.inbox.hasMore)
    #expect(c.inboxMessage == nil)
  }

  @Test(.enabled(if: hasMetal))
  func `opening a workspace held elsewhere asks again when control moves`()
    async throws
  {
    try await withFixture { f in
      let c = f.controller
      let other = try await MuxConnection.connect(
        endpoint: f.endpoint,
        frontend: .native
      )
      try await RuntimeFixture.withCleanup {
        let launch = LaunchSpec(
          command: ["/bin/sh"],
          workingDirectory: "/tmp",
          environment: [
            "PATH": "/usr/bin:/bin", "PS1": "$ ",
            "HOME": NSTemporaryDirectory(),
          ]
        )
        guard
          case let .created(created) = try await other.execute(
            .newWorkspace(NewWorkspaceRequest(launch: launch))
          ),
          case let .attached(_, ws) = try await other.execute(
            .attach(AttachRequest(.id(created.id)))
          ), let pane = ws.activeTabSnapshot?.activePane
        else {
          Issue.record("no second workspace")
          return
        }
        await other.post(
          .text(Self.osc("state=blocked:kind=question:app=far")),
          to: pane
        )
        #expect(
          await until { c.inbox.sorted.contains { $0.workspace == ws.id } }
        )
        let item = try #require(c.inbox.sorted.first { $0.workspace == ws.id })

        // The holder reattaches while the user decides: the first takeover
        // is refused as stale and the user is asked again.
        // `other` stands in for another device in use: always asked.
        c.decideTakeControl = { .ask($0.leaseGeneration) }
        var asked: [String] = []
        c.confirmDestructive = { message in
          asked.append(message)
          if asked.count == 1 {
            _ = try? await other.execute(.detach)
            _ = try? await other.execute(.attach(AttachRequest(.id(ws.id))))
          }
          return true
        }
        c.openAttention(item)
        #expect(await until { c.workspace?.id == ws.id })
        #expect(asked.count == 2)
        #expect(asked.first?.hasPrefix("Take control of workspace") == true)
        #expect(asked.last?.contains("changed while you were deciding") == true)
        #expect(await until { c.activePane == pane })
      } cleanup: {
        await other.close()
      }
    }
  }

  @Test
  func `snooze choices, wording and paging cursors`() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let now = try #require(
      calendar.date(
        from: DateComponents(
          year: 2026,
          month: 10,
          day: 10,
          hour: 14,
          minute: 30
        )
      )
    )
    let choices = MuxInboxModel.snoozeChoices(at: now, calendar: calendar)
    #expect(
      choices.map(\.title) == ["15 Minutes", "1 Hour", "Tomorrow at 9:00"]
    )
    #expect(choices[0].until == now.addingTimeInterval(900))
    #expect(choices[1].until == now.addingTimeInterval(3600))
    #expect(
      choices[2].until
        == calendar.date(
          from: DateComponents(year: 2026, month: 10, day: 11, hour: 9)
        )
    )

    #expect(
      MuxInboxModel.describe(MuxError(.staleRevision))
        .contains("changed while you were deciding")
    )
    #expect(
      MuxInboxModel.describe(MuxError(.leaseHeld))
        .hasPrefix("Another window or device controls this workspace.")
    )
    #expect(
      MuxInboxModel.describe(MuxError(.invalidRequest, "inbox cursor"))
        == "SwiftMux refused the request: inbox cursor"
    )
    #expect(MuxInboxModel.describe(.available) == nil)
    #expect(MuxInboxModel.describe(.paneExited) == nil)
    #expect(MuxInboxModel.describe(.stale) != nil)

    let source = AttentionSource(
      serviceEpoch: ServerInstanceID(),
      pane: PaneID(),
      terminalEpoch: TerminalEpochID(),
      recordPath: "",
      recordIncarnation: 1
    )
    func item(snoozed: Date?, created: Date) -> AttentionItem {
      AttentionItem(
        occurrence: OccurrenceID(),
        source: source,
        workspace: WorkspaceID(),
        tab: nil,
        category: .needsYou,
        resolution: .open,
        status: AttentionStatus(
          source: source,
          state: .blocked,
          updatedAt: created
        ),
        createdAt: created,
        updatedAt: created,
        snoozedUntil: snoozed,
        revision: 1
      )
    }
    // The snoozed request is the newer one, yet sorts last.
    let later = item(snoozed: now.addingTimeInterval(3600), created: now)
    let waiting = item(snoozed: nil, created: now.addingTimeInterval(-60))
    #expect(MuxInboxModel.snoozeText(waiting, at: now) == nil)
    #expect(
      MuxInboxModel.snoozeText(later, at: now, calendar: calendar)?
        .hasPrefix("Snoozed until ") == true
    )
    #expect(
      MuxInboxModel.snoozeText(later, at: now.addingTimeInterval(7200)) == nil
    )

    var model = MuxInboxModel()
    model.reset([
      .needsYou: InboxPage(
        items: [later],
        counts: InboxCounts(needsYou: 1),
        revision: 1,
        nextCursor: "next"
      ),
      .results: InboxPage(
        items: [],
        counts: InboxCounts(needsYou: 1),
        revision: 1,
        nextCursor: nil
      ),
    ])
    #expect(model.hasMore)
    #expect(model.cursors == [.needsYou: "next"])
    model.append(
      InboxPage(
        items: [waiting],
        counts: InboxCounts(needsYou: 1),
        revision: 1,
        nextCursor: nil
      ),
      section: .needsYou
    )
    #expect(!model.hasMore)
    #expect(
      model.sorted(at: now).map(\.occurrence) == [
        waiting.occurrence, later.occurrence,
      ]
    )
    model.forget(waiting.occurrence)
    #expect(model.items.count == 1)
  }

  @Test
  func `a page read before a removal never resurrects the item`() {
    let source = AttentionSource(
      serviceEpoch: ServerInstanceID(),
      pane: PaneID(),
      terminalEpoch: TerminalEpochID(),
      recordPath: "",
      recordIncarnation: 1
    )
    func item(
      _ occurrence: OccurrenceID,
      _ revision: UInt64,
      _ resolution: AttentionResolution = .open
    ) -> AttentionItem {
      AttentionItem(
        occurrence: occurrence,
        source: source,
        workspace: WorkspaceID(),
        tab: nil,
        category: .needsYou,
        resolution: resolution,
        status: AttentionStatus(
          source: source,
          state: .blocked,
          updatedAt: Date()
        ),
        createdAt: Date(),
        updatedAt: Date(),
        revision: revision
      )
    }
    func page(_ items: [AttentionItem], at revision: UInt64) -> InboxPage {
      InboxPage(
        items: items,
        counts: InboxCounts(needsYou: items.count),
        revision: revision,
        nextCursor: nil
      )
    }
    let removed = OccurrenceID()
    let resolved = OccurrenceID()
    let kept = OccurrenceID()
    var model = MuxInboxModel()
    _ = model.apply(
      InboxUpdate(
        revision: 2,
        counts: InboxCounts(needsYou: 3),
        changed: [item(removed, 2), item(resolved, 2), item(kept, 2)],
        removed: []
      )
    )
    #expect(model.items.count == 3)
    // Revision 3 removes one item and resolves another…
    _ = model.apply(
      InboxUpdate(
        revision: 3,
        counts: InboxCounts(needsYou: 1),
        changed: [item(resolved, 3, .resolved)],
        removed: [removed]
      )
    )
    #expect(Set(model.items.keys) == [kept])
    // …then pages read at revision 2 arrive: neither comes back.
    let stale = page(
      [item(removed, 2), item(resolved, 2), item(kept, 2)],
      at: 2
    )
    model.reset([.needsYou: stale, .results: page([], at: 2)])
    #expect(Set(model.items.keys) == [kept])
    #expect(model.counts.needsYou == 1)
    model.append(stale, section: .needsYou)
    #expect(Set(model.items.keys) == [kept])
    // An item older than the one held never replaces it.
    _ = model.apply(
      InboxUpdate(
        revision: 4,
        counts: InboxCounts(needsYou: 1),
        changed: [item(kept, 5)],
        removed: []
      )
    )
    model.append(page([item(kept, 4, .resolved)], at: 4), section: .needsYou)
    #expect(model.items[kept]?.revision == 5)
    // A page read after the removal is authoritative again.
    model.reset([.needsYou: page([item(removed, 6)], at: 6)])
    #expect(model.items[removed] != nil)
  }

  @Test(.enabled(if: hasMetal))
  func `a late layout event for the previous workspace is ignored`()
    async throws
  {
    try await withFixture { f in
      let c = f.controller
      let previous = try #require(c.workspace)
      let other = try await MuxConnection.connect(
        endpoint: f.endpoint,
        frontend: .native
      )
      try await RuntimeFixture.withCleanup {
        let launch = LaunchSpec(
          command: ["/bin/sh"],
          workingDirectory: "/tmp",
          environment: [
            "PATH": "/usr/bin:/bin", "PS1": "$ ",
            "HOME": NSTemporaryDirectory(),
          ]
        )
        guard
          case let .created(created) = try await other.execute(
            .newWorkspace(NewWorkspaceRequest(launch: launch))
          ),
          case let .attached(_, ws) = try await other.execute(
            .attach(AttachRequest(.id(created.id)))
          ), let pane = ws.activeTabSnapshot?.activePane
        else {
          Issue.record("no second workspace")
          return
        }
        await other.post(
          .text(Self.osc("state=blocked:kind=question:app=far")),
          to: pane
        )
        #expect(
          await until { c.inbox.sorted.contains { $0.workspace == ws.id } }
        )
        let item = try #require(c.inbox.sorted.first { $0.workspace == ws.id })
        _ = try await other.execute(.detach)
        c.openAttention(item)
        #expect(await until { c.workspace?.id == ws.id })
        #expect(c.attachedWorkspace == ws.id)

        // The previous workspace's layout event lands after the switch.
        var late = previous
        late.layoutRevision += 100
        c.handle(.layout(late))
        #expect(c.workspace?.id == ws.id)
        #expect(c.attachedWorkspace == ws.id)
        // An older layout of the current workspace is not shown either.
        var older = try #require(c.workspace)
        older.layoutRevision -= 1
        older.name = "stale"
        c.handle(.layout(older))
        #expect(c.workspace?.name != "stale")
      } cleanup: {
        await other.close()
      }
    }
  }

  @Test(.enabled(if: hasMetal))
  func `a refused attach keeps the current window and closes its connection`()
    async throws
  {
    try await withFixture { f in
      let c = f.controller
      let other = try await MuxConnection.connect(
        endpoint: f.endpoint,
        frontend: .native
      )
      var ownedReplacement: MuxConnection?
      try await RuntimeFixture.withCleanup {
        guard
          case let .created(created) = try await other.execute(
            .newWorkspace(
              NewWorkspaceRequest(
                launch: LaunchSpec(
                  command: ["/bin/sh"],
                  workingDirectory: "/tmp"
                )
              )
            )
          ),
          case .attached = try await other.execute(
            .attach(AttachRequest(.id(created.id)))
          )
        else {
          Issue.record("no second workspace")
          return
        }
        let connection = try await MuxConnection.connect(
          endpoint: f.endpoint,
          frontend: .native
        )
        ownedReplacement = connection
        // Held elsewhere and no takeover confirmed: refused, nothing left.
        await #expect {
          _ = try await MuxWorkspaceController.replace(
            c,
            with: .id(created.id),
            configuration: Configuration(),
            connection: connection
          )
        } throws: { ($0 as? MuxError)?.code == .leaseHeld }
        #expect(c.workspace?.id == f.workspace)
        #expect(c.window?.isVisible == true)
        // The new connection was closed: its event stream ends at once.
        #expect(await (try? connection.nextEvent()) == nil)
        // The current window still holds its lease and works.
        let pane = try #require(c.activePane)
        c.split(.leftRight)
        #expect(await until { c.workspace?.panes.count == 2 })
        #expect(c.workspace?.pane(pane) != nil)
      } cleanup: {
        await ownedReplacement?.close()
        await other.close()
      }
    }
  }

  /// A window on workspace W with an open request, then detached because
  /// `phone` took W over: the window still shows W but holds no lease.
  struct DetachedFixture {
    let fixture: Fixture
    let phone: MuxConnection
    let item: AttentionItem
    let pane: PaneID
    let host = NavigationHost(id: UUID(), name: "This Mac")
  }

  /// Counts may arrive on a resync before the asynchronous page reload.
  /// Capture the request in the same observation that proves readiness.
  private func waitForRequest(
    in controller: MuxWorkspaceController,
    from pane: PaneID
  ) async throws -> AttentionItem {
    var readyItem: AttentionItem?
    try #require(
      await until {
        readyItem = controller.inbox.sorted.first {
          $0.source.pane == pane && $0.category == .needsYou
        }
        return controller.inbox.counts.needsYou == 1 && readyItem != nil
      }
    )
    return try #require(readyItem)
  }

  func detachedByTakeover() async throws -> DetachedFixture {
    let f = try await open()
    let c = f.controller
    var ownedPhone: MuxConnection?
    do {
      let pane = try #require(c.activePane)
      c.send(.text(Self.osc("state=blocked:kind=question:app=tool")), to: pane)
      let item = try await waitForRequest(in: c, from: pane)
      try #require(c.holdsLease)
      let phone = try await MuxConnection.connect(
        endpoint: f.endpoint,
        frontend: .native
      )
      ownedPhone = phone
      guard
        case let .workspaces(list) = try await phone.execute(.listWorkspaces),
        let summary = list.first(where: { $0.id == f.workspace }),
        case .attached = try await phone.execute(
          .takeover(.id(f.workspace), expectedLease: summary.leaseGeneration)
        )
      else { throw MuxError(.invalidRequest, "no takeover") }
      try #require(await until { !c.holdsLease })
      // Still showing W: the old ownership check matched here.
      try #require(c.workspace?.id == f.workspace)
      try Task.checkCancellation()
      return DetachedFixture(fixture: f, phone: phone, item: item, pane: pane)
    } catch {
      await ownedPhone?.close()
      await retire(f)
      throw error
    }
  }

  func withDetachedFixture(
    _ work: @MainActor (DetachedFixture) async throws -> Void
  ) async throws {
    let d = try await detachedByTakeover()
    try await RuntimeFixture.withCleanup {
      try await work(d)
    } cleanup: {
      await d.phone.close()
      await retire(d.fixture)
    }
  }

  /// The router's opener over `AppDelegate`-style window replacement.
  func navigator(
    _ d: DetachedFixture,
    window: @escaping @MainActor (MuxWorkspaceController) -> Void
  ) -> AttentionNavigator {
    let endpoint = d.fixture.endpoint
    let connect: @Sendable () async throws -> MuxConnection = {
      try await MuxConnection.connect(endpoint: endpoint, frontend: .native)
    }
    var current: MuxWorkspaceController? = d.fixture.controller
    let opener = AttentionLinkRouter.Opener { target, lease in
      let shown = try await MuxWorkspaceController.reveal(
        target,
        in: current,
        configuration: Configuration(),
        connect: { try await connect() },
        takeover: lease
      )
      current = shown
      window(shown)
    }
    return AttentionNavigator(
      configuration: AttentionLinkConfiguration(),
      hosts: StaticHostDirectory([d.host]),
      connector: SMXAttentionConnector(opener: opener, connect: connect)
    )
  }

  func isSeen(
    _ d: DetachedFixture,
    _ destination: AttentionDestination
  ) async throws -> Bool {
    guard
      case let .attention(location) = try await d.phone.execute(
        .locateAttention(destination.reference)
      )
    else { return false }
    return location.item?.seen == true
  }

  @Test(.enabled(if: hasMetal))
  func `a window detached by a takeover does not own its workspace`()
    async throws
  {
    try await withDetachedFixture { d in
      let c = d.fixture.controller
      // Commands without a lease fail rather than only being logged.
      await #expect {
        try await c.revealAttention(pane: d.pane, tab: nil)
      } throws: { ($0 as? MuxError)?.code == .notAttached }
      let preview = AttentionPreview(
        item: d.item,
        target: PaneTarget(
          workspace: d.fixture.workspace,
          tab: nil,
          pane: d.pane
        ),
        leaseHeldElsewhere: true
      )
      #expect(
        AttentionLinkRouter.leaseNote(preview, owned: false)
          == "Another client controls this workspace."
      )
      #expect(AttentionLinkRouter.leaseNote(preview, owned: true) == nil)
    }
  }

  @Test(.enabled(if: hasMetal))
  func `revealing in a detached window offers a takeover, never silently`()
    async throws
  {
    try await withDetachedFixture { d in
      let c = d.fixture.controller
      var shown: MuxWorkspaceController?
      defer { shown?.close() }
      let navigator = navigator(d) { shown = $0 }
      let destination = AttentionDestination(
        hostProfileID: d.host.id,
        item: d.item,
        intent: .reveal
      )
      await navigator.open(destination)
      guard case .ready = navigator.state else {
        Issue.record("not ready: \(navigator.state)")
        return
      }
      await navigator.openInPane()
      // The plain attach is refused: an explicit offer, not `.opened`.
      guard case let .confirmTakeover(offer) = navigator.state else {
        Issue.record("no takeover offer: \(navigator.state)")
        return
      }
      #expect(shown == nil)
      #expect(try await isSeen(d, destination) == false)
      // The phone still controls W and the old window is kept.
      #expect(
        (try? await d.phone.execute(.newTab(name: nil, launch: nil))) != nil
      )
      #expect(c.window?.isVisible == true)
      #expect(!c.holdsLease)

      // Confirmed: the new window takes W over and shows the pane.
      await navigator.confirmTakeover()
      #expect(navigator.state == .opened(offer.preview.target))
      let window = try #require(shown)
      #expect(window !== c)
      #expect(window.holdsLease)
      #expect(window.attachedWorkspace == d.fixture.workspace)
      #expect(await until { window.activePane == d.pane })
      #expect(c.window?.isVisible != true)
      #expect(try await isSeen(d, destination))
    }
  }

  @Test(.enabled(if: hasMetal))
  func `revealing in a detached window reattaches once the lease is free`()
    async throws
  {
    try await withDetachedFixture { d in
      let c = d.fixture.controller
      var shown: MuxWorkspaceController?
      defer { shown?.close() }
      _ = try await d.phone.execute(.detach)
      let navigator = navigator(d) { shown = $0 }
      let destination = AttentionDestination(
        hostProfileID: d.host.id,
        item: d.item,
        intent: .reveal
      )
      await navigator.open(destination)
      await navigator.openInPane()
      guard case .opened = navigator.state else {
        Issue.record("not opened: \(navigator.state)")
        return
      }
      let window = try #require(shown)
      #expect(window !== c)
      #expect(window.holdsLease)
      #expect(await until { window.activePane == d.pane })
      #expect(c.window?.isVisible != true)
    }
  }

  /// The in-window inbox "Open" in a window that lost its lease sends no
  /// commands on that connection: it reattaches like an attention link,
  /// taking over only after confirmation.
  @Test(.enabled(if: hasMetal))
  func `inbox open in a detached window reattaches after confirmation`()
    async throws
  {
    try await withDetachedFixture { d in
      let c = d.fixture.controller
      var shown: MuxWorkspaceController?
      defer { shown?.close() }
      let endpoint = d.fixture.endpoint
      c.connectService = {
        try await MuxConnection.connect(endpoint: endpoint, frontend: .native)
      }
      c.onReplaced = { shown = $0 }
      // The phone stands in for another device in use: always asked.
      c.decideTakeControl = { .ask($0.leaseGeneration) }
      var asked: [String] = []
      var answer = false
      c.confirmDestructive = { message in
        asked.append(message)
        return answer
      }

      // Declined: nothing changes hands.
      c.openAttention(d.item)
      #expect(await until { asked.count == 1 })
      #expect(asked.first?.hasPrefix("Take control of workspace") == true)
      try await Task.sleep(for: .milliseconds(200))
      #expect(shown == nil)
      #expect(c.window?.isVisible == true)
      #expect(
        (try? await d.phone.execute(.newTab(name: nil, launch: nil))) != nil
      )

      // Confirmed: a new window takes the workspace over and shows the pane.
      answer = true
      c.openAttention(d.item)
      #expect(await until { shown != nil })
      let window = try #require(shown)
      #expect(asked.count == 2)
      #expect(window !== c)
      #expect(window.holdsLease)
      #expect(window.attachedWorkspace == d.fixture.workspace)
      #expect(await until { window.activePane == d.pane })
      #expect(c.window?.isVisible != true)
      await #expect {
        try await d.phone.execute(.newTab(name: nil, launch: nil))
      } throws: { ($0 as? MuxError)?.code == .notAttached }
    }
  }
}
