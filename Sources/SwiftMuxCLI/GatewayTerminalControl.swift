import SwiftMuxClient
import SwiftMuxGuardian
import SwiftMuxProtocol

/// Owns CLI control across the terminal's single recovery operation. A late
/// handshake after terminal exit is disposed rather than published.
@MainActor
final class GatewayTerminalControl {
  private var connection: MuxGatewayConnection
  private let service: String
  private var closed = false

  init(_ connection: MuxGatewayConnection, service: String) {
    self.connection = connection
    self.service = service
  }

  func reconnect() async throws -> MuxGatewayConnection {
    try Task.checkCancellation()
    guard !closed else { throw CancellationError() }
    do {
      try await connection.checkOpen()
      try Task.checkCancellation()
      guard !closed else { throw CancellationError() }
      return connection
    } catch is CancellationError { throw CancellationError() } catch {
      try Task.checkCancellation()
    }
    guard !closed else { throw CancellationError() }
    let service = service
    let fresh = try await MuxGatewayConnection.connect(
      peerRequirement: GuardianPeerSigningPolicy.requirementForCurrentProcess(),
      channel: { .connect(machService: service, queue: $0) }
    )
    guard !closed, !Task.isCancelled else {
      await fresh.close()
      throw CancellationError()
    }
    connection = fresh
    return fresh
  }

  func close() async {
    closed = true
    await connection.close()
  }
}
