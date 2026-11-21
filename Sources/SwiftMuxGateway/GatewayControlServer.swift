import Darwin
import Dispatch
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
import SwiftMuxXPC

/// Native control ingress. State and callbacks belong to queue. Cancelling this
/// listener does not End sessions or close the separately owned runtime.
/// Sendable: peers, jobs and the listener are touched only on `queue`.
package final class GatewayControlServer: @unchecked Sendable {
  private final class Peer {
    let channel: SMXChannel
    var welcomed = false
    var sequence: UInt64 = 1
    var pending: GatewayControlRequest?
    var result: (Data, SMXEndpoint?)?
    var charge = 0
    var replayed = false
    var timer: DispatchSourceTimer?
    var deadline: DispatchTime?
    init(_ channel: SMXChannel) { self.channel = channel }
  }
  private struct Job {
    let task: Task<Void, Never>
    let bytes: Int
  }
  private let queue = DispatchQueue(label: "swiftmux.gateway.control")
  private let identity = ServerInstanceID()
  private let runtime: GatewayRuntime
  private let peerRequirement: String?
  private var listener: SMXListener?
  private var peers: [UUID: Peer] = [:]
  private var jobs: [UUID: Job] = [:]
  private var retainedBytes = 0
  private var closed = false

  package init(runtime: GatewayRuntime, peerRequirement: String?) {
    self.runtime = runtime
    self.peerRequirement = peerRequirement
  }

  package func listenAnonymously() -> SMXEndpoint {
    queue.sync {
      precondition(listener == nil && !closed)
      let value = SMXListener(anonymousOn: queue)
      activate(value)
      return value.endpoint
    }
  }

  package func listen(machService: String) {
    queue.sync {
      precondition(listener == nil && !closed)
      activate(SMXListener(machService: machService, queue: queue))
    }
  }

  package func close() async {
    let pending: [Task<Void, Never>] = await withCheckedContinuation {
      continuation in
      queue.async {
        self.closed = true
        self.listener?.cancel()
        self.listener = nil
        for id in Array(self.peers.keys) { self.remove(id) }
        continuation.resume(returning: self.jobs.values.map(\.task))
      }
    }
    for task in pending { await task.value }
    // Every job queues completion before it finishes. Drain those callbacks too.
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume() }
    }
  }

  deinit {
    listener?.cancel()
    for peer in peers.values {
      peer.timer?.cancel();
      peer.channel.cancel()
    }
    for job in jobs.values { job.task.cancel() }
  }

  private func activate(_ value: SMXListener) {
    listener = value
    value.activate(connectionQueue: queue) { [weak self] channel in
      guard let self, !self.closed, self.peers.count < GatewayControl.maxPeers,
        channel.peerEUID == geteuid(),
        self.peerRequirement.map({ channel.requirePeer(codeSigning: $0) })
          ?? true
      else {
        channel.cancel();
        return
      }
      let id = UUID()
      self.peers[id] = Peer(channel)
      channel.activate(recordLimit: { GatewayControl.recordLimit }) {
        [weak self] event in
        switch event {
        case let .message(data): self?.receive(data, from: id)
        case .closed: self?.remove(id)
        }
      }
      self.arm(id, seconds: 5)
    }
  }

  private func receive(_ data: Data, from id: UUID) {
    guard let peer = peers[id], !closed else { return }
    do {
      if let deadline = peer.deadline, DispatchTime.now() >= deadline {
        throw MuxError(.connectionLost, "gateway control deadline exceeded")
      }
      let request = try SMXCodec.decode(
        GatewayControlRequest.self,
        from: data,
        limit: GatewayControl.recordLimit
      )
      if !peer.welcomed {
        guard case let .hello(version) = request,
          version == GatewayControl.version
        else {
          throw MuxError(
            .incompatibleVersion,
            "unsupported gateway control handshake"
          )
        }
        peer.welcomed = true
        disarm(peer)
        peer.channel.send(
          try encode(
            .welcome(version: GatewayControl.version, gateway: identity)
          )
        )
        return
      }
      switch request {
      case .hello: throw MuxError(.invalidRequest, "duplicate gateway hello")
      case let .acknowledge(sequence):
        guard sequence == peer.sequence, peer.result != nil else {
          throw MuxError(
            .invalidRequest,
            "unexpected gateway result acknowledgement"
          )
        }
        retainedBytes -= peer.charge
        peer.charge = 0
        peer.pending = nil
        peer.result = nil
        peer.replayed = false
        peer.sequence += 1
        disarm(peer)
      case let .command(gateway, sequence, body):
        guard gateway == identity, sequence == peer.sequence,
          sequence < UInt64.max
        else { throw MuxError(.staleAttachment, "stale gateway command") }
        if let pending = peer.pending {
          guard pending == request else {
            throw MuxError(.invalidRequest, "conflicting gateway command")
          }
          if let result = peer.result, !peer.replayed {
            peer.replayed = true
            deliver(result, to: peer)
          }
          return
        }
        let charge: Int
        if case let .create(_, launch) = body {
          charge = max(
            data.count,
            try MuxConnection.commandPayloadBytes(.newWorkspace(launch))
          )
        } else {
          charge = max(data.count, 256)
        }
        guard jobs.count < GatewayControl.maxJobs,
          charge <= GatewayControl.retainedByteLimit - retainedBytes
        else {
          throw MuxError(.resourceLimit, "gateway control capacity exhausted")
        }
        peer.pending = request
        retainedBytes += charge
        let runtime = runtime
        let task = Task.detached { [weak self] in
          let result: GatewayControlResult
          var endpoint: SMXEndpoint?
          do {
            let reply = try await Self.execute(body, runtime: runtime)
            result = .success(reply.0)
            endpoint = reply.1
          } catch {
            result = .failure(
              (error as? MuxError)
                ?? MuxError(.connectionLost, "gateway operation cancelled")
            )
          }
          guard let self else { return }
          let attachment = endpoint
          self.queue.async {
            self.complete(id, result: result, endpoint: attachment)
          }
        }
        jobs[id] = Job(task: task, bytes: charge)
        arm(id, seconds: 30)
      }
    } catch {
      refuse(
        id,
        (error as? MuxError)
          ?? MuxError(.invalidRequest, "invalid gateway control record")
      )
    }
  }

  private static func execute(
    _ command: GatewayControlCommand,
    runtime: GatewayRuntime
  ) async throws -> (GatewayControlReply, SMXEndpoint?) {
    try Task.checkCancellation()
    switch command {
    case .listWorkspaces:
      let records = await runtime.records
      guard records.count <= GatewayControl.maxWorkspaces else {
        throw MuxError(.resourceLimit)
      }
      return (
        .workspaces(
          records.map { record in
            let state: GatewayWorkspaceRecord.State =
              switch record.state {
              case .starting: .starting
              case .discovering: .discovering
              case .empty: .empty
              case .available: .available
              case let .unavailable(error): .unavailable(error)
              }
            return GatewayWorkspaceRecord(
              workspace: record.inventory.authority.workspace,
              state: state,
              summary: record.lastKnownSummary
            )
          }
        ), nil
      )
    case let .route(selector, role):
      let route = try await runtime.nativeRoute(for: selector, role: role)
      return (.route(route.descriptor), route.endpoint)
    case let .create(id, request):
      _ = try await runtime.createWorkspace(id, request: request)
      return (.created(id), nil)
    case let .end(selector):
      try await runtime.endWorkspace(selector)
      return (.ended, nil)
    case .savedWorkspaces:
      return (.savedWorkspaces(try await runtime.savedWorkspaces()), nil)
    case let .reopenSaved(request):
      let (id, outcome) = try await runtime.reopenSaved(request)
      return (.reopened(id, outcome), nil)
    case let .setSavedPolicy(policy, expected):
      return (
        .savedPolicy(
          try await runtime.setSavedPolicy(policy, expectedRevision: expected)
        ), nil
      )
    case let .deleteSaved(id):
      try await runtime.deleteSaved(id)
      return (.deletedSaved, nil)
    case let .previousOutput(id, pane, offset):
      return (
        .previousOutput(
          try await runtime.previousOutput(id, pane: pane, offset: offset)
        ), nil
      )
    case let .discardPreviousOutput(id, pane):
      try await runtime.discardPreviousOutput(id, pane: pane)
      return (.deletedSaved, nil)
    }
  }

  private func complete(
    _ id: UUID,
    result: GatewayControlResult,
    endpoint: SMXEndpoint?
  ) {
    guard let job = jobs.removeValue(forKey: id) else { return }
    retainedBytes -= job.bytes
    guard let peer = peers[id], !closed else { return }
    do {
      guard let deadline = peer.deadline, DispatchTime.now() < deadline else {
        throw MuxError(.connectionLost, "gateway operation deadline exceeded")
      }
      let data = try encode(.result(sequence: peer.sequence, value: result))
      let charge = job.bytes + data.count
      guard charge <= GatewayControl.retainedByteLimit - retainedBytes else {
        throw MuxError(.resourceLimit, "gateway result capacity exhausted")
      }
      retainedBytes += charge
      peer.charge = charge
      peer.result = (data, endpoint)
      deliver((data, endpoint), to: peer)
      arm(id, seconds: 5)
    } catch { refuse(id, (error as? MuxError) ?? MuxError(.resourceLimit)) }
  }

  private func encode(_ event: GatewayControlEvent) throws -> Data {
    try SMXCodec.encode(event, limit: GatewayControl.recordLimit)
  }
  private func deliver(_ result: (Data, SMXEndpoint?), to peer: Peer) {
    if let endpoint = result.1 {
      peer.channel.send(result.0, endpoint: endpoint)
    } else {
      peer.channel.send(result.0)
    }
  }
  private func refuse(_ id: UUID, _ error: MuxError) {
    if let peer = peers[id], let data = try? encode(.refused(error)) {
      peer.channel.send(data)
    }
    remove(id)
  }
  private func remove(_ id: UUID) {
    guard let peer = peers.removeValue(forKey: id) else { return }
    peer.timer?.cancel()
    peer.channel.cancel()
    retainedBytes -= peer.charge
    // In-flight charge remains until completion, including cancelled jobs.
    jobs[id]?.task.cancel()
  }
  private func disarm(_ peer: Peer) {
    peer.timer?.cancel();
    peer.timer = nil;
    peer.deadline = nil
  }
  private func arm(_ id: UUID, seconds: Int) {
    guard let peer = peers[id] else { return }
    disarm(peer)
    let deadline = DispatchTime.now() + .seconds(seconds)
    peer.deadline = deadline
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: deadline)
    timer.setEventHandler { [weak self] in
      guard let self, let current = self.peers[id]?.deadline,
        DispatchTime.now() >= current
      else { return }
      self.refuse(
        id,
        MuxError(.connectionLost, "gateway control deadline exceeded")
      )
    }
    peer.timer = timer
    timer.resume()
  }
}
