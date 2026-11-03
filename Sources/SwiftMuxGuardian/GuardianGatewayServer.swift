import Darwin
import Dispatch
import Foundation
import SwiftMuxProtocol
import SwiftMuxXPC

/// Separate listener so workers cannot promote their own connection to gateway
/// authority. Production supplies the designated gateway signing requirement.
package final class GuardianGatewayServer: @unchecked Sendable {
  private let queue = DispatchQueue(label: "swiftmux.guardian.gateway")
  private let guardian: GuardianServer
  private let peerRequirement: String?
  private let buildRegistry: GuardianBuildRegistry?
  private let workerMachService: String?
  private var listener: SMXListener?
  private var peers: [UUID: Peer] = [:]
  private var current: UUID?
  private var stopped = false

  private final class Peer {
    let channel: SMXChannel
    var identity: UUID?
    var sequence: UInt64 = 1
    var executing: GuardianGatewayRequest?
    var pending: (GuardianGatewayRequest, Data, SMXEndpoint?)?
    init(_ channel: SMXChannel) { self.channel = channel }
  }

  package init(
    guardian: GuardianServer,
    peerRequirement: String?,
    buildRegistry: GuardianBuildRegistry? = nil,
    workerMachService: String? = nil
  ) {
    precondition((buildRegistry == nil) == (workerMachService == nil))
    buildRegistry?.claimSelection(for: guardian.incarnation)
    self.guardian = guardian
    self.peerRequirement = peerRequirement
    self.buildRegistry = buildRegistry
    self.workerMachService = workerMachService
  }

  package func listenAnonymously() -> SMXEndpoint {
    queue.sync {
      precondition(listener == nil && !stopped)
      let value = SMXListener(anonymousOn: queue)
      activate(value)
      return value.endpoint
    }
  }

  package func listen(machService: String) {
    queue.sync {
      precondition(listener == nil && !stopped)
      activate(SMXListener(machService: machService, queue: queue))
    }
  }

  package func close() {
    queue.sync {
      stopped = true
      listener?.cancel()
      listener = nil
      for id in Array(peers.keys) { remove(id) }
    }
  }

  private func activate(_ value: SMXListener) {
    listener = value
    value.activate(connectionQueue: queue) { [weak self] channel in
      self?.accept(channel)
    }
  }

  private func accept(_ channel: SMXChannel) {
    guard !stopped, peers.count < 8, channel.peerEUID == geteuid(),
      peerRequirement.map({ channel.requirePeer(codeSigning: $0) }) ?? true
    else {
      channel.cancel();
      return
    }
    let id = UUID()
    peers[id] = Peer(channel)
    channel.activate(recordLimit: { GuardianWire.recordLimit }) {
      [weak self] event in
      guard let self else { return }
      switch event {
      case let .message(data):
        guard
          let request = try? JSONDecoder()
            .decode(GuardianGatewayRequest.self, from: data)
        else {
          self.reject(id, MuxError(.invalidRequest, "invalid gateway request"));
          return
        }
        self.receive(request, from: id)
      case .closed: self.remove(id)
      }
    }
    queue.asyncAfter(deadline: .now() + 5) { [weak self] in
      guard let self, let peer = self.peers[id], peer.identity == nil else {
        return
      }
      self.reject(id, MuxError(.unauthorized, "gateway handshake timed out"))
    }
  }

  private func receive(_ request: GuardianGatewayRequest, from id: UUID) {
    guard !stopped, let peer = peers[id] else { return }
    if case let .hello(version) = request {
      guard version == GuardianWire.version, peer.identity == nil else {
        reject(id, MuxError(.unauthorized, "invalid gateway admission"));
        return
      }
      if let current { remove(current) }
      let identity = UUID()
      peer.identity = identity
      current = id
      guardian.replaceGateway(identity, pid: peer.channel.peerPID)
      send(
        .welcome(
          incarnation: guardian.incarnation,
          gateway: identity,
          supportsEnsureWriter: true,
          supportsAdmissionControl: true,
          supportsWorkerSelection: buildRegistry != nil
        ),
        to: peer
      )
      return
    }
    guard current == id, let identity = peer.identity else {
      reject(id, MuxError(.unauthorized, "gateway is not admitted"));
      return
    }
    if case let .acknowledge(sequence) = request {
      guard sequence == peer.sequence, peer.pending != nil,
        sequence < UInt64.max
      else {
        reject(
          id,
          MuxError(.invalidRequest, "invalid gateway acknowledgement")
        );
        return
      }
      peer.pending = nil
      peer.sequence += 1
      return
    }
    guard case let .command(incarnation, gateway, sequence, body) = request,
      incarnation == guardian.incarnation, gateway == identity,
      sequence == peer.sequence
    else {
      reject(id, MuxError(.staleAttachment, "stale gateway command"));
      return
    }
    if let pending = peer.pending {
      guard pending.0 == request else {
        reject(id, MuxError(.invalidRequest, "conflicting gateway command"));
        return
      }
      deliver(pending.1, endpoint: pending.2, to: peer)
      return
    }
    if let executing = peer.executing {
      if executing != request {
        reject(id, MuxError(.invalidRequest, "conflicting pending command"))
      }
      return
    }
    let result: GuardianGatewayResult
    var endpoint: SMXEndpoint?
    do {
      switch body {
      case .workerSelection:
        guard let buildRegistry else {
          throw MuxError(.notAttached, "worker installation is not configured")
        }
        result = .workerSelection(try buildRegistry.selection())
      case .selectWorkerBuild, .clearWorkerRollback:
        guard let buildRegistry else {
          throw MuxError(.notAttached, "worker installation is not configured")
        }
        peer.executing = request
        let complete:
          @Sendable (Result<GuardianAdmissionStatus, MuxError>) -> Void = {
            [weak self] outcome in
            guard let self else { return }
            self.queue.async { [self] in
              let result: GuardianGatewayResult
              switch outcome {
              case let .success(status): result = .admission(status)
              case let .failure(error): result = .rejected(error)
              }
              finish(request, result: result, endpoint: nil, from: id)
            }
          }
        switch body {
        case let .selectWorkerBuild(build, revision):
          guardian.selectWorkerBuild(
            build,
            registry: buildRegistry,
            expectedRevision: revision,
            gateway: identity,
            completion: complete
          )
        case let .clearWorkerRollback(revision):
          guardian.clearWorkerRollback(
            registry: buildRegistry,
            expectedRevision: revision,
            gateway: identity,
            completion: complete
          )
        default: preconditionFailure()
        }
        return
      case .admissionStatus:
        result = .admission(try guardian.admissionStatus(gateway: identity))
      case let .setAdmissionPaused(paused, expectedRevision):
        result = .admission(
          try guardian.setAdmissionPaused(
            paused,
            expectedRevision: expectedRevision,
            gateway: identity
          )
        )
      case .inventory: result = .inventory(guardian.inventory())
      case let .create(workspace):
        guard let buildRegistry, let workerMachService else {
          throw MuxError(.notAttached, "worker installation is not configured")
        }
        result = .creating(
          try guardian.createWorker(
            workspace: workspace,
            registry: buildRegistry,
            machService: workerMachService,
            gateway: identity
          )
        )
      case let .endpoint(workspace):
        guard guardian.gatewayReady(workspace: workspace, gateway: identity),
          let value = guardian.workerEndpoint(workspace: workspace)
        else {
          throw MuxError(.notAttached, "worker gateway binding is not ready")
        }
        result = .endpoint(
          authority: value.authority,
          instance: value.instance,
          pid: value.pid
        )
        endpoint = value.endpoint
      case let .grantWriter(workspace):
        result = .writer(
          try guardian.grantWriter(workspace: workspace, gateway: identity)
        )
      case let .ensureWriter(authority):
        result = .writer(
          try guardian.ensureWriter(authority: authority, gateway: identity)
        )
      case let .end(authority):
        try guardian.endWorkspace(authority: authority, gateway: identity)
        result = .ending
      case let .forget(authority):
        try guardian.forgetWorkspace(authority: authority, gateway: identity)
        result = .forgotten
      }
    } catch let error as MuxError { result = .rejected(error) } catch {
      result = .rejected(MuxError(.invalidRequest, "gateway operation failed"))
    }
    finish(request, result: result, endpoint: endpoint, from: id)
  }

  private func finish(
    _ request: GuardianGatewayRequest,
    result: GuardianGatewayResult,
    endpoint: SMXEndpoint?,
    from id: UUID
  ) {
    guard !stopped, current == id, let peer = peers[id],
      case let .command(_, _, sequence, _) = request, sequence == peer.sequence
    else { return }
    peer.executing = nil
    guard
      let data = try? JSONEncoder()
        .encode(GuardianGatewayEvent.result(sequence: sequence, value: result)),
      data.count <= GuardianWire.recordLimit
    else {
      reject(
        id,
        MuxError(.resourceLimit, "gateway result exceeds record limit")
      );
      return
    }
    peer.pending = (request, data, endpoint)
    deliver(data, endpoint: endpoint, to: peer)
  }

  private func send(_ event: GuardianGatewayEvent, to peer: Peer) {
    if let data = try? JSONEncoder().encode(event) { peer.channel.send(data) }
  }

  private func deliver(_ data: Data, endpoint: SMXEndpoint?, to peer: Peer) {
    if let endpoint {
      peer.channel.send(data, endpoint: endpoint)
    } else {
      peer.channel.send(data)
    }
  }

  private func reject(_ id: UUID, _ error: MuxError) {
    if let peer = peers[id] { send(.refused(error), to: peer) }
    remove(id)
  }

  private func remove(_ id: UUID) {
    guard let peer = peers.removeValue(forKey: id) else { return }
    if current == id {
      current = nil
      if let identity = peer.identity { guardian.revokeGateway(identity) }
    }
    peer.channel.cancel()
  }
}
