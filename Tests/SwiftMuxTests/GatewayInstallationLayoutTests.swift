import Foundation
@testable import SwiftMuxGateway
import SwiftMuxProtocol
import Testing

/// The gateway helper exactly as Scripts/package-swiftmux.sh lays it out:
/// KeepAlive, Login Items association with the app, and the policy the
/// running gateway derives from its own agent plist.
struct GatewayInstallationLayoutTests {
  let label = "com.chr33s.swiftty.swiftmux-gateway"
  let arguments = [
    "--guardian-service", "com.chr33s.swiftty.swiftmux-guardian.control",
    "--guardian-identifier",
    "com.chr33s.swiftty.swiftmux-guardian.swiftmux-guardian",
    "--control-service", "com.chr33s.swiftty.swiftmux-gateway.control",
  ]

  func bundle(
    keepAlive: [String: Bool]? = ["SuccessfulExit": false],
    associated: [String] = ["com.chr33s.swiftty"]
  ) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "gateway-layout-\(UUID().uuidString)"
    )
    let bundle = root.appendingPathComponent("SwiftMuxGateway.app")
    let contents = bundle.appendingPathComponent("Contents")
    let agents = contents.appendingPathComponent("Library/LaunchAgents")
    try FileManager.default.createDirectory(
      at: agents,
      withIntermediateDirectories: true
    )
    try PropertyListSerialization.data(
      fromPropertyList: [
        "CFBundleIdentifier": label, "CFBundlePackageType": "APPL",
      ],
      format: .xml,
      options: 0
    )
    .write(to: contents.appendingPathComponent("Info.plist"))
    var agent: [String: Any] = [
      "Label": label, "BundleProgram": "Contents/MacOS/swiftmux-gateway",
      "ProgramArguments": ["swiftmux-gateway"] + arguments,
      "AssociatedBundleIdentifiers": associated,
      "MachServices": [label + ".control": true], "RunAtLoad": true,
      "ProcessType": "Interactive", "EnablePressuredExit": false,
      "EnableTransactions": false,
    ]
    if let keepAlive { agent["KeepAlive"] = keepAlive }
    try PropertyListSerialization.data(
      fromPropertyList: agent,
      format: .xml,
      options: 0
    )
    .write(to: agents.appendingPathComponent(label + ".plist"))
    return bundle
  }

  @Test
  func `the packaged layout passes the policy it registers with`() throws {
    let installed = try bundle()
    defer {
      try? FileManager.default.removeItem(
        at: installed.deletingLastPathComponent()
      )
    }
    let policy = try GatewayDaemonUpdate.installationPolicy(
      GatewayDaemonConfiguration(arguments: arguments),
      bundle: try #require(Bundle(url: installed))
    )
    #expect(policy.associatedBundleIdentifiers == ["com.chr33s.swiftty"])
    #expect(policy.keepAlive == ["SuccessfulExit": false])
    // A candidate packaged the same way is accepted.
    let candidate = try bundle()
    defer {
      try? FileManager.default.removeItem(
        at: candidate.deletingLastPathComponent()
      )
    }
    _ = try policy.validate(in: candidate)
    // One that changed its keep-alive or Login Items owner is not.
    for changed in [
      try bundle(keepAlive: nil), try bundle(associated: [label]),
    ] {
      defer {
        try? FileManager.default.removeItem(
          at: changed.deletingLastPathComponent()
        )
      }
      #expect(throws: MuxError.self) { try policy.validate(in: changed) }
    }
  }
}
