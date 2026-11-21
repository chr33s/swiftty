import Dispatch
import Foundation
import MuxAttention
import SwiftMuxGuardian
import SwiftMuxProtocol
import SwifttyEngine

// Planned replacement, worker side (spec.durability.md §6, §7.2). The old
// worker freezes, then exports one workspace checkpoint at the cut; the
// candidate imports it without effects, adopting the guardian's processes.

/// A workspace and its panes at the cut. Engine state is the explicit
/// binary checkpoint; the rest is structured metadata.
struct WorkspaceMigrationCheckpoint: Codable {
  static let format = 1

  struct TabCheckpoint: Codable {
    var id: TabID
    var name: String
    var layout: LayoutNode
    var activePane: PaneID
    var zoomedPane: PaneID?
  }

  struct PaneCheckpoint: Codable {
    var id: PaneID
    var process: UUID
    var pid: Int32
    var appliedOutput: UInt64
    var columns: Int
    var rows: Int
    var title: String
    var workingDirectory: String?
    var launch: SavedPaneLaunch
    var localDirectory: String?
    var directoryFallback: Bool
    var exitStatus: Int32?
    var historyBytes: Int
    var terminal: Data
    var parser: Data
    var revision: UInt64
    var geometryGeneration: UInt64
    var changeCount: UInt64
    var viewport: UInt64
    var epoch: TerminalEpochID
  }

  var format: Int
  var build: String
  var workspace: WorkspaceID
  var name: String
  var createdAt: Date
  var tabs: [TabCheckpoint]
  var activeTab: TabID
  var remainOnExit: Bool
  var wasAttachedLocally: Bool
  var launch: LaunchSpec
  var layoutRevision: UInt64
  var outputOptOut: Bool
  var panes: [PaneCheckpoint]
  var attention: Data
  var savedLayoutCauses: UInt8
  var savedLayoutEnd: SavedLayoutEnd?
  var theme: MuxTheme?
}

/// The guardian's view of a pane at the cut.
struct MigrationPaneHandle: Sendable {
  var handle: GuardianPaneHandle
  var pid: Int32
  var appliedOutput: UInt64
}

extension MuxService {
  /// Closes admission and waits for every pane queue. Refused while a
  /// launch, template, retirement or export is in flight: the cut must not
  /// cross one.
  nonisolated func freezeForMigration(
    commandsIdle:
      @escaping @Sendable (@escaping @Sendable (Bool) -> Void) -> Void,
    completion: @escaping @Sendable (MuxError?) -> Void
  ) {
    onQueue { service in
      guard service.pendingLaunches == 0, service.templateCreations.isEmpty,
        service.retiringPanes.isEmpty, service.savedOutputExport == nil
      else { return completion(MuxError(.quiescing, "work in flight")) }
      service.migrationFrozen = true
      // Settle before the cut: deliver pending inbox changes and stop the
      // snooze timer, so nothing changes the exported state afterwards.
      if service.attention.inbox.hasPendingUpdate { service.flushInbox() }
      service.snoozeTimer = nil
      let barrier = DispatchGroup()
      for record in service.panes.values {
        barrier.enter()
        record.runtime.queue.async { barrier.leave() }
      }
      // Re-enter through the nonisolated reference, never the isolated one.
      barrier.notify(queue: .global()) { [self] in
        self.onQueue { $0.awaitDrained(commandsIdle, completion) }
      }
    }
  }

  /// Input the worker acknowledged must reach the guardian before the cut:
  /// every pane's operations answered and no command waiting (§7.2 step 3).
  /// The guardian's frozen deadline bounds the wait.
  private func awaitDrained(
    _ commandsIdle:
      @escaping @Sendable (@escaping @Sendable (Bool) -> Void) -> Void,
    _ completion: @escaping @Sendable (MuxError?) -> Void
  ) {
    guard migrationFrozen else { return }  // Aborted meanwhile.
    guard panes.values.allSatisfy({ $0.runtime.inputSettled }) else {
      return retryDrain(commandsIdle, completion)
    }
    commandsIdle { [weak self] idle in
      guard let self else { return }
      self.onQueue { service in
        guard service.migrationFrozen else { return }
        if idle, service.panes.values.allSatisfy({ $0.runtime.inputSettled }) {
          completion(nil)
        } else {
          service.retryDrain(commandsIdle, completion)
        }
      }
    }
  }

  private func retryDrain(
    _ commandsIdle:
      @escaping @Sendable (@escaping @Sendable (Bool) -> Void) -> Void,
    _ completion: @escaping @Sendable (MuxError?) -> Void
  ) {
    queue.asyncAfter(deadline: .now() + .milliseconds(2)) { [weak self] in
      self?.assumeIsolated { $0.awaitDrained(commandsIdle, completion) }
    }
  }

  /// Aborted before release: the old worker carries on.
  nonisolated func thawMigration(completion: @escaping @Sendable () -> Void) {
    onQueue { service in
      service.migrationFrozen = false
      service.attentionChanged()
      completion()
    }
  }

  /// The checkpoint at the cut. Pane handles come from the transport.
  nonisolated func migrationCheckpoint(
    handles: [PaneID: MigrationPaneHandle],
    completion: @escaping @Sendable (Result<Data, MuxError>) -> Void
  ) {
    onQueue { service in
      do {
        completion(.success(try service.encodeMigrationCheckpoint(handles)))
      } catch {
        completion(
          .failure(
            error as? MuxError
              ?? MuxError(.quiescing, "checkpoint refused: \(error)")
          )
        )
      }
    }
  }

  private func encodeMigrationCheckpoint(
    _ handles: [PaneID: MigrationPaneHandle]
  ) throws -> Data {
    guard migrationFrozen, let id = configuration.workerWorkspace,
      let ws = workspaces.first(where: { $0.id == id })
    else { throw MuxError(.quiescing, "no frozen workspace to checkpoint") }
    // Status records applied before the cut are delivered, not exported.
    if attention.inbox.hasPendingUpdate { flushInbox() }
    var panesOut: [WorkspaceMigrationCheckpoint.PaneCheckpoint] = []
    for pane in ws.allPanes {
      guard let record = panes[pane], !record.detachedFromLayout,
        let handle = handles[pane]
      else { throw MuxError(.quiescing, "pane \(pane.short) is not settled") }
      let runtime = try record.runtime.migrationCheckpoint()
      panesOut.append(
        .init(
          id: pane,
          process: handle.handle.process,
          pid: handle.pid,
          appliedOutput: handle.appliedOutput,
          columns: record.columns,
          rows: record.rows,
          title: record.title,
          workingDirectory: record.workingDirectory,
          launch: record.launch,
          localDirectory: record.localDirectory,
          directoryFallback: record.directoryFallback,
          exitStatus: record.exitStatus,
          historyBytes: record.runtime.historyBytes,
          terminal: Data(runtime.terminal),
          parser: Data(runtime.parser),
          revision: runtime.revision,
          geometryGeneration: runtime.geometryGeneration,
          changeCount: runtime.changeCount,
          viewport: runtime.viewport,
          epoch: runtime.epoch
        )
      )
    }
    let checkpoint = WorkspaceMigrationCheckpoint(
      format: WorkspaceMigrationCheckpoint.format,
      build: SMX.build,
      workspace: ws.id,
      name: ws.name,
      createdAt: ws.createdAt,
      tabs: ws.tabs.map {
        .init(
          id: $0.id,
          name: $0.name,
          layout: $0.layout,
          activePane: $0.activePane,
          zoomedPane: $0.zoomedPane
        )
      },
      activeTab: ws.activeTab,
      remainOnExit: ws.remainOnExit,
      wasAttachedLocally: ws.wasAttachedLocally,
      launch: ws.launch,
      layoutRevision: ws.layoutRevision,
      outputOptOut: ws.outputOptOut,
      panes: panesOut,
      attention: try attention.inbox.checkpoint(),
      savedLayoutCauses: savedLayoutCauses.rawValue,
      savedLayoutEnd: savedLayoutEnd,
      theme: theme
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(checkpoint)
  }

  /// Candidate import, before the service listens: every pane adopts the
  /// guardian process it names; nothing spawns, replies or notifies.
  nonisolated func importMigrationCheckpoint(
    _ data: Data,
    adopt:
      @escaping @Sendable (
        PaneID, MigrationPaneHandle, DispatchQueue, MuxLimits
      ) throws -> any PaneProcess,
    completion: @escaping @Sendable (MuxError?) -> Void
  ) {
    onQueue { service in
      do {
        try service.decodeMigrationCheckpoint(data, adopt: adopt)
        completion(nil)
      } catch {
        completion(
          error as? MuxError
            ?? MuxError(.invalidRequest, "checkpoint import failed: \(error)")
        )
      }
    }
  }

  private func decodeMigrationCheckpoint(
    _ data: Data,
    adopt: (PaneID, MigrationPaneHandle, DispatchQueue, MuxLimits) throws ->
      any PaneProcess
  ) throws {
    let checkpoint = try JSONDecoder()
      .decode(WorkspaceMigrationCheckpoint.self, from: data)
    guard checkpoint.format == WorkspaceMigrationCheckpoint.format else {
      throw MuxError(.incompatibleVersion, "unsupported checkpoint format")
    }
    guard configuration.workerWorkspace == checkpoint.workspace,
      !workerWorkspaceClaimed, workspaces.isEmpty, panes.isEmpty,
      checkpoint.panes.count <= limits.maxPanes, !checkpoint.tabs.isEmpty
    else { throw MuxError(.invalidRequest, "candidate cannot import") }
    let layoutPanes = Set(checkpoint.tabs.flatMap(\.layout.panes))
    guard layoutPanes == Set(checkpoint.panes.map(\.id)),
      checkpoint.tabs.contains(where: { $0.id == checkpoint.activeTab })
    else { throw MuxError(.invalidRequest, "checkpoint layout mismatch") }
    for pane in checkpoint.panes {
      let queue = DispatchQueue(
        label: "swiftmux.pane.\(pane.id.short)",
        qos: .userInitiated
      )
      let process = try adopt(
        pane.id,
        MigrationPaneHandle(
          handle: GuardianPaneHandle(pane: pane.id, process: pane.process),
          pid: pane.pid,
          appliedOutput: pane.appliedOutput
        ),
        queue,
        limits
      )
      let runtime = PaneRuntime(
        id: pane.id,
        workspace: checkpoint.workspace,
        columns: pane.columns,
        rows: pane.rows,
        historyBytes: pane.historyBytes,
        innerTerm: configuration.innerTerm,
        limits: limits,
        scrollbackCompression: configuration.scrollbackCompression,
        javaScriptRuntime: automation.runtime
          ?? configuration.javaScriptRuntime,
        observingIO: configuration.observePaneIO,
        processOwner: process,
        processQueue: queue
      )
      try runtime.restoreMigration(
        PaneRuntime.MigrationCheckpoint(
          terminal: Array(pane.terminal),
          parser: Array(pane.parser),
          revision: pane.revision,
          geometryGeneration: pane.geometryGeneration,
          changeCount: pane.changeCount,
          viewport: pane.viewport,
          epoch: pane.epoch
        )
      )
      // The candidate must preserve the checkpoint's meaning: its restored
      // engine re-encodes to the same canonical bytes (§6).
      let verified = try runtime.migrationCheckpoint()
      guard verified.terminal == Array(pane.terminal),
        verified.parser == Array(pane.parser)
      else { throw MuxError(.invalidRequest, "checkpoint is not canonical") }
      if let theme = checkpoint.theme { runtime.setTheme(theme) }
      let id = pane.id
      runtime.onChange = { [weak self] in self?.onQueue { $0.paneChanged(id) } }
      runtime.onEvent = { [weak self] event in
        self?.onQueue { $0.paneEvent(id, event) }
      }
      panes[pane.id] = PaneRecord(
        runtime: runtime,
        workspace: checkpoint.workspace,
        columns: pane.columns,
        rows: pane.rows,
        title: pane.title,
        workingDirectory: pane.workingDirectory,
        launch: pane.launch,
        localDirectory: pane.localDirectory,
        directoryFallback: pane.directoryFallback,
        exitStatus: pane.exitStatus
      )
    }
    var ws = Workspace(
      id: checkpoint.workspace,
      name: checkpoint.name,
      tabs: checkpoint.tabs.map {
        Tab(
          id: $0.id,
          name: $0.name,
          layout: $0.layout,
          activePane: $0.activePane,
          zoomedPane: $0.zoomedPane
        )
      },
      activeTab: checkpoint.activeTab,
      remainOnExit: checkpoint.remainOnExit,
      launch: checkpoint.launch
    )
    ws.createdAt = checkpoint.createdAt
    ws.wasAttachedLocally = checkpoint.wasAttachedLocally
    ws.layoutRevision = checkpoint.layoutRevision
    ws.outputOptOut = checkpoint.outputOptOut
    workspaces = [ws]
    workerWorkspaceClaimed = true
    attention = InboxHub(
      restoring: try AttentionInbox(
        checkpoint: checkpoint.attention,
        limits: limits
      )
    )
    savedLayoutCauses = SavedLayoutCauses(
      rawValue: checkpoint.savedLayoutCauses
    )
    savedLayoutEnd = checkpoint.savedLayoutEnd
    theme = checkpoint.theme
    // Snoozes that expired during the cut expire now, once.
    attentionChanged()
  }
}
