import Foundation
import NIOCore
import ScreenProtocol
import SSHClient
import Synchronization

/// Fixed installed helper path (spec §5.1). Never interpolated from input.
public let defaultHelperPath = "/usr/local/libexec/swifttyd"

/// How to reach and authenticate to the Mac over SSH.
public struct SSHEndpoint: Sendable {
  public var configuration: SSHClient.SSHClientConfiguration
  /// A fixed credential, or one resolved again for every connection so an
  /// application-held key is released between bootstraps
  /// (spec.ssh-identity.md §6.1).
  public var credentialSource: CredentialSource
  public var trustStore: any HostTrustStore
  /// Asked only for an unknown key. Automatic reconnects should use
  /// `RejectUnknownHostKeys` so they never prompt.
  public var trustDecider: any HostTrustDecider
  public var helperPath: String

  public enum CredentialSource: Sendable {
    case fixed(SSHCredential)
    case resolved(@Sendable () async throws -> SSHCredential)
  }

  /// A `.resolved` credential could not be produced. Fails closed before
  /// any connection is made.
  public struct CredentialUnavailable: Error, Hashable, Sendable {
    public init() {}
  }

  public init(
    configuration: SSHClient.SSHClientConfiguration,
    credential: SSHCredential,
    trustStore: any HostTrustStore,
    trustDecider: any HostTrustDecider = RejectUnknownHostKeys(),
    helperPath: String = defaultHelperPath
  ) {
    self.init(
      configuration: configuration,
      credentialSource: .fixed(credential),
      trustStore: trustStore,
      trustDecider: trustDecider,
      helperPath: helperPath
    )
  }

  public init(
    configuration: SSHClient.SSHClientConfiguration,
    credentialSource: CredentialSource,
    trustStore: any HostTrustStore,
    trustDecider: any HostTrustDecider = RejectUnknownHostKeys(),
    helperPath: String = defaultHelperPath
  ) {
    self.configuration = configuration
    self.credentialSource = credentialSource
    self.trustStore = trustStore
    self.trustDecider = trustDecider
    self.helperPath = helperPath
  }

  func connect(
    eventLoopGroup: (any EventLoopGroup)?
  ) async throws -> SSHConnection {
    let credential: SSHCredential
    switch credentialSource {
    case .fixed(let fixed): credential = fixed
    case .resolved(let resolve):
      do { credential = try await resolve() } catch is CancellationError {
        throw CancellationError()
      } catch { throw CredentialUnavailable() }
    }
    return try await SSHConnection.connect(
      configuration: configuration,
      credential: credential,
      trustStore: trustStore,
      trustDecider: trustDecider,
      eventLoopGroup: eventLoopGroup
    )
  }
}

/// Runs `swifttyd bootstrap --stdio` on a fresh SSH connection per
/// request, so every grant follows a host-key check and authentication.
public struct SSHBootstrapper: RemoteBootstrapper {
  public var endpoint: SSHEndpoint
  public var eventLoopGroup: (any EventLoopGroup)?

  public init(
    endpoint: SSHEndpoint,
    eventLoopGroup: (any EventLoopGroup)? = nil
  ) {
    self.endpoint = endpoint
    self.eventLoopGroup = eventLoopGroup
  }

  public func bootstrap(
    _ request: BootstrapRequest
  ) async throws -> BootstrapResponse {
    let connection: SSHConnection
    do {
      connection = try await endpoint.connect(eventLoopGroup: eventLoopGroup)
    } catch { throw Self.map(error) }
    do {
      let response = try await connection.runBootstrap(
        helperPath: endpoint.helperPath,
        request: request
      )
      await connection.close()
      return response
    } catch {
      await connection.close()
      throw Self.map(error)
    }
  }

  static func map(_ error: any Error) -> RemoteBootstrapError {
    if error is SSHEndpoint.CredentialUnavailable {
      return .credentialUnavailable
    }
    guard let error = error as? SSHClientError else { return .unreachable }
    switch error {
    case .hostKeyChanged, .hostKeyRejected, .hostKeyMismatch,
      .trustStoreUnavailable:
      return .hostKeyRejected
    case .authenticationFailed: return .authenticationFailed
    case .bootstrapProtocol, .bootstrapFailed, .invalidHelperPath,
      .outputLimitExceeded:
      return .protocolViolation
    default: return .unreachable
    }
  }
}

/// `TerminalByteChannel` over an interactive SSH shell channel.
///
/// Sendable: handler, backlog and exit state live in the `state` Mutex;
/// `channel` is assigned once in `open` before the adapter is returned and
/// is only read afterwards. The adapter retains the channel until it ends.
public final class SSHShellByteChannel: TerminalByteChannel, @unchecked Sendable
{
  private enum QueuedEvent {
    case output([UInt8])
    case closed
  }

  private struct State {
    var handler: TerminalChannelHandler?
    var backlog: [QueuedEvent] = []
    var draining = false
    var closed = false
    var exitStatus: TerminalChannelExit?
    var finished = false
  }

  private let state = Mutex(State())
  private var channel: SSHShellChannel?

  init() {}

  /// Opens a PTY shell. Output is held until `start` and credit arrive.
  public static func open(
    on connection: SSHConnection,
    columns: Int,
    rows: Int
  ) async throws -> SSHShellByteChannel {
    let adapter = SSHShellByteChannel()
    adapter.channel = try await connection.openShell(
      columns: columns,
      rows: rows,
      initialReadCredit: 0
    ) { [weak adapter] event in adapter?.receive(event) }
    return adapter
  }

  func receive(_ event: SSHShellEvent) {
    let drain = state.withLock { s in
      guard !s.closed else { return false }
      switch event {
      case let .exitStatus(code):
        s.exitStatus = .exited(Int32(truncatingIfNeeded: code))
        return false
      case let .exitSignal(name):
        s.exitStatus = .signaled(name)
        return false
      case let .output(bytes): s.backlog.append(.output(bytes))
      case .closed:
        s.closed = true
        s.backlog.append(.closed)
      }
      guard s.handler != nil, !s.draining else { return false }
      s.draining = true
      return true
    }
    if drain { drainEvents() }
  }

  /// Retained delivery work, excluding the single coalesced exit reason.
  var pendingEventCount: Int { state.withLock { $0.backlog.count } }

  /// Exactly one caller drains events. Concurrent or reentrant arrivals
  /// join the backlog; callbacks run without holding the state lock.
  private func drainEvents() {
    while true {
      let batch = state.withLock {
        s -> ([QueuedEvent], TerminalChannelHandler)? in
        guard let handler = s.handler, !s.backlog.isEmpty else {
          s.draining = false
          return nil
        }
        let events = s.backlog
        s.backlog = []
        return (events, handler)
      }
      guard let (events, handler) = batch else { return }
      for event in events { dispatch(event, to: handler) }
    }
  }

  private func dispatch(
    _ event: QueuedEvent,
    to handler: TerminalChannelHandler
  ) {
    switch event {
    case let .output(bytes): handler.onOutput(bytes)
    case .closed:
      let exit = state.withLock { s -> TerminalChannelExit? in
        guard !s.finished else { return nil }
        s.finished = true
        return s.exitStatus ?? .disconnected
      }
      if let exit { handler.onExit(exit) }
    }
  }

  public func start(_ handler: TerminalChannelHandler) {
    let drain = state.withLock { s in
      guard s.handler == nil else { return false }
      s.handler = handler
      guard !s.backlog.isEmpty else { return false }
      s.draining = true
      return true
    }
    if drain { drainEvents() }
  }

  public func grantCredit(_ bytes: Int) { channel?.grantReadCredit(bytes) }

  public func write(_ bytes: [UInt8]) async throws {
    guard let channel else { throw SSHClientError.connectionClosed }
    var offset = 0
    let limit = 64 * 1024
    while offset < bytes.count {
      let end = min(offset + limit, bytes.count)
      try await channel.write(Array(bytes[offset ..< end]))
      offset = end
    }
  }

  public func resize(columns: Int, rows: Int) async throws {
    try await channel?.resize(columns: columns, rows: rows)
  }

  public func close() async { await channel?.close() }
}
