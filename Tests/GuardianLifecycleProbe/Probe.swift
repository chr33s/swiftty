import Darwin
import Foundation
import ServiceManagement
import SwiftMuxClient
import SwiftMuxProtocol
import SwiftMuxService

/// Qualification host only. An independently registered existing mux proves
/// launchd ownership before the production PTY/worker split is introduced.
@main
enum GuardianLifecycleProbe {
  static func main() async {
    do { try await run() } catch {
      FileHandle.standardError.write(Data("probe: \(error)\n".utf8))
      exit(1)
    }
  }

  static func run() async throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first,
      let label = Bundle.main.object(forInfoDictionaryKey: "ProbeService")
        as? String, label.hasPrefix("com.chr33s.swiftty.durability-probe.")
    else { throw MuxError(.invalidRequest, "run from a qualification bundle") }
    let registration = SMAppService.agent(plistName: label + ".plist")
    switch command {
    case "register":
      try registration.register()
      print(registration.status.rawValue)
    case "unregister": try await registration.unregister()
    case "registration-status": print(registration.status.rawValue)
    case "serve": try await serve(label)
    case "serve-guardian": try await serveGuardian(label)
    case "serve-workspace-guardian":
      try await serveGuardian(label, workspaceWorker: true)
    case "serve-workspace-gateway": try await serveWorkspaceGateway()
    case "serve-build-guardian": try await serveBuildGuardian(label)
    case "prepare-guardian-daemon": try prepareGuardianDaemon(label)
    case "check-gateway-access":
      guard args.count == 2,
        args[1].hasPrefix("com.chr33s.swiftty.durability-probe.")
      else {
        throw MuxError(.invalidRequest, "missing qualification control service")
      }
      try await checkGatewayAccess(args[1])
    case "native-client": try await nativeGatewayClient(args)
    case "validate-gateway-candidate", "stage-gateway-candidate":
      try validateGatewayCandidate(args)
    case "worker": try await runWorker()
    case "status", "create", "send", "end":
      guard args.count >= 2,
        args[1].hasPrefix("com.chr33s.swiftty.durability-probe.")
      else { throw MuxError(.invalidRequest, "missing probe service") }
      let connection = try await MuxConnection.connect(
        machService: args[1],
        frontend: .native
      )
      do {
        switch command {
        case "status":
          let response = try await connection.execute(.status)
          print(
            String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
          )
        case "create":
          let response = try await connection.execute(
            .newWorkspace(
              NewWorkspaceRequest(
                name: "durability-probe",
                launch: LaunchSpec(command: ["/bin/sh", "-i"])
              )
            )
          )
          print(
            String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
          )
        case "send":
          guard args.count == 4 else {
            throw MuxError(
              .invalidRequest,
              "send requires shell input and receipt path"
            )
          }
          guard
            case let .attached(_, workspace) = try await connection.execute(
              .attach(AttachRequest(.name("durability-probe")))
            )
          else { throw MuxError(.invalidRequest, "missing attachment") }
          guard let tab = workspace.tabs.first else {
            throw MuxError(.invalidRequest, "missing pane")
          }
          _ = try await connection.execute(.setSubscriptions([tab.activePane]))
          try await connection.send(.text(args[2]), to: tab.activePane)
          try await connection.send(.key(.enter, []), to: tab.activePane)
          let deadline = ContinuousClock.now + .seconds(10)
          while (try? String(contentsOfFile: args[3], encoding: .utf8))
            != "done"
          {
            guard ContinuousClock.now < deadline else {
              throw MuxError(.invalidRequest, "shell input receipt timed out")
            }
            try await Task.sleep(for: .milliseconds(10))
          }
        default: _ = try await connection.execute(.endAllWorkspaces)
        }
        await connection.close()
      } catch {
        await connection.close()
        throw error
      }
    default: throw MuxError(.invalidRequest, "unknown probe command")
    }
  }

  static func serve(_ label: String) async throws {
    let launcher = Bundle.main.bundleURL
      .appendingPathComponent("Contents/MacOS/swmux-launcher").path
    var configuration = MuxServiceConfiguration(launcherPath: launcher)
    configuration.peerRequirement =
      try PeerSigningPolicy.requirementForCurrentProcess()
    let service = try MuxService(configuration: configuration)
    signal(SIGPIPE, SIG_IGN)
    let signals = [SIGTERM, SIGINT]
      .map { number in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(
          signal: number,
          queue: .global()
        )
        source.setEventHandler { service.prepareToExit { exit(0) } }
        source.resume()
        return source
      }
    service.listen(machService: label)
    // The async entry point must keep its sources/service alive while the
    // main executor remains available for Service Management callbacks.
    while true {
      try await Task.sleep(for: .seconds(30))
      withExtendedLifetime((service, signals)) {}
    }
  }
}
