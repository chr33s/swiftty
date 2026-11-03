import Darwin
import Foundation
import SwiftMuxGuardian
import SwiftMuxProtocol

/// Expected installation topology supplied by the installer, not the candidate.
package struct GatewayInstallationPolicy: Sendable {
  package let bundleIdentifier: String
  package let agentLabel: String
  package let configuration: GatewayDaemonConfiguration
  package let standardOutputPath: String?
  package let standardErrorPath: String?

  package init(
    bundleIdentifier: String,
    agentLabel: String,
    configuration: GatewayDaemonConfiguration,
    standardOutputPath: String? = nil,
    standardErrorPath: String? = nil
  ) throws {
    guard GatewayDaemonConfiguration.identifier(bundleIdentifier),
      GatewayDaemonConfiguration.identifier(agentLabel),
      agentLabel != configuration.guardianService,
      agentLabel != configuration.guardianIdentifier
    else {
      throw MuxError(.invalidRequest, "invalid gateway installation identity")
    }
    self.bundleIdentifier = bundleIdentifier
    self.agentLabel = agentLabel
    self.configuration = configuration
    self.standardOutputPath = standardOutputPath
    self.standardErrorPath = standardErrorPath
  }

  /// Returns the exact metadata bytes to recheck after signature validation.
  func validate(in bundle: URL) throws -> [URL: Data] {
    let infoURL = bundle.appendingPathComponent("Contents/Info.plist")
    let agents = bundle.appendingPathComponent("Contents/Library/LaunchAgents")
    let agentURL = agents.appendingPathComponent(agentLabel + ".plist")
    guard
      try FileManager.default.contentsOfDirectory(atPath: agents.path) == [
        agentLabel + ".plist"
      ],
      !FileManager.default.fileExists(
        atPath: bundle.appendingPathComponent("Contents/Library/LaunchDaemons")
          .path
      )
    else {
      throw MuxError(
        .invalidRequest,
        "gateway bundle must contain only its configured LaunchAgent"
      )
    }
    let infoData = try Self.readMetadata(infoURL)
    let agentData = try Self.readMetadata(agentURL)
    guard
      let info = try PropertyListSerialization.propertyList(
        from: infoData,
        format: nil
      ) as? [String: Any],
      info["CFBundleIdentifier"] as? String == bundleIdentifier,
      info["CFBundlePackageType"] as? String == "APPL",
      let agent = try PropertyListSerialization.propertyList(
        from: agentData,
        format: nil
      ) as? [String: Any]
    else {
      throw MuxError(
        .invalidRequest,
        "gateway bundle identity differs from installation policy"
      )
    }
    let keys: Set<String> = [
      "Label", "BundleProgram", "ProgramArguments",
      "AssociatedBundleIdentifiers", "MachServices", "RunAtLoad", "ProcessType",
      "EnablePressuredExit", "EnableTransactions", "StandardOutPath",
      "StandardErrorPath",
    ]
    guard Set(agent.keys).isSubset(of: keys),
      agent["Label"] as? String == agentLabel,
      agent["BundleProgram"] as? String == "Contents/MacOS/swiftmux-gateway",
      agent["AssociatedBundleIdentifiers"] as? [String] == [bundleIdentifier],
      agent["MachServices"] as? [String: Bool] == [
        configuration.controlService: true
      ], agent["RunAtLoad"] as? Bool == true,
      agent["EnablePressuredExit"] as? Bool == false,
      agent["EnableTransactions"] as? Bool == false,
      agent["ProcessType"] as? String == "Interactive",
      Self.matchesPath(agent["StandardOutPath"], expected: standardOutputPath),
      Self.matchesPath(agent["StandardErrorPath"], expected: standardErrorPath),
      let arguments = agent["ProgramArguments"] as? [String],
      arguments.first == "swiftmux-gateway"
    else {
      throw MuxError(
        .invalidRequest,
        "gateway LaunchAgent differs from installation policy"
      )
    }
    let configured = try GatewayDaemonConfiguration(
      arguments: Array(arguments.dropFirst())
    )
    guard configured.guardianService == configuration.guardianService,
      configured.guardianIdentifier == configuration.guardianIdentifier,
      configured.controlService == configuration.controlService
    else {
      throw MuxError(
        .invalidRequest,
        "gateway service topology differs from installation policy"
      )
    }
    return [infoURL: infoData, agentURL: agentData]
  }

  private static func matchesPath(_ value: Any?, expected: String?) -> Bool {
    guard let expected else { return value == nil }
    return value as? String == expected
  }

  static func readMetadata(_ url: URL) throws -> Data {
    guard try GuardianArtifactValidation.check(url, directory: false) <= 65536
    else {
      throw MuxError(.resourceLimit, "gateway installation metadata too large")
    }
    let descriptor = Darwin.open(
      url.path,
      O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      throw MuxError(.unauthorized, "cannot open gateway installation metadata")
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
      status.st_uid == geteuid(), status.st_nlink == 1,
      status.st_mode & 0o022 == 0
    else {
      throw MuxError(.unauthorized, "unsafe gateway installation metadata")
    }
    let data = try handle.read(upToCount: 65537) ?? Data()
    guard data.count <= 65536 else {
      throw MuxError(.resourceLimit, "gateway installation metadata too large")
    }
    return data
  }
}
