#if os(macOS)
import Crypto
import Foundation
import NIOCore
import NIOPosix
import ScreenProtocol
import SessionCore
import SSHClient
import SwifttyCore
import Synchronization
import TerminalSurface
import Testing
import TestSupport

/// Real OpenSSH server plus a SwiftMux service with roaming
/// (`swiftmux-agent --roaming-config`), set up by Scripts/test-real-ssh.sh
/// (an apple/container Linux VM whose fixed helper path relays
/// `bootstrap --stdio` to the Mac's agent). Skipped unless that script
/// provides the environment.
struct RealOpenSSHTests {
  struct Environment {
    var host: String
    var port: Int
    var password: String
    var hostKey: String
    var keySeed: [UInt8]

    static var current: Environment? {
      let env = ProcessInfo.processInfo.environment
      guard let host = env["RST_REAL_SSH_HOST"],
        let port = env["RST_REAL_SSH_PORT"].flatMap(Int.init),
        let password = env["RST_REAL_SSH_PASSWORD"],
        let hostKey = env["RST_REAL_SSH_HOSTKEY"],
        let seed = env["RST_REAL_SSH_KEY_HEX"]
          .flatMap({ bytes(fromHex: $0, count: 32, ) })
      else { return nil }
      return Environment(
        host: host,
        port: port,
        password: password,
        hostKey: hostKey,
        keySeed: seed,
      )
    }

    var configuration: SSHClient.SSHClientConfiguration {
      SSHClient.SSHClientConfiguration(
        host: host,
        port: port,
        username: "rst",
        connectTimeout: .seconds(10),
      )
    }

    /// `RST_REAL_SSH_POSIX=1` uses BSD sockets instead of Network.framework.
    var group: (any EventLoopGroup)? {
      ProcessInfo.processInfo.environment["RST_REAL_SSH_POSIX"]?.isEmpty
        == false ? MultiThreadedEventLoopGroup.singleton : nil
    }

    var identity: SSHClient.HostIdentity {
      SSHClient.HostIdentity(host: host, port: port, )!
    }

    var key: Curve25519.Signing.PrivateKey {
      get throws {
        try Curve25519.Signing.PrivateKey(rawRepresentation: keySeed)
      }
    }
  }

  static let enabled = Environment.current != nil

  @Test(.enabled(if: enabled))
  func `unknown OpenSSH host key needs a decision and matches the server`()
    async throws
  {
    let env = try #require(Environment.current)
    let presented = Mutex<String?>(nil)
    let store = InMemoryHostTrustStore()
    // Rejecting fails closed before any credential is sent.
    await #expect(throws: SSHClientError.self) {
      let unexpected = try await SSHConnection.connect(
        configuration: env.configuration,
        credential: .password(env.password),
        trustStore: store,
        trustDecider: ClosureHostTrustDecider { request in
          presented.withLock { $0 = request.fingerprint }
          return .reject
        },
        eventLoopGroup: env.group,
      )
      await unexpected.close()
    }
    let expected = SSHPublicKeyFormat.fingerprint(openSSHPublicKey: env.hostKey)
    #expect(presented.withLock { $0 } == expected)

    // Approving remembers the key; a later connection needs no prompt.
    let connection = try await SSHConnection.connect(
      configuration: env.configuration,
      credential: .password(env.password),
      trustStore: store,
      trustDecider: ClosureHostTrustDecider { _ in .trustAndRemember },
      eventLoopGroup: env.group,
    )
    await connection.close()
    let again = try await SSHConnection.connect(
      configuration: env.configuration,
      credential: .ed25519(env.key),
      trustStore: store,
      trustDecider: RejectUnknownHostKeys(),
      eventLoopGroup: env.group,
    )
    try await RuntimeFixture.withCleanup {
      let result = try await again.execute(
        command: "id -un",
        stdin: [],
        limits: .init(),
      )
      #expect(String(decoding: result.stdout, as: UTF8.self).contains("rst"))
    } cleanup: {
      await again.close()
    }

    // A different key for the same host and port blocks reconnection.
    let wrong = InMemoryHostTrustStore(keys: [
      env.identity: SSHEd25519Key.authorizedKeysLine(
        for: Curve25519.Signing.PrivateKey().publicKey,
      )
    ])
    await #expect(throws: SSHClientError.self) {
      let unexpected = try await SSHConnection.connect(
        configuration: env.configuration,
        credential: .password(env.password),
        trustStore: wrong,
        trustDecider: ClosureHostTrustDecider { _ in .trustAndRemember },
        eventLoopGroup: env.group,
      )
      await unexpected.close()
    }
  }

  @Test(.enabled(if: enabled))
  func `roaming session bootstraps over OpenSSH exec and attaches over QUIC`()
    async throws
  {
    let env = try #require(Environment.current)
    let trusted = InMemoryHostTrustStore(keys: [env.identity: env.hostKey])
    let bootstrapper = try SSHBootstrapper(
      endpoint: SSHEndpoint(
        configuration: env.configuration,
        credential: .ed25519(env.key),
        trustStore: trusted,
      ),
      eventLoopGroup: env.group,
    )
    let display = TerminalSession(presentationColumns: 80, rows: 24)
    let client = RoamingClient(
      bootstrapper: bootstrapper,
      connector: QUICGrantConnector(),
      sink: display,
    )
    let screen = { display.snapshot().text.joined(separator: "\n") }
    try await RuntimeFixture.withCleanup {
      try await client.start(.create(GridSize(columns: 80, rows: 24)))
      try await poll("active") { await client.state == .active }
      try await settle(display)
      _ = await client.submit(.text("echo real-ssh-$((8*8))"))
      _ = await client.submit(.key(SemanticKey(.enter)))
      try await poll("output") { screen().contains("real-ssh-64") }

      // Token renewal path: a fresh SSH `resume` of the same session.
      let id = try #require(await client.status.sessionID)
      let list = try await bootstrapper.bootstrap(
        BootstrapRequest(operation: .list)
      )
      guard case let .sessions(sessions) = list else {
        Issue.record("unexpected \(list)")
        return
      }
      #expect(sessions.contains { $0.sessionID == id })
    } cleanup: {
      await client.close(.terminate)
    }
  }

  @Test(.enabled(if: enabled))
  func `ordinary SSH shell works as the UDP-blocked fallback`() async throws {
    let env = try #require(Environment.current)
    let connection = try await SSHConnection.connect(
      configuration: env.configuration,
      credential: .password(env.password),
      trustStore: InMemoryHostTrustStore(keys: [env.identity: env.hostKey]),
      trustDecider: RejectUnknownHostKeys(),
      eventLoopGroup: env.group,
    )
    try await RuntimeFixture.withCleanup {
      let channel = try await SSHShellByteChannel.open(
        on: connection,
        columns: 80,
        rows: 24,
      )
      let session = TerminalSession(columns: 80, rows: 24)
      let backend = SSHStreamBackend(channel: channel, session: session)
      try await RuntimeFixture.withCleanup {
        backend.start()
        try await settle(session)
        _ = await backend.submit(.text("echo fallback-$((9*9))\n"))
        try await poll("fallback output") {
          session.snapshot().text.joined().contains("fallback-81")
        }
      } cleanup: {
        await backend.close()
      }
    } cleanup: {
      await connection.close()
    }
  }

  @Test(.enabled(if: enabled))
  func `SFTP upload and download round trip through OpenSSH sftp-server`()
    async throws
  {
    let env = try #require(Environment.current)
    let connection = try await SSHConnection.connect(
      configuration: env.configuration,
      credential: .ed25519(env.key),
      trustStore: InMemoryHostTrustStore(keys: [env.identity: env.hostKey]),
      trustDecider: RejectUnknownHostKeys(),
      eventLoopGroup: env.group,
    )
    try await RuntimeFixture.withCleanup {
      let work = FileManager.default.temporaryDirectory.appendingPathComponent(
        "real-sftp-" + UUID().uuidString
      )
      try FileManager.default.createDirectory(
        at: work,
        withIntermediateDirectories: true,
      )
      defer { try? FileManager.default.removeItem(at: work) }
      var payload = [UInt8](repeating: 0, count: 1_000_003)
      var rng = SystemRandomNumberGenerator()
      for i in payload.indices { payload[i] = rng.next() }
      let source = work.appendingPathComponent("source.bin")
      try Data(payload).write(to: source)

      let remote = "/home/rst/files/round-trip-\(UUID().uuidString).bin"
      var upload = try await SFTPTransfers.prepareUpload(
        source: source,
        remotePath: remote,
        stagingDirectory: work,
      )
      // Interrupt after a few chunks, then resume on a fresh client from the
      // last persisted checkpoint, as an app does after a lost connection.
      let first = try await connection.openSFTP()
      let latest = Mutex(upload)
      let checkpoints = Mutex(0)
      let interrupted = Task { [upload] in
        var manifest = upload
        try await SFTPTransfers.upload(&manifest, client: first) { saved in
          latest.withLock { $0 = saved }
          checkpoints.withLock { $0 += 1 }
          if saved.acknowledgedOffset > 0 {
            // Cancel in the writer's task at its first durable prefix.
            // A delayed observer must not accidentally test a completed upload.
            withUnsafeCurrentTask { $0?.cancel() }
          }
        }
      }
      try await RuntimeFixture.withCleanup {
        try await poll("some progress") { checkpoints.withLock { $0 } >= 2 }
        // Retain the late-observer reproduction: interruption must already
        // have happened inside the checkpoint, regardless of this delay.
        try await Task.sleep(for: .seconds(2))
        #expect(interrupted.isCancelled)
        if case .success = await interrupted.result {
          Issue.record("the interrupted upload unexpectedly completed")
        }
        upload = latest.withLock { $0 }
        try #require(upload.acknowledgedOffset > 0)
        try #require(upload.acknowledgedOffset < upload.sourceSize)
        try #require(upload.state == .transferring)
      } cleanup: {
        interrupted.cancel()
        await first.close()
        _ = await interrupted.result
      }
      let resumable = upload
      let second = try await connection.openSFTP()
      try await RuntimeFixture.withCleanup {
        try await SFTPTransfers.upload(&upload, client: second)
        #expect(upload.state == .completed)
        #expect(upload.restartCount == resumable.restartCount)
        #expect(upload.remoteTemporaryPath == resumable.remoteTemporaryPath)

        let destination = work.appendingPathComponent("downloaded.bin")
        var download = try SFTPTransfers.prepareDownload(
          remotePath: remote,
          temporaryDirectory: work,
          destination: destination,
        )
        try await SFTPTransfers.download(&download, client: second)
        #expect(try Data(contentsOf: destination) == Data(payload))
        try await second.remove(remote)
      } cleanup: {
        await second.close()
      }
    } cleanup: {
      await connection.close()
    }
  }

  func poll(
    _ what: String,
    timeout: Duration = .seconds(20),
    _ condition: () async -> Bool,
  ) async throws {
    try await RuntimeFixture.wait(what, timeout: timeout, condition)
  }

  /// Interactive shells may discard typeahead sent before the prompt.
  func settle(_ session: TerminalSession) async throws {
    try await RuntimeFixture.settle {
      session.snapshot().text.joined(separator: "\n")
    }
  }
}
#endif
