import Darwin
import Dispatch
import Foundation
import SwiftMuxClient
import SwiftMuxGateway
import SwiftMuxGuardian
import SwiftMuxProtocol
import SwiftMuxService

extension GuardianLifecycleProbe {
  static func checkGatewayAccess(_ service: String) async throws {
    let control = try await GatewaySupervisor.connect(
      peerRequirement: PeerSigningPolicy.requirementForCurrentProcess(),
      channel: { .connect(machService: service, queue: $0) }
    )
    _ = try await control.inventory()
    await control.close()
    print("admitted")
  }

  /// Persistent gateway fixture using the actual worker, native client and
  /// terminal engine. Qualification only; not the product gateway facade.
  static func serveWorkspaceGateway() async throws {
    let root = try evidenceRoot()
    func stage(_ value: String) throws {
      try value.write(
        to: root.appendingPathComponent("gateway-stage"),
        atomically: true,
        encoding: .utf8
      )
    }
    try stage("connecting guardian")
    let retainedProofURL = root.appendingPathComponent("retained-proof.txt")
    let previousProof = try? String(
      contentsOf: retainedProofURL,
      encoding: .utf8
    )
    guard
      let guardian = Bundle.main.object(forInfoDictionaryKey: "ProbeGuardian")
        as? String, guardian.hasPrefix("com.chr33s.swiftty.durability-probe.")
    else { throw MuxError(.invalidRequest, "missing qualification guardian") }
    let requirement = try PeerSigningPolicy.requirementForCurrentProcess()
    let control = try await GatewaySupervisor.connect(
      peerRequirement: requirement,
      channel: { .connect(machService: guardian + ".control", queue: $0) }
    )
    let runtime = try await GatewayRuntime.start(
      supervisor: control,
      peerRequirement: requirement
    )
    let frontendServer = GatewayControlServer(
      runtime: runtime,
      peerRequirement: requirement
    )
    let frontendEndpoint = frontendServer.listenAnonymously()
    let frontendControl = try await MuxGatewayConnection.connect(
      peerRequirement: requirement,
      expectedPID: getpid(),
      channel: { .connect(endpoint: frontendEndpoint, queue: $0) }
    )
    let launchRequest = NewWorkspaceRequest(
      name: "durability-probe",
      launch: LaunchSpec(
        command: ["/bin/sh", "-i"],
        workingDirectory: "/tmp",
        environment: ["PATH": "/usr/bin:/bin", "PS1": "$ "]
      )
    )
    var createdByRuntime = false
    let requestedWorkspace =
      (Bundle.main.object(forInfoDictionaryKey: "ProbeWorkspace") as? String)
      .flatMap(WorkspaceID.init)
    if let requestedWorkspace,
      try await !control.inventory()
        .contains(where: { $0.authority.workspace == requestedWorkspace })
    {
      try stage("creating workspace through native control")
      try await frontendControl.createWorkspace(
        requestedWorkspace,
        request: launchRequest
      )
      createdByRuntime = true
    }
    let deadline = ContinuousClock.now + .seconds(15)
    var inventory: GuardianWorkspaceInventory?
    while inventory == nil {
      let items = try await control.inventory()
      inventory = items.first {
        $0.available
          && (requestedWorkspace == nil
            || $0.authority.workspace == requestedWorkspace)
      }
      if let failure = items.first(where: {
        $0.authority.workspace == requestedWorkspace
      })?
      .launchError {
        throw failure
      }
      guard ContinuousClock.now < deadline else {
        throw MuxError(.connectionLost, "worker did not start")
      }
      if inventory == nil { try await Task.sleep(for: .milliseconds(25)) }
    }
    let authority = inventory!.authority
    while true {
      do {
        _ = try await control.workerEndpoint(authority)
        break
      } catch let error as MuxError where error.code == .notAttached {
        guard ContinuousClock.now < deadline else {
          throw MuxError(.connectionLost, "worker not ready")
        }
        try await Task.sleep(for: .milliseconds(25))
      }
    }
    try stage("opening native listener")
    let nativeEndpoint = try GatewayNativeEndpoint(
      supervisor: control,
      authority: authority,
      peerRequirement: requirement
    )
    try stage("connecting native frontend")
    let bootstrapClient = try await MuxConnection.connect(
      endpoint: nativeEndpoint.endpoint,
      frontend: .native
    )
    try stage("listing workspaces")
    guard let worker = inventory!.worker,
      let server = await bootstrapClient.welcome?.server
    else { throw MuxError(.invalidRequest, "missing worker identity") }
    guard
      case let .workspaces(workspaces) = try await bootstrapClient.execute(
        .listWorkspaces
      )
    else { throw MuxError(.invalidRequest, "missing workspace list") }
    let created = createdByRuntime || workspaces.isEmpty
    if workspaces.isEmpty {
      // Older qualification modes provision a worker directly without a build
      // registry. Their initial graph is still explicitly created here.
      _ = try await bootstrapClient.execute(.newWorkspace(launchRequest))
    }
    try stage("subscribing directory")
    let graphDeadline = ContinuousClock.now + .seconds(5)
    var observedGraph: WorkspaceSnapshot?
    while observedGraph == nil {
      if let record = await runtime.records.first(where: {
        $0.inventory.authority == authority
      }) {
        if case let .unavailable(error) = record.state { throw error }
        if case .available = record.state { observedGraph = record.graph }
      }
      guard ContinuousClock.now < graphDeadline else {
        throw MuxError(
          .connectionLost,
          "directory graph did not become available"
        )
      }
      if observedGraph == nil { try await Task.sleep(for: .milliseconds(10)) }
    }
    guard let discoveredGraph = observedGraph,
      let discoveredTab = discoveredGraph.activeTabSnapshot
    else {
      throw MuxError(.invalidRequest, "directory graph has no active tab")
    }
    await bootstrapClient.close()
    await nativeEndpoint.close()
    try stage("selecting native route")
    let nativeRecords = try await frontendControl.listWorkspaces()
    guard
      nativeRecords.contains(where: {
        $0.workspace == authority.workspace && $0.state == .available
      })
    else {
      throw MuxError(.notAttached, "native control did not discover workspace")
    }
    let opened = try await frontendControl.openWorkspace(
      .id(authority.workspace),
      role: .controller
    )
    let client = opened.connection
    guard await client.welcome?.server == server else {
      throw MuxError(
        .serverInstanceChanged,
        "route selected a different worker"
      )
    }
    try stage("attaching")
    guard
      case let .attached(_, workspace) = try await client.execute(
        .attach(AttachRequest(.id(authority.workspace)))
      ), let tab = workspace.activeTabSnapshot
    else { throw MuxError(.invalidRequest, "missing worker workspace") }
    let pane = tab.activePane
    try stage("setting geometry")
    _ = try await client.execute(
      .setGeometry(
        GeometryBatch(
          layoutRevision: workspace.layoutRevision,
          generation: 1,
          entries: [.init(pane: pane, columns: 120, rows: 24)]
        )
      )
    )
    try stage("subscribing frames")
    _ = try await client.execute(.setSubscriptions([pane]))
    // Interactive /bin/sh enables history expansion; disable it on a separate
    // line before submitting the background-job PID expression `$!`.
    try stage("sending input")
    if created { try await client.send(.text("set +H\r"), to: pane) }
    let marker =
      "proof_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let setup =
      created ? "SWMUX_PROBE=durable; set -m; sleep 300 & SWMUX_JOB=$!; " : ""
    let build = inventory!.worker?.build ?? ""
    let resourceCheck =
      requestedWorkspace == nil
      ? ""
      : "SWMUX_RESOURCES=missing; case \"$TERMINFO_DIRS\" in *'/Versions/\(build)/Worker.app/Contents/Resources/terminfo:'*) SWMUX_RESOURCES=ok;; esac; "
    try await client.send(
      .text(
        setup + resourceCheck
          + "printf '\(marker)=%s:%s:%s:%s:%s\\n' \"$SWMUX_PROBE\" \"$$\" \"$SWMUX_JOB\" \"$-\" \"$SWMUX_RESOURCES\"\r"
      ),
      to: pane
    )
    try stage("waiting for proof")
    let frameDeadline = ContinuousClock.now + .seconds(10)
    var proof: String?
    while proof == nil, ContinuousClock.now < frameDeadline {
      if case let .frame(frame) = try await client.nextEvent(
        timeout: .seconds(2)
      ) {
        try JSONEncoder().encode(frame.lines)
          .write(
            to: root.appendingPathComponent("last-frame.json"),
            options: .atomic
          )
        proof = frame.lines.first { $0.hasPrefix(marker + "=durable:") }
        if proof != nil, let previousProof, !frame.lines.contains(previousProof)
        {
          throw MuxError(
            .invalidRequest,
            "pre-restart terminal content was lost"
          )
        }
      }
    }
    guard let proof else {
      throw MuxError(.connectionLost, "terminal proof did not arrive")
    }
    let values: [String: String] = [
      "gateway": String(getpid()), "worker": String(worker.pid),
      "workspace": String(describing: authority.workspace),
      "server": String(describing: server), "proof": proof,
      "workerBuild": build,
      "graphRevision": String(discoveredGraph.layoutRevision),
      "graphTab": discoveredTab.id.description,
      "graphPane": discoveredTab.activePane.description,
      "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
        as? String ?? "",
    ]
    try proof.write(to: retainedProofURL, atomically: true, encoding: .utf8)
    try JSONEncoder().encode(values)
      .write(to: root.appendingPathComponent("gateway.json"), options: .atomic)
    while true {
      let check = root.appendingPathComponent("gateway-check")
      if FileManager.default.fileExists(atPath: check.path) {
        _ = try await control.inventory()
        _ = try await client.execute(.status)
        try FileManager.default.removeItem(at: check)
        try Data("done".utf8)
          .write(
            to: root.appendingPathComponent("gateway-checked"),
            options: .atomic
          )
      }
      if FileManager.default.fileExists(
        atPath: root.appendingPathComponent("gateway-end").path
      ) {
        try await frontendControl.endWorkspace(.id(authority.workspace))
        guard
          try await control.inventory()
            .allSatisfy({ $0.authority != authority })
        else { throw MuxError(.invalidRequest, "ended workspace was retained") }
        let retirementDeadline = ContinuousClock.now + .seconds(5)
        while true {
          let retained = await runtime.records.contains {
            $0.inventory.authority == authority
          }
          let routeCount = await runtime.nativeRouteCount
          let connectionCount = await runtime.nativeConnectionCount
          if !retained && routeCount == 0 && connectionCount == 0 { break }
          if let failure = await runtime.failure { throw failure }
          guard ContinuousClock.now < retirementDeadline else {
            throw MuxError(
              .invalidRequest,
              "runtime retained a retired workspace or native route"
            )
          }
          try await Task.sleep(for: .milliseconds(10))
        }
        try? FileManager.default.removeItem(
          at: root.appendingPathComponent("gateway-end")
        )
        try Data("retired".utf8)
          .write(
            to: root.appendingPathComponent("gateway-retired"),
            options: .atomic
          )
      }
      try await Task.sleep(for: .milliseconds(50))
      withExtendedLifetime(
        (control, client, runtime, frontendServer, frontendControl)
      ) {}
    }
  }
}
