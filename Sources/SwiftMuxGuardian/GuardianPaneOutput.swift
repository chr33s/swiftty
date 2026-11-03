import Dispatch
import Foundation
import SwiftMuxProtocol

/// Worker-side ordered output consumption. Owns transport records, never a
/// PTY, parser, writer or terminal snapshot. Parsing may stop inside a record
/// while a query reply awaits admission; acknowledge only fully applied records.
package final class GuardianPaneOutput: @unchecked Sendable {
  private struct Record {
    let sequence: UInt64
    let bytes: Data
    var offset = 0
  }
  private let queue: DispatchQueue
  private var records: [Record] = []
  private var filtered: Data?
  private var nextSequence: UInt64 = 1
  private var appliedSequence: UInt64 = 0
  private var barrier: (through: UInt64, commit: () -> Void)?
  private var bufferedBytes = 0
  private var processing = false
  private var failed = false
  private var finalStatus: (Int32, Bool)?
  package private(set) var childIsExiting = false
  package private(set) var finished = false

  // Install on queue before receiving records. All callbacks run on queue.
  package var canConsume: (() -> Bool)?
  package var consume: ((UnsafeBufferPointer<UInt8>) -> Int)?
  package var filter: ((Data) -> Data)?
  /// Includes replies awaiting a command result, even after exit has caused
  /// the engine to drop its generated reply buffer. Final delivery waits for
  /// that admission outcome so credit and pane disposal cannot race it.
  package var hasPendingReply: (() -> Bool)?
  package var onBatch: (() -> Void)?
  package var onExiting: (() -> Void)?
  package var onFinished: ((Int32, Bool) -> Void)?
  package var acknowledge: ((UInt64) -> Void)?
  package var onFailure: ((MuxError) -> Void)?

  package init(queue: DispatchQueue) { self.queue = queue }

  package func receive(sequence: UInt64, bytes: Data) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard !failed else { return }
    guard !finished, finalStatus == nil, sequence == nextSequence,
      sequence < UInt64.max, !bytes.isEmpty,
      bytes.count <= GuardianWire.outputChunkLimit,
      records.count < GuardianWire.outputRecordLimit,
      bytes.count <= (1 << 20) - bufferedBytes
    else {
      fail("invalid or over-budget guardian output");
      return
    }
    nextSequence += 1
    bufferedBytes += bytes.count
    records.append(Record(sequence: sequence, bytes: bytes))
    resume()
  }

  package func exiting() {
    dispatchPrecondition(condition: .onQueue(queue))
    guard !failed, !childIsExiting else { return }
    childIsExiting = true
    onExiting?()
    resume()
  }

  /// Insert at receipt of the guardian's resize result, before dispatching
  /// later output events. The caller holds geometry-dependent semantic work
  /// until commit, while keeping reply admission and cancellation/control
  /// traffic available to resolve backpressure. Only one resize may be
  /// unsettled per pane; callers coalesce new size requests rather than
  /// accumulating barrier closures.
  package func afterApplying(through: UInt64, commit: @escaping () -> Void) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard !failed else { return }
    guard !finished, finalStatus == nil, barrier == nil,
      through == nextSequence - 1, through >= appliedSequence
    else {
      fail("invalid or overlapping guardian output barrier")
      return
    }
    barrier = (through, commit)
    resume()
  }

  package func exited(status: Int32, forced: Bool) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard !failed else { return }
    guard !finished, finalStatus == nil else {
      fail("duplicate guardian exit");
      return
    }
    finalStatus = (status, forced)
    exiting()
    resume()
  }

  /// Called after reply admission/credit or another explicit consumer barrier.
  /// Each turn is bounded, so output cannot starve workspace health/control.
  package func resume() {
    dispatchPrecondition(condition: .onQueue(queue))
    guard !processing, !failed, !finished else { return }
    processing = true
    defer { processing = false }
    var budget = GuardianWire.outputChunkLimit
    while !records.isEmpty, budget > 0 {
      guard commitBarrierIfReady() else { return }
      guard canConsume?() == true else {
        onBatch?();
        return
      }
      let record = records[0]
      if filtered == nil {
        let value = filter?(record.bytes) ?? record.bytes
        guard value.count <= GuardianWire.outputChunkLimit else {
          fail("filtered guardian output exceeds chunk budget");
          return
        }
        filtered = value
      }
      let bytes = filtered!
      if record.offset < bytes.count {
        let end = min(bytes.count, record.offset + budget)
        let count = bytes.withUnsafeBytes { raw in
          consume?(
            UnsafeBufferPointer(
              rebasing: raw.bindMemory(to: UInt8.self)[record.offset ..< end]
            )
          ) ?? 0
        }
        guard !failed else { return }
        guard count >= 0, count <= end - record.offset else {
          fail("invalid terminal consumption count");
          return
        }
        guard count > 0 else {
          onBatch?();
          return
        }
        records[0].offset += count
        budget -= count
      }
      if records[0].offset == bytes.count {
        bufferedBytes -= record.bytes.count
        records.removeFirst()
        filtered = nil
        appliedSequence = record.sequence
        acknowledge?(record.sequence)
      }
    }
    onBatch?()
    guard !failed else { return }
    guard commitBarrierIfReady() else { return }
    if records.isEmpty, let (status, forced) = finalStatus,
      canConsume?() == true, hasPendingReply?() != true
    {
      finished = true
      onFinished?(status, forced)
    } else if !records.isEmpty, budget <= 0 {
      queue.async { [weak self] in self?.resume() }
    }
  }

  private func commitBarrierIfReady() -> Bool {
    guard let pending = barrier, pending.through == appliedSequence else {
      return true
    }
    guard canConsume?() == true, hasPendingReply?() != true else {
      onBatch?()
      return false
    }
    barrier = nil
    pending.commit()
    return !failed
  }

  /// Abandon an unavailable stream without inventing a process exit or
  /// retaining a parsing barrier's completion and terminal buffers forever.
  package func abandon() {
    dispatchPrecondition(condition: .onQueue(queue))
    failed = true
    records.removeAll()
    filtered = nil
    barrier = nil
    bufferedBytes = 0
  }

  private func fail(_ reason: String) {
    guard !failed else { return }
    abandon()
    onFailure?(MuxError(.invalidRequest, reason))
  }
}
