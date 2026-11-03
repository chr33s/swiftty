import Darwin
import Dispatch
import Foundation
import SwiftMuxGuardian
import SwiftMuxProtocol
import SwiftMuxService

// Signed separate-process transport qualification. This fixture intentionally
// has no terminal emulator, graph, or production gateway routing.
extension GuardianLifecycleProbe {
  static func evidenceRoot() throws -> URL {
    guard
      let path = Bundle.main.object(forInfoDictionaryKey: "ProbeEvidence")
        as? String, path.hasPrefix("/")
    else { throw MuxError(.invalidRequest, "missing evidence directory") }
    return URL(fileURLWithPath: path, isDirectory: true)
  }

  static func serveGuardian(
    _ label: String,
    workspaceWorker: Bool = false
  ) async throws {
    let root = try evidenceRoot()
    let server = try GuardianServer(
      launcherPath: Bundle.main.bundleURL
        .appendingPathComponent("Contents/MacOS/swmux-launcher").path,
      peerRequirement: try PeerSigningPolicy.requirementForCurrentProcess()
    )
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
    server.listen(machService: label)
    let control =
      workspaceWorker
      ? GuardianGatewayServer(
        guardian: server,
        peerRequirement: try PeerSigningPolicy.requirementForCurrentProcess()
      ) : nil
    control?.listen(machService: label + ".control")
    let workspace = WorkspaceID()
    server.launchWorker(
      workspace: workspace,
      executable: workspaceWorker
        ? Bundle.main.executableURL!.deletingLastPathComponent()
          .appendingPathComponent("swiftmux-worker").path
        : Bundle.main.executableURL!.path,
      arguments: workspaceWorker ? [] : ["worker"],
      build: "signed-probe-1",
      machService: label
    ) { result in
      if case let .failure(error) = result {
        try? Data(error.description.utf8)
          .write(
            to: root.appendingPathComponent("launch-error.txt"),
            options: .atomic
          )
      }
    }
    var ending = false
    while true {
      if !ending,
        FileManager.default.fileExists(
          atPath: root.appendingPathComponent("end").path
        )
      {
        ending = true
        server.endWorkspace(workspace)
      }
      let inventory = server.inventory().first
      let values = Snapshot(
        guardian: getpid(),
        worker: inventory?.worker?.pid,
        shell: inventory?.panes.first?.pid,
        available: inventory?.available ?? false,
        workerFinished: inventory?.worker?.finished ?? false,
        shellFinished: inventory?.panes.first?.finished ?? false
      )
      try JSONEncoder().encode(values)
        .write(
          to: root.appendingPathComponent("guardian.json"),
          options: .atomic
        )
      try await Task.sleep(for: .milliseconds(50))
      withExtendedLifetime((server, control, signals)) {}
    }
  }

  static func runWorker() async throws {
    let bootstrap = try GuardianWorkerBootstrap.read()
    let fixture = Worker(bootstrap: bootstrap, root: try evidenceRoot())
    try fixture.start()
    while true {
      try await Task.sleep(for: .seconds(30))
      withExtendedLifetime(fixture) {}
    }
  }

  private struct Snapshot: Codable {
    let guardian: Int32
    let worker: Int32?
    let shell: Int32?
    let available: Bool
    let workerFinished: Bool
    let shellFinished: Bool
  }

  private final class Worker: @unchecked Sendable {
    let queue = DispatchQueue(label: "guardian-qualification.worker")
    let bootstrap: GuardianWorkerBootstrap
    let root: URL
    var connection: GuardianWorkerConnection?
    let pump: GuardianPaneOutput
    var handle: GuardianPaneHandle?
    var output = Data()
    var shell: Int32?

    init(bootstrap: GuardianWorkerBootstrap, root: URL) {
      self.bootstrap = bootstrap
      self.root = root
      pump = GuardianPaneOutput(queue: queue)
    }

    func start() throws {
      try queue.sync {
        pump.canConsume = { true }
        pump.consume = { [weak self] bytes in
          self?.output.append(contentsOf: bytes)
          return bytes.count
        }
        pump.acknowledge = { [weak self] sequence in
          guard let self, let handle = self.handle else { exit(4) }
          self.connection?.acknowledgeOutput(handle, through: sequence)
        }
        pump.onBatch = { [weak self] in self?.writeEvidence() }
        pump.onFailure = { _ in exit(5) }
        connection = try bootstrap.connect(
          queue: queue,
          handlers: .init(
            ready: { [weak self] _ in self?.spawn() },
            output: { [weak self] _, sequence, bytes in
              self?.pump.receive(sequence: sequence, bytes: bytes)
            },
            inputReleased: { _, _ in },
            exiting: { [weak self] _ in self?.pump.exiting() },
            exited: { [weak self] _, status, forced in
              self?.pump.exited(status: status, forced: forced)
            },
            progress: { complete in complete() },
            closed: { _ in exit(0) }
          )
        )
      }
    }

    private func spawn() {
      let pane = PaneID()
      do {
        _ = try connection?
          .submit(
            .spawn(
              pane: pane,
              launch: LaunchSpec(command: [
                "/bin/sh", "-c", "printf GUARDIAN_READY; exec /bin/sleep 300",
              ]),
              columns: 80,
              rows: 24
            )
          ) { [weak self] outcome in
            guard let self else { return }
            if case let .success(.spawned(pid, process)) = outcome {
              self.handle = GuardianPaneHandle(pane: pane, process: process)
              self.shell = pid
              self.writeEvidence()
            } else {
              exit(2)
            }
          }
      } catch { exit(3) }
    }

    private func writeEvidence() {
      let values: [String: String] = [
        "worker": String(getpid()), "parent": String(getppid()),
        "guardian": String(bootstrap.guardianPID),
        "shell": shell.map(String.init) ?? "",
        "output": String(decoding: output, as: UTF8.self),
      ]
      if let data = try? JSONEncoder().encode(values) {
        try? data.write(
          to: root.appendingPathComponent("worker.json"),
          options: .atomic
        )
      }
    }
  }
}
