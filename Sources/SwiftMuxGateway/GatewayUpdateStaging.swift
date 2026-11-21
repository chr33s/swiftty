import Darwin
import Foundation
import SwiftMuxGuardian
import SwiftMuxProtocol

/// Publishes immutable candidate copies. This store never changes registration,
/// selects a running build or collects previously published versions.
/// Sendable: stored properties are immutable; publication is serialized by `lock`.
package final class GatewayUpdateStaging: @unchecked Sendable {
  private let root: URL
  private let bundleRequirement: String
  private let executableRequirement: String
  private let installation: GatewayInstallationPolicy
  private let lock = NSLock()

  package init(
    root: URL,
    bundleRequirement: String,
    executableRequirement: String,
    installation: GatewayInstallationPolicy
  ) throws {
    self.root = root.standardizedFileURL
    self.bundleRequirement = bundleRequirement
    self.executableRequirement = executableRequirement
    self.installation = installation
    try validateRoot()
  }

  package func stage(_ source: URL) throws -> GatewayUpdateArtifact {
    lock.lock()
    defer { lock.unlock() }
    try Task.checkCancellation()
    try validateRoot()
    let candidate = try validate(source)
    // Never copy a source containing the staging root into itself.
    guard !root.pathComponents.starts(with: candidate.bundle.pathComponents)
    else {
      throw MuxError(
        .invalidRequest,
        "gateway staging directory is inside the source bundle"
      )
    }
    let destination = try versionDirectory(candidate.manifest.build)
    let scratch = root.appendingPathComponent(
      ".stage-" + UUID().uuidString,
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: scratch,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: scratch) }
    let copy = scratch.appendingPathComponent("Gateway.app", isDirectory: true)
    try FileManager.default.copyItem(at: candidate.bundle, to: copy)
    let checked = try validate(copy)
    guard checked.manifest.build == candidate.manifest.build else {
      throw MuxError(.invalidRequest, "gateway build changed during staging")
    }
    try Task.checkCancellation()
    try validateRoot()
    guard renamex_np(scratch.path, destination.path, UInt32(RENAME_EXCL)) == 0
    else {
      throw MuxError(
        .launchFailed,
        "cannot publish gateway build; existing versions are never replaced"
      )
    }
    // Publication is complete. Do not delete it if later inspection fails;
    // callers can inspect the known build ID after an uncertain result.
    return try validate(destination.appendingPathComponent("Gateway.app"))
  }

  package func load(_ build: String) throws -> GatewayUpdateArtifact {
    lock.lock()
    defer { lock.unlock() }
    try validateRoot()
    let directory = try versionDirectory(build)
    try GuardianArtifactValidation.check(
      directory,
      directory: true,
      privateDirectory: true
    )
    let artifact = try validate(directory.appendingPathComponent("Gateway.app"))
    guard artifact.manifest.build == build else {
      throw MuxError(
        .invalidRequest,
        "gateway build directory and manifest disagree"
      )
    }
    return artifact
  }

  private func validate(_ bundle: URL) throws -> GatewayUpdateArtifact {
    try GatewayUpdateArtifact.validate(
      bundle,
      bundleRequirement: bundleRequirement,
      executableRequirement: executableRequirement,
      installation: installation
    )
  }

  private func versionDirectory(_ build: String) throws -> URL {
    guard GatewayUpdateArtifact.isBuildIdentifier(build) else {
      throw MuxError(.invalidRequest, "invalid gateway build identifier")
    }
    return root.appendingPathComponent(build, isDirectory: true)
  }

  private func validateRoot() throws {
    guard root.isFileURL, root.path == root.resolvingSymlinksInPath().path
    else {
      throw MuxError(.unauthorized, "gateway staging root contains a symlink")
    }
    try GuardianArtifactValidation.check(
      root,
      directory: true,
      privateDirectory: true
    )
  }
}
