import Darwin
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
import SwiftMuxService

/// Qualification of the durable installer (spec.durability.md §9, UA8) with
/// isolated fixture agents. Each helper bundle registers its own agent, as
/// the production helpers do.
extension GuardianLifecycleProbe {
  struct BundleAgent: DurableAgent, LegacyRegistration {
    let app: URL
    func register() async throws { try Self.run(app, "register") }
    func unregister() async throws { try Self.run(app, "unregister") }

    static func run(_ app: URL, _ command: String) throws {
      let process = Process()
      process.executableURL = app.appendingPathComponent("Contents/MacOS/probe")
      process.arguments = [command]
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw MuxError(.launchFailed, "\(command) failed for \(app.path)")
      }
    }
  }

  protocol LegacyRegistration: Sendable {
    func register() async throws
    func unregister() async throws
  }

  struct ProbeLegacy: LegacyMux {
    let service: String
    let registration: BundleAgent
    private func connect() async throws -> MuxConnection {
      try await MuxConnection.connect(machService: service, frontend: .native)
    }
    func workspaceCount() async throws -> Int {
      let connection = try await connect()
      defer { Task { await connection.close() } }
      guard
        case let .workspaces(list) = try await connection.execute(
          .listWorkspaces
        )
      else { throw MuxError(.invalidRequest, "missing legacy workspaces") }
      return list.count
    }
    func endAll() async throws {
      let connection = try await connect()
      defer { Task { await connection.close() } }
      _ = try await connection.execute(.endAllWorkspaces)
    }
    func unregister() async throws { try await registration.unregister() }
    func register() async throws { try await registration.register() }
  }

  /// `durable-install ACTION LEGACY-SERVICE LEGACY-APP GUARDIAN-APP
  /// GATEWAY-APP CONTROL-SERVICE RECORD confirm|decline`
  static func durableInstall(_ args: [String]) async throws {
    guard args.count == 9,
      ["adopt", "maintain", "uninstall", "startup"].contains(args[1]),
      args[2].hasPrefix("com.chr33s.swiftty.durability-probe."),
      args[6].hasPrefix("com.chr33s.swiftty.durability-probe."),
      ["confirm", "decline"].contains(args[8])
    else { throw MuxError(.invalidRequest, "invalid installer arguments") }
    let legacy = ProbeLegacy(
      service: args[2],
      registration: BundleAgent(app: URL(fileURLWithPath: args[3]))
    )
    // The production adapters: each helper registers its own agent; status
    // comes from the gateway's native control.
    func helper(_ path: String) -> HelperProcessAgent {
      HelperProcessAgent(
        executable: URL(fileURLWithPath: path)
          .appendingPathComponent("Contents/MacOS/probe")
      )
    }
    let installer = DurableInstallation(
      guardian: helper(args[4]),
      gateway: helper(args[5]),
      status: GatewayControlStatus(
        controlService: args[6],
        peerRequirement: try PeerSigningPolicy.requirementForCurrentProcess()
      ),
      record: URL(fileURLWithPath: args[7])
    )
    let answer = args[8] == "confirm"
    let confirm: DurableInstallation.Confirm = { _ in answer }
    let summary: String
    switch args[1] {
    case "adopt":
      summary = describe(
        try await installer.adopt(from: legacy, confirm: confirm)
      )
    case "maintain":
      summary = describe(
        try await installer.maintainGuardian(confirm: confirm, replace: {})
      )
    case "uninstall":
      summary = describe(try await installer.uninstall(confirm: confirm))
    default:
      switch try await installer.startup() {
      case .notInstalled: summary = "not-installed"
      case let .running(guardian): summary = "running:\(guardian)"
      case let .sessionsEnded(previous, guardian):
        summary =
          "sessions-ended:\(previous.map(\.uuidString) ?? "-"):\(guardian)"
      case .unavailable: summary = "unavailable"
      case let .interrupted(phase): summary = "interrupted:\(phase.rawValue)"
      }
    }
    print(summary)
  }

  private static func describe(_ outcome: DurableInstallation.Outcome) -> String
  {
    switch outcome {
    case let .installed(guardian): "installed:\(guardian)"
    case let .maintained(guardian): "maintained:\(guardian)"
    case .uninstalled: "uninstalled"
    case let .declined(count): "declined:\(count)"
    }
  }
}
