import Dispatch
import Foundation
import SwiftMuxGuardian
import SwiftMuxProtocol

/// The supervised worker's composition root. Gateway death cannot destroy its
/// service, graph or terminal state. Loss of guardian authority fails closed;
/// teardown never substitutes for the guardian's explicit End operation.
package final class WorkspaceWorkerHost: @unchecked Sendable {
  private struct Binding: Equatable {
    let identity: UUID
    let pid: Int32
    let writer: UUID?
  }
  private let queue = DispatchQueue(label: "swiftmux.worker.host")
  private let workspace: WorkspaceID
  private let launcherPath: String
  private let peerRequirement: String?
  private let onReady: @Sendable (ServerInstanceID) -> Void
  private let onUnavailable: @Sendable (MuxError) -> Void
  private var broker: GuardianWorkspaceTransport?
  private var service: MuxService?
  private var ready = false
  private var failure: MuxError?
  private var binding: Binding?
  private var transition: (@Sendable (MuxError?) -> Void)?

  package init(
    workspace: WorkspaceID,
    launcherPath: String,
    peerRequirement: String?,
    connect: (DispatchQueue, GuardianWorkerConnection.Handlers) throws ->
      GuardianWorkerConnection,
    ready: @escaping @Sendable (ServerInstanceID) -> Void,
    unavailable: @escaping @Sendable (MuxError) -> Void
  ) throws {
    self.workspace = workspace
    self.launcherPath = launcherPath
    self.peerRequirement = peerRequirement
    onReady = ready
    onUnavailable = unavailable
    try queue.sync {
      broker = try GuardianWorkspaceTransport(
        workspace: workspace,
        maxPanes: MuxLimits.standard.maxPanes,
        connect: connect,
        gatewayChanged: { [weak self] binding, completion in
          guard let self else {
            completion(MuxError(.connectionLost, "worker host gone"));
            return
          }
          if let identity = binding.gateway, let pid = binding.pid, pid > 0 {
            self.bindGateway(
              identity: identity,
              pid: pid,
              writer: binding.writer,
              completion: completion
            )
          } else if binding.gateway == nil && binding.pid == nil
            && binding.writer == nil
          {
            self.revokeGateway(completion: completion)
          } else {
            completion(MuxError(.unauthorized, "invalid gateway binding"))
          }
        },
        ready: { [weak self] in
          guard let self else { return }
          self.queue.async { self.startService() }
        },
        closed: { [weak self] error in
          guard let self else { return }
          self.queue.async { self.fail(error) }
        }
      )
    }
  }

  /// Applied only from the authenticated guardian binding stream.
  private func bindGateway(
    identity: UUID,
    pid: Int32,
    writer: UUID?,
    completion: @escaping @Sendable (MuxError?) -> Void
  ) {
    guard pid > 0 else {
      completion(MuxError(.unauthorized, "invalid gateway PID"));
      return
    }
    replaceBinding(
      Binding(identity: identity, pid: pid, writer: writer),
      completion: completion
    )
  }

  private func revokeGateway(
    completion: @escaping @Sendable (MuxError?) -> Void
  ) { replaceBinding(nil, completion: completion) }

  package func close() {
    queue.async { [self] in
      fail(MuxError(.connectionLost, "worker host closed"))
    }
  }

  private func startService() {
    guard failure == nil, service == nil, let broker else { return }
    do {
      var configuration = MuxServiceConfiguration(launcherPath: launcherPath)
      configuration.workerWorkspace = workspace
      configuration.requiresGatewayBinding = true
      configuration.peerRequirement = peerRequirement
      let workspaceID = workspace
      configuration.paneProcessFactory = { id, workspace, queue, limits in
        guard workspace == workspaceID else {
          throw MuxError(.unauthorized, "worker workspace mismatch")
        }
        return try broker.makePane(id: id, queue: queue, limits: limits)
      }
      let service = try MuxService(configuration: configuration)
      self.service = service
      let endpoint = service.listenAnonymously()
      broker.publishServiceEndpoint(endpoint, instance: service.instance) {
        [weak self] error in
        guard let self else { return }
        self.queue.async { [self] in
          guard self.failure == nil else { return }
          if let error {
            self.fail(error);
            return
          }
          self.ready = true
          self.onReady(service.instance)
        }
      }
    } catch { fail(error) }
  }

  private func replaceBinding(
    _ next: Binding?,
    completion: @escaping @Sendable (MuxError?) -> Void
  ) {
    queue.async { [self] in
      guard failure == nil, ready, let service, let broker else {
        completion(failure ?? MuxError(.connectionLost, "worker not ready"));
        return
      }
      guard transition == nil else {
        completion(MuxError(.resourceLimit, "gateway binding pending"));
        return
      }
      guard binding != next else {
        completion(nil);
        return
      }
      transition = completion
      if let binding, let next, binding.identity == next.identity,
        binding.pid == next.pid
      {
        broker.replaceWriter(next.writer) { [self] error in
          queue.async { [self] in
            guard failure == nil, transition != nil else { return }
            if let error {
              fail(error);
              return
            }
            completeBinding(next)
          }
        }
        return
      }
      binding = nil
      service.setGatewayPeer(nil) { [self] in
        queue.async { [self] in
          guard failure == nil, transition != nil else { return }
          broker.replaceWriter(next?.writer) { [self] error in
            queue.async { [self] in
              guard failure == nil, transition != nil else { return }
              if let error {
                fail(error);
                return
              }
              service.setGatewayPeer(next?.pid) { [self] in
                queue.async { [self] in
                  guard failure == nil, transition != nil else { return }
                  completeBinding(next)
                }
              }
            }
          }
        }
      }
    }
  }

  private func completeBinding(_ next: Binding?) {
    binding = next
    let completed = transition
    transition = nil
    completed?(nil)
  }

  private func fail(_ error: MuxError) {
    guard failure == nil else { return }
    failure = error
    ready = false
    binding = nil
    let pending = transition
    transition = nil
    service?.setGatewayPeer(nil) {}
    broker?.close()
    pending?(error)
    onUnavailable(error)
  }
}
