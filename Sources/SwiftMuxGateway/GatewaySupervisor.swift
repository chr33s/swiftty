import Dispatch
import Foundation
import SwiftMuxGuardian
import SwiftMuxProtocol
import SwiftMuxXPC

/// Bounded async access to the guardian's single-command control link.
/// Cancellation abandons a caller, never replays a transmitted operation or
/// releases its wire slot before the result arrives. Disconnect fails all work.
package actor GatewaySupervisor {
  package nonisolated let queue = DispatchSerialQueue(
    label: "swiftmux.gateway.supervisor"
  )
  package nonisolated var unownedExecutor: UnownedSerialExecutor {
    queue.asUnownedSerialExecutor()
  }

  private struct Request {
    let id: UUID
    let command: GuardianGatewayCommand
    var continuation:
      CheckedContinuation<GuardianGatewayConnection.Reply, any Error>?
  }

  package static let maxPendingCommands = 64
  private var connection: GuardianGatewayConnection?
  private var handshake: CheckedContinuation<Void, any Error>?
  private var active: Request?
  private var waiting: [Request] = []
  private var failure: MuxError?
  package private(set) var identity: GuardianGatewayConnection.Identity?
  package var pendingCommandCount: Int {
    waiting.count + (active == nil ? 0 : 1)
  }

  private init() {}

  package static func connect(
    peerRequirement: String?,
    expectedGuardianPID: Int32? = nil,
    channel: @Sendable (DispatchQueue) -> SMXChannel
  ) async throws -> GatewaySupervisor {
    try Task.checkCancellation()
    let supervisor = GatewaySupervisor()
    do {
      try await supervisor.open(
        peerRequirement: peerRequirement,
        expectedGuardianPID: expectedGuardianPID,
        channel: channel
      )
      try Task.checkCancellation()
      try await supervisor.checkOpen()
      return supervisor
    } catch {
      await supervisor.close()
      throw error
    }
  }

  private func open(
    peerRequirement: String?,
    expectedGuardianPID: Int32?,
    channel: @Sendable (DispatchQueue) -> SMXChannel
  ) async throws {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { continuation in
        handshake = continuation
        do {
          connection = try GuardianGatewayConnection(
            channel: channel(queue),
            peerRequirement: peerRequirement,
            expectedGuardianPID: expectedGuardianPID,
            ready: { [weak self] identity in
              self?
                .assumeIsolated {
                  $0.identity = identity
                  let waiter = $0.handshake
                  $0.handshake = nil
                  waiter?.resume()
                }
            },
            closed: { [weak self] error in
              self?.assumeIsolated { $0.finish(error) }
            }
          )
        } catch {
          finish(
            (error as? MuxError)
              ?? MuxError(.connectionLost, "guardian connection failed")
          )
        }
      }
    } onCancel: {
      self.queue.async { self.assumeIsolated { $0.close() } }
    }
  }

  package func close() {
    connection?.close()
    finish(MuxError(.connectionLost, "gateway supervisor closed"))
  }

  package func checkOpen() throws {
    if let failure { throw failure }
    guard identity != nil else {
      throw MuxError(.notAttached, "guardian is not ready")
    }
  }

  package func request(
    _ command: GuardianGatewayCommand
  ) async throws -> GuardianGatewayConnection.Reply {
    try Task.checkCancellation()
    try checkOpen()
    guard pendingCommandCount < Self.maxPendingCommands else {
      throw MuxError(.resourceLimit, "gateway control queue is full")
    }
    let id = UUID()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        waiting.append(
          Request(id: id, command: command, continuation: continuation)
        )
        pump()
      }
    } onCancel: {
      self.queue.async { self.assumeIsolated { $0.cancel(id) } }
    }
  }

  private func pump() {
    guard failure == nil, active == nil, !waiting.isEmpty else { return }
    active = waiting.removeFirst()
    guard let active, let connection,
      connection.submit(
        active.command,
        completion: { [weak self] result in
          self?
            .assumeIsolated { supervisor in
              let waiter = supervisor.active?.continuation
              supervisor.active = nil
              switch result {
              case let .success(.rejected(error)):
                waiter?.resume(throwing: error)
              case let .success(reply): waiter?.resume(returning: reply)
              case let .failure(error):
                waiter?.resume(throwing: error)
                supervisor.finish(error)
              }
              supervisor.pump()
            }
        }
      )
    else {
      // A healthy link accepts exactly one command. No retry of an uncertain send.
      close()
      return
    }
  }

  private func cancel(_ id: UUID) {
    if active?.id == id {
      let waiter = active?.continuation
      active?.continuation = nil
      waiter?.resume(throwing: CancellationError())
    } else if let index = waiting.firstIndex(where: { $0.id == id }) {
      waiting.remove(at: index).continuation?
        .resume(throwing: CancellationError())
    }
  }

  private func finish(_ error: MuxError) {
    guard failure == nil else { return }
    failure = error
    let handshake = handshake
    self.handshake = nil
    let active = active
    self.active = nil
    let waiting = waiting
    self.waiting.removeAll()
    handshake?.resume(throwing: error)
    active?.continuation?.resume(throwing: error)
    for request in waiting { request.continuation?.resume(throwing: error) }
  }
}
