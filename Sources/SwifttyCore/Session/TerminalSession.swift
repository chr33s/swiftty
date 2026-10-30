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
///
/// A presentation session (`init(presentationColumns:rows:configuration:)`)
/// has no transport and no parser: it displays frames another terminal
/// produced (`installPresentation`), forwards semantic input to
/// `semanticInputHandler` and proposes grid sizes to
/// `gridProposalHandler`, so remote modes and side effects stay with the
/// terminal that owns them (spec.roaming.md §A.4.3–4.4).
///
/// Sendable: terminal state, parser, transport sources and buffers are
/// confined to `queue`; callbacks live behind `SessionCallbacks`' lock. The
/// `readBuffer` allocation is owned by the session, used only on `queue`, and
/// deallocated in `deinit` after every source handler has finished.
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

  /// Receives semantic `.text`, `.key` (press and repeat) and `.paste`
  /// input instead of encoding it (presentation mode), on `queue`, in
  /// order. Mouse, focus and raw bytes are dropped.
  public var semanticInputHandler: (@Sendable (TerminalInput) -> Void)? {
    get { callbacks.semanticInput }
    set { callbacks.semanticInput = newValue }
  }

  /// Receives the grid a frontend proposes (view geometry) instead of
  /// resizing or reflowing the displayed frame (presentation mode). Called
  /// on `queue`, in order with input; dimensions are at least one.
  public var gridProposalHandler:
    (@Sendable (_ columns: Int, _ rows: Int) -> Void)?
  {
    get { callbacks.gridProposal }
    set { callbacks.gridProposal = newValue }
  }

  /// Receives viewport scrolling (positive reveals history) instead of
  /// scrolling the displayed frame (presentation mode), so the remote
  /// host can present its own history window. Called on `queue`, in order
  /// with input.
  public var viewportScrollHandler: (@Sendable (_ lines: Int) -> Void)? {
    get { callbacks.viewportScroll }
    set { callbacks.viewportScroll = newValue }
  }

  /// Presentation mode: shows frames produced by a remote authoritative
  /// terminal. Never parses program output or encodes input.
  public let isPresentation: Bool

  // Owned by `queue`.
  private var state: TerminalState
  private var parser = Parser()
  private var builder = SnapshotBuilder()
  #if os(macOS)
  private var process: PTYProcess?
  private var readSource: DispatchSourceRead?
  private var readSourceActive = false
  private var processingRead = false
  private var bufferedRead = 0 ..< 0
  private var replyExitPoll: DispatchSourceTimer?
  private var childIsExiting = false
  private var writeSource: DispatchSourceWrite?
  private var exitSource: DispatchSourceProcess?
  private var exitPoll: DispatchSourceTimer?
  // Advancing a slice avoids moving the remaining paste on every partial write.
  private var pendingWrite: ArraySlice<UInt8> = []
  private var pendingReplies = PTYReplyLedger()
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
  /// Idle scrollback compression; nil for presentation sessions and when
  /// compression is off or unsupported.
  private var scrollbackMaintenance: ScrollbackMaintenanceClient?

  static let readBufferSize = 64 * 1024
  /// Max bytes parsed per read event so snapshots can interleave.
  static let readBudget = 1 << 20
  /// Longest a synchronized update (mode 2026) holds back redraws.
  static let synchronizedTimeout: UInt64 = 1_000_000_000

  public convenience init(
    columns: Int = 80,
    rows: Int = 24,
    configuration: SessionConfiguration = SessionConfiguration()
  ) {
    self.init(
      columns: columns,
      rows: rows,
      configuration: configuration,
      presentation: false
    )
  }

  /// Presentation mode: shows frames produced by a remote authoritative
  /// terminal. Never parses program output or encodes input.
  ///
  /// History is disabled; `configuration` supplies the palette. The
  /// screen starts blank until the first `installPresentation`.
  public convenience init(
    presentationColumns columns: Int,
    rows: Int,
    configuration: SessionConfiguration = SessionConfiguration()
  ) {
    var configuration = configuration
    configuration.scrollbackLimitBytes = 0
    configuration.scrollbackLimitRows = 0
    configuration.programStatusEnabled = false
    self.init(
      columns: columns,
      rows: rows,
      configuration: configuration,
      presentation: true
    )
  }

  private init(
    columns: Int,
    rows: Int,
    configuration: SessionConfiguration,
    presentation: Bool
  ) {
    isPresentation = presentation
    queue.setSpecific(key: queueKey, value: true)
    state = TerminalState(
      columns: columns,
      rows: rows,
      scrollbackLimitBytes: configuration.scrollbackLimitBytes,
      scrollbackLimitRows: configuration.scrollbackLimitRows,
      palette: configuration.palette,
    )
    state.programStatusEnabled = configuration.programStatusEnabled
    state.rectangleChecksumsEnabled = configuration.rectangleChecksumsEnabled
    state.setScrollbackCompression(
      !presentation && configuration.scrollbackCompression
    )
    readBuffer = .allocate(byteCount: Self.readBufferSize, alignment: 16)
    encodeBuffer.reserveCapacity(256)
    updateScrollbackMaintenance()
  }

  deinit {
    // Source handlers capture `self` weakly and hold it while they run,
    // so none can be running once this executes.
    #if os(macOS)
    if let process {
      process.hangUp()
      PTYProcessShutdown.start(process.pid)
    }
    teardown()
    #endif
    scrollbackMaintenance?.cancel()
    readBuffer.deallocate()
  }

  // MARK: Lifecycle

  #if os(macOS)
  public func start(_ configuration: SessionConfiguration) throws {
    try start(configuration, if: { true })
  }

  /// Checks transport ownership on the session queue before spawning.
  package func start(
    _ configuration: SessionConfiguration,
    if shouldStart: @Sendable () -> Bool
  ) throws {
    precondition(!isPresentation, "a presentation session has no process")
    try queue.sync {
      guard shouldStart() else { throw CancellationError() }
      precondition(process == nil, "session already started")
      state.rectangleChecksumsEnabled = configuration.rectangleChecksumsEnabled
      let process = try PTYProcess.spawn(
        configuration,
        columns: state.columns,
        rows: state.rows,
        cellPixelSize: cellPixelSize,
        retainingSlaveForDrain: true,
      )
      self.process = process
      childIsExiting = false
      let fd = process.master.rawValue

      let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
      read.setEventHandler { [weak self] in self?.readAvailable() }
      // Cancellation is asynchronous. Both descriptor sources must
      // finish canceling before the PTY's owning descriptor closes.
      read.setCancelHandler { withExtendedLifetime(process) {} }
      read.resume()
      readSource = read
      readSourceActive = true

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
      PTYProcessShutdown.start(process.pid)
      teardown()
      finishProgram()
    }
  }

  public var isRunning: Bool {
    if DispatchQueue.getSpecific(key: queueKey) == true {
      return process != nil
    }
    return queue.sync { process != nil }
  }
  #endif

  /// Parses program output from an external transport. Ordered with
  /// `send`, `resize` and other calls; returns immediately. Ignored in
  /// presentation mode.
  public func receive(_ bytes: [UInt8]) {
    guard !isPresentation else { return }
    queue.async { [self] in
      bytes.withUnsafeBufferPointer { parse($0) }
      publish()
    }
  }

  /// Produces output using the state at the time it is parsed. The body
  /// runs on `queue`, ordered with input, resizing and other output. This
  /// lets an in-process transport format output for the current dimensions
  /// without a resize interleaving between formatting and parsing.
  /// Empty output does not publish an update. Ignored in presentation mode.
  public func receive(
    _ makeOutput: @escaping @Sendable (borrowing TerminalState) -> [UInt8]
  ) {
    guard !isPresentation else { return }
    queue.async { [self] in
      let bytes = makeOutput(state)
      guard !bytes.isEmpty else { return }
      bytes.withUnsafeBufferPointer { parse($0) }
      publish()
    }
  }

  // MARK: Input / resize / output

  /// Resizes (reflowing) the terminal and its PTY. In presentation mode
  /// only proposes the grid to `gridProposalHandler`; the displayed frame
  /// keeps its size until the remote terminal sends one at the new size.
  public func resize(columns: Int, rows: Int) {
    resize(columns: columns, rows: rows, if: { true })
  }

  /// Checks transport ownership when the queued geometry change runs.
  package func resize(
    columns: Int,
    rows: Int,
    if shouldResize: @escaping @Sendable () -> Bool
  ) {
    if isPresentation {
      let columns = max(1, columns)
      let rows = max(1, rows)
      queue.async { [self] in
        guard shouldResize() else { return }
        callbacks.gridProposal?(columns, rows)
      }
      return
    }
    queue.async { [self] in
      guard shouldResize() else { return }
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

  /// Encodes input with the current modes and writes it to the program.
  /// In presentation mode routes `.text`, `.key` and `.paste` to
  /// `semanticInputHandler` instead and never reaches `onWrite`.
  /// Standalone PTY input has no admission limit. Frontends needing bounded
  /// input and refusal feedback should use `TerminalSurface.LocalPTYBackend`.
  public func send(_ input: TerminalInput) {
    if !isPresentation, let handler = callbacks.inputHandler {
      switch input {
      case let .text(text) where text.isEmpty: return
      case let .bytes(bytes) where bytes.isEmpty: return
      default: handler(input)
      }
      return
    }
    sendInput(input, encoded: nil)
  }

  /// An external transport can admit input synchronously before any
  /// encoding is queued. Its accepted inputs use `send(_:encoded:)`.
  package var inputHandler: (@Sendable (TerminalInput) -> Void)? {
    get { callbacks.inputHandler }
    set { callbacks.inputHandler = newValue }
  }

  package var ptyInputAdmission: PTYInputAdmission? {
    callbacks.ptyInputAdmission
  }

  package func installPTYInputAdmission(
    _ admission: PTYInputAdmission,
    handler: @escaping @Sendable (TerminalInput) -> Void
  ) { callbacks.installPTYInputAdmission(admission, handler: handler) }

  /// Queues already admitted native input without entering its handler again.
  package func sendToPTY(_ input: TerminalInput, reservation: Int) {
    precondition(!isPresentation)
    sendInput(input) { [self] bytes in
      writeToChild(bytes, reservation: reservation)
    }
  }

  /// Delivers this input's encoding to an external transport instead of
  /// `onWrite`. Called once on the session queue, including empty encodings,
  /// so the transport can replace admission reservations with actual bytes.
  package func send(
    _ input: TerminalInput,
    encoded: @escaping @Sendable ([UInt8]) -> Void
  ) {
    precondition(!isPresentation)
    sendInput(input, encoded: encoded)
  }

  private func sendInput(
    _ input: TerminalInput,
    encoded: (@Sendable ([UInt8]) -> Void)?
  ) {
    if isPresentation {
      switch input {
      case let .key(event) where event.action == .release: return
      case .text, .key, .paste:
        queue.async { [self] in callbacks.semanticInput?(input) }
      case .mouse, .focus, .bytes: return
      }
      return
    }
    queue.async { [self] in
      encodeBuffer.removeAll(keepingCapacity: true)
      guard
        InputEncoder.encode(
          input,
          modes: state.modes,
          keyboardFlags: state.keyboardFlags,
          into: &encodeBuffer
        )
      else {
        encoded?([])
        return
      }
      noteScrollbackActivity()
      switch input {
      case let .key(event) where event.action == .release: break
      case .text, .key, .paste:
        if state.viewportOffset != 0 {
          state.scrollViewportToBottom()
          publish()
        }
      default: break
      }
      if let encoded {
        encoded(encodeBuffer)
      } else {
        writeToChild(encodeBuffer)
      }
    }
  }

  /// Scrolls the viewport; a presentation session forwards the request to
  /// `viewportScrollHandler` instead.
  public func scrollViewport(by lines: Int) {
    queue.async { [self] in
      if isPresentation {
        callbacks.viewportScroll?(lines)
        return
      }
      state.scrollViewport(by: lines)
      publish()
    }
  }

  // MARK: Scrollback storage

  /// Requested and effective scrollback compression for this session.
  public var scrollbackCompression: ScrollbackCompressionPolicy {
    withState { $0.scrollbackCompression }
  }

  /// Metadata-only scrollback memory accounting; never restores history.
  public var scrollbackStatistics: ScrollbackStatistics {
    withState { $0.scrollbackStatistics }
  }

  /// Turns idle compression on or off. Turning it off stops maintenance
  /// without decoding: compressed rows stay readable and restore on demand.
  /// Presentation sessions keep history and compression off.
  public func setScrollbackCompression(_ enabled: Bool) {
    queue.async { [self] in
      guard !isPresentation else { return }
      state.setScrollbackCompression(enabled)
      updateScrollbackMaintenance()
    }
  }

  /// Registers with the process coordinator while compression is effective.
  private func updateScrollbackMaintenance() {
    guard !isPresentation, state.scrollbackCompression.effective else {
      scrollbackMaintenance?.cancel()
      scrollbackMaintenance = nil
      return
    }
    if scrollbackMaintenance == nil {
      scrollbackMaintenance = ScrollbackMaintenanceClient(
        queue: queue,
        step: { [weak self] generation in
          self?.state.maintainScrollback(expectedGeneration: generation)
        },
        release: { [weak self] in self?.state.releaseScrollbackWorkspace() }
      )
    }
    scrollbackMaintenance?.noteActivity(generation: state.scrollbackGeneration)
  }

  /// Records a batch of relevant activity; quiet output then compresses.
  private func noteScrollbackActivity() {
    guard let scrollbackMaintenance else { return }
    _ = state.takeScrollbackMaintenanceDirty()
    scrollbackMaintenance.noteActivity(generation: state.scrollbackGeneration)
  }

  /// After a borrowed read or capture promoted cold history, rearms
  /// maintenance without postponing it or publishing anything.
  private func rearmScrollbackMaintenanceIfNeeded() {
    guard let scrollbackMaintenance, state.takeScrollbackMaintenanceDirty()
    else { return }
    scrollbackMaintenance.requestMaintenance(
      generation: state.scrollbackGeneration
    )
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
    guard !isPresentation else { return }
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
      let snapshot = builder.build(from: &state, overscan: overscan)
      rearmScrollbackMaintenanceIfNeeded()
      return snapshot
    }
  }

  /// Feeds bytes as if the child had written them (tests, replays, benchmarks).
  /// Ignored in presentation mode.
  public func feed(_ bytes: borrowing Span<UInt8>) {
    guard !isPresentation else { return }
    bytes.withUnsafeBufferPointer { buffer in
      queue.sync {
        parse(buffer)
        publish()
      }
    }
  }

  public func feed(_ bytes: [UInt8]) { feed(bytes.span) }

  /// Runs `body` on the queue with mutable state, then publishes changes,
  /// including any made before the body throws.
  public func mutate<R>(_ body: (inout TerminalState) throws -> R) rethrows -> R
  {
    try queue.sync {
      defer {
        state.markSearchDirty()
        publish()
      }
      return try body(&state)
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
      defer { rearmScrollbackMaintenanceIfNeeded() }
      return try body(state)
    }
    return try queue.sync {
      defer { rearmScrollbackMaintenanceIfNeeded() }
      return try body(state)
    }
  }

  // MARK: Presentation

  /// Atomically replaces the visible state with `frame` after validating
  /// it (`PresentationFrame.isValid`); returns false, changing nothing,
  /// if it is invalid or this is not a presentation session.
  ///
  /// The frame's layout wins: no reflow and no width recalculation. Clears
  /// the selection and search, damages the whole screen and publishes an
  /// update, ordered with other calls. May be called from any thread,
  /// including `queue`.
  @discardableResult
  public func installPresentation(_ frame: PresentationFrame) -> Bool {
    guard isPresentation, frame.isValid else { return false }
    let install = { [self] in
      state.installPresentation(frame)
      publish()
    }
    if DispatchQueue.getSpecific(key: queueKey) == true {
      install()
    } else {
      queue.sync(execute: install)
    }
    return true
  }

  // MARK: Queue-owned internals

  private func parse(_ buffer: UnsafeBufferPointer<UInt8>) {
    if !buffer.isEmpty { onProgramOutput?(Array(buffer)) }
    let span = Span(_unsafeElements: buffer)
    parser.consume(span, into: &state)
  }

  #if os(macOS)
  private func readAvailable() {
    guard let process, !processingRead else { return }
    processingRead = true
    defer { processingRead = false }
    var budget = Self.readBudget
    while budget > 0 {
      if updateReadPressure() { break }
      if bufferedRead.isEmpty {
        let target = UnsafeMutableRawBufferPointer(
          start: readBuffer.baseAddress,
          count: min(budget, readBuffer.count)
        )
        let n = process.master.read(into: target)
        if n > 0 {
          bufferedRead = 0 ..< n
          let chunk = UnsafeBufferPointer(
            start: readBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
            count: n
          )
          // Record each physical chunk once, before parsing any of it.
          onProgramOutput?(Array(chunk))
        } else {
          if n < 0, errno == EINTR { continue }
          if n < 0, errno == EAGAIN { break }
          // EOF or EIO: the slave side is gone.
          setReadSourceActive(true)
          readSource?.cancel()
          readSource = nil
          readSourceActive = false
          break
        }
      }
      let chunk = UnsafeBufferPointer(
        start: readBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
          .advanced(by: bufferedRead.lowerBound),
        count: bufferedRead.count
      )
      let consumed = parser.consumePrefix(chunk, into: &state, replyLimit: 1)
      bufferedRead =
        (bufferedRead.lowerBound + consumed) ..< bufferedRead.upperBound
      budget -= consumed
      // Check actual writer pressure after each complete reply, keeping
      // frontend notifications batched at the read-turn boundary.
      flushReplies()
    }
    publish()
  }
  #endif

  /// Flushes replies and events, then notifies the frontend once.
  private func publish() {
    noteScrollbackActivity()
    if synchronizedGeneration != state.synchronizedOutputGeneration {
      synchronizedGeneration = state.synchronizedOutputGeneration
      synchronizedSince = DispatchTime.now().uptimeNanoseconds
    }
    state.refreshSearchIfNeeded()
    onStateChange?(state)
    flushReplies()
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

  private func flushReplies() {
    guard !state.output.isEmpty else { return }
    writeReply(state.output)
    state.output.removeAll(keepingCapacity: true)
  }

  /// Terminal-generated replies: to the PTY, else `onTerminalReply`,
  /// else `onWrite`.
  private func writeReply(_ bytes: [UInt8]) {
    #if os(macOS)
    if process != nil {
      // NOTE_EXIT may precede the final controlling-terminal drain. Keep
      // parsing that output, but the departing child cannot use replies.
      if childIsExiting { return }
      writeToChild(bytes, isReply: true)
      return
    }
    #endif
    if let onTerminalReply { onTerminalReply(bytes) } else { onWrite?(bytes) }
  }

  private func writeToChild(
    _ bytes: [UInt8],
    reservation: Int = 0,
    isReply: Bool = false
  ) {
    let admission = callbacks.ptyInputAdmission
    if let admission, !admission.encoded(bytes.count, reservation: reservation)
    {
      return
    }
    guard !bytes.isEmpty else {
      #if os(macOS)
      updateReadPressure()
      #endif
      return
    }
    #if os(macOS)
    guard let process else {
      admission?.consumed(bytes.count)
      onWrite?(bytes);
      return
    }
    if !pendingWrite.isEmpty {
      // An advancing slice otherwise retains every consumed prefix while
      // sustained input keeps the live suffix nonempty.
      if pendingWrite.startIndex >= Self.readBufferSize {
        pendingWrite = ArraySlice(Array(pendingWrite))
      }
      pendingWrite.append(contentsOf: bytes)
      pendingReplies.append(count: bytes.count, isReply: isReply)
      updateReadPressure()
      return
    }
    let written =
      bytes.withUnsafeBytes { process.master.writeAvailable($0) } ?? bytes.count
    admission?.consumed(written)
    if written < bytes.count {
      pendingWrite.append(contentsOf: bytes[written...])
      pendingReplies.append(count: bytes.count - written, isReply: isReply)
      setWriteSourceActive(true)
    }
    updateReadPressure()
    #else
    admission?.consumed(bytes.count)
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
    pendingReplies.consumed(written)
    callbacks.ptyInputAdmission?.consumed(written)
    if pendingWrite.isEmpty {
      pendingWrite = []  // Release the consumed slice's backing storage.
      setWriteSourceActive(false)
    }
    if !updateReadPressure(), !bufferedRead.isEmpty { readAvailable() }
  }

  /// One complete command's reply can cross the threshold. Pause only for
  /// reply bytes: user input ahead of or behind a small reply must still
  /// allow the child to print output before it reads stdin. Standalone
  /// sessions use a 64 KiB threshold; backends supply their write limit.
  @discardableResult
  private func updateReadPressure() -> Bool {
    let admission = callbacks.ptyInputAdmission
    let limit = admission?.limit ?? Self.readBufferSize
    let paused = !childIsExiting && pendingReplies.byteCount > limit
    setReadSourceActive(!paused)
    return paused
  }

  private func setReadSourceActive(_ active: Bool) {
    if active {
      replyExitPoll?.cancel()
      replyExitPoll = nil
    }
    guard let readSource, active != readSourceActive else { return }
    readSourceActive = active
    if active {
      readSource.resume()
    } else {
      readSource.suspend()
      pollPausedExit()
    }
  }

  /// Release pressure when the child is departing, even if NOTE_EXIT
  /// waits for the controlling terminal to drain.
  private func pollPausedExit() {
    guard replyExitPoll == nil else { return }
    let poll = DispatchSource.makeTimerSource(queue: queue)
    poll.schedule(
      deadline: .now() + .milliseconds(25),
      repeating: .milliseconds(25)
    )
    poll.setEventHandler { [weak self] in
      guard let self, !self.readSourceActive, let process = self.process,
        PTYProcessExit.hasStartedExiting(process.pid)
      else { return }
      self.childExited()
    }
    replyExitPoll = poll
    poll.resume()
  }

  private func setWriteSourceActive(_ active: Bool) {
    guard let writeSource, active != writeSourceActive else { return }
    writeSourceActive = active
    if active { writeSource.resume() } else { writeSource.suspend() }
  }

  private func childExited() {
    guard let process else { return }
    childIsExiting = true
    callbacks.ptyInputAdmission?.close()
    readAvailable()  // exit can wait for the controlling terminal to drain
    // NOTE_EXIT can precede waitability. Keep draining on later queue
    // turns rather than block every input, resize and disposal operation.
    var info = siginfo_t()
    var peek: Int32
    repeat {
      peek = waitid(
        P_PID,
        id_t(process.pid),
        &info,
        WEXITED | WNOHANG | WNOWAIT
      )
    } while peek < 0 && errno == EINTR
    if peek == 0, info.si_pid != process.pid {
      if exitPoll == nil {
        let poll = DispatchSource.makeTimerSource(queue: queue)
        poll.schedule(
          deadline: .now() + .milliseconds(50),
          repeating: .milliseconds(50)
        )
        poll.setEventHandler { [weak self] in self?.childExited() }
        exitPoll = poll
        poll.resume()
      }
      return
    }
    readAvailable()  // the retained slave preserves output through exit
    let code: Int32 =
      peek == 0
      ? (info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status)
      : -1
    if peek == 0 {
      // Preserve the owned leader's PID until remaining group members
      // have retired. The reaper holds no terminal or PTY descriptors.
      process.hangUp()
      PTYProcessShutdown.start(process.pid)
    }
    teardown()
    finishProgram()
    onEvent?(.exited(code))
  }

  private func teardown() {
    callbacks.ptyInputAdmission?.close()
    setReadSourceActive(true)  // a suspended source must not be released
    readSource?.cancel()
    readSource = nil
    readSourceActive = false
    setWriteSourceActive(true)  // a suspended source must not be released
    writeSource?.cancel()
    writeSource = nil
    writeSourceActive = false
    pendingWrite.removeAll()
    pendingReplies = PTYReplyLedger()
    bufferedRead = 0 ..< 0
    exitSource?.cancel()
    exitSource = nil
    exitPoll?.cancel()
    exitPoll = nil
    process = nil
    childIsExiting = false
  }
  #endif
}
