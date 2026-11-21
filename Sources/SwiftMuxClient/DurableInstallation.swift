import Darwin
import Foundation
import SwiftMuxProtocol

/// One launchd job the installer owns (spec.durability.md §9): the guardian
/// helper or the gateway. Each call completes only when the operation has;
/// unregistering a running agent terminates it.
public protocol DurableAgent: Sendable {
  func register() async throws
  func unregister() async throws
}

/// Today's monolithic agent, during the one-time transition.
public protocol LegacyMux: Sendable {
  /// Live workspaces, including retained screens.
  func workspaceCount() async throws -> Int
  /// Ends every workspace with normal bounded termination.
  func endAll() async throws
  func unregister() async throws
  /// Restores the agent when the transition fails before completing.
  func register() async throws
}

/// The running durable topology, as the gateway reports it.
public protocol DurableStatus: Sendable {
  /// Nil while the gateway is unreachable.
  func installation() async throws -> GatewayInstallationStatus?
  /// Explicit End of every retained workspace, running or unavailable.
  func endAll() async throws
}

/// What the installer last established. Owner-only installation metadata,
/// never session authority (spec.durability.md §9).
public struct DurableInstallationRecord: Codable, Sendable, Equatable {
  public enum Phase: String, Codable, Sendable {
    /// Leaving the monolithic agent: it is unregistered, durable agents
    /// are not yet verified.
    case transitioning
    case installed
    /// Guardian maintenance or uninstall in progress.
    case maintaining
  }
  public var phase: Phase
  /// The guardian incarnation verified at install or maintenance.
  public var guardianIncarnation: UUID?
  public var updatedAt: Date

  public init(
    phase: Phase,
    guardianIncarnation: UUID?,
    updatedAt: Date = Date()
  ) {
    self.phase = phase
    self.guardianIncarnation = guardianIncarnation
    self.updatedAt = updatedAt
  }
}

/// Initial adoption, guardian maintenance, uninstall and reboot reporting
/// (spec.durability.md §9, UA8). Every disruptive step sits behind the
/// empty-state barrier and an explicit End confirmation; nothing adopts a
/// live shell, and nothing claims sessions survived a guardian restart.
public actor DurableInstallation {
  public enum Outcome: Sendable, Equatable {
    case installed(guardian: UUID)
    case maintained(guardian: UUID)
    case uninstalled
    /// The user declined to end live sessions; nothing changed.
    case declined(workspaces: Int)
  }

  /// After a guardian restart (crash, logout or reboot) live sessions are
  /// gone. Saved layouts may be offered for reopening (§12.2); nothing is
  /// reported as restored.
  public enum Startup: Sendable, Equatable {
    case notInstalled
    case running(guardian: UUID)
    case sessionsEnded(previous: UUID?, guardian: UUID)
    /// The gateway is unreachable; no local shell is started instead.
    case unavailable
    /// A transition or maintenance did not finish.
    case interrupted(DurableInstallationRecord.Phase)
  }

  /// Asks the user to end `workspaces` live workspaces. True to proceed.
  public typealias Confirm = @Sendable (Int) async -> Bool

  private let guardian: any DurableAgent
  private let gateway: any DurableAgent
  private let status: any DurableStatus
  private let record: URL
  private let settle: Duration
  private let poll: Duration

  public init(
    guardian: any DurableAgent,
    gateway: any DurableAgent,
    status: any DurableStatus,
    record: URL,
    settle: Duration = .seconds(30),
    poll: Duration = .milliseconds(100)
  ) {
    self.guardian = guardian
    self.gateway = gateway
    self.status = status
    self.record = record
    self.settle = settle
    self.poll = poll
  }

  // MARK: Initial adoption

  /// The one-time move from the monolithic agent. Its shells are never
  /// adopted: they end (after confirmation) before it is unregistered.
  public func adopt(
    from legacy: any LegacyMux,
    confirm: Confirm
  ) async throws -> Outcome {
    if let current = try load(), current.phase == .installed {
      throw MuxError(.invalidRequest, "the durable topology is installed")
    }
    let live = try await legacy.workspaceCount()
    if live > 0 {
      guard await confirm(live) else { return .declined(workspaces: live) }
      try await legacy.endAll()
      try await waitUntil("legacy sessions to end") {
        try await legacy.workspaceCount() == 0
      }
    }
    try save(.init(phase: .transitioning, guardianIncarnation: nil))
    try await legacy.unregister()
    do {
      let incarnation = try await start()
      try save(.init(phase: .installed, guardianIncarnation: incarnation))
      return .installed(guardian: incarnation)
    } catch {
      // Not yet durable: both new agents are empty, so restore the old
      // one rather than leave the user with no terminal service.
      try? await gateway.unregister()
      try? await guardian.unregister()
      try await legacy.register()
      remove()
      throw error
    }
  }

  // MARK: Guardian maintenance and uninstall

  /// Replaces the guardian helper behind the empty-state barrier, then
  /// verifies a new incarnation. `replace` installs the new helper bundle.
  public func maintainGuardian(
    confirm: Confirm,
    replace: @Sendable () async throws -> Void
  ) async throws -> Outcome {
    guard let before = try await barrier(confirm: confirm) else {
      return .declined(workspaces: try await liveCount())
    }
    try save(.init(phase: .maintaining, guardianIncarnation: before))
    try await gateway.unregister()
    try await guardian.unregister()
    try await replace()
    let incarnation = try await start()
    guard incarnation != before else {
      throw MuxError(.serverInstanceChanged, "guardian did not restart")
    }
    try save(.init(phase: .installed, guardianIncarnation: incarnation))
    return .maintained(guardian: incarnation)
  }

  /// Removes the durable agents behind the same barrier. The monolithic
  /// agent is not reinstated.
  public func uninstall(confirm: Confirm) async throws -> Outcome {
    guard let current = try await barrier(confirm: confirm) else {
      return .declined(workspaces: try await liveCount())
    }
    try save(.init(phase: .maintaining, guardianIncarnation: current))
    try await gateway.unregister()
    try await guardian.unregister()
    remove()
    return .uninstalled
  }

  // MARK: Startup

  /// What the app reports at launch. Never a restoration claim.
  public func startup() async throws -> Startup {
    guard var current = try load() else { return .notInstalled }
    guard current.phase == .installed else {
      return .interrupted(current.phase)
    }
    guard let status = try? await status.installation() else {
      return .unavailable
    }
    if status.guardianIncarnation == current.guardianIncarnation {
      return .running(guardian: status.guardianIncarnation)
    }
    let previous = current.guardianIncarnation
    current.guardianIncarnation = status.guardianIncarnation
    current.updatedAt = Date()
    try save(current)
    return .sessionsEnded(
      previous: previous,
      guardian: status.guardianIncarnation
    )
  }

  // MARK: Steps

  /// The guardian then the gateway; verified through the gateway, which
  /// must report an empty guardian.
  private func start() async throws -> UUID {
    try await guardian.register()
    try await gateway.register()
    var verified: GatewayInstallationStatus?
    try await waitUntil("the durable topology") {
      verified = try? await status.installation()
      return verified != nil
    }
    guard let verified, verified.workspaces == 0 else {
      throw MuxError(.invalidRequest, "a new guardian reported live workspaces")
    }
    return verified.guardianIncarnation
  }

  /// Empty-state barrier: nil when the user declines. Ends confirmed
  /// workspaces through the gateway and waits for an empty guardian.
  private func barrier(confirm: Confirm) async throws -> UUID? {
    guard let current = try await status.installation() else {
      throw MuxError(.notAttached, "the gateway is unreachable")
    }
    if current.workspaces > 0 {
      guard await confirm(current.workspaces) else { return nil }
      try await status.endAll()
      try await waitUntil("durable sessions to end") {
        try await status.installation()?.workspaces == 0
      }
    }
    return current.guardianIncarnation
  }

  private func liveCount() async throws -> Int {
    try await status.installation()?.workspaces ?? 0
  }

  private func waitUntil(
    _ what: String,
    _ condition: () async throws -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + settle
    while !(try await condition()) {
      guard ContinuousClock.now < deadline else {
        throw MuxError(.quiescing, "timed out waiting for \(what)")
      }
      try await Task.sleep(for: poll)
    }
  }

  // MARK: Record

  private func load() throws -> DurableInstallationRecord? {
    guard FileManager.default.fileExists(atPath: record.path) else {
      return nil
    }
    let attributes = try FileManager.default.attributesOfItem(
      atPath: record.path
    )
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      (attributes[.posixPermissions] as? Int).map({ $0 & 0o077 == 0 }) == true
    else { throw MuxError(.invalidRequest, "unsafe installation record") }
    return try JSONDecoder()
      .decode(DurableInstallationRecord.self, from: Data(contentsOf: record))
  }

  private func save(_ value: DurableInstallationRecord) throws {
    let directory = record.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let temporary = directory.appendingPathComponent(
      ".install-\(UUID().uuidString)"
    )
    let data = try JSONEncoder().encode(value)
    let fd = open(
      temporary.path,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
      0o600
    )
    guard fd >= 0 else {
      throw MuxError(.invalidRequest, "cannot write record")
    }
    let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    let synced = fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0
    close(fd)
    guard written == data.count, synced,
      rename(temporary.path, record.path) == 0
    else {
      unlink(temporary.path)
      throw MuxError(.invalidRequest, "cannot publish installation record")
    }
  }

  private func remove() { unlink(record.path) }
}

/// A durable helper bundle registering its own agent: its executable's
/// `register` and `unregister` commands (spec.durability.md §9).
public struct HelperProcessAgent: DurableAgent {
  public let executable: URL

  public init(executable: URL) { self.executable = executable }

  public func register() async throws { try await run("register") }
  public func unregister() async throws { try await run("unregister") }

  private func run(_ command: String) async throws {
    let process = Process()
    process.executableURL = executable
    process.arguments = [command]
    process.standardOutput = FileHandle.nullDevice
    let status: Int32 = try await withCheckedThrowingContinuation {
      continuation in
      process.terminationHandler = {
        continuation.resume(returning: $0.terminationStatus)
      }
      do { try process.run() } catch {
        process.terminationHandler = nil
        continuation.resume(throwing: error)
      }
    }
    guard status == 0 else {
      throw MuxError(
        .launchFailed,
        "\(executable.lastPathComponent) \(command) exited \(status)"
      )
    }
  }
}

/// The durable topology as its gateway reports it over native control.
public struct GatewayControlStatus: DurableStatus {
  public let controlService: String
  public let peerRequirement: String?

  public init(controlService: String, peerRequirement: String?) {
    self.controlService = controlService
    self.peerRequirement = peerRequirement
  }

  private func connect() async throws -> MuxGatewayConnection {
    let service = controlService
    return try await MuxGatewayConnection.connect(
      peerRequirement: peerRequirement,
      channel: { .connect(machService: service, queue: $0) }
    )
  }

  public func installation() async throws -> GatewayInstallationStatus? {
    guard let connection = try? await connect() else { return nil }
    let status = try? await connection.installationStatus()
    await connection.close()
    return status
  }

  public func endAll() async throws {
    let connection = try await connect()
    do {
      for record in try await connection.listWorkspaces() {
        try await connection.endWorkspace(.id(record.workspace))
      }
      await connection.close()
    } catch {
      await connection.close()
      throw error
    }
  }
}
