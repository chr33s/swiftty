import Darwin
import Dispatch
import Foundation
import SwiftMuxProtocol
import Synchronization
import TerminalProcess

/// The guardian's sole owner of one PTY, child and ordered byte writer.
/// No parser, workspace graph or terminal engine is linked here. All mutable
/// operations and consumer callbacks are confined to `queue`; only `pid` is
/// read cross-queue. The local adapter uses its pane queue until the IPC
/// adapter supplies bounded transport callbacks instead.
/// Sendable: mutable state is confined to `queue`; `pid` is atomic.
package final class GuardianPTY: @unchecked Sendable {
  package let queue: DispatchQueue
  private let limits: MuxLimits
  private let id: PaneID
  private let workspace: WorkspaceID
  private let observePaneIO: (@Sendable (PaneID, PaneIOObservation) -> Void)?
  private var writer: PaneWriter
  private var master: Int32 = -1
  private var slave: Int32 = -1
  private let spawnedPID = Atomic<pid_t>(0)
  package var pid: pid_t { spawnedPID.load(ordering: .acquiring) }
  /// Set at adoption: the child started in home, not the requested directory.
  package private(set) var directoryFallback = false
  package var isOpen: Bool { master >= 0 }
  package private(set) var exitStatus: Int32?
  package private(set) var finished = false
  package private(set) var childIsExiting = false
  private var forcedTermination = false
  private var terminating = false
  private var consumerUnavailable = false
  private var naturalDrainDeadline: DispatchTime?
  private var terminationDeadline: DispatchTime?
  private var groupKillSent = false
  private var drainTimer: DispatchWorkItem?
  /// The latest a paused consumer may hold up the final drain.
  private var drainLimit: DispatchTime?
  private var readSource: DispatchSourceRead?
  private var readSourceActive = false
  private var processingRead = false
  private var replyExitPoll: DispatchSourceTimer?
  private var bufferedRead = 0 ..< 0
  private var writeSource: DispatchSourceWrite?
  private var writeActive = false
  private var exitSource: DispatchSourceProcess?
  private var exitPoll: DispatchSourceTimer?
  private let readBuffer: UnsafeMutableRawBufferPointer

  // Install before launch, call only on queue; callbacks must not block.
  package var canConsume: (() -> Bool)?
  package var consume: ((UnsafeBufferPointer<UInt8>) -> Int)?
  package var filter: ((Data) -> Data)?
  package var hasPendingReply: (() -> Bool)?
  package var onBatch: (() -> Void)?
  package var onInputReleased: ((Int) -> Void)?
  package var onReplyReleased: ((Int) -> Void)?
  package var onExiting: (() -> Void)?
  package var onFinished: ((Int32, Bool) -> Void)?
  package var onUnavailable: ((MuxError) -> Void)?

  package static let drainBound: DispatchTimeInterval = .seconds(1)
  package static let terminateGrace = PTYProcessShutdown.grace

  package init(
    id: PaneID,
    workspace: WorkspaceID,
    queue: DispatchQueue,
    limits: MuxLimits,
    observingIO: (@Sendable (PaneID, PaneIOObservation) -> Void)? = nil
  ) {
    self.id = id
    self.workspace = workspace
    self.queue = queue
    self.limits = limits
    observePaneIO = observingIO
    writer = PaneWriter(replyReserve: limits.replyReserveBytes)
    readBuffer = .allocate(byteCount: limits.readTurnBytes, alignment: 16)
  }

  deinit {
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
  package func launch(
    _ spec: LaunchSpec,
    launcher: PaneLauncher,
    columns: Int,
    rows: Int
  ) throws(MuxError) {
    dispatchPrecondition(condition: .onQueue(queue))
    let p = try launcher.launch(
      spec,
      pane: id,
      workspace: workspace,
      columns: columns,
      rows: rows,
    )
    adopt(p)
  }

  /// Installs an exclusively owned launch result after a supervisor waited
  /// for the launcher handshake off the I/O queue.
  package func adopt(_ p: LaunchedProcess) {
    dispatchPrecondition(condition: .onQueue(queue))
    directoryFallback = p.directoryFallback
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
    guard master >= 0, !processingRead, !consumerUnavailable || terminating
    else { return }
    processingRead = true
    defer { processingRead = false }
    var budget = limits.readTurnBytes
    var parsedAny = false
    var sawEOF = false
    while budget > 0 {
      guard consumerUnavailable || canConsume?() == true else {
        setReadActive(false)
        onBatch?()
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
          if let filter {
            let filtered = filter(
              Data(bytes: readBuffer.baseAddress!, count: n)
            )
            precondition(filtered.count <= readBuffer.count)
            _ = filtered.copyBytes(to: readBuffer.bindMemory(to: UInt8.self))
            bufferedRead = 0 ..< filtered.count
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
      let consumed = consumerUnavailable ? chunk.count : (consume?(chunk) ?? 0)
      precondition(consumed >= 0 && consumed <= chunk.count)
      guard consumed > 0 else {
        setReadActive(false)
        return
      }
      bufferedRead =
        (bufferedRead.lowerBound + consumed) ..< bufferedRead.upperBound
      budget -= consumed
      parsedAny = true
    }
    if parsedAny { onBatch?() }
    if hasPendingReply?() == true { setReadActive(false) }
    if sawEOF {
      setReadActive(true)
      readSource?.cancel()
      readSource = nil
      readSourceActive = false
      if exitStatus != nil { finish() }
    }
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
    guard replyExitPoll == nil, !consumerUnavailable else { return }
    let poll = DispatchSource.makeTimerSource(queue: queue)
    poll.schedule(
      deadline: .now() + .milliseconds(25),
      repeating: .milliseconds(25),
    )
    poll.setEventHandler { [weak self] in
      guard let self, !self.finished, !self.readSourceActive else { return }
      guard PTYProcessExit.hasStartedExiting(self.pid) else { return }
      self.noteChildExiting()
      self.readAvailable()
    }
    replyExitPoll = poll
    poll.resume()
  }

  package func flush() {
    guard master >= 0, !consumerUnavailable else { return }
    let replyBefore = writer.pendingReplyBytes + writer.deferredReplyBytes
    let fd = master
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
    let replyReleased =
      replyBefore - writer.pendingReplyBytes - writer.deferredReplyBytes
    if replyReleased > 0 { onReplyReleased?(replyReleased) }
    guard let released else {
      discardWriter()
      setWriteActive(false)
      if !readSourceActive { readAvailable() }
      return
    }
    onInputReleased?(released)
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

  // Queue-confined typed writer operations. No caller can replace writer
  // state or restore partial-write offsets during worker replacement.
  package var replyReserve: Int { writer.replyReserve }
  package var pendingInputBytes: Int { writer.pendingInputBytes }
  /// Replies accepted or deferred but not yet written.
  package var pendingReplyBytes: Int {
    writer.pendingReplyBytes + writer.deferredReplyBytes
  }
  package var hasOpenPaste: Bool { writer.hasOpenPaste }
  package var pasteID: UInt64? { writer.paste?.id }
  package func appendInput(_ bytes: [UInt8]) { writer.appendInput(bytes) }
  package func appendReply(_ bytes: [UInt8]) -> Bool {
    writer.appendReply(bytes)
  }
  package func beginPaste(id: UInt64, bracketed: Bool) {
    writer.beginPaste(id: id, bracketed: bracketed)
  }
  package func appendPaste(id: UInt64, text: String) {
    writer.appendPaste(id: id, text: text)
  }
  package func endPaste(id: UInt64) { writer.endPaste(id: id) }
  package func cancelPaste(
    id: UInt64,
    discardDeferredInput: Bool
  ) -> (discarded: Int, wrote: Bool) {
    writer.cancelPaste(id: id, discardDeferredInput: discardDeferredInput)
  }
  package func discardUnwrittenInput() -> Int { writer.discardUnwrittenInput() }
  @discardableResult
  package func resize(columns: Int, rows: Int) -> Int32 {
    guard master >= 0 else { return EBADF }
    var size = winsize(
      ws_row: UInt16(clamping: rows),
      ws_col: UInt16(clamping: columns),
      ws_xpixel: 0,
      ws_ypixel: 0
    )
    return ioctl(master, TIOCSWINSZ, &size) == 0 ? 0 : errno
  }

  /// A lost worker is not an End request. Retain descriptors and child
  /// ownership, stop all I/O, and cancel its unwritten user-input suffix.
  /// There is deliberately no reconnect/reset-emulator operation here.
  package func detachConsumer() {
    dispatchPrecondition(condition: .onQueue(queue))
    guard !consumerUnavailable else { return }
    consumerUnavailable = true
    onInputReleased?(writer.discardUnwrittenInput())
    setReadActive(false)
    setWriteActive(false)
    replyExitPoll?.cancel()
    replyExitPoll = nil
    exitPoll?.cancel()
    exitPoll = nil
    canConsume = nil
    consume = nil
    filter = nil
    hasPendingReply = nil
    onBatch = nil
    onInputReleased = nil
    onReplyReleased = nil
    onExiting = nil
  }

  /// Captures teardown progress in pane order without signaling or reaping.
  package func terminationStateForTesting() -> String {
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

  // MARK: Lifetime

  private func noteChildExiting() {
    guard !childIsExiting else { return }
    childIsExiting = true
    onExiting?()
  }

  private func childExited(pollIfNeeded: Bool = true) {
    guard exitStatus == nil, !finished, !consumerUnavailable || terminating
    else { return }
    if pollIfNeeded {
      // NOTE_EXIT can precede waitability while the controlling terminal
      // drains. Release reply pressure before checking the exit status.
      noteChildExiting()
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
    noteChildExiting()
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
    noteChildExiting()
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
    drainLimit = .now() + Self.pausedDrainLimit
    armDrain()
  }

  private func armDrain() {
    let timer = DispatchWorkItem { [weak self] in self?.drainExpired() }
    drainTimer = timer
    queue.asyncAfter(deadline: .now() + Self.drainBound, execute: timer)
  }

  /// Final output waiting on a paused consumer (backpressure, or a planned
  /// replacement's freeze) is kept, not cut off; only a consumer that is
  /// reading and still sees no EOF ends the drain at its usual bound.
  private func drainExpired() {
    drainTimer = nil
    if !consumerUnavailable, canConsume?() == false, let drainLimit,
      DispatchTime.now() < drainLimit
    {
      armDrain()
      return
    }
    finish()
  }

  /// How long a paused consumer may delay the final drain.
  static let pausedDrainLimit: DispatchTimeInterval = .seconds(60)

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
    discardWriter()
    if master >= 0 {
      // Hang up descendants still holding the slave.
      close(master)
      master = -1
    }
    if slave >= 0 {
      close(slave)
      slave = -1
    }
    onFinished?(exitStatus ?? -1, forcedTermination)
  }

  private func discardWriter() {
    let replies = writer.pendingReplyBytes + writer.deferredReplyBytes
    onInputReleased?(writer.discardAll())
    if replies > 0 { onReplyReleased?(replies) }
  }

  /// Bounded explicit termination of this pane's processes only.
  package func terminate() {
    queue.async { [self] in
      guard !finished else {
        onFinished?(exitStatus ?? -1, forcedTermination)
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
