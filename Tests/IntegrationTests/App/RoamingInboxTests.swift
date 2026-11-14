import CoreTestSupport
import Foundation
import MuxNavigation
import ScreenProtocol
import SwiftMuxProtocol
import Synchronization
import Testing

@testable import RoamingApp

/// One ordered clock/lock shared by this fixture's service actors and model.
/// Recording does not suspend either side or sample another actor's state.
private final class InboxRefreshTrace: Sendable {
  struct Event: Sendable {
    let elapsed: Duration
    let phase: String
    let generation: UUID?
    let host: UUID?
  }

  private struct State {
    var events: [Event] = []
    var dropped = 0
  }

  private let start = ContinuousClock.now
  private let state = Mutex(State())

  func record(_ phase: String, generation: UUID? = nil, host: UUID? = nil) {
    state.withLock {
      guard $0.events.count < 256 else {
        $0.dropped += 1;
        return
      }
      $0.events.append(
        Event(
          elapsed: start.duration(to: .now),
          phase: phase,
          generation: generation,
          host: host
        )
      )
    }
  }

  var events: [Event] { state.withLock { $0.events } }

  var summary: String {
    state.withLock {
      let entries = $0.events.map { event in
        let generation =
          event.generation.map { String($0.uuidString.prefix(8)) } ?? "-"
        let host = event.host.map { String($0.uuidString.prefix(8)) } ?? "-"
        return "\(event.elapsed):\(event.phase)(g=\(generation),h=\(host))"
      }
      return "[\(entries.joined(separator: "; "))], dropped=\($0.dropped)"
    }
  }

  func report(_ fixture: String) throws {
    guard
      let directory = ProcessInfo.processInfo.environment[
        "SWIFTTY_INBOX_TRACE_DIRECTORY"
      ]
    else { return }
    let captured = state.withLock { $0 }
    let events: [[String: Any]] = captured.events.map { event in
      let duration = event.elapsed.components
      return [
        "elapsed_seconds": Double(duration.seconds) + Double(
          duration.attoseconds
        ) / 1e18, "phase": event.phase,
        "generation": event.generation?.uuidString as Any? ?? NSNull(),
        "host": event.host?.uuidString as Any? ?? NSNull(),
      ]
    }
    let data = try JSONSerialization.data(
      withJSONObject: [
        "fixture": fixture, "events": events, "dropped": captured.dropped,
      ],
      options: [.prettyPrinted, .sortedKeys]
    )
    let url = URL(fileURLWithPath: directory, isDirectory: true)
      .appendingPathComponent(fixture + ".json")
    try data.write(to: url, options: .atomic)
  }

  func observe(
    _ generation: UUID,
    _ host: UUID?,
    _ phase: RoamingInboxModel.RefreshPhase
  ) { record("model." + phase.rawValue, generation: generation, host: host) }
}

private actor InboxService: RoamingAttentionMetadataService {
  let epoch = SwiftMuxProtocol.ServerInstanceID(rawValue: UUID())
  var pages: [InboxQuery.Section: [InboxPage]] = [:]
  var holdFirst = false
  var held: CheckedContinuation<Void, Never>?
  var closes = 0
  var metadataRequests = 0
  var metadataReplies = 0
  var actionError: AttentionServiceError?
  private let trace: InboxRefreshTrace?
  private let label: String

  init(trace: InboxRefreshTrace? = nil, label: String = "service") {
    self.trace = trace
    self.label = label
  }

  func configure(_ pages: [InboxQuery.Section: [InboxPage]], hold: Bool = false)
  {
    self.pages = pages
    holdFirst = hold
  }
  func failActions() { actionError = .other("Action failed") }
  var isHolding: Bool { held != nil }
  var progress: String {
    "requests=\(metadataRequests), replies=\(metadataReplies), closes=\(closes), holding=\(isHolding)"
  }
  func release() {
    held?.resume();
    held = nil
  }

  func metadata(
    _ request: AttentionRequest
  ) async throws(AttentionServiceError) -> HostMetadata {
    trace?.record(label + ".metadataRequest")
    metadataRequests += 1
    guard case let .inbox(query) = request else {
      if let actionError { throw actionError }
      metadataReplies += 1
      trace?.record(label + ".metadataReply")
      return HostMetadata(serviceEpoch: epoch)
    }
    let index = Int(query.cursor ?? "0") ?? 0
    let page =
      pages[query.section]
      .flatMap { $0.indices.contains(index) ? $0[index] : nil }
      ?? InboxPage(
        items: [],
        counts: pages[.needsYou]?.first?.counts ?? InboxCounts(),
        revision: 1,
        nextCursor: nil
      )
    if holdFirst, query.section == .needsYou, query.cursor == nil {
      holdFirst = false
      await withCheckedContinuation { held = $0 }
    }
    metadataReplies += 1
    trace?.record(label + ".metadataReply")
    return HostMetadata(serviceEpoch: epoch, inbox: page)
  }
  func serviceEpoch() async throws(AttentionServiceError)
    -> SwiftMuxProtocol.ServerInstanceID
  { epoch }
  func locate(
    _ reference: AttentionReference
  ) async throws(AttentionServiceError) -> AttentionLocation { throw .notFound }
  func leaseState(
    of workspace: WorkspaceID
  ) async throws(AttentionServiceError) -> LeaseState { throw .notFound }
  func open(
    _ target: PaneTarget,
    takeover expectedLease: UInt64?
  ) async throws(AttentionServiceError) { throw .notFound }
  func markSeen(
    _ reference: AttentionReference
  ) async throws(AttentionServiceError) {}
  func close() async {
    trace?.record(label + ".closeEntered")
    closes += 1
    trace?.record(label + ".closeReturned")
  }
}

private actor InboxConnector: AttentionServiceConnector {
  var services: [InboxService]
  var calls: [UUID] = []
  init(_ services: [InboxService]) { self.services = services }
  func connect(
    to host: NavigationHost
  ) async throws(AttentionServiceError) -> any AttentionService {
    calls.append(host.id)
    guard !services.isEmpty else { throw .offline("No test service") }
    return services.removeFirst()
  }
}

@MainActor
private func inboxEventually(_ condition: () async -> Bool) async throws -> Bool
{
  let deadline = ContinuousClock.now + .seconds(2)
  while !(await condition()) {
    guard ContinuousClock.now < deadline else { return false }
    try await Task.sleep(for: .milliseconds(5))
  }
  return true
}

extension MainActorIntegrationTests {
  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(1)))
  struct RoamingInboxTests {
    private func progress(
      _ inbox: RoamingInboxModel,
      connector: InboxConnector,
      services: [InboxService],
      trace: InboxRefreshTrace? = nil
    ) async -> Comment {
      // Capture main-actor publication before yielding to service actors.
      let publication =
        "states=\(inbox.hostStates), entries=\(inbox.entries.count), refreshed=\(String(describing: inbox.refreshedAt))"
      let phases = trace?.summary ?? "not recorded"
      let calls = await connector.calls.count
      var serviceStates: [String] = []
      for service in services { serviceStates.append(await service.progress) }
      return Comment(
        rawValue:
          "\(publication), phases=\(phases), connections=\(calls), services=\(serviceStates)"
      )
    }

    func app(at directory: URL, hosts: [HostProfile]) throws -> RoamingAppModel
    {
      let app = RoamingAppModel(
        store: ConnectionStore(
          fileURL: directory.appendingPathComponent("hosts.json")
        )
      )
      for host in hosts { #expect(try app.save(host)) }
      return app
    }
    func host(_ name: String, password: Bool = false) -> HostProfile {
      HostProfile(
        nickname: name,
        host: name + ".local",
        username: "test",
        auth: password ? .password : .key(identityID: UUID())
      )
    }
    func item(epoch: SwiftMuxProtocol.ServerInstanceID) -> AttentionItem {
      let source = AttentionSource(
        serviceEpoch: epoch,
        pane: PaneID(rawValue: UUID()),
        terminalEpoch: TerminalEpochID(rawValue: UUID()),
        recordPath: "",
        recordIncarnation: 1
      )
      let now = Date.now
      return AttentionItem(
        occurrence: OccurrenceID(rawValue: UUID()),
        source: source,
        workspace: WorkspaceID(rawValue: UUID()),
        tab: nil,
        category: .needsYou,
        resolution: .open,
        status: AttentionStatus(
          source: source,
          state: .blocked,
          updatedAt: now
        ),
        createdAt: now,
        updatedAt: now,
        revision: 1
      )
    }
    func page(
      _ items: [AttentionItem],
      count: Int,
      next: String? = nil
    ) -> InboxPage {
      InboxPage(
        items: items,
        counts: InboxCounts(needsYou: count),
        revision: 1,
        nextCursor: next
      )
    }

    @Test
    func refreshReadsAllPages() async throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let trace = InboxRefreshTrace()
      let service = InboxService(trace: trace)
      let epoch = service.epoch
      let items = [item(epoch: epoch), item(epoch: epoch)]
      await service.configure([
        .needsYou: [
          page([items[0]], count: 2, next: "1"), page([items[1]], count: 2),
        ]
      ])
      let connector = InboxConnector([service])
      let model = try app(at: directory, hosts: [host("first")])
      let inbox = RoamingInboxModel(
        model: model,
        connectorFactory: { _ in connector },
        observeRefresh: trace.observe
      )
      inbox.refresh()
      let refreshed = try await inboxEventually { inbox.refreshedAt != nil }
      let hostStates = inbox.hostStates
      let phases = trace.summary
      let connectionCalls = await connector.calls.count
      let serviceCloses = await service.closes
      let serviceHolding = await service.isHolding
      #expect(
        refreshed,
        Comment(
          rawValue: """
            host states=\(hostStates), connections=\(connectionCalls)
            closes=\(serviceCloses), holding=\(serviceHolding)
            phases=\(phases)
            """
        )
      )
      #expect(Set(inbox.entries.map(\.item)) == Set(items))
      #expect(inbox.needsYouCount == 2)
      #expect(try await inboxEventually { await service.closes == 1 })
      let events = trace.events
      #expect(events.filter { $0.phase == "model.pageReceived" }.count == 3)
      let read = try #require(
        events.firstIndex { $0.phase == "model.snapshotRead" }
      )
      let entered = try #require(
        events.firstIndex { $0.phase == "service.closeEntered" }
      )
      let returned = try #require(
        events.firstIndex { $0.phase == "service.closeReturned" }
      )
      let joined = try #require(
        events.firstIndex { $0.phase == "model.retirementJoined" }
      )
      let published = try #require(
        events.firstIndex { $0.phase == "model.published" }
      )
      #expect(
        read < entered && entered < returned && returned < joined
          && joined < published
      )
      #expect(Set(events.compactMap(\.generation)).count == 1)
      try trace.report("all-pages")
    }

    @Test
    func cancelledRefreshCannotOverwriteTheNewerSnapshot() async throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let trace = InboxRefreshTrace()
      let old = InboxService(trace: trace, label: "old")
      let fresh = InboxService(trace: trace, label: "fresh")
      let oldItem = item(epoch: old.epoch)
      let freshItem = item(epoch: fresh.epoch)
      await old.configure([.needsYou: [page([oldItem], count: 1)]], hold: true)
      await fresh.configure([.needsYou: [page([freshItem], count: 2)]])
      let connector = InboxConnector([old, fresh])
      let model = try app(at: directory, hosts: [host("first")])
      let inbox = RoamingInboxModel(
        model: model,
        connectorFactory: { _ in connector },
        observeRefresh: trace.observe
      )
      let previousRefresh = inbox.refresh()
      #expect(try await inboxEventually { await old.isHolding })
      let replacementRefresh = inbox.refresh()
      let loadedAt = ContinuousClock.now
      let loaded = try await inboxEventually {
        inbox.entries.first?.item == freshItem
      }
      let elapsed = ContinuousClock.now - loadedAt
      trace.record("test.loadedObserved=\(loaded)")
      let state = await progress(
        inbox,
        connector: connector,
        services: [old, fresh],
        trace: trace
      )
      #expect(
        loaded,
        Comment(rawValue: "elapsed=\(elapsed), \(state.rawValue)")
      )
      await old.release()
      #expect(try await inboxEventually { await old.closes == 1 })
      #expect(inbox.entries.map(\.item) == [freshItem])
      await previousRefresh.value
      await replacementRefresh.value
      let finalCloses = await old.closes
      #expect(
        finalCloses == 1,
        "The replaced service must be closed exactly once after both workers finish."
      )
      let events = trace.events
      let generations = events.filter { $0.phase == "model.scheduled" }
        .compactMap(\.generation)
      #expect(generations.count == 2 && Set(generations).count == 2)
      #expect(
        events.filter { $0.phase == "model.published" }.compactMap(\.generation)
          == Array(generations.suffix(1))
      )
      try trace.report("replacement")
    }

    @Test
    func backgroundRefreshKeepsTheSkippedPasswordHosts() async throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let trace = InboxRefreshTrace()
      let service = InboxService(trace: trace)
      let item = item(epoch: service.epoch)
      await service.configure([.needsYou: [page([item], count: 1)]])
      let connector = InboxConnector([service])
      let model = try app(at: directory, hosts: [host("first", password: true)])
      let inbox = RoamingInboxModel(
        model: model,
        connectorFactory: { _ in connector },
        observeRefresh: trace.observe
      )
      inbox.refresh()
      let loadedAt = ContinuousClock.now
      let loaded = try await inboxEventually { inbox.entries.count == 1 }
      let elapsed = ContinuousClock.now - loadedAt
      trace.record("test.loadedObserved=\(loaded)")
      let state = await progress(
        inbox,
        connector: connector,
        services: [service],
        trace: trace
      )
      #expect(
        loaded,
        Comment(rawValue: "elapsed=\(elapsed), \(state.rawValue)")
      )
      let previous = inbox.refreshedAt
      inbox.refresh(interactive: false)
      #expect(try await inboxEventually { inbox.refreshedAt != previous })
      #expect(inbox.entries.map(\.item) == [item])
      #expect(await connector.calls.count == 1)
      try trace.report("background")
    }

    @Test
    func deletedHostsDoNotKeepTheirCounts() async throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let first = host("first")
      let second = host("second")
      let one = InboxService()
      let two = InboxService()
      let again = InboxService()
      for service in [one, two, again] {
        await service.configure([
          .needsYou: [page([item(epoch: service.epoch)], count: 1)],
          .results: [page([], count: 1)],
        ])
      }
      let connector = InboxConnector([one, two, again])
      let model = try app(at: directory, hosts: [first, second])
      let inbox = RoamingInboxModel(
        model: model,
        connectorFactory: { _ in connector }
      )
      inbox.refresh()
      #expect(try await inboxEventually { inbox.entries.count == 2 })
      model.delete(second)
      let previous = inbox.refreshedAt
      inbox.refresh()
      #expect(try await inboxEventually { inbox.refreshedAt != previous })
      #expect(inbox.hostStates[second.id] == nil)
      #expect(inbox.needsYouCount == 1)
    }

    @Test
    func repeatedCursorFailsWithoutPublishingPartialResults() async throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let service = InboxService()
      let item = item(epoch: service.epoch)
      await service.configure([
        .needsYou: [
          page([item], count: 1, next: "1"), page([], count: 1, next: "1"),
        ]
      ])
      let connector = InboxConnector([service])
      let host = host("first")
      let model = try app(at: directory, hosts: [host])
      let inbox = RoamingInboxModel(
        model: model,
        connectorFactory: { _ in connector }
      )
      inbox.refresh()
      #expect(try await inboxEventually { inbox.refreshedAt != nil })
      if case .failed = inbox.hostStates[host.id] {
      } else {
        Issue.record("Expected invalid cursor failure")
      }
      #expect(inbox.entries.isEmpty)
    }

    @Test
    func failedActionIsNotHiddenByAnotherRefresh() async throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let service = InboxService()
      let item = item(epoch: service.epoch)
      await service.configure([.needsYou: [page([item], count: 1)]])
      let failed = InboxService()
      await failed.failActions()
      let connector = InboxConnector([service, failed])
      let host = host("first")
      let model = try app(at: directory, hosts: [host])
      let inbox = RoamingInboxModel(
        model: model,
        connectorFactory: { _ in connector }
      )
      inbox.refresh()
      #expect(try await inboxEventually { inbox.entries.count == 1 })
      let entry = try #require(inbox.entries.first)
      inbox.perform(
        .markReviewed(
          AttentionReference(source: item.source, occurrence: item.occurrence)
        ),
        on: entry
      )
      #expect(
        try await inboxEventually {
          inbox.hostStates[host.id] == .failed("Action failed")
        }
      )
      #expect(inbox.hostStates[host.id] == .failed("Action failed"))
      #expect(await connector.calls.count == 2)
    }

    @Test(arguments: ["count", "cursor", "epoch", "page", "text"])
    func untrustedPageLimitsAreRejected(field: String) async throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let service = InboxService()
      var entry = item(epoch: service.epoch)
      var first = page([entry], count: 1)
      switch field {
      case "count": first.counts.needsYou = Int.max
      case "cursor": first.nextCursor = String(repeating: "x", count: 257)
      case "epoch":
        entry.source.serviceEpoch = SwiftMuxProtocol.ServerInstanceID(
          rawValue: UUID()
        )
        first.items = [entry]
      case "page":
        first.items = Array(
          repeating: entry,
          count: MuxLimits.standard.inboxPageSize + 1
        )
      default:
        entry.status.message = String(
          repeating: "x",
          count: MuxLimits.standard.statusTextBytes
        )
        first.items = [entry]
      }
      await service.configure([.needsYou: [first]])
      let connector = InboxConnector([service])
      let host = host("first")
      let model = try app(at: directory, hosts: [host])
      let inbox = RoamingInboxModel(
        model: model,
        connectorFactory: { _ in connector }
      )
      await inbox.refresh().value
      if case .failed = inbox.hostStates[host.id] {
      } else {
        Issue.record("Expected invalid metadata failure")
      }
      #expect(inbox.entries.isEmpty)
    }
  }
}
