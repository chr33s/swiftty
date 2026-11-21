import Foundation
import NIOCore
import NIOSSH
import Synchronization

extension SSHConnection {
  /// Owns channel acceptance and subsequent setup through one deadline.
  /// NIOSSH buffers close before activation, so aborting an unaccepted child
  /// must close the parent to release the pending channel and its promises.
  func withSessionChannel<Value: Sendable>(
    timeout: Duration,
    timeoutError: any Error,
    initialize: @escaping @Sendable (any Channel) throws -> Void,
    operation: @Sendable (any Channel, ConnectionAttempt) async throws -> Value,
  ) async throws -> Value {
    try Task.checkCancellation()
    let parent = channel
    let attempt = ConnectionAttempt(
      deadline: .now() + TimeAmount(clamping: timeout),
      timeoutError: timeoutError,
    )
    let timer = parent.eventLoop.scheduleTask(deadline: attempt.deadline) {
      attempt.abort(timeoutError)
    }
    defer { timer.cancel() }
    return try await withTaskCancellationHandler {
      do {
        let child = try await createSessionChannel(
          attempt: attempt,
          initialize: initialize,
        )
        try Task.checkCancellation()
        let value = try await operation(child, attempt)
        try Task.checkCancellation()
        try attempt.finish(keeping: child)
        return value
      } catch {
        attempt.abort(error)
        if Task.isCancelled { throw CancellationError() }
        throw attempt.failure ?? error
      }
    } onCancel: {
      attempt.abort(CancellationError())
    }
  }

  private func createSessionChannel(
    attempt: ConnectionAttempt,
    initialize: @escaping @Sendable (any Channel) throws -> Void,
  ) async throws -> any Channel {
    let parent = channel
    let promise = parent.eventLoop.makePromise(of: (any Channel).self)
    let settled = Mutex(false)
    promise.futureResult.whenComplete { _ in settled.withLock { $0 = true } }
    parent.eventLoop.execute {
      do {
        if let error = attempt.failure { throw error }
        guard parent.isActive else { throw SSHClientError.connectionClosed }
        let ssh = try parent.pipeline.syncOperations.handler(
          type: NIOSSHHandler.self
        )
        ssh.createChannel(promise, channelType: .session) { child, _ in
          child.eventLoop.makeCompletedFuture {
            try attempt.register(child) { pending in
              let mustCloseParent =
                !settled.withLock { $0 } && !pending.isActive
              pending.close(promise: nil)
              if mustCloseParent { parent.close(promise: nil) }
            }
            try child.pipeline.syncOperations.addHandler(
              ChannelCloseHandler(parent: parent)
            )
            try initialize(child)
          }
        }
      } catch { promise.fail(error) }
    }
    do {
      return try await attempt.wait(for: promise.futureResult) {
        $0.close(promise: nil)
      }
    } catch let error as NIOSSHError where error.type == .channelSetupRejected {
      throw SSHClientError.channelRequestRejected("session")
    } catch let error as NIOSSHError
      where error.type == .creatingChannelAfterClosure
    { throw SSHClientError.connectionClosed }
  }
}

/// The outcome of one bounded connection health check
/// (spec.roaming.md §9.1).
public enum SSHHealth: Sendable, Equatable {
  /// The server answered within the deadline.
  case responsive
  /// No answer within the deadline; the connection may be half-open.
  case unresponsive
  /// The connection is already closed.
  case closed
}

extension SSHConnection {
  /// Asks the server to open, then immediately closes, a session channel.
  /// Any answer, including a refusal, proves the server is still reading
  /// this connection. Sends nothing to a running shell and has no effect
  /// on it.
  public func probe(timeout: Duration = .seconds(10)) async -> SSHHealth {
    guard isActive else { return .closed }
    do {
      try await withSessionChannel(
        timeout: timeout,
        timeoutError: SSHClientError.channelSetupTimeout,
        initialize: { _ in },
        operation: { child, _ in child.close(promise: nil) }
      )
      return .responsive
    } catch SSHClientError.channelRequestRejected {
      return .responsive
    } catch {
      return isActive ? .unresponsive : .closed
    }
  }
}
