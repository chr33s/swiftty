import Darwin
import Dispatch
import Foundation
import MuxAttention
import SwiftMuxExport
import SwiftMuxProtocol
import SwifttyEngine
import Synchronization

/// Events a pane reports to the service, on the pane queue.
enum PaneEvent: Sendable {
  case title(String)
  case bell
  case workingDirectory(String)
  /// OSC 7501 changes in stream order, under the terminal epoch they
  /// happened in. Always delivered before `finished`.
  case status(TerminalEpochID, [StatusChange])
  /// Process exited and output drained (or the drain bound elapsed).
  case finished(status: Int32, forced: Bool)
  /// A kitty clipboard read or committed write for the controller to
  /// answer (`completeClipboardRead` / `completeClipboardWrite`).
  case clipboardRead(MuxClipboardRead)
  case clipboardWrite(MuxClipboardWrite)
}

/// Events gathered off the parse path, shared with the emulator's hooks.
final class PendingPaneEvents: Sendable { let events = Mutex<[PaneEvent]>([]) }

/// One PTY, its process lifecycle and its authoritative terminal. Every
/// operation runs on `queue` in order: output parsing, input writes,
/// replies, resizes and frame capture.
///
/// Sendable: terminal, parser, descriptors and sources are confined to
/// `queue`; shared counters use `Mutex`/`Atomic`; `onChange`/`onEvent` are
/// set once before the pane is published to the service, and `pid` is an
/// `Atomic` that can be set only once. The `readBuffer` allocation is used
/// only on `queue` and freed in `deinit`.
final class PaneRuntime: @unchecked Sendable {
  let id: PaneID
  let workspace: WorkspaceID
  let queue: DispatchQueue
  let limits: MuxLimits
  /// This pane's share of the service's logical history budget.
  let historyBytes: Int

  /// Admitted, unwritten input bytes; shared with the service for
  /// admission decisions.
  let outstandingInput = Mutex(0)
  /// Set when a change notification is posted; cleared by the service.
  let changePosted = Atomic(false)

  private struct ResizeRequest: Sendable {
    let columns: Int
    let rows: Int
    let generation: UInt64
  }

  private struct ResizeState: Sendable {
    var pending: ResizeRequest?
    var scheduled = false
    /// Last generation handed out; a coalesced request skips some.
    var requested: UInt64 = 0
  }

  private let resizes = Mutex(ResizeState())

  // Set once before use, read on `queue`.
  var onChange: (@Sendable () -> Void)?
  var onEvent: (@Sendable (PaneEvent) -> Void)?

  // MARK: Queue-owned state

  private var state: TerminalState
  /// Idle history compression on this pane's queue; nil when off.
  private var scrollbackMaintenance: ScrollbackMaintenanceClient?
  private var parser = Parser()
  private var writer: PaneWriter
  private let observePaneIO: (@Sendable (PaneID, PaneIOObservation) -> Void)?
  private var master: Int32 = -1
  private var slave: Int32 = -1
  /// Set once at spawn on `queue`; read on the service queue too.
  private let spawnedPID = Atomic<pid_t>(0)
  /// The child's process id, 0 before spawn.
  var pid: pid_t { spawnedPID.load(ordering: .acquiring) }
  private var readSource: DispatchSourceRead?
  private var readSourceActive = false
  private var processingRead = false
  private var replyExitPoll: DispatchSourceTimer?
  /// Unparsed bytes in readBuffer, held while reply capacity is exhausted.
  private var bufferedRead = 0 ..< 0
  private var childIsExiting = false
  private var writeSource: DispatchSourceWrite?
  private var writeActive = false
  private var exitSource: DispatchSourceProcess?
  private var exitPoll: DispatchSourceTimer?
  private let readBuffer: UnsafeMutableRawBufferPointer
  private var exitStatus: Int32?
  private var finished = false
  private var forcedTermination = false
  private var terminating = false
  private var naturalDrainDeadline: DispatchTime?
  private var terminationDeadline: DispatchTime?
  private var groupKillSent = false
  private var drainTimer: DispatchWorkItem?
  /// Every committed state change advances this.
  private(set) var revision: UInt64 = 0
  /// Owned by this pane: the generation of the last applied geometry
  /// request, whichever lease sent it, so it never goes backwards.
  private(set) var geometryGeneration: UInt64 = 0
  /// Advances with committed state changes only (not viewer captures).
  private var changeCount: UInt64 = 0
  /// Matches of the last viewer search, valid while `changeCount` holds.
  private var viewerSearchCache: ViewerSearchCache?

  private struct ViewerSearchCache {
    var query: String
    var change: UInt64
    var search: TerminalState.TerminalSearchSnapshot
  }
  /// Advances whenever the controller's window moves. The service reads
  /// it too: Ready counts only a frame of the current window.
  let currentViewport = Atomic<UInt64>(0)
  /// New on creation and on every full reset (RIS).
  private var terminalEpoch = TerminalEpochID()
  /// Clipboard requests the emulator deferred during a parse, emitted
  /// with the batch's other events.
  private let clipboardRequests = PendingPaneEvents()
  /// Status changes journaled per publish; past it the inbox resyncs
  /// from the records (intermediate transitions are then lost).
  static let statusJournalLimit = 4096

  static let drainBound: DispatchTimeInterval = .seconds(1)
  static let terminateGrace: DispatchTimeInterval = .seconds(2)

  init(
    id: PaneID,
    workspace: WorkspaceID,
    columns: Int,
    rows: Int,
    historyBytes: Int,
    innerTerm: String = SMX.fallbackInnerTerm,
    limits: MuxLimits,
    scrollbackCompression: Bool = true,
    observingIO: (@Sendable (PaneID, PaneIOObservation) -> Void)? = nil,
  ) {
    self.id = id
    self.workspace = workspace
    self.limits = limits
    observePaneIO = observingIO
    queue = DispatchQueue(
      label: "swiftmux.pane.\(id.short)",
      qos: .userInitiated,
    )
    self.historyBytes = historyBytes
    state = TerminalState(
      columns: columns,
      rows: rows,
      scrollbackLimitBytes: historyBytes,
      scrollbackLimitRows: limits.historyRowsPerPane,
    )
    // The inner identity matches the TERM panes run under; enhanced
    // keyboard reporting and clipboard writes are not offered.
    state.terminalVersion =
      "swmux \(SMX.build.split(separator: "-").last ?? "")"
    state.terminfoName = innerTerm
    state.keyboardProtocolEnabled = false
    state.clipboardWritesAdvertised = false
    // The kitty clipboard reaches the controlling app, which may prompt;
    // the service answers if no app can.
    let requests = clipboardRequests
    state.kittyClipboardReader = { [id] request in
      requests.events.withLock {
        $0.append(
          .clipboardRead(
            MuxClipboardRead(
              pane: id,
              token: request.token,
              mimes: request.mimes,
              list: request.list,
              name: request.name,
              granted: request.granted,
              canRemember: request.canRemember
            )
          )
        )
      }
      return .deferred
    }
    state.kittyClipboardWriter = { [id] request in
      requests.events.withLock {
        $0.append(
          .clipboardWrite(
            MuxClipboardWrite(
              pane: id,
              token: request.token,
              contents: request.contents.map {
                MuxClipboardContent(mime: $0.mime, data: Data($0.data))
              },
              name: request.name,
              granted: request.granted,
              canRemember: request.canRemember
            )
          )
        )
      }
      return .deferred
    }
    // OSC 7501 feeds the attention inbox, hidden or not.
    state.programStatusEnabled = true
    state.programStatusCapacity = limits.statusRecordsPerPane
    state.programStatusJournalLimit = Self.statusJournalLimit
    writer = PaneWriter(replyReserve: limits.replyReserveBytes)
    readBuffer = .allocate(byteCount: limits.readTurnBytes, alignment: 16)
    state.setScrollbackCompression(scrollbackCompression)
    if state.scrollbackCompression.effective {
      scrollbackMaintenance = ScrollbackMaintenanceClient(
        queue: queue,
        step: { [weak self] generation in
          self?.state.maintainScrollback(expectedGeneration: generation)
        },
        release: { [weak self] in self?.state.releaseScrollbackWorkspace() }
      )
    }
  }

  deinit {
    scrollbackMaintenance?.cancel()
    // Weak source callbacks cannot run once deinitialization starts.
    // Transfer exclusive reaping without retaining the service or PTY.
    exitSource?.cancel()
    exitPoll?.cancel()
    replyExitPoll?.cancel()
    if pid > 0, exitStatus == nil {
      kill(-pid, SIGHUP)
      kill(pid, SIGHUP)
      PTYProcessShutdown.start(pid)
    }
    setReadActive(true)
    readSource?.cancel()
    if let writeSource {
      // Never release a suspended source.
      if !writeActive { writeSource.resume() }
      writeSource.cancel()
    }
    if master >= 0 { close(master) }
    if slave >= 0 { close(slave) }
    readBuffer.deallocate()
  }

  // MARK: Launch

  /// Spawns the pane's process. Call on `queue`.
  func launch(_ spec: LaunchSpec, launcher: PaneLauncher) throws(MuxError) {
    dispatchPrecondition(condition: .onQueue(queue))
    let p = try launcher.launch(
      spec,
      pane: id,
      workspace: workspace,
      columns: state.columns,
      rows: state.rows,
    )
    master = p.master
    slave = p.slave
    let (stored, _) = spawnedPID.compareExchange(
      expected: 0,
      desired: p.pid,
      ordering: .releasing
    )
    precondition(stored, "a pane spawns one process")
    let fd = master
    let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    read.setEventHandler { [weak self] in self?.readAvailable() }
    read.resume()
    readSource = read
    readSourceActive = true
    let write = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
    write.setEventHandler { [weak self] in self?.flush() }
    writeSource = write  // resumed only while output is pending
    let exit = DispatchSource.makeProcessSource(
      identifier: pid,
      eventMask: .exit,
      queue: queue,
    )
    exit.setEventHandler { [weak self] in self?.childExited() }
    exit.resume()
    exitSource = exit
    // The child may have exited before the source was armed. Defer the
    // check until this launch turn has queued service registration; it
    // can synchronously drain output and emit the final lifecycle event.
    queue.async { [weak self] in self?.childExited(pollIfNeeded: false) }
  }

  // MARK: Output

  private func readAvailable() {
    guard master >= 0, !processingRead else { return }
    processingRead = true
    defer { processingRead = false }
    var budget = limits.readTurnBytes
    var parsedAny = false
    var sawEOF = false
    while budget > 0 {
      guard enqueueReplies() else {
        setReadActive(false)
        publish()
        return
      }
      setReadActive(true)
      if bufferedRead.isEmpty {
        let n = Darwin.read(
          master,
          readBuffer.baseAddress,
          min(budget, readBuffer.count),
        )
        if n > 0 {
          observeIO(
            .read,
            bytes: UnsafeRawBufferPointer(rebasing: readBuffer[..<n])
          )
          bufferedRead = 0 ..< n
        } else {
          if n < 0, errno == EINTR { continue }
          if n < 0, errno == EAGAIN { break }
          sawEOF = true
          break
        }
      }
      let chunk = UnsafeBufferPointer(
        start: readBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
          + bufferedRead.lowerBound,
        count: bufferedRead.count,
      )
      let consumed = parser.consumePrefix(chunk, into: &state, replyLimit: 1)
      bufferedRead =
        (bufferedRead.lowerBound + consumed) ..< bufferedRead.upperBound
      budget -= consumed
      parsedAny = true
    }
    if parsedAny { publish() }
    if !state.output.isEmpty { setReadActive(false) }
    if sawEOF {
      setReadActive(true)
      readSource?.cancel()
      readSource = nil
      readSourceActive = false
      if exitStatus != nil { finish() }
    }
  }

  /// One complete command can remain pending beyond the writer reserve.
  /// Its reply is retained separately, without parsing more input into it.
  private func enqueueReplies() -> Bool {
    guard !state.output.isEmpty else { return true }
    state.output.withUnsafeBytes { observeIO(.replyGenerated, bytes: $0) }
    if childIsExiting || exitStatus != nil || finished
      || state.output.count > writer.replyReserve
    {
      // Dead children cannot use replies. A custom reserve smaller than
      // one command retains the existing oversized-reply drop policy.
      state.output.withUnsafeBytes { observeIO(.replyDropped, bytes: $0) }
      state.output.removeAll(keepingCapacity: true)
      return true
    }
    guard writer.appendReply(state.output) else { return false }
    state.output.withUnsafeBytes { observeIO(.replyQueued, bytes: $0) }
    state.output.removeAll(keepingCapacity: true)
    flush()
    return true
  }

  private func setReadActive(_ active: Bool) {
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

  /// Darwin may delay NOTE_EXIT until the controlling terminal drains.
  /// The short BSD record exposes exit-in-progress without a terminal lock.
  private func pollPausedExit() {
    guard replyExitPoll == nil else { return }
    let poll = DispatchSource.makeTimerSource(queue: queue)
    poll.schedule(
      deadline: .now() + .milliseconds(25),
      repeating: .milliseconds(25),
    )
    poll.setEventHandler { [weak self] in
      guard let self, !self.finished, !self.readSourceActive else { return }
      guard PTYProcessExit.hasStartedExiting(self.pid) else { return }
      self.childIsExiting = true
      self.readAvailable()
    }
    replyExitPoll = poll
    poll.resume()
  }

  /// Flushes replies and events, then notifies the service once.
  private func publish() {
    state.refreshSearchIfNeeded()
    _ = enqueueReplies()
    publishStatus()
    // This service does not expose tmux control-mode streams. Drain their
    // bytes with each batch instead of retaining the entire stream.
    state.controlModeData.removeAll(keepingCapacity: true)
    for event in state.takeEvents() {
      switch event {
      case let .title(raw):
        // Cleaned once here for every client's chrome.
        onEvent?(.title(DisplayText.sanitize(raw)))
      case .bell: onEvent?(.bell)
      case let .workingDirectory(d): onEvent?(.workingDirectory(d))
      default: break  // OSC 52 clipboard writes are disabled
      }
    }
    let requests = clipboardRequests.events.withLock { requests in
      defer { requests.removeAll() }
      return requests
    }
    for request in requests { onEvent?(request) }
    _ = state.takeDamage()
    noteScrollbackActivity()
    noteChange()
  }

  /// One activity record per batch; storage work never changes
  /// `changeCount`, damage or published frames.
  private func noteScrollbackActivity() {
    guard let scrollbackMaintenance else { return }
    _ = state.takeScrollbackMaintenanceDirty()
    scrollbackMaintenance.noteActivity(generation: state.scrollbackGeneration)
  }

  /// After a capture or inspection promoted cold history, rearms
  /// maintenance without postponing it.
  private func rearmScrollbackMaintenanceIfNeeded() {
    guard let scrollbackMaintenance, state.takeScrollbackMaintenanceDirty()
    else { return }
    scrollbackMaintenance.requestMaintenance(
      generation: state.scrollbackGeneration
    )
  }

  /// Converts the status journal into owned changes, splitting it at
  /// each reset into a new terminal epoch.
  private func publishStatus() {
    guard let journal = state.takeProgramStatusJournal() else { return }
    var batch: [StatusChange] = []
    var epochChanged = false
    for change in journal.changes {
      switch change {
      case let .report(record): batch.append(.report(Self.status(record)))
      case let .removed(ids): batch.append(.removed(ids))
      case .reset:
        if !batch.isEmpty { onEvent?(.status(terminalEpoch, batch)) }
        batch = []
        terminalEpoch = TerminalEpochID()
        epochChanged = true
      }
    }
    if journal.truncated {
      batch.append(.sync(journal.snapshot.records.map(Self.status)))
    }
    if !batch.isEmpty || epochChanged {
      onEvent?(.status(terminalEpoch, batch))
    }
  }

  static func status(_ r: ProgramStatusRecord) -> StatusRecord {
    let state: AttentionState =
      switch r.state {
      case .idle: .idle
      case .working: .working
      case .done: .done
      case .blocked: .blocked
      case .error: .error
      }
    let kind: AttentionBlockedKind? =
      switch r.kind {
      case .permission?: .permission
      case .question?: .question
      case .auth?: .auth
      case nil: nil
      }
    return StatusRecord(
      path: r.id,
      state: state,
      kind: kind,
      progress: r.progress,
      app: r.app,
      title: r.title,
      message: r.message,
    )
  }

  private func noteChange() {
    revision &+= 1
    changeCount &+= 1
    if !changePosted.exchange(true, ordering: .acquiringAndReleasing) {
      onChange?()
    }
  }

  // MARK: Input

  /// Admission happened in the service; `estimate` was reserved.
  func write(_ input: MuxInput, estimate: Int) {
    queue.async { [self] in
      noteScrollbackActivity()
      guard master >= 0, exitStatus == nil else {
        release(estimate)
        return
      }
      var bytes: [UInt8] = []
      let terminalInputs: [TerminalInput] =
        switch input {
        case let .text(s): [.text(s)]
        case let .key(key, mods):
          [.key(KeyEvent(Self.key(key), modifiers: Self.modifiers(mods)))]
        case let .focus(f): [.focus(f)]
        case let .paste(s): [.paste(s)]
        case let .mouse(m):
          // Reported only while the program asks; the frontend's view of
          // the modes may be a frame behind.
          state.modes.isDisjoint(with: .mouseTracking)
            ? [] : [.mouse(Self.mouse(m))]
        case let .moveCursor(address, column):
          promptClick(to: address, column: column)
        case let .clipboardPaste(types):
          // Nothing when the program turned paste events off meanwhile.
          state.kittyPasteEvent(available: types).map { [.bytes($0)] } ?? []
        case let .drag(drag): dragReport(drag).map { [.bytes($0)] } ?? []
        }
      // Enhanced keyboard reporting is disabled in this profile.
      for terminalInput in terminalInputs {
        InputEncoder.encode(
          terminalInput,
          modes: state.modes,
          keyboardFlags: 0,
          into: &bytes,
        )
      }
      switch input {
      case .focus, .mouse, .drag: break
      case .moveCursor where bytes.isEmpty: break
      default:
        guard state.viewportOffset != 0 else { break }
        state.scrollViewportToBottom()
        advanceViewport()
        noteChange()
      }
      adjust(by: bytes.count - estimate)
      guard !bytes.isEmpty else { return }
      writer.appendInput(bytes)
      flush()
    }
  }

  /// Arrow keys moving the shell's cursor to a cell of its command line,
  /// or its `click_events` report; none when the address is stale or
  /// outside it.
  private func promptClick(
    to address: HistoryAddress,
    column: Int
  ) -> [TerminalInput] {
    guard address.generation == state.addressingGeneration,
      address.alternateScreen == state.isAlternateScreen,
      let action = state.promptClickAction(
        at: TerminalPoint(row: address.row, column: column)
      )
    else { return [] }
    let moves: Int
    switch action {
    case let .report(bytes): return [.bytes(bytes)]
    case let .moves(count): moves = count
    }
    guard moves.magnitude <= MuxInput.maxCursorMoves else { return [] }
    return Array(
      repeating: .key(KeyEvent(moves < 0 ? .left : .right)),
      count: Int(moves.magnitude)
    )
  }

  static func mouse(_ m: MuxMouse) -> MouseEvent {
    let action: MouseEvent.Action =
      switch m.action {
      case .press: .press
      case .release: .release
      case .motion: .motion
      }
    let button: MouseEvent.Button =
      switch m.button {
      case .left: .left
      case .middle: .middle
      case .right: .right
      case .none: .none
      case .wheelUp: .wheelUp
      case .wheelDown: .wheelDown
      case .wheelLeft: .wheelLeft
      case .wheelRight: .wheelRight
      }
    return MouseEvent(
      action,
      button,
      column: max(0, m.column),
      row: max(0, m.row),
      modifiers: modifiers(m.modifiers)
    )
  }

  func pasteBegin(id: UInt64, estimate: Int) {
    queue.async { [self] in
      guard master >= 0, !finished, !writer.hasOpenPaste else {
        release(estimate)
        return
      }
      if state.viewportOffset != 0 {
        state.scrollViewportToBottom()
        advanceViewport()
        noteChange()
      }
      let before = writer.pendingInputBytes
      writer.beginPaste(
        id: id,
        bracketed: state.modes.contains(.bracketedPaste),
      )
      adjust(by: (writer.pendingInputBytes - before) - estimate)
      flush()
    }
  }

  func pasteChunk(id: UInt64, text: String, estimate: Int) {
    queue.async { [self] in
      guard master >= 0, !finished, writer.paste?.id == id else {
        release(estimate)
        return
      }
      let before = writer.pendingInputBytes
      writer.appendPaste(id: id, text: text)
      adjust(by: (writer.pendingInputBytes - before) - estimate)
      flush()
    }
  }

  func pasteEnd(id: UInt64) {
    queue.async { [self] in
      writer.endPaste(id: id)
      flush()
    }
  }

  /// Disconnect, cancellation or limit failure. `completion` reports the
  /// outcome by what reached the program: `partial` once any payload
  /// byte was written (it cannot be rolled back), `aborted` when none was.
  /// A cancelled paste is never `completed`: its sender gave up on the
  /// rest, as the client reports it.
  func pasteCancel(
    id: UInt64,
    discardDeferredInput: Bool = false,
    completion: @escaping @Sendable (PasteState) -> Void,
  ) {
    queue.async { [self] in
      let (discarded, wrote) = writer.cancelPaste(
        id: id,
        discardDeferredInput: discardDeferredInput
      )
      release(discarded)
      flush()
      completion(wrote ? .partial : .aborted)
    }
  }

  /// Drops this pane's unwritten user input. Queued ahead of any later
  /// writer's bytes when a lease is released.
  func discardUnwrittenInput() {
    queue.async { [self] in
      release(writer.discardUnwrittenInput())
      flush()
    }
  }

  private func flush() {
    guard master >= 0 else { return }
    let fd = master
    guard
      let released = writer.flush({ buffer in
        var offset = 0
        while offset < buffer.count {
          let n = Darwin.write(
            fd,
            buffer.baseAddress! + offset,
            buffer.count - offset,
          )
          if n > 0 {
            observeIO(
              .written,
              bytes: UnsafeRawBufferPointer(
                rebasing: buffer[offset ..< offset + n]
              )
            )
            offset += n
            continue
          }
          if n < 0, errno == EINTR { continue }
          if n < 0, errno == EAGAIN {
            observeIO(
              .writeBlocked,
              bytes: UnsafeRawBufferPointer(rebasing: buffer[offset...]),
              error: errno
            )
            break
          }
          observeIO(
            .writeFailed,
            bytes: UnsafeRawBufferPointer(rebasing: buffer[offset...]),
            error: n < 0 ? errno : nil
          )
          return offset > 0 ? offset : nil
        }
        return offset
      })
    else {
      release(writer.discardAll())
      setWriteActive(false)
      if !readSourceActive { readAvailable() }
      return
    }
    release(released)
    setWriteActive(!writer.isEmpty)
    if !readSourceActive { readAvailable() }
  }

  private func setWriteActive(_ active: Bool) {
    guard let writeSource, active != writeActive else { return }
    writeActive = active
    if active { writeSource.resume() } else { writeSource.suspend() }
  }

  private func observeIO(
    _ phase: PaneIOObservation.Phase,
    bytes: UnsafeRawBufferPointer,
    error: Int32? = nil
  ) {
    guard let observePaneIO else { return }
    observePaneIO(
      id,
      PaneIOObservation(
        phase: phase,
        byteCount: bytes.count,
        prefix: Array(bytes.prefix(256)),
        error: error
      )
    )
  }

  private func release(_ n: Int) { adjust(by: -n) }

  private func adjust(by delta: Int) {
    guard delta != 0 else { return }
    outstandingInput.withLock { $0 = max(0, $0 + delta) }
  }

  /// Reserves credit for admission; false when over the per-pane budget.
  func reserve(_ bytes: Int) -> Bool {
    outstandingInput.withLock { value in
      guard value + bytes <= limits.inputBytesPerPane else { return false }
      value += bytes
      return true
    }
  }

  // MARK: Geometry, history and search

  /// Engine resize, then `TIOCSWINSZ`, in this pane's order. Returns the
  /// geometry generation frames carry once this request is applied.
  @discardableResult
  func resize(columns: Int, rows: Int) -> UInt64 {
    let (generation, schedule) = resizes.withLock { requests in
      requests.requested &+= 1
      requests.pending = ResizeRequest(
        columns: columns,
        rows: rows,
        generation: requests.requested,
      )
      guard !requests.scheduled else { return (requests.requested, false) }
      requests.scheduled = true
      return (requests.requested, true)
    }
    if schedule { scheduleResize() }
    return generation
  }

  /// One running resize and one replaceable pending request. Queue the next
  /// turn at the tail so sustained geometry traffic cannot starve input.
  private func scheduleResize() {
    queue.async { [self] in
      let request = resizes.withLock { requests in
        let request = requests.pending!
        requests.pending = nil
        return request
      }
      applyResize(request)
      let again = resizes.withLock { requests in
        if requests.pending != nil { return true }
        requests.scheduled = false
        return false
      }
      if again { scheduleResize() }
    }
  }

  private func applyResize(_ request: ResizeRequest) {
    geometryGeneration = request.generation
    guard request.columns != state.columns || request.rows != state.rows else {
      noteChange()
      return
    }
    state.resize(columns: request.columns, rows: request.rows)
    if master >= 0 {
      var size = winsize(
        ws_row: UInt16(clamping: state.rows),
        ws_col: UInt16(clamping: state.columns),
        ws_xpixel: 0,
        ws_ypixel: 0,
      )
      _ = ioctl(master, TIOCSWINSZ, &size)
    }
    publish()
  }

  func scroll(
    _ request: ScrollRequest,
    completion: @escaping @Sendable (MuxError?) -> Void,
  ) {
    queue.async { [self] in
      switch request {
      case let .lines(n): state.scrollViewport(by: n)
      case let .pages(n):
        // The engine clamps to history; only the product can overflow.
        let (lines, overflow) = n.multipliedReportingOverflow(
          by: max(1, state.rows - 1),
        )
        state.scrollViewport(by: overflow ? (n < 0 ? .min : .max) : lines)
      case .bottom: state.scrollViewportToBottom()
      case .oldest: state.scrollViewport(by: .max)
      case let .prompt(n):
        guard state.jumpToPrompt(n) else {
          completion(MuxError(.notFound, "no such prompt"))
          return
        }
      case let .top(address):
        guard address.generation == state.addressingGeneration,
          address.alternateScreen == state.isAlternateScreen,
          state.contains(absoluteRow: address.row)
        else {
          completion(MuxError(.historyUnavailable, "history address is stale"))
          return
        }
        state.scrollViewport(by: -state.viewportRow(absoluteRow: address.row))
      }
      advanceViewport()
      noteChange()
      completion(nil)
    }
  }

  /// Moves the controller viewport to an anchor, addressed as a viewer's
  /// is (either screen); `followTail` returns it to live output.
  func setViewport(
    followTail: Bool,
    historyGeneration: UInt64,
    anchorRow: Int?,
    completion: @escaping @Sendable (MuxError?) -> Void,
  ) {
    queue.async { [self] in
      guard
        place(
          followTail: followTail,
          historyGeneration: historyGeneration,
          anchorRow: anchorRow,
        )
      else {
        completion(MuxError(.historyUnavailable, "history anchor is stale"))
        return
      }
      advanceViewport()
      noteChange()
      completion(nil)
    }
  }

  /// A step with nothing to select, or an end with no search, changes
  /// nothing.
  func search(
    _ query: String?,
    step forward: Bool?,
    completion: @escaping @Sendable (SearchResult) -> Void,
  ) {
    queue.async { [self] in
      let changes: Bool
      if let query {
        state.search(query)
        state.selectSearchMatch(forward: false)
        changes = true
      } else if let forward {
        // Nothing to step to: the window stays. (Matches are current:
        // the parser refreshes them after every read.)
        changes = state.selectSearchMatch(forward: forward) != nil
      } else {
        changes = state.isSearching
        state.endSearch()
      }
      if changes {
        advanceViewport()
        noteChange()
      }
      completion(
        SearchResult(
          matchCount: state.searchMatches.count,
          selected: state.searchSelected,
        ),
      )
    }
  }

  // MARK: Terminal control and shell integration

  /// Clears the screen, keeping the cursor's line, as the direct view's
  /// Clear Screen does.
  func clearScreen() {
    queue.async { [self] in
      guard !finished else { return }
      state.clearScreenKeepingCursorLine()
      advanceViewport()
      noteChange()
    }
  }

  /// The program's report of a native drag; nil without a registration.
  /// Dropped items that could not be served in one reply are left out.
  private func dragReport(_ drag: MuxDrag) -> [UInt8]? {
    func position(_ p: MuxDragPosition) -> KittyDragAndDrop.MoveEvent {
      var operations: KittyDragAndDrop.Operations = []
      if p.allowsCopy { operations.insert(.copy) }
      if p.allowsMove { operations.insert(.move) }
      return KittyDragAndDrop.MoveEvent(
        column: UInt32(clamping: max(0, p.column)),
        row: UInt32(clamping: max(0, p.row)),
        pixelX: Int32(clamping: p.pixelX),
        pixelY: Int32(clamping: p.pixelY),
        operations: operations
      )
    }
    switch drag {
    case let .move(p, types): return state.dragMove(position(p), mimes: types)
    case let .drop(p, items):
      return state.dragDrop(
        position(p),
        items:
          items.filter { Self.replyFits([$0], reserve: writer.replyReserve) }
          .map { KittyDragAndDrop.Item(mime: $0.mime, data: Array($0.data)) }
      )
    case .leave: return state.dragLeave()
    }
  }

  /// Answers a deferred kitty clipboard read. Contents whose reply would
  /// not fit the pane's reply reserve answer EIO rather than being lost.
  func completeClipboardRead(_ token: UInt64, _ result: MuxClipboardReadResult)
  {
    queue.async { [self] in
      guard !finished else { return }
      let answer: KittyClipboard.ReadResult =
        switch result {
        case let .success(available, contents, remember):
          Self.replyFits(contents, reserve: writer.replyReserve)
            ? .success(
              available: available,
              contents: contents.map {
                KittyClipboard.Content(mime: $0.mime, data: Array($0.data))
              },
              remember: remember
            ) : .ioError
        case .denied: .denied
        case .unsupported: .unsupported
        case .busy: .busy
        case .ioError: .ioError
        }
      state.completeKittyClipboardRead(token, with: answer)
      _ = enqueueReplies()
    }
  }

  func completeClipboardWrite(
    _ token: UInt64,
    _ result: MuxClipboardWriteResult
  ) {
    queue.async { [self] in
      guard !finished else { return }
      let answer: KittyClipboard.WriteResult =
        switch result {
        case let .success(remember): .success(remember: remember)
        case .denied: .denied
        case .unsupported: .unsupported
        case .busy: .busy
        case .invalidData: .invalidData
        case .ioError: .ioError
        }
      state.completeKittyClipboardWrite(token, with: answer)
      _ = enqueueReplies()
    }
  }

  /// Whether `contents`, base64-encoded in DATA packets, fit one reply.
  static func replyFits(_ contents: [MuxClipboardContent], reserve: Int) -> Bool
  {
    let raw = contents.reduce(0) { $0 + $1.data.count + $1.mime.utf8.count }
    let packets = contents.reduce(0) { $0 + $1.data.count / 4096 + 1 }
    return (raw + 2) / 3 * 4 + packets * 96 + 1024 <= reserve
  }

  /// Full reset (RIS) of the emulator; the process keeps running.
  func resetTerminal() {
    queue.async { [self] in
      guard !finished else { return }
      parser = Parser()
      state.reset()
      publishStatus()
      advanceViewport()
      noteChange()
    }
  }

  private func point(_ address: HistoryAddress, column: Int) -> TerminalPoint? {
    guard address.generation == state.addressingGeneration,
      address.alternateScreen == state.isAlternateScreen,
      state.contains(absoluteRow: address.row)
    else { return nil }
    return TerminalPoint(row: address.row, column: column)
  }

  private func address(_ row: Int) -> HistoryAddress {
    HistoryAddress(
      generation: state.addressingGeneration,
      alternateScreen: state.isAlternateScreen,
      row: row
    )
  }

  func link(
    at address: HistoryAddress,
    column: Int,
    detectURLs: Bool,
    completion: @escaping @Sendable (MuxLink?) -> Void,
  ) {
    queue.async { [self] in
      guard let p = point(address, column: column),
        let link = state.link(at: p, detectURLs: detectURLs)
      else { return completion(nil) }
      completion(
        MuxLink(
          url: link.url,
          start: self.address(link.range.start.row),
          startColumn: link.range.start.column,
          end: self.address(link.range.end.row),
          endColumn: link.range.end.column
        )
      )
    }
  }

  /// The output around `address`, or the most recent command with
  /// output; scrolled into view as the direct view's selection is.
  func commandOutput(
    at address: HistoryAddress?,
    completion: @escaping @Sendable (CommandOutput?) -> Void,
  ) {
    queue.async { [self] in
      let click = address.flatMap { point($0, column: 0) }
      let prompts = state.promptRows()
      var output = state.commandOutputRange(
        at: click ?? TerminalPoint(row: prompts.last ?? 0, column: 0)
      )
      if output == nil, click == nil {
        // Fresh prompts and commands without output are skipped.
        for boundary in prompts.reversed() {
          output = state.commandOutputRange(
            at: TerminalPoint(row: boundary - 1, column: 0)
          )
          if output != nil { break }
        }
      }
      guard let range = output else { return completion(nil) }
      let before = state.viewportOffset
      state.scrollToShow(row: range.start.row)
      if state.viewportOffset != before {
        advanceViewport()
        noteChange()
      }
      completion(
        CommandOutput(
          start: self.address(range.start.row),
          end: self.address(range.end.row),
          text: state.text(from: range.start, to: range.end)
        )
      )
    }
  }

  /// Frontend theme: default colours and scheme, as a theme change does.
  func setTheme(_ theme: MuxTheme) {
    queue.async { [self] in
      var colors = InlineArray<256, UInt32>(repeating: 0)
      for i in 0 ..< 256 { colors[i] = theme.palette.colors[i] }
      let p = theme.palette
      state.setDefaultPalette(
        Palette(
          colors: colors,
          foreground: p.foreground,
          background: p.background,
          cursor: p.cursor,
          cursorText: p.cursorText,
          selectionForeground: p.selectionForeground,
          selectionBackground: p.selectionBackground,
        ),
      )
      state.setColorScheme(theme.dark ? .dark : .light)
      publish()
    }
  }

  private func advanceViewport() {
    currentViewport.wrappingAdd(1, ordering: .releasing)
  }

  /// Returns the viewport to live output and clears search (detach).
  func resetViewport() {
    queue.async { [self] in
      state.endSearch()
      state.scrollViewportToBottom()
      advanceViewport()
      noteChange()
    }
  }

  // MARK: Frames

  struct CapturedFrame: Sendable {
    var data: Data
    var revision: UInt64
    var geometry: UInt64
    /// The viewport (a viewer's window) the frame shows.
    var viewportRevision: UInt64

    var sent: SentFrame {
      SentFrame(
        revision: revision,
        bytes: data.count,
        geometry: geometry,
        viewport: viewportRevision,
      )
    }
  }

  /// Result of applying a viewer's anchor without touching the engine
  /// viewport that the controller is using.
  struct ResolvedViewport: Sendable {
    var followTail: Bool
    var historyGeneration: UInt64
    var anchorRow: Int?
    var search: SearchResult?
    var selectedMatch: SelectedMatch?
  }

  /// Captures cells and metadata in one operation and encodes the frame
  /// message, off the service queue. `viewport` nil uses the controller's
  /// engine viewport. A viewer viewport is applied only for the capture
  /// and then restored, so it cannot move the controller or the PTY.
  func captureFrame(
    server: ServerInstanceID,
    attachment: AttachmentID,
    layoutRevision: UInt64,
    viewport: ViewerViewport? = nil,
    completion: @escaping @Sendable (Result<CapturedFrame, MuxError>) -> Void,
  ) {
    queue.async { [self] in
      // The controller's capture uses the engine state as it is; only a
      // viewer window needs saving and restoring around the capture.
      var saved: (offset: Int, search: TerminalState.TerminalSearchSnapshot)?
      if let viewport {
        saved = (state.viewportOffset, state.snapshotSearch())
        if let failure = apply(viewport) {
          restore(offset: saved!.offset, search: saved!.search)
          completion(.failure(failure))
          return
        }
      } else {
        state.refreshSearchIfNeeded()
      }
      var screen = state.captureOwnedScreen()
      let selected = state.searchSelected
      let geometry = geometryGeneration
      // A viewer capture does not share the controller's revision: each
      // exported frame for this pane stays strictly newer than the last.
      if viewport != nil { revision &+= 1 }
      let shownRevision =
        viewport?.revision ?? currentViewport.load(ordering: .relaxed)
      if let saved { restore(offset: saved.offset, search: saved.search) }
      rearmScrollbackMaintenanceIfNeeded()
      if let viewport {
        fit(
          &screen,
          columns: viewport.columns ?? screen.columns,
          rows: viewport.rows ?? screen.rows,
        )
      }
      let identity = FrameIdentity(
        server: server,
        attachment: attachment,
        pane: id,
        revision: revision,
        layoutRevision: layoutRevision,
        geometryGeneration: geometry,
        viewportRevision: shownRevision,
      )
      do {
        var frame = try FrameExporter.frame(
          from: screen,
          identity: identity,
          limits: limits,
        )
        frame.search?.selected = selected
        let data = try SMXCodec.encode(
          ServerMessage.event(.frame(frame)),
          limit: limits.maxFrameBytes,
        )
        completion(
          .success(
            CapturedFrame(
              data: data,
              revision: revision,
              geometry: geometry,
              viewportRevision: shownRevision,
            )
          )
        )
      } catch let error as MuxError { completion(.failure(error)) } catch {
        completion(.failure(MuxError(.resourceLimit, "\(error)")))
      }
    }
  }

  /// Checks an anchor and, for a search, the match list. A relative
  /// `scroll` moves from the viewer's anchor and stops at the history
  /// edges. Searches and scrolls start from the viewer's own window (the
  /// tail when its anchor is stale), never from the controller's.
  /// Restores the controller viewport and search before returning.
  func resolveViewer(
    _ request: ViewportRequest,
    searchQuery: String?,
    searchStep: Bool?,
    searchSelected: SelectedMatch? = nil,
    scroll: ScrollRequest? = nil,
    completion: @escaping @Sendable (Result<ResolvedViewport, MuxError>) -> Void,
  ) {
    queue.async { [self] in
      let savedOffset = state.viewportOffset
      let savedSearch = state.snapshotSearch()
      defer { restore(offset: savedOffset, search: savedSearch) }
      let anchored = place(
        followTail: request.followTail,
        historyGeneration: request.historyGeneration,
        anchorRow: request.anchorRow,
      )
      let searching = searchQuery != nil || searchStep != nil
      // A stale anchor leaves the controller's viewport in place; a search
      // or scroll must start from the tail instead.
      if !anchored, searching || scroll != nil {
        state.scrollViewportToBottom()
      }
      if let searchStep {
        if let searchQuery, !searchQuery.isEmpty { viewerSearch(searchQuery) }
        // `search` clears the selection. Continue from the viewer's match
        // so a step does not jump back to the last occurrence.
        reselect(searchSelected)
        _ = state.selectSearchMatch(forward: searchStep)
      } else if let searchQuery {
        viewerSearch(searchQuery)
        _ = state.selectSearchMatch(forward: false)
      } else if let scroll {
        switch scroll {
        case let .lines(n): state.scrollViewport(by: n)
        case let .pages(n):
          // A page is the viewer's display height, not the PTY's.
          let page = max(1, (request.rows ?? state.rows) - 1)
          let (lines, overflow) = n.multipliedReportingOverflow(by: page)
          state.scrollViewport(by: overflow ? (n < 0 ? .min : .max) : lines)
        case .bottom: state.scrollViewportToBottom()
        case .oldest: state.scrollViewport(by: .max)
        case let .prompt(n): state.jumpToPrompt(n)
        case .top: break
        }
      } else if !anchored {
        completion(
          .failure(MuxError(.historyUnavailable, "history anchor is stale"))
        )
        return
      }
      let searchResult: SearchResult? =
        searching
        ? SearchResult(
          matchCount: state.searchMatches.count,
          selected: state.searchSelected,
        ) : nil
      let follow =
        request.followTail && !searching && scroll == nil
        ? true : state.viewportOffset == 0
      completion(
        .success(
          ResolvedViewport(
            followTail: follow,
            historyGeneration: state.addressingGeneration,
            anchorRow: state.absoluteRow(viewportRow: 0),
            search: searchResult,
            selectedMatch: state.searchSelected.map {
              SelectedMatch(
                range: state.searchMatches[$0],
                index: $0,
                historyGeneration: state.addressingGeneration,
              )
            },
          )
        )
      )
    }
  }

  /// Moves the engine viewport to a viewer window. False when the anchor
  /// is stale; the viewport is then unchanged.
  private func place(
    followTail: Bool,
    historyGeneration: UInt64,
    anchorRow: Int?,
  ) -> Bool {
    if followTail {
      state.scrollViewportToBottom()
    } else if let row = anchorRow {
      guard historyGeneration == state.addressingGeneration,
        state.contains(absoluteRow: row)
      else { return false }
      state.scrollViewport(by: -state.viewportRow(absoluteRow: row))
    }
    return true
  }

  /// Runs a viewer search, reusing the matches of an identical search
  /// while the pane has not changed (several observers, one scan).
  private func viewerSearch(_ query: String) {
    if let cache = viewerSearchCache, cache.query == query,
      cache.change == changeCount
    {
      state.restoreSearch(cache.search)
      return
    }
    state.search(query)
    viewerSearchCache = ViewerSearchCache(
      query: query,
      change: changeCount,
      search: state.snapshotSearch(),
    )
  }

  /// Applies a viewer window for the duration of one capture. A viewer
  /// without a search of its own shows none, whatever the controller's.
  private func apply(_ viewport: ViewerViewport) -> MuxError? {
    let placed = place(
      followTail: viewport.followTail,
      historyGeneration: viewport.historyGeneration,
      anchorRow: viewport.anchorRow,
    )
    guard placed else {
      return MuxError(.historyUnavailable, "history anchor is stale")
    }
    if let query = viewport.searchQuery, !query.isEmpty {
      viewerSearch(query)
      reselect(viewport.searchSelected)
    } else {
      state.endSearch()
    }
    return nil
  }

  /// Reselects a viewer's match: by position within its history
  /// generation, else (rows renumbered by a clear, reflow or screen switch)
  /// by its place in the match list, as near as the new list allows.
  private func reselect(_ match: SelectedMatch?) {
    guard let match else { return }
    if match.historyGeneration == state.addressingGeneration {
      state.reselectSearchMatch(match.range)
    } else if !state.searchMatches.isEmpty {
      let index = min(match.index, state.searchMatches.count - 1)
      state.reselectSearchMatch(state.searchMatches[index])
    }
  }

  private func restore(
    offset: Int,
    search: TerminalState.TerminalSearchSnapshot
  ) {
    state.restoreSearch(search)
    let delta = offset - state.viewportOffset
    if delta != 0 { state.scrollViewport(by: delta) }
  }

  /// Crops or pads a captured grid. Does not change addressing of the
  /// rows that remain; the PTY size is the caller's responsibility.
  private func fit(_ screen: inout OwnedScreen, columns: Int, rows: Int) {
    guard columns > 0, rows > 0,
      columns != screen.columns || rows != screen.rows
    else { return }
    var cells: [Cell] = []
    cells.reserveCapacity(columns * rows)
    var wrapped: [Bool] = []
    wrapped.reserveCapacity(rows)
    for y in 0 ..< rows {
      let source = y < screen.rows
      wrapped.append(
        source && y < screen.wrapped.count ? screen.wrapped[y] : false
      )
      for x in 0 ..< columns {
        if source, x < screen.columns {
          cells.append(screen.cells[y * screen.columns + x])
        } else {
          cells.append(.blank)
        }
      }
    }
    screen.cells = cells
    screen.wrapped = wrapped
    screen.columns = columns
    screen.rows = rows
    screen.cursor.x = min(max(0, screen.cursor.x), columns - 1)
    screen.cursor.y = min(max(0, screen.cursor.y), rows - 1)
  }

  /// Plain text of the visible screen (tests, diagnostics).
  func screenLines() -> [String] { queue.sync { state.screenLines } }

  /// Metadata-only history storage accounting (tests, diagnostics).
  var scrollbackStatistics: ScrollbackStatistics {
    queue.sync { state.scrollbackStatistics }
  }

  /// Runs idle maintenance to completion now, as the coordinator would
  /// after a quiet period (tests). Publishes nothing.
  func compressScrollbackForTesting() -> ScrollbackStatistics {
    queue.sync {
      var budget = ScrollbackMaintenanceBudget()
      budget.maximumCandidates = 1 << 20
      budget.maximumUnits = 1 << 20
      while state.maintainScrollback(budget: budget) == .pending {}
      return state.scrollbackStatistics
    }
  }

  /// Captures teardown progress in pane order without signaling or reaping.
  func terminationStateForTesting() -> String {
    queue.sync {
      let now = DispatchTime.now().uptimeNanoseconds
      let remaining = terminationDeadline.map {
        $0.uptimeNanoseconds > now ? $0.uptimeNanoseconds - now : 0
      }
      return
        "pid=\(pid) terminating=\(terminating) exit=\(String(describing: exitStatus)) "
        + "finished=\(finished) forced=\(forcedTermination) groupKill=\(groupKillSent) "
        + "graceRemainingNs=\(String(describing: remaining)) drainPending=\(drainTimer != nil)"
    }
  }

  /// Runs `body` in this pane's order with the authoritative state, for
  /// exports other than `PaneFrame` (the roaming bridge's screens).
  func inspect<T: Sendable>(
    _ body: @escaping @Sendable (borrowing TerminalState) -> T,
    completion: @escaping @Sendable (T) -> Void,
  ) {
    queue.async { [self] in
      let value = body(state)
      rearmScrollbackMaintenanceIfNeeded()
      completion(value)
    }
  }

  var size: (columns: Int, rows: Int) {
    queue.sync { (state.columns, state.rows) }
  }

  // MARK: Lifetime

  private func childExited(pollIfNeeded: Bool = true) {
    guard exitStatus == nil, !finished else { return }
    if pollIfNeeded {
      // NOTE_EXIT can precede waitability while the controlling terminal
      // drains. Release reply pressure before checking the exit status.
      childIsExiting = true
      readAvailable()
    }
    var info = siginfo_t()
    var peek: Int32
    repeat {
      peek = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
    } while peek < 0 && errno == EINTR
    guard peek == 0 else {
      recordExit(-1)
      return
    }
    guard info.si_pid == pid else {
      if pollIfNeeded { pollExit() }
      return
    }
    childIsExiting = true
    readAvailable()
    if !groupKillSent, groupHasOtherMembers {
      if !terminating {
        // Preserve the natural final-output drain before hanging up any
        // descendants. Retain the leader until cleanup can safely signal
        // the group; collecting it first would permit ID reuse.
        let deadline = naturalDrainDeadline ?? (.now() + Self.drainBound)
        naturalDrainDeadline = deadline
        if DispatchTime.now() < deadline {
          pollExit()
          return
        }
        beginTermination()
      }
      if let deadline = terminationDeadline, DispatchTime.now() < deadline {
        pollExit()
        return
      }
      killOwnedGroup()
    }
    var status: Int32 = 0
    var result: pid_t
    repeat {
      result = waitpid(pid, &status, WNOHANG)
    } while result < 0 && errno == EINTR
    if result == 0 {
      pollExit()
      return
    }
    recordExit(result == pid ? status : -1)
  }

  /// Only a complete single-member result proves no descendants remain.
  /// A full buffer or a failed query keeps cleanup conservative.
  private var groupHasOtherMembers: Bool {
    var members = [pid_t](repeating: 0, count: 2)
    let count = members.withUnsafeMutableBytes {
      proc_listpgrppids(pid, $0.baseAddress, Int32($0.count))
    }
    return count != 1 || members[0] != pid
  }

  private func pollExit() {
    guard exitPoll == nil else { return }
    let poll = DispatchSource.makeTimerSource(queue: queue)
    poll.schedule(
      deadline: .now() + .milliseconds(25),
      repeating: .milliseconds(25),
    )
    poll.setEventHandler { [weak self] in self?.childExited() }
    exitPoll = poll
    poll.resume()
  }

  /// Called only after waitid confirms exclusive ownership of the leader.
  private func killOwnedGroup() {
    guard !groupKillSent else { return }
    groupKillSent = true
    forcedTermination = true
    kill(-pid, SIGKILL)
    kill(pid, SIGKILL)
  }

  private func recordExit(_ raw: Int32) {
    guard exitStatus == nil else { return }
    exitSource?.cancel()
    exitSource = nil
    exitPoll?.cancel()
    exitPoll = nil
    exitStatus =
      raw == -1
      ? -1 : ((raw & 0x7F) == 0 ? (raw >> 8) & 0xFF : 128 + (raw & 0x7F))
    // Drain what the PTY holds, then release our slave so EOF can arrive
    // once descendants also close it.
    readAvailable()
    if slave >= 0 {
      close(slave)
      slave = -1
    }
    if readSource == nil {
      finish()
      return
    }
    // Descendants may retain the slave; bound the wait.
    let timer = DispatchWorkItem { [weak self] in self?.finish() }
    drainTimer = timer
    queue.asyncAfter(deadline: .now() + Self.drainBound, execute: timer)
  }

  private func finish() {
    guard !finished else { return }
    finished = true
    readAvailable()
    drainTimer?.cancel()
    drainTimer = nil
    setReadActive(true)
    readSource?.cancel()
    readSource = nil
    readSourceActive = false
    bufferedRead = 0 ..< 0
    setWriteActive(true)  // a suspended source must not be released
    writeSource?.cancel()
    writeSource = nil
    writeActive = false
    release(writer.discardAll())
    if master >= 0 {
      // Hang up descendants still holding the slave.
      close(master)
      master = -1
    }
    if slave >= 0 {
      close(slave)
      slave = -1
    }
    parser = Parser()
    state.programExited()
    // The final status reaches the inbox before `finished`.
    publishStatus()
    noteChange()
    onEvent?(.finished(status: exitStatus ?? -1, forced: forcedTermination))
  }

  /// Bounded explicit termination of this pane's processes only.
  func terminate() {
    queue.async { [self] in
      guard !finished else {
        onEvent?(.finished(status: exitStatus ?? -1, forced: forcedTermination))
        return
      }
      guard pid > 0 else {
        finish()
        return
      }
      beginTermination()
    }
  }

  private func beginTermination() {
    guard !terminating else { return }
    terminating = true
    let deadline = DispatchTime.now() + Self.terminateGrace
    terminationDeadline = deadline
    if exitStatus == nil {
      kill(-pid, SIGHUP)
      kill(pid, SIGHUP)
    }
    queue.asyncAfter(deadline: deadline) { [self] in
      guard !finished else { return }
      forcedTermination = true
      if exitStatus == nil {
        var info = siginfo_t()
        var owned: Int32
        repeat {
          owned = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        } while owned < 0 && errno == EINTR
        if owned == 0 { killOwnedGroup() }
        childExited()
      } else {
        finish()
      }
    }
  }

  // MARK: Input mapping

  static func key(_ key: MuxKey) -> Key {
    switch key {
    case let .character(v): .character(Unicode.Scalar(v) ?? " ")
    case .enter: .enter
    case .tab: .tab
    case .backspace: .backspace
    case .escape: .escape
    case .up: .up
    case .down: .down
    case .left: .left
    case .right: .right
    case .home: .home
    case .end: .end
    case .pageUp: .pageUp
    case .pageDown: .pageDown
    case .insert: .insert
    case .delete: .delete
    case let .function(n): .function(min(max(n, 1), 12))
    case let .keypad(k):
      KeypadKey(rawValue: k.rawValue).map(Key.keypad) ?? .enter
    }
  }

  static func modifiers(_ m: MuxKeyModifiers) -> KeyModifiers {
    var out: KeyModifiers = []
    if m.contains(.shift) { out.insert(.shift) }
    if m.contains(.alt) { out.insert(.alt) }
    if m.contains(.control) { out.insert(.control) }
    return out
  }
}
