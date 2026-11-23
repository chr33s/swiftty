import Foundation
import ServiceManagement
import SwiftMuxClient
import SwiftMuxGuardian
import SwiftMuxProtocol

/// The durable topology this app installs (spec.durability.md §9): a
/// separately signed guardian helper and gateway helper, copied out of the
/// replaceable app into the owner's SwiftMux support directory, each
/// registering its own agent. Used only when the app ships the helpers.
enum DurableSessions {
  static let guardianLabel = "com.chr33s.swiftty.swiftmux-guardian"
  static let gatewayLabel = "com.chr33s.swiftty.swiftmux-gateway"
  static var gatewayControl: String { gatewayLabel + ".control" }
  static let guardianApp = "SwiftMuxGuardian.app"
  static let gatewayApp = "SwiftMuxGateway.app"
  static let workerApp = "Worker.app"

  static var support: URL? {
    HelperAgentCommand.accountHome()
      .map {
        URL(fileURLWithPath: $0)
          .appendingPathComponent("Library/Application Support/SwiftMux")
      }
  }

  private static var bundled: URL {
    Bundle.main.bundleURL.appendingPathComponent("Contents/Library/Helpers")
  }

  /// This app carries the helpers (opt-in packaging).
  static var isShipped: Bool {
    FileManager.default.fileExists(
      atPath: bundled.appendingPathComponent(guardianApp).path
    )
  }

  /// The installer's record says the durable topology is in use.
  static var isInstalled: Bool {
    guard let record = support?.appendingPathComponent("durable-install.json"),
      let data = try? Data(contentsOf: record),
      let value = try? JSONDecoder()
        .decode(DurableInstallationRecord.self, from: data)
    else { return false }
    return value.phase == .installed
  }

  static func installer() throws -> DurableInstallation {
    guard let support else {
      throw MuxError(.unauthorized, "no account home directory")
    }
    let helpers = support.appendingPathComponent("Helpers")
    return DurableInstallation(
      guardian: HelperProcessAgent(
        executable: helpers.appendingPathComponent(
          "\(guardianApp)/Contents/MacOS/swiftmux-guardian"
        )
      ),
      gateway: HelperProcessAgent(
        executable: helpers.appendingPathComponent(
          "\(gatewayApp)/Contents/MacOS/swiftmux-gateway"
        )
      ),
      status: GatewayControlStatus(
        controlService: gatewayControl,
        peerRequirement:
          try GuardianPeerSigningPolicy.requirementForCurrentProcess()
      ),
      record: support.appendingPathComponent("durable-install.json")
    )
  }

  /// Copies the signed helpers out of the app, installs its worker build
  /// and writes the guardian's private configuration. Run only while the
  /// helpers are unregistered (before adoption, during maintenance).
  static func prepare() throws {
    guard isShipped, let support else {
      throw MuxError(.notFound, "this app does not carry durable helpers")
    }
    guard
      let requirement =
        try GuardianPeerSigningPolicy.requirementForCurrentProcess()
    else { throw MuxError(.unauthorized, "a team-signed app is required") }
    let manager = FileManager.default
    try manager.createDirectory(
      at: support,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let helpers = support.appendingPathComponent("Helpers")
    try manager.createDirectory(
      at: helpers,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    for name in [guardianApp, gatewayApp] {
      let target = helpers.appendingPathComponent(name)
      let staging = helpers.appendingPathComponent(
        ".\(name)-\(UUID().uuidString)"
      )
      try manager.copyItem(
        at: bundled.appendingPathComponent(name),
        to: staging
      )
      do {
        try GuardianArtifactValidation.validateSignature(
          staging.path,
          requirement: requirement
        )
        if manager.fileExists(atPath: target.path) {
          try manager.removeItem(at: target)
        }
        try manager.moveItem(at: staging, to: target)
      } catch {
        try? manager.removeItem(at: staging)
        throw error
      }
    }
    let versions = support.appendingPathComponent("Versions")
    try? manager.createDirectory(
      at: versions,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let registry = try GuardianBuildRegistry(
      root: versions,
      peerRequirement: requirement
    )
    let worker = bundled.appendingPathComponent(workerApp)
    let manifest = try JSONDecoder()
      .decode(
        GuardianBuildManifest.self,
        from: Data(
          contentsOf: worker.appendingPathComponent(
            "Contents/Resources/build.json"
          )
        )
      )
    if !manager.fileExists(
      atPath: versions.appendingPathComponent(manifest.build).path
    ) {
      try registry.install(bundle: worker, build: manifest.build)
    }
    if try registry.selection().selected == nil {
      try registry.select(manifest.build)
    }
    let configuration = GuardianDaemonConfiguration(
      workerMachService: guardianLabel,
      gatewayMachService: guardianLabel + ".control",
      gatewayIdentifier: gatewayLabel + ".swiftmux-gateway",
      buildRoot: versions.path,
      launcherPath:
        helpers.appendingPathComponent(
          "\(guardianApp)/Contents/MacOS/swmux-launcher"
        )
        .path
    )
    let file = support.appendingPathComponent("guardian.json")
    try JSONEncoder().encode(configuration).write(to: file, options: .atomic)
    guard chmod(file.path, 0o600) == 0 else {
      throw MuxError(.unauthorized, "cannot protect guardian configuration")
    }
  }

  /// An ordinary update from a newer app (spec.durability.md §5.2): stage
  /// its gateway helper and worker build, let the running gateway check
  /// them under the barrier, then swap the gateway bundle.
  static func update(
    _ installer: DurableInstallation
  ) async throws -> DurableInstallation.GatewayUpdate {
    guard isShipped, let support else {
      throw MuxError(.notFound, "this app does not carry durable helpers")
    }
    guard
      let requirement =
        try GuardianPeerSigningPolicy.requirementForCurrentProcess()
    else { throw MuxError(.unauthorized, "a team-signed app is required") }
    let manager = FileManager.default
    let helpers = support.appendingPathComponent("Helpers")
    let current = helpers.appendingPathComponent(gatewayApp)
    let candidate = helpers.appendingPathComponent(".candidate-\(gatewayApp)")
    let previous = helpers.appendingPathComponent(".previous-\(gatewayApp)")
    for stale in [candidate, previous]
    where manager.fileExists(atPath: stale.path) {
      try manager.removeItem(at: stale)
    }
    try manager.copyItem(
      at: bundled.appendingPathComponent(gatewayApp),
      to: candidate
    )
    try GuardianArtifactValidation.validateSignature(
      candidate.path,
      requirement: requirement
    )
    // The worker build ships with the app; the guardian revalidates it.
    let registry = try GuardianBuildRegistry(
      root: support.appendingPathComponent("Versions"),
      peerRequirement: requirement
    )
    let worker = bundled.appendingPathComponent(workerApp)
    let manifest = try JSONDecoder()
      .decode(
        GuardianBuildManifest.self,
        from: Data(
          contentsOf: worker.appendingPathComponent(
            "Contents/Resources/build.json"
          )
        )
      )
    if !manager.fileExists(
      atPath: support.appendingPathComponent("Versions/\(manifest.build)").path
    ) {
      try registry.install(bundle: worker, build: manifest.build)
    }
    let status = GatewayControlStatus(
      controlService: gatewayControl,
      peerRequirement: requirement
    )
    return try await installer.updateGateway(
      GatewayUpdateRequest(
        candidate: candidate.path,
        workerBuild: manifest.build,
        workerProtocol: manifest.workerProtocol
      ),
      through: status,
      agent: HelperProcessAgent(
        executable: current.appendingPathComponent(
          "Contents/MacOS/swiftmux-gateway"
        )
      ),
      install: {
        try FileManager.default.moveItem(at: current, to: previous)
        do {
          try FileManager.default.moveItem(at: candidate, to: current)
        } catch {
          try? FileManager.default.moveItem(at: previous, to: current)
          throw error
        }
        return {
          try FileManager.default.removeItem(at: current)
          try FileManager.default.moveItem(at: previous, to: current)
        }
      }
    )
  }

  /// The monolithic agent this app registered before the transition.
  /// `force` (the user confirmed ending its sessions): an agent that can no
  /// longer be reached (another signing team, or an ad-hoc build launchd
  /// refuses to start) is unregistered, ending its sessions, instead of
  /// blocking the transition.
  struct Legacy: LegacyMux {
    var force = false
    private var service: SMAppService {
      SMAppService.agent(plistName: SMX.agentPlistName)
    }
    func workspaceCount() async throws -> Int {
      guard service.status == .enabled else { return 0 }
      let connection: MuxConnection
      do {
        connection = try await MuxConnection.connect(frontend: .control)
      } catch {
        guard force else {
          throw MuxError(
            .connectionLost,
            "the previous SwiftMux agent cannot be reached (\(error)); confirm ending its sessions to replace it"
          )
        }
        try await service.unregister()
        return 0
      }
      defer { Task { await connection.close() } }
      guard
        case let .workspaces(list) = try await connection.execute(
          .listWorkspaces
        )
      else { throw MuxError(.invalidRequest, "missing workspace list") }
      return list.count
    }
    func endAll() async throws {
      let connection = try await MuxConnection.connect(frontend: .control)
      defer { Task { await connection.close() } }
      _ = try await connection.execute(.endAllWorkspaces)
    }
    func unregister() async throws {
      guard service.status == .enabled || service.status == .requiresApproval
      else { return }
      try await service.unregister()
    }
    func register() async throws { try service.register() }
  }

  /// `swiftty --durable-sessions adopt|maintain|uninstall|status [--confirm]`.
  /// Headless: without `--confirm`, live sessions are never ended.
  static func command(_ arguments: [String]) async -> Int32 {
    guard let action = arguments.first,
      ["adopt", "maintain", "uninstall", "status", "update"].contains(action),
      arguments.count <= 2, arguments.count == 1 || arguments[1] == "--confirm"
    else {
      FileHandle.standardError.write(
        Data(
          "usage: swiftty --durable-sessions adopt|maintain|uninstall|status|update [--confirm]\n"
            .utf8
        )
      )
      return 64
    }
    let confirmed = arguments.count == 2
    let confirm: DurableInstallation.Confirm = { _ in confirmed }
    do {
      let installer = try installer()
      switch action {
      case "adopt":
        // Never replace a live installation's helpers outside an update.
        guard !isInstalled else {
          throw MuxError(.invalidRequest, "the durable topology is installed")
        }
        try prepare()
        print(
          try await installer.adopt(
            from: Legacy(force: confirmed),
            confirm: confirm
          )
        )
      case "maintain":
        print(
          try await installer.maintainGuardian(confirm: confirm) {
            try prepare()
          }
        )
      case "uninstall": print(try await installer.uninstall(confirm: confirm))
      case "update": print(try await update(installer))
      default: print(try await installer.startup())
      }
      return 0
    } catch {
      FileHandle.standardError.write(Data("swiftty: \(error)\n".utf8))
      return 1
    }
  }

  /// What to tell the user at launch. Never a restoration claim; never a
  /// local-shell fallback when the gateway is unreachable.
  static func startupNotice() async -> String? {
    guard isInstalled, let installer = try? installer(),
      let startup = try? await installer.startup()
    else { return nil }
    switch startup {
    case .sessionsEnded:
      return String(
        localized:
          "SwiftMux restarted, so the sessions that were running have ended. Saved workspaces can be reopened from the Workspace menu."
      )
    case .unavailable:
      return String(
        localized:
          "SwiftMux is not running. Sessions will be available once its background helpers start."
      )
    case let .interrupted(phase):
      return String(
        localized:
          "A SwiftMux installation step did not finish (\(phase.rawValue)). Run the installer again."
      )
    case .notInstalled, .running: return nil
    }
  }
}
