import SwiftMuxProtocol
import Synchronization

/// Shared across selected-workspace listeners. A permit follows a connection
/// from pending guardian lookup through relay teardown without a credit gap.
package final class GatewayNativeAdmission: Sendable {
  package final class Permit: Sendable {
    private let owner: GatewayNativeAdmission
    fileprivate init(_ owner: GatewayNativeAdmission) { self.owner = owner }
    deinit { owner.used.withLock { $0 -= 1 } }
  }

  private let limit: Int
  private let used = Mutex(0)

  package init(limit: Int = 64) throws {
    guard limit > 0, limit <= 256 else {
      throw MuxError(.invalidRequest, "invalid native connection limit")
    }
    self.limit = limit
  }

  package var count: Int { used.withLock { $0 } }

  package func acquire() -> Permit? {
    used.withLock { count in
      guard count < limit else { return nil }
      count += 1
      return Permit(self)
    }
  }
}
