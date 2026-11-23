#if os(macOS)
import Dispatch
import Foundation
import ScreenProtocol
import SessionCore
import SwiftMuxClient
import SwiftMuxGateway
import SwiftMuxProtocol
import TerminalHost

/// The roaming host's view of a durable gateway: each roaming workspace is
/// a guardian-supervised worker. Sessions drive their worker directly
/// (`SMXRoamingMux`) with remote trust; workspace-wide requests go to each
/// worker's local control client, which never holds a lease.
package final class GatewayRoamingWorkspaces: RoamingWorkspaces {
  private let runtime: GatewayRuntime
  private let controls = ControlClients()
  package let instance: SwiftMuxProtocol.ServerInstanceID

  /// Grants are bound to the guardian incarnation: a gateway restart keeps
  /// them, a guardian restart (which ends every session) does not.
  package static func make(
    runtime: GatewayRuntime
  ) async throws -> GatewayRoamingWorkspaces {
    guard let incarnation = await runtime.guardianIncarnation else {
      throw MuxError(.connectionLost, "no guardian incarnation")
    }
    return GatewayRoamingWorkspaces(
      runtime: runtime,
      instance: SwiftMuxProtocol.ServerInstanceID(rawValue: incarnation)
    )
  }

  private init(
    runtime: GatewayRuntime,
    instance: SwiftMuxProtocol.ServerInstanceID
  ) {
    self.runtime = runtime
    self.instance = instance
  }

  package var pendingControlRequestCount: Int { 0 }

  package func close() {
    let controls = controls
    Task { await controls.closeAll() }
  }

  // MARK: Workspaces

  package func create(
    _ request: NewWorkspaceRequest
  ) async -> Result<WorkspaceID, MuxError> {
    let id = WorkspaceID()
    do {
      _ = try await runtime.createWorkspace(id, request: request)
      return .success(id)
    } catch { return .failure(Self.muxError(error)) }
  }

  package func control(_ command: MuxCommand) async -> MuxResult {
    switch command {
    case .listWorkspaces: return .success(.workspaces(await runtime.summaries))
    case let .endWorkspace(.id(workspace), _):
      do {
        try await runtime.endWorkspace(.id(workspace))
        return .success(.ok)
      } catch { return .failure(Self.muxError(error)) }
    case let .inbox(query): return await inbox(query)
    case .locateAttention, .markSeen, .snooze, .markReviewed:
      return await firstAnswer(command)
    default:
      return .failure(
        MuxError(.invalidRequest, "not a roaming gateway request")
      )
    }
  }

  package func endIfUnused(
    _ workspace: WorkspaceID,
    onlyIfExited: Bool
  ) async -> Bool {
    let checked = await execute(
      .endWorkspaceIfUnused(workspace, onlyIfExited: onlyIfExited),
      in: workspace
    )
    guard case .success = checked else { return false }
    // The worker ended its workspace; retire the worker process too.
    try? await runtime.endWorkspace(.id(workspace))
    await controls.drop(workspace)
    return true
  }

  // MARK: Attention

  /// Attention lives with each workspace's worker: ask each in turn.
  private func firstAnswer(_ command: MuxCommand) async -> MuxResult {
    var last = MuxResult.failure(MuxError(.notFound, "attention"))
    for summary in await runtime.summaries {
      let result = await execute(command, in: summary.id)
      switch result {
      case .success: return result
      case let .failure(error) where error.code == .notFound: last = result
      case .failure: last = result
      }
    }
    return last
  }

  /// One page across every worker's inbox, newest first. Paging across
  /// workers is not supported: the merged page has no next cursor.
  private func inbox(_ query: InboxQuery) async -> MuxResult {
    var single = query
    single.cursor = nil
    var items: [AttentionItem] = []
    var counts = InboxCounts()
    var revision: UInt64 = 0
    for summary in await runtime.summaries {
      guard
        case let .success(.inbox(page)) = await execute(
          .inbox(single),
          in: summary.id
        )
      else { continue }
      items += page.items
      counts.needsYou += page.counts.needsYou
      counts.results += page.counts.results
      revision = max(revision, page.revision)
    }
    items.sort { $0.updatedAt > $1.updatedAt }
    return .success(
      .inbox(
        InboxPage(
          items: Array(items.prefix(max(query.limit, 1))),
          counts: counts,
          revision: revision,
          nextCursor: nil
        )
      )
    )
  }

  // MARK: Sessions

  package func makeMux(
    workspace: WorkspaceID,
    queue: DispatchQueue
  ) -> any RoamingMux {
    let runtime = runtime
    return SMXRoamingMux(queue: queue) {
      try await runtime.connectWorker(
        for: workspace,
        role: .controller,
        frontend: .native,
        transport: .remote
      )
    }
  }

  package func sessionChanged(
    _ id: String,
    workspace: WorkspaceID,
    state: String
  ) {
    let command = MuxCommand.roamingSessionChanged(
      id: id,
      workspace: workspace,
      state: state
    )
    Task { _ = await self.execute(command, in: workspace) }
  }

  // MARK: Control clients

  private func execute(
    _ command: MuxCommand,
    in workspace: WorkspaceID
  ) async -> MuxResult {
    let runtime = runtime
    do {
      let connection = try await controls.connection(for: workspace) {
        try await runtime.connectWorker(
          for: workspace,
          role: .observer,
          frontend: .control,
          transport: .local
        )
      }
      do { return .success(try await connection.execute(command)) } catch {
        if (error as? MuxError)?.code == .connectionLost {
          await controls.drop(workspace)
        }
        return .failure(Self.muxError(error))
      }
    } catch { return .failure(Self.muxError(error)) }
  }

  private static func muxError(_ error: any Error) -> MuxError {
    (error as? MuxError) ?? MuxError(.connectionLost, "\(error)")
  }
}

/// One lease-free control client per worker, opened on first use.
private actor ControlClients {
  private var clients: [WorkspaceID: MuxConnection] = [:]

  func connection(
    for workspace: WorkspaceID,
    open: @Sendable () async throws -> MuxConnection
  ) async throws -> MuxConnection {
    if let client = clients[workspace] { return client }
    let client = try await open()
    if let raced = clients[workspace] {
      await client.close()
      return raced
    }
    clients[workspace] = client
    return client
  }

  func drop(_ workspace: WorkspaceID) async {
    await clients.removeValue(forKey: workspace)?.close()
  }

  func closeAll() async {
    let all = clients.values
    clients = [:]
    for client in all { await client.close() }
  }
}
#endif
