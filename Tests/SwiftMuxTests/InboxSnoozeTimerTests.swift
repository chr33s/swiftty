import Dispatch
import Foundation
import Synchronization
@testable import SwiftMuxService
import Testing

@Suite(.timeLimit(.minutes(1)))
struct InboxSnoozeTimerTests {
  final class Token: Sendable {}

  private func until(
    _ timeout: Duration = .seconds(2),
    _ predicate: () -> Bool
  ) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if predicate() { return true }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return predicate()
  }

  @Test
  func replacementAndCancellationReleaseOwnedCallbackBeforeExpiry() async {
    let queue = DispatchQueue(label: "snooze.timer.ownership")
    weak var captured: Token?
    weak var owner: InboxSnoozeTimer?
    queue.sync {
      let token = Token()
      captured = token
      var timer: InboxSnoozeTimer? = InboxSnoozeTimer(queue: queue) { [token] in
        _ = withExtendedLifetime(token) {
          Issue.record("Future timer fired early")
        }
      }
      owner = timer
      for index in 0 ..< 10_000 {
        timer?.schedule(Date().addingTimeInterval(Double(86400 + index)))
      }
      #expect(captured != nil)
      timer?.schedule(nil)
      timer = nil
    }
    #expect(owner == nil)
    #expect(await until { captured == nil })
  }

  @Test
  func earlierExpiryFiresOnceAndClearsDeadline() async {
    let queue = DispatchQueue(label: "snooze.timer.expiry")
    let fired = Mutex(0)
    let timer = InboxSnoozeTimer(queue: queue) { fired.withLock { $0 += 1 } }
    queue.sync {
      timer.schedule(Date().addingTimeInterval(86400))
      timer.schedule(Date(timeIntervalSince1970: .greatestFiniteMagnitude))
      timer.schedule(Date().addingTimeInterval(-1))
    }
    #expect(await until { fired.withLock { $0 == 1 } })
    queue.sync { #expect(timer.deadline == nil) }
    queue.sync { timer.schedule(Date().addingTimeInterval(-1)) }
    #expect(await until { fired.withLock { $0 == 2 } })
    queue.sync { #expect(timer.deadline == nil) }
  }

  @Test(arguments: [false, true])
  func postponedOrClearedReadyEventCannotExpireTheReplacement(
    _ clear: Bool
  ) async {
    let queue = DispatchQueue(label: "snooze.timer.replacement")
    let fired = Mutex(0)
    let timer = InboxSnoozeTimer(queue: queue) { fired.withLock { $0 += 1 } }
    queue.sync {
      timer.schedule(Date().addingTimeInterval(-1))
      // Keep the target queue occupied while the original source becomes ready.
      Thread.sleep(forTimeInterval: 0.1)
      timer.schedule(clear ? nil : Date().addingTimeInterval(86400))
    }
    #expect(await !(until(.milliseconds(100)) { fired.withLock { $0 != 0 } }))
    queue.sync { timer.schedule(Date().addingTimeInterval(-1)) }
    #expect(await until { fired.withLock { $0 == 1 } })
    queue.sync { timer.schedule(nil) }
  }
}
