import Foundation
import Security
import SwiftMuxGuardian
import SwiftMuxProtocol

/// The running gateway's side of an ordinary update (spec.durability.md
/// §5.2). Candidates must match this installation: the policy and signing
/// identities come from the installed bundle, never from the candidate.
package enum GatewayDaemonUpdate {
  /// The installer swaps the bundle after the reply; nothing happens here.
  struct HandOver: GatewayReplacement {
    func install(_ build: String) async throws {}
  }

  package static func handler(
    supervisor: GatewaySupervisor,
    configuration: GatewayDaemonConfiguration,
    teamRequirement: String,
    plans: GatewayUpdatePlanStore,
    bundle: Bundle = .main
  ) throws -> GatewayRuntime.UpdateHandler {
    guard let own = runningGatewayBuild(bundle: bundle) else {
      throw MuxError(.notFound, "gateway build declaration missing")
    }
    let policy = try installationPolicy(configuration, bundle: bundle)
    // The bundle's signature is its main executable's: one identifier, the
    // one the guardian requires of its gateway (`<label>.swiftmux-gateway`).
    guard let executableIdentifier = signingIdentifier() else {
      throw MuxError(.unauthorized, "gateway signing identity unknown")
    }
    let executableRequirement =
      "(\(teamRequirement)) and identifier \"\(executableIdentifier)\""
    let bundleRequirement = executableRequirement
    return { request in
      let candidate = try GatewayUpdateArtifact.validate(
        URL(fileURLWithPath: request.candidate),
        bundleRequirement: bundleRequirement,
        executableRequirement: executableRequirement,
        installation: policy
      )
      let worker = request.workerBuild.flatMap { build in
        request.workerProtocol.map { (build: build, protocol: $0) }
      }
      let updater = GatewayUpdater(
        supervisor: supervisor,
        plans: plans,
        replacement: HandOver()
      )
      switch try await updater.install(
        candidate: candidate,
        currentBuild: own.build,
        currentProtocols: Set(own.workerProtocols),
        worker: worker
      ) {
      case let .handedOver(plan): return .handedOver(build: plan.gatewayBuild)
      case let .deferred(error): return .deferred(error)
      default: throw MuxError(.invalidRequest, "unexpected update outcome")
      }
    }
  }

  /// The policy this installation was registered with: its one agent plist
  /// supplies the label, log paths, Login Items association and keep-alive.
  static func installationPolicy(
    _ configuration: GatewayDaemonConfiguration,
    bundle: Bundle
  ) throws -> GatewayInstallationPolicy {
    let agents = bundle.bundleURL.appendingPathComponent(
      "Contents/Library/LaunchAgents"
    )
    let plists = try FileManager.default
      .contentsOfDirectory(at: agents, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "plist" }
    guard plists.count == 1,
      let agent = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: plists[0]),
        format: nil
      ) as? [String: Any], let label = agent["Label"] as? String,
      let bundleIdentifier = bundle.bundleIdentifier
    else {
      throw MuxError(.invalidRequest, "gateway agent declaration missing")
    }
    return try GatewayInstallationPolicy(
      bundleIdentifier: bundleIdentifier,
      agentLabel: label,
      configuration: configuration,
      standardOutputPath: agent["StandardOutPath"] as? String,
      standardErrorPath: agent["StandardErrorPath"] as? String,
      associatedBundleIdentifiers: agent["AssociatedBundleIdentifiers"]
        as? [String],
      keepAlive: agent["KeepAlive"] as? [String: Bool]
    )
  }

  /// This executable's code-signing identifier.
  static func signingIdentifier() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
      return nil
    }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
      let staticCode
    else { return nil }
    var information: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode,
        SecCSFlags(rawValue: kSecCSSigningInformation),
        &information
      ) == errSecSuccess, let values = information as? [String: Any]
    else { return nil }
    return values[kSecCodeInfoIdentifier as String] as? String
  }
}
