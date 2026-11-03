import Dispatch
import Foundation
import SwiftMuxProtocol

/// Workspace-queue admission in front of GuardianWorkerConnection. Results
/// release transport capacity immediately; a pane's later parsing/resize barrier
/// must never hold this queue's in-flight slot. Progress probes and output acks
/// continue using the connection directly.
package final class GuardianWorkerCommands: @unchecked Sendable {
  package typealias Completion =
    @Sendable (Result<GuardianResult, MuxError>) -> Void
  package typealias Send = (GuardianCommand, @escaping Completion) throws ->
    Bool

  private enum Lane: CaseIterable { case input, reply, control }
  private struct Entry {
    let command: GuardianCommand
    let lane: Lane
    let bytes: Int
    let completion: Completion
  }
  private struct Usage {
    var count = 0;
    var bytes = 0
  }
  private let queue: DispatchQueue
  private let send: Send
  private var waiting: [Entry] = []
  private var active: Entry?
  private var usage: [Lane: Usage] = [:]
  private var stopped: MuxError?
  private var pumping = false

  package init(queue: DispatchQueue, send: @escaping Send) {
    self.queue = queue
    self.send = send
  }

  /// False is local non-admission with no callback or wire effect. Every true
  /// return completes once. Start using this queue only after worker admission.
  /// Commands waiting here have no protocol sequence and may be cancelled;
  /// an in-flight command can only be resolved by its guardian result or loss.
  package func submit(
    _ command: GuardianCommand,
    completion: @escaping Completion
  ) throws -> Bool {
    dispatchPrecondition(condition: .onQueue(queue))
    guard stopped == nil else { return false }
    let lane = lane(for: command)
    // Account encoded payload, including escaping and base64, not just raw data.
    let bytes = try JSONEncoder().encode(command).count
    guard bytes <= GuardianWire.commandRecordLimit - 1024 else {
      throw MuxError(.resourceLimit, "guardian command too large")
    }
    let used = usage[lane, default: Usage()]
    let limit = lane == .input ? 8 << 20 : 1 << 20
    guard used.count < GuardianWire.commandWindow, bytes <= limit - used.bytes
    else { return false }
    usage[lane] = Usage(count: used.count + 1, bytes: used.bytes + bytes)
    waiting.append(
      Entry(command: command, lane: lane, bytes: bytes, completion: completion)
    )
    pump()
    return true
  }

  /// Run on capability revocation before enqueueing guardian cancellation.
  /// Refund only operations that have never been sent. The guardian remains
  /// authoritative for bytes and paste markers already accepted on the wire.
  package func cancelUnsentInput(
    pane: GuardianPaneHandle,
    paste: UInt64? = nil,
    includingOrdinaryInput: Bool = true
  ) {
    dispatchPrecondition(condition: .onQueue(queue))
    let removed = waiting.filter {
      matchesInput(
        $0.command,
        pane: pane,
        paste: paste,
        ordinary: includingOrdinaryInput
      )
    }
    waiting.removeAll {
      matchesInput(
        $0.command,
        pane: pane,
        paste: paste,
        ordinary: includingOrdinaryInput
      )
    }
    for entry in removed { release(entry) }
    for entry in removed {
      entry.completion(
        .success(
          .rejected(MuxError(.staleAttachment, "unsent input cancelled"))
        )
      )
    }
  }

  /// Called by the connection's closed handler before its pending completion.
  /// Nothing is replayed. Queued commands are known not to have executed; the
  /// active command has an unknown outcome, preserving that distinction.
  package func close(_ error: MuxError) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard stopped == nil else { return }
    stopped = error
    let pending = active
    active = nil
    let unsent = waiting
    waiting.removeAll()
    usage.removeAll()
    pending?
      .completion(
        .failure(MuxError(.connectionLost, "guardian outcome unknown"))
      )
    for entry in unsent { entry.completion(.success(.rejected(error))) }
  }

  private func pump() {
    guard !pumping else { return }
    pumping = true
    defer { pumping = false }
    while stopped == nil, active == nil, !waiting.isEmpty {
      let entry = waiting.removeFirst()
      active = entry
      do {
        let accepted = try send(entry.command) { [weak self] result in
          guard let self else { return }
          dispatchPrecondition(condition: .onQueue(self.queue))
          guard self.stopped == nil, self.active != nil else { return }
          self.active = nil
          self.release(entry)
          entry.completion(result)
          self.pump()
        }
        if !accepted {
          // Only this scheduler may submit commands on its connection, after
          // welcome. A busy/closed connection here violates that ownership.
          let error = MuxError(
            .connectionLost,
            "guardian command channel unavailable"
          )
          active = nil
          release(entry)
          entry.completion(.success(.rejected(error)))
          close(error)
        }
      } catch {
        active = nil
        release(entry)
        let failure =
          error as? MuxError
          ?? MuxError(.invalidRequest, "cannot encode guardian command")
        entry.completion(.success(.rejected(failure)))
      }
    }
  }

  private func release(_ entry: Entry) {
    var used = usage[entry.lane]!
    used.count -= 1
    used.bytes -= entry.bytes
    usage[entry.lane] = used
  }

  private func lane(for command: GuardianCommand) -> Lane {
    switch command {
    case .spawn, .input, .beginPaste, .appendPaste: .input
    case .reply: .reply
    case .endPaste, .cancelPaste, .cancelInput, .resize, .end, .forget: .control
    }
  }

  private func matchesInput(
    _ command: GuardianCommand,
    pane: GuardianPaneHandle,
    paste: UInt64?,
    ordinary: Bool
  ) -> Bool {
    switch command {
    case let .input(target, _, _): target == pane && ordinary
    case let .beginPaste(target, _, id, _), let .appendPaste(target, _, id, _),
      let .endPaste(target, _, id):
      target == pane && (paste == nil || paste == id)
    default: false
    }
  }
}
