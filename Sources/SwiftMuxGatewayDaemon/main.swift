import Darwin
import Dispatch
import Foundation
import SwiftMuxGateway
import SwiftMuxGatewayRoaming
import SwiftMuxGuardian
import TerminalHost

// This is a separate native control service, not a replacement registration for
// the legacy SMX agent. Installation must explicitly choose the durable topology.
if CommandLine.arguments.count == 2,
  ["register", "unregister", "status"].contains(CommandLine.arguments[1])
{
  exit(HelperAgentCommand.run(CommandLine.arguments[1]))
}
// Remote clients (spec.roaming.md): the same configuration `swifttyd
// bootstrap` reads. Roaming is optional: an absent or unreadable
// configuration disables it, never the gateway's native service.
let hostConfiguration: HostConfiguration?
do {
  let url = HostConfiguration.resolvedConfigurationURL()
  hostConfiguration = try HostConfiguration.loadForStartup(
    from: url,
    required:
      !(ProcessInfo.processInfo.environment[HostConfiguration.environmentKey]
      ?? "")
      .isEmpty
  )
} catch {
  FileHandle.standardError.write(
    Data(
      "swiftmux-gateway: roaming disabled: cannot read its configuration: \(error)\n"
        .utf8
    )
  )
  hostConfiguration = nil
}

do {
  let configuration = try GatewayDaemonConfiguration(
    arguments: Array(CommandLine.arguments.dropFirst())
  )
  guard
    let requirement =
      try GuardianPeerSigningPolicy.requirementForCurrentProcess()
  else {
    FileHandle.standardError.write(
      Data("swiftmux-gateway: a team-signed helper is required\n".utf8)
    )
    exit(78)
  }
  signal(SIGPIPE, SIG_IGN)
  signal(SIGTERM, SIG_IGN)
  signal(SIGINT, SIG_IGN)
  let task = Task.detached {
    var runtime: GatewayRuntime?
    var server: GatewayControlServer?
    var roaming: Task<RoamingHost?, Never>?
    var status: Int32 = 0
    do {
      let supervisor = try await GatewaySupervisor.connect(
        peerRequirement: configuration.guardianRequirement(
          teamRequirement: requirement
        ),
        channel: {
          .connect(machService: configuration.guardianService, queue: $0)
        }
      )
      // Saved layouts (spec.durability.md §12.2): sealed records under the
      // user's SwiftMux support directory, keyed from the login keychain.
      // A signed bundle may pin another absolute root (qualification
      // fixtures do, so they never touch the owner's real store).
      let support =
        (Bundle.main.object(forInfoDictionaryKey: "SwiftMuxSupportDirectory")
        as? String)
        .flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
        ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SwiftMux")
      let identifier = Bundle.main.bundleIdentifier ?? "dev.chr33s.swiftmux"
      let saved = SavedLayoutService(
        files: SavedLayoutFiles(root: support),
        keys: LoginKeychainKeyStore(service: "\(identifier).saved-workspaces"),
        build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
          as? String ?? "unknown"
      )
      // Finish an update this gateway was installed by (§5.2 steps 5–6)
      // before serving frontends. An unverifiable successor leaves the
      // barrier paused for the installer.
      var upgrade: String?
      if let own = runningGatewayBuild() {
        let updater = GatewayUpdater(
          supervisor: supervisor,
          plans: GatewayUpdatePlanStore(root: support),
          replacement: InstallerRequiredReplacement()
        )
        // A failure here leaves the barrier as it was (the next start or the
        // installer retries); it never keeps this gateway from serving.
        do {
          let outcome = try await updater.complete(
            ownBuild: own.build,
            ownProtocols: Set(own.workerProtocols)
          )
          if case let .completed(plan) = outcome { upgrade = plan.workerBuild }
        } catch {
          FileHandle.standardError.write(
            Data("swiftmux-gateway: update not finished: \(error)\n".utf8)
          )
        }
      }
      let started = try await GatewayRuntime.start(
        supervisor: supervisor,
        peerRequirement: requirement,
        saved: saved
      )
      runtime = started
      if runningGatewayBuild() != nil {
        await started.setUpdateHandler(
          try GatewayDaemonUpdate.handler(
            supervisor: supervisor,
            configuration: configuration,
            teamRequirement: requirement,
            plans: GatewayUpdatePlanStore(root: support)
          )
        )
      }
      if let upgrade {
        // Capability B after the update: deferred per workspace on refusal.
        Task.detached { _ = await started.upgradeWorkspaces(to: upgrade) }
      }
      try Task.checkCancellation()
      let control = GatewayControlServer(
        runtime: started,
        peerRequirement: requirement
      )
      server = control
      control.listen(machService: configuration.controlService)
      if let hostConfiguration {
        roaming = Task { await serveRoaming(hostConfiguration, started) }
      }
      while true {
        try Task.checkCancellation()
        if let failure = await started.failure { throw failure }
        try await Task.sleep(for: .milliseconds(250))
      }
    } catch {
      if !Task.isCancelled {
        status = 75
        FileHandle.standardError.write(
          Data("swiftmux-gateway: \(error)\n".utf8)
        )
      }
    }
    // Drain native work before releasing guardian authority. Neither action ends
    // a workspace; launchd may restart this gateway and rediscover the sessions.
    // Serving until here; releasing it stops the listener and control
    // socket before native work drains.
    // Stops the listener and control socket before native work drains.
    roaming?.cancel()
    _ = await roaming?.value
    await server?.close()
    await runtime?.close()
    exit(status)
  }
  let signals = [SIGTERM, SIGINT]
    .map { number in
      let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
      source.setEventHandler { task.cancel() }
      source.resume()
      return source
    }
  withExtendedLifetime((task, signals)) { dispatchMain() }
} catch {
  FileHandle.standardError.write(
    Data(
      "swiftmux-gateway: invalid installation configuration: \(error)\n".utf8
    )
  )
  exit(78)
}

/// Serves roaming clients until cancelled. A failure to start (the port is
/// in use, the certificate cannot be prepared) is retried in the background;
/// it never takes the native service down with it.
func serveRoaming(
  _ configuration: HostConfiguration,
  _ runtime: GatewayRuntime
) async -> RoamingHost? {
  var host: RoamingHost?
  while !Task.isCancelled {
    if host == nil {
      do {
        let workspaces = try await GatewayRoamingWorkspaces.make(
          runtime: runtime
        )
        host = try await RoamingHost.start(
          workspaces: { workspaces },
          configuration: configuration
        )
      } catch {
        if Task.isCancelled { break }
        FileHandle.standardError.write(
          Data(
            "swiftmux-gateway: roaming unavailable, retrying: \(error)\n".utf8
          )
        )
      }
    }
    try? await Task.sleep(for: host == nil ? .seconds(30) : .seconds(3600))
  }
  // Released here: its deinit stops the listener and control socket.
  withExtendedLifetime(host) {}
  return nil
}
