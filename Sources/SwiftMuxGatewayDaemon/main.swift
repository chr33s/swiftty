import Darwin
import Dispatch
import Foundation
import SwiftMuxGateway
import SwiftMuxGuardian

// This is a separate native control service, not a replacement registration for
// the legacy SMX agent. Installation must explicitly choose the durable topology.
if CommandLine.arguments.count == 2,
  ["register", "unregister", "status"].contains(CommandLine.arguments[1])
{
  exit(HelperAgentCommand.run(CommandLine.arguments[1]))
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
