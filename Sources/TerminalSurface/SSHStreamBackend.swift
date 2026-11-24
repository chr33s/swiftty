import Foundation
import ScreenProtocol
import SessionCore
import SwifttyCore
import Synchronization

/// Ordinary SSH on direct clients (spec §A.3.B): shell-channel output is
/// parsed by a local `TerminalSession`; encoded input and terminal replies
/// return over the same channel.
///
/// `TerminalSession.receive` returns before parsing, so it is not
/// backpressure. This adapter hands the channel output credit only as
/// parsing completes: after each chunk it queues an ordered marker
/// (`receive { _ in ...; return [] }`) that runs on the session queue once
/// the chunk is parsed and returns that chunk's credit. Unparsed output
/// therefore never exceeds `outputWindow` plus one transport read.
/// Credit is also withheld while the ordered writer is full, so a peer
/// cannot grow the reply queue indefinitely by sending terminal queries.
public final class SSHStreamBackend: TerminalSurfaceBackend {
  enum Outbound: Sendable {
    case bytes([UInt8])
    case resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int)
  }

  struct State: Sendable {
    var lifecycle: SurfaceLifecycle = .connecting
    var started = false
    var unparsed = 0
    var peakUnparsed = 0
    var withheldCredit = 0
    var outbound: [Outbound] = []
    var outboundBytes = 0
    var reservedBytes = 0
    var pumping = false
    var onLifecycleChange: (@Sendable (SurfaceLifecycle) -> Void)?
    var onScreenInstalled: (@Sendable (Date) -> Void)?
    var onInputRefusal: (@Sendable (InputRefusal) -> Void)?
    /// Grid last sent to (or opened on) the remote PTY.
    var remoteGrid: GridSize?
    /// Cell size in pixels last sent to the remote PTY (0 × 0 at open).
    var remoteCell = (width: 0, height: 0)
  }

  public let session: TerminalSession
  let channel: any TerminalByteChannel
  /// Output credit: the most program output delivered but not yet parsed.
  public let outputWindow: Int
  /// User input is refused when queued encoding reservations plus bytes
  /// awaiting the channel would exceed this limit.
  public let writeLimit: Int
  private let state = Mutex(State())

  /// No remote clipboard writes or URL opening by default (spec §A.7);
  /// local emulator features otherwise work.
  public static let capabilities = SurfaceCapabilities(
    scrollback: true,
    search: true,
    mouseReporting: true,
    remoteClipboardWrites: false,
    localCopy: true,
    paste: true,
    openURLs: false,
    localProcess: false,
    textInput: true
  )

  /// - Parameters:
  ///   - channel: The remote byte channel for output, input, and resizing.
  ///   - session: A regular byte-stream terminal session with no local PTY.
  ///   - outputWindow: Positive initial output credit, returned as parsing
  ///     ends.
  ///   - writeLimit: Positive byte limit for input awaiting the channel.
  public init(
    channel: any TerminalByteChannel,
    session: TerminalSession,
    outputWindow: Int = 256 * 1024,
    writeLimit: Int = RSTLimits.maxPendingInputBytes
  ) {
    precondition(outputWindow > 0 && writeLimit > 0)
    self.channel = channel
    self.session = session
    self.outputWindow = outputWindow
    self.writeLimit = writeLimit
  }

  /// Bytes delivered to the session and not yet parsed.
  public var unparsedBytes: Int { state.withLock { $0.unparsed } }
  /// High-water mark of `unparsedBytes`.
  public var peakUnparsedBytes: Int { state.withLock { $0.peakUnparsed } }

  /// Called after program output has been parsed, with the time that
  /// parse finished. Grid changes and local input do not call it.
  public var onScreenInstalled: (@Sendable (Date) -> Void)? {
    get { state.withLock { $0.onScreenInstalled } }
    set {
      let previous = state.withLock { s in
        let previous = s.onScreenInstalled
        s.onScreenInstalled = newValue
        return previous
      }
      withExtendedLifetime(previous) {}
    }
  }

  /// Wires the session and channel and grants the initial credit.
  public func start() {
    let first = state.withLock { s in
      defer { s.started = true }
      return !s.started
    }
    guard first else { return }
    // Views send full native input directly to the session. Admit it
    // before the session queue, preserving mouse/focus and rich key data.
    session.inputHandler = { [weak self] input in
      guard let self else { return }
      if case let .refused(reason) = submitInput(input) {
        // A dropped focus report is the view's, not something the user
        // typed; reporting it would raise a misleading notice.
        if case .focus = input { return }
        let handler = state.withLock { $0.onInputRefusal }
        handler?(reason)
      }
    }
    // Encoded input and terminal replies share the ordered writer.
    session.onWrite = { [weak self] bytes in self?.enqueue(.bytes(bytes)) }
    // Any local grid change (a view resizing its session directly, or
    // `proposeGrid`) becomes a window-change request, ordered with writes.
    let initial = session.withState {
      GridSize(columns: $0.columns, rows: $0.rows)
    }
    state.withLock { $0.remoteGrid = initial }
    session.onStateChange = { [weak self] terminal in
      self?
        .gridChanged(
          GridSize(columns: terminal.columns, rows: terminal.rows),
          cell: terminal.cellPixelSize
        )
    }
    channel.start(
      TerminalChannelHandler(
        onOutput: { [weak self] bytes in self?.output(bytes) },
        onExit: { [weak self] exit in self?.exited(exit) }
      )
    )
    setLifecycle(.active)
    channel.grantCredit(outputWindow)
  }

  private func output(_ bytes: [UInt8]) {
    let count = bytes.count
    guard count > 0 else { return }
    state.withLock { s in
      s.unparsed += count
      s.peakUnparsed = max(s.peakUnparsed, s.unparsed)
    }
    session.receive(bytes)
    // Runs on the session queue after `bytes` were parsed.
    session.receive { [weak self] _ in
      let installed = Date()
      self?.parsed(count)
      let handler = self?.state.withLock { $0.onScreenInstalled }
      handler?(installed)
      return []
    }
  }

  /// A grid or cell-size change becomes a window-change request; the
  /// pixel size lets remote programs size images (`kitten icat`).
  private func gridChanged(_ grid: GridSize, cell: (width: Int, height: Int)) {
    let changed = state.withLock { s -> Bool in
      guard s.remoteGrid != grid || s.remoteCell != cell else { return false }
      s.remoteGrid = grid
      s.remoteCell = cell
      return true
    }
    if changed {
      enqueue(
        .resize(
          columns: grid.columns,
          rows: grid.rows,
          pixelWidth: grid.columns * max(cell.width, 0),
          pixelHeight: grid.rows * max(cell.height, 0)
        )
      )
    }
  }

  private func parsed(_ count: Int) {
    let credit = state.withLock { s in
      s.unparsed -= count
      guard !s.lifecycle.isFinal else { return 0 }
      s.withheldCredit += count
      return takeOutputCredit(&s)
    }
    if credit > 0 { channel.grantCredit(credit) }
  }

  private func takeOutputCredit(_ s: inout State) -> Int {
    guard !s.lifecycle.isFinal, s.outboundBytes < writeLimit else { return 0 }
    let credit = s.withheldCredit
    s.withheldCredit = 0
    return credit
  }

  private func exited(_ exit: TerminalChannelExit) {
    // Ordered after all output already handed to the session.
    session.programExited()
    switch exit {
    case let .exited(status): setLifecycle(.exited(status))
    case .signaled: setLifecycle(.exited(nil))
    case .disconnected: setLifecycle(.lost)
    }
  }

  private func setLifecycle(_ next: SurfaceLifecycle) {
    let handler = state.withLock {
      s -> (@Sendable (SurfaceLifecycle) -> Void)? in
      guard s.lifecycle != next, !s.lifecycle.isFinal else { return nil }
      s.lifecycle = next
      return s.onLifecycleChange
    }
    handler?(next)
  }

  // MARK: Ordered channel writer

  private func enqueue(_ item: Outbound, reservation: Int = 0) {
    let start = state.withLock { s -> Bool in
      s.reservedBytes -= reservation
      guard !s.lifecycle.isFinal else { return false }
      if case let .bytes(bytes) = item, bytes.isEmpty { return false }
      // Adjacent geometry changes have no intervening input to preserve.
      // Keep the last one, while never coalescing across a byte write.
      if case .resize = item, let last = s.outbound.last, case .resize = last {
        s.outbound[s.outbound.count - 1] = item
      } else {
        s.outbound.append(item)
      }
      if case let .bytes(bytes) = item { s.outboundBytes += bytes.count }
      guard !s.pumping else { return false }
      s.pumping = true
      return true
    }
    if start { Task { await self.pump() } }
  }

  private func pump() async {
    while true {
      let item = state.withLock { s -> Outbound? in
        guard !s.outbound.isEmpty, !s.lifecycle.isFinal else {
          s.pumping = false
          s.outbound = []
          s.outboundBytes = 0
          return nil
        }
        return s.outbound.removeFirst()
      }
      guard let item else { return }
      do {
        switch item {
        case let .bytes(bytes):
          try await channel.write(bytes)
          let credit = state.withLock { s in
            s.outboundBytes -= bytes.count
            return takeOutputCredit(&s)
          }
          if credit > 0 { channel.grantCredit(credit) }
        case let .resize(columns, rows, pixelWidth, pixelHeight):
          try await channel.resize(
            columns: columns,
            rows: rows,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
          )
        }
      } catch { setLifecycle(.lost) }
    }
  }

  // MARK: TerminalSurfaceBackend

  public var capabilities: SurfaceCapabilities { Self.capabilities }
  public var display: SurfaceDisplay { .session(session) }
  public func currentFrame() -> SurfaceFrame? { nil }

  /// The view observes `session.onUpdate` directly.
  public var onInvalidate: (@Sendable () -> Void)? {
    get { nil }
    set { _ = newValue }
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

  /// Direct view input has no asynchronous result receiver. Refusals
  /// are reported synchronously here, outside the backend lock.
  public var onInputRefusal: (@Sendable (InputRefusal) -> Void)? {
    get { state.withLock { $0.onInputRefusal } }
    set {
      let previous = state.withLock { s in
        let previous = s.onInputRefusal
        s.onInputRefusal = newValue
        return previous
      }
      withExtendedLifetime(previous) {}
    }
  }

  public func submit(_ input: SurfaceInput) async -> SurfaceInputResult {
    do { try input.operation.validate() } catch { return .refused(.invalid) }
    return submitInput(input.terminalInput)
  }

  private func submitInput(_ input: TerminalInput) -> SurfaceInputResult {
    guard let reservation = inputReservation(for: input) else {
      return .refused(.invalid)
    }
    let refusal = state.withLock { s -> InputRefusal? in
      if s.lifecycle.isFinal { return .closed }
      guard s.lifecycle == .active else { return .notActive(.idle) }
      guard reservation <= writeLimit - s.outboundBytes - s.reservedBytes else {
        return .backpressure
      }
      s.reservedBytes += reservation
      return nil
    }
    if let refusal { return .refused(refusal) }
    // Charge before queuing encoding, then atomically exchange the
    // reservation for encoded bytes (including an empty encoding).
    session.send(input) { [weak self] bytes in
      self?.enqueue(.bytes(bytes), reservation: reservation)
    }
    return .accepted(sequence: nil)
  }

  /// Resizes the local emulator; the resulting grid change resizes the
  /// remote PTY, in order with writes.
  public func proposeGrid(columns: Int, rows: Int) async {
    guard columns > 0, rows > 0 else { return }
    session.resize(columns: columns, rows: rows)
  }

  public func close() async {
    setLifecycle(.closed)
    session.onWrite = nil
    session.onStateChange = nil
    await channel.close()
    session.programExited()
  }
}
