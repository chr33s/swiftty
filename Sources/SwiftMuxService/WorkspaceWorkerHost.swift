import CryptoKit
import Dispatch
import Foundation
import SwiftMuxGuardian
import SwiftMuxProtocol

/// The supervised worker's composition root. Gateway death cannot destroy its
/// service, graph or terminal state. Loss of guardian authority fails closed;
/// teardown never substitutes for the guardian's explicit End operation.
/// Sendable: mutable state is touched only on `queue`.
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
  /// Planned replacement (spec.durability.md §7).
  private let candidate: UUID?
  private let onRetired: @Sendable () -> Void
  private var importBytes = Data()
  private var imported = false
  private var retired = false

  package init(
    workspace: WorkspaceID,
    launcherPath: String,
    peerRequirement: String?,
    connect: (DispatchQueue, GuardianWorkerConnection.Handlers) throws ->
      GuardianWorkerConnection,
    ready: @escaping @Sendable (ServerInstanceID) -> Void,
    unavailable: @escaping @Sendable (MuxError) -> Void,
    candidate: UUID? = nil,
    retired: @escaping @Sendable () -> Void = {}
  ) throws {
    self.candidate = candidate
    onRetired = retired
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
        migration: { [weak self] event in
          guard let self else { return }
          self.queue.async { self.migration(event) }
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

  private func makeService() throws -> MuxService {
    guard let broker else {
      throw MuxError(.connectionLost, "worker transport gone")
    }
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
    return try MuxService(configuration: configuration)
  }

  private func startService() {
    guard failure == nil, let broker else { return }
    // A released candidate already imported its workspace.
    if let service, candidate != nil {
      publish(service, broker: broker)
      return
    }
    guard service == nil else { return }
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
      publish(service, broker: broker)
    } catch { fail(error) }
  }

  private func publish(
    _ service: MuxService,
    broker: GuardianWorkspaceTransport
  ) {
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

  // MARK: Planned replacement (spec.durability.md §7.2)

  private func migration(_ event: GuardianWorkerConnection.MigrationEvent) {
    guard failure == nil, let broker else { return }
    switch event {
    case let .freeze(transaction):
      guard let service, ready else {
        broker.migrationRefused(
          transaction,
          MuxError(.quiescing, "worker not ready")
        )
        return
      }
      service.freezeForMigration(commandsIdle: {
        broker.commandsIdle(completion: $0)
      }) { error in
        if let error {
          broker.migrationRefused(transaction, error)
        } else {
          broker.migrationFrozen(transaction)
        }
      }
    case let .export(transaction):
      guard let service else { return }
      broker.migrationHandles { handles in
        service.migrationCheckpoint(handles: handles) { result in
          switch result {
          case let .success(data): broker.migrationExport(transaction, data)
          case let .failure(error): broker.migrationRefused(transaction, error)
          }
        }
      }
    case let .aborted(transaction):
      service?.thawMigration { broker.migrationResumed(transaction) }
    case .retire:
      // The guardian fenced this worker; no process is ended here.
      retired = true
      onRetired()
    case .welcome: break
    case let .importChunk(transaction, offset, total, bytes):
      guard candidate == transaction, !imported, offset == importBytes.count,
        total > 0, total <= GuardianMigrationWire.checkpointLimit,
        offset + bytes.count <= total
      else {
        fail(MuxError(.invalidRequest, "invalid checkpoint import"))
        return
      }
      importBytes.append(bytes)
      guard importBytes.count == total else { return }
      let data = importBytes
      importBytes = Data()
      do {
        let service = try makeService()
        self.service = service
        service.importMigrationCheckpoint(
          data,
          adopt: { id, handle, queue, limits in
            try broker.adoptPane(
              id: id,
              handle: handle.handle,
              pid: handle.pid,
              appliedOutput: handle.appliedOutput,
              queue: queue,
              limits: limits
            )
          }
        ) { [weak self] error in
          guard let self else { return }
          self.queue.async { [self] in
            if let error {
              fail(error)
              return
            }
            imported = true
            broker.migrationImported(
              transaction,
              digest: Data(SHA256.hash(data: data))
            )
          }
        }
      } catch {
        fail(
          error as? MuxError
            ?? MuxError(.invalidRequest, "candidate service failed")
        )
      }
    case let .activate(transaction):
      guard candidate == transaction, imported, service != nil else {
        fail(MuxError(.invalidRequest, "candidate cannot activate"))
        return
      }
      broker.migrationActivated(transaction)
    case .released:
      // `ready` follows and publishes the imported service.
      break
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
