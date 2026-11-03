import Darwin
import Dispatch
import Foundation
import SwiftMuxGateway
import SwiftMuxGuardian

// This is a separate native control service, not a replacement registration for
// the legacy SMX agent. Installation must explicitly choose the durable topology.
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
      let started = try await GatewayRuntime.start(
        supervisor: supervisor,
        peerRequirement: requirement
      )
      runtime = started
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
