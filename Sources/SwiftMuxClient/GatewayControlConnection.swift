#if os(macOS)
import Darwin
import Dispatch
import Foundation
import SwiftMuxProtocol
import SwiftMuxXPC

/// Queue-confined native bootstrap connection. One admitted command remains
/// outstanding until its result arrives; uncertain mutations are never replayed.
/// Construct and call on the channel queue. Callbacks use that same queue.
/// Sendable: state is touched only on the channel queue.
package final class GatewayControlConnection: @unchecked Sendable {
  package struct Route: Sendable {
    package let descriptor: GatewayRouteDescriptor
    package let endpoint: SMXEndpoint
    /// A terminal connection must authenticate this PID and descriptor.server.
    package let gatewayPID: Int32
  }

  package enum Reply: Sendable {
    case workspaces([GatewayWorkspaceRecord])
    case route(Route)
    case created(WorkspaceID)
    case ended
    case savedWorkspaces(SavedWorkspaceList)
    case reopened(WorkspaceID, WorkspaceTemplateOutcome)
    case savedPolicy(SavedLayoutPolicy)
    case deletedSaved
    case previousOutput(SavedOutputPage)
    case installation(GatewayInstallationStatus)
  }

  private struct Pending {
    let command: GatewayControlCommand
    let completion: @Sendable (Result<Reply, MuxError>) -> Void
  }

  private let channel: SMXChannel
  private let expectedPID: Int32?
  private let timeout: TimeInterval
  private let onReady: @Sendable (ServerInstanceID) -> Void
  private let onClosed: @Sendable (MuxError) -> Void
  private var identity: ServerInstanceID?
  private var gatewayPID: Int32?
  private var sequence: UInt64 = 1
  private var pending: Pending?
  private var timer: DispatchSourceTimer?
  private var deadline: DispatchTime?
  private var ended = false

  package init(
    channel: SMXChannel,
    peerRequirement: String?,
    expectedPID: Int32? = nil,
    timeout: TimeInterval = 30,
    ready: @escaping @Sendable (ServerInstanceID) -> Void,
    closed: @escaping @Sendable (MuxError) -> Void
  ) throws {
    self.channel = channel
    self.expectedPID = expectedPID
    self.timeout = timeout
    onReady = ready
    onClosed = closed
    guard timeout.isFinite, timeout > 0, timeout <= 30,
      expectedPID.map({ $0 > 0 }) ?? true
    else {
      channel.cancel()
      throw MuxError(
        .invalidRequest,
        "invalid gateway connection configuration"
      )
    }
    guard peerRequirement.map({ channel.requirePeer(codeSigning: $0) }) ?? true
    else {
      channel.cancel()
      throw MuxError(.unauthorized, "gateway signing requirement rejected")
    }
    channel.activate(
      recordLimit: { GatewayControl.recordLimit },
      endpointHandler: { [weak self] data, endpoint in
        self?.receive(data, endpoint: endpoint)
      }
    ) { [weak self] event in
      switch event {
      case let .message(data): self?.receive(data, endpoint: nil)
      case .closed:
        self?
          .finish(MuxError(.connectionLost, "gateway control connection lost"))
      }
    }
    armDeadline(min(timeout, 5))
    send(.hello(version: GatewayControl.version))
  }

  deinit {
    timer?.cancel()
    channel.cancel()
  }

  /// False means no submission. A local validation failure is delivered through
  /// completion without consuming a sequence or closing the connection.
  @discardableResult
  package func submit(
    _ command: GatewayControlCommand,
    completion: @escaping @Sendable (Result<Reply, MuxError>) -> Void
  ) -> Bool {
    guard !ended, let identity, pending == nil, sequence < UInt64.max else {
      return false
    }
    do {
      switch command {
      case let .create(_, launch):
        _ = try MuxConnection.commandPayloadBytes(.newWorkspace(launch))
      case let .route(selector, _), let .end(selector):
        _ = try MuxConnection.commandPayloadBytes(.endWorkspace(selector))
      case let .reopenSaved(request):
        _ = try MuxConnection.commandPayloadBytes(
          .newWorkspace(NewWorkspaceRequest(launch: request.launch))
        )
      case .listWorkspaces, .savedWorkspaces, .setSavedPolicy, .deleteSaved,
        .previousOutput, .discardPreviousOutput, .installationStatus:
        break
      }
      let request = GatewayControlRequest.command(
        gateway: identity,
        sequence: sequence,
        body: command
      )
      let data = try JSONEncoder().encode(request)
      guard data.count <= GatewayControl.recordLimit else {
        throw MuxError(.resourceLimit, "gateway command exceeds record limit")
      }
      pending = Pending(command: command, completion: completion)
      armDeadline(timeout)
      channel.send(data)
    } catch {
      completion(
        .failure(
          error as? MuxError
            ?? MuxError(.invalidRequest, "cannot encode gateway command")
        )
      )
    }
    return true
  }

  package func close() {
    finish(MuxError(.connectionLost, "gateway control connection closed"))
  }

  private func receive(_ data: Data, endpoint: SMXEndpoint?) {
    guard !ended else { return }
    guard channel.peerEUID == geteuid(), channel.peerPID > 0,
      expectedPID.map({ channel.peerPID == $0 }) ?? true,
      gatewayPID.map({ channel.peerPID == $0 }) ?? true
    else {
      finish(MuxError(.unauthorized, "unexpected gateway peer"))
      return
    }
    guard
      let event = try? JSONDecoder()
        .decode(GatewayControlEvent.self, from: data)
    else {
      invalidResponse()
      return
    }
    switch event {
    case let .welcome(version, gateway):
      guard identity == nil, endpoint == nil else {
        invalidResponse();
        return
      }
      guard version == GatewayControl.version else {
        finish(
          MuxError(.incompatibleVersion, "unsupported gateway control version")
        )
        return
      }
      disarmDeadline()
      identity = gateway
      gatewayPID = channel.peerPID
      onReady(gateway)
    case let .refused(error):
      guard endpoint == nil else {
        invalidResponse();
        return
      }
      finish(error)
    case let .result(number, value):
      guard identity != nil, let pending, number == sequence else {
        invalidResponse();
        return
      }
      let result: Result<Reply, MuxError>
      switch value {
      case let .failure(error):
        guard endpoint == nil else {
          invalidResponse();
          return
        }
        result = .failure(error)
      case let .success(value):
        guard
          let reply = validate(
            value,
            endpoint: endpoint,
            command: pending.command
          )
        else {
          invalidResponse();
          return
        }
        result = .success(reply)
      }
      disarmDeadline()
      self.pending = nil
      send(.acknowledge(sequence: sequence))
      sequence += 1
      pending.completion(result)
    }
  }

  private func validate(
    _ reply: GatewayControlReply,
    endpoint: SMXEndpoint?,
    command: GatewayControlCommand
  ) -> Reply? {
    if case let .route(descriptor) = reply {
      guard case let .route(selector, _) = command, let endpoint, let gatewayPID
      else { return nil }
      if case let .id(workspace) = selector, workspace != descriptor.workspace {
        return nil
      }
      return .route(
        Route(
          descriptor: descriptor,
          endpoint: endpoint,
          gatewayPID: gatewayPID
        )
      )
    }
    guard endpoint == nil else { return nil }
    switch (command, reply) {
    case (.listWorkspaces, let .workspaces(records)):
      guard records.count <= GatewayControl.maxWorkspaces,
        Set(records.map(\.workspace)).count == records.count,
        records.allSatisfy({ record in
          record.summary.map { $0.id == record.workspace } ?? true
        })
      else { return nil }
      return .workspaces(records)
    case let (.create(expected, _), .created(actual)) where expected == actual:
      return .created(actual)
    case (.end, .ended): return .ended
    case (.savedWorkspaces, let .savedWorkspaces(list)):
      guard list.workspaces.count <= GatewayControl.maxWorkspaces,
        Set(list.workspaces.map(\.id)).count == list.workspaces.count
      else { return nil }
      return .savedWorkspaces(list)
    case let (.reopenSaved(request), .reopened(id, outcome))
    where id != request.record: return .reopened(id, outcome)
    case let (.setSavedPolicy(policy, expected), .savedPolicy(value))
    where value.revision > expected && value.isValid
      && value.saveLayout == policy.saveLayout
      && value.saveOutput == policy.saveOutput:
      return .savedPolicy(value)
    case (.deleteSaved, .deletedSaved), (.discardPreviousOutput, .deletedSaved):
      return .deletedSaved
    case let (.previousOutput(_, _, offset), .previousOutput(page))
    where page.offset == offset && page.bytes.count <= SavedOutputPage.maxBytes
      && page.total <= SavedOutput.maxBytes:
      return .previousOutput(page)
    case let (.installationStatus, .installation(status))
    where status.workspaces >= 0: return .installation(status)
    default: return nil
    }
  }

  private func send(_ request: GatewayControlRequest) {
    guard let data = try? JSONEncoder().encode(request) else {
      invalidResponse();
      return
    }
    channel.send(data)
  }

  private func disarmDeadline() {
    timer?.cancel()
    timer = nil
    deadline = nil
  }

  private func armDeadline(_ timeout: TimeInterval) {
    disarmDeadline()
    let deadline = DispatchTime.now() + timeout
    self.deadline = deadline
    let timer = DispatchSource.makeTimerSource(queue: channel.queue)
    timer.schedule(deadline: deadline)
    timer.setEventHandler { [weak self] in
      guard let self, self.deadline == deadline else { return }
      self.finish(
        MuxError(.connectionLost, "gateway control response timed out")
      )
    }
    self.timer = timer
    timer.resume()
  }

  private func invalidResponse() {
    finish(MuxError(.invalidRequest, "unexpected gateway control response"))
  }

  private func finish(_ error: MuxError) {
    guard !ended else { return }
    ended = true
    disarmDeadline()
    let pending = pending
    self.pending = nil
    channel.cancel()
    pending?.completion(.failure(error))
    onClosed(error)
  }
}
#endif
