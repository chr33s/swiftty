#if os(macOS)
import AppleTransport
import Foundation
import Network
import ScreenProtocol
import SessionCore
import SwiftMuxProtocol
import SwiftMuxService
import Synchronization

/// The roaming transport of the SwiftMux service (spec.inbox.md §1, §7):
/// the pinned QUIC listener, the bootstrap control socket and the grant
/// registry, all inside the one service process that owns the panes.
/// `swifttyd bootstrap --stdio` (run by sshd) reaches it through the
/// control socket.
public final class RoamingHost: Sendable {
  public let registry: SessionRegistry
  // Listener callbacks can outlive stop; revoke their registry before teardown.
  private final class RegistryTarget: Sendable {
    let registry = Mutex<SessionRegistry?>(nil)

    func accept(_ connection: any RSTConnection) {
      if let registry = registry.withLock({ $0 }) {
        registry.accept(connection)
      } else {
        connection.close()
      }
    }
  }

  private let target: RegistryTarget
  private let control: ControlSocketServer
  private let configuration: HostConfiguration
  private let transport: Mutex<Transport>
  private let renewal = Mutex<DispatchSourceTimer?>(nil)
  private let renewing = Mutex(false)
  typealias TransportFactory =
    @Sendable (HostConfiguration, Date) throws -> (
      any RSTListener, HostCertificate, Date
    )
  private let transportFactory: TransportFactory

  struct Transport {
    var listener: any RSTListener
    var notValidAfter: Date
  }

  /// How often the certificate's remaining validity is checked.
  static let renewalCheckInterval: DispatchTimeInterval = .seconds(3600)

  private init(
    registry: SessionRegistry,
    target: RegistryTarget,
    control: ControlSocketServer,
    configuration: HostConfiguration,
    transport: Transport,
    transportFactory: @escaping TransportFactory
  ) {
    self.registry = registry
    self.target = target
    self.control = control
    self.configuration = configuration
    self.transport = Mutex(transport)
    self.transportFactory = transportFactory
  }

  deinit {
    target.registry.withLock { $0 = nil }
    renewal.withLock { $0?.cancel() }
    control.stop()
    transport.withLock { $0.listener }.stop()
  }

  /// Binds the listener first (grants advertise its actual port), then
  /// serves bootstrap requests, sweeps expired grants and renews the QUIC
  /// certificate before it expires (the service never idle-exits while
  /// roaming, so startup alone cannot renew it).
  public static func start(
    service: MuxService,
    configuration config: HostConfiguration,
    policy: RegistryPolicy = RegistryPolicy(),
    launch: @escaping @Sendable () -> LaunchSpec = RoamingHost.defaultLaunch
  ) async throws -> RoamingHost {
    try await start(
      service: service,
      configuration: config,
      policy: policy,
      launch: launch,
      transportFactory: makeTransport
    )
  }

  static func start(
    service: MuxService,
    configuration config: HostConfiguration,
    policy: RegistryPolicy = RegistryPolicy(),
    launch: @escaping @Sendable () -> LaunchSpec = RoamingHost.defaultLaunch,
    transportFactory: @escaping TransportFactory
  ) async throws -> RoamingHost {
    try await start(
      workspaces: {
        LocalRoamingWorkspaces(
          service: service,
          control: MuxLocalSession(
            queue: DispatchQueue(label: "swiftmux.roaming.registry")
          )
        )
      },
      configuration: config,
      policy: policy,
      launch: launch,
      transportFactory: transportFactory
    )
  }

  /// Serves roaming through any SwiftMux topology, such as a durable
  /// gateway's workers. `workspaces` is called once the listener is bound.
  package static func start(
    workspaces: @escaping @Sendable () -> any RoamingWorkspaces,
    configuration config: HostConfiguration,
    policy: RegistryPolicy = RegistryPolicy(),
    launch: @escaping @Sendable () -> LaunchSpec = RoamingHost.defaultLaunch
  ) async throws -> RoamingHost {
    try await start(
      workspaces: workspaces,
      configuration: config,
      policy: policy,
      launch: launch,
      transportFactory: makeTransport
    )
  }

  static func start(
    workspaces: @escaping @Sendable () -> any RoamingWorkspaces,
    configuration config: HostConfiguration,
    policy: RegistryPolicy = RegistryPolicy(),
    launch: @escaping @Sendable () -> LaunchSpec = RoamingHost.defaultLaunch,
    transportFactory: @escaping TransportFactory
  ) async throws -> RoamingHost {
    try Task.checkCancellation()
    try ControlDirectory.prepare(config.stateDirectoryURL)
    let target = RegistryTarget()
    let (transport, identity) = try await startTransport(
      config: config,
      now: Date(),
      factory: transportFactory
    ) { connection in target.accept(connection) }
    var control: ControlSocketServer?
    do {
      try Task.checkCancellation()
      let registry = SessionRegistry(
        workspaces: workspaces(),
        identity: identity,
        policy: policy,
        launch: launch
      )
      let bootstrap = BootstrapService(registry: registry)
      let server = try ControlSocketServer(directory: config.stateDirectoryURL)
      { request in
        guard target.registry.withLock({ $0 }) != nil else {
          return
            (try? BootstrapEnvelope.encode(
              BootstrapResponse.failure(.agentUnavailable)
            )) ?? []
        }
        return await bootstrap.respond(toEnvelope: request)
      }
      control = server
      try server.start()
      try Task.checkCancellation()
      registry.startSweeping()
      let host = RoamingHost(
        registry: registry,
        target: target,
        control: server,
        configuration: config,
        transport: transport,
        transportFactory: transportFactory
      )
      host.startRenewing()
      target.registry.withLock { $0 = registry }
      return host
    } catch {
      target.registry.withLock { $0 = nil }
      control?.stop()
      transport.listener.stop()
      throw error
    }
  }

  private static func startTransport(
    config: HostConfiguration,
    now: Date,
    factory: TransportFactory,
    accept: @escaping @Sendable (any RSTConnection) -> Void
  ) async throws -> (Transport, HostIdentity) {
    let (listener, certificate, notValidAfter) = try factory(config, now)
    do {
      try Task.checkCancellation()
      try await listener.start(onConnection: accept)
      try Task.checkCancellation()
    } catch {
      listener.stop()
      throw error
    }
    let identity = HostIdentity(
      endpoint: BootstrapEndpoint(
        host: config.advertisedHost,
        port: listener.port
      ),
      certificate: certificate
    )
    return (
      Transport(listener: listener, notValidAfter: notValidAfter), identity
    )
  }

  /// When the certificate is within its renewal margin, replaces the
  /// listener with one presenting a renewed certificate and advertises it
  /// in new grants. Attached clients are disconnected once; they reattach
  /// with a fresh grant over SSH. Returns whether it renewed.
  /// Calls overlapping an active renewal return false without replacing it.
  @discardableResult
  func renewIfNeeded(now: Date = Date()) async -> Bool {
    guard !Task.isCancelled else { return false }
    let acquired = renewing.withLock { active in
      guard !active else { return false }
      active = true
      return true
    }
    guard acquired else { return false }
    defer { renewing.withLock { $0 = false } }
    let current = transport.withLock { $0 }
    guard
      current.notValidAfter.timeIntervalSince(now)
        <= AppleTransport.HostIdentity.renewalMargin
    else { return false }
    // The new listener binds the same configured port, so the old one
    // goes first.
    current.listener.stop()
    let target = target
    do {
      let (next, identity) = try await Self.startTransport(
        config: configuration,
        now: now,
        factory: transportFactory
      ) { connection in target.accept(connection) }
      transport.withLock { $0 = next }
      registry.replaceIdentity(identity)
      return true
    } catch {
      // Retried at the next check; until then roaming attaches fail and
      // clients keep retrying.
      FileHandle.standardError.write(
        Data("swiftmux-agent: QUIC certificate renewal failed: \(error)\n".utf8)
      )
      return false
    }
  }

  private func startRenewing() {
    let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    source.schedule(
      deadline: .now() + Self.renewalCheckInterval,
      repeating: Self.renewalCheckInterval
    )
    source.setEventHandler { [weak self] in
      guard let self else { return }
      Task { await self.renewIfNeeded() }
    }
    source.resume()
    renewal.withLock { $0 = source }
  }

  /// A login shell with the agent's locale and search path; the shell's
  /// own startup files supply the rest.
  public static func defaultLaunch() -> LaunchSpec {
    let inherited = ProcessInfo.processInfo.environment
    var environment: [String: String] = [:]
    for key in ["PATH", "USER", "LOGNAME", "SHELL", "LANG", "TMPDIR"] {
      if let value = inherited[key] { environment[key] = value }
    }
    environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
    return LaunchSpec(environment: environment)
  }
}

struct IdentityMismatch: Error, CustomStringConvertible {
  var description: String { "host certificate fingerprint mismatch" }
}

/// Creates the QUIC/UDP listener bound to `config.bindAddress`:`port`
/// (ALPN `rst/1`, TLS 1.3, no 0-RTT) and the service-owned TLS
/// certificate it presents. The certificate is independent of the SSH
/// host key and reaches clients only inside SSH-authenticated grants.
func makeTransport(
  config: HostConfiguration,
  now: Date = Date()
) throws -> (any RSTListener, HostCertificate, Date) {
  let advertised = config.advertisedHost
  let isAddress =
    IPv4Address(advertised) != nil || IPv6Address(advertised) != nil
  let identity = try AppleTransport.HostIdentity.loadOrCreate(
    directory: config.stateDirectoryURL.appendingPathComponent("tls"),
    hostnames: isAddress ? [] : [advertised],
    ipAddresses: isAddress ? [advertised] : [],
    now: now
  )
  let bindAll =
    config.bindAddress == "*" || config.bindAddress == "::"
    || config.bindAddress == "0.0.0.0"
  let listener = QUICRSTListener(
    identity: identity,
    configuration: QUICRSTListener.Configuration(
      host: bindAll ? nil : config.bindAddress,
      port: config.port
    )
  )
  guard
    let certificate = HostCertificate(
      der: identity.certificateDER,
      sha256Hex: identity.certificateSHA256
    )
  else { throw IdentityMismatch() }
  return (listener, certificate, identity.notValidAfter)
}
#endif
