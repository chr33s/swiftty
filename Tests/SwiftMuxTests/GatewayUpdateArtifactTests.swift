import Darwin
import Foundation
import SwiftMuxGateway
import SwiftMuxGuardian
import SwiftMuxProtocol
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct GatewayUpdateArtifactTests {
  @Test
  func sealedDeclarationIsLoadedWithBothSigningRequirements() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let artifact = try fixture.validate()
    #expect(artifact.manifest.build == "candidate-1")
    #expect(artifact.manifest.guardianProtocol == GuardianWire.version)
    #expect(artifact.manifest.workerProtocols == Array(SMX.compatibleVersions))
    #expect(artifact.manifest.nativeControlProtocol == GatewayControl.version)
    #expect(throws: MuxError.self) {
      try GatewayUpdateArtifact.validate(
        fixture.bundle,
        bundleRequirement: "identifier \"wrong.bundle\"",
        executableRequirement: Fixture.executableRequirement,
        installation: try Fixture.policy()
      )
    }
    #expect(throws: MuxError.self) {
      try GatewayUpdateArtifact.validate(
        fixture.bundle,
        bundleRequirement: Fixture.bundleRequirement,
        executableRequirement: "identifier \"wrong.executable\"",
        installation: try Fixture.policy()
      )
    }
  }

  @Test
  func validatedArtifactDrivesRuntimeProtocolPreflight() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let guardian = try GuardianServer(
      launcherPath: launcherPath(),
      peerRequirement: nil
    )
    let control = GuardianGatewayServer(
      guardian: guardian,
      peerRequirement: nil
    )
    let endpoint = control.listenAnonymously()
    defer {
      control.close();
      guardian.shutdown {}
    }
    let supervisor = try await GatewaySupervisor.connect(
      peerRequirement: nil,
      expectedGuardianPID: getpid(),
      channel: { .connect(endpoint: endpoint, queue: $0) }
    )
    let runtime = try await GatewayRuntime.start(
      supervisor: supervisor,
      peerRequirement: nil
    )
    try await runtime.preflightUpdate(fixture.validate())
    var declaration = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: fixture.metadata))
        as? [String: Any]
    )
    declaration["nativeControlProtocol"] = GatewayControl.version + 1
    try JSONSerialization.data(withJSONObject: declaration)
      .write(to: fixture.metadata)
    try fixture.sign()
    let incompatible = try fixture.validate()
    do {
      try await runtime.preflightUpdate(incompatible)
      Issue.record("unsupported candidate frontend protocol passed preflight")
    } catch let error as MuxError {
      #expect(error.code == .incompatibleVersion)
    }
    #expect(guardian.inventory().isEmpty)
    await runtime.close()
  }

  @Test(arguments: [
    "tamper", "unsigned", "symlink", "hardlink", "writable", "oversize",
    "schema", "duplicates",
  ])
  func malformedOrUntrustedCandidateIsRefused(kind: String) throws {
    let fixture = try Fixture(signed: kind != "unsigned")
    defer { fixture.remove() }
    switch kind {
    case "tamper": try Data("{}".utf8).write(to: fixture.metadata)
    case "symlink":
      let saved = fixture.root.appendingPathComponent("saved.json")
      try FileManager.default.moveItem(at: fixture.metadata, to: saved)
      try FileManager.default.createSymbolicLink(
        at: fixture.metadata,
        withDestinationURL: saved
      )
    case "hardlink":
      #expect(
        link(
          fixture.metadata.path,
          fixture.root.appendingPathComponent("alias").path
        ) == 0
      )
    case "writable": #expect(chmod(fixture.metadata.path, 0o666) == 0)
    case "oversize":
      try Data(repeating: 32, count: 65537).write(to: fixture.metadata)
      try fixture.sign()
    case "schema", "duplicates":
      var declaration = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: fixture.metadata))
          as? [String: Any]
      )
      if kind == "schema" {
        declaration["schema"] = 99
      } else {
        declaration["workerProtocols"] = [2, 2]
      }
      try JSONSerialization.data(withJSONObject: declaration)
        .write(to: fixture.metadata)
      try fixture.sign()
    default: break
    }
    #expect(throws: (any Error).self) { try fixture.validate() }
  }

  @Test(arguments: [
    "label", "program", "bundleProgram", "guardianService", "guardianIdentity",
    "controlService", "extraService", "extraAgent", "daemon", "pressure",
    "transactions", "environment", "log", "association", "bundle", "arguments",
  ])
  func signedCandidateCannotChangeInstallationTopology(kind: String) throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let agentURL = fixture.bundle.appendingPathComponent(
      "Contents/Library/LaunchAgents/test.gateway.service.plist"
    )
    var agent = try #require(
      PropertyListSerialization.propertyList(
        from: Data(contentsOf: agentURL),
        format: nil
      ) as? [String: Any]
    )
    switch kind {
    case "label": agent["Label"] = "test.guardian"
    case "program": agent["Program"] = "/bin/sh"
    case "bundleProgram":
      agent["BundleProgram"] = "Contents/MacOS/swiftmux-guardian"
    case "guardianService", "guardianIdentity", "controlService", "arguments":
      var args = try #require(agent["ProgramArguments"] as? [String])
      switch kind {
      case "guardianService": args[2] = "different.guardian"
      case "guardianIdentity": args[4] = "different.identity"
      case "controlService": args[6] = "different.control"
      default: args += ["--guardian-service", "test.guardian.control"]
      }
      agent["ProgramArguments"] = args
    case "extraService":
      agent["MachServices"] = [
        "test.gateway.service": true, "test.guardian": true,
      ]
    case "extraAgent":
      try FileManager.default.copyItem(
        at: agentURL,
        to: agentURL.deletingLastPathComponent()
          .appendingPathComponent("guardian.plist")
      )
    case "daemon":
      try FileManager.default.createDirectory(
        at: fixture.bundle.appendingPathComponent(
          "Contents/Library/LaunchDaemons"
        ),
        withIntermediateDirectories: false
      )
    case "pressure": agent["EnablePressuredExit"] = true
    case "transactions": agent["EnableTransactions"] = true
    case "environment":
      agent["EnvironmentVariables"] = [
        "DYLD_INSERT_LIBRARIES": "/tmp/not-a-library"
      ]
    case "log": agent["StandardOutPath"] = "/tmp/redirected-output"
    case "association":
      agent["AssociatedBundleIdentifiers"] = ["test.guardian.app"]
    case "bundle":
      let infoURL = fixture.bundle.appendingPathComponent("Contents/Info.plist")
      var info = try #require(
        PropertyListSerialization.propertyList(
          from: Data(contentsOf: infoURL),
          format: nil
        ) as? [String: Any]
      )
      info["CFBundleIdentifier"] = "different.bundle"
      try PropertyListSerialization.data(
        fromPropertyList: info,
        format: .xml,
        options: 0
      )
      .write(to: infoURL)
    default: break
    }
    try PropertyListSerialization.data(
      fromPropertyList: agent,
      format: .xml,
      options: 0
    )
    .write(to: agentURL)
    try fixture.sign()
    #expect(throws: MuxError.self) { try fixture.validate() }
  }

  struct Fixture {
    static let bundleRequirement = "identifier \"test.gateway.artifact.app\""
    static let executableRequirement =
      "identifier \"test.gateway.artifact.executable\""
    let root: URL
    let bundle: URL
    var metadata: URL {
      bundle.appendingPathComponent("Contents/Resources/gateway-build.json")
    }

    init(signed: Bool = true) throws {
      root = FileManager.default.temporaryDirectory
        .appendingPathComponent("gateway-artifact-" + UUID().uuidString)
        .resolvingSymlinksInPath()
      bundle = root.appendingPathComponent("Gateway.app")
      let macos = bundle.appendingPathComponent("Contents/MacOS")
      try FileManager.default.createDirectory(
        at: macos,
        withIntermediateDirectories: true
      )
      try FileManager.default.createDirectory(
        at: metadata.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      for name in ["probe", "swiftmux-gateway"] {
        try FileManager.default.copyItem(
          at: URL(fileURLWithPath: "/usr/bin/true"),
          to: macos.appendingPathComponent(name)
        )
      }
      let plist: [String: Any] = [
        "CFBundleIdentifier": "test.gateway.artifact.app",
        "CFBundleExecutable": "probe", "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1",
      ]
      try PropertyListSerialization.data(
        fromPropertyList: plist,
        format: .xml,
        options: 0
      )
      .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
      let declaration: [String: Any] = [
        "schema": 1, "build": "candidate-1",
        "guardianProtocol": GuardianWire.version,
        "workerProtocols": Array(SMX.compatibleVersions),
        "nativeControlProtocol": GatewayControl.version,
      ]
      try JSONSerialization.data(withJSONObject: declaration)
        .write(to: metadata)
      let agents = bundle.appendingPathComponent(
        "Contents/Library/LaunchAgents"
      )
      try FileManager.default.createDirectory(
        at: agents,
        withIntermediateDirectories: true
      )
      let agent: [String: Any] = [
        "Label": "test.gateway.service",
        "BundleProgram": "Contents/MacOS/swiftmux-gateway",
        "ProgramArguments": [
          "swiftmux-gateway", "--guardian-service", "test.guardian.control",
          "--guardian-identifier", "test.guardian.executable",
          "--control-service", "test.gateway.service",
        ], "AssociatedBundleIdentifiers": ["test.gateway.artifact.app"],
        "MachServices": ["test.gateway.service": true], "RunAtLoad": true,
        "EnablePressuredExit": false, "EnableTransactions": false,
        "ProcessType": "Interactive",
      ]
      try PropertyListSerialization.data(
        fromPropertyList: agent,
        format: .xml,
        options: 0
      )
      .write(to: agents.appendingPathComponent("test.gateway.service.plist"))
      if signed { try sign() }
    }

    static func policy() throws -> GatewayInstallationPolicy {
      try GatewayInstallationPolicy(
        bundleIdentifier: "test.gateway.artifact.app",
        agentLabel: "test.gateway.service",
        configuration: GatewayDaemonConfiguration(arguments: [
          "--guardian-service", "test.guardian.control",
          "--guardian-identifier", "test.guardian.executable",
          "--control-service", "test.gateway.service",
        ])
      )
    }

    func sign() throws {
      try codesign(
        bundle.appendingPathComponent("Contents/MacOS/swiftmux-gateway"),
        identifier: "test.gateway.artifact.executable"
      )
      try codesign(bundle, identifier: "test.gateway.artifact.app")
    }
    func codesign(_ path: URL, identifier: String) throws {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
      process.arguments = [
        "--force", "--sign", "-", "--identifier", identifier, path.path,
      ]
      let errors = Pipe()
      process.standardError = errors
      try process.run()
      let output = errors.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw MuxError(.unauthorized, String(decoding: output, as: UTF8.self))
      }
    }
    func validate() throws -> GatewayUpdateArtifact {
      try GatewayUpdateArtifact.validate(
        bundle,
        bundleRequirement: Self.bundleRequirement,
        executableRequirement: Self.executableRequirement,
        installation: try Self.policy()
      )
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
  }
}
