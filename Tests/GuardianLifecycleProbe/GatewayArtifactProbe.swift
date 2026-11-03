import Foundation
import SwiftMuxGateway
import SwiftMuxGuardian
import SwiftMuxProtocol

extension GuardianLifecycleProbe {
  static func validateGatewayCandidate(_ args: [String]) throws {
    let stage = args.first == "stage-gateway-candidate"
    guard args.count == (stage ? 8 : 7),
      args[2 ... 3]
        .allSatisfy({ identifier in
          identifier.hasPrefix("com.chr33s.swiftty.durability-probe.")
            && identifier.utf8.count <= 255
            && identifier.utf8.allSatisfy {
              (48 ... 57).contains($0) || (65 ... 90).contains($0)
                || (97 ... 122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
            }
        }),
      let team = try GuardianPeerSigningPolicy.requirementForCurrentProcess()
    else {
      throw MuxError(.unauthorized, "invalid signed artifact qualification")
    }
    let root = URL(fileURLWithPath: args[1]).deletingLastPathComponent()
    let policy = try GatewayInstallationPolicy(
      bundleIdentifier: args[2],
      agentLabel: args[6],
      configuration: GatewayDaemonConfiguration(arguments: [
        "--guardian-service", args[4], "--guardian-identifier", args[5],
        "--control-service", args[6],
      ]),
      standardOutputPath: root.appendingPathComponent(args[6] + ".stdout").path,
      standardErrorPath: root.appendingPathComponent(args[6] + ".stderr").path
    )
    let source = URL(fileURLWithPath: args[1])
    let bundleRequirement = "(\(team)) and identifier \"\(args[2])\""
    let executableRequirement = "(\(team)) and identifier \"\(args[3])\""
    let artifact: GatewayUpdateArtifact
    if stage {
      let store = try GatewayUpdateStaging(
        root: URL(fileURLWithPath: args[7]),
        bundleRequirement: bundleRequirement,
        executableRequirement: executableRequirement,
        installation: policy
      )
      artifact = try store.stage(source)
    } else {
      artifact = try GatewayUpdateArtifact.validate(
        source,
        bundleRequirement: bundleRequirement,
        executableRequirement: executableRequirement,
        installation: policy
      )
    }
    print(
      String(
        decoding: try JSONEncoder().encode(artifact.manifest),
        as: UTF8.self
      )
    )
  }
}
