import SwiftMuxClient
import SwiftMuxGuardian
import SwiftMuxProtocol

/// Explicit creation only. A caller supplies the identity before any side effect
/// so uncertain outcomes can be inspected without replaying the launch.
package actor GatewayWorkspaceCreator {
  private struct Job {
    let bytes: Int
    let task: Task<Created, any Error>
  }

  /// One explicit creation command, transmitted at most once.
  package enum Payload: Sendable {
    case request(NewWorkspaceRequest)
    /// A reopened saved layout (spec.durability.md §12.2.7).
    case template(WorkspaceTemplate)

    var command: MuxCommand {
      switch self {
      case let .request(value): .newWorkspace(value)
      case let .template(value): .newWorkspaceFromTemplate(value)
      }
    }
  }

  package struct Created: Sendable {
    package let authority: GuardianAuthority
    package let outcome: WorkspaceTemplateOutcome?
  }

  private let supervisor: GatewaySupervisor
  private let peerRequirement: String?
  private var jobs: [WorkspaceID: Job] = [:]
  private var bytes = 0
  private var closed = false

  package init(supervisor: GatewaySupervisor, peerRequirement: String?) {
    self.supervisor = supervisor
    self.peerRequirement = peerRequirement
  }

  deinit { for job in jobs.values { job.task.cancel() } }

  package var pendingCount: Int { jobs.count }

  package func create(
    _ id: WorkspaceID,
    request: NewWorkspaceRequest,
    timeout: Duration = .seconds(15)
  ) async throws -> GuardianAuthority {
    try await create(id, payload: .request(request), timeout: timeout).authority
  }

  package func create(
    _ id: WorkspaceID,
    payload: Payload,
    timeout: Duration = .seconds(15)
  ) async throws -> Created {
    try Task.checkCancellation()
    guard !closed else {
      throw MuxError(.connectionLost, "workspace creator closed")
    }
    guard timeout > .zero, timeout <= .seconds(30) else {
      throw MuxError(.invalidRequest, "invalid workspace creation timeout")
    }
    guard jobs[id] == nil else {
      throw MuxError(.quiescing, "workspace creation already pending")
    }
    let charge = try MuxConnection.commandPayloadBytes(payload.command)
    guard jobs.count < 4, charge <= (4 << 20) - bytes else {
      throw MuxError(.resourceLimit, "workspace creation capacity exhausted")
    }
    let supervisor = supervisor
    let requirement = peerRequirement
    let task = Task.detached {
      try await withThrowingTaskGroup(of: Created.self) { group in
        group.addTask {
          try await Self.perform(
            id,
            payload: payload,
            supervisor: supervisor,
            peerRequirement: requirement
          )
        }
        group.addTask {
          try await Task.sleep(for: timeout)
          throw MuxError(
            .connectionLost,
            "workspace \(id) creation timed out; inspect its inventory"
          )
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
          throw CancellationError()
        }
        return result
      }
    }
    bytes += charge
    jobs[id] = Job(bytes: charge, task: task)
    defer {
      if let retired = jobs.removeValue(forKey: id) { bytes -= retired.bytes }
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  package func close() async {
    closed = true
    let current = Array(jobs.values)
    for job in current { job.task.cancel() }
    for job in current { _ = await job.task.result }
    jobs.removeAll()
    bytes = 0
  }

  private static func perform(
    _ id: WorkspaceID,
    payload: Payload,
    supervisor: GatewaySupervisor,
    peerRequirement: String?
  ) async throws -> Created {
    guard
      try await !supervisor.inventory()
        .contains(where: { $0.authority.workspace == id })
    else {
      throw MuxError(
        .invalidRequest,
        "workspace \(id) already exists; inspect it instead of recreating it"
      )
    }
    try Task.checkCancellation()
    let authority = try await supervisor.create(id)
    let client: MuxConnection
    while true {
      try Task.checkCancellation()
      do {
        client = try await supervisor.connectWorker(
          authority,
          peerRequirement: peerRequirement,
          frontend: .control,
          forwardedTransport: .local
        )
        break
      } catch let error as MuxError where error.code == .notAttached {
        let inventory = try await supervisor.inventory()
        guard let item = inventory.first(where: { $0.authority == authority })
        else {
          throw MuxError(
            .staleAttachment,
            "workspace \(id) creation authority disappeared"
          )
        }
        if let error = item.launchError { throw error }
        guard item.starting || item.available else {
          throw MuxError(
            .notAttached,
            "workspace \(id) worker unavailable; processes retained"
          )
        }
        try await Task.sleep(for: .milliseconds(25))
      }
    }
    do {
      // This mutating command is transmitted at most once, including timeout,
      // cancellation and loss of its reply. Closing a client does not End it.
      if case .template = payload,
        await client.welcome?.features.contains(.savedLayoutMetadata) != true
      {
        throw MuxError(
          .incompatibleVersion,
          "worker cannot reopen saved layouts"
        )
      }
      let reply = try await client.execute(payload.command)
      let outcome: WorkspaceTemplateOutcome?
      switch (payload, reply) {
      case let (.request, .created(snapshot)) where snapshot.id == id:
        outcome = nil
      case let (.template, .createdFromTemplate(snapshot, value))
      where snapshot.id == id: outcome = value
      default:
        throw MuxError(
          .invalidRequest,
          "workspace \(id) returned an invalid creation result"
        )
      }
      await client.close()
      return Created(authority: authority, outcome: outcome)
    } catch {
      await client.close()
      throw error
    }
  }
}
