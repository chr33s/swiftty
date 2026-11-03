import Foundation
import MuxAttention
import SwiftMuxProtocol
@testable import SwiftMuxService
import Testing

struct InboxHubTests {
  @Test
  func deliveryTokensFenceStaleSubscriptionsAndDuplicateAcknowledgements()
    throws
  {
    var limits = MuxLimits.standard
    limits.inboxPendingUpdates = 1
    var hub = InboxHub(serviceEpoch: ServerInstanceID(), limits: limits)
    let client = UUID()
    let pane = PaneID()
    let epoch = TerminalEpochID()
    let context = AttentionContext(workspace: WorkspaceID(), tab: nil)
    _ = try hub.subscribe(client, requiresToken: true)
    hub.apply(
      [.report(StatusRecord(path: "a", state: .blocked))],
      pane: pane,
      epoch: epoch,
      context: context
    )
    let old = try #require(hub.flush().first?.1)
    let oldToken = try #require(old.acknowledgementToken)
    hub.unsubscribe(client)
    _ = try hub.subscribe(client, requiresToken: true)
    hub.apply(
      [.report(StatusRecord(path: "b", state: .blocked))],
      pane: pane,
      epoch: epoch,
      context: context
    )
    let current = try #require(hub.flush().first?.1)
    let token = try #require(current.acknowledgementToken)
    #expect(token != oldToken)
    hub.apply(
      [.report(StatusRecord(path: "c", state: .blocked))],
      pane: pane,
      epoch: epoch,
      context: context
    )
    #expect(hub.flush().isEmpty)
    #expect(hub.acknowledge(client) == nil)
    #expect(
      hub.acknowledge(client, revision: old.revision, token: oldToken) == nil
    )
    #expect(
      hub.acknowledge(client, revision: current.revision + 1, token: token)
        == nil
    )
    #expect(hub.subscribers[client]?.unacknowledged == 1)
    #expect(hub.subscribers[client]?.needsResync == true)
    let acknowledged = hub.acknowledge(
      client,
      revision: current.revision,
      token: token
    )
    let resync = try #require(acknowledged)
    let resyncToken = try #require(resync.acknowledgementToken)
    #expect(resync.resync)
    #expect(resyncToken != token)
    #expect(
      hub.acknowledge(client, revision: current.revision, token: token) == nil
    )
    #expect(hub.subscribers[client]?.pendingTokens.count == 1)
    #expect(
      hub.acknowledge(client, revision: resync.revision, token: resyncToken)
        == nil
    )
    #expect(hub.subscribers[client]?.unacknowledged == 0)
    #expect(hub.subscribers[client]?.pendingTokens.isEmpty == true)
  }

  @Test
  func legacyInboxAcknowledgementStillDecodes() throws {
    let data = Data(#"{"inboxAck":{"revision":7}}"#.utf8)
    guard
      case let .inboxAck(revision, token) = try SMXCodec.decode(
        ClientMessage.self,
        from: data,
        limit: 4096
      )
    else {
      throw MuxError(
        .invalidRequest,
        "legacy inbox acknowledgement did not decode"
      )
    }
    #expect(revision == 7)
    #expect(token == nil)
  }

  @Test
  func `oversized reducer batches reach subscribers as resync notifications`()
    throws
  {
    var limits = MuxLimits.standard
    limits.maxControlRecordBytes = 2 * AttentionInbox.itemOverhead
    limits.resolvedHistory = 0
    var hub = InboxHub(serviceEpoch: ServerInstanceID(), limits: limits)
    let subscriber = UUID()
    _ = try hub.subscribe(subscriber)
    let pane = PaneID()
    let epoch = TerminalEpochID()
    let context = AttentionContext(workspace: WorkspaceID(), tab: nil)
    hub.apply(
      ["a", "b", "c"].map { .report(StatusRecord(path: $0, state: .blocked)) },
      pane: pane,
      epoch: epoch,
      context: context
    )
    let first = hub.flush()
    #expect(first.count == 1)
    let delivered = try #require(first.first)
    #expect(delivered.0 == subscriber)
    #expect(delivered.1.resync)
    #expect(delivered.1.changed.isEmpty && delivered.1.removed.isEmpty)
    #expect(delivered.1.counts.needsYou == 3)
    let empty = hub.flush()
    #expect(empty.isEmpty)
    let page = try hub.page(InboxQuery())
    #expect(page.items.map(\.source.recordPath).sorted() == ["a", "b", "c"])
    let removed = try #require(page.items.first { $0.source.recordPath == "a" })
    let acknowledged = hub.acknowledge(subscriber)
    #expect(acknowledged == nil)
    hub.apply([.removed(["a"])], pane: pane, epoch: epoch, context: context)
    let following = hub.flush()
    #expect(following.count == 1)
    let delta = try #require(following.first).1
    #expect(!delta.resync)
    #expect(delta.removed == [removed.occurrence])
    #expect(delta.counts.needsYou == 2)
  }

  @Test
  func failedInitialSnapshotDoesNotAdmitASubscriber() {
    var limits = MuxLimits.standard
    limits.inboxPageSize = 0
    limits.inboxSubscribers = 1
    var hub = InboxHub(serviceEpoch: ServerInstanceID(), limits: limits)
    for _ in 0 ..< 2 {
      do {
        _ = try hub.subscribe(UUID())
        Issue.record("Disabled paging admitted a subscriber")
      } catch { #expect(error.code == .resourceLimit) }
      #expect(hub.subscribers.isEmpty)
    }
    hub.apply(
      [.report(StatusRecord(path: "question", state: .blocked))],
      pane: PaneID(),
      epoch: TerminalEpochID(),
      context: AttentionContext(workspace: WorkspaceID(), tab: nil)
    )
    #expect(hub.flush().isEmpty)
    #expect(hub.inbox.counts(at: Date()).needsYou == 1)
  }

  @Test
  func subscriptionBoundsAndRepeatedAdmissionPreserveDeliveryCredit() throws {
    var limits = MuxLimits.standard
    limits.inboxSubscribers = 1
    var hub = InboxHub(serviceEpoch: ServerInstanceID(), limits: limits)
    let a = UUID()
    let b = UUID()
    _ = try hub.subscribe(a)
    hub.apply(
      [.report(StatusRecord(path: "question", state: .blocked))],
      pane: PaneID(),
      epoch: TerminalEpochID(),
      context: AttentionContext(workspace: WorkspaceID(), tab: nil)
    )
    #expect(hub.flush().count == 1)
    _ = try hub.subscribe(a)
    #expect(hub.subscribers[a]?.unacknowledged == 1)
    do {
      _ = try hub.subscribe(b)
      Issue.record("Subscriber bound was exceeded")
    } catch { #expect(error.code == .resourceLimit) }
    #expect(hub.subscribers.count == 1)
    hub.unsubscribe(a)
    hub.unsubscribe(a)
    _ = try hub.subscribe(b)
    #expect(hub.subscribers[b]?.unacknowledged == 0)
  }
}
