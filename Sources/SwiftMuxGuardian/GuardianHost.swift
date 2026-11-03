import Foundation
import SwiftMuxProtocol

/// Composition root for the independently installed process owner. It has no
/// engine/service dependency, idle exit, default shell or gateway-owned lifetime.
package final class GuardianHost: Sendable {
  private let server: GuardianServer
  private let control: GuardianGatewayServer
  private let configuration: GuardianDaemonConfiguration

  package init(
    configuration: GuardianDaemonConfiguration,
    signingRequirement: String
  ) throws {
    try configuration.validate()
    guard !signingRequirement.isEmpty else {
      throw MuxError(.unauthorized, "guardian requires signing policy")
    }
    try GuardianWorkerProcess.validateSignature(
      configuration.launcherPath,
      requirement: signingRequirement
    )
    let registry = try GuardianBuildRegistry(
      root: URL(fileURLWithPath: configuration.buildRoot),
      peerRequirement: signingRequirement
    )
    server = try GuardianServer(
      launcherPath: configuration.launcherPath,
      peerRequirement: signingRequirement
    )
    control = GuardianGatewayServer(
      guardian: server,
      peerRequirement: configuration.gatewayRequirement(
        teamRequirement: signingRequirement
      ),
      buildRegistry: registry,
      workerMachService: configuration.workerMachService
    )
    self.configuration = configuration
  }

  package func start() {
    server.listen(machService: configuration.workerMachService)
    control.listen(machService: configuration.gatewayMachService)
  }

  /// OS/launchd termination is the guardian-loss boundary. Ordinary gateway
  /// updates must never call this or unregister the guardian's independent job.
  package func shutdown(completion: @escaping @Sendable () -> Void) {
    control.close()
    server.shutdown(completion: completion)
  }
}
