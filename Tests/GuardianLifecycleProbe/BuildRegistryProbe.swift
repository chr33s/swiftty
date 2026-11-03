import Darwin
import Dispatch
import Foundation
import SwiftMuxGateway
import SwiftMuxGuardian
import SwiftMuxProtocol
import SwiftMuxService

extension GuardianLifecycleProbe {
  private static func updateBuildSelection(
    service: String,
    requirement: String?,
    build: String?
  ) async throws {
    let supervisor = try await GatewaySupervisor.connect(
      peerRequirement: requirement,
      channel: { .connect(machService: service, queue: $0) }
    )
    do {
      let status = try await supervisor.admissionStatus()
      let paused = try await supervisor.setAdmissionPaused(
        true,
        expectedRevision: status.revision
      )
      let result: GuardianAdmissionStatus
      if let build {
        result = try await supervisor.selectWorkerBuild(
          build,
          expectedRevision: paused.revision
        )
      } else {
        result = try await supervisor.clearWorkerRollback(
          expectedRevision: paused.revision
        )
      }
      let selection = try await supervisor.workerSelection()
      guard
        build.map({ selection.selected == $0 }) ?? (selection.rollback == nil)
      else {
        throw MuxError(.invalidRequest, "selection outcome did not match")
      }
      _ = try await supervisor.setAdmissionPaused(
        false,
        expectedRevision: result.revision
      )
      await supervisor.close()
    } catch {
      await supervisor.close()
      throw error
    }
  }

  static func prepareGuardianDaemon(_ label: String) throws {
    let root = try evidenceRoot().resolvingSymlinksInPath()
    guard
      let gatewayIdentifier = Bundle.main.object(
        forInfoDictionaryKey: "ProbeGatewayIdentifier"
      ) as? String
    else {
      throw MuxError(
        .invalidRequest,
        "missing qualification gateway identifier"
      )
    }
    let registry = try GuardianBuildRegistry(
      root: root.appendingPathComponent("Versions"),
      peerRequirement: PeerSigningPolicy.requirementForCurrentProcess()
    )
    try registry.install(
      bundle: root.appendingPathComponent("Staged-one.app"),
      build: "one"
    )
    try registry.select("one")
    let configuration = GuardianDaemonConfiguration(
      workerMachService: label,
      gatewayMachService: label + ".control",
      gatewayIdentifier: gatewayIdentifier,
      buildRoot: root.appendingPathComponent("Versions").path,
      launcherPath: Bundle.main.bundleURL
        .appendingPathComponent("Contents/MacOS/swmux-launcher").path
    )
    let file = root.appendingPathComponent("guardian-config.json")
    try JSONEncoder().encode(configuration).write(to: file, options: .atomic)
    guard chmod(file.path, 0o600) == 0 else {
      throw MuxError(.unauthorized, "cannot protect daemon configuration")
    }
  }

  /// Installer commands below are fixture-owned files in a unique private
  /// directory. They are not exposed by the product gateway protocol.
  static func serveBuildGuardian(_ label: String) async throws {
    let root = try evidenceRoot().resolvingSymlinksInPath()
    let requirement = try PeerSigningPolicy.requirementForCurrentProcess()
    let registry = try GuardianBuildRegistry(
      root: root.appendingPathComponent("Versions"),
      peerRequirement: requirement
    )
    for build in ["one", "two"] {
      try registry.install(
        bundle: root.appendingPathComponent("Staged-\(build).app"),
        build: build
      )
    }
    try registry.select("one")
    let server = try GuardianServer(
      launcherPath: Bundle.main.bundleURL
        .appendingPathComponent("Contents/MacOS/swmux-launcher").path,
      peerRequirement: requirement
    )
    let control = GuardianGatewayServer(
      guardian: server,
      peerRequirement: requirement,
      buildRegistry: registry,
      workerMachService: label
    )
    server.listen(machService: label)
    control.listen(machService: label + ".control")
    signal(SIGPIPE, SIG_IGN)
    let signals = [SIGTERM, SIGINT]
      .map { number in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(
          signal: number,
          queue: .global()
        )
        source.setEventHandler { server.shutdown { exit(0) } }
        source.resume()
        return source
      }
    while true {
      if takeMarker("select-two", root: root) {
        try await updateBuildSelection(
          service: label + ".control",
          requirement: requirement,
          build: "two"
        )
        try Data("two".utf8)
          .write(to: root.appendingPathComponent("selected"), options: .atomic)
      }
      if takeMarker("collect-one", root: root) {
        try await updateBuildSelection(
          service: label + ".control",
          requirement: requirement,
          build: nil
        )
        let result: String
        do {
          try registry.remove("one");
          result = "collected"
        } catch let error as MuxError where error.code == .quiescing {
          result = "pinned"
        }
        try Data(result.utf8)
          .write(
            to: root.appendingPathComponent("collection"),
            options: .atomic
          )
      }
      if takeMarker("end-all", root: root) {
        for workspace in server.inventory() {
          server.endWorkspace(workspace.authority.workspace)
        }
      }
      let inventory = server.inventory()
      try JSONEncoder().encode(inventory)
        .write(
          to: root.appendingPathComponent("inventory.json"),
          options: .atomic
        )
      if takeMarker("forget-all", root: root) {
        for workspace in inventory {
          try server.forgetWorkspace(workspace.authority.workspace)
        }
        try Data("done".utf8)
          .write(to: root.appendingPathComponent("forgotten"), options: .atomic)
      }
      try await Task.sleep(for: .milliseconds(25))
      withExtendedLifetime((server, control, registry, signals)) {}
    }
  }

  private static func takeMarker(_ name: String, root: URL) -> Bool {
    let file = root.appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: file.path) else {
      return false
    }
    return (try? FileManager.default.removeItem(at: file)) != nil
  }
}
