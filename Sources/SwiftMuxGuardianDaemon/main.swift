import Darwin
import Dispatch
import Foundation
import ServiceManagement
import SwiftMuxGuardian

// The installer asks the helper to register its own agent (spec.durability.md
// §9): only this bundle can name its embedded LaunchAgent.
if CommandLine.arguments.count == 2,
  ["register", "unregister", "status"].contains(CommandLine.arguments[1])
{
  exit(HelperAgentCommand.run(CommandLine.arguments[1]))
}

// launchd owns this process directly. Its private installation configuration is
// explicit; there is no environment-selected service or local-shell fallback.
// `--support-config` names the owner's SwiftMux support directory, resolved
// from the account database, because a signed agent plist cannot carry a
// per-user path.
let configPath: String
switch CommandLine.arguments.count {
case 3 where CommandLine.arguments[1] == "--config":
  configPath = CommandLine.arguments[2]
case 2 where CommandLine.arguments[1] == "--support-config":
  guard let home = HelperAgentCommand.accountHome() else { exit(78) }
  configPath = home + "/Library/Application Support/SwiftMux/guardian.json"
default:
  FileHandle.standardError.write(
    Data(
      "usage: swiftmux-guardian --config ABSOLUTE_PATH | --support-config | register | unregister | status\n"
        .utf8
    )
  )
  exit(64)
}
do {
  let configuration = try GuardianDaemonConfiguration.load(path: configPath)
  guard
    let requirement =
      try GuardianPeerSigningPolicy.requirementForCurrentProcess()
  else {
    FileHandle.standardError.write(
      Data("swiftmux-guardian: a team-signed helper is required\n".utf8)
    )
    exit(78)
  }
  let host = try GuardianHost(
    configuration: configuration,
    signingRequirement: requirement
  )
  signal(SIGPIPE, SIG_IGN)
  let signals = [SIGTERM, SIGINT]
    .map { number in
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(
        signal: number,
        queue: .global()
      )
      source.setEventHandler { host.shutdown { exit(0) } }
      source.resume()
      return source
    }
  host.start()
  withExtendedLifetime((host, signals)) { dispatchMain() }
} catch {
  FileHandle.standardError.write(
    Data(
      "swiftmux-guardian: installation configuration or signing validation failed: \(error)\n"
        .utf8
    )
  )
  exit(78)
}
