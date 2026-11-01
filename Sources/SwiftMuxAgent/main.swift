// swiftmux-agent: the per-user SwiftMux LaunchAgent.
//
// Runs directly under launchd (no self-forking or daemonization) and
// serves one Mach/XPC endpoint. With a roaming configuration it also
// serves remote clients (SSH bootstrap + QUIC RST/1) from the same
// process, so local and remote attachments share one set of panes
// (spec.inbox.md §1). It exits only at the ordered empty-state barrier,
// after an idle delay that respects launchd's launch throttling, and
// never while serving roaming clients.
import Darwin
import Foundation
import SwiftMuxProtocol
import SwiftMuxService
import TerminalHost

func usage() -> Never {
  FileHandle.standardError.write(
    Data(
      """
      usage: swiftmux-agent [--mach-service NAME] [--launcher PATH] [--idle-exit SECONDS|never]
                            [--roaming-config PATH | --no-roaming]

      """
      .utf8
    )
  )
  exit(64)
}

var machService =
  ProcessInfo.processInfo.environment["SWMUX_SERVICE"] ?? SMX.defaultMachService
var launcherPath: String?
var idleExit: TimeInterval? = 30
/// Explicit paths are required; only a missing default disables roaming.
var roamingConfig: URL? = HostConfiguration.resolvedConfigurationURL()
var requiredRoamingConfig =
  !(ProcessInfo.processInfo.environment[HostConfiguration.environmentKey] ?? "")
  .isEmpty
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
  switch arg {
  case "--mach-service":
    guard let value = args.popFirst() else { usage() }
    machService = value
  case "--launcher":
    guard let value = args.popFirst() else { usage() }
    launcherPath = value
  case "--idle-exit":
    guard let value = args.popFirst() else { usage() }
    if value == "never" {
      idleExit = nil
    } else {
      guard let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0
      else { usage() }
      idleExit = seconds
    }
  case "--roaming-config":
    guard let value = args.popFirst() else { usage() }
    roamingConfig = URL(fileURLWithPath: value)
    requiredRoamingConfig = true
  case "--no-roaming": roamingConfig = nil
  default: usage()
  }
}

// Validate before launcher, terminfo, signing or service initialization.
let hostConfiguration: HostConfiguration?
do {
  hostConfiguration = try HostConfiguration.loadForStartup(
    from: roamingConfig,
    required: requiredRoamingConfig
  )
} catch {
  FileHandle.standardError.write(
    Data(
      "swiftmux-agent: cannot read roaming configuration at \(roamingConfig?.path ?? ""); bindAddress and advertisedHost must be set explicitly\n"
        .utf8
    )
  )
  exit(78)
}

/// The launcher ships beside the agent (Contents/MacOS in the app bundle).
func siblingLauncher() -> String {
  let exe =
    Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
  return exe.resolvingSymlinksInPath().deletingLastPathComponent()
    .appending(path: "swmux-launcher").path
}

let launcher = launcherPath ?? siblingLauncher()
guard FileManager.default.isExecutableFile(atPath: launcher) else {
  FileHandle.standardError.write(
    Data("swiftmux-agent: launcher not found at \(launcher)\n".utf8)
  )
  exit(69)
}

var configuration = MuxServiceConfiguration(launcherPath: launcher)
configuration.javaScriptDirectory = FileManager.default
  .homeDirectoryForCurrentUser.appendingPathComponent(
    ".config/swiftty",
    isDirectory: true
  )
do {
  configuration.peerRequirement =
    try PeerSigningPolicy.requirementForCurrentProcess()
} catch {
  FileHandle.standardError.write(
    Data(
      "swiftmux-agent: cannot establish peer signing policy: \(error)\n".utf8
    )
  )
  exit(78)
}
let terminfo = InnerTerminfo.defaultDirectory
if InnerTerminfo.install(into: terminfo) {
  configuration.innerTerm = SMX.innerTerm
  configuration.terminfoDirectory = terminfo.path
}
// Remote clients need the listener up while no local client is around.
configuration.idleExitDelay = hostConfiguration == nil ? idleExit : nil

// Never let SIGPIPE from a closed peer or PTY kill the service.
signal(SIGPIPE, SIG_IGN)
let service = try MuxService(configuration: configuration)
// launchd bootout sends SIGTERM. Closing PTYs alone cannot retire a pane
// that ignores SIGHUP, so keep the agent alive through its process barrier.
let terminationSources = [SIGTERM, SIGINT]
  .map { sig in
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    source.setEventHandler { @Sendable [service] in
      service.prepareToExit { exit(0) }
    }
    return source
  }
terminationSources.forEach { $0.resume() }
service.listen(machService: machService)
service.setIdleHandler { exit(0) }

enum Roaming { nonisolated(unsafe) static var host: RoamingHost? }

if let config = hostConfiguration {
  Task {
    do {
      Roaming.host = try await RoamingHost.start(
        service: service,
        configuration: config
      )
    } catch {
      FileHandle.standardError.write(
        Data("swiftmux-agent: roaming unavailable: \(error)\n".utf8)
      )
      exit(1)
    }
  }
}
withExtendedLifetime(terminationSources) { dispatchMain() }
