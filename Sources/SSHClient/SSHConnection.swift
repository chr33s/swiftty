import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Synchronization

#if canImport(Network)
import Network
import NIOTransportServices
#endif

/// Explicit host, port and username profile (spec §2). No OpenSSH
/// configuration is evaluated.
public struct SSHClientConfiguration: Hashable, Sendable, Codable {
  public var host: String
  public var port: Int
  public var username: String
  /// Bound on TCP connect plus key exchange and authentication.
  public var connectTimeout: Duration
  /// Host-key fingerprints (OpenSSH `SHA256:` form) the server must
  /// present, from a pairing code the user confirmed. Checked before the
  /// trust store and before any credential, so a known key outside this
  /// set still blocks. `nil` applies only the trust store.
  public var expectedHostKeyFingerprints: Set<String>?
  /// Restricts name resolution and connection to IPv4 (spec.roaming.md
  /// §9.1). Off by default.
  public var forceIPv4: Bool
  /// TCP keepalive probes, so an idle connection through a NAT or a
  /// suspended peer is detected by the transport. `nil` disables them.
  public var keepalive: SSHKeepalive?

  public init(
    host: String,
    port: Int = 22,
    username: String,
    connectTimeout: Duration = .seconds(20),
    expectedHostKeyFingerprints: Set<String>? = nil,
    forceIPv4: Bool = false,
    keepalive: SSHKeepalive? = nil
  ) {
    self.host = host
    self.port = port
    self.username = username
    self.connectTimeout = connectTimeout
    self.expectedHostKeyFingerprints = expectedHostKeyFingerprints
    self.forceIPv4 = forceIPv4
    self.keepalive = keepalive
  }

  private enum CodingKeys: String, CodingKey {
    case host, port, username, connectTimeout, expectedHostKeyFingerprints
    case forceIPv4, keepalive
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    host = try c.decode(String.self, forKey: .host)
    port = try c.decode(Int.self, forKey: .port)
    username = try c.decode(String.self, forKey: .username)
    connectTimeout = try c.decode(Duration.self, forKey: .connectTimeout)
    expectedHostKeyFingerprints = try c.decodeIfPresent(
      Set<String>.self,
      forKey: .expectedHostKeyFingerprints
    )
    forceIPv4 = try c.decodeIfPresent(Bool.self, forKey: .forceIPv4) ?? false
    keepalive = try c.decodeIfPresent(SSHKeepalive.self, forKey: .keepalive)
  }

  /// Identity host trust is scoped to; `nil` if host or port is invalid.
  public var hostIdentity: HostIdentity? {
    HostIdentity(host: host, port: port)
  }

  var isValidUsername: Bool {
    !username.isEmpty && username.utf8.count <= 256
      && username.unicodeScalars.allSatisfy {
        $0.value >= 0x20 && $0.value != 0x7F
      }
  }
}

/// TCP keepalive timing (spec.roaming.md §9.1). The transport closes the
/// connection after `count` unanswered probes, which the shell then
/// reports as lost.
public struct SSHKeepalive: Hashable, Sendable, Codable {
  /// Idle time before the first probe, in seconds.
  public var idle: Int
  /// Time between unanswered probes, in seconds.
  public var interval: Int
  public var count: Int

  public init(idle: Int = 30, interval: Int = 10, count: Int = 3) {
    self.idle = max(1, idle)
    self.interval = max(1, interval)
    self.count = max(1, count)
  }

  public static let standard = SSHKeepalive()
}

/// A user credential. Descriptions are redacted; never log the payload.
public enum SSHCredential: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  case password(String)
  /// An Ed25519, ECDSA or Secure Enclave key (spec.ssh-identity.md §13).
  case publicKey(SSHSigningKey)

  /// App-managed Ed25519 key (see `Ed25519KeyStore`).
  public static func ed25519(_ key: Curve25519.Signing.PrivateKey) -> Self {
    .publicKey(.ed25519(key))
  }

  public var description: String {
    switch self {
    case .password: "SSHCredential.password(<redacted>)"
    case .publicKey: "SSHCredential.publicKey(<redacted>)"
    }
  }
  public var debugDescription: String { description }
}

/// Offers the single configured credential once; a rejection ends
/// authentication.
final class CredentialOfferDelegate: NIOSSHClientUserAuthenticationDelegate,
  Sendable
{
  let username: String
  /// `nil` offers nothing: host-key verification only.
  let credential: SSHCredential?
  let attempt: ConnectionAttempt
  let offered = Mutex(false)
  let exhausted = Mutex(false)

  init(username: String, credential: SSHCredential?, attempt: ConnectionAttempt)
  {
    self.username = username
    self.credential = credential
    self.attempt = attempt
  }

  func nextAuthenticationType(
    availableMethods: NIOSSHAvailableUserAuthenticationMethods,
    nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
  ) {
    if let error = attempt.failure {
      nextChallengePromise.fail(error)
      return
    }
    let first = offered.withLock { wasOffered in
      defer { wasOffered = true }
      return !wasOffered
    }
    let offer: NIOSSHUserAuthenticationOffer.Offer? =
      switch credential {
      case let .password(password) where availableMethods.contains(.password):
        .password(.init(password: password))
      case let .publicKey(key) where availableMethods.contains(.publicKey):
        .privateKey(.init(privateKey: key.nioPrivateKey))
      default: nil
      }
    guard first, let offer else {
      exhausted.withLock { $0 = true }
      nextChallengePromise.fail(SSHClientError.authenticationFailed)
      return
    }
    nextChallengePromise.succeed(
      NIOSSHUserAuthenticationOffer(
        username: username,
        serviceName: "",
        offer: offer
      )
    )
  }
}

/// Completes the authentication promise and closes the connection on
/// any pipeline error. Runs on the connection's event loop.
final class ConnectionEventsHandler: ChannelInboundHandler {
  typealias InboundIn = Any

  let authenticated: EventLoopPromise<Void>
  let verifier: HostKeyVerifier
  let auth: CredentialOfferDelegate
  private var completed = false
  private var firstError: (any Error)?

  init(
    authenticated: EventLoopPromise<Void>,
    verifier: HostKeyVerifier,
    auth: CredentialOfferDelegate
  ) {
    self.authenticated = authenticated
    self.verifier = verifier
    self.auth = auth
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if event is UserAuthSuccessEvent, !completed {
      completed = true
      authenticated.succeed()
    }
    context.fireUserInboundEventTriggered(event)
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    if firstError == nil { firstError = error }
    context.close(promise: nil)
  }

  func handlerAdded(context: ChannelHandlerContext) {
    // NIOSSHHandler does not forward channelInactive, so observe the
    // close future instead.
    context.channel.closeFuture.assumeIsolated()
      .whenComplete { _ in self.connectionClosed() }
  }

  private func connectionClosed() {
    verifier.connectionClosed()
    if !completed {
      completed = true
      authenticated.fail(firstError ?? SSHClientError.connectionClosed)
    }
  }
}

/// An authenticated SSH connection. Channels (exec, shell, SFTP) are
/// multiplexed over it; closing it closes them all.
///
/// Thread-safe: every NIO object is touched only on its event loop.
public final class SSHConnection: Sendable {
  public let configuration: SSHClientConfiguration
  public let hostIdentity: HostIdentity
  /// OpenSSH `SHA256:` fingerprint of the verified host key.
  public let hostKeyFingerprint: String
  let channel: any Channel

  init(
    configuration: SSHClientConfiguration,
    hostIdentity: HostIdentity,
    hostKeyFingerprint: String,
    channel: any Channel
  ) {
    self.configuration = configuration
    self.hostIdentity = hostIdentity
    self.hostKeyFingerprint = hostKeyFingerprint
    self.channel = channel
  }

  /// The default client group: Network.framework on Apple platforms.
  public static var defaultEventLoopGroup: any EventLoopGroup {
    #if canImport(Network)
    NIOTSEventLoopGroup.singleton
    #else
    MultiThreadedEventLoopGroup.singleton
    #endif
  }

  /// The group for connections authenticated by a Secure Enclave key when
  /// the caller names none. NIOSSH signs on the channel's event loop, and a
  /// key that requires user presence blocks that thread until Face ID,
  /// Touch ID or the passcode finishes. One loop of its own keeps the
  /// prompt from stalling every other SSH and SFTP channel on the shared
  /// default group.
  public static let secureEnclaveEventLoopGroup: any EventLoopGroup = {
    #if canImport(Network)
    NIOTSEventLoopGroup(loopCount: 1)
    #else
    MultiThreadedEventLoopGroup(numberOfThreads: 1)
    #endif
  }()

  /// Connects, verifies the host key against `trustStore` (asking
  /// `trustDecider` about unknown keys) and only then authenticates.
  ///
  /// - Throws: `SSHClientError.hostKeyChanged` for a mismatching key
  ///   (fails closed), `.hostKeyRejected`, `.authenticationFailed`,
  ///   `.connectTimeout`, or a transport error.
  public static func connect(
    configuration: SSHClientConfiguration,
    credential: SSHCredential,
    trustStore: any HostTrustStore,
    trustDecider: any HostTrustDecider,
    eventLoopGroup: (any EventLoopGroup)? = nil
  ) async throws -> SSHConnection {
    let outcome = try await establish(
      configuration: configuration,
      credential: credential,
      trustStore: trustStore,
      trustDecider: trustDecider,
      eventLoopGroup: eventLoopGroup
    )
    guard case let .connected(connection) = outcome else {
      throw SSHClientError.connectionClosed
    }
    return connection
  }

  /// Connects and verifies the host key exactly as `connect` does
  /// (asking `trustDecider` about an unknown key), then disconnects
  /// without offering any credential. Lets a client settle trust before
  /// it asks the user for a password.
  ///
  /// - Returns: the verified key's OpenSSH `SHA256:` fingerprint.
  /// - Throws: the trust errors of `connect`, `.connectTimeout`, or a
  ///   transport error.
  public static func verifyHostKey(
    configuration: SSHClientConfiguration,
    trustStore: any HostTrustStore,
    trustDecider: any HostTrustDecider,
    eventLoopGroup: (any EventLoopGroup)? = nil
  ) async throws -> String {
    let outcome = try await establish(
      configuration: configuration,
      credential: nil,
      trustStore: trustStore,
      trustDecider: trustDecider,
      eventLoopGroup: eventLoopGroup
    )
    switch outcome {
    case let .verified(fingerprint): return fingerprint
    case let .connected(connection):
      // A server that accepts "none" authentication.
      await connection.close()
      return connection.hostKeyFingerprint
    }
  }

  static func defaultGroup(for credential: SSHCredential?) -> any EventLoopGroup
  {
    #if canImport(Darwin)
    if case .publicKey(.secureEnclaveP256)? = credential {
      return secureEnclaveEventLoopGroup
    }
    #endif
    return defaultEventLoopGroup
  }

  private enum Outcome {
    case connected(SSHConnection)
    /// Host key verified; no credential offered, connection closed.
    case verified(String)
  }

  private static func establish(
    configuration: SSHClientConfiguration,
    credential: SSHCredential?,
    trustStore: any HostTrustStore,
    trustDecider: any HostTrustDecider,
    eventLoopGroup: (any EventLoopGroup)?
  ) async throws -> Outcome {
    guard let identity = configuration.hostIdentity else {
      throw SSHClientError.invalidConfiguration("host or port")
    }
    guard configuration.isValidUsername else {
      throw SSHClientError.invalidConfiguration("username")
    }
    try Task.checkCancellation()
    let loop = (eventLoopGroup ?? defaultGroup(for: credential)).next()
    let timeout = TimeAmount(clamping: configuration.connectTimeout)
    let attempt = ConnectionAttempt(deadline: .now() + timeout)
    let timer = loop.scheduleTask(deadline: attempt.deadline) {
      attempt.abort(SSHClientError.connectTimeout)
    }
    defer { timer.cancel() }
    return try await withTaskCancellationHandler {
      do {
        let outcome = try await performEstablishment(
          configuration: configuration,
          identity: identity,
          credential: credential,
          trustStore: trustStore,
          trustDecider: trustDecider,
          loop: loop,
          timeout: timeout,
          attempt: attempt
        )
        try Task.checkCancellation()
        if case let .connected(connection) = outcome {
          try attempt.finish(keeping: connection.channel)
        } else {
          try attempt.finish(keeping: nil)
        }
        return outcome
      } catch {
        attempt.abort(error)
        if Task.isCancelled { throw CancellationError() }
        throw attempt.failure ?? error
      }
    } onCancel: {
      attempt.abort(CancellationError())
    }
  }

  private static func performEstablishment(
    configuration: SSHClientConfiguration,
    identity: HostIdentity,
    credential: SSHCredential?,
    trustStore: any HostTrustStore,
    trustDecider: any HostTrustDecider,
    loop: any EventLoop,
    timeout: TimeAmount,
    attempt: ConnectionAttempt
  ) async throws -> Outcome {
    try Task.checkCancellation()
    let initializer: @Sendable (any Channel) -> EventLoopFuture<Void> = {
      channel in
      channel.eventLoop.makeCompletedFuture {
        try attempt.register(channel)
        let verifier = HostKeyVerifier(
          host: identity,
          store: trustStore,
          decider: trustDecider,
          expected: configuration.expectedHostKeyFingerprints
        )
        let auth = CredentialOfferDelegate(
          username: configuration.username,
          credential: credential,
          attempt: attempt
        )
        let authenticated = channel.eventLoop.makePromise(of: Void.self)

        var client = NIOSSH.SSHClientConfiguration(
          userAuthDelegate: auth,
          serverAuthDelegate: verifier
        )
        // Smallest RFC 4253 packet size: bounds the per-channel receive
        // window (64 packets) that backs shell read credit.
        client.maximumPacketSize = 32 * 1024
        let ssh = NIOSSHHandler(
          role: .client(client),
          allocator: channel.allocator,
          inboundChildChannelInitializer: nil
        )
        do {
          try channel.pipeline.syncOperations.addHandler(ssh)
          try channel.pipeline.syncOperations.addHandler(
            ConnectionEventsHandler(
              authenticated: authenticated,
              verifier: verifier,
              auth: auth
            )
          )
        } catch {
          authenticated.fail(error)
          throw error
        }
      }
    }

    let channel: any Channel
    do {
      let connecting = try connectChannel(
        loop: loop,
        configuration: configuration,
        timeout: timeout,
        initializer: initializer
      )
      channel = try await attempt.wait(for: connecting) {
        $0.close(promise: nil)
      }
    } catch {
      if Task.isCancelled { throw CancellationError() }
      if case ChannelError.connectTimeout = error {
        throw SSHClientError.connectTimeout
      }
      throw error
    }

    // A failed Happy Eyeballs candidate must not settle the winner's handshake.
    let (authenticated, verifier, auth) = try await attempt.wait(
      for: channel.eventLoop.submit {
        let events = try channel.pipeline.syncOperations.handler(
          type: ConnectionEventsHandler.self
        )
        return (events.authenticated, events.verifier, events.auth)
      }
    )
    do {
      try Task.checkCancellation()
      try await attempt.wait(for: authenticated.futureResult)
      try Task.checkCancellation()
    } catch {
      channel.close(promise: nil)
      if let error = attempt.failure { throw error }
      if Task.isCancelled { throw CancellationError() }
      if let trust = verifier.failure.withLock({ $0 }) { throw trust }
      if credential == nil, let line = verifier.accepted.withLock({ $0 }),
        let fingerprint = SSHPublicKeyFormat.fingerprint(openSSHPublicKey: line)
      {
        return .verified(fingerprint)
      }
      if auth.exhausted.withLock({ $0 }) {
        throw SSHClientError.authenticationFailed
      }
      throw error
    }

    let fingerprint = verifier.accepted.withLock { $0 }
      .flatMap { SSHPublicKeyFormat.fingerprint(openSSHPublicKey: $0) }
    guard let fingerprint else {
      // Authentication cannot succeed without a verified host key.
      channel.close(promise: nil)
      throw SSHClientError.connectionClosed
    }
    return .connected(
      SSHConnection(
        configuration: configuration,
        hostIdentity: identity,
        hostKeyFingerprint: fingerprint,
        channel: channel
      )
    )
  }

  private static func connectChannel(
    loop: any EventLoop,
    configuration: SSHClientConfiguration,
    timeout: TimeAmount,
    initializer: @escaping @Sendable (any Channel) -> EventLoopFuture<Void>
  ) throws -> EventLoopFuture<any Channel> {
    let host = configuration.host
    let port = configuration.port
    #if canImport(Network)
    if let bootstrap = NIOTSConnectionBootstrap(validatingGroup: loop) {
      let tcp = NWProtocolTCP.Options()
      tcp.noDelay = true
      if let keepalive = configuration.keepalive {
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = keepalive.idle
        tcp.keepaliveInterval = keepalive.interval
        tcp.keepaliveCount = keepalive.count
      }
      let forceIPv4 = configuration.forceIPv4
      return bootstrap.connectTimeout(timeout).tcpOptions(tcp)
        .configureNWParameters { parameters in
          guard forceIPv4,
            let ip = parameters.defaultProtocolStack.internetProtocol
              as? NWProtocolIP.Options
          else { return }
          ip.version = .v4
        }
        .channelInitializer(initializer).connect(host: host, port: port)
    }
    #endif
    guard let bootstrap = ClientBootstrap(validatingGroup: loop) else {
      throw SSHClientError.invalidConfiguration("event loop group")
    }
    var configured = bootstrap.connectTimeout(timeout)
      .channelOption(.socketOption(.tcp_nodelay), value: 1)
    if configuration.keepalive != nil {
      configured = configured.channelOption(
        .socketOption(.so_keepalive),
        value: 1
      )
    }
    // Address-family selection needs Network.framework, which every Apple
    // client uses. Refuse rather than silently connecting over IPv6.
    if configuration.forceIPv4 {
      throw SSHClientError.invalidConfiguration("IPv4-only transport")
    }
    return configured.channelInitializer(initializer)
      .connect(host: host, port: port)
  }

  public var isActive: Bool { channel.isActive }

  /// Completes when the connection closes for any reason.
  public var closeFuture: EventLoopFuture<Void> { channel.closeFuture }

  /// Closes the connection and every channel on it. Idempotent.
  public func close() async {
    channel.close(promise: nil)
    try? await channel.closeFuture.get()
  }

}

extension TimeAmount {
  init(clamping duration: Duration) {
    let (seconds, attoseconds) = duration.components
    let nanos = seconds.multipliedReportingOverflow(by: 1_000_000_000)
    let total = nanos.partialValue.addingReportingOverflow(
      attoseconds / 1_000_000_000
    )
    self = .nanoseconds(
      nanos.overflow || total.overflow
        ? (seconds < 0 ? .min : .max) : total.partialValue
    )
  }
}
