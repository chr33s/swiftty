import Darwin
import Dispatch
import Foundation
import SwiftMuxProtocol
import SwiftMuxXPC

extension GuardianServer {
  func accept(_ channel: SMXChannel) {
    guard !stopping, channel.peerEUID == geteuid(),
      peers.count < limits.maxPanes + 8,
      peerRequirement.map({ channel.requirePeer(codeSigning: $0) }) ?? true
    else {
      channel.cancel();
      return
    }
    let id = UUID()
    peers[id] = Peer(channel)
    channel.activate(
      recordLimit: { GuardianWire.recordLimit },
      endpointHandler: { [weak self] data, endpoint in
        self?.publishEndpoint(data, endpoint: endpoint, from: id)
      }
    ) { [weak self] event in
      guard let self else { return }
      switch event {
      case let .message(data):
        do {
          try self.receive(
            JSONDecoder().decode(GuardianRequest.self, from: data),
            from: id,
            encodedBytes: data.count
          )
        } catch {
          self.reject(id, MuxError(.invalidRequest, "invalid guardian request"))
        }
      case .closed:
        if let workspace = self.peers.removeValue(forKey: id)?.workspace,
          let value = self.workspaces[workspace], value.connection == id
        {
          self.loseWorker(value)
        }
      }
    }
    queue.asyncAfter(deadline: .now() + 5) { [weak self] in
      guard let self, let peer = self.peers[id], peer.workspace == nil else {
        return
      }
      self.reject(id, MuxError(.unauthorized, "worker handshake timed out"))
    }
  }

  private func publishEndpoint(
    _ data: Data,
    endpoint: SMXEndpoint,
    from id: UUID
  ) {
    guard !stopping, let peer = peers[id], let workspaceID = peer.workspace,
      let workspace = workspaces[workspaceID], workspace.connection == id,
      !workspace.unavailable, workspace.serviceEndpoint == nil,
      let publication = try? JSONDecoder()
        .decode(GuardianEndpointPublication.self, from: data),
      publication.version == GuardianWire.version,
      publication.authority == workspace.authority,
      peer.channel.peerPID == workspace.expectedPID
    else {
      reject(id, MuxError(.unauthorized, "invalid worker endpoint publication"))
      return
    }
    workspace.serviceEndpoint = GuardianWorkerEndpoint(
      authority: workspace.authority,
      instance: publication.instance,
      pid: workspace.expectedPID,
      endpoint: endpoint
    )
    send(.endpointPublished(instance: publication.instance), to: workspace)
  }

  func receive(
    _ request: GuardianRequest,
    from id: UUID,
    encodedBytes: Int
  ) throws {
    guard let peer = peers[id] else { return }
    if case let .hello(version, workspaceID, token) = request {
      guard version == GuardianWire.version, peer.workspace == nil,
        let workspace = workspaces[workspaceID], workspace.token == token,
        workspace.expectedPID == peer.channel.peerPID,
        workspace.connection == nil, !workspace.unavailable, !stopping
      else {
        reject(id, MuxError(.unauthorized, "invalid worker admission"));
        return
      }
      workspace.token = nil
      workspace.connection = id
      peer.workspace = workspaceID
      send(.welcome(authority: workspace.authority), to: workspace)
      startProgressWatchdog(workspace)
      return
    }
    guard let workspaceID = peer.workspace,
      let workspace = workspaces[workspaceID], workspace.connection == id,
      !workspace.unavailable, !stopping
    else {
      reject(id, MuxError(.unauthorized, "worker is not admitted"));
      return
    }
    let authority: GuardianAuthority
    switch request {
    case let .command(value, _, _), let .retire(value, _),
      let .outputAck(value, _, _), let .progress(value, _),
      let .subscribeGateway(value), let .gatewayApplied(value, _):
      authority = value
    case .hello: return
    }
    guard authority == workspace.authority else {
      reject(id, MuxError(.staleAttachment, "stale guardian authority"));
      return
    }
    switch request {
    case .subscribeGateway:
      guard workspace.serviceEndpoint != nil, !workspace.observesGateway else {
        reject(id, MuxError(.invalidRequest, "invalid gateway subscription"))
        return
      }
      workspace.observesGateway = true
      publishGatewayBinding(workspace)
    case let .gatewayApplied(_, revision):
      guard workspace.observesGateway,
        revision > workspace.appliedGatewayRevision,
        revision == workspace.inFlightGatewayRevision
      else {
        reject(id, MuxError(.invalidRequest, "invalid gateway acknowledgement"))
        return
      }
      workspace.appliedGatewayRevision = revision
      workspace.inFlightGatewayRevision = nil
      sendCurrentGatewayBinding(workspace)
    case let .progress(_, probe):
      guard workspace.progressProbe == probe,
        DispatchTime.now() < workspace.progressDeadline
      else {
        reject(
          id,
          MuxError(.invalidRequest, "invalid or expired progress probe")
        )
        return
      }
      acknowledgeProgress(workspace)
    case let .command(_, sequence, command):
      if sequence < workspace.nextCommand {
        guard let (previous, result, _) = workspace.results[sequence],
          previous == command
        else {
          reject(
            id,
            MuxError(.invalidRequest, "retired or conflicting command retry")
          );
          return
        }
        send(.result(sequence: sequence, value: result), to: workspace)
        return
      }
      if let pending = workspace.pendingLaunch {
        if sequence == workspace.nextCommand {
          guard command == pending.command else {
            reject(
              id,
              MuxError(.invalidRequest, "conflicting pending launch retry")
            );
            return
          }  // The original result will satisfy this retry when launch settles.
        } else {
          send(.retry(sequence: sequence), to: workspace)
        }
        return
      }
      guard sequence == workspace.nextCommand, sequence < UInt64.max else {
        reject(id, MuxError(.invalidRequest, "command sequence gap"));
        return
      }
      // A full window does not forget a result or consume this sequence.
      // Retire acknowledged replies, then retry the same command/sequence.
      let charge = encodedBytes * 2 + 1024
      guard encodedBytes <= GuardianWire.commandRecordLimit else {
        reject(
          id,
          MuxError(.resourceLimit, "command exceeds deduplication budget")
        )
        return
      }
      guard workspace.results.count < GuardianWire.commandWindow,
        charge <= (1 << 20) - workspace.resultBytes,
        charge <= (16 << 20) - resultBytes
      else {
        send(.retry(sequence: sequence), to: workspace)
        return
      }
      if case .spawn = command {
        do {
          try beginSpawn(command, workspace: workspace, charge: charge)
          return
        } catch let error as MuxError {
          recordResult(
            .rejected(error),
            command: command,
            workspace: workspace,
            charge: charge
          )
          return
        }
      }
      let result: GuardianResult
      do { result = try perform(command, workspace: workspace) } catch let error
        as MuxError
      { result = .rejected(error) } catch {
        result = .rejected(
          MuxError(.invalidRequest, "guardian operation failed")
        )
      }
      recordResult(
        result,
        command: command,
        workspace: workspace,
        charge: charge
      )
    case let .retire(_, through):
      guard through < workspace.nextCommand else {
        reject(
          id,
          MuxError(.invalidRequest, "cannot retire an unexecuted command")
        );
        return
      }
      guard through > workspace.retired else { return }
      let released = workspace.results.filter { $0.key <= through }.values
        .reduce(0) { $0 + $1.2 }
      workspace.resultBytes -= released
      resultBytes -= released
      workspace.results = workspace.results.filter { $0.key > through }
      workspace.retired = through
    case let .outputAck(_, paneID, through):
      guard let pane = workspace.panes[paneID.pane],
        pane.process == paneID.process, through < pane.nextOutput
      else {
        reject(
          id,
          MuxError(.invalidRequest, "output acknowledgement beyond sent data")
        );
        return
      }
      guard through > pane.acknowledged else { return }
      let released = pane.outstanding.filter { $0.key <= through }.values
        .reduce(0, +)
      pane.outstanding = pane.outstanding.filter { $0.key > through }
      pane.acknowledged = through
      pane.outputBytes -= released
      workspace.outputBytes -= released
      outputBytes -= released
      // Host/workspace pressure may have paused other panes as well.
      for group in workspaces.values where !group.unavailable {
        for value in group.panes.values { value.runtime.flush() }
      }
    case .hello: break
    }
  }

  func recordResult(
    _ result: GuardianResult,
    command: GuardianCommand,
    workspace: Workspace,
    charge: Int,
    alreadyReserved: Bool = false
  ) {
    guard !workspace.unavailable else { return }
    let sequence = workspace.nextCommand
    workspace.results[sequence] = (command, result, charge)
    if !alreadyReserved {
      workspace.resultBytes += charge
      resultBytes += charge
    }
    workspace.nextCommand += 1
    send(.result(sequence: sequence, value: result), to: workspace)
  }

  func send(_ event: GuardianEvent, to workspace: Workspace) {
    guard let id = workspace.connection, let peer = peers[id],
      let bytes = try? JSONEncoder().encode(event),
      bytes.count <= GuardianWire.recordLimit
    else { return }
    peer.channel.send(bytes)
  }

  func reject(_ id: UUID, _ error: MuxError) {
    guard let peer = peers.removeValue(forKey: id) else { return }
    if let bytes = try? JSONEncoder().encode(GuardianEvent.refused(error)) {
      peer.channel.send(bytes)
    }
    peer.channel.cancel()
    if let workspaceID = peer.workspace,
      let workspace = workspaces[workspaceID], workspace.connection == id
    {
      loseWorker(workspace)
    }
  }

  func loseWorker(_ workspace: Workspace) {
    guard !workspace.unavailable else { return }
    let previous = workspace.connection
    workspace.unavailable = true
    workspace.connection = nil
    workspace.serviceEndpoint = nil
    workspace.token = nil
    workspace.writer = nil
    workspace.progressTimer?.cancel()
    workspace.progressTimer = nil
    workspace.progressProbe = nil
    if let previous { peers.removeValue(forKey: previous)?.channel.cancel() }
    for pane in workspace.panes.values {
      pane.runtime.detachConsumer()
      pane.outstanding.removeAll()
      pane.outputBytes = 0
    }
    outputBytes -= workspace.outputBytes
    workspace.outputBytes = 0
    // No history replay is promised. Results cannot be accessed after the
    // connection is fenced; the process inventory is deliberately retained.
    resultBytes -= workspace.resultBytes
    workspace.resultBytes = 0
    workspace.results.removeAll()
    workspace.worker?.terminate()
  }
}
