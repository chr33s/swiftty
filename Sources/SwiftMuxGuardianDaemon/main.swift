import Darwin
import Dispatch
import Foundation
import SwiftMuxGuardian

// launchd owns this process directly. Its private installation configuration is
// explicit; there is no environment-selected service or local-shell fallback.
guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--config"
else {
  FileHandle.standardError.write(
    Data("usage: swiftmux-guardian --config ABSOLUTE_PATH\n".utf8)
  )
  exit(64)
}
do {
  let configuration = try GuardianDaemonConfiguration.load(
    path: CommandLine.arguments[2]
  )
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
