import Foundation
import MuxAttention
import SwiftMuxClient
import SwiftMuxProtocol
@testable import SwiftMuxService
import Testing

/// The OSC 7501 attention inbox through the service (spec.inbox.md §3;
/// acceptance 12, 14, 15, 18, 21).
@Suite(.serialized, .timeLimit(.minutes(1)))
struct InboxTests {
  /// One OSC 7501 report for `printf` (BEL-terminated).
  static func osc(_ body: String) -> String { "\\033]7501;\(body)\\007" }

  /// A pane running `script` under `/bin/sh -c`, no lease taken.
  private func create(
    _ c: MuxConnection,
    _ script: String,
    remainOnExit: Bool = false
  ) async throws -> WorkspaceSnapshot {
    var launch = shellLaunch()
    launch.command = ["/bin/sh", "-c", script]
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(
          NewWorkspaceRequest(launch: launch, remainOnExit: remainOnExit)
        )
      )
    else { throw MuxError(.invalidRequest, "create") }
    return ws
  }

  private func page(
    _ c: MuxConnection,
    _ section: InboxQuery.Section = .all
  ) async throws -> InboxPage {
    guard
      case let .inbox(page) = try await c.execute(
        .inbox(InboxQuery(section: section))
      )
    else { throw MuxError(.invalidRequest, "inbox reply") }
    return page
  }

  private func poll(
    _ c: MuxConnection,
    timeout: Duration = .seconds(10),
    until predicate: (InboxPage) -> Bool
  ) async throws -> InboxPage {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      let p = try await page(c)
      if predicate(p) { return p }
      try await Task.sleep(for: .milliseconds(20))
    }
    throw MuxError(.notFound, "timed out waiting for the inbox")
  }

  private func locate(
    _ c: MuxConnection,
    _ command: MuxCommand
  ) async throws -> AttentionLocation {
    guard case let .attention(location) = try await c.execute(command) else {
      throw MuxError(.invalidRequest, "attention reply")
    }
    return location
  }

  private func ref(_ item: AttentionItem) -> AttentionReference {
    AttentionReference(source: item.source, occurrence: item.occurrence)
  }

  @Test
  func snoozeReplacementClearingAndExpiryNotifySubscribersWithoutLease()
    async throws
  {
    let h = try Harness()
    let c = try await h.connect(.control)
    do {
      _ = try await create(
        c,
        "printf '\(Self.osc("state=blocked:kind=question"))'; exec sleep 30"
      )
      let item = try #require(
        try await poll(c) { !$0.items.isEmpty }.items.first
      )
      let reference = ref(item)
      for index in 0 ..< 32 {
        let until = Date().addingTimeInterval(Double(86400 + index))
        let location = try await locate(c, .snooze(reference, until: until))
        #expect(location.item?.snoozedUntil == until)
      }
      guard
        case let .inbox(snapshot) = try await c.execute(.subscribeInbox(true))
      else { throw MuxError(.invalidRequest, "subscribe reply") }
      #expect(snapshot.counts.needsYou == 0)
      _ = try await locate(c, .snooze(reference, until: nil))
      _ = try await updates(c) { received in
        received.contains { update in
          update.counts.needsYou == 1
            && update.changed.contains {
              $0.occurrence == item.occurrence && $0.snoozedUntil == nil
            }
        }
      }
      let until = Date().addingTimeInterval(0.2)
      let snoozed = try await locate(c, .snooze(reference, until: until))
      let revision = try #require(snoozed.item?.revision)
      _ = try await updates(c) { received in
        received.contains { update in
          update.counts.needsYou == 0
            && update.changed.contains {
              $0.occurrence == item.occurrence && $0.snoozedUntil == until
            }
        }
      }
      // No query or metadata command triggers this final update.
      _ = try await updates(c) { received in
        received.contains { update in
          update.counts.needsYou == 1
            && update.changed.contains {
              $0.source == item.source && $0.occurrence == item.occurrence
                && $0.snoozedUntil == nil && $0.revision > revision
            }
        }
      }
      guard
        case let .workspaces(workspaces) = try await c.execute(.listWorkspaces)
      else { throw MuxError(.invalidRequest, "workspaces reply") }
      #expect(workspaces.allSatisfy { !$0.isAttached })
    } catch {
      _ = try? await c.execute(.endAllWorkspaces)
      await c.close()
      throw error
    }
    try await c.execute(.endAllWorkspaces)
    await c.close()
  }

  @Test
  func successiveSnoozeExpiriesRearmAndNotifyEachExactOccurrence() async throws
  {
    let h = try Harness()
    let c = try await h.connect(.control)
    do {
      let reports =
        Self.osc("state=blocked:id=first:kind=question")
        + Self.osc("state=blocked:id=second:kind=question")
      _ = try await create(c, "printf '\(reports)'; exec sleep 30")
      let items = try await poll(c) { $0.items.count == 2 }.items
      let first = try #require(items.first { $0.source.recordPath == "first" })
      let second = try #require(
        items.first { $0.source.recordPath == "second" }
      )
      let now = Date()
      _ = try await locate(
        c,
        .snooze(ref(first), until: now.addingTimeInterval(0.5))
      )
      _ = try await locate(
        c,
        .snooze(ref(second), until: now.addingTimeInterval(1.0))
      )
      _ = try await c.execute(.subscribeInbox(true))
      _ = try await updates(c) { received in
        received.contains { update in
          update.counts.needsYou == 1
            && update.changed.contains {
              $0.occurrence == first.occurrence && $0.source == first.source
                && $0.snoozedUntil == nil
            }
        }
      }
      _ = try await updates(c) { received in
        received.contains { update in
          update.counts.needsYou == 2
            && update.changed.contains {
              $0.occurrence == second.occurrence && $0.source == second.source
                && $0.snoozedUntil == nil
            }
        }
      }
    } catch {
      _ = try? await c.execute(.endAllWorkspaces)
      await c.close()
      throw error
    }
    try await c.execute(.endAllWorkspaces)
    await c.close()
  }

  /// Inbox updates until `predicate` holds over all received so far.
  private func updates(
    _ c: MuxConnection,
    timeout: Duration = .seconds(10),
    until predicate: ([InboxUpdate]) -> Bool
  ) async throws -> [InboxUpdate] {
    let deadline = ContinuousClock.now + timeout
    var received: [InboxUpdate] = []
    while ContinuousClock.now < deadline {
      let event = try await withTimeout(deadline - ContinuousClock.now) {
        try await c.nextEvent()
      }
      if case let .inbox(update)? = event {
        received.append(update)
        if predicate(received) { return received }
      }
    }
    throw MuxError(.notFound, "timed out waiting for inbox updates")
  }

  @Test
  func `hidden detached pane reports reach the inbox (acceptance 14)`()
    async throws
  {
    let h = try Harness()
    let first = try await h.connect()
    // "QWxsb3c/" is base64 "Allow?".
    let ws = try await create(
      first,
      "sleep 0.5; printf '\(Self.osc("state=blocked:kind=permission:app=tool:msg=QWxsb3c/"))'; exec sleep 30"
    )
    // Quit the only client before the request is reported.
    await first.close()
    try await Task.sleep(for: .milliseconds(800))

    let second = try await h.connect()
    let p = try await poll(second) { !$0.items.isEmpty }
    let item = p.items[0]
    #expect(item.category == .needsYou)
    #expect(item.resolution == .open)
    #expect(item.status.kind == .permission)
    #expect(item.status.app == "tool")
    #expect(item.status.message == "Allow?")
    #expect(item.workspace == ws.id)
    #expect(item.source.pane == ws.activeTabSnapshot?.activePane)
    #expect(p.counts == InboxCounts(needsYou: 1, results: 0))

    // Reads never take the lease.
    let location = try await locate(second, .locateAttention(ref(item)))
    #expect(location.availability == .available)
    #expect(location.workspace == ws.id)
    #expect(location.tab == ws.activeTab)
    #expect(location.pane == item.source.pane)
    #expect(!location.leaseHeldElsewhere)

    // Opening marks seen, not resolved (acceptance 15).
    let seen = try await locate(second, .markSeen(ref(item)))
    #expect(seen.item?.seen == true)
    #expect(seen.item?.resolution == .open)
    #expect(try await page(second, .needsYou).counts.needsYou == 1)
    guard case let .workspaces(list) = try await second.execute(.listWorkspaces)
    else { throw MuxError(.invalidRequest) }
    #expect(list.first { $0.id == ws.id }?.isAttached == false)

    // A request cannot be reviewed away.
    await #expect(throws: MuxError.self) {
      try await second.execute(.markReviewed(self.ref(item)))
    }
    try await second.execute(.endAllWorkspaces)
  }

  @Test
  func `rapid blocked working blocked is two occurrences (acceptance 12)`()
    async throws
  {
    let h = try Harness()
    let c = try await h.connect()
    _ = try await c.execute(.subscribeInbox(true))
    let script =
      "sleep 0.2; printf '" + Self.osc("state=blocked:kind=question")
      + Self.osc("state=working") + Self.osc("state=blocked:kind=question")
      + "'; exec sleep 30"
    _ = try await create(c, script)
    let received = try await updates(c) { all in
      Set(all.flatMap(\.changed).map(\.occurrence)).count >= 2
    }
    var latest: [OccurrenceID: AttentionItem] = [:]
    for item in received.flatMap(\.changed) { latest[item.occurrence] = item }
    let items = latest.values.sorted { $0.createdAt < $1.createdAt }
    #expect(items.count == 2)
    #expect(
      items.map(\.resolution).sorted { $0.rawValue < $1.rawValue } == [
        .open, .resolved,
      ]
    )
    #expect(received.last?.counts.needsYou == 1)

    // A delayed acknowledgement of the first leaves the second alone.
    let first = try #require(items.first { $0.resolution == .resolved })
    let second = try #require(items.first { $0.resolution == .open })
    let stale = try await locate(c, .markSeen(ref(first)))
    #expect(stale.availability == .stale)
    let current = try await locate(c, .locateAttention(ref(second)))
    #expect(current.availability == .available)
    #expect(current.item?.seen == false)
    try await c.execute(.endAllWorkspaces)
  }

  @Test
  func `locate reports a lease held elsewhere without taking it`() async throws
  {
    let h = try Harness()
    let holder = try await h.connect()
    let ws = try await create(
      holder,
      "sleep 0.2; printf '\(Self.osc("state=blocked:kind=auth"))'; exec sleep 30"
    )
    try await holder.attachAndShow(.id(ws.id))
    let other = try await h.connect()
    let item = try await poll(other) { !$0.items.isEmpty }.items[0]
    let elsewhere = try await locate(other, .locateAttention(ref(item)))
    #expect(elsewhere.leaseHeldElsewhere)
    #expect(elsewhere.availability == .available)
    let own = try await locate(holder, .locateAttention(ref(item)))
    #expect(!own.leaseHeldElsewhere)
    // The holder still has its lease.
    guard case let .workspaces(list) = try await other.execute(.listWorkspaces)
    else { throw MuxError(.invalidRequest) }
    #expect(list.first { $0.id == ws.id }?.isAttached == true)
    try await holder.execute(.endAllWorkspaces)
  }

  @Test
  func `final status is drained before the pane exits`() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let script =
      "printf '" + Self.osc("state=blocked:id=ask:kind=question")
      + Self.osc("state=error:id=build:msg=ZmFpbGVk") + "'; exit 3"
    _ = try await create(c, script)
    let p = try await poll(c) { page in
      page.items.contains { $0.resolution == .paneExited }
        && page.items.contains { $0.category == .needsYou }
    }
    let request = try #require(p.items.first { $0.category == .needsYou })
    let failure = try #require(p.items.first { $0.category == .failure })
    // Exit lifecycle resolved the request; the failure stays unreviewed.
    #expect(request.resolution == .resolved)
    #expect(failure.resolution == .paneExited)
    #expect(failure.status.message == "failed")
    #expect(p.counts.needsYou == 1)
    let location = try await locate(c, .locateAttention(ref(failure)))
    #expect(location.availability == .paneExited)
    let reviewed = try await locate(c, .markReviewed(ref(failure)))
    #expect(reviewed.item?.resolution == .reviewed)
    #expect(try await page(c).counts.needsYou == 0)
  }

  @Test
  func `stale and unknown references`() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let unknown = AttentionReference(
      source: AttentionSource(
        serviceEpoch: ServerInstanceID(),
        pane: PaneID(),
        terminalEpoch: TerminalEpochID(),
        recordPath: "",
        recordIncarnation: 1
      ),
      occurrence: OccurrenceID()
    )
    let missing = try await locate(c, .locateAttention(unknown))
    #expect(missing.availability == .missing)
    #expect(missing.item == nil)
    await #expect(throws: MuxError.self) {
      try await c.execute(.inbox(InboxQuery(cursor: "nope")))
    }
  }

  @Test
  func `a slow subscriber is resynced, not queued without bound`() async throws
  {
    var limits = MuxLimits.standard
    limits.inboxPendingUpdates = 2
    let h = try Harness(limits: limits)
    let slow = try await h.connect()
    _ = try await slow.execute(.subscribeInbox(true))
    // Separate reports, each flushed on its own.
    var script = "sleep 0.2"
    for i in 1 ... 8 {
      script += "; printf '\(Self.osc("state=error:id=e\(i)"))'; sleep 0.1"
    }
    _ = try await create(slow, script + "; exec sleep 30")
    // Do not read until every report has been reduced.
    let control = try await h.connect()
    _ = try await poll(control) { $0.counts.needsYou == 8 }
    try await Task.sleep(for: .milliseconds(100))

    let received = try await updates(slow) { $0.contains(where: \.resync) }
    #expect(received.count == 3)
    #expect(received.filter(\.resync).count == 1)
    #expect(received.last?.resync == true)
    #expect(received.last?.counts.needsYou == 8)
    // Nothing else was queued for it: closing ends the event stream.
    Task {
      try? await Task.sleep(for: .milliseconds(300))
      await slow.close()
    }
    #expect(try await slow.nextEvent() == nil)
    try await control.execute(.endAllWorkspaces)
  }

  @Test
  func `oversized inbox event disconnect frees its subscriber slot`()
    async throws
  {
    var limits = MuxLimits.standard
    limits.maxFrameBytes = 1
    limits.inboxSubscribers = 1
    limits.inboxPageSize = 1
    let h = try Harness(limits: limits)
    let control = try await h.connect()
    let subscriber = try await h.connect()
    var replacement: MuxConnection?
    do {
      let ws = try await create(control, "exec sleep 30")
      let pane = try #require(ws.panes.first).id
      _ = try await subscriber.execute(.subscribeInbox(true))
      // Valid per-record text sizes, but one batch exceeds the server wire
      // limit. Inject a single reduction turn so PTY read timing cannot split it.
      let changes: [StatusChange] = (0 ..< 40)
        .map {
          .report(
            StatusRecord(
              path: "error\($0)",
              state: .error,
              message: String(repeating: "x", count: 2048)
            )
          )
        }
      await withCheckedContinuation { continuation in
        h.service.onQueue { service in
          service.paneEvent(pane, .status(TerminalEpochID(), changes))
          continuation.resume()
        }
      }
      let disconnected = try await withTimeout(.seconds(5)) {
        do {
          while try await subscriber.nextEvent() != nil {}
          return false
        } catch let error as MuxError { return error.code == .connectionLost }
      }
      #expect(disconnected)
      guard case let .status(status) = try await control.execute(.status) else {
        throw MuxError(.invalidRequest, "status reply")
      }
      #expect(status.panes == 1)
      guard
        case let .inbox(page) = try await control.execute(
          .inbox(InboxQuery(limit: 1))
        )
      else { throw MuxError(.invalidRequest, "inbox reply") }
      #expect(page.items.count == 1)
      #expect(page.counts.needsYou == 40)
      // There is only one subscriber slot; reuse proves service-side teardown.
      let next = try await h.connect()
      replacement = next
      _ = try await next.execute(.subscribeInbox(true))
      try await control.execute(.endAllWorkspaces)
      await next.close()
      await subscriber.close()
      await control.close()
    } catch {
      _ = try? await control.execute(.endAllWorkspaces)
      await replacement?.close()
      await subscriber.close()
      await control.close()
      throw error
    }
  }

  @Test
  func `subscribers are bounded`() async throws {
    var limits = MuxLimits.standard
    limits.inboxSubscribers = 1
    let h = try Harness(limits: limits)
    let a = try await h.connect()
    let b = try await h.connect()
    _ = try await a.execute(.subscribeInbox(true))
    await #expect(throws: MuxError.self) {
      try await b.execute(.subscribeInbox(true))
    }
    _ = try await a.execute(.subscribeInbox(false))
    _ = try await b.execute(.subscribeInbox(true))
  }
}
