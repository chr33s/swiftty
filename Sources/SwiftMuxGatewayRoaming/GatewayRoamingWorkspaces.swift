#if os(macOS)
import Dispatch
import Foundation
import ScreenProtocol
import SessionCore
import SwiftMuxClient
import SwiftMuxGateway
import SwiftMuxProtocol
import Synchronization
import TerminalHost

/// The roaming host's view of a durable gateway: each roaming workspace is
/// a guardian-supervised worker. Sessions drive their worker directly
/// (`SMXRoamingMux`) with remote trust; workspace-wide requests go to each
/// worker's local control client, which never holds a lease.
package final class GatewayRoamingWorkspaces: RoamingWorkspaces {
  private let runtime: GatewayRuntime
  private let controls = ControlClients()
  /// Session connections per workspace, dropped when its worker is replaced.
  private let sessions = Mutex<[WorkspaceID: [WeakMux]]>([:])
  package let instance: SwiftMuxProtocol.ServerInstanceID
  package let initialFloor: RoamingSession.Floor

  /// Grants are bound to the guardian incarnation: a gateway restart keeps
  /// them, a guardian restart (which ends every session) does not.
  package static func make(
    runtime: GatewayRuntime,
    now: Date = Date()
  ) async throws -> GatewayRoamingWorkspaces {
    guard let incarnation = await runtime.guardianIncarnation else {
      throw MuxError(.connectionLost, "no guardian incarnation")
    }
    let workspaces = GatewayRoamingWorkspaces(
      runtime: runtime,
      instance: SwiftMuxProtocol.ServerInstanceID(rawValue: incarnation),
      initialFloor: Self.floor(at: now)
    )
    await runtime.setMigrationHandler { [weak workspaces] workspace in
      await workspaces?.workerReplaced(workspace)
    }
    return workspaces
  }

  /// Sessions outlive this gateway, but their epoch and revision counters
  /// do not: start each new session above anything a client of an earlier
  /// gateway run could have seen. Counters advance far slower than once
  /// per microsecond, so microseconds since 2001 always lie above them.
  static func floor(at now: Date) -> RoamingSession.Floor {
    let base = UInt64(max(0, now.timeIntervalSinceReferenceDate) * 1_000_000)
    var floor = RoamingSession.Floor()
    floor.epoch = base
    floor.screenRevision = base
    floor.resizeRevision = base
    return floor
  }

  private init(
    runtime: GatewayRuntime,
    instance: SwiftMuxProtocol.ServerInstanceID,
    initialFloor: RoamingSession.Floor
  ) {
    self.runtime = runtime
    self.instance = instance
    self.initialFloor = initialFloor
  }

  package var pendingControlRequestCount: Int { 0 }

  package func close() {
    let controls = controls
    Task { await controls.closeAll() }
  }

  // MARK: Workspaces

  /// Returns once frontends can find the workspace: a session's attach and
  /// the registry's sweep both look it up straight away.
  package func create(
    _ request: NewWorkspaceRequest
  ) async -> Result<WorkspaceID, MuxError> {
    let id = WorkspaceID()
    do {
      _ = try await runtime.createWorkspace(id, request: request)
      try await runtime.waitUntilAvailable(id)
      return .success(id)
    } catch { return .failure(Self.muxError(error)) }
  }

  package func control(_ command: MuxCommand) async -> MuxResult {
    switch command {
    case .listWorkspaces: return .success(.workspaces(await runtime.summaries))
    case let .endWorkspace(.id(workspace), _):
      do {
        try await runtime.endWorkspace(.id(workspace))
        await controls.drop(workspace)
        return .success(.ok)
      } catch { return .failure(Self.muxError(error)) }
    case let .inbox(query): return await inbox(query)
    case let .locateAttention(reference): return await owner(reference, command)
    case let .markSeen(reference): return await owner(reference, command)
    case let .snooze(reference, _): return await owner(reference, command)
    case let .markReviewed(reference): return await owner(reference, command)
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

  /// Attention lives with the worker that recorded it, named by the
  /// reference's service epoch. Every other worker would answer for an
  /// item it does not hold (`missing`, or a no-op acknowledgement).
  private func owner(
    _ reference: AttentionReference,
    _ command: MuxCommand
  ) async -> MuxResult {
    let epoch = reference.source.serviceEpoch
    let workspaces = await runtime.summaries.map(\.id)
    let servers = await withTaskGroup(
      of: (WorkspaceID, SwiftMuxProtocol.ServerInstanceID?).self
    ) { group in
      for workspace in workspaces {
        group.addTask { (workspace, await self.server(of: workspace)) }
      }
      var found: [WorkspaceID: SwiftMuxProtocol.ServerInstanceID] = [:]
      for await (workspace, server) in group { found[workspace] = server }
      return found
    }
    guard let workspace = servers.first(where: { $0.value == epoch })?.key
    else {
      if case .locateAttention = command {
        return .success(.attention(AttentionLocation(availability: .missing)))
      }
      return .failure(MuxError(.notFound, "attention"))
    }
    return await execute(command, in: workspace)
  }

  /// One page across every worker's inbox, newest first, asked of all
  /// workers at once. Paging across workers is not supported: the merged
  /// page has no next cursor.
  private func inbox(_ query: InboxQuery) async -> MuxResult {
    var single = query
    single.cursor = nil
    let request = single
    let workspaces = await runtime.summaries.map(\.id)
    let pages = await withTaskGroup(of: InboxPage?.self) { group in
      for workspace in workspaces {
        group.addTask {
          guard
            case let .success(.inbox(page)) = await self.execute(
              .inbox(request),
              in: workspace
            )
          else { return nil }
          return page
        }
      }
      var pages: [InboxPage] = []
      for await page in group { if let page { pages.append(page) } }
      return pages
    }
    var items: [AttentionItem] = []
    var counts = InboxCounts()
    var revision: UInt64 = 0
    for page in pages {
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
    let mux = SMXRoamingMux(queue: queue) {
      try await runtime.connectWorker(
        for: workspace,
        role: .controller,
        frontend: .native,
        transport: .remote,
        // Roaming clients may draw kitty graphics (spec.graphics.md §16).
        capabilities: ClientCapabilities.supported.union(.images)
      )
    }
    sessions.withLock { all in
      all[workspace, default: []].removeAll { $0.value == nil }
      all[workspace, default: []].append(WeakMux(mux))
    }
    return mux
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

  /// The workspace's processes moved to another worker: clients of the
  /// retired one reconnect (sessions reattach; control clients reopen).
  func workerReplaced(_ workspace: WorkspaceID) async {
    await controls.drop(workspace)
    let replaced = sessions.withLock { $0.removeValue(forKey: workspace) }
    for mux in replaced ?? [] {
      mux.value?.invalidate("workspace moved to another worker")
    }
  }

  // MARK: Control clients

  private func server(
    of workspace: WorkspaceID
  ) async -> SwiftMuxProtocol.ServerInstanceID? {
    guard let connection = try? await control(workspace) else { return nil }
    return await connection.welcome?.server
  }

  private func control(_ workspace: WorkspaceID) async throws -> MuxConnection {
    let runtime = runtime
    return try await controls.connection(for: workspace) {
      try await runtime.connectWorker(
        for: workspace,
        role: .observer,
        frontend: .control,
        transport: .local
      )
    }
  }

  private func execute(
    _ command: MuxCommand,
    in workspace: WorkspaceID
  ) async -> MuxResult {
    do {
      let connection = try await control(workspace)
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

private struct WeakMux: Sendable {
  private let box: Box
  init(_ value: SMXRoamingMux) { box = Box(value) }
  var value: SMXRoamingMux? { box.value }

  private final class Box: @unchecked Sendable {
    weak var value: SMXRoamingMux?
    init(_ value: SMXRoamingMux) { self.value = value }
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
