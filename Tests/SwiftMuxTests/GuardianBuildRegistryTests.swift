import Darwin
import Dispatch
import Foundation
import SwiftMuxGateway
import SwiftMuxGuardian
import SwiftMuxProtocol
import SwiftMuxXPC
import Synchronization
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct GuardianBuildRegistryTests {
  @Test
  func selectionWireReconcilesPublicationAfterGatewayLoss() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let registry = try fixture.registry()
    try registry.select("one")
    let io = DispatchQueue(label: "wire-selection-storage")
    let release = DispatchSemaphore(value: 0)
    io.async { release.wait() }
    let guardian = try GuardianServer(
      launcherPath: launcherPath(),
      peerRequirement: nil,
      buildSelectionQueue: io
    )
    let control = GuardianGatewayServer(
      guardian: guardian,
      peerRequirement: nil,
      buildRegistry: registry,
      workerMachService: "qualification.unused"
    )
    let endpoint = control.listenAnonymously()
    defer {
      release.signal()
      control.close()
      stop(guardian)
    }
    let first = try await GatewaySupervisor.connect(
      peerRequirement: nil,
      channel: { .connect(endpoint: endpoint, queue: $0) }
    )
    let original = try await first.workerSelection()
    #expect(original.selected == "one" && original.rollback == nil)
    let paused = try await first.setAdmissionPaused(true, expectedRevision: 0)
    let selection = Task {
      try await first.selectWorkerBuild(
        "two",
        expectedRevision: paused.revision
      )
    }
    let identity = try #require(await first.identity?.gateway)
    let deadline = ContinuousClock.now + .seconds(5)
    while try guardian.admissionStatus(gateway: identity).selectionPending
      != true && ContinuousClock.now < deadline
    { try await Task.sleep(for: .milliseconds(10)) }
    #expect(
      try guardian.admissionStatus(gateway: identity).selectionPending == true
    )
    let second = try await GatewaySupervisor.connect(
      peerRequirement: nil,
      channel: { .connect(endpoint: endpoint, queue: $0) }
    )
    await #expect(throws: MuxError.self) { try await selection.value }
    #expect(try await second.admissionStatus().selectionPending == true)
    do {
      _ = try await second.setAdmissionPaused(false, expectedRevision: 2)
      Issue.record("resumed pending selection over wire")
    } catch let error as MuxError { #expect(error.code == .quiescing) }
    release.signal()
    let settledDeadline = ContinuousClock.now + .seconds(5)
    while try await second.admissionStatus().selectionPending == true
      && ContinuousClock.now < settledDeadline
    { try await Task.sleep(for: .milliseconds(10)) }
    let committed = try await second.workerSelection()
    #expect(committed.selected == "two" && committed.rollback == "one")
    let cleared = try await second.clearWorkerRollback(expectedRevision: 2)
    #expect(cleared.paused && cleared.revision == 3)
    #expect(try await second.workerSelection().rollback == nil)
    _ = try await second.setAdmissionPaused(false, expectedRevision: 3)
    await first.close()
    await second.close()
  }

  @Test
  func pendingPublicationSurvivesGatewayLossAndBlocksResume() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let registry = try fixture.registry()
    try registry.select("one")
    let io = DispatchQueue(label: "blocked-build-selection")
    let release = DispatchSemaphore(value: 0)
    io.async { release.wait() }
    let guardian = try GuardianServer(
      launcherPath: launcherPath(),
      peerRequirement: nil,
      buildSelectionQueue: io
    )
    defer {
      release.signal()
      stop(guardian)
    }
    registry.claimSelection(for: guardian.incarnation)
    let gateway = UUID()
    guardian.replaceGateway(gateway)
    _ = try guardian.setAdmissionPaused(
      true,
      expectedRevision: 0,
      gateway: gateway
    )
    let completed = Mutex<Result<GuardianAdmissionStatus, MuxError>?>(nil)
    guardian.selectWorkerBuild(
      "two",
      registry: registry,
      expectedRevision: 1,
      gateway: gateway
    ) { result in completed.withLock { $0 = result } }
    // The read synchronizes behind reservation, while storage remains blocked.
    let pending = try guardian.admissionStatus(gateway: gateway)
    #expect(
      pending.paused && pending.selectionPending == true
        && pending.revision == 2
    )
    let replacement = UUID()
    guardian.replaceGateway(replacement)
    #expect(try guardian.admissionStatus(gateway: replacement) == pending)
    do {
      _ = try guardian.setAdmissionPaused(
        false,
        expectedRevision: 2,
        gateway: replacement
      )
      Issue.record("resumed during publication")
    } catch let error as MuxError { #expect(error.code == .quiescing) }
    #expect(try registry.pinSelected().build == "one")
    #expect(completed.withLock { $0 == nil })
    release.signal()
    let deadline = ContinuousClock.now + .seconds(5)
    while completed.withLock({ $0 == nil }) && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let outcome = try #require(completed.withLock { $0 }).get()
    #expect(
      outcome.paused && outcome.selectionPending == false
        && outcome.revision == 2
    )
    #expect(try registry.pinSelected().build == "two")
    _ = try guardian.setAdmissionPaused(
      false,
      expectedRevision: 2,
      gateway: replacement
    )
  }

  @Test
  func liveSelectionRequiresSettledBarrierAndInvalidatesOldResume() async throws
  {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let registry = try fixture.registry()
    try registry.select("one")
    let guardian = try GuardianServer(
      launcherPath: launcherPath(),
      peerRequirement: nil
    )
    defer { stop(guardian) }
    registry.claimSelection(for: guardian.incarnation)
    let gateway = UUID()
    guardian.replaceGateway(gateway)
    func select(
      _ build: String,
      revision: UInt64,
      gateway: UUID
    ) async throws -> GuardianAdmissionStatus {
      try await withCheckedThrowingContinuation { continuation in
        guardian.selectWorkerBuild(
          build,
          registry: registry,
          expectedRevision: revision,
          gateway: gateway
        ) { continuation.resume(with: $0) }
      }
    }
    do {
      _ = try await select("two", revision: 0, gateway: gateway)
      Issue.record("selection without pause succeeded")
    } catch let error as MuxError { #expect(error.code == .quiescing) }
    _ = try guardian.setAdmissionPaused(
      true,
      expectedRevision: 0,
      gateway: gateway
    )
    do {
      try registry.select("two")
      Issue.record("installer bypassed live guardian")
    } catch let error as MuxError { #expect(error.code == .unauthorized) }
    let committed = try await select("two", revision: 1, gateway: gateway)
    #expect(
      committed.paused && committed.revision == 2
        && committed.selectionPending == false
    )
    #expect(try registry.pinSelected().build == "two")
    #expect(throws: MuxError.self) { try registry.remove("one") }
    do {
      _ = try guardian.setAdmissionPaused(
        false,
        expectedRevision: 1,
        gateway: gateway
      )
      Issue.record("old resume crossed selection")
    } catch let error as MuxError { #expect(error.code == .staleRevision) }
    do {
      _ = try await select("one", revision: 1, gateway: gateway)
      Issue.record("stale selection succeeded")
    } catch let error as MuxError { #expect(error.code == .staleRevision) }
    do {
      _ = try await select("missing", revision: 2, gateway: gateway)
      Issue.record("invalid build selected")
    } catch is MuxError {}
    let failed = try guardian.admissionStatus(gateway: gateway)
    #expect(
      failed.paused && failed.revision == 3 && failed.selectionPending == false
    )
    #expect(try registry.pinSelected().build == "two")
    // Only a replacing barrier survives gateway replacement (§5.2).
    let replacing = try guardian.advanceAdmissionPhase(
      expectedRevision: 3,
      gateway: gateway
    )
    #expect(replacing.revision == 4 && replacing.phase == .replacing)
    let replacement = UUID()
    guardian.replaceGateway(replacement)
    #expect(try guardian.admissionStatus(gateway: replacement) == replacing)
    do {
      _ = try await select("one", revision: 3, gateway: gateway)
      Issue.record("old gateway selected a build")
    } catch let error as MuxError { #expect(error.code == .staleAttachment) }
    let rolledBack = try await select("one", revision: 4, gateway: replacement)
    #expect(rolledBack.revision == 5 && rolledBack.paused)
    _ = try guardian.setAdmissionPaused(
      false,
      expectedRevision: 5,
      gateway: replacement
    )
    let starting = WorkspaceID()
    _ = try guardian.provisionWorker(workspace: starting, pid: getpid())
    _ = try guardian.setAdmissionPaused(
      true,
      expectedRevision: 6,
      gateway: replacement
    )
    do {
      _ = try await select("two", revision: 7, gateway: replacement)
      Issue.record("selection crossed starting worker")
    } catch let error as MuxError { #expect(error.code == .quiescing) }
    #expect(try guardian.admissionStatus(gateway: replacement).revision == 7)
    #expect(try registry.pinSelected().build == "one")
  }

  @Test
  func installationPublishesOnceAndSelectionSurvivesRegistryRestart() throws {
    let source = try Fixture()
    let destination = try Fixture()
    defer {
      source.remove();
      destination.remove()
    }
    for build in ["one", "two"] {
      try FileManager.default.removeItem(
        at: destination.root.appendingPathComponent(build)
      )
    }
    do {
      let registry = try destination.registry()
      let bundle = source.root.appendingPathComponent("one/Worker.app")
      try registry.install(bundle: bundle, build: "one")
      try registry.select("one")
      let pin = try registry.pinSelected()
      let original = try Data(contentsOf: URL(fileURLWithPath: pin.workerPath))
      try Data("#!/bin/sh\nexit 42\n".utf8)
        .write(
          to: bundle.appendingPathComponent("Contents/MacOS/swiftmux-worker")
        )
      #expect(throws: MuxError.self) {
        try registry.install(bundle: bundle, build: "one")
      }
      #expect(
        try Data(contentsOf: URL(fileURLWithPath: pin.workerPath)) == original
      )
      #expect(try registry.pinSelected().build == "one")
      try registry.install(
        bundle: source.root.appendingPathComponent("two/Worker.app"),
        build: "two"
      )
      try registry.select("two")
      #expect(throws: MuxError.self) { try registry.remove("one") }
      #expect(
        try FileManager.default
          .contentsOfDirectory(atPath: destination.root.path)
          .allSatisfy {
            !$0.hasPrefix(".install-") && !$0.hasPrefix(".selection-")
          }
      )
    }
    do {
      let restarted = try destination.registry()
      #expect(try restarted.pinSelected().build == "two")
      #expect(throws: MuxError.self) { try restarted.remove("one") }
      try restarted.selectRollback()
      #expect(try restarted.pinSelected().build == "one")
    }
    let restartedAgain = try destination.registry()
    #expect(try restartedAgain.pinSelected().build == "one")
    #expect(throws: MuxError.self) { try restartedAgain.remove("two") }
    try restartedAgain.clearRollback()
    try restartedAgain.remove("two")
  }

  @Test
  func failedInstallationAndSelectionLeaveTheCurrentBuildUsable() throws {
    let source = try Fixture()
    let destination = try Fixture()
    defer {
      source.remove();
      destination.remove()
    }
    let registry = try destination.registry()
    try registry.select("one")
    let bundle = source.root.appendingPathComponent("two/Worker.app")
    try FileManager.default.removeItem(
      at: bundle.appendingPathComponent("Contents/MacOS/swsh")
    )
    #expect(throws: MuxError.self) {
      try registry.install(bundle: bundle, build: "three")
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: destination.root.appendingPathComponent("three").path
      )
    )
    #expect(throws: MuxError.self) { try registry.select("three") }
    #expect(try registry.pinSelected().build == "one")
    // A publication obstruction must not update the in-memory selection.
    let metadata = destination.root.appendingPathComponent(".selection.json")
    try FileManager.default.removeItem(at: metadata)
    try FileManager.default.createDirectory(
      at: metadata,
      withIntermediateDirectories: false
    )
    #expect(throws: MuxError.self) { try registry.select("two") }
    #expect(try registry.pinSelected().build == "one")
  }

  @Test(arguments: [
    "symlink", "hardlink", "permissions", "corrupt", "schema", "missingBuild",
  ])
  func invalidSelectionCannotRestoreAuthority(kind: String) throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    do { try fixture.registry().select("one") }
    let metadata = fixture.root.appendingPathComponent(".selection.json")
    switch kind {
    case "symlink":
      let moved = fixture.root.appendingPathComponent("metadata-copy")
      try FileManager.default.moveItem(at: metadata, to: moved)
      try FileManager.default.createSymbolicLink(
        at: metadata,
        withDestinationURL: moved
      )
    case "hardlink":
      #expect(
        link(
          metadata.path,
          fixture.root.appendingPathComponent("metadata-copy").path
        ) == 0
      )
    case "permissions": #expect(chmod(metadata.path, 0o644) == 0)
    case "corrupt": try Data("{".utf8).write(to: metadata)
    case "schema":
      try Data(#"{"schema":999,"selected":"one"}"#.utf8).write(to: metadata)
    default:
      try FileManager.default.removeItem(
        at: fixture.root.appendingPathComponent("one")
      )
    }
    #expect(throws: (any Error).self) { try fixture.registry() }
  }

  @Test
  func gatewayCreationUsesSelectedBuildAndRetryDiscoversTheSameWorker() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let registry = try fixture.registry()
    try registry.select("one")
    let server = try GuardianServer(
      launcherPath: launcherPath(),
      peerRequirement: nil
    )
    let control = GuardianGatewayServer(
      guardian: server,
      peerRequirement: nil,
      buildRegistry: registry,
      workerMachService: "qualification.unused"
    )
    let endpoint = control.listenAnonymously()
    defer {
      control.close();
      stop(server)
    }
    let workspace = WorkspaceID()
    let authority = try createThroughGateway(endpoint, workspace: workspace)
    #expect(authority.workspace == workspace)
    try awaitSettlement(server)
    let first = try #require(server.inventory().first?.worker)
    #expect(first.build == "one")
    let updater = UUID()
    server.replaceGateway(updater)
    _ = try server.setAdmissionPaused(
      true,
      expectedRevision: 0,
      gateway: updater
    )
    let selected = DispatchSemaphore(value: 0)
    let selection = Mutex<Result<GuardianAdmissionStatus, MuxError>?>(nil)
    server.selectWorkerBuild(
      "two",
      registry: registry,
      expectedRevision: 1,
      gateway: updater
    ) { result in
      selection.withLock { $0 = result }
      selected.signal()
    }
    #expect(selected.wait(timeout: .now() + 5) == .success)
    let status = try #require(selection.withLock { $0 }).get()
    _ = try server.setAdmissionPaused(
      false,
      expectedRevision: status.revision,
      gateway: updater
    )
    let repeated = try createThroughGateway(endpoint, workspace: workspace)
    #expect(repeated == authority)
    #expect(server.inventory().count == 1)
    #expect(server.inventory().first?.worker?.pid == first.pid)
    #expect(throws: MuxError.self) { try registry.remove("one") }
    server.endWorkspace(workspace)
    try server.forgetWorkspace(workspace)
    #expect(throws: MuxError.self) { try registry.clearRollback() }
    #expect(throws: MuxError.self) { try registry.remove("one") }
    let next = WorkspaceID()
    _ = try createThroughGateway(endpoint, workspace: next)
    try awaitSettlement(server)
    #expect(server.inventory().first?.worker?.build == "two")
  }

  @Test
  func creationFailureRemainsDiscoverableAndPendingEndPreventsActivation()
    throws
  {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let registry = try fixture.registry()
    var limits = MuxLimits.standard
    limits.maxPanes = 1
    let server = try GuardianServer(
      launcherPath: launcherPath(),
      limits: limits,
      peerRequirement: nil
    )
    defer { stop(server) }
    let gateway = UUID()
    server.replaceGateway(gateway)
    let workspace = WorkspaceID()
    let authority = try server.createWorker(
      workspace: workspace,
      registry: registry,
      machService: "qualification.unused",
      gateway: gateway
    )
    try awaitSettlement(server)
    #expect(server.inventory().first?.launchError?.code == .notFound)
    #expect(server.inventory().first?.worker == nil)
    #expect(server.inventory().first?.workerProtocol == nil)
    let paused = try server.setAdmissionPaused(
      true,
      expectedRevision: 0,
      gateway: gateway
    )
    #expect(paused.pendingWorkers == 0)
    try registry.select("one")
    #expect(
      try server.createWorker(
        workspace: workspace,
        registry: registry,
        machService: "qualification.unused",
        gateway: gateway
      ) == authority
    )
    #expect(server.inventory().first?.launchError?.code == .notFound)
    #expect(throws: MuxError.self) {
      try server.createWorker(
        workspace: WorkspaceID(),
        registry: registry,
        machService: "qualification.unused",
        gateway: gateway
      )
    }
    try server.endWorkspace(authority: authority, gateway: gateway)
    try server.forgetWorkspace(workspace)
    do {
      _ = try server.createWorker(
        workspace: WorkspaceID(),
        registry: registry,
        machService: "qualification.unused",
        gateway: gateway
      )
      Issue.record("paused creation succeeded")
    } catch let error as MuxError { #expect(error.code == .quiescing) }
    #expect(server.inventory().isEmpty)
    _ = try server.setAdmissionPaused(
      false,
      expectedRevision: paused.revision,
      gateway: gateway
    )
    let next = WorkspaceID()
    let nextAuthority = try server.createWorker(
      workspace: next,
      registry: registry,
      machService: "qualification.unused",
      gateway: gateway
    )
    try server.endWorkspace(authority: nextAuthority, gateway: gateway)
    try awaitSettlement(server)
    #expect(server.inventory().first?.available == false)
    try server.forgetWorkspace(next)
  }

  private func awaitSettlement(_ server: GuardianServer) throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while server.inventory()
      .contains(where: { $0.starting || $0.worker?.finished == false })
    {
      guard ContinuousClock.now < deadline else {
        throw MuxError(.connectionLost, "creation did not settle")
      }
      Thread.sleep(forTimeInterval: 0.005)
    }
  }

  private func stop(_ server: GuardianServer) {
    let stopped = DispatchSemaphore(value: 0)
    server.shutdown { stopped.signal() }
    #expect(stopped.wait(timeout: .now() + 5) == .success)
  }

  private func createThroughGateway(
    _ endpoint: SMXEndpoint,
    workspace: WorkspaceID
  ) throws -> GuardianAuthority {
    let state = CreationClient()
    let queue = DispatchQueue(label: "registry-creation-client")
    try queue.sync {
      state.connection = try GuardianGatewayConnection(
        channel: .connect(endpoint: endpoint, queue: queue),
        peerRequirement: nil,
        expectedGuardianPID: getpid(),
        ready: { _ in
          let admitted = state.connection?
            .submit(.create(workspace: workspace)) { result in
              state.result.withLock { $0 = result }
              state.completed.signal()
            }
          #expect(admitted == true)
        },
        closed: { _ in }
      )
    }
    defer {
      queue.sync {
        state.connection?.close();
        state.connection = nil
      }
    }
    guard state.completed.wait(timeout: .now() + 5) == .success,
      let result = state.result.withLock({ $0 }),
      case let .creating(authority) = try result.get()
    else { throw MuxError(.connectionLost, "gateway creation failed") }
    return authority
  }

  private final class CreationClient: @unchecked Sendable {
    var connection: GuardianGatewayConnection?
    let completed = DispatchSemaphore(value: 0)
    let result = Mutex<Result<GuardianGatewayConnection.Reply, MuxError>?>(nil)
  }

  @Test
  func selectionAndLiveReferencesPreventCollection() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let registry = try fixture.registry()
    #expect(throws: MuxError.self) { try registry.pinSelected() }
    try registry.select("one")
    var pin: GuardianBuildPin? = try registry.pinSelected()
    #expect(pin?.build == "one")
    #expect(pin?.manifest.workerProtocol == SMX.protocolVersion)
    #expect(pin?.manifest.guardianProtocol == GuardianWire.version)
    try registry.select("two")
    #expect(throws: MuxError.self) { try registry.remove("one") }
    #expect(throws: MuxError.self) { try registry.remove("two") }
    withExtendedLifetime(pin) {}
    pin = nil
    #expect(throws: MuxError.self) { try registry.remove("one") }
    try registry.clearRollback()
    try registry.remove("one")
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent("one").path
      )
    )
    #expect(try registry.pinSelected().build == "two")
  }

  @Test
  func workspaceRetainsBuildAfterWorkerExitUntilAcknowledgedRetirement() throws
  {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let registry = try fixture.registry()
    let server = try GuardianServer(
      launcherPath: launcherPath(),
      peerRequirement: nil
    )
    defer {
      let stopped = DispatchSemaphore(value: 0)
      server.shutdown { stopped.signal() }
      #expect(stopped.wait(timeout: .now() + 5) == .success)
    }
    let workspace = WorkspaceID()
    try launch(server, registry: registry, workspace: workspace)
    let deadline = ContinuousClock.now + .seconds(5)
    while server.inventory().first?.worker?.finished != true {
      guard ContinuousClock.now < deadline else {
        throw MuxError(.connectionLost, "worker did not exit")
      }
      Thread.sleep(forTimeInterval: 0.005)
    }
    #expect(server.inventory().first?.worker?.build == "one")
    #expect(server.inventory().first?.workerProtocol == SMX.protocolVersion)
    // Inventory uses the validated pin, not a later read from an installation path.
    let manifestURL = fixture.root.appendingPathComponent(
      "one/Worker.app/Contents/Resources/build.json"
    )
    try JSONEncoder()
      .encode(
        GuardianBuildManifest(
          build: "one",
          workerProtocol: SMX.protocolVersion + 100
        )
      )
      .write(to: manifestURL)
    #expect(server.inventory().first?.workerProtocol == SMX.protocolVersion)
    #expect(throws: MuxError.self) { try registry.pin("one") }
    #expect(throws: MuxError.self) { try registry.remove("one") }
    #expect(throws: MuxError.self) { try server.forgetWorkspace(workspace) }
    server.endWorkspace(workspace)
    try server.forgetWorkspace(workspace)
    try registry.remove("one")
  }

  @Test
  func runtimePreflightReadsRetainedPinWithoutEndingOrCollectingIt()
    async throws
  {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let registry = try fixture.registry()
    let server = try GuardianServer(
      launcherPath: launcherPath(),
      peerRequirement: nil
    )
    let control = GuardianGatewayServer(guardian: server, peerRequirement: nil)
    let endpoint = control.listenAnonymously()
    defer {
      control.close();
      stop(server)
    }
    let workspace = WorkspaceID()
    try launch(server, registry: registry, workspace: workspace)
    try awaitSettlement(server)
    let supervisor = try await GatewaySupervisor.connect(
      peerRequirement: nil,
      expectedGuardianPID: getpid(),
      channel: { .connect(endpoint: endpoint, queue: $0) }
    )
    let runtime = try await GatewayRuntime.start(
      supervisor: supervisor,
      peerRequirement: nil
    )
    try await runtime.preflightUpdate(
      guardianProtocol: GuardianWire.version,
      workerProtocols: [SMX.protocolVersion]
    )
    do {
      try await runtime.preflightUpdate(
        guardianProtocol: GuardianWire.version,
        workerProtocols: [SMX.protocolVersion + 1]
      )
      Issue.record("incompatible retained worker passed runtime preflight")
    } catch let error as MuxError {
      #expect(error.code == .incompatibleVersion)
    }
    #expect(server.inventory().count == 1)
    #expect(throws: MuxError.self) { try registry.remove("one") }
    #expect(throws: MuxError.self) { try server.forgetWorkspace(workspace) }
    try await runtime.endWorkspace(.id(workspace))
    // This check must fetch current guardian inventory, not the monitor's cache.
    try await runtime.preflightUpdate(
      guardianProtocol: GuardianWire.version,
      workerProtocols: [SMX.protocolVersion + 1]
    )
    await runtime.close()
    await #expect(throws: MuxError.self) {
      try await runtime.preflightUpdate(
        guardianProtocol: GuardianWire.version,
        workerProtocols: [SMX.protocolVersion]
      )
    }
  }

  @Test(arguments: [
    "symlink", "hardlink", "writable", "manifest", "version", "missing",
    "signature",
  ])
  func unsafeOrIncompatibleBuildIsRejected(kind: String) throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let bundle = fixture.root.appendingPathComponent("one/Worker.app")
    let resource = bundle.appendingPathComponent(
      "Contents/Resources/build.json"
    )
    switch kind {
    case "symlink":
      try FileManager.default.createSymbolicLink(
        at: bundle.appendingPathComponent("escape"),
        withDestinationURL: fixture.root
      )
    case "hardlink":
      #expect(
        link(resource.path, bundle.appendingPathComponent("alias").path) == 0
      )
    case "writable": #expect(chmod(resource.path, 0o666) == 0)
    case "manifest":
      try JSONEncoder().encode(GuardianBuildManifest(build: "another"))
        .write(to: resource)
    case "version":
      try JSONEncoder()
        .encode(GuardianBuildManifest(build: "one", guardianProtocol: 999))
        .write(to: resource)
    case "missing":
      try FileManager.default.removeItem(
        at: bundle.appendingPathComponent("Contents/MacOS/swsh")
      )
    default: break
    }
    let registry = try GuardianBuildRegistry(
      root: fixture.root,
      peerRequirement: kind == "signature" ? "anchor apple" : nil
    )
    #expect(throws: (any Error).self) { try registry.pin("one") }
    #expect(throws: MuxError.self) { try registry.pin("../one") }
  }

  @Test
  func buildRootMustBePrivateAndCannotBeASymlink() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let alias = fixture.root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(
      at: alias,
      withDestinationURL: fixture.root
    )
    #expect(throws: MuxError.self) {
      try GuardianBuildRegistry(root: alias, peerRequirement: nil)
    }
    #expect(chmod(fixture.root.path, 0o755) == 0)
    #expect(throws: MuxError.self) { try fixture.registry() }
  }

  private func launch(
    _ server: GuardianServer,
    registry: GuardianBuildRegistry,
    workspace: WorkspaceID
  ) throws {
    let pin = try registry.pin("one")
    let completed = DispatchSemaphore(value: 0)
    server.launchWorker(
      workspace: workspace,
      build: pin,
      machService: "qualification.unused"
    ) { result in
      if case let .failure(error) = result {
        Issue.record("worker launch failed: \(error)")
      }
      completed.signal()
    }
    #expect(completed.wait(timeout: .now() + 5) == .success)
  }

  struct Fixture {
    let root: URL
    init() throws {
      root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent(
          "swiftty-builds-" + UUID().uuidString,
          isDirectory: true
        )
      try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      for build in ["one", "two"] {
        let directory = root.appendingPathComponent(build)
        try FileManager.default.createDirectory(
          at: directory,
          withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700]
        )
        let bundle = directory.appendingPathComponent("Worker.app")
        let executables = bundle.appendingPathComponent("Contents/MacOS")
        let resources = bundle.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(
          at: executables,
          withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
          at: resources.appendingPathComponent("terminfo"),
          withIntermediateDirectories: true
        )
        for name in ["swiftmux-worker", "swmux-launcher", "swsh"] {
          let executable = executables.appendingPathComponent(name)
          try Data("#!/bin/sh\ncat <&3 >/dev/null\nexit 0\n".utf8)
            .write(to: executable)
          #expect(chmod(executable.path, 0o700) == 0)
        }
        try JSONEncoder().encode(GuardianBuildManifest(build: build))
          .write(to: resources.appendingPathComponent("build.json"))
      }
    }
    func registry() throws -> GuardianBuildRegistry {
      try GuardianBuildRegistry(root: root, peerRequirement: nil)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
  }
}
