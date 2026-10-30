import Dispatch
import Foundation

/// One reschedulable source, confined to the service queue. Deinitialization
/// only cancels the thread-safe source; mutable scheduling state stays on queue.
///
/// Sendable: `deadline` is read and written only on `queue` (the service
/// queue and the source's handler queue); the timer source is owned by the
/// instance and cancelled in `deinit`.
final class InboxSnoozeTimer: @unchecked Sendable {
  private let queue: DispatchQueue
  private let source: any DispatchSourceTimer
  private(set) var deadline: Date?

  init(queue: DispatchQueue, onExpiry: @escaping @Sendable () -> Void) {
    self.queue = queue
    source = DispatchSource.makeTimerSource(queue: queue)
    source.schedule(deadline: .distantFuture)
    source.setEventHandler { [weak self] in
      guard let self, let deadline = self.deadline else { return }
      // A previously ready event may run after rescheduling. Wall-clock
      // changes and the bounded far-future wakeup also need this check.
      guard deadline <= Date() else {
        self.arm(deadline)
        return
      }
      self.deadline = nil
      self.source.schedule(deadline: .distantFuture)
      onExpiry()
    }
    source.resume()
  }

  deinit {
    source.setEventHandler(handler: nil)
    source.cancel()
  }

  func schedule(_ deadline: Date?) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard deadline != self.deadline else { return }
    self.deadline = deadline
    if let deadline {
      arm(deadline)
    } else {
      source.schedule(deadline: .distantFuture)
    }
  }

  private func arm(_ deadline: Date) {
    // Bound conversion to dispatch nanoseconds even for arbitrarily distant
    // dates. Early wakeups rearm this same source without expiring the snooze.
    let delay = min(86400, max(0, deadline.timeIntervalSinceNow))
    source.schedule(wallDeadline: .now() + delay)
  }
}
