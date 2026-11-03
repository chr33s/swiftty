import Darwin
import Dispatch
import Foundation
import SwiftMuxProtocol
import SwiftMuxXPC

/// Gateway side of the supervisor link. All methods and callbacks use the
/// channel queue. One command is admitted at a time; false means not submitted.
/// A failed admitted command has an unknown outcome and is never replayed here.
package final class GuardianGatewayConnection: @unchecked Sendable {
  package struct Identity: Sendable {
    package let incarnation: UUID
    package let gateway: UUID
    package let supportsEnsureWriter: Bool
    package let supportsAdmissionControl: Bool
    package let supportsWorkerSelection: Bool
  }

  package enum Reply: Sendable {
    case inventory([GuardianWorkspaceInventory])
    case admission(GuardianAdmissionStatus)
    case workerSelection(GuardianWorkerSelection)
    case creating(GuardianAuthority)
    case endpoint(GuardianWorkerEndpoint)
    case writer(UUID)
    case ending
    case forgotten
    case rejected(MuxError)
  }

  private struct Pending {
    let command: GuardianGatewayCommand
    let completion: @Sendable (Result<Reply, MuxError>) -> Void
  }

  private let channel: SMXChannel
  private let expectedGuardianPID: Int32?
  private let timeout: TimeInterval
  private let onReady: @Sendable (Identity) -> Void
  private let onClosed: @Sendable (MuxError) -> Void
  private var identity: Identity?
  private var sequence: UInt64 = 1
  private var pending: Pending?
  private var timer: DispatchSourceTimer?
  private var ended = false

  package init(
    channel: SMXChannel,
    peerRequirement: String?,
    expectedGuardianPID: Int32? = nil,
    timeout: TimeInterval = 5,
    ready: @escaping @Sendable (Identity) -> Void,
    closed: @escaping @Sendable (MuxError) -> Void
  ) throws {
    self.channel = channel
    self.expectedGuardianPID = expectedGuardianPID
    self.timeout = timeout
    onReady = ready
    onClosed = closed
    guard timeout.isFinite, timeout > 0, timeout <= 5 else {
      channel.cancel()
      throw MuxError(.invalidRequest, "invalid gateway response timeout")
    }
    guard peerRequirement.map({ channel.requirePeer(codeSigning: $0) }) ?? true
    else {
      channel.cancel()
      throw MuxError(.unauthorized, "guardian signing requirement rejected")
    }
    channel.activate(
      recordLimit: { GuardianWire.recordLimit },
      endpointHandler: { [weak self] data, endpoint in
        self?.receive(data, endpoint: endpoint)
      }
    ) { [weak self] event in
      switch event {
      case let .message(data): self?.receive(data, endpoint: nil)
      case .closed:
        self?.finish(MuxError(.connectionLost, "guardian connection lost"))
      }
    }
    armDeadline()
    send(.hello(version: GuardianWire.version))
  }

  deinit {
    timer?.cancel();
    channel.cancel()
  }

  @discardableResult
  package func submit(
    _ command: GuardianGatewayCommand,
    completion: @escaping @Sendable (Result<Reply, MuxError>) -> Void
  ) -> Bool {
    guard !ended, let identity, pending == nil, sequence < UInt64.max else {
      return false
    }
    if case .ensureWriter = command, !identity.supportsEnsureWriter {
      completion(
        .success(
          .rejected(
            MuxError(
              .incompatibleVersion,
              "guardian does not support stable writer grants"
            )
          )
        )
      )
      return true
    }
    switch command {
    case .admissionStatus, .setAdmissionPaused:
      guard identity.supportsAdmissionControl else {
        completion(
          .success(
            .rejected(
              MuxError(
                .incompatibleVersion,
                "guardian does not support admission control"
              )
            )
          )
        )
        return true
      }
    case .workerSelection, .selectWorkerBuild, .clearWorkerRollback:
      guard identity.supportsWorkerSelection else {
        completion(
          .success(
            .rejected(
              MuxError(
                .incompatibleVersion,
                "guardian does not support worker selection"
              )
            )
          )
        )
        return true
      }
    default: break
    }
    pending = Pending(command: command, completion: completion)
    armDeadline()
    send(
      .command(
        incarnation: identity.incarnation,
        gateway: identity.gateway,
        sequence: sequence,
        body: command
      )
    )
    return true
  }

  package func close() {
    finish(MuxError(.connectionLost, "gateway control connection closed"))
  }

  private func receive(_ data: Data, endpoint: SMXEndpoint?) {
    guard !ended else { return }
    guard channel.peerEUID == geteuid(),
      expectedGuardianPID.map({ channel.peerPID == $0 }) ?? true,
      let event = try? JSONDecoder()
        .decode(GuardianGatewayEvent.self, from: data)
    else {
      finish(MuxError(.unauthorized, "invalid guardian peer or message"));
      return
    }
    switch event {
    case let .welcome(
      incarnation,
      gateway,
      supportsEnsureWriter,
      supportsAdmissionControl,
      supportsWorkerSelection
    ):
      guard identity == nil, endpoint == nil else {
        invalidResponse();
        return
      }
      timer?.cancel()
      timer = nil
      let value = Identity(
        incarnation: incarnation,
        gateway: gateway,
        supportsEnsureWriter: supportsEnsureWriter == true,
        supportsAdmissionControl: supportsAdmissionControl == true,
        supportsWorkerSelection: supportsWorkerSelection == true
      )
      identity = value
      onReady(value)
    case let .refused(error):
      guard endpoint == nil else {
        invalidResponse();
        return
      }
      finish(error)
    case let .result(number, value):
      guard let identity, let pending, number == sequence,
        let reply = validate(
          value,
          endpoint: endpoint,
          command: pending.command,
          identity: identity
        )
      else {
        invalidResponse();
        return
      }
      timer?.cancel()
      timer = nil
      self.pending = nil
      send(.acknowledge(sequence: sequence))
      sequence += 1
      pending.completion(.success(reply))
    }
  }

  private func validate(
    _ result: GuardianGatewayResult,
    endpoint: SMXEndpoint?,
    command: GuardianGatewayCommand,
    identity: Identity
  ) -> Reply? {
    if case let .endpoint(authority, instance, pid) = result {
      guard case let .endpoint(workspace) = command, let endpoint,
        authority.incarnation == identity.incarnation,
        authority.workspace == workspace, authority.generation > 0, pid > 0
      else { return nil }
      return .endpoint(
        GuardianWorkerEndpoint(
          authority: authority,
          instance: instance,
          pid: pid,
          endpoint: endpoint
        )
      )
    }
    guard endpoint == nil else { return nil }
    switch (command, result) {
    case let (.create(workspace), .creating(authority)):
      guard authority.incarnation == identity.incarnation,
        authority.workspace == workspace, authority.generation > 0
      else { return nil }
      return .creating(authority)
    case (_, let .rejected(error)): return .rejected(error)
    case (.inventory, let .inventory(items)):
      guard
        items.allSatisfy({
          $0.authority.incarnation == identity.incarnation
            && $0.authority.generation > 0
        }), Set(items.map { $0.authority.workspace }).count == items.count
      else { return nil }
      return .inventory(items)
    case (.grantWriter, let .writer(capability)),
      (.ensureWriter, let .writer(capability)):
      return .writer(capability)
    case (.admissionStatus, let .admission(status)):
      guard status.pendingWorkers >= 0 else { return nil }
      return .admission(status)
    case let (.setAdmissionPaused(paused, expectedRevision), .admission(status)):
      guard status.pendingWorkers >= 0, status.selectionPending != true,
        status.paused == paused, expectedRevision < UInt64.max,
        status.revision == expectedRevision + 1
      else { return nil }
      return .admission(status)
    case (.workerSelection, let .workerSelection(selection)):
      guard selection.selected != nil || selection.rollback == nil,
        selection.rollback == nil || selection.rollback != selection.selected,
        [selection.selected, selection.rollback].compactMap({ $0 })
          .allSatisfy({
            !$0.isEmpty && $0.utf8.count <= 128 && !$0.hasPrefix(".")
              && $0.utf8.allSatisfy {
                (48 ... 57).contains($0) || (65 ... 90).contains($0)
                  || (97 ... 122).contains($0) || $0 == 45 || $0 == 46
                  || $0 == 95
              }
          })
      else { return nil }
      return .workerSelection(selection)
    case let (.selectWorkerBuild(_, expectedRevision), .admission(status)),
      let (.clearWorkerRollback(expectedRevision), .admission(status)):
      guard status.paused, status.selectionPending == false,
        status.pendingWorkers == 0, expectedRevision < UInt64.max,
        status.revision == expectedRevision + 1
      else { return nil }
      return .admission(status)
    case (.end, .ending): return .ending
    case (.forget, .forgotten): return .forgotten
    default: return nil
    }
  }

  private func send(_ request: GuardianGatewayRequest) {
    guard let data = try? JSONEncoder().encode(request),
      data.count <= GuardianWire.recordLimit
    else {
      finish(MuxError(.invalidRequest, "cannot encode guardian command"));
      return
    }
    channel.send(data)
  }

  private func armDeadline() {
    timer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: channel.queue)
    timer.schedule(deadline: .now() + timeout)
    timer.setEventHandler { [weak self] in
      self?.finish(MuxError(.connectionLost, "guardian response timed out"))
    }
    self.timer = timer
    timer.resume()
  }

  private func invalidResponse() {
    finish(MuxError(.invalidRequest, "unexpected guardian response"))
  }

  private func finish(_ error: MuxError) {
    guard !ended else { return }
    ended = true
    timer?.cancel()
    timer = nil
    let pending = pending
    self.pending = nil
    channel.cancel()
    pending?.completion(.failure(error))
    onClosed(error)
  }
}
