#if os(macOS)
import AppleTransport
import Darwin
import Foundation
import ScreenProtocol
import SessionCore
import SwiftMuxProtocol
import SwiftMuxService
import Synchronization
@testable import TerminalHost
import TestSupport
import Testing

struct HostTestTimeout: Error, CustomStringConvertible {
  var what: String
  var description: String { "timed out waiting for \(what)" }
}

/// Polls `body` until it returns a value or `timeout` passes.
@discardableResult
func hostEventually<T>(
  _ what: String,
  timeout: Duration = .seconds(10),
  _ body: () throws -> T?
) async throws -> T {
  let deadline = ContinuousClock.now + timeout
  while true {
    if let value = try body() { return value }
    guard ContinuousClock.now < deadline else {
      throw HostTestTimeout(what: what)
    }
    try await Task.sleep(for: .milliseconds(20))
  }
}

/// `hostEventually` for conditions that must await.
@discardableResult
func hostEventuallyAsync<T>(
  _ what: String,
  timeout: Duration = .seconds(10),
  _ body: () async throws -> T?
) async throws -> T {
  let deadline = ContinuousClock.now + timeout
  while true {
    if let value = try await body() { return value }
    guard ContinuousClock.now < deadline else {
      throw HostTestTimeout(what: what)
    }
    try await Task.sleep(for: .milliseconds(20))
  }
}

/// A real self-signed certificate so grants carry an SPKI pin.
private let testCertificateDER: Data = {
  do {
    return try AppleTransport.HostIdentity.generate(ipAddresses: ["127.0.0.1"])
      .certificateDER
  } catch { fatalError("test certificate: \(error)") }
}()

func testIdentity() -> TerminalHost.HostIdentity {
  TerminalHost.HostIdentity(
    endpoint: BootstrapEndpoint(host: "127.0.0.1", port: 51222),
    certificate: HostCertificate(der: testCertificateDER)
  )
}

/// A short private temporary directory (Unix socket paths are limited).
func makeTemporaryDirectory() throws -> URL {
  var template = Array("/tmp/rsth.XXXXXX".utf8CString)
  let created = template.withUnsafeMutableBufferPointer {
    mkdtemp($0.baseAddress!)
  }
  if created != nil {
    return URL(
      fileURLWithPath: String(
        decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
        as: UTF8.self
      )
    )
  }
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "rsth-\(UUID().uuidString.prefix(8))"
  )
  try FileManager.default.createDirectory(
    at: url,
    withIntermediateDirectories: false,
    attributes: [.posixPermissions: 0o700]
  )
  return url
}

/// `/bin/sh`, interactive by default, or running `script` with `-c`.
func shellLaunch(
  _ script: String? = nil,
  in directory: URL? = nil
) -> LaunchSpec {
  let home = directory?.path ?? NSTemporaryDirectory()
  return LaunchSpec(
    command: script.map { ["/bin/sh", "-c", $0] } ?? ["/bin/sh"],
    workingDirectory: home,
    environment: [
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color",
      "HOME": home, "PS1": "$ ", "LANG": "en_US.UTF-8",
    ]
  )
}

/// The pane launcher built alongside the tests (`swift build` builds it).
func launcherPath() throws -> String { try NativeTestProducts.launcherPath() }

/// A private SwiftMux service: the PTY owner behind every registry.
func makeService() throws -> MuxService {
  try MuxService(
    configuration: MuxServiceConfiguration(launcherPath: try launcherPath())
  )
}

/// The shell PID of a session's active pane.
func shellPID(
  _ registry: SessionRegistry,
  _ session: RoamingSession
) async -> pid_t? {
  guard let pane = session.diagnostics.activePane,
    let pid = await registry.service.panePID(pane), pid > 0
  else { return nil }
  return pid
}

func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

/// Builds a registry over a fresh service, runs `body`, then ends every
/// workspace and awaits the owned service's process barrier on every outcome.
func withRegistry(
  policy: RegistryPolicy = RegistryPolicy(),
  launch: @escaping @Sendable () -> LaunchSpec = { shellLaunch() },
  _ body: (SessionRegistry) async throws -> Void
) async throws {
  let registry = SessionRegistry(
    service: try makeService(),
    identity: testIdentity(),
    policy: policy,
    launch: launch
  )
  try await RuntimeFixture.withCleanup(
    { try await body(registry) },
    cleanup: {
      registry.stopSweeping()
      await withCheckedContinuation { continuation in
        registry.service.prepareToExit { continuation.resume() }
      }
    }
  )
}

/// The client end of an in-memory RST/1 connection served by a registry.
final class TestClient: @unchecked Sendable {
  private struct State {
    var reader = ControlRecordReader()
    var messages: [ControlMessage] = []
    var snapshots: [ScreenSnapshot] = []
    var closed = false
    var badFrames = 0
  }

  let connection: InMemoryRSTConnection
  private let state = Mutex(State())
  let autoAck: Bool

  init(_ registry: SessionRegistry, autoAck: Bool = true) {
    let (client, server) = InMemoryRSTConnection.pair()
    connection = client
    self.autoAck = autoAck
    registry.accept(server)
    client.start(
      RSTConnectionHandler(
        onControl: { [self] bytes in
          state.withLock { s in
            if let messages = try? s.reader.append(bytes) {
              s.messages += messages
            }
          }
        },
        onSnapshot: { [self] bytes in
          guard let snapshot = try? SnapshotFrame.decode(bytes) else {
            state.withLock { $0.badFrames += 1 }
            return
          }
          state.withLock { s in
            s.snapshots.append(snapshot)
            if s.snapshots.count > 8 { s.snapshots.removeFirst() }
          }
          if autoAck {
            try? await send(
              .screenAck(
                epoch: snapshot.attachmentEpoch,
                screenRevision: snapshot.screenRevision
              )
            )
          }
        },
        onClosed: { [self] _ in state.withLock { $0.closed = true } }
      )
    )
  }

  func send(_ message: ControlMessage) async throws {
    try await connection.sendControl(ControlRecord.encode(message))
  }

  var messages: [ControlMessage] { state.withLock { $0.messages } }
  var isClosed: Bool { state.withLock { $0.closed } }
  var badFrames: Int { state.withLock { $0.badFrames } }
  var latestSnapshot: ScreenSnapshot? { state.withLock { $0.snapshots.last } }

  func message(
    _ what: String,
    timeout: Duration = .seconds(10),
    where predicate: (ControlMessage) -> Bool
  ) async throws -> ControlMessage {
    try await hostEventually(what, timeout: timeout) {
      messages.first(where: predicate)
    }
  }

  /// The newest retained snapshot matching `predicate`. With `after`, only
  /// snapshots captured later than it count, so a retained frame from
  /// before a request cannot stand in for the request's result.
  func snapshot(
    _ what: String,
    after: ScreenSnapshot? = nil,
    timeout: Duration = .seconds(10),
    where predicate: (ScreenSnapshot) -> Bool
  ) async throws -> ScreenSnapshot {
    let floor = after?.screenRevision
    return try await hostEventually(what, timeout: timeout) {
      state.withLock { state in
        state.snapshots.last { shot in
          (floor.map { shot.screenRevision > $0 } ?? true) && predicate(shot)
        }
      }
    }
  }

  func attach(
    _ grant: BootstrapGrant,
    token: ApplicationToken? = nil,
    instance: SessionCore.ServerInstanceID? = nil
  ) async throws {
    try await send(
      .attach(
        .init(
          sessionID: grant.sessionID,
          serverInstanceID: instance ?? grant.serverInstanceID,
          writerID: grant.writerID,
          applicationToken: token ?? grant.applicationToken
        )
      )
    )
  }

  /// Attaches and returns `Attached`.
  func attached(_ grant: BootstrapGrant) async throws -> ControlMessage.Attached
  {
    try await attach(grant)
    let reply = try await message("Attached or Error") {
      if case .attached = $0 { return true }
      if case .error = $0 { return true }
      return false
    }
    guard case let .attached(attached) = reply else {
      Issue.record("attach failed: \(reply)")
      throw HostTestTimeout(what: "Attached")
    }
    return attached
  }

  func errorCode() async throws -> RSTErrorCode {
    let reply = try await message("Error") {
      if case .error = $0 { return true }
      return false
    }
    guard case let .error(error) = reply else { fatalError() }
    return error.code
  }

  func inputAck(_ sequence: UInt64) -> Bool {
    messages.contains {
      if case .inputAck(_, sequence) = $0 { return true }
      return false
    }
  }
}

func screenText(_ snapshot: ScreenSnapshot) -> String {
  snapshot.textLines.joined(separator: "\n")
}
#endif
