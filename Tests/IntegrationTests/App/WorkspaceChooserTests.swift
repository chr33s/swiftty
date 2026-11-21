import Crypto
import Foundation
import MuxNavigation
import ScreenProtocol
import SSHIdentity
import SessionCore
import SwiftMuxProtocol
import Synchronization
import TerminalSurface
import Testing

@testable import RoamingApp

/// Metadata-only service: answers `.workspaces` from a script and counts
/// every request. It can create nothing and holds no lease.
private final class ScriptedWorkspaces: RoamingAttentionMetadataService {
  private struct State {
    var replies: [HostMetadata]
    var requests: [AttentionRequest] = []
    var closed = 0
    var pauseNext = false
    var pending: CheckedContinuation<Void, Never>?
  }

  private let state: Mutex<State>

  init(_ replies: [HostMetadata]) { state = Mutex(State(replies: replies)) }

  var requests: [AttentionRequest] { state.withLock { $0.requests } }
  var closed: Int { state.withLock { $0.closed } }

  func suspendNextReply() { state.withLock { $0.pauseNext = true } }
  var isWaiting: Bool { state.withLock { $0.pending != nil } }
  func releaseReply() {
    let pending = state.withLock { state in
      let pending = state.pending
      state.pending = nil
      return pending
    }
    pending?.resume()
  }

  func metadata(
    _ request: AttentionRequest
  ) async throws(AttentionServiceError) -> HostMetadata {
    await withCheckedContinuation { continuation in
      let suspended = state.withLock { state in
        guard state.pauseNext else { return false }
        state.pauseNext = false
        state.pending = continuation
        return true
      }
      if !suspended { continuation.resume() }
    }
    return try state.withLock { state throws(AttentionServiceError) in
      state.requests.append(request)
      guard !state.replies.isEmpty else { throw .offline("gone") }
      return state.replies.count > 1
        ? state.replies.removeFirst() : state.replies[0]
    }
  }

  func serviceEpoch() async throws(AttentionServiceError)
    -> SwiftMuxProtocol.ServerInstanceID
  { try await metadata(.workspaces).serviceEpoch }
  func locate(
    _ reference: AttentionReference
  ) async throws(AttentionServiceError) -> AttentionLocation { throw .notFound }
  func leaseState(
    of workspace: WorkspaceID
  ) async throws(AttentionServiceError) -> LeaseState { throw .notFound }
  func open(
    _ target: PaneTarget,
    takeover expectedLease: UInt64?
  ) async throws(AttentionServiceError) { throw .unsupported("not here") }
  func markSeen(
    _ reference: AttentionReference
  ) async throws(AttentionServiceError) {}
  func close() async { state.withLock { $0.closed += 1 } }
}

private struct ScriptedConnector: AttentionServiceConnector {
  let service: ScriptedWorkspaces
  var beforeConnect: (@Sendable () async -> Void)?
  func connect(
    to host: NavigationHost
  ) async throws(AttentionServiceError) -> any AttentionService {
    await beforeConnect?()
    return service
  }
}

extension MainActorIntegrationTests {
  /// spec.connection-setup.md T9–T11: listing and cancelling create
  /// nothing; selection resumes by identity; takeover is confirmed for
  /// the observed generation and races refresh instead of retrying.
  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(1)))
  struct WorkspaceChooserTests {
    let epoch = SwiftMuxProtocol.ServerInstanceID()

    func model() throws -> (RoamingAppModel, HostProfile, URL) {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
      let app = RoamingAppModel(
        store: ConnectionStore(
          fileURL: directory.appendingPathComponent("hosts.json")
        ),
        resumeStore: SessionResumeStore(
          defaults: try #require(UserDefaults(suiteName: UUID().uuidString))
        )
      )
      let host = HostProfile(nickname: "Mac", host: "mac.local", username: "me")
      #expect(try app.save(host))
      return (app, host, directory)
    }

    func summary(
      _ name: String,
      attached: Bool = false,
      lease: UInt64 = 0
    ) -> WorkspaceSummary {
      WorkspaceSummary(
        id: WorkspaceID(),
        name: name,
        tabCount: 2,
        paneCount: 3,
        createdAt: .now,
        isAttached: attached,
        leaseGeneration: lease,
        leaseHolder: attached
          ? LeaseHolder(transport: .remote, frontend: .terminal, since: .now)
          : nil
      )
    }

    func loaded(_ chooser: WorkspaceChooserModel) async throws -> Bool {
      let deadline = ContinuousClock.now + .seconds(5)
      while chooser.phase != .loaded {
        guard ContinuousClock.now < deadline else { return false }
        try await Task.sleep(for: .milliseconds(5))
      }
      return true
    }

    func settle(_ condition: () -> Bool) async throws -> Bool {
      let deadline = ContinuousClock.now + .seconds(5)
      while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try await Task.sleep(for: .milliseconds(5))
      }
      return true
    }

    @Test(arguments: [
      "unchanged", "rename", "key", "case", "roundTrip", "account", "binding",
      "endpoint", "port", "username",
    ])
    func shownWorkspaceBelongsToTheActiveTerminalsOwner(
      change: String
    ) async throws {
      let (app, original, directory) = try model()
      defer { try? FileManager.default.removeItem(at: directory) }
      if change != "binding" {
        #expect(
          app.commitConnections {
            $0.settings.metadataSync = true
            ConnectionSyncCoordinator.bind(&$0, to: "a")
          }
        )
      }
      let held = summary("Held", attached: true, lease: 7)
      app.openWorkspace(original, intent: .resume(SessionID(held.id), nil))
      let active = try #require(app.activeSession)
      #expect(
        active.selection?.context.scope == (change == "binding" ? nil : "a")
      )
      active.observe(
        RoamingStatus(state: .active, sessionID: SessionID(held.id))
      )
      var host = original
      switch change {
      case "binding":
        #expect(
          app.commitConnections {
            $0.settings.metadataSync = true
            ConnectionSyncCoordinator.bind(&$0, to: "a")
          }
        )
      case "account", "roundTrip":
        #expect(
          app.commitConnections {
            ConnectionSyncCoordinator.bind(&$0, to: "b")
            if change == "account" {
              $0.activateRecord(
                ConnectionSnapshot.hostRecord(host.id),
                for: "b"
              )
              $0.upsertHost(host)
            }
          }
        )
        if change == "roundTrip" {
          #expect(
            app.commitConnections {
              ConnectionSyncCoordinator.bind(&$0, to: "a")
            }
          )
        }
      case "endpoint": host.host = "other.local"
      case "port": host.port += 1
      case "username": host.username = "other"
      case "rename": host.nickname = "Renamed"
      case "case": host.host = host.host.uppercased()
      case "key": host.auth = .key(identityID: UUID())
      default: break
      }
      if change != "account" { #expect(try app.save(host)) }
      let service = ScriptedWorkspaces([
        HostMetadata(serviceEpoch: epoch, workspaces: [held])
      ])
      let chooser = WorkspaceChooserModel(
        model: app,
        host: host,
        connector: ScriptedConnector(service: service)
      )
      defer {
        chooser.close();
        app.close()
      }
      chooser.load()
      try #require(try await loaded(chooser))
      let row = try #require(chooser.rows.first)
      let sameOwner = ["unchanged", "rename", "key", "case", "roundTrip"]
        .contains(change)
      #expect(row.isShownHere == sameOwner)
      #expect(row.heldElsewhere == !sameOwner)
      chooser.choose(row)
      if !sameOwner {
        #expect(chooser.pendingTakeover == row)
        #expect(app.activeSession === active)
        #expect(!chooser.finished)
        // Exercise the independent lease re-read after the confirmation.
        chooser.confirmTakeover()
      }
      try #require(try await settle { chooser.finished })
      if !sameOwner {
        #expect(
          app.activeSession?.takeWorkspaceIntent()
            == .resume(SessionID(held.id), ResumeTarget(expectedLease: 7))
        )
      }
    }

    @Test(
      arguments: ["create", "resume", "takeover"],
      [
        "account", "roundTrip", "revision", "deleted", "notification",
        "unrelated", "unchanged",
      ]
    )
    func chooserActionsRequireTheirReviewedHost(
      action: String,
      change: String
    ) async throws {
      let (app, host, directory) = try model()
      defer { try? FileManager.default.removeItem(at: directory) }
      #expect(
        app.commitConnections { ConnectionSyncCoordinator.bind(&$0, to: "a") }
      )
      let row = summary("Work", attached: action == "takeover", lease: 7)
      let service = ScriptedWorkspaces([
        HostMetadata(serviceEpoch: epoch, workspaces: [row])
      ])
      let chooser = WorkspaceChooserModel(
        model: app,
        host: host,
        connector: ScriptedConnector(service: service)
      )
      defer {
        chooser.close();
        app.close()
      }
      chooser.load()
      try #require(try await loaded(chooser))
      let selected = try #require(chooser.rows.first)
      if action == "takeover" { chooser.choose(selected) }
      switch change {
      case "account", "roundTrip":
        #expect(
          app.commitConnections {
            ConnectionSyncCoordinator.bind(&$0, to: "b")
            if change == "account" {
              $0.activateRecord(
                ConnectionSnapshot.hostRecord(host.id),
                for: "b"
              )
              $0.upsertHost(host)
            }
          }
        )
        if change == "roundTrip" {
          #expect(
            app.commitConnections {
              ConnectionSyncCoordinator.bind(&$0, to: "a")
            }
          )
        }
      case "revision":
        var changed = host
        changed.nickname = "Renamed"
        #expect(try app.save(changed))
        #expect(try app.save(host))
      case "deleted": app.delete(host)
      case "notification": app.identityStore.accountDidChange()
      case "unrelated":
        #expect(
          try app.save(
            HostProfile(nickname: "Other", host: "other.local", username: "me")
          )
        )
      default: break
      }
      let previousHost = HostProfile(
        nickname: "Active",
        host: "active.local",
        username: "me"
      )
      app.open(previousHost)
      let previousSession = app.activeSession
      switch action {
      case "create": chooser.createNew()
      case "resume": chooser.choose(selected)
      default: chooser.confirmTakeover()
      }
      try #require(
        try await settle {
          if case .failed = chooser.phase { return true }
          return chooser.finished || chooser.notice != nil
        }
      )
      if change == "unchanged" || change == "unrelated" {
        #expect(chooser.finished)
        #expect(app.activeSession?.host == host)
        #expect(app.activeSession?.takeWorkspaceIntent() != nil)
      } else {
        #expect(!chooser.finished)
        #expect(app.activeSession === previousSession)
        #expect(app.activeSession?.takeWorkspaceIntent() == nil)
      }
      #expect(chooser.pendingTakeover == nil)
    }

    @Test(arguments: [false, true])
    func chooserRechecksSelectionAfterAnOutstandingReply(
      resume: Bool
    ) async throws {
      let (app, host, directory) = try model()
      defer { try? FileManager.default.removeItem(at: directory) }
      #expect(
        app.commitConnections { ConnectionSyncCoordinator.bind(&$0, to: "a") }
      )
      let row = summary("Work")
      let service = ScriptedWorkspaces([
        HostMetadata(serviceEpoch: epoch, workspaces: [row])
      ])
      let chooser = WorkspaceChooserModel(
        model: app,
        host: host,
        connector: ScriptedConnector(service: service)
      )
      defer {
        service.releaseReply();
        chooser.close();
        app.close()
      }
      if resume {
        chooser.load()
        try #require(try await loaded(chooser))
        service.suspendNextReply()
        chooser.choose(try #require(chooser.rows.first))
      } else {
        service.suspendNextReply()
        chooser.load()
      }
      try #require(try await settle { service.isWaiting })
      #expect(
        app.commitConnections {
          ConnectionSyncCoordinator.bind(&$0, to: "b")
          $0.activateRecord(ConnectionSnapshot.hostRecord(host.id), for: "b")
          $0.upsertHost(host)
        }
      )
      service.releaseReply()
      try #require(
        try await settle {
          if case .failed = chooser.phase { return true }
          return chooser.finished || chooser.phase == .loaded && !resume
        }
      )
      #expect(chooser.phase == .failed(RoamingAppModel.hostChangedMessage))
      #expect(chooser.rows.isEmpty)
      #expect(!chooser.finished)
      #expect(app.activeSession == nil)
      #expect(app.activeSession?.takeWorkspaceIntent() == nil)
      try #require(try await settle { service.closed == 1 })
    }

    @Test
    func successfulLegacyMigrationKeepsTheSelectedChooserUsable() async throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let app = RoamingAppModel(
        store: ConnectionStore(
          fileURL: directory.appendingPathComponent("hosts.json")
        ),
        secrets: InMemoryIdentitySecretStore(),
        legacyKeys: InMemoryLegacyKeySource(keys: [
          "phone": Curve25519.Signing.PrivateKey()
        ])
      )
      let host = HostProfile(
        nickname: "Mac",
        host: "mac.local",
        username: "me",
        auth: .legacyKey(label: "phone")
      )
      #expect(try app.save(host))
      let service = ScriptedWorkspaces([
        HostMetadata(serviceEpoch: epoch, workspaces: [summary("a")])
      ])
      let chooser = WorkspaceChooserModel(
        model: app,
        host: host,
        connector: ScriptedConnector(
          service: service,
          beforeConnect: { await app.identityStore.recover() }
        )
      )
      defer {
        chooser.close();
        app.close()
      }
      chooser.load()
      try #require(try await settle { chooser.phase != .connecting })
      #expect(chooser.phase == .loaded)
      #expect(chooser.host.auth.identityID == app.hosts.first?.auth.identityID)
      #expect(chooser.host.auth.identityID != nil)
      chooser.createNew()
      #expect(chooser.finished)
      #expect(app.activeSession?.host == app.hosts.first)
    }

    @Test
    func browsingAnEmptyMacAndCancellingCreatesNothing() async throws {
      let (app, host, directory) = try model()
      defer { try? FileManager.default.removeItem(at: directory) }
      let service = ScriptedWorkspaces([
        HostMetadata(serviceEpoch: epoch, workspaces: [])
      ])
      let chooser = WorkspaceChooserModel(
        model: app,
        host: host,
        connector: ScriptedConnector(service: service)
      )
      chooser.load()
      #expect(try await loaded(chooser))
      #expect(chooser.rows.isEmpty)
      chooser.close()
      #expect(try await settle { service.closed == 1 })
      // Only lease-free listing was sent; no create, no attachment.
      #expect(service.requests == [.workspaces])
      #expect(app.activeSession == nil)
      #expect(app.resumableSessionID(for: host) == nil)
      #expect(app.activeSession?.takeWorkspaceIntent() == nil)
    }

    @Test
    func choosingAFreeWorkspaceResumesItsIdentity() async throws {
      let (app, host, directory) = try model()
      defer { try? FileManager.default.removeItem(at: directory) }
      let free = summary("build")
      let service = ScriptedWorkspaces([
        HostMetadata(serviceEpoch: epoch, workspaces: [free])
      ])
      let chooser = WorkspaceChooserModel(
        model: app,
        host: host,
        connector: ScriptedConnector(service: service)
      )
      chooser.load()
      #expect(try await loaded(chooser))
      #expect(chooser.rows.first?.summary.livePaneCount == nil)
      chooser.choose(try #require(chooser.rows.first))
      #expect(try await settle { chooser.finished })
      #expect(app.activeSession?.host == host)
      #expect(
        app.activeSession?.takeWorkspaceIntent()
          == .resume(SessionID(free.id), nil)
      )
      #expect(app.resumableSessionID(for: host) == SessionID(free.id))
      app.close()
    }

    @Test
    func newWorkspaceIsTheOnlyCreate() async throws {
      let (app, host, directory) = try model()
      defer { try? FileManager.default.removeItem(at: directory) }
      let service = ScriptedWorkspaces([
        HostMetadata(serviceEpoch: epoch, workspaces: [summary("a")])
      ])
      let chooser = WorkspaceChooserModel(
        model: app,
        host: host,
        connector: ScriptedConnector(service: service)
      )
      chooser.load()
      #expect(try await loaded(chooser))
      chooser.createNew()
      #expect(chooser.finished)
      #expect(app.activeSession?.takeWorkspaceIntent() == .create)
      #expect(app.activeSession?.takeWorkspaceIntent() == nil)
      app.close()
    }

    @Test
    func takeoverNeedsConfirmationAndSendsTheObservedGeneration() async throws {
      let (app, host, directory) = try model()
      defer { try? FileManager.default.removeItem(at: directory) }
      let held = summary("held", attached: true, lease: 7)
      let service = ScriptedWorkspaces([
        HostMetadata(serviceEpoch: epoch, workspaces: [held])
      ])
      let chooser = WorkspaceChooserModel(
        model: app,
        host: host,
        connector: ScriptedConnector(service: service)
      )
      chooser.load()
      #expect(try await loaded(chooser))
      let row = try #require(chooser.rows.first)
      #expect(row.heldElsewhere)
      chooser.choose(row)
      // Nothing happens until the user confirms.
      #expect(chooser.pendingTakeover == row)
      #expect(app.activeSession == nil)
      chooser.confirmTakeover()
      #expect(try await settle { chooser.finished })
      #expect(
        app.activeSession?.takeWorkspaceIntent()
          == .resume(SessionID(held.id), ResumeTarget(expectedLease: 7))
      )
      app.close()
    }

    @Test(arguments: [false, true])
    func changedLeaseOrEpochRefreshesInsteadOfRetrying(
      epochChanged: Bool
    ) async throws {
      let (app, host, directory) = try model()
      defer { try? FileManager.default.removeItem(at: directory) }
      var held = summary("held", attached: true, lease: 7)
      var moved = held
      moved.leaseGeneration = 8
      let after =
        epochChanged
        ? HostMetadata(
          serviceEpoch: SwiftMuxProtocol.ServerInstanceID(),
          workspaces: [held]
        ) : HostMetadata(serviceEpoch: epoch, workspaces: [moved])
      let service = ScriptedWorkspaces([
        HostMetadata(serviceEpoch: epoch, workspaces: [held]), after,
      ])
      let chooser = WorkspaceChooserModel(
        model: app,
        host: host,
        connector: ScriptedConnector(service: service)
      )
      chooser.load()
      #expect(try await loaded(chooser))
      chooser.choose(try #require(chooser.rows.first))
      chooser.confirmTakeover()
      #expect(try await settle { chooser.notice != nil })
      #expect(try await settle { service.requests.count >= 3 })
      #expect(!chooser.finished)
      #expect(app.activeSession == nil)
      #expect(app.activeSession?.takeWorkspaceIntent() == nil)
      // The list now shows what is current, for a fresh decision.
      #expect(try await settle { chooser.serviceEpoch == after.serviceEpoch })
      held.leaseGeneration = after.workspaces![0].leaseGeneration
      #expect(
        chooser.rows.first?.summary.leaseGeneration == held.leaseGeneration
      )
      chooser.close()
    }

    @Test
    func vanishedWorkspaceIsNotReplacedByACreate() async throws {
      let (app, host, directory) = try model()
      defer { try? FileManager.default.removeItem(at: directory) }
      let gone = summary("gone")
      let service = ScriptedWorkspaces([
        HostMetadata(serviceEpoch: epoch, workspaces: [gone]),
        HostMetadata(serviceEpoch: epoch, workspaces: []),
      ])
      let chooser = WorkspaceChooserModel(
        model: app,
        host: host,
        connector: ScriptedConnector(service: service)
      )
      chooser.load()
      #expect(try await loaded(chooser))
      chooser.choose(try #require(chooser.rows.first))
      #expect(try await settle { chooser.notice != nil })
      #expect(!chooser.finished)
      #expect(app.activeSession?.takeWorkspaceIntent() == nil)
      chooser.close()
    }
  }

  /// Remembered identities never turn into creates (T10).
  @MainActor
  struct WorkspaceIntentTests {
    func app() throws -> RoamingAppModel {
      RoamingAppModel(
        store: ConnectionStore(
          fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("hosts.json")
        ),
        resumeStore: SessionResumeStore(
          defaults: try #require(UserDefaults(suiteName: UUID().uuidString))
        )
      )
    }

    @Test
    func resumeLastWorkspaceNeedsARememberedIdentity() throws {
      let app = try app()
      let host = HostProfile(nickname: "Mac", host: "mac.local", username: "me")
      #expect(!app.resumeLastWorkspace(host))
      #expect(app.activeSession == nil)
      #expect(app.activeSession?.takeWorkspaceIntent() == nil)
      let id = SessionID(WorkspaceID())
      app.rememberSession(id, for: app.connectionSelection(for: host))
      #expect(app.resumeLastWorkspace(host))
      #expect(app.activeSession?.takeWorkspaceIntent() == .resume(id, nil))
      app.close()
    }

    @Test
    func aScreenWithoutAChoiceCreatesNothing() async throws {
      let app = try app()
      let host = HostProfile(nickname: "Mac", host: "mac.local", username: "me")
      app.open(host)
      let session = try #require(app.activeSession)
      let controller = RoamingTerminalController(model: session, app: app)
      controller.start()
      let deadline = ContinuousClock.now + .seconds(5)
      while case .preparing = controller.phase, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
      }
      #expect(
        controller.phase == .failed(RoamingTerminalController.noWorkspaceChosen)
      )
      #expect(controller.intent == nil)
      #expect(app.pendingPassword == nil)
      #expect(app.pendingTrust == nil)
      await controller.close(.detach)
      app.close()
    }

    @Test
    func selectingTheShownWorkspaceKeepsTheTerminal() throws {
      let app = try app()
      let host = HostProfile(nickname: "Mac", host: "mac.local", username: "me")
      let id = SessionID(WorkspaceID())
      app.openWorkspace(host, intent: .resume(id, nil))
      let first = try #require(app.activeSession)
      first.observe(RoamingStatus(state: .active, sessionID: id))
      app.openWorkspace(host, intent: .resume(id, nil))
      #expect(app.activeSession === first)
      app.openWorkspace(host, intent: .create)
      #expect(app.activeSession !== first)
      #expect(first.connectionState == .userClosed)
      app.close()
    }
  }
}
