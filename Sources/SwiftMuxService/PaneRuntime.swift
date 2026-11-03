import SwiftMuxGuardian
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

/// A pane's authoritative terminal and queue-owned process adapter. The default
/// GuardianPTY adapter owns descriptors, process lifecycle and byte-writer
/// state. Launch/paste admission may complete later; the terminal never reads
/// mutable writer counters to infer an operation's admission result. Ordered
/// remote input/geometry barriers remain necessary before enabling IPC here.
///
/// Sendable: engine/parser and guardian calls are confined to `queue`;
/// cross-queue admission/change counters use Mutex/Atomic. Callbacks are
/// installed before publication and capture this runtime weakly.
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
  /// Includes requests queued for encoding and requests awaiting the process
  /// owner's admission result, independently of byte/write credit.
  static let inputOperationLimit = GuardianWire.commandWindow
  private let inputOperations = Mutex(0)
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
  private var geometryFailure: MuxError?
  private var processFailure: MuxError?
  private var resizing = false
  private enum DeferredPaneWorkKind: Equatable {
    case input
    case control
    case theme
    case viewportReset
    case begin(UInt64)
    case chunk(UInt64)
    case end(UInt64)
  }
  private struct DeferredPaneWork {
    let kind: DeferredPaneWorkKind
    let run: () -> Void
    let cancel: () -> Void
  }
  // Data entries retain their input-operation reservation; each pending begin
  // permits at most one additional end marker.
  private var geometryWork: [DeferredPaneWork] = []

  // Set once before use, read on `queue`.
  var onChange: (@Sendable () -> Void)?
  var onEvent: (@Sendable (PaneEvent) -> Void)?

  // MARK: Queue-owned state

  private var state: TerminalState
  /// Idle history compression on this pane's queue; nil when off.
  private var scrollbackMaintenance: ScrollbackMaintenanceClient?
  private var parser = Parser()
  private let process: any PaneProcess
  private let observePaneIO: (@Sendable (PaneID, PaneIOObservation) -> Void)?
  private let javaScriptRuntime: JavaScriptRuntime?
  var pid: pid_t { process.pid }
  /// Every committed state change advances this.
  private(set) var revision: UInt64 = 0
  /// Owned by this pane: the generation of the last applied geometry
  /// request, whichever lease sent it, so it never goes backwards.
  private(set) var geometryGeneration: UInt64 = 0
  /// Advances with committed state changes only (not viewer captures).
  private var changeCount: UInt64 = 0
  /// Matches of the last viewer search, valid while `changeCount` holds.
  private var viewerSearchCache: ViewerSearchCache?
  /// Row versions per attachment (frames are cropped per viewer, so each
  /// attachment numbers its own rows). Pane queue only.
  private var rowTrackers: [AttachmentID: RowVersionTracker] = [:]
  /// Attachments by most recent capture, oldest first (eviction order).
  private var rowTrackerOrder: [AttachmentID] = []
  /// Trackers kept for attachments that never detach cleanly.
  static let maxRowTrackers = 16

  /// Drops a detached attachment's row versions (pane queue).
  func forgetRowVersions(of attachment: AttachmentID) {
    queue.async { [self] in
      rowTrackers.removeValue(forKey: attachment)
      rowTrackerOrder.removeAll { $0 == attachment }
    }
  }

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

  static let drainBound: DispatchTimeInterval = GuardianPTY.drainBound
  static let terminateGrace: DispatchTimeInterval = GuardianPTY.terminateGrace

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
    processOwner: (any PaneProcess)? = nil,
    processQueue: DispatchQueue? = nil,
    processFactory: (
      @Sendable (PaneID, WorkspaceID, DispatchQueue, MuxLimits) ->
        any PaneProcess
    )? = nil,
  ) {
    self.id = id
    self.workspace = workspace
    self.limits = limits
    self.javaScriptRuntime = javaScriptRuntime
    observePaneIO = observingIO
    queue =
      processQueue
      ?? DispatchQueue(label: "swiftmux.pane.\(id.short)", qos: .userInitiated,
      )
    process =
      processOwner ?? processFactory?(id, workspace, queue, limits)
      ?? GuardianPTY(
        id: id,
        workspace: workspace,
        queue: queue,
        limits: limits,
        observingIO: observingIO
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
    process.canConsume = { [weak self] in self?.enqueueReplies() ?? false }
    process.consume = { [weak self] bytes in
      guard let self else { return 0 }
      return self.parser.consumePrefix(bytes, into: &self.state, replyLimit: 1)
    }
    if let javaScriptRuntime {
      process.filter = { bytes in
        javaScriptRuntime.filter(
          bytes,
          stream: .stdout,
          pane: id.description,
          maximumBytes: limits.readTurnBytes
        )
      }
    }
    process.hasPendingReply = { [weak self] in
      self.map { !$0.state.output.isEmpty } ?? false
    }
    process.onBatch = { [weak self] in self?.publish() }
    process.onInputReleased = { [weak self] bytes in self?.release(bytes) }
    process.onUnavailable = { [weak self] error in
      guard let self else { return }
      self.processFailure = error
      self.geometryFailure = error
      self.cancelGeometryWork { _ in true }
      self.noteChange()
    }
    process.onFinished = { [weak self] status, forced in
      guard let self else { return }
      self.cancelGeometryWork { _ in true }
      self.parser = Parser()
      self.state.programExited()
      self.publishStatus()
      self.noteChange()
      self.onEvent?(.finished(status: status, forced: forced))
    }
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

  deinit { scrollbackMaintenance?.cancel() }

  func launch(
    _ spec: LaunchSpec,
    launcher: PaneLauncher,
    completion: @escaping @Sendable (Result<Void, MuxError>) -> Void
  ) {
    process.start(
      spec,
      launcher: launcher,
      columns: state.columns,
      rows: state.rows,
      completion: completion
    )
  }

  /// One complete command can remain pending beyond the writer reserve.
  /// Its reply is retained separately, without parsing more input into it.
  private func enqueueReplies() -> Bool {
    guard !state.output.isEmpty else { return true }
    state.output.withUnsafeBytes { observeIO(.replyGenerated, bytes: $0) }
    if process.childIsExiting || process.exitStatus != nil || process.finished
      || state.output.count > process.replyReserve
    {
      // Dead children cannot use replies. A custom reserve smaller than
      // one command retains the existing oversized-reply drop policy.
      state.output.withUnsafeBytes { observeIO(.replyDropped, bytes: $0) }
      state.output.removeAll(keepingCapacity: true)
      return true
    }
    guard process.appendReply(state.output) else { return false }
    state.output.withUnsafeBytes { observeIO(.replyQueued, bytes: $0) }
    state.output.removeAll(keepingCapacity: true)
    process.flush()
    return true
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

  private func noteChange() {
    revision &+= 1
    changeCount &+= 1
    if !changePosted.exchange(true, ordering: .acquiringAndReleasing) {
      onChange?()
    }
  }

  // MARK: Input

  private func afterGeometry(
    _ kind: DeferredPaneWorkKind,
    estimate: Int,
    run: @escaping () -> Void
  ) {
    // An active paste must finish so replies deferred behind it can drain.
    let continuingPaste: Bool
    if case let .chunk(id) = kind {
      continuingPaste = process.pasteID == id
    } else {
      continuingPaste = false
    }
    guard resizing && !continuingPaste else {
      run();
      return
    }
    geometryWork.append(
      DeferredPaneWork(
        kind: kind,
        run: run,
        cancel: { [self] in
          release(estimate)
          finishInputOperation()
        }
      )
    )
  }

  /// These service-wide settings have latest-value semantics and no retained
  /// command result. Keep one pending value, in order with other pane work.
  private func afterGeometrySetting(
    _ kind: DeferredPaneWorkKind,
    run: @escaping () -> Void
  ) {
    guard resizing else {
      run();
      return
    }
    geometryWork.removeAll { $0.kind == kind }
    geometryWork.append(DeferredPaneWork(kind: kind, run: run, cancel: run))
  }

  private func afterGeometryControl(
    failure: @escaping (MuxError) -> Void,
    run: @escaping () -> Void
  ) {
    guard resizing else {
      run();
      return
    }
    guard
      geometryWork.lazy.filter({ $0.kind == .control }).count
        < Self.inputOperationLimit
    else {
      failure(MuxError(.resourceLimit, "pane geometry wait queue is full"))
      return
    }
    geometryWork.append(
      DeferredPaneWork(
        kind: .control,
        run: run,
        cancel: { [self] in
          failure(
            geometryFailure ?? MuxError(.paneExited, "pane operation cancelled")
          )
        }
      )
    )
  }

  private func cancelGeometryWork(where matches: (DeferredPaneWorkKind) -> Bool)
  {
    let cancelled = geometryWork.filter { matches($0.kind) }
    geometryWork.removeAll { matches($0.kind) }
    for input in cancelled { input.cancel() }
  }

  /// Admission happened in the service; `estimate` was reserved.
  func write(_ input: MuxInput, estimate: Int) {
    queue.async { [self] in
      afterGeometry(.input, estimate: estimate) { [self] in
        noteScrollbackActivity()
        guard process.isOpen, process.exitStatus == nil else {
          release(estimate)
          finishInputOperation()
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
        var reserved = estimate
        if let javaScriptRuntime {
          let filtered = javaScriptRuntime.filter(
            Data(bytes),
            stream: .stdin,
            pane: id.description,
            maximumBytes: limits.inputBytesPerPane
          )
          if filtered.count <= estimate {
            bytes = Array(filtered)
          } else if reserveAdditionalBytes(filtered.count - estimate) {
            reserved = filtered.count
            bytes = Array(filtered)
          }
        }
        adjust(by: bytes.count - reserved)
        guard !bytes.isEmpty else {
          finishInputOperation();
          return
        }
        let encodedCount = bytes.count
        process.appendInput(bytes) { [self] admitted in
          adjust(by: admitted - encodedCount)
          finishInputOperation()
        }
        process.flush()
      }
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
      afterGeometry(.begin(id), estimate: estimate) { [self] in
        guard process.isOpen, !process.finished, !process.hasOpenPaste else {
          release(estimate)
          finishInputOperation()
          return
        }
        if state.viewportOffset != 0 {
          state.scrollViewportToBottom()
          advanceViewport()
          noteChange()
        }
        process.beginPaste(
          id: id,
          bracketed: state.modes.contains(.bracketedPaste),
          admitted: { [self] bytes in
            adjust(by: bytes - estimate)
            finishInputOperation()
          }
        )
        process.flush()
      }
    }
  }

  func pasteChunk(id: UInt64, text: String, estimate: Int) {
    queue.async { [self] in
      afterGeometry(.chunk(id), estimate: estimate) { [self] in
        guard process.isOpen, !process.finished, process.pasteID == id else {
          release(estimate)
          finishInputOperation()
          return
        }
        var payload = text
        var reserved = estimate
        if let javaScriptRuntime {
          let filtered = javaScriptRuntime.filter(
            Data(text.utf8),
            stream: .stdin,
            pane: self.id.description,
            maximumBytes: limits.inputBytesPerPane / 2
          )
          let estimateAfterFilter =
            filtered.count + filtered.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
          if estimateAfterFilter <= estimate {
            payload = String(decoding: filtered, as: UTF8.self)
          } else if reserveAdditionalBytes(estimateAfterFilter - reserved) {
            reserved = estimateAfterFilter
            payload = String(decoding: filtered, as: UTF8.self)
          }
        }
        let reservedBytes = reserved
        process.appendPaste(id: id, text: payload) { [self] bytes in
          adjust(by: bytes - reservedBytes)
          finishInputOperation()
        }
        process.flush()
      }
    }
  }

  func pasteEnd(id: UInt64) {
    queue.async { [self] in
      if resizing && process.pasteID != id {
        guard geometryWork.contains(where: { $0.kind == .begin(id) }),
          !geometryWork.contains(where: { $0.kind == .end(id) })
        else { return }
        geometryWork.append(
          DeferredPaneWork(
            kind: .end(id),
            run: { [self] in
              process.endPaste(id: id)
              process.flush()
            },
            cancel: {}
          )
        )
        return
      }
      process.endPaste(id: id)
      process.flush()
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
    failure: @escaping @Sendable (MuxError) -> Void,
    completion: @escaping @Sendable (PasteState) -> Void,
  ) {
    queue.async { [self] in
      cancelGeometryWork {
        $0 == .begin(id) || $0 == .chunk(id) || $0 == .end(id)
          || (discardDeferredInput && $0 == .input)
      }
      process.cancelPaste(id: id, discardDeferredInput: discardDeferredInput) {
        result in
        switch result {
        case let .success(wrote): completion(wrote ? .partial : .aborted)
        case let .failure(error): failure(error)
        }
      }
    }
  }

  /// Drops this pane's unwritten user input. Queued ahead of any later
  /// writer's bytes when a lease is released.
  func discardUnwrittenInput() {
    queue.async { [self] in
      cancelGeometryWork {
        switch $0 {
        case .input, .begin, .chunk, .end: true
        case .control, .theme, .viewportReset: false
        }
      }
      process.cancelInput()
    }
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

  /// Reserve one operation and its estimated bytes before scheduling work.
  /// The operation slot survives PTY writes until its admission response.
  func reserve(_ bytes: Int) -> Bool {
    inputOperations.withLock { count in
      guard count < Self.inputOperationLimit, reserveAdditionalBytes(bytes)
      else { return false }
      count += 1
      return true
    }
  }

  private func finishInputOperation() {
    inputOperations.withLock { count in
      precondition(count > 0, "input admission completed more than once")
      count -= 1
    }
  }

  /// A filter can enlarge an already admitted operation without reserving
  /// another operation slot. Counts are checked before addition.
  private func reserveAdditionalBytes(_ bytes: Int) -> Bool {
    outstandingInput.withLock { value in
      guard bytes >= 0, bytes <= limits.inputBytesPerPane - value else {
        return false
      }
      value += bytes
      return true
    }
  }

  // MARK: Geometry, history and search

  /// Commit engine geometry only after the ordered process resize succeeds. Returns the
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
      resizing = true
      applyResize(request) { [self] in
        resizing = false
        if geometryFailure != nil { cancelGeometryWork { _ in true } }
        let inputs = geometryWork
        geometryWork.removeAll(keepingCapacity: true)
        for input in inputs { input.run() }
        let again = resizes.withLock { requests in
          if requests.pending != nil { return true }
          requests.scheduled = false
          return false
        }
        if again { scheduleResize() }
      }
    }
  }

  private func applyResize(
    _ request: ResizeRequest,
    completion: @escaping @Sendable () -> Void
  ) {
    guard request.columns != state.columns || request.rows != state.rows else {
      geometryFailure = nil
      geometryGeneration = request.generation
      noteChange()
      completion()
      return
    }
    let commit: @Sendable (Result<Void, MuxError>) -> Void = { [self] result in
      switch result {
      case .success:
        geometryFailure = nil
        geometryGeneration = request.generation
        state.resize(columns: request.columns, rows: request.rows)
        publish()
      case let .failure(error):
        geometryFailure = error
        noteChange()
      }
      completion()
    }
    if !process.isOpen || process.finished {
      // Retained exit screens have geometry but no live PTY to resize.
      commit(.success(()))
    } else {
      process.resize(
        columns: request.columns,
        rows: request.rows,
        completion: commit
      )
    }
  }

  func scroll(
    _ request: ScrollRequest,
    completion: @escaping @Sendable (MuxError?) -> Void,
  ) {
    queue.async { [self] in
      afterGeometryControl(failure: { completion($0) }) { [self] in
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
            completion(
              MuxError(.historyUnavailable, "history address is stale")
            )
            return
          }
          state.scrollViewport(by: -state.viewportRow(absoluteRow: address.row))
        }
        advanceViewport()
        noteChange()
        completion(nil)
      }
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
      afterGeometryControl(failure: { completion($0) }) { [self] in
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
  }

  /// A step with nothing to select, or an end with no search, changes
  /// nothing.
  func search(
    _ query: String?,
    step forward: Bool?,
    failure: @escaping @Sendable (MuxError) -> Void,
    completion: @escaping @Sendable (SearchResult) -> Void,
  ) {
    queue.async { [self] in
      afterGeometryControl(failure: { failure($0) }) { [self] in
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
  }

  // MARK: Terminal control and shell integration

  /// Clears the screen, keeping the cursor's line, as the direct view's
  /// Clear Screen does.
  func clearScreen(completion: @escaping @Sendable (MuxError?) -> Void) {
    queue.async { [self] in
      afterGeometryControl(failure: { completion($0) }) { [self] in
        guard !process.finished else {
          completion(MuxError(.paneExited, "pane exited"));
          return
        }
        state.clearScreenKeepingCursorLine()
        advanceViewport()
        noteChange()
        completion(nil)
      }
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
          items.filter { Self.replyFits([$0], reserve: process.replyReserve) }
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
      guard !process.finished else { return }
      let answer: KittyClipboard.ReadResult =
        switch result {
        case let .success(available, contents, remember):
          Self.replyFits(contents, reserve: process.replyReserve)
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
      guard !process.finished else { return }
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
  func resetTerminal(completion: @escaping @Sendable (MuxError?) -> Void) {
    queue.async { [self] in
      afterGeometryControl(failure: { completion($0) }) { [self] in
        guard !process.finished else {
          completion(MuxError(.paneExited, "pane exited"));
          return
        }
        parser = Parser()
        state.reset()
        publishStatus()
        advanceViewport()
        noteChange()
        completion(nil)
      }
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
    failure: @escaping @Sendable (MuxError) -> Void,
    completion: @escaping @Sendable (MuxLink?) -> Void,
  ) {
    queue.async { [self] in
      afterGeometryControl(failure: { failure($0) }) { [self] in
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
  }

  /// The output around `address`, or the most recent command with
  /// output; scrolled into view as the direct view's selection is.
  func commandOutput(
    at address: HistoryAddress?,
    failure: @escaping @Sendable (MuxError) -> Void,
    completion: @escaping @Sendable (CommandOutput?) -> Void,
  ) {
    queue.async { [self] in
      afterGeometryControl(failure: { failure($0) }) { [self] in
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
  }

  /// Frontend theme: default colours and scheme, as a theme change does.
  /// Text of a client-local selection (spec.multiplexer.md §4, "Live
  /// selection across pages"). Fails rather than copying text the client
  /// did not see: a changed generation or evicted row is
  /// `historyUnavailable`, a changed screen row `selectionChanged`.
  func copySelection(
    _ request: CopySelectionRequest,
    attachment: AttachmentID,
    completion: @escaping @Sendable (Result<String, MuxError>) -> Void,
  ) {
    queue.async { [self] in
      let tracker = rowTrackers[attachment]
      completion(
        SelectionCopy.text(request, in: state) { identity in
          tracker?.matches(identity, in: state) ?? false
        }
      )
    }
  }

  func setTheme(_ theme: MuxTheme) {
    queue.async { [self] in
      afterGeometrySetting(.theme) { [self] in
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
  }

  private func advanceViewport() {
    currentViewport.wrappingAdd(1, ordering: .releasing)
  }

  /// Returns the viewport to live output and clears search (detach).
  func resetViewport() {
    queue.async { [self] in
      afterGeometrySetting(.viewportReset) { [self] in
        state.endSearch()
        state.scrollViewportToBottom()
        advanceViewport()
        noteChange()
      }
    }
  }

  // MARK: Frames

  struct CapturedFrame: Sendable {
    var data: Data
    var revision: UInt64
    var geometry: UInt64
    /// The viewport (a viewer's window) the frame shows.
    var viewportRevision: UInt64
    /// What the client holds once it acknowledges this frame.
    var baseline: FrameBaseline?

    var sent: SentFrame {
      SentFrame(
        revision: revision,
        bytes: data.count,
        geometry: geometry,
        viewport: viewportRevision,
        baseline: baseline,
      )
    }
  }

  /// How one client receives frames (negotiated at hello).
  struct FrameEncoding: Sendable {
    var binary = false
    var deltas = false
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
    encoding: FrameEncoding = FrameEncoding(),
    baseline: FrameBaseline? = nil,
    completion: @escaping @Sendable (Result<CapturedFrame, MuxError>) -> Void,
  ) {
    queue.async { [self] in
      afterGeometryControl(failure: { completion(.failure($0)) }) { [self] in
        if let geometryFailure = processFailure ?? geometryFailure {
          completion(.failure(geometryFailure))
          return
        }
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
          screen = screen.cropped(
            columns: viewport.columns ?? screen.columns,
            rows: viewport.rows ?? screen.rows
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
          // Detach forgets a tracker; this bound only evicts the attachment
          // least recently captured, never every live one.
          rowTrackerOrder.removeAll { $0 == attachment }
          rowTrackerOrder.append(attachment)
          while rowTrackerOrder.count > Self.maxRowTrackers {
            rowTrackers.removeValue(forKey: rowTrackerOrder.removeFirst())
          }
          frame.rowVersions = rowTrackers[
            attachment,
            default: RowVersionTracker()
          ]
          .stamp(screen)
          let delta =
            encoding.deltas
            ? baseline.flatMap {
              FrameDeltaBuilder.delta(from: frame, base: $0)
            } : nil
          let data: Data
          switch (encoding.binary, delta) {
          case (true, let delta?): data = SMXB.encode(delta)
          case (true, nil): data = SMXB.encode(frame)
          case (false, let delta?):
            data = try SMXCodec.encode(
              ServerMessage.event(.frameDelta(delta)),
              limit: limits.maxFrameBytes,
            )
          case (false, nil):
            data = try SMXCodec.encode(
              ServerMessage.event(.frame(frame)),
              limit: limits.maxFrameBytes,
            )
          }
          guard data.count <= limits.maxFrameBytes else {
            throw MuxError(.resourceLimit, "frame of \(data.count) bytes")
          }
          completion(
            .success(
              CapturedFrame(
                data: data,
                revision: revision,
                geometry: geometry,
                viewportRevision: shownRevision,
                baseline: FrameBaseline(frame),
              )
            )
          )
        } catch let error as MuxError { completion(.failure(error)) } catch {
          completion(.failure(MuxError(.resourceLimit, "\(error)")))
        }
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
      afterGeometryControl(failure: { completion(.failure($0)) }) { [self] in
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

  func terminationStateForTesting() -> String {
    process.terminationStateForTesting()
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

  func retire(completion: @escaping @Sendable (MuxError?) -> Void) {
    queue.async { [self] in process.retire(completion: completion) }
  }

  func terminate() {
    queue.async { [self] in
      cancelGeometryWork { _ in true }
      process.terminate()
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
