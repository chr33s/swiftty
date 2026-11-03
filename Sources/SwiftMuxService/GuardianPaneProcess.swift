import Dispatch
import Foundation
import SwiftMuxGuardian
import SwiftMuxProtocol
import Synchronization

/// The workspace transport admits synchronously without waiting for a guardian
/// result. Completions and events must be delivered on the pane queue, in wire
/// order. The workspace queue must never synchronously call a pane queue.
struct GuardianPaneTransport: Sendable {
  var submit:
    @Sendable (GuardianCommand, @escaping GuardianWorkerCommands.Completion)
      throws -> Bool
  var cancelUnsent: @Sendable (GuardianPaneHandle, UInt64?, Bool) -> Void
  var acknowledge: @Sendable (GuardianPaneHandle, UInt64) -> Void
  var retire: @Sendable (@escaping @Sendable (MuxError?) -> Void) -> Void
  var writer: @Sendable () -> UUID?
  var failed: @Sendable (MuxError) -> Void
}

/// Worker-side PaneProcess. Owns neither a descriptor nor child lifetime. The
/// guardian keeps the byte writer; this adapter tracks only transport admission
/// and conservative reply credit, never partial PTY-write offsets.
final class GuardianPaneProcess: PaneProcess, @unchecked Sendable {
  let queue: DispatchQueue
  let id: PaneID
  let replyReserve: Int
  private let transport: GuardianPaneTransport
  private let output: GuardianPaneOutput
  private let spawnedPID = Atomic<Int32>(0)
  private(set) var handle: GuardianPaneHandle?
  private(set) var isOpen = false
  private(set) var exitStatus: Int32?
  private(set) var finished = false
  private(set) var pasteID: UInt64?
  private var lost = false
  private var started = false
  private var ending = false
  private var replyBytes = 0
  private var pendingReplies = 0
  private var replyRetryScheduled = false
  private var resizeCompletion: (@Sendable (Result<Void, MuxError>) -> Void)?
  var pid: Int32 { spawnedPID.load(ordering: .acquiring) }
  var childIsExiting: Bool { output.childIsExiting }
  var hasOpenPaste: Bool { pasteID != nil }

  var canConsume: (() -> Bool)?
  var consume: ((UnsafeBufferPointer<UInt8>) -> Int)?
  var filter: ((Data) -> Data)?
  var hasPendingReply: (() -> Bool)?
  var onBatch: (() -> Void)?
  var onInputReleased: ((Int) -> Void)?
  var onFinished: ((Int32, Bool) -> Void)?
  var onUnavailable: ((MuxError) -> Void)?

  init(
    id: PaneID,
    queue: DispatchQueue,
    limits: MuxLimits,
    transport: GuardianPaneTransport
  ) {
    self.id = id
    self.queue = queue
    self.transport = transport
    replyReserve = min(limits.replyReserveBytes, GuardianWire.inputChunkLimit)
    output = GuardianPaneOutput(queue: queue)
    output.canConsume = { [weak self] in
      guard let self, !self.lost else { return false }
      return self.canConsume?() == true
    }
    output.consume = { [weak self] in self?.consume?($0) ?? 0 }
    output.filter = { [weak self] in self?.filter?($0) ?? $0 }
    output.hasPendingReply = { [weak self] in
      guard let self else { return false }
      return self.pendingReplies > 0 || self.hasPendingReply?() == true
    }
    output.onBatch = { [weak self] in self?.onBatch?() }
    output.acknowledge = { [weak self] through in
      guard let self, let handle = self.handle else { return }
      self.transport.acknowledge(handle, through)
    }
    output.onFinished = { [weak self] status, forced in
      guard let self else { return }
      self.finished = true
      self.isOpen = false
      self.pasteID = nil
      self.onFinished?(status, forced)
    }
    output.onFailure = { [weak self] in self?.unavailable($0) }
  }

  func start(
    _ spec: LaunchSpec,
    launcher: PaneLauncher,
    columns: Int,
    rows: Int,
    completion: @escaping @Sendable (Result<Void, MuxError>) -> Void
  ) {
    guard !started else {
      completion(.failure(MuxError(.invalidRequest, "pane already started")));
      return
    }
    started = true
    request(.spawn(pane: id, launch: spec, columns: columns, rows: rows)) {
      [self] result in
      switch result {
      case let .success(.spawned(pid, process)):
        handle = GuardianPaneHandle(pane: id, process: process)
        spawnedPID.store(pid, ordering: .releasing)
        isOpen = !lost
        completion(
          lost
            ? .failure(MuxError(.connectionLost, "worker unavailable"))
            : .success(())
        )
        if ending { endProcess() }
      case let .success(.rejected(error)), let .failure(error):
        completion(.failure(error))
      default:
        let error = MuxError(.invalidRequest, "invalid guardian spawn result")
        unavailable(error)
        completion(.failure(error))
      }
    }
  }

  func appendInput(
    _ bytes: [UInt8],
    admitted: @escaping @Sendable (Int) -> Void
  ) {
    guard let handle, let writer = transport.writer(), isOpen, !lost else {
      admitted(0);
      return
    }
    admit(
      .input(pane: handle, writer: writer, bytes: Data(bytes)),
      completion: admitted
    )
  }

  func appendReply(_ bytes: [UInt8]) -> Bool {
    guard let handle, !lost, isOpen, !childIsExiting,
      bytes.count <= replyReserve - replyBytes
    else { return false }
    replyBytes += bytes.count
    pendingReplies += 1
    do {
      let accepted = try transport.submit(
        .reply(pane: handle, bytes: Data(bytes))
      ) { [self] result in
        pendingReplies -= 1
        switch result {
        case .success(.ok): break
        case .success(.rejected):
          replyBytes -= bytes.count
          if !childIsExiting {
            unavailable(
              MuxError(.connectionLost, "guardian rejected terminal reply")
            )
          }
        case let .failure(error): unavailable(error)
        default:
          unavailable(MuxError(.invalidRequest, "invalid reply admission"))
        }
        output.resume()
      }
      if accepted { return true }
      // Another pane may occupy the shared reply lane. No wire command was
      // admitted; retain the engine reply and retry with one bounded timer.
      if !replyRetryScheduled {
        replyRetryScheduled = true
        queue.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in
          guard let self else { return }
          self.replyRetryScheduled = false
          if !self.lost { self.output.resume() }
        }
      }
    } catch {
      unavailable(
        error as? MuxError ?? MuxError(.invalidRequest, "reply encoding failed")
      )
    }
    replyBytes -= bytes.count
    pendingReplies -= 1
    return false
  }

  func beginPaste(
    id: UInt64,
    bracketed: Bool,
    admitted: @escaping @Sendable (Int) -> Void
  ) {
    guard let handle, let writer = transport.writer(), isOpen, !lost,
      pasteID == nil
    else {
      admitted(0);
      return
    }
    pasteID = id
    request(
      .beginPaste(pane: handle, writer: writer, id: id, bracketed: bracketed)
    ) { [self] result in
      if case let .success(.admitted(bytes)) = result {
        guard bytes == (bracketed ? 12 : 0) else {
          unavailable(
            MuxError(.invalidRequest, "invalid paste admission count")
          )
          admitted(0)
          return
        }
        admitted(bytes)
      } else {
        if pasteID == id { pasteID = nil }
        admitted(0)
      }
    }
  }

  func appendPaste(
    id: UInt64,
    text: String,
    admitted: @escaping @Sendable (Int) -> Void
  ) {
    guard let handle, let writer = transport.writer(), isOpen, !lost,
      pasteID == id
    else {
      admitted(0);
      return
    }
    admit(
      .appendPaste(pane: handle, writer: writer, id: id, text: text),
      completion: admitted
    )
  }

  func endPaste(id: UInt64) {
    guard let handle, let writer = transport.writer(), pasteID == id, !lost
    else { return }
    pasteID = nil
    request(.endPaste(pane: handle, writer: writer, id: id)) { [self] result in
      checkControl(result)
    }
  }

  func cancelPaste(
    id: UInt64,
    discardDeferredInput: Bool,
    completion: @escaping @Sendable (Result<Bool, MuxError>) -> Void
  ) {
    guard let handle, let writer = transport.writer(), !lost else {
      completion(
        .failure(MuxError(.connectionLost, "paste cancellation unavailable"))
      );
      return
    }
    transport.cancelUnsent(handle, id, discardDeferredInput)
    if pasteID == id { pasteID = nil }
    request(
      .cancelPaste(
        pane: handle,
        writer: writer,
        id: id,
        discardDeferredInput: discardDeferredInput
      )
    ) { result in
      if case let .success(.pasteCancelled(wrote)) = result {
        completion(.success(wrote))
      } else {
        switch result {
        case let .success(.rejected(error)), let .failure(error):
          completion(.failure(error))
        default:
          completion(
            .failure(
              MuxError(.invalidRequest, "invalid paste cancellation result")
            )
          )
        }
      }
    }
  }

  func cancelInput() {
    guard let handle, !lost else { return }
    pasteID = nil
    transport.cancelUnsent(handle, nil, true)
    request(.cancelInput(pane: handle)) { [self] result in checkControl(result)
    }
  }

  func resize(
    columns: Int,
    rows: Int,
    completion: @escaping @Sendable (Result<Void, MuxError>) -> Void
  ) {
    guard let handle, !lost else {
      completion(.failure(MuxError(.connectionLost, "pane unavailable")));
      return
    }
    guard resizeCompletion == nil else {
      completion(.failure(MuxError(.invalidRequest, "resize already pending")));
      return
    }
    resizeCompletion = completion
    request(.resize(pane: handle, columns: columns, rows: rows)) {
      [self] result in
      switch result {
      case let .success(.resized(through)):
        output.afterApplying(through: through) { [self] in
          finishResize(.success(()))
        }
      case let .success(.rejected(error)), let .failure(error):
        finishResize(.failure(error))
      default:
        let error = MuxError(.invalidRequest, "invalid guardian resize result")
        unavailable(error)
        finishResize(.failure(error))
      }
    }
  }

  func retire(completion: @escaping @Sendable (MuxError?) -> Void) {
    guard finished || handle == nil else {
      completion(MuxError(.invalidRequest, "cannot retire a live pane"))
      return
    }
    transport.retire(completion)
  }

  func flush() { output.resume() }
  func terminate() {
    queue.async { [self] in
      guard !ending else { return }
      ending = true
      endProcess()
    }
  }
  private func endProcess() {
    guard let handle, !lost else { return }
    transport.cancelUnsent(handle, nil, true)
    request(.end(pane: handle)) { [self] result in checkControl(result) }
  }
  func terminationStateForTesting() -> String {
    "guardian pane pid=\(pid) finished=\(finished) unavailable=\(lost)"
  }

  /// Called in wire order, including command completions, on the pane queue.
  func receive(_ event: GuardianEvent) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard !lost else { return }
    switch event {
    case let .output(pane, sequence, bytes):
      guard validate(pane) else { return }
      output.receive(sequence: sequence, bytes: bytes)
    case let .inputReleased(pane, bytes):
      guard validate(pane) else { return }
      guard bytes >= 0 else {
        unavailable(MuxError(.invalidRequest, "invalid input credit"));
        return
      }
      onInputReleased?(bytes)
    case let .replyReleased(pane, bytes):
      guard validate(pane) else { return }
      guard bytes >= 0, bytes <= replyBytes else {
        unavailable(MuxError(.invalidRequest, "invalid reply credit"));
        return
      }
      replyBytes -= bytes
      output.resume()
    case let .exiting(pane):
      guard validate(pane) else { return }
      output.exiting()
    case let .exited(pane, status, forced):
      guard validate(pane) else { return }
      exitStatus = status
      output.exited(status: status, forced: forced)
    default: unavailable(MuxError(.invalidRequest, "unexpected pane event"))
    }
  }

  func unavailable(_ error: MuxError) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard !lost else { return }
    lost = true
    isOpen = false
    pasteID = nil
    output.abandon()
    onUnavailable?(error)
    finishResize(.failure(error))
    transport.failed(error)
  }

  private func finishResize(_ result: Result<Void, MuxError>) {
    let completion = resizeCompletion
    resizeCompletion = nil
    completion?(result)
  }

  private func validate(_ pane: GuardianPaneHandle) -> Bool {
    guard pane == handle else {
      unavailable(MuxError(.invalidRequest, "stale guardian pane event"));
      return false
    }
    return true
  }
  private func request(
    _ command: GuardianCommand,
    completion: @escaping GuardianWorkerCommands.Completion
  ) {
    guard !lost else {
      completion(
        .success(.rejected(MuxError(.connectionLost, "pane unavailable")))
      );
      return
    }
    do {
      let accepted = try transport.submit(command) { [self] result in
        if case let .failure(error) = result { unavailable(error) }
        completion(result)
      }
      if !accepted {
        completion(
          .success(
            .rejected(MuxError(.resourceLimit, "guardian admission full"))
          )
        )
      }
    } catch {
      completion(
        .success(
          .rejected(
            error as? MuxError
              ?? MuxError(.invalidRequest, "command encoding failed")
          )
        )
      )
    }
  }
  private func admit(
    _ command: GuardianCommand,
    completion: @escaping @Sendable (Int) -> Void
  ) {
    request(command) { [self] result in
      if case let .success(.admitted(bytes)) = result {
        let maximum: Int
        switch command {
        case let .input(_, _, data): maximum = data.count
        case let .appendPaste(_, _, _, text): maximum = text.utf8.count * 2
        default: maximum = 0
        }
        guard bytes >= 0, bytes <= maximum else {
          unavailable(
            MuxError(.invalidRequest, "invalid input admission count")
          )
          completion(0)
          return
        }
        completion(bytes)
      } else {
        completion(0)
      }
    }
  }

  private func checkControl(_ result: Result<GuardianResult, MuxError>) {
    switch result {
    case .success(.ok): break
    case let .success(.rejected(error)), let .failure(error): unavailable(error)
    default:
      unavailable(MuxError(.invalidRequest, "invalid guardian control result"))
    }
  }
}
