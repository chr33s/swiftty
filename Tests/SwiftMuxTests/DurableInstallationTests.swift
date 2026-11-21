import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
import Synchronization
import Testing

/// Installer ordering (spec.durability.md §9, UA8) against recorded fakes:
/// empty-state barrier, End confirmation, rollback before the transition
/// completes, guardian maintenance, uninstall and startup reporting.
@Suite(.serialized)
struct DurableInstallationTests {
  final class World: @unchecked Sendable {
    let log = Mutex<[String]>([])
    let state = Mutex(
      (
        legacyWorkspaces: 0, guardianUp: false, gatewayUp: false,
        incarnation: UUID(), durableWorkspaces: 0, failGateway: false,
        updatePending: false
      )
    )
    func note(_ entry: String) { log.withLock { $0.append(entry) } }
    var entries: [String] { log.withLock { $0 } }
  }

  struct Legacy: LegacyMux {
    let world: World
    func workspaceCount() async throws -> Int {
      world.state.withLock { $0.legacyWorkspaces }
    }
    func endAll() async throws {
      world.note("legacy.endAll")
      world.state.withLock { $0.legacyWorkspaces = 0 }
    }
    func unregister() async throws { world.note("legacy.unregister") }
    func register() async throws { world.note("legacy.register") }
  }

  struct Agent: DurableAgent {
    let world: World
    let name: String
    func register() async throws {
      world.note("\(name).register")
      try world.state.withLock { state in
        if name == "guardian" {
          state.guardianUp = true
          state.incarnation = UUID()  // A fresh guardian process.
        } else {
          if state.failGateway {
            throw MuxError(.launchFailed, "gateway registration failed")
          }
          state.gatewayUp = true
        }
      }
    }
    func unregister() async throws {
      world.note("\(name).unregister")
      world.state.withLock { state in
        if name == "guardian" {
          state.guardianUp = false
          state.durableWorkspaces = 0  // Its PTYs end with it.
        } else {
          state.gatewayUp = false
        }
      }
    }
  }

  struct Status: DurableStatus {
    let world: World
    func installation() async throws -> GatewayInstallationStatus? {
      world.state.withLock { state in
        guard state.guardianUp, state.gatewayUp else { return nil }
        return GatewayInstallationStatus(
          guardianIncarnation: state.incarnation,
          workspaces: state.durableWorkspaces,
          updatePending: state.updatePending
        )
      }
    }
    func endAll() async throws {
      world.note("durable.endAll")
      world.state.withLock { $0.durableWorkspaces = 0 }
    }
  }

  /// The running gateway's side: hands over unless told to defer; the
  /// candidate finishes only when `candidateFinishes`.
  struct Updating: GatewayUpdating {
    let world: World
    let defers: Bool
    func prepareUpdate(
      _ request: GatewayUpdateRequest
    ) async throws -> GatewayUpdateResult {
      world.note("prepare")
      if defers { return .deferred(MuxError(.incompatibleVersion, "no")) }
      world.state.withLock { $0.updatePending = true }
      return .handedOver(build: "2")
    }
  }

  private func update(
    _ world: World,
    _ install: DurableInstallation,
    defers: Bool = false,
    candidateFinishes: Bool
  ) async throws -> DurableInstallation.GatewayUpdate {
    try await install.updateGateway(
      GatewayUpdateRequest(
        candidate: "/c",
        workerBuild: nil,
        workerProtocol: nil
      ),
      through: Updating(world: world, defers: defers),
      agent: Agent(world: world, name: "gateway"),
      install: {
        world.note("swap")
        if candidateFinishes {
          world.state.withLock { $0.updatePending = false }
        }
        return {
          world.note("restore")
          world.state.withLock { $0.updatePending = false }
        }
      },
      settle: .milliseconds(300)
    )
  }

  @Test
  func aGatewayUpdateSwapsAfterHandoverAndRollsBackIfUnfinished() async throws {
    let world = World()
    let dir = root()
    defer { try? FileManager.default.removeItem(at: dir) }
    let install = installer(world, dir)
    _ = try await install.adopt(
      from: Legacy(world: world),
      confirm: confirming(world, true)
    )
    world.log.withLock { $0.removeAll() }
    #expect(
      try await update(world, install, candidateFinishes: true)
        == .updated(build: "2")
    )
    #expect(
      world.entries == [
        "prepare", "gateway.unregister", "swap", "gateway.register",
      ]
    )
    world.log.withLock { $0.removeAll() }
    #expect(
      try await update(world, install, candidateFinishes: false)
        == .rolledBack(build: "2")
    )
    #expect(
      world.entries == [
        "prepare", "gateway.unregister", "swap", "gateway.register",
        "gateway.unregister", "restore", "gateway.register",
      ]
    )
    world.log.withLock { $0.removeAll() }
    guard
      case .deferred = try await update(
        world,
        install,
        defers: true,
        candidateFinishes: true
      )
    else {
      Issue.record("incompatible update was not deferred")
      return
    }
    #expect(world.entries == ["prepare"])
  }

  private func installer(_ world: World, _ root: URL) -> DurableInstallation {
    DurableInstallation(
      guardian: Agent(world: world, name: "guardian"),
      gateway: Agent(world: world, name: "gateway"),
      status: Status(world: world),
      record: root.appendingPathComponent("install.json"),
      settle: .seconds(2),
      poll: .milliseconds(5)
    )
  }

  private func root() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "durable-install-\(UUID().uuidString)"
    )
  }

  private func confirming(
    _ world: World,
    _ answer: Bool
  ) -> DurableInstallation.Confirm {
    { count in
      world.note("confirm(\(count))")
      return answer
    }
  }

  @Test
  func adoptionEndsLegacySessionsOnlyAfterConfirmationThenRegisters()
    async throws
  {
    let world = World()
    world.state.withLock { $0.legacyWorkspaces = 2 }
    let dir = root()
    defer { try? FileManager.default.removeItem(at: dir) }
    let outcome = try await installer(world, dir)
      .adopt(from: Legacy(world: world), confirm: confirming(world, true))
    guard case .installed = outcome else {
      Issue.record("\(outcome)")
      return
    }
    #expect(
      world.entries == [
        "confirm(2)", "legacy.endAll", "legacy.unregister", "guardian.register",
        "gateway.register",
      ]
    )
    #expect(try await installer(world, dir).startup() != .notInstalled)
  }

  @Test
  func declinedAdoptionChangesNothing() async throws {
    let world = World()
    world.state.withLock { $0.legacyWorkspaces = 3 }
    let dir = root()
    defer { try? FileManager.default.removeItem(at: dir) }
    let outcome = try await installer(world, dir)
      .adopt(from: Legacy(world: world), confirm: confirming(world, false))
    #expect(outcome == .declined(workspaces: 3))
    #expect(world.entries == ["confirm(3)"])
    #expect(world.state.withLock { $0.legacyWorkspaces } == 3)
    #expect(try await installer(world, dir).startup() == .notInstalled)
  }

  @Test
  func anEmptyLegacyAgentNeedsNoConfirmation() async throws {
    let world = World()
    let dir = root()
    defer { try? FileManager.default.removeItem(at: dir) }
    _ = try await installer(world, dir)
      .adopt(from: Legacy(world: world), confirm: confirming(world, false))
    #expect(!world.entries.contains { $0.hasPrefix("confirm") })
    #expect(world.entries.first == "legacy.unregister")
  }

  @Test
  func aFailedTransitionRestoresTheLegacyAgent() async throws {
    let world = World()
    world.state.withLock { $0.failGateway = true }
    let dir = root()
    defer { try? FileManager.default.removeItem(at: dir) }
    await #expect(throws: MuxError.self) {
      _ = try await installer(world, dir)
        .adopt(from: Legacy(world: world), confirm: confirming(world, true))
    }
    #expect(
      world.entries == [
        "legacy.unregister", "guardian.register", "gateway.register",
        "gateway.unregister", "guardian.unregister", "legacy.register",
      ]
    )
    #expect(try await installer(world, dir).startup() == .notInstalled)
  }

  @Test
  func guardianMaintenanceIsBehindTheEmptyStateBarrier() async throws {
    let world = World()
    let dir = root()
    defer { try? FileManager.default.removeItem(at: dir) }
    let install = installer(world, dir)
    guard
      case let .installed(first) = try await install.adopt(
        from: Legacy(world: world),
        confirm: confirming(world, true)
      )
    else { return }
    world.state.withLock { $0.durableWorkspaces = 2 }
    world.log.withLock { $0.removeAll() }
    // Declined: every session and agent stays.
    #expect(
      try await install.maintainGuardian(
        confirm: confirming(world, false),
        replace: { world.note("replace") }
      ) == .declined(workspaces: 2)
    )
    #expect(world.entries == ["confirm(2)"])
    world.log.withLock { $0.removeAll() }
    let outcome = try await install.maintainGuardian(
      confirm: confirming(world, true),
      replace: { world.note("replace") }
    )
    guard case let .maintained(second) = outcome else {
      Issue.record("\(outcome)")
      return
    }
    #expect(second != first)
    #expect(
      world.entries == [
        "confirm(2)", "durable.endAll", "gateway.unregister",
        "guardian.unregister", "replace", "guardian.register",
        "gateway.register",
      ]
    )
    #expect(try await install.startup() == .running(guardian: second))
  }

  @Test
  func uninstallEndsConfirmedSessionsAndRemovesBothAgents() async throws {
    let world = World()
    let dir = root()
    defer { try? FileManager.default.removeItem(at: dir) }
    let install = installer(world, dir)
    _ = try await install.adopt(
      from: Legacy(world: world),
      confirm: confirming(world, true)
    )
    world.state.withLock { $0.durableWorkspaces = 1 }
    world.log.withLock { $0.removeAll() }
    #expect(
      try await install.uninstall(confirm: confirming(world, true))
        == .uninstalled
    )
    #expect(
      world.entries == [
        "confirm(1)", "durable.endAll", "gateway.unregister",
        "guardian.unregister",
      ]
    )
    #expect(!world.entries.contains("legacy.register"))
    #expect(try await install.startup() == .notInstalled)
  }

  @Test
  func aGuardianRestartIsReportedAsEndedSessionsNeverRestored() async throws {
    let world = World()
    let dir = root()
    defer { try? FileManager.default.removeItem(at: dir) }
    let install = installer(world, dir)
    guard
      case let .installed(first) = try await install.adopt(
        from: Legacy(world: world),
        confirm: confirming(world, true)
      )
    else { return }
    // Reboot: launchd starts a fresh guardian with no sessions.
    let rebooted = UUID()
    world.state.withLock {
      $0.incarnation = rebooted
      $0.durableWorkspaces = 0
    }
    #expect(
      try await install.startup()
        == .sessionsEnded(previous: first, guardian: rebooted)
    )
    #expect(try await install.startup() == .running(guardian: rebooted))
    // An unreachable gateway is reported, not replaced by a local shell.
    world.state.withLock { $0.gatewayUp = false }
    #expect(try await install.startup() == .unavailable)
  }
}
