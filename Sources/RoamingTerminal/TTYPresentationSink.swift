import RoamingKit
import SwifttyEngine
import Synchronization

/// Receives roaming frames on the client's executor and keeps only the
/// newest, notifying the TTY frontend at most once until it is read.
/// Frames are never queued: a slow outer terminal skips to current state.
public final class TTYPresentationSink: PresentationSink {
  private struct State {
    var frame: PresentationFrame?
    var notified = false
    var closed = false
    var onFrame: (@Sendable () -> Void)?
  }

  private let state = Mutex(State())

  public init() {}

  /// Called from any executor when a newer frame exists.
  public func setFrameHandler(_ handler: (@Sendable () -> Void)?) {
    state.withLock { $0.onFrame = handler }
  }

  @discardableResult
  public func install(_ frame: PresentationFrame) -> Bool {
    guard frame.isValid else { return false }
    let (accepted, notify) = state.withLock {
      s -> (Bool, (@Sendable () -> Void)?) in
      guard !s.closed else { return (false, nil) }
      s.frame = frame
      guard !s.notified else { return (true, nil) }
      s.notified = true
      return (true, s.onFrame)
    }
    notify?()
    return accepted
  }

  /// The newest frame; re-arms the notification.
  public func take() -> PresentationFrame? {
    state.withLock {
      $0.notified = false
      return $0.frame
    }
  }

  public func close() {
    state.withLock {
      $0.closed = true
      $0.onFrame = nil
    }
  }
}
