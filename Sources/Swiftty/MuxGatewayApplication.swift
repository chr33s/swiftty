import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
import SwifttyCore

/// App-owned native control lifetime. Window transports remain independently
/// owned. A later operation may reconnect control, but no failed operation is
/// retried here and no unavailable workspace is implicitly recreated.
@MainActor
final class MuxGatewayApplication {
  typealias Connect = @MainActor () async throws -> MuxGatewayConnection
  private let connect: Connect
  private var cached: MuxGatewayConnection?
  private var opening: (id: UUID, task: Task<MuxGatewayConnection, any Error>)?
  private var waiters = 0
  private(set) var isClosed = false
  private(set) var lastCreationID: WorkspaceID?
  var pendingCountForTesting: Int { waiters }

  init(connect: @escaping Connect) { self.connect = connect }

  func connection() async throws -> MuxGatewayConnection {
    try Task.checkCancellation()
    guard !isClosed else {
      throw MuxError(.connectionLost, "gateway application closed")
    }
    guard waiters < 64 else {
      throw MuxError(.resourceLimit, "too many gateway connection waiters")
    }
    waiters += 1
    defer { waiters -= 1 }
    if let cached {
      do {
        try await cached.checkOpen()
        try Task.checkCancellation()
        guard !isClosed else {
          throw MuxError(.connectionLost, "gateway application closed")
        }
        return cached
      } catch is CancellationError { throw CancellationError() } catch {
        if self.cached === cached { self.cached = nil }
        await cached.close()
      }
    }
    try Task.checkCancellation()
    guard !isClosed else {
      throw MuxError(.connectionLost, "gateway application closed")
    }
    if opening == nil {
      let connect = connect
      opening = (UUID(), Task { try await connect() })
    }
    let attempt = opening!
    do {
      let value = try await attempt.task.value
      guard !isClosed else {
        await value.close()
        throw MuxError(.connectionLost, "gateway application closed")
      }
      if opening?.id == attempt.id {
        cached = value
        opening = nil
      }
      // Cancellation abandons this waiter, not the shared connection or another
      // caller's handshake. Startup/shutdown owns the single root task.
      try await value.checkOpen()
      try Task.checkCancellation()
      guard !isClosed else {
        throw MuxError(.connectionLost, "gateway application closed")
      }
      return value
    } catch {
      if opening?.id == attempt.id { opening = nil }
      throw error
    }
  }

  func listing() async throws -> WorkspaceListing {
    try await MuxWorkspaceController.listing(gateway: connection())
  }

  func open(
    _ selector: WorkspaceSelector?,
    configuration: Configuration,
    takeover lease: UInt64?
  ) async throws -> MuxWorkspaceController {
    let gateway = try await connection()
    let target: WorkspaceSelector
    if let selector {
      target = selector
    } else {
      let id = WorkspaceID()
      lastCreationID = id
      do {
        try await gateway.createWorkspace(
          id,
          request: WorkspaceLaunch.request(configuration)
        )
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
          try Task.checkCancellation()
          if let record = try await gateway.listWorkspaces()
            .first(where: { $0.workspace == id })
          {
            if case .available = record.state { break }
            if case let .unavailable(error) = record.state { throw error }
          }
          guard ContinuousClock.now < deadline else {
            throw MuxError(.quiescing, "workspace discovery is pending")
          }
          try await Task.sleep(for: .milliseconds(25))
        }
      } catch is CancellationError { throw CancellationError() } catch {
        throw MuxError(
          (error as? MuxError)?.code ?? .connectionLost,
          "creation outcome for workspace \(id): \(error)"
        )
      }
      target = .id(id)
    }
    try Task.checkCancellation()
    guard !isClosed else {
      throw MuxError(.connectionLost, "gateway application closed")
    }
    let window = try await MuxWorkspaceController.open(
      target,
      configuration: configuration,
      gateway: gateway,
      takeover: lease
    )
    guard !isClosed, !Task.isCancelled else {
      await window.detach()
      window.close()
      if Task.isCancelled { throw CancellationError() }
      throw MuxError(.connectionLost, "gateway application closed")
    }
    window.reconnectGateway = { [weak self] in
      guard let self else {
        throw MuxError(.connectionLost, "gateway application closed")
      }
      return try await self.connection()
    }
    return window
  }

  func close() async {
    isClosed = true
    let attempt = opening
    attempt?.task.cancel()
    let cached = cached
    self.cached = nil
    await cached?.close()
    if let attempt, let value = try? await attempt.task.value {
      await value.close()
    }
    opening = nil
  }
}
