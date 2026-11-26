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

  struct TabCheckpoint: Codable, LayeredTab {
    var id: TabID
    var name: String
    var layout: LayoutNode?
    @OmittedWhenEmpty
    var layers: [FloatingLayer] = []
    var activePane: PaneID
    var zoomedPane: PaneID?
    var previousPane: PaneID?
  }

  /// The controller lease at the cut. Provisional on import: it grants
  /// nothing until the same relay resumes it (§6).
  struct LeaseCheckpoint: Codable {
    var attachment: AttachmentID
    var generation: UInt64
    var holder: LeaseHolder
    var nextInput: UInt64
    var geometryGeneration: UInt64
    var pastes: [UInt64: ActivePaste]
    var readiness: Bool
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
  /// The service instance the candidate continues.
  var server: ServerInstanceID
  var lease: LeaseCheckpoint?
  var leaseGeneration: UInt64
  /// The guardian writer capability the old worker held; the candidate
  /// continues with it, so queued writes are not cancelled (§7.2 step 6).
  var writer: UUID?
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
      service.scheduleAutomationTopology()
      // Settle before the cut: deliver pending inbox changes and stop the
      // snooze timer, so nothing changes the exported state afterwards.
      if service.attention.inbox.hasPendingUpdate { service.flushInbox() }
      service.snoozeTimer = nil
      service.automation.runtime?.setPollingPaused(true)
      let barrier = DispatchGroup()
      for record in service.panes.values {
        // Settle clipboard requests first; the barrier then follows them.
        record.runtime.settleClipboardForMigration()
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
      service.scheduleAutomationTopology()
      service.attentionChanged()
      service.automation.runtime?.setPollingPaused(false)
      let deferred = service.automation.frozen
      service.automation.frozen.removeAll()
      for action in deferred { service.handleAutomation(action) }
      completion()
    }
  }

  /// The checkpoint at the cut. Pane handles come from the transport.
  nonisolated func migrationCheckpoint(
    handles: [PaneID: MigrationPaneHandle],
    writer: UUID?,
    completion: @escaping @Sendable (Result<Data, MuxError>) -> Void
  ) {
    onQueue { service in
      do {
        completion(
          .success(
            try service.encodeMigrationCheckpoint(handles, writer: writer)
          )
        )
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
    _ handles: [PaneID: MigrationPaneHandle],
    writer: UUID?
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
          layers: $0.layers,
          activePane: $0.activePane,
          zoomedPane: $0.zoomedPane,
          previousPane: $0.previousPane
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
      theme: theme,
      server: instance,
      lease: leases[ws.id]
        .map {
          .init(
            attachment: $0.attachment,
            generation: $0.generation,
            holder: $0.holder,
            nextInput: $0.nextInput,
            geometryGeneration: $0.geometryGeneration,
            pastes: $0.pastes,
            readiness: $0.readiness.enabled
          )
        },
      leaseGeneration: leaseGenerations[ws.id] ?? 0,
      writer: writer
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

  /// A checkpoint tab names each pane once, and each layer's focus and
  /// bounds are inside that layer and the tab.
  private static func checkpointTabValid(
    _ tab: WorkspaceMigrationCheckpoint.TabCheckpoint
  ) -> Bool {
    let panes = tab.panes
    guard Set(panes).count == panes.count, !panes.isEmpty,
      panes.contains(tab.activePane),
      tab.zoomedPane.map(panes.contains) ?? true, tab.layout?.isValid() ?? true
    else { return false }
    return tab.layers.allSatisfy {
      $0.bounds.isValid && $0.layout.isValid()
        && $0.layout.contains($0.focusedPane)
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
    let layoutPanes = Set(checkpoint.tabs.flatMap(\.panes))
    guard layoutPanes == Set(checkpoint.panes.map(\.id)),
      checkpoint.tabs.contains(where: { $0.id == checkpoint.activeTab }),
      checkpoint.tabs.allSatisfy(Self.checkpointTabValid)
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
          layers: $0.layers,
          activePane: $0.activePane,
          zoomedPane: $0.zoomedPane,
          previousPane: $0.previousPane
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
    guard checkpoint.server == instance else {
      throw MuxError(.invalidRequest, "candidate instance mismatch")
    }
    leaseGenerations[checkpoint.workspace] = checkpoint.leaseGeneration
    if let carried = checkpoint.lease {
      var lease = Lease(
        client: UUID(),  // No connection holds it until resumed.
        workspace: checkpoint.workspace,
        generation: carried.generation,
        holder: carried.holder
      )
      lease.attachment = carried.attachment
      lease.nextInput = carried.nextInput
      lease.geometryGeneration = carried.geometryGeneration
      lease.pastes = carried.pastes
      lease.readiness.enabled = carried.readiness
      provisionalLease = lease
      // An unresumed lease is fenced like a lost connection.
      queue.asyncAfter(deadline: .now() + Self.provisionalLeaseLifetime) {
        [weak self] in
        self?
          .assumeIsolated {
            $0.fenceProvisionalLease(
              reason: "replacement lease was not resumed"
            )
          }
      }
    }
    // Snoozes that expired during the cut expire now, once.
    attentionChanged()
  }

  static let provisionalLeaseLifetime: DispatchTimeInterval = .seconds(10)

  /// The relay that held the lease continues it on this worker: same
  /// attachment, input watermark and open pastes; fresh frame state, so
  /// full frames follow its subscriptions.
  func resumeAttachment(
    _ attachment: AttachmentID,
    nextInput: UInt64,
    client: Client,
    hello: Hello
  ) -> MuxResult {
    guard hello.frontend != .control, clientLeases[client.id] == nil,
      clientViewers[client.id] == nil, var lease = provisionalLease,
      lease.attachment == attachment, nextInput >= lease.nextInput,
      leases[lease.workspace] == nil,
      let ws = workspaces.first(where: { $0.id == lease.workspace })
    else { return .failure(MuxError(.staleAttachment, "no lease to resume")) }
    provisionalLease = nil
    lease.client = client.id
    lease.nextInput = nextInput
    leases[ws.id] = lease
    leaseOrder.append(ws.id)
    clientLeases[client.id] = ws.id
    publishWorkspaces()
    var snap = snapshot(ws)
    snap.attachmentRole = .controller
    return .success(.attached(attachment: attachment, workspace: snap))
  }

  /// Anyone else attaching, or expiry: the carried lease's pending work is
  /// fenced exactly as a lost connection's would be.
  func fenceProvisionalLease(reason: String) {
    guard let lease = provisionalLease else { return }
    provisionalLease = nil
    guard leases[lease.workspace] == nil else { return }
    leases[lease.workspace] = lease
    leaseOrder.append(lease.workspace)
    releaseLease(lease.workspace, notify: false, fence: true, reason: reason)
  }
}
