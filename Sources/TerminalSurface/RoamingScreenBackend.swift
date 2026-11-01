import ScreenProtocol
import SessionCore
import SwifttyCore
import Synchronization

/// Holds the newest installed frame for synchronous view access, forwards
/// it to an optional presentation sink, and coalesces invalidations: one
/// notification until the frame is read, never a queue of frames.
final class FrameMailbox: PresentationSink {
  struct State: Sendable {
    var frame: SurfaceFrame?
    var generation: UInt64 = 0
    var notified = false
    var notificationRevision: UInt64 = 0
    var onInvalidate: (@Sendable () -> Void)?
  }

  let state = Mutex(State())
  let forward: (any PresentationSink)?

  private struct Notification {
    let revision: UInt64
    let handler: @Sendable () -> Void
  }

  init(forward: (any PresentationSink)?) { self.forward = forward }

  @discardableResult
  func install(_ frame: PresentationFrame) -> Bool {
    let notification = state.withLock { s in
      s.generation &+= 1
      s.frame = SurfaceFrame(generation: s.generation, frame: frame)
      return claimNotification(&s)
    }
    // This mailbox owns the frame. Forwarding is an additional consumer,
    // whose refusal does not remove the view-readable frame.
    _ = forward?.install(frame)
    deliver(notification)
    return true
  }

  func take() -> SurfaceFrame? {
    state.withLock { s in
      s.notified = false
      s.notificationRevision &+= 1
      return s.frame
    }
  }

  func setHandler(_ handler: (@Sendable () -> Void)?) {
    let (previous, notification) = state.withLock { s in
      let previous = s.onInvalidate
      s.onInvalidate = handler
      s.notified = false
      s.notificationRevision &+= 1
      return (previous, claimNotification(&s))
    }
    withExtendedLifetime(previous) {}
    deliver(notification)
  }

  private func claimNotification(_ s: inout State) -> Notification? {
    guard s.frame != nil, !s.notified, let handler = s.onInvalidate else {
      return nil
    }
    s.notified = true
    s.notificationRevision &+= 1
    return Notification(revision: s.notificationRevision, handler: handler)
  }

  private func deliver(_ notification: Notification?) {
    guard let notification else { return }
    let current = state.withLock { s in
      s.notified && s.notificationRevision == notification.revision
    }
    if current { notification.handler() }
  }
}

/// RST/1 presentation backend for direct clients (spec §A.3.C, §4.1):
/// a view-facing wrapper around `RoamingClient`. Frames come only from
/// validated host snapshots; input is semantic and never encoded or
/// echoed locally.
public final class RoamingScreenBackend: TerminalSurfaceBackend {
  struct State: Sendable {
    var lifecycle: SurfaceLifecycle = .connecting
    var hasBeenActive = false
    var onLifecycleChange: (@Sendable (SurfaceLifecycle) -> Void)?
    var onStatus: (@Sendable (RoamingStatus) -> Void)?
  }

  public let client: RoamingClient
  private let mailbox: FrameMailbox
  private let inputPump: OrderedInputPump
  private let state = Mutex(State())

  /// - Parameters:
  ///   - bootstrapper: Supplies authenticated bootstrap grants for the host.
  ///   - connector: Opens the transport used to attach to the roaming session.
  ///   - sink: Also receives every installed frame, for example a
  ///     presentation-mode `TerminalSession` the view renders.
  ///   - configuration: Client limits and connection settings.
  ///   - timing: Clock and sleep operations used by the client.
  public init(
    bootstrapper: any RemoteBootstrapper,
    connector: any RSTConnector,
    sink: (any PresentationSink)? = nil,
    configuration: RoamingClientConfiguration = .init(),
    timing: SurfaceTiming = .system
  ) {
    mailbox = FrameMailbox(forward: sink)
    let client = RoamingClient(
      bootstrapper: bootstrapper,
      connector: connector,
      sink: mailbox,
      configuration: configuration,
      timing: timing
    )
    self.client = client
    inputPump = OrderedInputPump { [weak client] input in
      guard let client else { return .refused(.closed) }
      return await client.submit(input)
    }
  }

  /// Binds the presentation session's synchronous, ordered callback to this
  /// attachment. The pump retains this client's identity without owning its
  /// lifetime: queued input cannot follow a retry, and a retained display
  /// callback cannot form a client → sink → display → pump → client cycle.
  package func bindInput(to display: TerminalSession) {
    display.semanticInputHandler = { [inputPump] input in
      if let input = SurfaceInput(input) { inputPump.enqueue(input) }
    }
  }

  /// Synchronous fencing before an application waits for queued lifecycle work.
  package func stopInput() { inputPump.close() }

  /// Observes nonsecret status (UI chrome, companion bridge).
  public var onStatus: (@Sendable (RoamingStatus) -> Void)? {
    get { state.withLock { $0.onStatus } }
    set {
      let previous = state.withLock { s in
        let previous = s.onStatus
        s.onStatus = newValue
        return previous
      }
      withExtendedLifetime(previous) {}
    }
  }

  /// Starts observing the client, then bootstraps and attaches.
  public func start(_ target: RoamingTarget) async throws(RoamingClientError) {
    await client.setStatusHandler { [weak self] status in self?.observe(status)
    }
    try await client.start(target)
  }

  private func observe(_ status: RoamingStatus) {
    let (changed, lifecycleHandler, statusHandler) = state.withLock {
      s -> (
        SurfaceLifecycle?, (@Sendable (SurfaceLifecycle) -> Void)?,
        (@Sendable (RoamingStatus) -> Void)?
      ) in
      if status.state == .active { s.hasBeenActive = true }
      let next = Self.lifecycle(for: status, hasBeenActive: s.hasBeenActive)
      guard next != s.lifecycle else { return (nil, nil, s.onStatus) }
      s.lifecycle = next
      return (next, s.onLifecycleChange, s.onStatus)
    }
    statusHandler?(status)
    if let changed { lifecycleHandler?(changed) }
  }

  static func lifecycle(
    for status: RoamingStatus,
    hasBeenActive: Bool
  ) -> SurfaceLifecycle {
    switch status.state {
    case .idle, .sshBootstrap, .attaching:
      hasBeenActive ? .interrupted : .connecting
    case .active: .active
    case .suspect, .reconnecting, .backgroundDetached: .interrupted
    case .sessionExited: .exited(status.exitStatus)
    case .sessionLost: .lost
    case .userClosed: .closed
    }
  }

  // MARK: TerminalSurfaceBackend

  public var capabilities: SurfaceCapabilities { .roaming }
  public var display: SurfaceDisplay { .frames }

  public func currentFrame() -> SurfaceFrame? { mailbox.take() }

  /// A newly installed handler is notified of any cached frame. Each
  /// binding coalesces further notifications until `currentFrame()`.
  public var onInvalidate: (@Sendable () -> Void)? {
    get { mailbox.state.withLock { $0.onInvalidate } }
    set { mailbox.setHandler(newValue) }
  }

  public var lifecycle: SurfaceLifecycle { state.withLock { $0.lifecycle } }

  public var onLifecycleChange: (@Sendable (SurfaceLifecycle) -> Void)? {
    get { state.withLock { $0.onLifecycleChange } }
    set {
      let previous = state.withLock { s in
        let previous = s.onLifecycleChange
        s.onLifecycleChange = newValue
        return previous
      }
      withExtendedLifetime(previous) {}
    }
  }

  public func submit(_ input: SurfaceInput) async -> SurfaceInputResult {
    await client.submit(input)
  }

  public func proposeGrid(columns: Int, rows: Int) async {
    await client.proposeGrid(columns: columns, rows: rows)
  }

  /// Scrolls this client's history window on the host (when supported).
  public func scrollViewport(by lines: Int) async {
    await client.scrollViewport(by: lines)
  }

  public func close() async { await close(.detach) }

  package func close(_ mode: RoamingCloseMode) async {
    stopInput()
    await client.close(mode)
  }

  // MARK: Platform lifecycle

  public func enterBackground() async { await client.enterBackground() }
  public func enterForeground() async { await client.enterForeground() }
  public func wake() async { await client.wake() }
  public func pathChanged() async { await client.pathChanged() }
  public func terminate() async { await close(.terminate) }
}
