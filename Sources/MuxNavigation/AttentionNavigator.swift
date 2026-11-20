import Foundation
import Observation
import SwiftMuxProtocol

/// Item metadata shown before anything is opened. `item`'s program text
/// is untrusted: render it as plain text, never markup or a link.
public struct AttentionPreview: Sendable, Equatable {
  public var item: AttentionItem
  public var target: PaneTarget
  public var leaseHeldElsewhere: Bool

  public init(item: AttentionItem, target: PaneTarget, leaseHeldElsewhere: Bool)
  {
    self.item = item
    self.target = target
    self.leaseHeldElsewhere = leaseHeldElsewhere
  }
}

/// An explicit takeover offer; never acted on without the user.
public struct TakeoverOffer: Sendable, Equatable {
  public var preview: AttentionPreview
  /// Generation the user is agreeing to displace.
  public var expectedLease: UInt64
  public var holder: LeaseHolder?
  /// The previous offer went stale (someone else took control first).
  public var controllerChanged: Bool

  public init(
    preview: AttentionPreview,
    expectedLease: UInt64,
    holder: LeaseHolder?,
    controllerChanged: Bool = false
  ) {
    self.preview = preview
    self.expectedLease = expectedLease
    self.holder = holder
    self.controllerChanged = controllerChanged
  }
}

/// UI states of one link navigation (spec.inbox.md §4).
public enum AttentionNavigationState: Sendable, Equatable {
  public enum MissingReason: Sendable, Equatable {
    /// Different service epoch: the service restarted since the link
    /// was made, so every pane it named is gone.
    case serviceRestarted
    /// Unknown occurrence, replaced terminal or gone pane.
    case notFound
  }

  case idle
  /// Step 1 failed; nothing was contacted.
  case rejected(AttentionLink.Rejection)
  /// The link's host is not one of the recipient's configured hosts.
  case needsHostSelection([NavigationHost])
  case connecting(NavigationHost)
  /// Offline or not resolvable right now; `retry()` may succeed.
  case unavailable(reason: String)
  /// The exact occurrence is current; offer **Open in pane**.
  case ready(AttentionPreview)
  /// The exact occurrence was resolved, reviewed or superseded. Never
  /// replaced by a newer request with the same label.
  case stale(AttentionPreview)
  case missing(MissingReason)
  /// The pane exited; its retained final output may still be opened.
  case paneExited(AttentionPreview)
  /// Another client controls the workspace.
  case confirmTakeover(TakeoverOffer)
  case opening(PaneTarget)
  case opened(PaneTarget)
}

/// Platform-independent state machine for following an attention link
/// (spec.inbox.md §4, steps 1–7). Platform code feeds it URLs
/// and user choices, renders `state`, and supplies the host directory and
/// service connector.
///
/// Guarantees:
/// - links are validated before anything is contacted, and hosts come
///   only from the recipient's configuration;
/// - the service epoch and exact occurrence are checked before any item
///   metadata is shown, and nothing else is ever substituted for it;
/// - metadata reads never take a lease; opening never takes over
///   silently;
/// - `markSeen` is sent at most once, for exactly the linked occurrence,
///   and only after the user saw it;
/// - a newer navigation cancels an older one, so a delayed result can
///   never change state or acknowledge anything.
@MainActor
@Observable
public final class AttentionNavigator {
  public private(set) var state: AttentionNavigationState = .idle {
    didSet { onStateChange?(state) }
  }
  public private(set) var destination: AttentionDestination?

  @ObservationIgnored
  public var onStateChange: (@MainActor (AttentionNavigationState) -> Void)?

  @ObservationIgnored
  private let configuration: AttentionLinkConfiguration
  @ObservationIgnored
  private let hosts: any AttentionHostDirectory
  @ObservationIgnored
  private let connector: any AttentionServiceConnector
  @ObservationIgnored
  private var service: (any AttentionService)?
  @ObservationIgnored
  private var host: NavigationHost?
  @ObservationIgnored
  private var generation: UInt64 = 0
  @ObservationIgnored
  private var seenSent = false
  @ObservationIgnored
  private var activation: (id: UUID, task: Task<Void, Never>)?

  public init(
    configuration: AttentionLinkConfiguration,
    hosts: any AttentionHostDirectory,
    connector: any AttentionServiceConnector
  ) {
    self.configuration = configuration
    self.hosts = hosts
    self.connector = connector
  }

  // MARK: Inputs

  /// Step 1: validates `url` and starts navigation, or shows why not.
  public func open(_ url: URL) async {
    let destination: AttentionDestination
    do {
      destination = try AttentionLink.parse(url, configuration: configuration)
    } catch {
      restart(nil)
      state = .rejected(error)
      return
    }
    await open(destination)
  }

  /// Starts navigation to an already-typed destination (for example a
  /// notification action or a Handoff continuation).
  public func open(_ destination: AttentionDestination) async {
    guard destination.isValid else {
      restart(nil)
      state = .rejected(.invalidLocator(.invalidRecordPath))
      return
    }
    let gen = restart(destination)
    // Step 2: the recipient's own mapping, or an explicit choice.
    let configured = await hosts.configuredHosts()
    guard gen == generation else { return }
    guard
      let host = configured.first(where: {
        $0.id == destination.localHostProfileID
      })
    else {
      state = .needsHostSelection(configured)
      return
    }
    await resolve(on: host, generation: gen)
  }

  /// Uses one of the recipient's configured hosts for the pending link.
  public func selectHost(_ host: NavigationHost) async {
    guard case let .needsHostSelection(choices) = state,
      let chosen = choices.first(where: { $0.id == host.id })
    else { return }
    await resolve(on: chosen, generation: generation)
  }

  /// Re-runs resolution after an unavailable state.
  public func retry() async {
    guard case .unavailable = state, destination != nil, let host else {
      return
    }
    await resolve(on: host, generation: generation)
  }

  /// The user chose **Open in pane** (step 5).
  public func openInPane() async {
    let preview: AttentionPreview
    switch state {
    case let .ready(p), let .paneExited(p): preview = p
    default: return
    }
    // Always a plain attach first: the opener may already hold the lease
    // (its own window), and otherwise the service refuses with
    // `leaseHeld`, which becomes an explicit offer.
    await activate(preview, takeover: nil, generation: generation)
  }

  public func confirmTakeover() async {
    guard case let .confirmTakeover(offer) = state else { return }
    await activate(
      offer.preview,
      takeover: offer.expectedLease,
      generation: generation
    )
  }

  /// The user declined the takeover offer: back to read-only metadata.
  public func declineTakeover() {
    guard case let .confirmTakeover(offer) = state else { return }
    state = .ready(offer.preview)
  }

  /// The user has looked at the item (step 7): marks exactly the linked
  /// occurrence seen, once. Does nothing unless the shown item is that
  /// occurrence.
  public func didView() async {
    let item: AttentionItem
    switch state {
    case let .ready(p), let .stale(p), let .paneExited(p): item = p.item
    case let .confirmTakeover(o): item = o.preview.item
    default: return
    }
    await markSeen(item, generation: generation)
  }

  /// Abandons the current navigation; late results are dropped.
  public func cancel() {
    restart(nil)
    state = .idle
  }

  // MARK: Steps

  @discardableResult
  private func restart(_ destination: AttentionDestination?) -> UInt64 {
    generation &+= 1
    activation?.task.cancel()
    activation = nil
    self.destination = destination
    seenSent = false
    host = nil
    if let service {
      self.service = nil
      Task { await service.close() }
    }
    return generation
  }

  /// Steps 3–4: authenticate, check epoch and exact occurrence, read
  /// metadata without a lease.
  private func resolve(on host: NavigationHost, generation gen: UInt64) async {
    guard let destination else { return }
    self.host = host
    state = .connecting(host)
    guard gen == generation else { return }
    if let old = service {
      service = nil
      await old.close()
    }
    guard gen == generation else { return }
    let connected: any AttentionService
    do { connected = try await connector.connect(to: host) } catch {
      guard gen == generation else { return }
      state = failureState(error)
      return
    }
    guard gen == generation else {
      await connected.close()
      return
    }
    service = connected
    do {
      let epoch = try await connected.serviceEpoch()
      guard gen == generation else { return }
      guard epoch == destination.serviceEpoch else {
        state = .missing(.serviceRestarted)
        return
      }
      let location = try await connected.locate(destination.reference)
      guard gen == generation else { return }
      state = metadataState(location, destination: destination)
    } catch {
      guard gen == generation else { return }
      state = failureState(error)
    }
  }

  /// Maps a location to a state, refusing anything that is not the exact
  /// linked occurrence.
  private func metadataState(
    _ location: AttentionLocation,
    destination: AttentionDestination
  ) -> AttentionNavigationState {
    guard location.availability != .missing else { return .missing(.notFound) }
    guard let item = location.item, destination.matches(item),
      location.pane == nil || location.pane == destination.paneID
    else { return .missing(.notFound) }
    let preview = AttentionPreview(
      item: item,
      target: PaneTarget(
        workspace: location.workspace ?? item.workspace,
        tab: location.tab ?? item.tab,
        pane: destination.paneID
      ),
      leaseHeldElsewhere: location.leaseHeldElsewhere
    )
    switch location.availability {
    case .available:
      // An item the service still lists but that is no longer open is
      // stale, whatever the availability summary says.
      return item.resolution == .open ? .ready(preview) : .stale(preview)
    case .stale: return .stale(preview)
    case .paneExited: return .paneExited(preview)
    case .missing: return .missing(.notFound)
    }
  }

  private func failureState(
    _ error: AttentionServiceError
  ) -> AttentionNavigationState {
    switch error {
    case .serviceRestarted: .missing(.serviceRestarted)
    case .notFound: .missing(.notFound)
    case let .offline(reason): .unavailable(reason: reason)
    case .unauthorized: .unavailable(reason: "Not authorized on this host.")
    case let .unsupported(reason): .unavailable(reason: reason)
    case let .other(reason): .unavailable(reason: reason)
    case .leaseHeld, .leaseChanged, .paneExited:
      .unavailable(reason: "The pane could not be opened.")
    }
  }

  private func offerTakeover(
    _ preview: AttentionPreview,
    changed: Bool,
    generation gen: UInt64
  ) async {
    guard let service else { return }
    do {
      let lease = try await service.leaseState(of: preview.target.workspace)
      guard gen == generation else { return }
      state = .confirmTakeover(
        TakeoverOffer(
          preview: preview,
          expectedLease: lease.generation,
          holder: lease.holder,
          controllerChanged: changed
        )
      )
    } catch {
      guard gen == generation else { return }
      state = failureState(error)
    }
  }

  /// Step 5–6: attach (or take over, only when `takeover` is set).
  private func activate(
    _ preview: AttentionPreview,
    takeover: UInt64?,
    generation gen: UInt64
  ) async {
    activation?.task.cancel()
    let id = UUID()
    let task = Task {
      await performActivation(preview, takeover: takeover, generation: gen)
    }
    activation = (id, task)
    await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
    if activation?.id == id { activation = nil }
  }

  private func performActivation(
    _ preview: AttentionPreview,
    takeover: UInt64?,
    generation gen: UInt64
  ) async {
    guard gen == generation, !Task.isCancelled else { return }
    guard let service else { return }
    state = .opening(preview.target)
    guard gen == generation, !Task.isCancelled else { return }
    do {
      try await service.open(preview.target, takeover: takeover)
      guard gen == generation else { return }
      state = .opened(preview.target)
      await markSeen(preview.item, generation: gen)
    } catch .leaseHeld {
      guard gen == generation else { return }
      await offerTakeover(preview, changed: takeover != nil, generation: gen)
    } catch .leaseChanged {
      guard gen == generation else { return }
      await offerTakeover(preview, changed: true, generation: gen)
    } catch .paneExited {
      guard gen == generation else { return }
      state = .paneExited(preview)
    } catch {
      guard gen == generation else { return }
      state = failureState(error)
    }
  }

  /// Step 7, guarded: only the linked occurrence, only once, only for
  /// the current navigation.
  private func markSeen(_ item: AttentionItem, generation gen: UInt64) async {
    guard gen == generation, !seenSent, let destination, let service,
      destination.matches(item)
    else { return }
    seenSent = true
    try? await service.markSeen(destination.reference)
  }
}
