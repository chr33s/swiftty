import Dispatch
import Foundation
import SwiftMuxGuardian
import SwiftMuxProtocol

/// Process-facing boundary of the terminal runtime. Mutable state, callbacks,
/// and admission completions belong to the pane queue. Completions may arrive
/// later; neither launch nor paste accounting may assume immediate admission.
/// `pid` and `terminate` retain their existing cross-queue contracts.
/// Every accepted start/admission/cancellation call completes exactly once,
/// including failure/teardown. Admission reports actual bytes charged; release
/// events may precede that response, so the caller retains its conservative
/// reservation until both have been accounted for. Cancellation releases credit
/// through onInputReleased, independently of its authoritative `wrote` result.
/// A failed/uncertain cancellation reports an error, never a fabricated false.
protocol PaneProcess: AnyObject, Sendable {
  var pid: Int32 { get }
  var isOpen: Bool { get }
  var exitStatus: Int32? { get }
  var finished: Bool { get }
  var childIsExiting: Bool { get }
  /// After a successful start: the child began in home instead.
  var directoryFallback: Bool { get }
  var replyReserve: Int { get }
  var hasOpenPaste: Bool { get }
  var pasteID: UInt64? { get }

  var canConsume: (() -> Bool)? { get set }
  var consume: ((UnsafeBufferPointer<UInt8>) -> Int)? { get set }
  var filter: ((Data) -> Data)? { get set }
  var hasPendingReply: (() -> Bool)? { get set }
  var onBatch: (() -> Void)? { get set }
  var onInputReleased: ((Int) -> Void)? { get set }
  var onFinished: ((Int32, Bool) -> Void)? { get set }
  var onUnavailable: ((MuxError) -> Void)? { get set }

  func start(
    _ spec: LaunchSpec,
    launcher: PaneLauncher,
    columns: Int,
    rows: Int,
    completion: @escaping @Sendable (Result<Void, MuxError>) -> Void
  )
  func appendInput(
    _ bytes: [UInt8],
    admitted: @escaping @Sendable (Int) -> Void
  )
  func appendReply(_ bytes: [UInt8]) -> Bool
  func beginPaste(
    id: UInt64,
    bracketed: Bool,
    admitted: @escaping @Sendable (Int) -> Void
  )
  func appendPaste(
    id: UInt64,
    text: String,
    admitted: @escaping @Sendable (Int) -> Void
  )
  func endPaste(id: UInt64)
  func cancelPaste(
    id: UInt64,
    discardDeferredInput: Bool,
    completion: @escaping @Sendable (Result<Bool, MuxError>) -> Void
  )
  func cancelInput()
  /// Complete on the pane queue at the applied output cut, before later output.
  func resize(
    columns: Int,
    rows: Int,
    completion: @escaping @Sendable (Result<Void, MuxError>) -> Void
  )
  func flush()
  func retire(completion: @escaping @Sendable (MuxError?) -> Void)
  func terminate()
  func terminationStateForTesting() -> String
}

/// Local process owner used by the existing monolithic service. The guardian
/// remains the sole byte-writer owner; the runtime sees actual admissions and
/// credit releases, never a snapshot of mutable writer counters.
extension GuardianPTY: PaneProcess {
  func retire(completion: @escaping @Sendable (MuxError?) -> Void) {
    guard finished || !isOpen else {
      completion(MuxError(.invalidRequest, "cannot retire a live pane"))
      return
    }
    completion(nil)
  }

  func resize(
    columns: Int,
    rows: Int,
    completion: @escaping @Sendable (Result<Void, MuxError>) -> Void
  ) {
    let error = resize(columns: columns, rows: rows)
    if error == 0 {
      completion(.success(()))
    } else {
      completion(
        .failure(
          MuxError(.invalidRequest, "PTY resize failed (errno \(error))")
        )
      )
    }
  }

  func appendInput(
    _ bytes: [UInt8],
    admitted: @escaping @Sendable (Int) -> Void
  ) {
    appendInput(bytes)
    admitted(bytes.count)
  }

  func start(
    _ spec: LaunchSpec,
    launcher: PaneLauncher,
    columns: Int,
    rows: Int,
    completion: @escaping @Sendable (Result<Void, MuxError>) -> Void
  ) {
    do throws(MuxError) {
      try launch(spec, launcher: launcher, columns: columns, rows: rows)
      completion(.success(()))
    } catch { completion(.failure(error)) }
  }

  func beginPaste(
    id: UInt64,
    bracketed: Bool,
    admitted: @escaping @Sendable (Int) -> Void
  ) {
    let before = pendingInputBytes
    beginPaste(id: id, bracketed: bracketed)
    admitted(pendingInputBytes - before)
  }

  func appendPaste(
    id: UInt64,
    text: String,
    admitted: @escaping @Sendable (Int) -> Void
  ) {
    let before = pendingInputBytes
    appendPaste(id: id, text: text)
    admitted(pendingInputBytes - before)
  }

  func cancelPaste(
    id: UInt64,
    discardDeferredInput: Bool,
    completion: @escaping @Sendable (Result<Bool, MuxError>) -> Void
  ) {
    let result = cancelPaste(id: id, discardDeferredInput: discardDeferredInput)
    onInputReleased?(result.discarded)
    flush()
    completion(.success(result.wrote))
  }

  func cancelInput() {
    onInputReleased?(discardUnwrittenInput())
    flush()
  }
}
