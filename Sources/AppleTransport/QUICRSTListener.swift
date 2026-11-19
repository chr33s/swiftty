#if os(macOS)
import Foundation
import Network
import ScreenProtocol
import SessionCore
import Synchronization

/// The `swifttyd` QUIC listener (spec §4, §5.3, §12). Each accepted
/// connection group becomes one `QUICRSTConnection`, reported only after
/// its TLS 1.3 handshake completed with ALPN `rst/1`.
///
/// Application resources are capped independently of QUIC: at most
/// `maxConnections` live connections, and new handshakes are admitted
/// through a token bucket. Excess groups are canceled before any stream
/// is read. Nothing here creates a PTY; authorization (`Attach`) is the
/// caller's job on the control stream.
public final class QUICRSTListener: RSTListener {
  public struct Configuration: Sendable {
    /// Local address to bind; nil binds every interface. Must be
    /// explicit in deployments (spec §4).
    public var host: String?
    /// UDP port; 0 picks an ephemeral port (see `port`).
    public var port: UInt16
    public var maxConnections: Int
    /// Sustained new-handshake rate and burst.
    public var handshakesPerSecond: Double
    public var handshakeBurst: Int
    public var idleTimeout: Duration
    public var alpn: String

    public init(
      host: String? = nil,
      port: UInt16 = 0,
      maxConnections: Int = RSTLimits.maxSessionsPerAccount,
      handshakesPerSecond: Double = 4,
      handshakeBurst: Int = 8,
      idleTimeout: Duration = .seconds(60),
      alpn: String = RSTLimits.alpn
    ) {
      self.host = host
      self.port = port
      self.maxConnections = maxConnections
      self.handshakesPerSecond = handshakesPerSecond
      self.handshakeBurst = handshakeBurst
      self.idleTimeout = idleTimeout
      self.alpn = alpn
    }
  }

  private struct State {
    var listener: NWListener?
    var port: UInt16 = 0
    var stopped = false
    var bucket: TokenBucket
    /// Groups admitted but not yet ready, plus live connections.
    var active: [ObjectIdentifier: QUICRSTConnection] = [:]
    var rejected = 0
  }

  public let configuration: Configuration
  private let identity: HostIdentity
  private let queue = DispatchQueue(label: "rst.quic.listener")
  private let state: Mutex<State>
  private let beforeReportForTesting: (@Sendable (QUICRSTConnection) -> Void)?

  public convenience init(
    identity: HostIdentity,
    configuration: Configuration = .init()
  ) {
    self.init(
      identity: identity,
      configuration: configuration,
      beforeReportForTesting: nil
    )
  }

  init(
    identity: HostIdentity,
    configuration: Configuration,
    beforeReportForTesting: (@Sendable (QUICRSTConnection) -> Void)?
  ) {
    self.identity = identity
    self.configuration = configuration
    self.beforeReportForTesting = beforeReportForTesting
    self.state = Mutex(
      State(
        bucket: TokenBucket(
          capacity: configuration.handshakeBurst,
          refillPerSecond: configuration.handshakesPerSecond
        )
      )
    )
  }

  /// The bound UDP port once `start` returned.
  public var port: UInt16 { state.withLock { $0.port } }

  /// Admitted connection groups (handshaking or live).
  public var activeConnectionCount: Int { state.withLock { $0.active.count } }

  /// Groups refused by the connection cap or handshake rate limit.
  public var rejectedConnectionCount: Int { state.withLock { $0.rejected } }

  /// Binds and starts accepting; returns once the listener is ready.
  public func start(
    onConnection: @escaping @Sendable (any RSTConnection) -> Void
  ) async throws {
    try await start(onConnection: onConnection, beforeReturnForTesting: nil)
  }

  func start(
    onConnection: @escaping @Sendable (any RSTConnection) -> Void,
    beforeReturnForTesting: (@Sendable () async -> Void)?
  ) async throws {
    guard let secIdentity = identity.protocolIdentity else {
      throw RSTTransportError.handshake("identity unavailable")
    }
    let quic = try QUICOptions.server(
      identity: secIdentity,
      alpn: configuration.alpn,
      idleTimeout: configuration.idleTimeout
    )
    let parameters = QUICOptions.parameters(quic)
    let settings = QUICOptions.describe(
      role: "server",
      idleTimeout: configuration.idleTimeout
    )
    guard let nwPort = NWEndpoint.Port(rawValue: configuration.port) else {
      throw RSTTransportError.handshake("invalid port")
    }
    let listener: NWListener
    if let host = configuration.host {
      parameters.requiredLocalEndpoint = .hostPort(
        host: NWEndpoint.Host(host),
        port: nwPort
      )
      listener = try NWListener(using: parameters)
    } else {
      listener = try NWListener(using: parameters, on: nwPort)
    }
    try state.withLock { s in
      guard s.listener == nil, !s.stopped else {
        throw RSTTransportError.closed
      }
      s.listener = listener
    }

    listener.newConnectionGroupHandler = { [weak self] group in
      guard let self else {
        group.cancel()
        return
      }
      self.admit(group, settings: settings, onConnection: onConnection)
    }
    let waiter = OneShot()
    listener.stateUpdateHandler = { [weak self] newState in
      switch newState {
      case .ready:
        if let port = listener.port?.rawValue {
          self?.state.withLock { $0.port = port }
        }
        waiter.resolve(nil)
      case let .failed(error):
        waiter.resolve(error)
        self?.stop()
      case .cancelled: waiter.resolve(RSTTransportError.closed)
      default: break
      }
    }
    do {
      try await waiter.wait(timeout: .seconds(10)) {
        listener.start(queue: queue)
      }
      await beforeReturnForTesting?()
      guard !Task.isCancelled else { throw RSTTransportError.canceled }
      try state.withLock { s in
        guard !s.stopped, s.listener === listener else {
          throw RSTTransportError.closed
        }
      }
    } catch {
      stop()
      throw error
    }
  }

  private func admit(
    _ group: NWConnectionGroup,
    settings: String,
    onConnection: @escaping @Sendable (any RSTConnection) -> Void
  ) {
    let groupQueue = DispatchQueue(label: "rst.quic.server", target: queue)
    let connection = QUICRSTConnection(
      role: .server,
      group: group,
      queue: groupQueue,
      settings: settings
    )
    let key = ObjectIdentifier(connection)
    let admitted = state.withLock { s -> Bool in
      guard !s.stopped, s.active.count < configuration.maxConnections,
        s.bucket.take()
      else {
        s.rejected += 1
        return false
      }
      s.active[key] = connection
      return true
    }
    guard admitted else {
      group.cancel()
      return
    }
    connection.setOnTerminated { [weak self] in
      self?.state.withLock { _ = $0.active.removeValue(forKey: key) }
    }
    connection.attachGroupHandlers()
    let alpn = configuration.alpn
    let reported = Mutex(false)
    let beforeReport = beforeReportForTesting
    group.stateUpdateHandler = { [weak connection] newState in
      guard let connection else { return }
      if case .ready = newState {
        // Defense in depth: the TLS stack already refuses a mismatch.
        guard connection.negotiatedALPN == alpn else {
          connection.close()
          return
        }
        let first = reported.withLock { r -> Bool in
          defer { r = true }
          return !r
        }
        if first {
          beforeReport?(connection)
          guard !connection.isClosed else { return }
          onConnection(connection)
        }
      }
      connection.groupStateChanged(newState)
    }
    group.start(queue: groupQueue)
    // A handshake that never completes must not hold a slot forever.
    groupQueue.asyncAfter(deadline: .now() + .seconds(10)) {
      [weak connection] in
      guard let connection, group.state != .ready else { return }
      connection.close()
    }
  }

  /// Stops accepting and closes every connection. Idempotent.
  public func stop() {
    let (listener, connections) = state.withLock {
      s -> (NWListener?, [QUICRSTConnection]) in
      s.stopped = true
      defer {
        s.listener = nil
        s.active = [:]
      }
      return (s.listener, Array(s.active.values))
    }
    listener?.cancel()
    for connection in connections { connection.close() }
  }
}
#endif
