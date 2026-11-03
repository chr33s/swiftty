#if os(macOS)
import Foundation
import SwiftMuxProtocol

/// Bounded read-only readiness discovery shared by native and terminal frontends.
@MainActor
public enum MuxGatewayRecovery {
  /// Retry only connection establishment and read-only inventory. Once ready,
  /// the caller submits one attach; uncertain attachment outcomes are not retried.
  public static func waitForWorkspace(
    _ workspace: WorkspaceID,
    reconnect: @escaping @MainActor () async throws -> MuxGatewayConnection,
    role: AttachmentRole = .controller,
    timeout: Duration = .seconds(30)
  ) async throws -> MuxGatewayConnection {
    try Task.checkCancellation()
    let deadline = ContinuousClock.now + timeout
    let (results, continuation) = AsyncThrowingStream<
      MuxGatewayConnection, any Error
    >
    .makeStream(bufferingPolicy: .bufferingOldest(1))
    // The caller owns shared control. Abandoning this wait cancels discovery but
    // must neither close that control nor await a noncooperative shared handshake.
    let discovery = Task {
      do {
        let gateway = try await discoverGatewayWorkspace(
          workspace,
          reconnect: reconnect,
          role: role,
          deadline: deadline
        )
        continuation.yield(gateway)
        continuation.finish()
      } catch { continuation.finish(throwing: error) }
    }
    let timer = Task {
      do { try await Task.sleep(until: deadline, clock: .continuous) } catch {
        return
      }
      continuation.finish(
        throwing: MuxError(
          .connectionLost,
          "gateway reconnect deadline expired"
        )
      )
    }
    defer {
      discovery.cancel()
      timer.cancel()
      continuation.finish()
    }
    var iterator = results.makeAsyncIterator()
    let gateway = try await iterator.next()
    try Task.checkCancellation()
    guard ContinuousClock.now < deadline else {
      throw MuxError(.connectionLost, "gateway reconnect deadline expired")
    }
    guard let gateway else { throw MuxError(.connectionLost) }
    return gateway
  }

  private static func discoverGatewayWorkspace(
    _ workspace: WorkspaceID,
    reconnect: @MainActor () async throws -> MuxGatewayConnection,
    role: AttachmentRole,
    deadline: ContinuousClock.Instant
  ) async throws -> MuxGatewayConnection {
    while true {
      try Task.checkCancellation()
      guard ContinuousClock.now < deadline else {
        throw MuxError(.connectionLost, "gateway reconnect deadline expired")
      }
      do {
        let gateway = try await reconnect()
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
          throw MuxError(.connectionLost, "gateway reconnect deadline expired")
        }
        let records = try await gateway.listWorkspaces()
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
          throw MuxError(.connectionLost, "gateway reconnect deadline expired")
        }
        guard let record = records.first(where: { $0.workspace == workspace })
        else { throw MuxError(.notFound, "retained workspace not found") }
        switch record.state {
        case .available:
          guard let summary = record.summary else {
            throw MuxError(.quiescing, "workspace metadata pending")
          }
          guard role == .observer || !summary.isAttached else {
            throw MuxError(.leaseHeld)
          }
          return gateway
        case .starting, .discovering:
          throw MuxError(.quiescing, "workspace discovery pending")
        case .empty, .unavailable:
          throw MuxError(
            .notAttached,
            "terminal worker unavailable; processes retained"
          )
        }
      } catch let error as MuxError
        where error.code == .connectionLost || error.code == .quiescing
      {
        // No mutation has been submitted. Other refusals stop recovery.
      }
      try await Task.sleep(
        until: min(deadline, .now + .milliseconds(250)),
        clock: .continuous
      )
    }
  }
}
#endif
