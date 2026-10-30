import Foundation
import HostConnection
import Network
import Observation
import Synchronization
import dnssd

/// One browsed `_swiftty._tcp` record, before validation.
struct BrowsedService: Hashable, Sendable {
  var name: String
  var type: String
  var domain: String
  /// The interface the record was seen on; resolution stays on it.
  var interfaceIndex: UInt32
  var txt: [String: String]?
  /// Wire size of the TXT record.
  var txtBytes: Int
}

/// A Mac shown under Nearby Macs. Matching names are grouped for display
/// only: a name is never proof that two records are the same host, and
/// nothing here is trusted or connected to automatically.
struct NearbyCandidate: Identifiable, Hashable, Sendable {
  /// The raw instance name, the browse key.
  var id: String
  /// Sanitized display text; never used as a host name.
  var displayName: String
  /// Every interface the record was seen on; resolution uses the first.
  var services: [BrowsedService]
}

/// Validates and bounds browse results (spec.connection-setup.md D3).
enum NearbyCandidateList {
  static func make(_ services: [BrowsedService]) -> [NearbyCandidate] {
    var byName: [String: NearbyCandidate] = [:]
    var order: [String] = []
    for service in services {
      guard service.type.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        == HostDiscovery.serviceType,
        service.domain.lowercased() == HostDiscovery.domain,
        let txt = service.txt,
        HostDiscovery.validate(txt: txt, byteCount: service.txtBytes)
          == .accepted,
        service.name.utf8.count <= HostDiscovery.maxInstanceNameBytes
      else { continue }
      let display = HostDiscovery.sanitizedName(service.name)
      guard !display.isEmpty else { continue }
      if var existing = byName[service.name] {
        if !existing.services.contains(service), existing.services.count < 8 {
          existing.services.append(service)
          byName[service.name] = existing
        }
        continue
      }
      guard order.count < HostDiscovery.maxCandidates else { continue }
      order.append(service.name)
      byName[service.name] = NearbyCandidate(
        id: service.name,
        displayName: display,
        services: [service]
      )
    }
    return order.compactMap { byName[$0] }
      .sorted {
        $0.displayName.localizedStandardCompare($1.displayName)
          == .orderedAscending
      }
  }
}

/// A resolved service endpoint: the advertised SSH port and the host
/// name the record names (preferred over a transient address).
struct ResolvedEndpoint: Hashable, Sendable {
  var host: String
  var port: Int
}

enum ResolveError: Error, Hashable, Sendable {
  case cancelled
  case timedOut
  case policyDenied
  /// The record named no usable host or port.
  case unsupported
  case failed(Int32)
}

protocol ServiceResolving: Sendable {
  func resolve(
    _ service: BrowsedService
  ) async throws(ResolveError) -> ResolvedEndpoint
}

/// `DNSServiceResolve` on the record's own interface, so a link-local
/// result is not detached from its scope. The host target (such as
/// `MacBook.local.`) is returned without its trailing dot; the system
/// resolver applies the interface when SSH later connects to it.
struct DNSSDResolver: ServiceResolving {
  var timeout: Duration = .seconds(10)

  func resolve(
    _ service: BrowsedService
  ) async throws(ResolveError) -> ResolvedEndpoint {
    let operation = DNSSDResolveOperation(service: service)
    do {
      return try await withTaskCancellationHandler {
        try await withThrowingTaskGroup(of: ResolvedEndpoint.self) { group in
          group.addTask { try await operation.run() }
          group.addTask {
            try await Task.sleep(for: timeout)
            throw ResolveError.timedOut
          }
          defer { group.cancelAll() }
          guard let first = try await group.next() else {
            throw ResolveError.cancelled
          }
          return first
        }
      } onCancel: {
        operation.cancel(.cancelled)
      }
    } catch let error as ResolveError {
      operation.cancel(error)
      throw error
    } catch {
      operation.cancel(.cancelled)
      throw .cancelled
    }
  }
}

/// One resolution: completes exactly once and deallocates its DNS-SD
/// reference on its own queue, so a late callback cannot outlive it.
private final class DNSSDResolveOperation: Sendable {
  /// A DNS-SD reference, touched only on `queue` after registration.
  ///
  /// Sendable: none: immutable after init. It is stored in the `state` Mutex
  /// and passed to DNS-SD only on `queue`, where `finish` deallocates it once.
  private struct Reference: @unchecked Sendable {
    let ref: DNSServiceRef
  }

  private struct State {
    var ref: Reference?
    var continuation: CheckedContinuation<ResolvedEndpoint, any Error>?
    var outcome: Result<ResolvedEndpoint, ResolveError>?
  }

  let service: BrowsedService
  private let queue = DispatchQueue(label: "dev.swiftty.roaming.resolve")
  private let state = Mutex(State())

  init(service: BrowsedService) { self.service = service }

  func run() async throws -> ResolvedEndpoint {
    try await withCheckedThrowingContinuation { continuation in
      let early = state.withLock { state -> Result<ResolvedEndpoint, ResolveError>? in
        if let outcome = state.outcome { return outcome }
        state.continuation = continuation
        return nil
      }
      if let early {
        continuation.resume(with: early.mapError { $0 as any Error })
        return
      }
      queue.async { self.begin() }
    }
  }

  private func begin() {
    var ref: DNSServiceRef?
    let context = Unmanaged.passUnretained(self).toOpaque()
    let error = DNSServiceResolve(
      &ref,
      0,
      service.interfaceIndex,
      service.name,
      service.type,
      service.domain,
      { _, _, _, error, _, target, port, _, _, context in
        guard let context else { return }
        let operation = Unmanaged<DNSSDResolveOperation>
          .fromOpaque(context).takeUnretainedValue()
        operation.reply(error: error, target: target, port: port)
      },
      context
    )
    guard error == kDNSServiceErr_NoError, let ref else {
      finish(.failure(Self.map(error)))
      return
    }
    let registered = state.withLock { state -> Bool in
      guard state.outcome == nil else { return false }
      state.ref = Reference(ref: ref)
      return true
    }
    guard registered else {
      DNSServiceRefDeallocate(ref)
      return
    }
    DNSServiceSetDispatchQueue(ref, queue)
  }

  /// Runs on `queue`.
  private func reply(
    error: DNSServiceErrorType,
    target: UnsafePointer<CChar>?,
    port: UInt16
  ) {
    guard error == kDNSServiceErr_NoError else {
      finish(.failure(Self.map(error)))
      return
    }
    guard let target else {
      finish(.failure(.unsupported))
      return
    }
    var host = String(cString: target)
    if host.hasSuffix(".") { host.removeLast() }
    let value = Int(UInt16(bigEndian: port))
    guard HostConnectionDescriptor.isValidHost(host), (1 ... 65_535).contains(value)
    else {
      finish(.failure(.unsupported))
      return
    }
    finish(.success(ResolvedEndpoint(host: host, port: value)))
  }

  func cancel(_ error: ResolveError) { finish(.failure(error)) }

  private func finish(_ outcome: Result<ResolvedEndpoint, ResolveError>) {
    let (reference, continuation) = state.withLock {
      state -> (Reference?, CheckedContinuation<ResolvedEndpoint, any Error>?) in
      guard state.outcome == nil else { return (nil, nil) }
      state.outcome = outcome
      let taken = (state.ref, state.continuation)
      state.ref = nil
      state.continuation = nil
      return taken
    }
    if let reference {
      // Deallocate on the reference's serial queue, keeping this context
      // alive until then: a callback queued earlier still finds it, and
      // none can follow.
      queue.async { [self] in
        DNSServiceRefDeallocate(reference.ref)
        withExtendedLifetime(self) {}
      }
    }
    continuation?.resume(with: outcome.mapError { $0 as any Error })
  }

  static func map(_ error: DNSServiceErrorType) -> ResolveError {
    switch Int(error) {
    case Int(kDNSServiceErr_PolicyDenied): .policyDenied
    case Int(kDNSServiceErr_Timeout): .timedOut
    default: .failed(error)
    }
  }
}

// MARK: - Browser

/// Nearby Macs: one `NWBrowser` for `_swiftty._tcp` in `local.`, started
/// only when the user opens Nearby Macs and stopped on dismissal or
/// backgrounding. Never browses other types, probes a subnet or connects
/// to results on its own.
@MainActor
@Observable
final class NearbyMacBrowser {
  enum State: Equatable {
    case idle
    case searching
    case results
    /// Browsing is running but nothing answered yet. Not evidence about
    /// Local Network permission.
    case noResults
    /// The system reported a Local Network policy denial.
    case denied
    case failed(String)
  }

  private(set) var state: State = .idle
  private(set) var candidates: [NearbyCandidate] = []
  /// The one candidate being resolved.
  private(set) var resolving: NearbyCandidate.ID?
  private(set) var resolveError: String?

  /// How long an empty, running browse shows "searching".
  static let quietPeriod: Duration = .seconds(6)

  @ObservationIgnored
  private var browser: NWBrowser?
  @ObservationIgnored
  private var generation = 0
  /// Separate from the browse generation: superseding a resolution must
  /// not discard browse updates.
  @ObservationIgnored
  private var resolveGeneration = 0
  @ObservationIgnored
  private var quietTask: Task<Void, Never>?
  @ObservationIgnored
  private var resolveTask: Task<Void, Never>?
  @ObservationIgnored
  private let resolver: any ServiceResolving

  init(resolver: any ServiceResolving = DNSSDResolver()) {
    self.resolver = resolver
  }

  /// Starts the one browse operation. A running browse is kept.
  func start() {
    guard browser == nil else { return }
    generation += 1
    let generation = generation
    candidates = []
    resolveError = nil
    state = .searching
    let parameters = NWParameters()
    parameters.includePeerToPeer = false
    let browser = NWBrowser(
      for: .bonjourWithTXTRecord(
        type: HostDiscovery.serviceType,
        domain: HostDiscovery.domain
      ),
      using: parameters
    )
    browser.stateUpdateHandler = { [weak self] state in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.browserState(state, generation) }
      }
    }
    browser.browseResultsChangedHandler = { [weak self] results, _ in
      let services = results.prefix(4 * HostDiscovery.maxCandidates)
        .compactMap(Self.service)
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.update(services, generation) }
      }
    }
    self.browser = browser
    browser.start(queue: .main)
  }

  /// Stops browsing and any resolution; late callbacks are ignored.
  func stop() {
    generation += 1
    resolveGeneration += 1
    browser?.cancel()
    browser = nil
    quietTask?.cancel()
    quietTask = nil
    resolveTask?.cancel()
    resolveTask = nil
    resolving = nil
    if state != .denied { state = .idle }
  }

  /// A fresh attempt, e.g. after returning from Settings.
  func restart() {
    stop()
    start()
  }

  nonisolated private static func service(
    _ result: NWBrowser.Result
  ) -> BrowsedService? {
    guard
      case let .service(name, type, domain, interface) = result.endpoint
    else { return nil }
    var txt: [String: String]?
    var bytes = 0
    if case let .bonjour(record) = result.metadata {
      bytes = record.data.count
      if bytes <= HostDiscovery.maxTXTBytes { txt = record.dictionary }
    }
    return BrowsedService(
      name: name,
      type: type,
      domain: domain,
      interfaceIndex: UInt32(interface?.index ?? 0),
      txt: txt,
      txtBytes: bytes
    )
  }

  private func browserState(_ next: NWBrowser.State, _ generation: Int) {
    guard generation == self.generation else { return }
    switch next {
    case .ready:
      if candidates.isEmpty { scheduleQuiet(generation) }
    case let .waiting(error), let .failed(error):
      if Self.isPolicyDenial(error) {
        state = .denied
      } else if case .failed = next {
        state = .failed("Searching stopped: \(error.localizedDescription)")
        browser?.cancel()
        browser = nil
      } else if candidates.isEmpty {
        // Waiting keeps the browse alive (for example, while the system
        // asks for permission); it reports nothing about permission.
        state = .searching
      }
    case .cancelled, .setup: break
    @unknown default: break
    }
  }

  private func scheduleQuiet(_ generation: Int) {
    quietTask?.cancel()
    quietTask = Task { [weak self] in
      try? await Task.sleep(for: Self.quietPeriod)
      guard !Task.isCancelled, let self, generation == self.generation,
        self.candidates.isEmpty, self.state == .searching
      else { return }
      self.state = .noResults
    }
  }

  func update(_ services: [BrowsedService], _ generation: Int? = nil) {
    guard generation.map({ $0 == self.generation }) ?? true else { return }
    candidates = NearbyCandidateList.make(services)
    if let resolving, !candidates.contains(where: { $0.id == resolving }) {
      // The record went away: drop its resolution.
      resolveTask?.cancel()
      resolveTask = nil
      resolveGeneration += 1
      self.resolving = nil
    }
    switch state {
    case .denied, .failed: break
    case .searching where candidates.isEmpty: break
    default: state = candidates.isEmpty ? .noResults : .results
    }
  }

  static func isPolicyDenial(_ error: NWError) -> Bool {
    if case let .dns(code) = error {
      return Int(code) == Int(kDNSServiceErr_PolicyDenied)
    }
    return false
  }

  /// Resolves the chosen candidate to a temporary pairing candidate. A
  /// newer choice supersedes this one; nothing is saved or connected.
  func choose(
    _ candidate: NearbyCandidate,
    then select: @escaping @MainActor @Sendable (HostCandidate) -> Void
  ) {
    resolveTask?.cancel()
    resolveGeneration += 1
    let generation = resolveGeneration
    resolving = candidate.id
    resolveError = nil
    let resolver = resolver
    guard let service = candidate.services.first else { return }
    resolveTask = Task { [weak self] in
      let result: Result<ResolvedEndpoint, ResolveError>
      do throws(ResolveError) {
        result = .success(try await resolver.resolve(service))
      } catch { result = .failure(error) }
      guard let self, generation == self.resolveGeneration, !Task.isCancelled,
        self.resolving == candidate.id
      else { return }
      self.resolving = nil
      self.resolveTask = nil
      switch result {
      case let .success(endpoint):
        select(
          HostCandidate(
            nearbyName: candidate.displayName,
            host: endpoint.host,
            port: endpoint.port
          )
        )
      case .failure(.cancelled): break
      case .failure(.policyDenied): self.state = .denied
      case .failure(.timedOut):
        self.resolveError =
          "\(candidate.displayName) did not answer in time. Check that it is "
          + "still on this network and its Connect a Device panel is open."
      case .failure(.unsupported):
        self.resolveError =
          "\(candidate.displayName) advertised an unusable address."
      case let .failure(.failed(code)):
        self.resolveError =
          "\(candidate.displayName) could not be resolved (DNS-SD error \(code))."
      }
    }
  }
}
