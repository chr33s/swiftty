#if os(macOS)
import Dispatch
import Foundation
import SessionCore
import SwiftMuxProtocol
import SwiftMuxService
import Synchronization

/// An SMX client of the in-process SwiftMux service: hello, numbered
/// requests, sequenced input and events. Every callback runs on `queue`.
///
/// The roaming host owns no PTYs; it reaches panes only through this, so
/// remote attachments get the same leases, takeover fencing and input
/// ledger as the native frontend.
///
/// Sendable: the connection, pending request/input tables, close state,
/// `welcome` and the handler properties are read and written only on
/// `queue`; sink callbacks hop there and hold `self` weakly. No unsafe
/// storage.
final class MuxLocalSession: @unchecked Sendable {
  typealias EventHandler = (MuxEvent) -> Void

  let queue: DispatchQueue
  private var connection: MuxLocalConnection?
  private var nextRequest: UInt64 = 1
  private var requests: [UInt64: (MuxResult) -> Void] = [:]
  private var nextInput: UInt64 = 1
  private var inputs: [UInt64: (MuxError?) -> Void] = [:]
  private var closed = false
  private var closePending = false
  private var closeCompletions: [() -> Void] = []
  /// Numbered requests still awaiting a service reply (on `queue`).
  var pendingRequestCount: Int {
    dispatchPrecondition(condition: .onQueue(queue))
    return requests.count
  }
  /// Set on `queue` before any message is expected.
  var onEvent: EventHandler?
  var onPaneChanged: ((PaneID) -> Void)?
  var onClosed: ((String) -> Void)?
  private(set) var welcome: Welcome?
  /// False once closed or rejected: requests then fail immediately.
  var isOpen: Bool { connection != nil && !closed }

  init(queue: DispatchQueue) { self.queue = queue }

  /// Connects and says hello; requests may be issued immediately after.
  func connect(to service: MuxService, frontend: FrontendKind, remote: Bool) {
    dispatchPrecondition(condition: .onQueue(queue))
    let sink = LocalClientSink(
      onMessage: { [weak self] message in
        self?.queue.async { [weak self] in self?.receive(message) }
      },
      onPaneChanged: { [weak self] pane in
        self?.queue.async { [weak self] in self?.onPaneChanged?(pane) }
      },
      onClosed: { [weak self] reason in
        self?.queue.async { [weak self] in self?.finish(reason) }
      }
    )
    let connection = service.connectLocal(remote: remote, sink: sink)
    self.connection = connection
    connection.send(.hello(Hello(frontend: frontend)))
  }

  func request(
    _ command: MuxCommand,
    expiresAt: ContinuousClock.Instant? = nil,
    isAdmitted: (@Sendable () -> Bool)? = nil,
    _ completion: @escaping (MuxResult) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard let connection, !closed else {
      return completion(.failure(MuxError(.connectionLost)))
    }
    let id = nextRequest
    nextRequest += 1
    requests[id] = completion
    connection.sendRequest(
      id: id,
      command: command,
      expiresAt: expiresAt,
      isAdmitted: isAdmitted
    )
  }

  func request(
    _ command: MuxCommand,
    expiresAt: ContinuousClock.Instant? = nil,
    isAdmitted: (@Sendable () -> Bool)? = nil
  ) async -> MuxResult {
    await withCheckedContinuation { continuation in
      queue.async {
        self.request(command, expiresAt: expiresAt, isAdmitted: isAdmitted) {
          continuation.resume(returning: $0)
        }
      }
    }
  }

  /// Input sequences restart at one for each attachment.
  func resetInput() { nextInput = 1 }

  func input(
    _ payload: InputPayload,
    attachment: AttachmentID,
    pane: PaneID,
    _ completion: @escaping (MuxError?) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard let connection, !closed else {
      return completion(MuxError(.connectionLost))
    }
    let sequence = nextInput
    nextInput += 1
    inputs[sequence] = completion
    connection.send(
      .input(
        InputRecord(
          sequence: sequence,
          attachment: attachment,
          pane: pane,
          payload: payload
        )
      )
    )
  }

  /// Releases any lease held through this session. Pending callbacks
  /// complete with `connectionLost`; `then` waits for service disconnection.
  func close(then completion: (() -> Void)? = nil) {
    dispatchPrecondition(condition: .onQueue(queue))
    if let completion { closeCompletions.append(completion) }
    guard !closePending else { return }
    guard let connection else {
      finish("closed")
      drainCloseCompletions()
      return
    }
    self.connection = nil
    closePending = true
    connection.close { [self] in
      queue.async { [self] in
        closePending = false
        drainCloseCompletions()
      }
    }
    finish("closed")
  }

  private func drainCloseCompletions() {
    let completions = closeCompletions
    closeCompletions = []
    for completion in completions { completion() }
  }

  private func receive(_ message: ServerMessage) {
    switch message {
    case let .welcome(w): welcome = w
    case let .rejected(error): finish("rejected: \(error)")
    case let .reply(id, result): requests.removeValue(forKey: id)?(result)
    case let .inputAck(sequence, error):
      inputs.removeValue(forKey: sequence)?(error)
    case let .event(event): onEvent?(event)
    }
  }

  private func finish(_ reason: String) {
    guard !closed else { return }
    closed = true
    let lost = MuxError(.connectionLost, reason)
    let pendingRequests = requests.values
    let pendingInputs = inputs.values
    requests = [:]
    inputs = [:]
    for callback in pendingRequests { callback(.failure(lost)) }
    for callback in pendingInputs { callback(lost) }
    onClosed?(reason)
  }
}

#endif
