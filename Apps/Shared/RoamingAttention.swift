import Foundation
import MuxNavigation
import Observation
import SSHClient
import ScreenProtocol
import SessionCore
import SwiftMuxProtocol
import Synchronization
import TerminalSurface

/// Metadata operations shared by authenticated roaming services.
protocol RoamingAttentionMetadataService: AttentionService {
  func metadata(
    _ request: AttentionRequest
  ) async throws(AttentionServiceError) -> HostMetadata
}

/// Attention metadata for roaming hosts over the SSH bootstrap channel
/// (spec.inbox.md §3, §9): host-key check and authentication first, then
/// lease-free `attention` requests to the SwiftMux service. Opening a pane
/// goes through the ordinary roaming attachment, with explicit takeover.
struct RoamingAttentionConnector: AttentionServiceConnector {
  let model: RoamingAppModel
  var interactive = true
  /// Report SSH failures by stage (host key, sign-in, reachability)
  /// instead of collapsing them, for screens that explain one host.
  var detailedErrors = false
  /// A chooser retains the host it showed instead of resolving a new selection.
  var selection: HostMutationContext?

  @MainActor
  func connect(
    to host: NavigationHost
  ) async throws(AttentionServiceError) -> any AttentionService {
    let profile: HostProfile
    if let selection {
      guard selection.id == host.id, model.hostMutationIsCurrent(selection),
        let selected = selection.original
      else { throw .other(RoamingAppModel.hostChangedMessage) }
      profile = selected
    } else {
      guard let current = model.hosts.first(where: { $0.id == host.id }) else {
        throw .notFound
      }
      profile = current
    }
    let connection: SSHConnection
    do {
      connection = try await model.ssh.connect(
        profile,
        interactive: interactive
      )
    } catch { throw detailedErrors ? Self.describe(error) : Self.map(error) }
    return RoamingAttentionService(
      model: model,
      host: profile,
      connection: connection
    )
  }

  /// The SSH stage and its nonsecret explanation.
  static func describe(_ error: SSHAccessError) -> AttentionServiceError {
    let message = String(
      localized: "\(error.title). \(error.detail)",
      bundle: #bundle
    )
    return error == .unreachable ? .offline(message) : .other(message)
  }

  static func map(_ error: SSHAccessError) -> AttentionServiceError {
    switch error {
    case .cancelled: .other("Sign-in was cancelled.")
    case .hostKeyChanged, .hostKeyRejected, .hostKeyMismatch,
      .trustStoreUnavailable, .keyUnavailable, .keyNeedsRepair,
      .unsupportedAuthMethod, .authenticationFailed:
      .unauthorized
    default: .offline("The Mac could not be reached.")
    }
  }
}

/// One authenticated SSH connection; each request is a no-PTY exec of the
/// fixed bootstrap helper.
final class RoamingAttentionService: RoamingAttentionMetadataService, Sendable {
  private let model: RoamingAppModel
  private let host: HostProfile
  private let connection: SSHConnection
  private let helperPath: String

  init(
    model: RoamingAppModel,
    host: HostProfile,
    connection: SSHConnection,
    helperPath: String = defaultHelperPath
  ) {
    self.model = model
    self.host = host
    self.connection = connection
    self.helperPath = helperPath
  }

  func metadata(
    _ request: AttentionRequest
  ) async throws(AttentionServiceError) -> HostMetadata {
    let response: BootstrapResponse
    do {
      response = try await connection.runBootstrap(
        helperPath: helperPath,
        request: BootstrapRequest(operation: .attention, attention: request)
      )
    } catch { throw .offline("The Mac's SwiftMux service did not answer.") }
    switch response {
    case let .metadata(metadata): return metadata
    case .failure(.unknownSession): throw .notFound
    case .failure(.agentUnavailable):
      throw .offline("Roaming is not enabled in SwiftMux on this Mac.")
    case .failure(.unsupportedVersion), .failure(.malformed):
      throw .unsupported(
        "This Mac's SwiftMux does not serve attention metadata."
      )
    default: throw .other("Unexpected reply from the Mac.")
    }
  }

  func serviceEpoch() async throws(AttentionServiceError)
    -> SwiftMuxProtocol.ServerInstanceID
  { try await metadata(.workspaces).serviceEpoch }

  func locate(
    _ reference: AttentionReference
  ) async throws(AttentionServiceError) -> AttentionLocation {
    let metadata = try await metadata(.locate(reference))
    guard metadata.serviceEpoch == reference.source.serviceEpoch else {
      throw .serviceRestarted
    }
    guard var location = metadata.location else { throw .notFound }
    // The service reports any holder; this app's own attachment to the
    // workspace is not "elsewhere".
    if let workspace = location.workspace, await ownsWorkspace(workspace) {
      location.leaseHeldElsewhere = false
    }
    return location
  }

  func leaseState(
    of workspace: WorkspaceID
  ) async throws(AttentionServiceError) -> LeaseState {
    guard
      let summary = try await metadata(.workspaces).workspaces?
        .first(where: { $0.id == workspace })
    else { throw .notFound }
    return LeaseState(
      generation: summary.leaseGeneration,
      holder: summary.leaseHolder
    )
  }

  func open(
    _ target: PaneTarget,
    takeover expectedLease: UInt64?
  ) async throws(AttentionServiceError) {
    guard
      let summary = try await metadata(.workspaces).workspaces?
        .first(where: { $0.id == target.workspace })
    else { throw .notFound }
    var lease = expectedLease
    if summary.isAttached {
      if await ownsWorkspace(target.workspace) {
        // Replacing this app's own attachment is not a takeover prompt.
        lease = summary.leaseGeneration
      } else if let expected = expectedLease {
        guard expected == summary.leaseGeneration else { throw .leaseChanged }
      } else {
        throw .leaseHeld
      }
    } else {
      lease = nil
    }
    let host = host
    let failure: AttentionServiceError? = await MainActor.run {
      guard !Task.isCancelled, connection.isActive else {
        return .other("Opening was cancelled.")
      }
      guard model.hosts.contains(host) else { return .notFound }
      model.reveal(
        host,
        workspace: SessionID(target.workspace),
        target: ResumeTarget(pane: target.pane, expectedLease: lease)
      )
      return nil
    }
    if let failure { throw failure }
  }

  func markSeen(
    _ reference: AttentionReference
  ) async throws(AttentionServiceError) {
    _ = try await metadata(.markSeen(reference))
  }

  func close() async { await connection.close() }

  @MainActor
  private func ownsWorkspace(_ workspace: WorkspaceID) -> Bool {
    guard let session = model.activeSession, session.host.id == host.id,
      session.kind == .roaming
    else { return false }
    return session.sessionID == SessionID(workspace)
  }
}

// MARK: Inbox across configured hosts

/// The attention inbox of every configured Mac, keyed by
/// `(host, service epoch, occurrence)` (spec.inbox.md §4 multi-host
/// aggregation). Fetched on demand over SSH; there is no push delivery.
@MainActor
@Observable
final class RoamingInboxModel {
  /// Per-instance observations for diagnosing asynchronous refresh boundaries.
  /// Contains identities and phases only, never host credentials or item text.
  nonisolated enum RefreshPhase: String, Sendable {
    case scheduled, workerStarted, connected, pageReceived, snapshotRead
    case retirementStarted, retirementReturned, retirementJoined, hostLoaded
    case published, readFailed, superseded
  }

  /// Replacement and a late worker share one asynchronous retirement.
  nonisolated private final class ServiceLifetime: Sendable {
    let service: any AttentionService
    private let closing = Mutex<Task<Void, Never>?>(nil)
    private let observe: (@Sendable (RefreshPhase) -> Void)?

    init(
      _ service: any AttentionService,
      observe: (@Sendable (RefreshPhase) -> Void)?
    ) {
      self.service = service
      self.observe = observe
    }

    func close() async {
      let task = closing.withLock { slot -> Task<Void, Never> in
        if let existing = slot { return existing }
        let created = Task { [service, observe] in
          observe?(.retirementStarted)
          await service.close()
          observe?(.retirementReturned)
        }
        slot = created
        return created
      }
      await task.value
    }
  }

  private struct RefreshGate: Sendable {
    var generation = UUID()
    var service: ServiceLifetime?
  }

  nonisolated private static let maxEntriesPerHost = 10_000
  nonisolated private static let maxPagesPerSection = 100
  nonisolated struct Entry: Identifiable, Hashable, Sendable {
    let host: NavigationHost
    let item: AttentionItem
    /// Sanitized once here rather than on every inbox redraw.
    let title: String?
    let appName: String?
    var id: String {
      "\(host.id)/\(item.source.serviceEpoch)/\(item.occurrence)"
    }

    init(host: NavigationHost, item: AttentionItem) {
      self.host = host
      self.item = item
      title = AttentionPresentation.plain(
        item.status.title ?? item.status.message
      )
      appName = AttentionPresentation.plain(item.status.app)
    }
  }

  enum HostState: Equatable {
    case loading
    case loaded(InboxCounts)
    case failed(String)
  }

  private(set) var entries: [Entry] = [] {
    didSet {
      needsYouEntries = entries.filter { $0.item.category != .result }
      resultEntries = entries.filter { $0.item.category == .result }
    }
  }
  /// `entries` split by section, cached so the inbox does not filter up
  /// to 10,000 entries per host on every redraw.
  private(set) var needsYouEntries: [Entry] = []
  private(set) var resultEntries: [Entry] = []
  private(set) var hostStates: [UUID: HostState] = [:]
  private(set) var refreshedAt: Date?
  @ObservationIgnored
  private let model: RoamingAppModel
  @ObservationIgnored
  private var refreshing: Task<Void, Never>?
  @ObservationIgnored
  private var generation = UUID()
  @ObservationIgnored
  nonisolated private let refreshGate = Mutex(RefreshGate())
  @ObservationIgnored
  private var fetchedProfiles: [UUID: HostProfile] = [:]
  @ObservationIgnored
  private let connectorFactory:
    @MainActor (Bool) -> any AttentionServiceConnector
  @ObservationIgnored
  private let observeRefresh: (@Sendable (UUID, UUID?, RefreshPhase) -> Void)?

  init(
    model: RoamingAppModel,
    connectorFactory: (@MainActor (Bool) -> any AttentionServiceConnector)? =
      nil,
    observeRefresh: (@Sendable (UUID, UUID?, RefreshPhase) -> Void)? = nil
  ) {
    self.model = model
    self.observeRefresh = observeRefresh
    self.connectorFactory =
      connectorFactory ?? {
        RoamingAttentionConnector(model: model, interactive: $0)
      }
  }

  var needsYouCount: Int {
    hostStates.values.reduce(0) { total, state in
      if case let .loaded(counts) = state {
        total + counts.needsYou
      } else {
        total
      }
    }
  }

  /// Fetches the needs-you and results sections from every host. Hosts
  /// that fail keep their own error; others still load. A background
  /// (non-interactive) refresh skips password hosts so it never prompts.
  @discardableResult
  func refresh(
    interactive: Bool = true,
    hostIDs: Set<UUID>? = nil
  ) -> Task<Void, Never> {
    refreshing?.cancel()
    let generation = UUID()
    self.generation = generation
    let previousService = refreshGate.withLock { gate in
      let previous = gate.service
      gate.service = nil
      gate.generation = generation
      return previous
    }
    if let previousService {
      Task.detached(priority: .userInitiated) { await previousService.close() }
    }
    if model.hosts.isEmpty { model.load() }
    let configured = Dictionary(
      uniqueKeysWithValues: model.hosts.map { ($0.id, $0) }
    )
    // Discard deleted or edited host snapshots before retaining skipped hosts.
    entries = entries.filter {
      configured[$0.host.id] != nil
        && fetchedProfiles[$0.host.id] == configured[$0.host.id]
    }
    hostStates = hostStates.filter {
      configured[$0.key] != nil && fetchedProfiles[$0.key] == configured[$0.key]
    }
    fetchedProfiles = configured
    let profiles = model.hosts.filter {
      (interactive || $0.auth != .password)
        && (hostIDs?.contains($0.id) ?? true)
    }
    let selected = Set(profiles.map(\.id))
    let retained = entries.filter { !selected.contains($0.host.id) }
    for profile in profiles { hostStates[profile.id] = .loading }
    let connector = connectorFactory(interactive)
    let observe = observeRefresh
    observe?(generation, nil, .scheduled)
    let task = Self.startRefresh(
      model: self,
      generation: generation,
      profiles: profiles,
      retained: retained,
      configured: configured,
      connector: connector,
      observe: observe
    )
    refreshing = task
    return task
  }

  /// The page loop must not resume on the main actor. A metadata reply that
  /// waits for that actor missed the two-second publication predicate while
  /// the actor was busy; one hop publishes the finished snapshot.
  nonisolated private static func startRefresh(
    model: RoamingInboxModel,
    generation: UUID,
    profiles: [HostProfile],
    retained: [Entry],
    configured: [UUID: HostProfile],
    connector: any AttentionServiceConnector,
    observe: (@Sendable (UUID, UUID?, RefreshPhase) -> Void)?
  ) -> Task<Void, Never> {
    Task.detached(priority: .userInitiated) {
      await model.performRefresh(
        generation: generation,
        profiles: profiles,
        retained: retained,
        configured: configured,
        connector: connector,
        observe: observe
      )
    }
  }

  nonisolated private func performRefresh(
    generation: UUID,
    profiles: [HostProfile],
    retained: [Entry],
    configured: [UUID: HostProfile],
    connector: any AttentionServiceConnector,
    observe: (@Sendable (UUID, UUID?, RefreshPhase) -> Void)?
  ) async {
    observe?(generation, nil, .workerStarted)
    var collected = retained
    var failures: [(HostProfile, NavigationHost, String)] = []
    var loaded: [(HostProfile, NavigationHost, [Entry], InboxCounts)] = []
    for profile in profiles {
      guard isCurrent(generation) else { return }
      let host = NavigationHost(id: profile.id, name: profile.nickname)
      let service: any AttentionService
      do throws(AttentionServiceError) {
        service = try await connector.connect(to: host)
      } catch {
        guard isCurrent(generation) else { return }
        failures.append((profile, host, Self.describe(error)))
        continue
      }
      observe?(generation, host.id, .connected)
      guard isCurrent(generation) else {
        observe?(generation, host.id, .superseded)
        await service.close()
        return
      }
      let observer: (@Sendable (RefreshPhase) -> Void)?
      if let observe {
        observer = { phase in observe(generation, host.id, phase) }
      } else {
        observer = nil
      }
      let lifetime = ServiceLifetime(service, observe: observer)
      guard install(lifetime, generation: generation) else {
        observe?(generation, host.id, .superseded)
        await lifetime.close()
        return
      }
      do throws(AttentionServiceError) {
        guard let metadata = service as? any RoamingAttentionMetadataService
        else { throw .unsupported("This host cannot serve inbox metadata.") }
        let snapshot = try await readInbox(
          metadata,
          host: host,
          generation: generation,
          observe: observe
        )
        observe?(generation, host.id, .snapshotRead)
        await lifetime.close()
        clearInstalled(lifetime)
        observe?(generation, host.id, .retirementJoined)
        guard isCurrent(generation) else {
          observe?(generation, host.id, .superseded)
          return
        }
        loaded.append((profile, host, snapshot.entries, snapshot.counts))
        collected += snapshot.entries
      } catch {
        observe?(generation, host.id, .readFailed)
        await lifetime.close()
        clearInstalled(lifetime)
        observe?(generation, host.id, .retirementJoined)
        guard isCurrent(generation) else { return }
        failures.append((profile, host, Self.describe(error)))
      }
    }
    guard isCurrent(generation) else { return }
    let publishEntries = collected
    let publishFailures = failures
    let publishLoaded = loaded
    await MainActor.run {
      guard self.ownsRefresh(generation) else { return }
      let current = Dictionary(
        uniqueKeysWithValues: self.model.hosts.map { ($0.id, $0) }
      )
      for (profile, host, message) in publishFailures
      where self.model.hosts.contains(profile) {
        self.hostStates[host.id] = .failed(message)
      }
      for (profile, host, _, counts) in publishLoaded
      where self.model.hosts.contains(profile) {
        self.hostStates[host.id] = .loaded(counts)
        observe?(generation, host.id, .hostLoaded)
      }
      var seen = Set<String>()
      self.entries =
        publishEntries.filter {
          configured[$0.host.id] == current[$0.host.id]
            && current[$0.host.id] != nil && seen.insert($0.id).inserted
        }
        .sorted { $0.item.updatedAt > $1.item.updatedAt }
      self.hostStates = self.hostStates.filter {
        configured[$0.key] == current[$0.key] && current[$0.key] != nil
      }
      self.refreshedAt = .now
      self.refreshing = nil
      observe?(generation, nil, .published)
      self.model.onAttentionSummaries?(self.summaries)
    }
  }

  nonisolated private func isCurrent(_ generation: UUID) -> Bool {
    refreshGate.withLock { $0.generation } == generation && !Task.isCancelled
  }

  nonisolated private func install(
    _ lifetime: ServiceLifetime,
    generation: UUID
  ) -> Bool {
    refreshGate.withLock { gate in
      guard gate.generation == generation else { return false }
      gate.service = lifetime
      return true
    }
  }

  nonisolated private func clearInstalled(_ lifetime: ServiceLifetime) {
    refreshGate.withLock { gate in
      if gate.service === lifetime { gate.service = nil }
    }
  }

  private func ownsRefresh(_ generation: UUID) -> Bool {
    self.generation == generation && !Task.isCancelled
  }

  /// Follow opaque cursors with finite work and memory, and publish a
  /// host's snapshot only after both sections finish successfully.
  /// Nonisolated so each metadata reply resumes without waiting for the
  /// main actor.
  nonisolated private func readInbox(
    _ service: any RoamingAttentionMetadataService,
    host: NavigationHost,
    generation: UUID,
    observe: (@Sendable (UUID, UUID?, RefreshPhase) -> Void)?
  ) async throws(AttentionServiceError) -> (
    entries: [Entry], counts: InboxCounts
  ) {
    var entries: [Entry] = []
    var counts = InboxCounts()
    var epoch: SwiftMuxProtocol.ServerInstanceID?
    var textBytes = 0
    for section in [InboxQuery.Section.needsYou, .results] {
      var cursor: String?
      var visited: Set<String> = []
      var pages = 0
      repeat {
        guard !Task.isCancelled else { throw .other("Refresh cancelled.") }
        guard pages < Self.maxPagesPerSection else {
          throw .other("The Mac's inbox exceeded the download limit.")
        }
        let metadata = try await service.metadata(
          .inbox(InboxQuery(section: section, cursor: cursor))
        )
        observe?(generation, host.id, .pageReceived)
        if let epoch, epoch != metadata.serviceEpoch { throw .serviceRestarted }
        epoch = metadata.serviceEpoch
        guard let page = metadata.inbox,
          page.items.count <= MuxLimits.standard.inboxPageSize,
          page.items.allSatisfy({
            $0.source.serviceEpoch == metadata.serviceEpoch
          }), (0 ... Self.maxEntriesPerHost).contains(page.counts.needsYou),
          (0 ... Self.maxEntriesPerHost).contains(page.counts.results)
        else { throw .other("The Mac returned an invalid inbox page.") }
        guard page.items.count <= Self.maxEntriesPerHost - entries.count else {
          throw .other("The Mac's inbox exceeded the download limit.")
        }
        for item in page.items {
          let cost =
            256
            + [
              item.source.recordPath, item.status.source.recordPath,
              item.status.app, item.status.title, item.status.message,
            ]
            .compactMap { $0 }.reduce(0) { $0 + $1.utf8.count }
          guard cost <= MuxLimits.standard.statusTextBytes - textBytes else {
            throw .other("The Mac's inbox exceeded the download limit.")
          }
          textBytes += cost
        }
        entries += page.items.map { Entry(host: host, item: $0) }
        counts = page.counts
        pages += 1
        cursor = page.nextCursor
        if let cursor {
          guard !cursor.isEmpty, cursor.utf8.count <= 256,
            visited.insert(cursor).inserted
          else { throw .other("The Mac returned an invalid inbox cursor.") }
        }
      } while cursor != nil
    }
    return (entries, counts)
  }

  /// Redacted summaries for the watch: no message text.
  var summaries: [AttentionSummary] {
    entries.prefix(20)
      .map { entry in
        let counts: InboxCounts =
          if case let .loaded(counts) = hostStates[entry.host.id] {
            counts
          } else { InboxCounts() }
        // The locator lets the watch hand off to this device; it carries
        // identifiers only.
        return AttentionSummary(
          item: entry.item,
          counts: counts,
          policy: .redacted,
          destination: destination(for: entry)
        )
      }
  }

  /// The typed destination for an entry, for the link navigator.
  func destination(for entry: Entry) -> AttentionDestination {
    AttentionDestination(hostProfileID: entry.host.id, item: entry.item)
  }

  /// Snoozes or reviews exactly this occurrence, then refreshes.
  func perform(_ request: AttentionRequest, on entry: Entry) {
    guard let profile = model.hosts.first(where: { $0.id == entry.host.id })
    else { return }
    let connector = connectorFactory(true)
    let generation = self.generation
    Task {
      let service: any AttentionService
      do throws(AttentionServiceError) {
        service = try await connector.connect(to: entry.host)
      } catch {
        if self.generation == generation, model.hosts.contains(profile) {
          hostStates[entry.host.id] = .failed(Self.describe(error))
        }
        return
      }
      do throws(AttentionServiceError) {
        guard let metadata = service as? any RoamingAttentionMetadataService
        else { throw .unsupported("This host cannot serve inbox metadata.") }
        _ = try await metadata.metadata(request)
        await service.close()
        guard !Task.isCancelled, model.hosts.contains(profile) else { return }
        refresh(hostIDs: [entry.host.id])
      } catch {
        await service.close()
        if self.generation == generation, model.hosts.contains(profile) {
          hostStates[entry.host.id] = .failed(Self.describe(error))
        }
      }
    }
  }

  nonisolated static func describe(_ error: AttentionServiceError) -> String {
    switch error {
    case let .offline(reason), let .unsupported(reason), let .other(reason):
      reason
    case .unauthorized: "Sign-in to the Mac failed."
    case .notFound: "The item is no longer available."
    case .serviceRestarted: "SwiftMux restarted on the Mac."
    case .leaseHeld: "Another device controls this workspace."
    case .leaseChanged: "The workspace's controller changed."
    case .paneExited: "The pane exited."
    }
  }
}
