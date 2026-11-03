import AppKit
import Foundation
import ServiceManagement
import SwiftMuxClient
import SwiftMuxGuardian
import SwiftMuxProtocol

// `swiftty --swiftmux-agent register|unregister|status` manages the bundled
// SwiftMux LaunchAgent without opening windows (packaging checks, scripts).
let arguments = CommandLine.arguments
let gatewayService: String?
do {
  gatewayService = try GatewayLaunchOptions.service(
    arguments: Array(arguments.dropFirst())
  )
} catch {
  FileHandle.standardError.write(Data("swiftty: \(error)\n".utf8))
  exit(64)
}
// Query before replacing the bundle: another copy or a command-line process
// with the same executable name must not suppress opening this installation.
if arguments.dropFirst().first == "--running-app" {
  guard arguments.count == 3 else {
    FileHandle.standardError.write(
      Data("usage: swiftty --running-app APP_PATH\n".utf8)
    )
    exit(64)
  }
  let requested = URL(fileURLWithPath: arguments[2]).standardizedFileURL
    .resolvingSymlinksInPath().path
  let running = NSWorkspace.shared.runningApplications.contains { application in
    application.processIdentifier != ProcessInfo.processInfo.processIdentifier
      && !application.isTerminated
      && application.bundleURL?.standardizedFileURL.resolvingSymlinksInPath()
        .path == requested
  }
  print(running ? "running" : "stopped")
  exit(0)
}
if let i = arguments.firstIndex(of: "--swiftmux-agent") {
  let service = SMAppService.agent(plistName: SMX.agentPlistName)
  func describe(_ status: SMAppService.Status) -> String {
    switch status {
    case .enabled: "enabled"
    case .requiresApproval: "requiresApproval"
    case .notFound: "notFound"
    case .notRegistered: "notRegistered"
    @unknown default: "unknown"
    }
  }
  let action = i + 1 < arguments.count ? arguments[i + 1] : "status"
  do {
    switch action {
    case "register": try service.register()
    case "unregister":
      try AgentUnregisterWait.run { completion in
        service.unregister(completionHandler: completion)
      }
    case "status": break
    default:
      FileHandle.standardError.write(
        Data(
          "usage: swiftty --swiftmux-agent register|unregister|status\n".utf8
        )
      )
      exit(64)
    }
    print(describe(service.status))
    exit(0)
  } catch {
    print(
      "\(action) failed: \(error.localizedDescription); status \(describe(service.status))"
    )
    exit(1)
  }
}

let app = NSApplication.shared
let gatewayApplication = gatewayService.map { service in
  MuxGatewayApplication(connect: {
    try await MuxGatewayConnection.connect(
      peerRequirement: GuardianPeerSigningPolicy.requirementForCurrentProcess(),
      channel: { .connect(machService: service, queue: $0) }
    )
  })
}
let delegate = AppDelegate(gatewayApplication: gatewayApplication)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
