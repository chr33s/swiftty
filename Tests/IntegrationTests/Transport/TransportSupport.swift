#if os(macOS)
@testable import AppleTransport
import Foundation
import ScreenProtocol
import SessionCore
import Synchronization
import Testing

/// One identity per test process: generation is cheap, but sharing keeps
/// the loopback tests focused on transport behavior.
let loopbackIdentity: HostIdentity = {
  do {
    return try HostIdentity.generate(
      hostnames: ["localhost"],
      ipAddresses: ["127.0.0.1"]
    )
  } catch { fatalError("identity generation failed: \(error)") }
}()

/// Runs `body`, recording both ends' termination diagnostics if it throws.
/// Release builds on CI have seen loopback connections close mid-transfer;
/// this names which side ended the connection and why.
func withConnectionDiagnostics<T>(
  client: QUICRSTConnection,
  server: QUICRSTConnection,
  _ body: () async throws -> T
) async throws -> T {
  do { return try await body() } catch {
    Issue.record(
      """
      failed: \(error)
      client: \(client.snapshotDiagnosticsForTesting)
      server: \(server.snapshotDiagnosticsForTesting)
      """
    )
    throw error
  }
}

/// Collects everything a connection delivers.
final class Inbox: Sendable {
  private struct State {
    var reader = ControlRecordReader()
    var messages: [ControlMessage] = []
    var snapshots: [[UInt8]] = []
    var closed = false
    var closeError: String?
    var controlBytes = 0
  }

  private let state = Mutex(State())

  var handler: RSTConnectionHandler {
    RSTConnectionHandler(
      onControl: { [self] bytes in
        state.withLock { s in
          s.controlBytes += bytes.count
          if let messages = try? s.reader.append(bytes) {
            s.messages += messages
          }
        }
      },
      onSnapshot: { [self] bytes in
        state.withLock { $0.snapshots.append(bytes) }
      },
      onClosed: { [self] error in
        state.withLock {
          $0.closed = true
          $0.closeError = error.map { String(describing: $0) }
        }
      }
    )
  }

  var messages: [ControlMessage] { state.withLock { $0.messages } }
  var snapshots: [[UInt8]] { state.withLock { $0.snapshots } }
  var closed: Bool { state.withLock { $0.closed } }
  var closeError: String? { state.withLock { $0.closeError } }
  var controlBytes: Int { state.withLock { $0.controlBytes } }
}

/// Receives server-side connections, starting each with a fresh inbox.
final class Accepted: Sendable {
  private let state = Mutex<[(QUICRSTConnection, Inbox)]>([])

  func add(_ connection: any RSTConnection) {
    guard let connection = connection as? QUICRSTConnection else { return }
    let inbox = Inbox()
    state.withLock { $0.append((connection, inbox)) }
    connection.start(inbox.handler)
  }

  var all: [(QUICRSTConnection, Inbox)] { state.withLock { $0 } }
  var count: Int { state.withLock { $0.count } }
}

struct TimedOut: Error { var line: Int }

/// Polls `condition` until it holds or the deadline passes.
func transportEventually(
  _ timeout: Duration = .seconds(10),
  line: Int = #line,
  _ condition: () -> Bool
) async throws {
  let deadline = ContinuousClock.now + timeout
  while !condition() {
    guard ContinuousClock.now < deadline else { throw TimedOut(line: line) }
    try await Task.sleep(for: .milliseconds(10))
  }
}

/// Starts a loopback listener on an ephemeral port.
func startListener(
  _ configuration: QUICRSTListener.Configuration = .init(host: "127.0.0.1"),
  identity: HostIdentity = loopbackIdentity
) async throws -> (QUICRSTListener, Accepted) {
  let listener = QUICRSTListener(
    identity: identity,
    configuration: configuration
  )
  let accepted = Accepted()
  try await listener.start { accepted.add($0) }
  return (listener, accepted)
}

func connector(
  _ alpn: String = RSTLimits.alpn,
  timeout: Duration = .seconds(5)
) -> QUICRSTConnector {
  QUICRSTConnector(alpn: alpn, handshakeTimeout: timeout)
}

/// A syntactically valid plain-encoding snapshot payload of `bodyLength`
/// bytes; the transport never decodes it.
func snapshotPayload(bodyLength: Int, fill: UInt8) -> [UInt8] {
  var out: [UInt8] = [SnapshotFrame.Encoding.plain.rawValue]
  for _ in 0 ..< 2 {
    let n = UInt32(bodyLength)
    out += [
      UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF),
      UInt8(n & 0xFF),
    ]
  }
  out += [UInt8](repeating: fill, count: bodyLength)
  return out
}
#endif
