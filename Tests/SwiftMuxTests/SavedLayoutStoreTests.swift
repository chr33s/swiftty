import CryptoKit
import Foundation
@testable import SwiftMuxGateway
import SwiftMuxGuardian
import SwiftMuxProtocol
import Synchronization
import Testing

/// The gateway's saved-layout store (spec.durability.md §12.2, RS1–RS11
/// at the unit level; the end-to-end reopen is in SavedLayoutGatewayTests).
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SavedLayoutStoreTests {
  final class Fixture: @unchecked Sendable {
    let root: URL
    let keys = MemoryKeyStore()
    let incarnation = UUID()
    let retired = Mutex<[WorkspaceID]>([])

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "saved-layout-\(UUID().uuidString)"
      )
      try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
      )
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var files: SavedLayoutFiles { SavedLayoutFiles(root: root) }

    func service(
      hold: Duration = .milliseconds(150),
      interval: Duration = .milliseconds(20),
      savedRecords: Int = 32
    ) async -> SavedLayoutService {
      var timing = SavedLayoutService.Timing()
      timing.exitHold = hold
      timing.writeInterval = interval
      timing.writesPerSecond = 100
      var limits = SavedLayoutService.Limits()
      limits.savedRecords = savedRecords
      let service = SavedLayoutService(
        files: files,
        keys: keys,
        build: "test",
        timing: timing,
        limits: limits
      )
      await service.setRetire { [self] authority in
        self.retired.withLock { $0.append(authority.workspace) }
      }
      await service.start(incarnation: incarnation)
      return service
    }

    func authority(_ id: WorkspaceID) -> GuardianAuthority {
      GuardianAuthority(incarnation: incarnation, workspace: id, generation: 1)
    }

    func inventory(
      _ workspaces: [WorkspaceID: SavedLayoutInventoryState] = [:],
      incarnation: UUID? = nil
    ) -> SavedLayoutInventory {
      SavedLayoutInventory(
        incarnation: incarnation ?? self.incarnation,
        workspaces: workspaces
      )
    }
  }

  /// A two-tab, three-pane workspace.
  static func state(
    _ id: WorkspaceID,
    name: String = "work",
    ratio: Double = 0.4,
    panes count: Int = 3,
    causes: SavedLayoutCauses = .command,
    end: SavedLayoutEnd? = nil
  ) -> SavedLayoutState {
    let panes = (0 ..< count).map { _ in PaneID() }
    let first: LayoutNode =
      count > 1
      ? .split(
        axis: .leftRight,
        ratio: ratio,
        first: .pane(panes[0]),
        second: .pane(panes[1])
      ) : .pane(panes[0])
    var tabs = [
      TabSnapshot(
        id: TabID(),
        name: "edit",
        layout: first,
        activePane: panes[0]
      )
    ]
    if count > 2 {
      tabs.append(
        TabSnapshot(
          id: TabID(),
          name: "logs",
          layout: .pane(panes[2]),
          activePane: panes[2]
        )
      )
    }
    let graph = WorkspaceSnapshot(
      id: id,
      name: name,
      tabs: tabs,
      activeTab: tabs.last!.id,
      panes: panes.map { PaneSummary(id: $0, columns: 80, rows: 24) },
      layoutRevision: 1
    )
    return SavedLayoutState(
      graph: end == nil ? graph : nil,
      panes: panes.enumerated()
        .map { index, pane in
          SavedPaneMetadata(
            pane: pane,
            launch: index == 1 ? .command(["top"]) : .loginShell,
            localDirectory: "/tmp/\(index)"
          )
        },
      outputOptOut: false,
      causes: causes,
      end: end
    )
  }

  private func waitFor(
    _ condition: @Sendable () async -> Bool,
    timeout: Duration = .seconds(3)
  ) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
      guard ContinuousClock.now < deadline else {
        Issue.record("condition not reached")
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  @Test
  func sealedRecordsAreBoundToIdentityGenerationAndKey() throws {
    let key = SymmetricKey(size: .bits256)
    let id = WorkspaceID()
    let section = SavedLayoutSection(kind: .record, bytes: Data("{}".utf8))
    let sealed = try SavedLayoutSeal.seal(
      [section],
      workspace: id,
      generation: 3,
      key: key
    )
    #expect(
      try SavedLayoutSeal.open(sealed, workspace: id, generation: 3, key: key)
        == [section]
    )
    // Renamed to another generation or record, or opened with another key.
    #expect(throws: (any Error).self) {
      try SavedLayoutSeal.open(sealed, workspace: id, generation: 4, key: key)
    }
    #expect(throws: (any Error).self) {
      try SavedLayoutSeal.open(
        sealed,
        workspace: WorkspaceID(),
        generation: 3,
        key: key
      )
    }
    #expect(throws: (any Error).self) {
      try SavedLayoutSeal.open(
        sealed,
        workspace: id,
        generation: 3,
        key: SymmetricKey(size: .bits256)
      )
    }
    var torn = sealed
    torn.removeLast(5)
    #expect(throws: (any Error).self) {
      try SavedLayoutSeal.open(torn, workspace: id, generation: 3, key: key)
    }
    #expect(!String(decoding: sealed, as: UTF8.self).contains("{}"))
  }

  @Test
  func commandChangesAreSavedAndReloadedWithTwoGenerations() async throws {
    let fixture = try Fixture()
    let service = await fixture.service()
    let id = WorkspaceID()
    await service.observe(fixture.authority(id), state: Self.state(id))
    try await waitFor { await service.record(id) != nil }
    for ratio in [0.5, 0.6, 0.7] {
      try await Task.sleep(for: .milliseconds(30))
      await service.observe(
        fixture.authority(id),
        state: Self.state(id, ratio: ratio)
      )
    }
    try await waitFor {
      guard
        case let .split(_, ratio, _, _) = await service.record(id)?.content
          .tabs[0].layout
      else { return false }
      return ratio == 0.7
    }
    #expect(try fixture.files.generations()[id]?.count == 2)
    let content = try #require(await service.record(id)?.content)
    #expect(content.tabs.map(\.name) == ["edit", "logs"])
    #expect(content.activeTab == 1)
    #expect(content.panes[1].launch == .command(["top"]))
    #expect(
      content.panes.map(\.localDirectory) == ["/tmp/0", "/tmp/1", "/tmp/2"]
    )
    // A fresh gateway reads the same record.
    let reloaded = await fixture.service()
    #expect(await reloaded.record(id)?.content == content)
    // A torn newest generation falls back to the previous one.
    let generations = try #require(try fixture.files.generations()[id])
    let newest = fixture.files.workspaces.appendingPathComponent(
      "\(id.description).\(generations.last!).smxs"
    )
    try Data("garbage".utf8).write(to: newest)
    let fallback = await fixture.service()
    let previous = try #require(await fallback.record(id))
    #expect(previous.generation == generations.first)
    #expect(
      try FileManager.default
        .contentsOfDirectory(atPath: fixture.files.quarantine.path).count == 1
    )
  }

  @Test
  func exitChangesWaitOutTheHoldAndShutdownDiscardsThem() async throws {
    let fixture = try Fixture()
    let service = await fixture.service(hold: .milliseconds(300))
    let id = WorkspaceID()
    await service.observe(fixture.authority(id), state: Self.state(id))
    try await waitFor { await service.record(id) != nil }
    try await Task.sleep(for: .milliseconds(40))
    // Shells dying at logout shrink the graph; that change is held.
    await service.observe(
      fixture.authority(id),
      state: Self.state(id, panes: 1, causes: .exit)
    )
    try await Task.sleep(for: .milliseconds(100))
    #expect(await service.record(id)?.content.paneCount == 3)
    await service.shutdown()
    try await Task.sleep(for: .milliseconds(400))
    #expect(await fixture.service().record(id)?.content.paneCount == 3)
  }

  @Test
  func ordinaryExitChangesApplyAfterTheHold() async throws {
    let fixture = try Fixture()
    let service = await fixture.service(hold: .milliseconds(100))
    let id = WorkspaceID()
    await service.observe(fixture.authority(id), state: Self.state(id))
    try await waitFor { await service.record(id) != nil }
    await service.observe(
      fixture.authority(id),
      state: Self.state(id, panes: 1, causes: .exit)
    )
    try await waitFor { await service.record(id)?.content.paneCount == 1 }
    // A guardian loss during a later hold keeps the last written layout.
    await service.observe(
      fixture.authority(id),
      state: Self.state(
        id,
        name: "renamed",
        panes: 2,
        causes: [.command, .exit]
      )
    )
    await service.guardianLost()
    try await Task.sleep(for: .milliseconds(200))
    #expect(await service.record(id)?.content.name == "work")
  }

  @Test
  func dispositionsDeleteKeepOrHoldAndRetireTheEmptyWorker() async throws {
    let fixture = try Fixture()
    let service = await fixture.service(hold: .milliseconds(100))
    let ended = WorkspaceID()
    let retained = WorkspaceID()
    let exited = WorkspaceID()
    let lost = WorkspaceID()
    for id in [ended, retained, exited, lost] {
      await service.observe(fixture.authority(id), state: Self.state(id))
    }
    try await waitFor { await service.recordIDs.count == 4 }
    await service.observe(
      fixture.authority(ended),
      state: Self.state(ended, end: .ended(.ended))
    )
    await service.observe(
      fixture.authority(retained),
      state: Self.state(retained, end: .ended(.retained))
    )
    await service.observe(
      fixture.authority(exited),
      state: Self.state(exited, end: .exited)
    )
    await service.observe(
      fixture.authority(lost),
      state: Self.state(lost, end: .exited)
    )
    await service.workerLost(lost)
    #expect(await service.record(ended) == nil)
    #expect(await service.record(retained)?.disposition == .retained)
    #expect(await service.record(exited) != nil)
    try await waitFor { await service.record(exited) == nil }
    #expect(await service.record(lost) != nil)
    try await waitFor {
      Set(fixture.retired.withLock { $0 }) == [ended, retained, exited]
    }
    let list = await service.list(fixture.inventory(), markOffered: false)
    let listed: Set<WorkspaceID> = Set(list.workspaces.map(\.id))
    let expected: Set<WorkspaceID> = [retained, lost]
    #expect(listed == expected)
  }

  @Test
  func onlyAMissingKeyDeletesRecords() async throws {
    let fixture = try Fixture()
    let id = WorkspaceID()
    let service = await fixture.service()
    await service.observe(fixture.authority(id), state: Self.state(id))
    try await waitFor { await service.record(id) != nil }
    fixture.keys.setUnavailable("locked")
    let locked = await fixture.service()
    #expect(await locked.record(id) == nil)
    #expect(await locked.storeState == .unavailable("locked"))
    await locked.observe(
      fixture.authority(id),
      state: Self.state(id, name: "while locked")
    )
    try await Task.sleep(for: .milliseconds(80))
    #expect(try fixture.files.generations()[id]?.isEmpty == false)
    #expect(await locked.notSavedSince(id) != nil)
    fixture.keys.setUnavailable(nil)
    #expect(await fixture.service().record(id)?.content.name == "work")
    fixture.keys.removeKey()
    let lostKey = await fixture.service()
    #expect(await lostKey.storeState == .keyLost)
    #expect(await lostKey.record(id) == nil)
    #expect(try fixture.files.generations()[id] == nil)
    #expect(fixture.keys.hasKey)
  }

  @Test
  func policyChangesAreRevisionedAndDeleteBeforeAcknowledging() async throws {
    let fixture = try Fixture()
    let service = await fixture.service()
    let id = WorkspaceID()
    await service.observe(fixture.authority(id), state: Self.state(id))
    try await waitFor { await service.record(id) != nil }
    var off = SavedLayoutPolicy.defaults
    off.saveLayout = false
    do {
      _ = try await service.setPolicy(off, expectedRevision: 7)
      Issue.record("stale policy revision accepted")
    } catch let error as MuxError { #expect(error.code == .staleRevision) }
    var invalid = SavedLayoutPolicy.defaults
    invalid.retentionDays = 0
    await #expect(throws: MuxError.self) {
      try await service.setPolicy(invalid, expectedRevision: 0)
    }
    let applied = try await service.setPolicy(off, expectedRevision: 0)
    #expect(applied.revision == 1 && !applied.saveLayout)
    #expect(await service.record(id) == nil)
    #expect(!fixture.keys.hasKey)
    #expect(try fixture.files.readPolicy() == applied)
    // Nothing is written while saving is off.
    await service.observe(
      fixture.authority(id),
      state: Self.state(id, name: "x")
    )
    try await Task.sleep(for: .milliseconds(60))
    #expect(
      !FileManager.default.fileExists(atPath: fixture.files.workspaces.path)
    )
    // An unreadable policy disables writing and deletion until set again.
    try Data("{".utf8).write(to: fixture.files.policy)
    let unreadable = await fixture.service()
    await #expect(throws: MuxError.self) {
      try await unreadable.deleteSaved(nil)
    }
    let restored = try await unreadable.setPolicy(
      .defaults,
      expectedRevision: 0
    )
    #expect(restored.saveLayout && restored.revision >= 1)
  }

  @Test
  func reopenMarksSettlesAndNamesWithoutDuplicates() async throws {
    let fixture = try Fixture()
    let service = await fixture.service()
    let id = WorkspaceID()
    await service.observe(fixture.authority(id), state: Self.state(id))
    try await waitFor { await service.record(id) != nil }
    // After a reboot the guardian has a new incarnation.
    let rebooted = fixture.inventory(
      [WorkspaceID(): .live(name: "work")],
      incarnation: UUID()
    )
    let list = await service.list(rebooted, markOffered: true)
    #expect(list.workspaces.first?.state == .saved)
    #expect(
      list.workspaces.first?.commands == [.init(slot: 1, command: ["top"])]
    )
    #expect(await service.record(id)?.firstOfferedAt != nil)
    let base = LaunchSpec(
      command: nil,
      workingDirectory: "/home",
      environment: ["TERM_PROGRAM": "swiftty"]
    )
    let captured = Mutex<(WorkspaceID, WorkspaceTemplate)?>(nil)
    // Uncertain creation: the mark stays and nothing is retried.
    do {
      _ = try await service.reopen(
        SavedReopenRequest(record: id, launch: base),
        inventory: rebooted
      ) { target, template in
        captured.withLock { $0 = (target, template) }
        throw MuxError(.connectionLost, "creation timed out")
      }
      Issue.record("uncertain creation reported success")
    } catch let error as MuxError { #expect(error.code == .connectionLost) }
    let (target, template) = try #require(captured.withLock { $0 })
    #expect(await service.record(id)?.reopeningAs == target)
    #expect(template.name == "work (2)")
    #expect(
      template.panes.map(\.workingDirectory) == ["/tmp/0", "/tmp/1", "/tmp/2"]
    )
    // The saved command did not run: it was not chosen.
    #expect(template.panes.allSatisfy { $0.command == nil })
    #expect(template.activeTab == 1)
    await #expect(throws: MuxError.self) {
      try await service.reopen(
        SavedReopenRequest(record: id, launch: base),
        inventory: rebooted
      ) { _, _ in
        WorkspaceTemplateOutcome(
          panes: [:],
          failedSlots: [],
          directoryFallbackSlots: []
        )
      }
    }
    // Discovery finds the target live: the reopen happened.
    await service.reconcile(
      fixture.inventory([target: .live(name: "work (2)")], incarnation: UUID())
    ) { _ in }
    #expect(await service.record(id) == nil)
  }

  @Test
  func reopenRunsOnlyChosenCommandsAndClearsDefiniteFailures() async throws {
    let fixture = try Fixture()
    let service = await fixture.service()
    let id = WorkspaceID()
    await service.observe(fixture.authority(id), state: Self.state(id))
    try await waitFor { await service.record(id) != nil }
    let inventory = fixture.inventory(incarnation: UUID())
    let base = LaunchSpec(command: nil, workingDirectory: nil, environment: [:])
    do {
      _ = try await service.reopen(
        SavedReopenRequest(record: id, launch: base, runCommandSlots: [1]),
        inventory: inventory
      ) { _, template in
        #expect(template.panes[1].command == ["top"])
        #expect(template.panes[0].command == nil)
        throw MuxError(.launchFailed, "no pane started")
      }
    } catch let error as MuxError { #expect(error.code == .launchFailed) }
    #expect(await service.record(id)?.reopeningAs == nil)
    let (target, _) = try await service.reopen(
      SavedReopenRequest(record: id, launch: base),
      inventory: inventory
    ) { _, _ in
      WorkspaceTemplateOutcome(
        panes: [:],
        failedSlots: [],
        directoryFallbackSlots: []
      )
    }
    #expect(await service.record(id) == nil)
    #expect(target != id)
  }

  @Test
  func supersededAndEndedRecordsAreRemovedOnReconcile() async throws {
    let fixture = try Fixture()
    let service = await fixture.service()
    let source = WorkspaceID()
    await service.observe(fixture.authority(source), state: Self.state(source))
    try await waitFor { await service.record(source) != nil }
    let other = fixture.inventory(incarnation: UUID())
    let captured = Mutex<WorkspaceID?>(nil)
    _ = try? await service.reopen(
      SavedReopenRequest(
        record: source,
        launch: LaunchSpec(
          command: nil,
          workingDirectory: nil,
          environment: [:]
        )
      ),
      inventory: other
    ) { target, _ in
      captured.withLock { $0 = target }
      throw MuxError(.connectionLost)
    }
    let target = try #require(captured.withLock { $0 })
    // The reopened workspace saved its own record, then a reboot lost both.
    await service.observe(fixture.authority(target), state: Self.state(target))
    try await waitFor { await service.record(target) != nil }
    await service.reconcile(fixture.inventory(incarnation: UUID())) { _ in }
    #expect(await service.record(source) == nil)
    #expect(await service.record(target) != nil)
    // A gateway-issued End marks the record first; reconcile finishes it.
    await service.markEnding(target, disposition: .ended)
    let reloaded = await fixture.service()
    await reloaded.reconcile(fixture.inventory()) { _ in }
    #expect(await reloaded.record(target) == nil)
  }

  @Test
  func evictionUsesStoreSequenceAndRetentionNeedsAnOffer() async throws {
    let fixture = try Fixture()
    let service = await fixture.service(savedRecords: 2)
    var ids: [WorkspaceID] = []
    for _ in 0 ..< 3 {
      let id = WorkspaceID()
      ids.append(id)
      await service.observe(fixture.authority(id), state: Self.state(id))
      try await waitFor { await service.record(id) != nil }
      await service.observe(
        fixture.authority(id),
        state: Self.state(id, end: .ended(.retained))
      )
    }
    // Three Saved records with a bound of two: the oldest write goes.
    #expect(await service.record(ids[0]) == nil)
    #expect(await service.record(ids[1]) != nil)
    #expect(await service.record(ids[2]) != nil)
    var policy = await service.currentPolicy
    policy.retentionDays = 1
    _ = try await service.setPolicy(policy, expectedRevision: policy.revision)
    // Never offered: no expiry, whatever the clock says.
    await service.reconcile(fixture.inventory()) { _ in }
    #expect(await service.recordIDs.count == 2)
  }

  // MARK: C1

  private func enableOutput(_ service: SavedLayoutService) async throws {
    var policy = await service.currentPolicy
    policy.saveOutput = true
    _ = try await service.setPolicy(policy, expectedRevision: policy.revision)
  }

  @Test
  func outputIsExportedSealedAndDroppedWithKeyRotation() async throws {
    let fixture = try Fixture()
    let service = await fixture.service()
    try await enableOutput(service)
    let id = WorkspaceID()
    let state = Self.state(id)
    let encoded = try SavedOutputTests.sample().encoded()
    let calls = Mutex(0)
    await service.observe(fixture.authority(id), state: state)
    await service.setOutputSource(fixture.authority(id)) { _, revision in
      calls.withLock { $0 += 1 }
      // Unchanged after the first export of each pane.
      return revision == nil ? (7, encoded) : (7, nil)
    }
    await service.exportOutputs()
    try await waitFor {
      (await service.list(fixture.inventory(), markOffered: false).workspaces
        .first?
        .hasOutput) == true
    }
    #expect(calls.withLock { $0 } == 3)
    await service.exportOutputs()
    #expect(calls.withLock { $0 } == 6)
    // Output stays sealed: the plaintext never reaches the file.
    let generation = try #require(try fixture.files.generations()[id]?.last)
    let file = try fixture.files.read(id, generation: generation)
    #expect(file.range(of: Data("SMXO".utf8)) == nil)
    #expect(
      (await fixture.service().list(fixture.inventory(), markOffered: false)
        .workspaces.first?
        .hasOutput) == true
    )
    let oldKey = try #require(fixture.keys.currentKey)
    var off = await service.currentPolicy
    off.saveOutput = false
    _ = try await service.setPolicy(off, expectedRevision: off.revision)
    #expect(
      (await service.list(fixture.inventory(), markOffered: false).workspaces
        .first?
        .hasOutput) == false
    )
    #expect(fixture.keys.currentKey != oldKey)
    #expect(try fixture.files.generations()[id]?.count == 1)
    // Only the new key opens what is left.
    let reloaded = await fixture.service()
    #expect(await reloaded.record(id) != nil)
  }

  /// A crash between resealing records and promoting the new key leaves
  /// both keys; the next start reads every record and finishes the
  /// rotation, with the "no output" choice kept.
  @Test
  func anInterruptedKeyRotationFinishesAtTheNextStart() async throws {
    let fixture = try Fixture()
    let service = await fixture.service()
    try await enableOutput(service)
    let id = WorkspaceID()
    let encoded = try SavedOutputTests.sample().encoded()
    await service.observe(fixture.authority(id), state: Self.state(id))
    await service.setOutputSource(fixture.authority(id)) { _, _ in (7, encoded)
    }
    await service.exportOutputs()
    try await waitFor {
      (await service.list(fixture.inventory(), markOffered: false).workspaces
        .first?
        .hasOutput) == true
    }
    let oldKey = try #require(fixture.keys.currentKey)
    fixture.keys.failNextPromotion()
    var off = await service.currentPolicy
    off.saveOutput = false
    await #expect(throws: MuxError.self) {
      _ = try await service.setPolicy(off, expectedRevision: off.revision)
    }
    // Interrupted: both keys exist and the policy already says no output.
    #expect(fixture.keys.currentKey == oldKey)
    #expect(fixture.keys.stagedKey != nil)
    let restarted = await fixture.service()
    #expect(await restarted.record(id) != nil)
    #expect(await restarted.currentPolicy.saveOutput == false)
    #expect(
      (await restarted.list(fixture.inventory(), markOffered: false).workspaces
        .first?
        .hasOutput) == false
    )
    #expect(fixture.keys.stagedKey == nil)
    #expect(fixture.keys.currentKey != oldKey)
    // Only the promoted key is needed from now on.
    #expect(await fixture.service().record(id) != nil)
  }

  @Test
  func atomicFilesReplaceWholeAndLeaveNoTemporaries() throws {
    let fixture = try Fixture()
    let file = fixture.root.appendingPathComponent("state.json")
    try AtomicFile.write(Data("one".utf8), to: file)
    try AtomicFile.write(Data(repeating: 0x61, count: 300_000), to: file)
    #expect(try Data(contentsOf: file).count == 300_000)
    let mode =
      try
      FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
      as? Int
    #expect(mode == 0o600)
    let names = try FileManager.default.contentsOfDirectory(
      atPath: fixture.root.path
    )
    #expect(!names.contains { $0.hasPrefix(".state.json.") })
    #expect(throws: MuxError.self) {
      try AtomicFile.write(
        Data(),
        to: fixture.root.appendingPathComponent("missing/dir/x")
      )
    }
  }

  @Test
  func previousOutputFollowsTheReopenedPanesUntilDiscarded() async throws {
    let fixture = try Fixture()
    let service = await fixture.service()
    try await enableOutput(service)
    let source = WorkspaceID()
    let state = Self.state(source)
    let encoded = try SavedOutputTests.sample().encoded()
    await service.observe(fixture.authority(source), state: state)
    await service.setOutputSource(fixture.authority(source)) { _, _ in
      (1, encoded)
    }
    await service.exportOutputs()
    try await waitFor {
      (await service.list(fixture.inventory(), markOffered: false).workspaces
        .first?
        .hasOutput) == true
    }
    await service.observe(
      fixture.authority(source),
      state: Self.state(source, end: .ended(.retained))
    )
    // The reopened workspace's panes, by template slot.
    let panes = (0 ..< 3).map { _ in PaneID() }
    let (target, _) = try await service.reopen(
      SavedReopenRequest(
        record: source,
        launch: LaunchSpec(
          command: nil,
          workingDirectory: nil,
          environment: [:]
        )
      ),
      inventory: fixture.inventory(incarnation: UUID())
    ) { _, _ in
      WorkspaceTemplateOutcome(
        panes: [0: panes[0], 1: panes[1], 2: panes[2]],
        failedSlots: [],
        directoryFallbackSlots: []
      )
    }
    var reopened = Self.state(target)
    reopened.graph?.tabs[0].layout = .split(
      axis: .leftRight,
      ratio: 0.4,
      first: .pane(panes[0]),
      second: .pane(panes[1])
    )
    reopened.graph?.tabs[0].activePane = panes[0]
    reopened.graph?.tabs[1].layout = .pane(panes[2])
    reopened.graph?.tabs[1].activePane = panes[2]
    await service.observe(fixture.authority(target), state: reopened)
    let page = try await service.previousOutput(
      target,
      pane: panes[1],
      offset: 0
    )
    #expect(try SavedOutput(decoding: page.bytes) == SavedOutputTests.sample())
    // A pane that ends drops its previous output; discard drops the rest.
    var shrunk = Self.state(target, panes: 1)
    shrunk.graph?.tabs[0].layout = .pane(panes[0])
    shrunk.graph?.tabs[0].activePane = panes[0]
    shrunk.graph?.panes = [PaneSummary(id: panes[0], columns: 80, rows: 24)]
    shrunk.panes = [
      SavedPaneMetadata(
        pane: panes[0],
        launch: .loginShell,
        localDirectory: nil
      )
    ]
    await service.observe(fixture.authority(target), state: shrunk)
    await #expect(throws: MuxError.self) {
      try await service.previousOutput(target, pane: panes[1], offset: 0)
    }
    _ = try await service.previousOutput(target, pane: panes[0], offset: 0)
    await service.discardPreviousOutput(target, pane: nil)
    await #expect(throws: MuxError.self) {
      try await service.previousOutput(target, pane: panes[0], offset: 0)
    }
  }

  @Test
  func optedOutWorkspacesAreNeverExported() async throws {
    let fixture = try Fixture()
    let service = await fixture.service()
    try await enableOutput(service)
    let id = WorkspaceID()
    var state = Self.state(id)
    state.outputOptOut = true
    let calls = Mutex(0)
    await service.observe(fixture.authority(id), state: state)
    await service.setOutputSource(fixture.authority(id)) { _, _ in
      calls.withLock { $0 += 1 }
      return (1, Data())
    }
    await service.exportOutputs()
    #expect(calls.withLock { $0 } == 0)
  }
}
