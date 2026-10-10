import Darwin
import Dispatch

/// One terminal: the terminal model plus the transport feeding it.
///
/// The transport is either a child process on a PTY (`start`, macOS only) or
/// external: the host delivers program output with `receive` and takes the
/// terminal's replies and encoded input from `onWrite` (SSH channels, an
/// in-process interpreter, tmux panes), or replies separately from
/// `onTerminalReply`.
///
/// All terminal state is owned by a single serial queue. PTY reads are
/// delivered on that queue and parsed in place from a preallocated buffer;
/// the UI and renderer interact only through `send`, `resize` and
/// `snapshot`. Do not call these from `queue` itself.
/// Callback properties can be replaced from any thread. Each invocation
/// retains its current handler and runs outside the callback-storage lock.
/// Read-only properties and `withState` may be used within callbacks.
public final class TerminalSession: @unchecked Sendable {
  package let queue = DispatchQueue(
    label: "swiftty.terminal",
    qos: .userInteractive
  )
  private let queueKey = DispatchSpecificKey<Bool>()
  private let callbacks = SessionCallbacks()

  /// Called on `queue` when new content is ready; coalesced for each handler
  /// until the next `snapshot()`. A replacement receives the next pending
  /// update even if the previous handler has not taken a snapshot.
  /// Typically schedules a redraw.
  public var onUpdate: (@Sendable () -> Void)? {
    get { callbacks.onUpdate }
    set { callbacks.onUpdate = newValue }
  }

  /// Called on `queue` for titles, bells, clipboard writes and exit.
  public var onEvent: (@Sendable (TerminalEvent) -> Void)? {
    get { callbacks.onEvent }
    set { callbacks.onEvent = newValue }
  }

  /// Called on `queue` with bytes for the application when no PTY is
  /// attached: replies to queries and encoded keyboard/mouse input.
  public var onWrite: (@Sendable ([UInt8]) -> Void)? {
    get { callbacks.onWrite }
    set { callbacks.onWrite = newValue }
  }

  /// Called on `queue`, when no PTY is attached, with replies the
  /// terminal generated itself (query answers such as DA, DSR, OSC 7501),
  /// so the host can route them apart from user input (e.g. to the tmux
  /// pane that asked). When nil, replies go to `onWrite`.
  public var onTerminalReply: (@Sendable ([UInt8]) -> Void)? {
    get { callbacks.onTerminalReply }
    set { callbacks.onTerminalReply = newValue }
  }

  /// Called on `queue` after OSC 7501 program status changed (reports,
  /// prompt start, reset, exit), once per batch, before `onUpdate`. Fires
  /// whether or not any cell changed.
  public var onProgramStatusChange: (@Sendable (ProgramStatusSnapshot) -> Void)?
  {
    get { callbacks.onProgramStatusChange }
    set { callbacks.onProgramStatusChange = newValue }
  }

  /// Called on `queue` after each batch of changes (parsed output, resize,
  /// `mutate`), before `onUpdate`, with read access to the state. Use it to
  /// mirror values the host reads often (modes, scroll position).
  public var onStateChange: (@Sendable (borrowing TerminalState) -> Void)? {
    get { callbacks.onStateChange }
    set { callbacks.onStateChange = newValue }
  }

  /// Called on `queue` with each nonempty chunk of program output before
  /// parsing: PTY reads, external `receive` calls and synchronous `feed`s.
  /// Useful for recording sessions for replay; bytes are copied only when
  /// an observer is installed.
  public var onProgramOutput: (@Sendable ([UInt8]) -> Void)? {
    get { callbacks.onProgramOutput }
    set { callbacks.onProgramOutput = newValue }
  }

  /// Called on `queue` with tmux control-mode lines (between
  /// `.controlModeStarted` and `.controlModeEnded`), in arrival order.
  public var onControlModeData: (@Sendable ([UInt8]) -> Void)? {
    get { callbacks.onControlModeData }
    set { callbacks.onControlModeData = newValue }
  }

  // Owned by `queue`.
  private var state: TerminalState
  private var parser = Parser()
  private var builder = SnapshotBuilder()
  #if os(macOS)
  private var process: PTYProcess?
  private var readSource: DispatchSourceRead?
  private var writeSource: DispatchSourceWrite?
  private var exitSource: DispatchSourceProcess?
  // Advancing a slice avoids moving the remaining paste on every partial write.
  private var pendingWrite: ArraySlice<UInt8> = []
  private var writeSourceActive = false
  #endif
  private var encodeBuffer: [UInt8] = []
  private let readBuffer: UnsafeMutableRawBufferPointer
  private var scheduledUpdateRevision: UInt64?
  private var drawnCursor: CursorState?
  private var synchronizedSince: UInt64 = 0
  private var synchronizedGeneration: UInt64 = 0
  private var synchronizedTimeoutScheduled = false
  private var cellPixelSize = (width: 0, height: 0)

  static let readBufferSize = 64 * 1024
  /// Max bytes parsed per read event so snapshots can interleave.
  static let readBudget = 1 << 20
  /// Longest a synchronized update (mode 2026) holds back redraws.
  static let synchronizedTimeout: UInt64 = 1_000_000_000

  public init(
    columns: Int = 80,
    rows: Int = 24,
    configuration: SessionConfiguration = SessionConfiguration()
  ) {
    queue.setSpecific(key: queueKey, value: true)
    state = TerminalState(
      columns: columns,
      rows: rows,
      scrollbackLimitBytes: configuration.scrollbackLimitBytes,
      scrollbackLimitRows: configuration.scrollbackLimitRows,
      palette: configuration.palette,
    )
    state.programStatusEnabled = configuration.programStatusEnabled
    readBuffer = .allocate(byteCount: Self.readBufferSize, alignment: 16)
    encodeBuffer.reserveCapacity(256)
  }

  deinit {
    // Source handlers capture `self` weakly and hold it while they run,
    // so none can be running once this executes.
    #if os(macOS)
    if let process {
      process.hangUp()
      Self.reap(process.pid)
    }
    teardown()
    #endif
    readBuffer.deallocate()
  }

  // MARK: Lifecycle

  #if os(macOS)
  public func start(_ configuration: SessionConfiguration) throws {
    try queue.sync {
      precondition(process == nil, "session already started")
      let process = try PTYProcess.spawn(
        configuration,
        columns: state.columns,
        rows: state.rows,
        cellPixelSize: cellPixelSize,
        retainingSlaveForDrain: true,
      )
      self.process = process
      let fd = process.master.rawValue

      let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
      read.setEventHandler { [weak self] in self?.readAvailable() }
      // Cancellation is asynchronous. Both descriptor sources must
      // finish canceling before the PTY's owning descriptor closes.
      read.setCancelHandler { withExtendedLifetime(process) {} }
      read.resume()
      readSource = read

      let write = DispatchSource.makeWriteSource(
        fileDescriptor: fd,
        queue: queue
      )
      write.setEventHandler { [weak self] in self?.flushPendingWrite() }
      write.setCancelHandler { withExtendedLifetime(process) {} }
      writeSource = write  // resumed only while output is pending

      let exit = DispatchSource.makeProcessSource(
        identifier: process.pid,
        eventMask: .exit,
        queue: queue
      )
      exit.setEventHandler { [weak self] in self?.childExited() }
      exit.resume()
      exitSource = exit
    }
  }

  public func stop() {
    queue.sync {
      guard let process else { return }
      process.hangUp()
      Self.reap(process.pid)
      teardown()
      finishProgram()
    }
  }

  /// Collects the exit status of a child whose exit source is being
  /// torn down, so it does not linger as a zombie.
  private static func reap(_ pid: pid_t) {
    let source = DispatchSource.makeProcessSource(
      identifier: pid,
      eventMask: .exit,
      queue: .global(qos: .utility)
    )
    // The handler retains the source until it cancels itself.
    source.setEventHandler { [source] in
      _ = waitForChild(pid, options: 0)
      source.cancel()
    }
    source.resume()
    // Already exited (the source may never fire for a zombie).
    if waitForChild(pid, options: WNOHANG).result == pid { source.cancel() }
  }

  private static func waitForChild(
    _ pid: pid_t,
    options: Int32
  ) -> (result: pid_t, status: Int32) {
    var status: Int32 = 0
    var result: pid_t
    repeat {
      result = waitpid(pid, &status, options)
    } while result < 0 && errno == EINTR
    return (result, status)
  }

  public var isRunning: Bool {
    if DispatchQueue.getSpecific(key: queueKey) == true {
      return process != nil
    }
    return queue.sync { process != nil }
  }
  #endif

  /// Parses program output from an external transport. Ordered with
  /// `send`, `resize` and other calls; returns immediately.
  public func receive(_ bytes: [UInt8]) {
    queue.async { [self] in
      bytes.withUnsafeBufferPointer { parse($0) }
      publish()
    }
  }

  /// Produces output using the state at the time it is parsed. The body
  /// runs on `queue`, ordered with input, resizing and other output. This
  /// lets an in-process transport format output for the current dimensions
  /// without a resize interleaving between formatting and parsing.
  /// Empty output does not publish an update.
  public func receive(
    _ makeOutput: @escaping @Sendable (borrowing TerminalState) -> [UInt8]
  ) {
    queue.async { [self] in
      let bytes = makeOutput(state)
      guard !bytes.isEmpty else { return }
      bytes.withUnsafeBufferPointer { parse($0) }
      publish()
    }
  }

  // MARK: Input / resize / output

  public func resize(columns: Int, rows: Int) {
    queue.async { [self] in
      state.resize(columns: columns, rows: rows)
      #if os(macOS)
      process?
        .resize(
          columns: state.columns,
          rows: state.rows,
          cellPixelSize: cellPixelSize
        )
      #endif
      publish()
    }
  }

  /// Cell size in pixels, reported to the PTY and via XTWINOPS.
  public func setCellPixelSize(width: Int, height: Int) {
    queue.async { [self] in
      let previous = state.cellPixelSize
      state.cellPixelSize = (width, height)
      cellPixelSize = state.cellPixelSize
      #if os(macOS)
      process?
        .resize(
          columns: state.columns,
          rows: state.rows,
          cellPixelSize: cellPixelSize
        )
      #endif
      if previous.width != cellPixelSize.width
        || previous.height != cellPixelSize.height
      {
        publish()
      }
    }
  }

  public func send(_ input: TerminalInput) {
    queue.async { [self] in
      encodeBuffer.removeAll(keepingCapacity: true)
      guard
        InputEncoder.encode(
          input,
          modes: state.modes,
          keyboardFlags: state.keyboardFlags,
          into: &encodeBuffer
        )
      else { return }
      switch input {
      case let .key(event) where event.action == .release: break
      case .text, .key, .paste:
        if state.viewportOffset != 0 {
          state.scrollViewportToBottom()
          publish()
        }
      default: break
      }
      writeToChild(encodeBuffer)
    }
  }

  public func scrollViewport(by lines: Int) {
    queue.async { [self] in
      state.scrollViewport(by: lines)
      publish()
    }
  }

  /// Current OSC 7501 records; with `onProgramStatusChange`, all a
  /// newly attached consumer needs.
  public var programStatusSnapshot: ProgramStatusSnapshot {
    withState { $0.programStatus.snapshot }
  }

  /// Continues an external output stream previously parsed by `source`.
  /// Copies its pending sequence, status records and prompt phase after
  /// all output already queued there. Applied here in order with `receive`.
  /// Stop feeding `source` before calling; call from outside both queues.
  public func continueStream(from source: TerminalSession) {
    let (continuation, controlString, status, phase) = source.queue.sync {
      (
        source.parser.continuation, source.state.controlStringContinuation,
        source.state.programStatus.snapshot, source.state.semanticState,
      )
    }
    queue.async { [self] in
      parser.restore(continuation)
      state.restoreControlString(controlString)
      state.replaceProgramStatus(with: status)
      state.semanticState = phase
      publish()
    }
  }

  /// Starts capture replay with a clean parser and screen, keeping status.
  /// Restore live parsing with `continueStream(from:)` after the replay.
  public func resetForCapture() {
    queue.async { [self] in
      parser = Parser()
      state.resetPreservingProgramStatus()
      publish()
    }
  }

  /// Resets the terminal and abandons any incomplete control sequence
  /// or UTF-8 character, ordered with output and input already queued.
  public func reset() {
    queue.async { [self] in
      parser = Parser()
      state.reset()
      publish()
    }
  }

  /// Turns OSC 7501 consumption on or off, ordered with `receive`.
  /// Turning it off clears the records.
  public func setProgramStatusEnabled(_ enabled: Bool) {
    queue.async { [self] in
      state.programStatusEnabled = enabled
      publish()
    }
  }

  /// For external transports: the program exited or the connection
  /// closed. Abandons incomplete parser sequences and drops transient program status (see
  /// `TerminalState.programExited()`), ordered with `receive`. PTY
  /// sessions do this themselves when the child exits.
  public func programExited() { queue.async { [self] in finishProgram() } }

  private func finishProgram() {
    parser = Parser()
    state.programExited()
    publish()
  }

  /// Current modes (for frontends deciding how to route mouse/scroll).
  public var modes: Modes { withState { $0.modes } }

  /// Negotiated kitty keyboard flags for hardware-key routing.
  public var keyboardFlags: UInt8 { withState { $0.keyboardFlags } }

  private var currentCursor: CursorState {
    CursorState(
      x: state.cursor.x,
      y: state.cursor.y,
      isVisible: state.modes.contains(.cursorVisible)
        && state.viewportOffset == 0,
      style: state.cursorStyle,
      isBlinking: state.modes.contains(.cursorBlink),
    )
  }

  /// Builds an immutable frame, reusing unretained storage when available.
  /// - Parameter overscan: Extra rows below a scrolled viewport.
  /// - Returns: A snapshot whose borrowed views remain valid while it is retained.
  /// - Complexity: O(rows + damaged cells); grapheme changes copy all cells.
  /// A pending search refresh may also scan history.
  /// Retaining every frame may allocate additional storage.
  public func snapshot(overscan: Int = 0) -> RenderSnapshot {
    queue.sync {
      scheduledUpdateRevision = nil
      if state.modes.contains(.synchronizedOutput),
        DispatchTime.now().uptimeNanoseconds - synchronizedSince
          < Self.synchronizedTimeout, let held = builder.repeatLast()
      {
        return held
      }
      drawnCursor = currentCursor
      return builder.build(from: &state, overscan: overscan)
    }
  }

  /// Feeds bytes as if the child had written them (tests, replays, benchmarks).
  public func feed(_ bytes: borrowing Span<UInt8>) {
    bytes.withUnsafeBufferPointer { buffer in
      queue.sync {
        parse(buffer)
        publish()
      }
    }
  }

  public func feed(_ bytes: [UInt8]) { feed(bytes.span) }

  /// Runs `body` on the queue with mutable state, then publishes changes.
  public func mutate<R>(_ body: (inout TerminalState) throws -> R) rethrows -> R
  {
    try queue.sync {
      let result = try body(&state)
      state.markSearchDirty()
      publish()
      return result
    }
  }

  /// Asynchronous `mutate`, ordered with `receive`, `send` and `resize`.
  public func mutateAsync(
    _ body: @escaping @Sendable (inout TerminalState) -> Void
  ) {
    queue.async { [self] in
      body(&state)
      state.markSearchDirty()
      publish()
    }
  }

  /// Read-only access to the terminal state on its queue. May also be
  /// called directly from a session callback already running on `queue`.
  public func withState<R>(
    _ body: (borrowing TerminalState) throws -> R
  ) rethrows -> R {
    if DispatchQueue.getSpecific(key: queueKey) == true {
      return try body(state)
    }
    return try queue.sync { try body(state) }
  }

  // MARK: Queue-owned internals

  private func parse(_ buffer: UnsafeBufferPointer<UInt8>) {
    if !buffer.isEmpty { onProgramOutput?(Array(buffer)) }
    let span = Span(_unsafeElements: buffer)
    parser.consume(span, into: &state)
  }

  #if os(macOS)
  private func readAvailable() {
    guard let process else { return }
    var budget = Self.readBudget
    while budget > 0 {
      let n = process.master.read(into: readBuffer)
      if n > 0 {
        let chunk = UnsafeBufferPointer(
          start: readBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
          count: n
        )
        parse(chunk)
        budget -= n
        continue
      }
      if n < 0, errno == EINTR { continue }
      if n < 0, errno == EAGAIN { break }
      // EOF or EIO: the slave side is gone.
      readSource?.cancel()
      readSource = nil
      break
    }
    publish()
  }
  #endif

  /// Flushes replies and events, then notifies the frontend once.
  private func publish() {
    if synchronizedGeneration != state.synchronizedOutputGeneration {
      synchronizedGeneration = state.synchronizedOutputGeneration
      synchronizedSince = DispatchTime.now().uptimeNanoseconds
    }
    state.refreshSearchIfNeeded()
    onStateChange?(state)
    if !state.output.isEmpty {
      writeReply(state.output)
      state.output.removeAll(keepingCapacity: true)
    }
    if let status = state.takeProgramStatusChange() {
      onProgramStatusChange?(status)
    }
    let ends = state.controlModeEndOffsets
    let events = state.takeEvents()
    let data = state.controlModeData
    if !data.isEmpty { state.controlModeData.removeAll(keepingCapacity: true) }
    // Flush each stream's bytes before its end event, even when other
    // events or another stream follow within the same parser batch.
    var start = 0
    var endIndex = 0
    for event in events {
      if event == .controlModeEnded {
        let end =
          endIndex < ends.count
          ? min(data.count, max(start, ends[endIndex])) : data.count
        if start < end {
          onControlModeData?(
            start == 0 && end == data.count ? data : Array(data[start ..< end])
          )
        }
        start = end
        endIndex += 1
      }
      onEvent?(event)
    }
    if start < data.count {
      onControlModeData?(start == 0 ? data : Array(data[start...]))
    }
    guard !state.damage.isEmpty || drawnCursor != currentCursor else { return }
    let update = callbacks.updateHandler
    guard let handler = update.handler,
      scheduledUpdateRevision != update.revision
    else { return }
    if state.modes.contains(.synchronizedOutput),
      DispatchTime.now().uptimeNanoseconds - synchronizedSince
        < Self.synchronizedTimeout
    {
      // Publish when the timeout lapses even if no more output arrives.
      if !synchronizedTimeoutScheduled {
        synchronizedTimeoutScheduled = true
        queue.asyncAfter(
          deadline: DispatchTime(
            uptimeNanoseconds: synchronizedSince + Self.synchronizedTimeout
          )
        ) { [weak self] in
          self?.synchronizedTimeoutScheduled = false
          self?.publish()
        }
      }
      return
    }
    scheduledUpdateRevision = update.revision
    handler()
  }

  /// Terminal-generated replies: to the PTY, else `onTerminalReply`,
  /// else `onWrite`.
  private func writeReply(_ bytes: [UInt8]) {
    #if os(macOS)
    if process != nil {
      writeToChild(bytes)
      return
    }
    #endif
    if let onTerminalReply { onTerminalReply(bytes) } else { onWrite?(bytes) }
  }

  private func writeToChild(_ bytes: [UInt8]) {
    guard !bytes.isEmpty else { return }
    #if os(macOS)
    guard let process else {
      onWrite?(bytes);
      return
    }
    if !pendingWrite.isEmpty {
      pendingWrite.append(contentsOf: bytes)
      return
    }
    let written =
      bytes.withUnsafeBytes { process.master.writeAvailable($0) } ?? bytes.count
    if written < bytes.count {
      pendingWrite.append(contentsOf: bytes[written...])
      setWriteSourceActive(true)
    }
    #else
    onWrite?(bytes)
    #endif
  }

  #if os(macOS)
  private func flushPendingWrite() {
    guard let process, !pendingWrite.isEmpty else { return }
    let written =
      pendingWrite.withUnsafeBytes { process.master.writeAvailable($0) }
      ?? pendingWrite.count
    pendingWrite.removeFirst(written)
    if pendingWrite.isEmpty {
      pendingWrite = []  // Release the consumed slice's backing storage.
      setWriteSourceActive(false)
    }
  }

  private func setWriteSourceActive(_ active: Bool) {
    guard let writeSource, active != writeSourceActive else { return }
    writeSourceActive = active
    if active { writeSource.resume() } else { writeSource.suspend() }
  }

  private func childExited() {
    guard let process else { return }
    readAvailable()  // exit can wait for the controlling terminal to drain
    // Darwin posts NOTE_EXIT before the child becomes waitable.
    // Wait for that final transition instead of decoding an untouched
    // zero status from WNOHANG as a successful exit.
    let waited = Self.waitForChild(process.pid, options: 0)
    readAvailable()  // the retained slave preserves output through exit
    let status = waited.status
    let code: Int32 =
      waited.result == process.pid
      ? ((status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F))
      : -1
    teardown()
    finishProgram()
    onEvent?(.exited(code))
  }

  private func teardown() {
    readSource?.cancel()
    readSource = nil
    setWriteSourceActive(true)  // a suspended source must not be released
    writeSource?.cancel()
    writeSource = nil
    writeSourceActive = false
    pendingWrite.removeAll()
    exitSource?.cancel()
    exitSource = nil
    process = nil
  }
  #endif
}
