import Synchronization

enum ProviderOperationError: Error { case busy }

/// Holds execution capacity until a provider returns, even if the
/// caller's independently owned wait has already ended.
final class ProviderOperationSlot: Sendable {
  private let occupied = Mutex(false)

  func run<Value: Sendable>(
    _ operation: @Sendable () async throws -> Value,
  ) async throws -> Value {
    try Task.checkCancellation()
    let acquired = occupied.withLock { occupied in
      guard !occupied else { return false }
      occupied = true
      return true
    }
    guard acquired else { throw ProviderOperationError.busy }
    defer { occupied.withLock { $0 = false } }
    try Task.checkCancellation()
    return try await operation()
  }
}
