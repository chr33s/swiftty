import Darwin
import Dispatch
import Foundation
import SwiftMuxProtocol
import SwiftMuxXPC

/// Worker side of the guardian link. Methods and callbacks run on the supplied
/// channel queue (the worker's workspace queue). No reconnection or input replay
/// occurs after loss. One command is in flight; callers retain further work
/// behind their existing bounded admission queues until its result arrives.
package final class GuardianWorkerConnection: @unchecked Sendable {
  package struct Handlers: Sendable {
    package var gatewayChanged:
      (
        @Sendable (
          GuardianGatewayBinding, @escaping @Sendable (MuxError?) -> Void
        ) -> Void
      )?
    package var endpointPublished: @Sendable (ServerInstanceID) -> Void
    package var ready: @Sendable (GuardianAuthority) -> Void
    package var output: @Sendable (GuardianPaneHandle, UInt64, Data) -> Void
    package var inputReleased: @Sendable (GuardianPaneHandle, Int) -> Void
    package var replyReleased: @Sendable (GuardianPaneHandle, Int) -> Void
    package var exiting: @Sendable (GuardianPaneHandle) -> Void
    package var exited: @Sendable (GuardianPaneHandle, Int32, Bool) -> Void
    /// Enqueue a barrier on every pane queue, then complete on the workspace
    /// queue. It must not wait for output credit or a child to read input.
    package var progress: @Sendable (@escaping @Sendable () -> Void) -> Void
    package var closed: @Sendable (MuxError) -> Void

    package init(
      ready: @escaping @Sendable (GuardianAuthority) -> Void,
      endpointPublished: @escaping @Sendable (ServerInstanceID) -> Void = { _ in
      },
      gatewayChanged: (
        @Sendable (
          GuardianGatewayBinding, @escaping @Sendable (MuxError?) -> Void
        ) -> Void
      )? = nil,
      output: @escaping @Sendable (GuardianPaneHandle, UInt64, Data) -> Void,
      inputReleased: @escaping @Sendable (GuardianPaneHandle, Int) -> Void,
      replyReleased: @escaping @Sendable (GuardianPaneHandle, Int) -> Void = {
        _,
        _ in
      },
      exiting: @escaping @Sendable (GuardianPaneHandle) -> Void = { _ in },
      exited: @escaping @Sendable (GuardianPaneHandle, Int32, Bool) -> Void,
      progress: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void,
      closed: @escaping @Sendable (MuxError) -> Void
    ) {
      self.ready = ready
      self.gatewayChanged = gatewayChanged
      self.endpointPublished = endpointPublished
      self.output = output
      self.inputReleased = inputReleased
      self.replyReleased = replyReleased
      self.exiting = exiting
      self.exited = exited
      self.progress = progress
      self.closed = closed
    }
  }

  private struct Pending {
    let sequence: UInt64
    let request: Data
    let completion: @Sendable (Result<GuardianResult, MuxError>) -> Void
  }

  private let channel: SMXChannel
  private let workspace: WorkspaceID
  private let handlers: Handlers
  private let expectedGuardianPID: Int32?
  private var authority: GuardianAuthority?
  private var nextCommand: UInt64 = 1
  private var pending: Pending?
  private var retryScheduled = false
  private var probe: UUID?
  private var ended = false
  private var publishedInstance: ServerInstanceID?
  private var publicationAcknowledged = false
  private var gatewayRevision: UInt64 = 0
  private var applyingGateway: UInt64?
  private var pendingGateway: GuardianGatewayBinding?
  private var gatewayTimer: DispatchSourceTimer?

  package init(
    channel: SMXChannel,
    workspace: WorkspaceID,
    token: UUID,
    peerRequirement: String?,
    expectedGuardianPID: Int32? = nil,
    handlers: Handlers
  ) throws {
    self.channel = channel
    self.workspace = workspace
    self.handlers = handlers
    self.expectedGuardianPID = expectedGuardianPID
    guard peerRequirement.map({ channel.requirePeer(codeSigning: $0) }) ?? true
    else {
      channel.cancel()
      throw MuxError(.unauthorized, "guardian signing requirement rejected")
    }
    channel.activate(recordLimit: { GuardianWire.recordLimit }) {
      [weak self] event in
      guard let self, !self.ended else { return }
      switch event {
      case let .message(data):
        guard self.channel.peerEUID == geteuid(),
          self.expectedGuardianPID.map({ self.channel.peerPID == $0 }) ?? true,
          let message = try? JSONDecoder()
            .decode(GuardianEvent.self, from: data)
        else {
          self.finish(
            MuxError(.unauthorized, "invalid guardian peer or message")
          )
          return
        }
        self.receive(message)
      case .closed:
        self.finish(MuxError(.connectionLost, "guardian connection lost"))
      }
    }
    channel.send(
      try JSONEncoder()
        .encode(
          GuardianRequest.hello(
            version: GuardianWire.version,
            workspace: workspace,
            token: token
          )
        )
    )
    channel.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
      guard let self, self.authority == nil, !self.ended else { return }
      self.finish(MuxError(.connectionLost, "guardian handshake timed out"))
    }
  }

  deinit {
    gatewayTimer?.cancel()
    channel.cancel()
  }

  /// False means not admitted locally: no sequence or wire effect was consumed.
  /// A result (including rejection) consumes a sequence. Connection loss leaves
  /// the outcome uncertain and must never cause automatic resubmission. The
  /// completion's failure branch means transport loss with unknown execution;
  /// success(.rejected(...)) is an authoritative guardian operation result.
  package func submit(
    _ command: GuardianCommand,
    completion: @escaping @Sendable (Result<GuardianResult, MuxError>) -> Void
  ) throws -> Bool {
    dispatchPrecondition(condition: .onQueue(channel.queue))
    guard !ended, let authority, pending == nil else { return false }
    guard nextCommand < UInt64.max else {
      throw MuxError(.resourceLimit, "guardian command sequence exhausted")
    }
    let request = try JSONEncoder()
      .encode(
        GuardianRequest.command(
          authority: authority,
          sequence: nextCommand,
          body: command
        )
      )
    guard request.count <= GuardianWire.commandRecordLimit else {
      throw MuxError(.resourceLimit, "guardian command too large")
    }
    pending = Pending(
      sequence: nextCommand,
      request: request,
      completion: completion
    )
    channel.send(request)
    return true
  }

  /// Publish one service endpoint after welcome. Never replace it in place:
  /// another service instance requires a newly supervised worker generation.
  package func publishEndpoint(
    _ endpoint: SMXEndpoint,
    instance: ServerInstanceID
  ) throws {
    dispatchPrecondition(condition: .onQueue(channel.queue))
    guard !ended, let authority, publishedInstance == nil else {
      throw MuxError(.invalidRequest, "worker endpoint cannot be published")
    }
    let data = try JSONEncoder()
      .encode(
        GuardianEndpointPublication(
          version: GuardianWire.version,
          authority: authority,
          instance: instance
        )
      )
    publishedInstance = instance
    channel.send(data, endpoint: endpoint)
  }

  /// Call only after the pane parser has applied this cumulative output cut.
  package func acknowledgeOutput(_ pane: GuardianPaneHandle, through: UInt64) {
    dispatchPrecondition(condition: .onQueue(channel.queue))
    guard !ended, let authority else { return }
    send(.outputAck(authority: authority, pane: pane, through: through))
  }

  package func close() {
    dispatchPrecondition(condition: .onQueue(channel.queue))
    finish(MuxError(.connectionLost, "worker closed guardian connection"))
  }

  private func receive(_ event: GuardianEvent) {
    if case let .welcome(value) = event {
      guard authority == nil, value.workspace == workspace, value.generation > 0
      else {
        finish(MuxError(.invalidRequest, "unexpected guardian welcome"))
        return
      }
      authority = value
      handlers.ready(value)
      return
    }
    if case let .refused(error) = event {
      finish(error);
      return
    }
    guard let authority else {
      finish(MuxError(.invalidRequest, "guardian event before admission"))
      return
    }
    switch event {
    case let .endpointPublished(instance):
      guard instance == publishedInstance, !publicationAcknowledged else {
        finish(
          MuxError(
            .invalidRequest,
            "unexpected endpoint publication acknowledgement"
          )
        )
        return
      }
      publicationAcknowledged = true
      handlers.endpointPublished(instance)
      if handlers.gatewayChanged != nil {
        send(.subscribeGateway(authority: authority))
      }
    case let .gatewayBinding(value):
      guard handlers.gatewayChanged != nil, publicationAcknowledged,
        value.authority == authority, value.revision > gatewayRevision
      else {
        finish(MuxError(.invalidRequest, "stale gateway binding"))
        return
      }
      gatewayRevision = value.revision
      pendingGateway = value
      applyGateway()
    case let .result(sequence, result):
      guard let operation = pending, operation.sequence == sequence else {
        finish(MuxError(.invalidRequest, "unexpected guardian command result"))
        return
      }
      pending = nil
      nextCommand += 1
      send(.retire(authority: authority, through: sequence))
      operation.completion(.success(result))
    case let .retry(sequence):
      guard pending?.sequence == sequence else {
        finish(MuxError(.invalidRequest, "unexpected guardian retry"))
        return
      }
      // Retry only explicit non-admission, with exactly the original bytes.
      // A single timer and command bound memory even under host-wide pressure.
      guard !retryScheduled else { return }
      retryScheduled = true
      channel.queue.asyncAfter(deadline: .now() + .milliseconds(50)) {
        [weak self] in
        guard let self else { return }
        self.retryScheduled = false
        guard !self.ended, let operation = self.pending,
          operation.sequence == sequence
        else { return }
        self.channel.send(operation.request)
      }
    case let .probe(value):
      guard probe == nil else {
        finish(
          MuxError(.invalidRequest, "overlapping guardian progress probes")
        )
        return
      }
      probe = value
      handlers.progress { [weak self] in
        guard let self else { return }
        self.channel.queue.async { [weak self] in
          guard let self, !self.ended, self.probe == value else { return }
          self.probe = nil
          self.send(.progress(authority: authority, probe: value))
        }
      }
    case let .output(pane, sequence, bytes):
      handlers.output(pane, sequence, bytes)
    case let .inputReleased(pane, bytes): handlers.inputReleased(pane, bytes)
    case let .replyReleased(pane, bytes): handlers.replyReleased(pane, bytes)
    case let .exiting(pane): handlers.exiting(pane)
    case let .exited(pane, status, forced):
      handlers.exited(pane, status, forced)
    case .welcome, .refused: break
    }
  }

  private func applyGateway() {
    guard !ended, applyingGateway == nil, let value = pendingGateway,
      let handler = handlers.gatewayChanged
    else { return }
    pendingGateway = nil
    applyingGateway = value.revision
    let timer = DispatchSource.makeTimerSource(queue: channel.queue)
    timer.schedule(deadline: .now() + 5)
    timer.setEventHandler { [weak self] in
      self?.finish(MuxError(.connectionLost, "gateway binding timed out"))
    }
    gatewayTimer = timer
    timer.resume()
    handler(value) { [weak self] error in
      guard let self else { return }
      self.channel.queue.async { [self] in
        guard !ended, applyingGateway == value.revision else { return }
        gatewayTimer?.cancel()
        gatewayTimer = nil
        applyingGateway = nil
        if let error {
          finish(error);
          return
        }
        send(
          .gatewayApplied(authority: value.authority, revision: value.revision)
        )
        applyGateway()
      }
    }
  }

  private func send(_ request: GuardianRequest) {
    guard let bytes = try? JSONEncoder().encode(request) else {
      finish(
        MuxError(.invalidRequest, "cannot encode guardian control request")
      )
      return
    }
    channel.send(bytes)
  }

  private func finish(_ error: MuxError) {
    guard !ended else { return }
    ended = true
    gatewayTimer?.cancel()
    gatewayTimer = nil
    pendingGateway = nil
    applyingGateway = nil
    probe = nil
    let operation = pending
    pending = nil
    channel.cancel()
    // Notify loss before resolving commands: callers must invalidate their
    // graph transaction instead of treating an uncertain spawn as absent.
    handlers.closed(error)
    operation?
      .completion(
        .failure(MuxError(.connectionLost, "guardian outcome unknown"))
      )
  }
}
