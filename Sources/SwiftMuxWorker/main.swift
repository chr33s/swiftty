import Darwin
import Dispatch
import Foundation
import SwiftMuxGuardian
import SwiftMuxService

// No command-line bootstrap or fallback. Only the guardian can supply the
// one-use admission token through its private inherited descriptor.
guard CommandLine.arguments.count == 1 else { exit(64) }
do {
  let bootstrap = try GuardianWorkerBootstrap.read()
  let launcher = URL(fileURLWithPath: CommandLine.arguments[0])
    .standardizedFileURL.deletingLastPathComponent()
    .appendingPathComponent("swmux-launcher").path
  let host = try WorkspaceWorkerHost(
    workspace: bootstrap.workspace,
    launcherPath: launcher,
    peerRequirement: bootstrap.peerRequirement,
    connect: { queue, handlers in
      try bootstrap.connect(queue: queue, handlers: handlers)
    },
    ready: { _ in },
    unavailable: { _ in exit(75) },
    candidate: bootstrap.migration,
    // Retired after a planned replacement: the guardian keeps every process.
    retired: { exit(0) }
  )
  withExtendedLifetime(host) { dispatchMain() }
} catch {
  FileHandle.standardError.write(
    Data("swiftmux-worker: bootstrap or initialization failed\n".utf8)
  )
  exit(78)
}
