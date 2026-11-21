import Dispatch
import Foundation
import SwiftMuxGuardian
import SwiftMuxProtocol
import SwiftMuxXPC

/// One guardian connection and admission window per workspace. The broker
/// serializes routing, never terminal parsing. Pane queues may synchronously
/// reserve a command here; this queue only dispatches asynchronously to panes.
final class GuardianWorkspaceTransport: @unchecked Sendable {
  typealias Connect = (DispatchQueue, GuardianWorkerConnection.Handlers) throws
    -> GuardianWorkerConnection
  private final class Route: @unchecked Sendable {
    let process: GuardianPaneProcess
    var handle: GuardianPaneHandle?
    var spawning = false
    init(_ process: GuardianPaneProcess) { self.process = process }
  }
  let workspace: WorkspaceID
  private let queue: DispatchQueue
  private let maxPanes: Int
  private let onReady: @Sendable () -> Void
  private let onClosed: @Sendable (MuxError) -> Void
  private var connection: GuardianWorkerConnection?
  private var routes: [PaneID: Route] = [:]
  private var writer: UUID?
  private var ready = false
  private var failure: MuxError?
  private var replacingWriter = false
  private var publishedEndpoint = false
  private var publication:
    (instance: ServerInstanceID, completion: @Sendable (MuxError?) -> Void)?
  private lazy var commands = GuardianWorkerCommands(queue: queue) {
    [unowned self] command, completion in
    guard let connection else { return false }
    return try connection.submit(command, completion: completion)
  }

  init(
    workspace: WorkspaceID,
    maxPanes: Int,
    connect: Connect,
    gatewayChanged: (
      @Sendable (
        GuardianGatewayBinding, @escaping @Sendable (MuxError?) -> Void
      ) -> Void
    )? = nil,
    ready: @escaping @Sendable () -> Void,
    closed: @escaping @Sendable (MuxError) -> Void
  ) throws {
    self.workspace = workspace
    self.maxPanes = maxPanes
    onReady = ready
    onClosed = closed
    queue = DispatchQueue(label: "swiftmux.guardian.workspace.\(workspace)")
    try queue.sync {
      connection = try connect(
        queue,
        .init(
          ready: { [weak self] _ in
            guard let self, self.failure == nil else { return }
            self.ready = true
            self.onReady()
          },
          endpointPublished: { [weak self] instance in
            guard let self else { return }
            guard let pending = self.publication, pending.instance == instance
            else {
              self.lost(
                MuxError(.invalidRequest, "unexpected endpoint publication")
              )
              return
            }
            self.publication = nil
            self.publishedEndpoint = true
            pending.completion(nil)
          },
          gatewayChanged: gatewayChanged,
          output: { [weak self] pane, sequence, bytes in
            self?
              .deliver(
                .output(pane: pane, sequence: sequence, bytes: bytes),
                to: pane
              )
          },
          inputReleased: { [weak self] pane, bytes in
            self?.deliver(.inputReleased(pane: pane, bytes: bytes), to: pane)
          },
          replyReleased: { [weak self] pane, bytes in
            self?.deliver(.replyReleased(pane: pane, bytes: bytes), to: pane)
          },
          exiting: { [weak self] pane in
            self?.deliver(.exiting(pane: pane), to: pane)
          },
          exited: { [weak self] pane, status, forced in
            self?
              .deliver(
                .exited(pane: pane, status: status, forced: forced),
                to: pane
              )
          },
          progress: { [weak self] completion in self?.progress(completion) },
          closed: { [weak self] in self?.lost($0) }
        )
      )
    }
  }

  /// Publish the worker service once, after its listener is active. Discovery
  /// may expose it only after the guardian acknowledges this registration.
  func publishServiceEndpoint(
    _ endpoint: SMXEndpoint,
    instance: ServerInstanceID,
    completion: @escaping @Sendable (MuxError?) -> Void
  ) {
    queue.async { [self] in
      guard ready, failure == nil, let connection else {
        completion(failure ?? MuxError(.connectionLost, "workspace not ready"))
        return
      }
      guard !publishedEndpoint, publication == nil else {
        completion(
          MuxError(.invalidRequest, "worker endpoint already published")
        )
        return
      }
      publication = (instance, completion)
      do { try connection.publishEndpoint(endpoint, instance: instance) } catch
      {
        lost(
          error as? MuxError
            ?? MuxError(.invalidRequest, "endpoint publication failed")
        )
        return
      }
      queue.asyncAfter(deadline: .now() + 5) { [weak self] in
        guard let self, self.publication?.instance == instance else { return }
        self.lost(MuxError(.connectionLost, "endpoint publication timed out"))
      }
    }
  }

  /// Call outside the broker queue; install callbacks before launching the pane.
  func makePane(
    id: PaneID,
    queue paneQueue: DispatchQueue,
    limits: MuxLimits
  ) throws -> GuardianPaneProcess {
    try queue.sync {
      guard ready, failure == nil else {
        throw failure
          ?? MuxError(.connectionLost, "guardian workspace not ready")
      }
      guard routes[id] == nil, routes.count < maxPanes else {
        throw MuxError(
          .resourceLimit,
          "guardian pane registry full or duplicate"
        )
      }
      let process = GuardianPaneProcess(
        id: id,
        queue: paneQueue,
        limits: limits,
        transport: .init(
          submit: { [weak self] command, completion in
            guard let self else { return false }
            return try self.queue.sync {
              try self.submit(command, pane: id, completion: completion)
            }
          },
          cancelUnsent: { [weak self] handle, paste, ordinary in
            guard let self else { return }
            self.queue.sync {
              guard self.routes[id]?.handle == handle else { return }
              self.commands.cancelUnsentInput(
                pane: handle,
                paste: paste,
                includingOrdinaryInput: ordinary
              )
            }
          },
          acknowledge: { [weak self] handle, through in
            guard let self else { return }
            self.queue.async {
              guard self.failure == nil, self.routes[id]?.handle == handle
              else { return }
              self.connection?.acknowledgeOutput(handle, through: through)
            }
          },
          retire: { [weak self] completion in
            guard let self else {
              completion(MuxError(.connectionLost, "workspace transport gone"))
              return
            }
            self.forget(id) { error in paneQueue.async { completion(error) } }
          },
          writer: { [weak self] in
            guard let self else { return nil }
            return self.queue.sync { self.writer }
          },
          failed: { [weak self] error in
            guard let self else { return }
            self.queue.async { self.lost(error) }
          }
        )
      )
      routes[id] = Route(process)
      return process
    }
  }

  /// The supervisor grants/revokes guardian capabilities first. Close local
  /// writer admission, cancel unsent work, and order pane cleanup before making
  /// the new capability visible. The callback runs on the broker queue.
  func replaceWriter(
    _ capability: UUID?,
    completion: @escaping @Sendable (MuxError?) -> Void
  ) {
    queue.async { [self] in
      guard failure == nil, ready else {
        completion(failure ?? MuxError(.connectionLost, "workspace not ready"));
        return
      }
      guard !replacingWriter else {
        completion(MuxError(.resourceLimit, "writer transition pending"));
        return
      }
      replacingWriter = true
      writer = nil
      let barrier = DispatchGroup()
      for route in routes.values {
        if let handle = route.handle {
          commands.cancelUnsentInput(pane: handle)
        }
        barrier.enter()
        route.process.queue.async {
          route.process.cancelInput()
          barrier.leave()
        }
      }
      barrier.notify(queue: queue) { [self] in
        replacingWriter = false
        if let failure {
          completion(failure);
          return
        }
        writer = capability
        completion(nil)
      }
    }
  }

  /// Successful forget retires both guardian inventory and this route. Failure
  /// leaves the pane addressable; never drop live ownership to reclaim a slot.
  func forget(
    _ pane: PaneID,
    completion: @escaping @Sendable (MuxError?) -> Void
  ) {
    queue.async { [self] in
      guard failure == nil, let route = routes[pane] else {
        completion(failure ?? MuxError(.notFound, "pane"));
        return
      }
      guard let handle = route.handle else {
        guard !route.spawning else {
          completion(MuxError(.resourceLimit, "pane launch pending"));
          return
        }
        routes.removeValue(forKey: pane)
        completion(nil)
        return
      }
      do {
        let accepted = try commands.submit(.forget(pane: handle)) {
          [self] result in
          switch result {
          case .success(.ok):
            routes.removeValue(forKey: pane)
            completion(nil)
          case let .success(.rejected(error)), let .failure(error):
            completion(error)
          default:
            completion(MuxError(.invalidRequest, "invalid forget result"))
          }
        }
        if !accepted {
          completion(
            MuxError(.resourceLimit, "guardian command capacity exhausted")
          )
        }
      } catch {
        completion(
          error as? MuxError
            ?? MuxError(.invalidRequest, "forget encoding failed")
        )
      }
    }
  }

  func close() {
    queue.async { [self] in
      lost(MuxError(.connectionLost, "workspace transport closed"))
    }
  }

  private func submit(
    _ command: GuardianCommand,
    pane: PaneID,
    completion: @escaping GuardianWorkerCommands.Completion
  ) throws -> Bool {
    guard ready, failure == nil, let route = routes[pane] else { return false }
    if case let .spawn(id, _, _, _) = command {
      guard id == pane, route.handle == nil, !route.spawning else {
        throw MuxError(.invalidRequest, "duplicate or mismatched spawn")
      }
    } else {
      guard commandHandle(command) == route.handle, route.handle != nil else {
        throw MuxError(.invalidRequest, "stale pane command")
      }
    }
    if case .spawn = command { route.spawning = true }
    do {
      let accepted = try commands.submit(command) { [route] result in
        if case .spawn = command {
          route.spawning = false
          if case let .success(.spawned(_, process, _)) = result {
            route.handle = GuardianPaneHandle(pane: pane, process: process)
          }
        }
        // Install identity before subsequent output; results and events enter
        // the pane queue in the same order as they arrive on the wire.
        route.process.queue.async { completion(result) }
      }
      if !accepted, case .spawn = command { route.spawning = false }
      return accepted
    } catch {
      if case .spawn = command { route.spawning = false }
      throw error
    }
  }

  private func deliver(_ event: GuardianEvent, to handle: GuardianPaneHandle) {
    guard failure == nil else { return }
    guard let route = routes[handle.pane], route.handle == handle else {
      lost(MuxError(.invalidRequest, "unknown guardian pane event"));
      return
    }
    route.process.queue.async { route.process.receive(event) }
  }

  private func progress(_ completion: @escaping @Sendable () -> Void) {
    let barrier = DispatchGroup()
    for route in routes.values {
      barrier.enter()
      route.process.queue.async { barrier.leave() }
    }
    barrier.notify(queue: queue, execute: completion)
  }

  private func lost(_ error: MuxError) {
    guard failure == nil else { return }
    failure = error
    ready = false
    writer = nil
    let pendingPublication = publication
    publication = nil
    pendingPublication?.completion(error)
    for route in routes.values {
      route.process.queue.async { route.process.unavailable(error) }
    }
    commands.close(error)
    connection?.close()
    onClosed(error)
  }

  private func commandHandle(_ command: GuardianCommand) -> GuardianPaneHandle?
  {
    switch command {
    case .spawn: nil
    case let .input(pane, _, _), let .reply(pane, _),
      let .beginPaste(pane, _, _, _), let .appendPaste(pane, _, _, _),
      let .endPaste(pane, _, _), let .cancelPaste(pane, _, _, _),
      let .cancelInput(pane), let .resize(pane, _, _), let .end(pane),
      let .forget(pane):
      pane
    }
  }
}
