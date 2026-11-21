import Crypto
import Foundation
import Synchronization
import NIOCore
import NIOSSH
import Testing

@testable import SSHClient

/// spec.ssh-identity.md §13 (ECDSA authentication) and spec.roaming.md
/// §9.1 (keepalive, IPv4-only transport, health checks).
@Suite(.timeLimit(.minutes(1)))
struct SSHResilienceTests {
  @Test(arguments: [
    SSHKeyAlgorithm.ecdsaP256, .ecdsaP384, .ecdsaP521, .ed25519,
  ])
  func publicKeyAlgorithmsAuthenticate(
    _ algorithm: SSHKeyAlgorithm
  ) async throws {
    let key = SSHSigningKey.generate(algorithm)
    #expect(key.algorithm == algorithm)
    #expect(key.publicKeyLine.hasPrefix(algorithm.rawValue + " "))
    #expect(
      SSHKeyAlgorithm(canonicalPublicKeyLine: key.publicKeyLine) == algorithm
    )
    let authorized = try NIOSSHPublicKey(openSSHPublicKey: key.publicKeyLine)
    let server = try await TestSSHServer.start(authorizedKeys: [authorized])
    defer { Task { await server.shutdown() } }
    let connection = try await server.connect(credential: .publicKey(key))
    #expect(connection.isActive)
    await connection.close()
    // A different key of the same type is refused; nothing else is tried.
    await #expect(throws: SSHClientError.authenticationFailed) {
      _ = try await server.connect(credential: .publicKey(.generate(algorithm)))
    }
  }

  @Test
  func credentialsAndKeysAreRedacted() {
    let key = SSHSigningKey.generate(.ecdsaP256)
    #expect(String(describing: key) == "SSHSigningKey(<redacted>)")
    #expect(
      String(describing: SSHCredential.publicKey(key))
        == "SSHCredential.publicKey(<redacted>)"
    )
    #expect(Mirror(reflecting: key).children.isEmpty)
  }

  @Test
  func authorizedKeysCommentsCannotInjectLines() {
    let line = SSHSigningKey.generate(.ecdsaP256).publicKeyLine
    let result = SSHPublicKeyFormat.authorizedKeysLine(
      line,
      comment: "a\nssh-ed25519 AAAA evil"
    )
    #expect(!result.contains("\n"))
    #expect(result.hasPrefix(line + " a"))
  }

  @Test
  func keepaliveAndIPv4ConnectOverLoopback() async throws {
    let server = try await TestSSHServer.start()
    defer { Task { await server.shutdown() } }
    var configuration = server.configuration()
    configuration.keepalive = SSHKeepalive(idle: 5, interval: 2, count: 2)
    configuration.forceIPv4 = true
    let connection = try await SSHConnection.connect(
      configuration: configuration,
      credential: .password(TestSSHServer.password),
      trustStore: server.trustingStore(),
      trustDecider: RejectUnknownHostKeys()
    )
    #expect(connection.isActive)
    #expect(await connection.probe(timeout: .seconds(5)) == .responsive)
    await connection.close()
    #expect(await connection.probe() == .closed)
  }

  @Test
  func ipv4OnlyRefusesAnIPv6Literal() async throws {
    let server = try await TestSSHServer.start()
    defer { Task { await server.shutdown() } }
    var configuration = server.configuration()
    configuration.host = "::1"
    configuration.forceIPv4 = true
    configuration.connectTimeout = .seconds(3)
    await #expect(throws: (any Error).self) {
      _ = try await SSHConnection.connect(
        configuration: configuration,
        credential: .password(TestSSHServer.password),
        trustStore: server.trustingStore(),
        trustDecider: RejectUnknownHostKeys()
      )
    }
  }

  @Test
  func anUnansweredProbeReportsTheConnection() async throws {
    let server = try await TestSSHServer.start()
    defer { Task { await server.shutdown() } }
    let connection = try await server.connect()
    server.state.faults.withLock { $0.dropAllServerWrites = true }
    let health = await connection.probe(timeout: .milliseconds(300))
    #expect(health != .responsive)
    await connection.close()
  }

  /// A health check cancelled while the server has not yet answered the
  /// probe's channel open (the app cancels its health task on every
  /// inactive-to-active transition) must not close a healthy connection.
  @Test
  func aCancelledProbeLeavesTheConnectionOpen() async throws {
    let server = try await TestSSHServer.start()
    defer { Task { await server.shutdown() } }
    let connection = try await server.connect()
    server.state.faults.withLock { $0.holdSessionChannelOpen = true }
    let check = Task { await connection.probe(timeout: .seconds(10)) }
    let deadline = ContinuousClock.now + .seconds(5)
    while server.state.heldSessionOpens.withLock({ $0.isEmpty }) {
      try #require(ContinuousClock.now < deadline, "probe never opened")
      try await Task.sleep(for: .milliseconds(10))
    }
    check.cancel()
    try await Task.sleep(for: .milliseconds(100))
    #expect(connection.isActive)
    server.state.faults.withLock { $0.holdSessionChannelOpen = false }
    for gate in server.state.heldSessionOpens.withLock({ $0 }) {
      gate.succeed()
    }
    #expect(await check.value == .responsive)
    #expect(connection.isActive)
    await connection.close()
  }

  @Test
  func configurationDecodesWithoutTheNewFields() throws {
    let old = SSHClient.SSHClientConfiguration(host: "mac", username: "me")
    var json =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(old))
      as! [String: Any]
    json["forceIPv4"] = nil
    json["keepalive"] = nil
    let decoded = try JSONDecoder()
      .decode(
        SSHClient.SSHClientConfiguration.self,
        from: JSONSerialization.data(withJSONObject: json)
      )
    #expect(decoded == old)
    #expect(!decoded.forceIPv4)
    #expect(decoded.keepalive == nil)
  }
}
