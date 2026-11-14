import Darwin
import Dispatch
import Foundation
import MuxAttention
import SwiftMuxExport
import SwiftMuxProtocol
import SwifttyEngine
import SwifttyJS
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
///
/// Input, geometry, terminal control and frame capture live in
/// `PaneRuntime+*.swift`. Queue-owned members are internal only so those
/// extensions can reach them; the confinement above still applies.
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

  struct ResizeRequest: Sendable {
    let columns: Int
    let rows: Int
    let generation: UInt64
  }

  struct ResizeState: Sendable {
    var pending: ResizeRequest?
    var scheduled = false
    /// Last generation handed out; a coalesced request skips some.
    var requested: UInt64 = 0
  }

  let resizes = Mutex(ResizeState())

  // Set once before use, read on `queue`.
  var onChange: (@Sendable () -> Void)?
  var onEvent: (@Sendable (PaneEvent) -> Void)?

  // MARK: Queue-owned state

  var state: TerminalState
  /// Idle history compression on this pane's queue; nil when off.
  private var scrollbackMaintenance: ScrollbackMaintenanceClient?
  var parser = Parser()
  var writer: PaneWriter
  let observePaneIO: (@Sendable (PaneID, PaneIOObservation) -> Void)?
  let javaScriptRuntime: JavaScriptRuntime?
  var master: Int32 = -1
  private var slave: Int32 = -1
  /// Set once at spawn on `queue`; read on the service queue too.
  private let spawnedPID = Atomic<pid_t>(0)
  /// The child's process id, 0 before spawn.
  var pid: pid_t { spawnedPID.load(ordering: .acquiring) }
  private var readSource: DispatchSourceRead?
  var readSourceActive = false
  private var processingRead = false
  private var replyExitPoll: DispatchSourceTimer?
  /// Unparsed bytes in readBuffer, held while reply capacity is exhausted.
  private var bufferedRead = 0 ..< 0
  private var childIsExiting = false
  var writeSource: DispatchSourceWrite?
  var writeActive = false
  private var exitSource: DispatchSourceProcess?
  private var exitPoll: DispatchSourceTimer?
  private let readBuffer: UnsafeMutableRawBufferPointer
  var exitStatus: Int32?
  var finished = false
  var forcedTermination = false
  var terminating = false
  private var naturalDrainDeadline: DispatchTime?
  var terminationDeadline: DispatchTime?
  var groupKillSent = false
  var drainTimer: DispatchWorkItem?
  /// Every committed state change advances this.
  var revision: UInt64 = 0
  /// Owned by this pane: the generation of the last applied geometry
  /// request, whichever lease sent it, so it never goes backwards.
  var geometryGeneration: UInt64 = 0
  /// Advances with committed state changes only (not viewer captures).
  var changeCount: UInt64 = 0
  /// Matches of the last viewer search, valid while `changeCount` holds.
  var viewerSearchCache: ViewerSearchCache?

  struct ViewerSearchCache {
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
  static let terminateGrace: DispatchTimeInterval = PTYProcessShutdown.grace

  init(
    id: PaneID,
    workspace: WorkspaceID,
    columns: Int,
    rows: Int,
    historyBytes: Int,
    innerTerm: String = SMX.fallbackInnerTerm,
    limits: MuxLimits,
    scrollbackCompression: Bool = true,
    javaScriptRuntime: JavaScriptRuntime? = nil,
    observingIO: (@Sendable (PaneID, PaneIOObservation) -> Void)? = nil,
  ) {
    self.id = id
    self.workspace = workspace
    self.limits = limits
    self.javaScriptRuntime = javaScriptRuntime
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
    if let javaScriptRuntime {
      state.onShellCommandFinished = { command, code in
        javaScriptRuntime.commandFinished(
          command: command,
          exitCode: code ?? -1,
          pane: id.description
        )
      }
    }
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

  func readAvailable() {
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
          if let javaScriptRuntime {
            let filtered = javaScriptRuntime.filter(
              Data(bytes: readBuffer.baseAddress!, count: n),
              stream: .stdout,
              pane: id.description,
              maximumBytes: readBuffer.count
            )
            _ = filtered.copyBytes(to: readBuffer.bindMemory(to: UInt8.self))
            bufferedRead = 0 ..< filtered.count
            // Parsing charges the replacement bytes below. Charge discarded
            // bytes too so shrinking filters cannot extend a PTY read turn.
            budget -= max(0, n - filtered.count)
            if filtered.isEmpty { continue }
          } else {
            bufferedRead = 0 ..< n
          }
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
  func enqueueReplies() -> Bool {
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
  func publish() {
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
      case let .workingDirectory(d):
        onEvent?(.workingDirectory(d))
        javaScriptRuntime?.directoryChanged(d, pane: id.description)
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
  func noteScrollbackActivity() {
    guard let scrollbackMaintenance else { return }
    _ = state.takeScrollbackMaintenanceDirty()
    scrollbackMaintenance.noteActivity(generation: state.scrollbackGeneration)
  }

  /// After a capture or inspection promoted cold history, rearms
  /// maintenance without postponing it.
  func rearmScrollbackMaintenanceIfNeeded() {
    guard let scrollbackMaintenance, state.takeScrollbackMaintenanceDirty()
    else { return }
    scrollbackMaintenance.requestMaintenance(
      generation: state.scrollbackGeneration
    )
  }

  /// Converts the status journal into owned changes, splitting it at
  /// each reset into a new terminal epoch.
  func publishStatus() {
    guard let journal = state.takeProgramStatusJournal() else { return }
    var batch: [StatusChange] = []
    var epochChanged = false
    for change in journal.changes {
      switch change {
      case let .report(record):
        batch.append(.report(Self.status(record)))
        if javaScriptRuntime != nil {
          emitJavaScriptStatus(.report, record: Self.javaScriptStatus(record))
        }
      case let .removed(ids):
        batch.append(.removed(ids))
        emitJavaScriptStatus(.removed, ids: ids)
      case .reset:
        if !batch.isEmpty { onEvent?(.status(terminalEpoch, batch)) }
        batch = []
        terminalEpoch = TerminalEpochID()
        emitJavaScriptStatus(.reset)
        epochChanged = true
      }
    }
    if journal.truncated {
      batch.append(.sync(journal.snapshot.records.map(Self.status)))
      if javaScriptRuntime != nil {
        emitJavaScriptStatus(
          .sync,
          records: journal.snapshot.records.map(Self.javaScriptStatus)
        )
      }
    }
    if !batch.isEmpty || epochChanged {
      onEvent?(.status(terminalEpoch, batch))
    }
  }

  private func emitJavaScriptStatus(
    _ type: JavaScriptStatusChange.Kind,
    record: JavaScriptProgramStatus? = nil,
    ids: [String]? = nil,
    records: [JavaScriptProgramStatus]? = nil
  ) {
    javaScriptRuntime?
      .statusChanged(
        JavaScriptStatusChange(
          type: type,
          paneId: id.description,
          terminalEpoch: terminalEpoch.description,
          record: record,
          ids: ids,
          records: records
        )
      )
  }

  private static func javaScriptStatus(
    _ record: ProgramStatusRecord
  ) -> JavaScriptProgramStatus {
    let value = status(record)
    return JavaScriptProgramStatus(
      id: record.id,
      state: value.state.rawValue,
      kind: value.kind?.rawValue,
      progress: record.progress,
      app: record.app,
      title: record.title,
      message: record.message,
      revision: String(record.revision)
    )
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

  func noteChange() {
    revision &+= 1
    changeCount &+= 1
    if !changePosted.exchange(true, ordering: .acquiringAndReleasing) {
      onChange?()
    }
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
}
