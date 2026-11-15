import Synchronization

enum DeadlineOperationError: Error { case timedOut }

/// Owns one operation's wait and disposes a value returned after that wait
/// ends, without requiring a provider to cooperate with cancellation.
final class DeadlineOperation<Value: Sendable>: Sendable {
  private struct State {
    var finished = false
    var continuation: CheckedContinuation<Value, any Error>?
    var tasks: [Task<Void, Never>] = []
  }

  private let state = Mutex(State())
  private let discard: @Sendable (Value) -> Void

  init(discard: @escaping @Sendable (Value) -> Void = { _ in }) {
    self.discard = discard
  }

  func run(
    timeout: Duration? = nil,
    timing: SurfaceTiming,
    operation: @escaping @Sendable () async throws -> Value,
  ) async throws -> Value {
    try Task.checkCancellation()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let waiting = state.withLock { state in
          guard !state.finished else { return false }
          state.continuation = continuation
          return true
        }
        guard waiting else {
          continuation.resume(throwing: CancellationError())
          return
        }
        register(
          Task {
            guard !Task.isCancelled else { return }
            do { try await finish(.success(operation())) } catch {
              finish(.failure(error))
            }
          }
        )
        if let timeout {
          register(
            Task {
              do { try await timing.sleep(timeout) } catch { return }
              finish(.failure(DeadlineOperationError.timedOut))
            }
          )
        }
      }
    } onCancel: {
      self.finish(.failure(CancellationError()))
    }
  }

  func cancel() { finish(.failure(CancellationError())) }

  private func register(_ task: Task<Void, Never>) {
    let finished = state.withLock { state in
      guard !state.finished else { return true }
      state.tasks.append(task)
      return false
    }
    if finished { task.cancel() }
  }

  private func finish(_ result: Result<Value, any Error>) {
    let owned = state.withLock { state -> State? in
      guard !state.finished else { return nil }
      let owned = state
      state = State(finished: true)
      return owned
    }
    guard let owned else {
      if case let .success(value) = result { discard(value) }
      return
    }
    for task in owned.tasks { task.cancel() }
    owned.continuation?.resume(with: result)
  }
}
