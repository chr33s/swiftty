import Darwin
import Foundation
import SwiftMuxGuardian
import SwiftMuxProtocol

/// A declaration read from a validated signed bundle. It is not an install
/// permit or a durable pin: publication must revalidate the staged artifact.
package struct GatewayUpdateArtifact: Sendable {
  package struct Manifest: Codable, Sendable {
    package let schema: Int
    package let build: String
    package let guardianProtocol: Int
    package let workerProtocols: [Int]
    package let nativeControlProtocol: Int
  }

  package let bundle: URL
  package let manifest: Manifest
  package let installation: GatewayInstallationPolicy
  private init(
    bundle: URL,
    manifest: Manifest,
    installation: GatewayInstallationPolicy
  ) {
    self.bundle = bundle
    self.manifest = manifest
    self.installation = installation
  }

  /// Requirements must come from installation policy, never from this bundle.
  /// Both bundle and nested executable are checked; no unsigned fallback exists.
  package static func validate(
    _ source: URL,
    bundleRequirement: String,
    executableRequirement: String,
    installation: GatewayInstallationPolicy
  ) throws -> Self {
    guard source.isFileURL, !bundleRequirement.isEmpty,
      !executableRequirement.isEmpty
    else {
      throw MuxError(
        .invalidRequest,
        "gateway update requires local signed artifacts"
      )
    }
    let bundle = source.standardizedFileURL
    guard bundle.path == bundle.resolvingSymlinksInPath().path else {
      throw MuxError(
        .unauthorized,
        "gateway bundle contains a symlink ancestor"
      )
    }
    try GuardianArtifactValidation.validateTree(bundle)
    let installationMetadata = try installation.validate(in: bundle)
    let executable = bundle.appendingPathComponent(
      "Contents/MacOS/swiftmux-gateway"
    )
    try GuardianArtifactValidation.check(executable, directory: false)
    guard access(executable.path, X_OK) == 0 else {
      throw MuxError(.unauthorized, "gateway executable is not executable")
    }
    let metadata = bundle.appendingPathComponent(
      "Contents/Resources/gateway-build.json"
    )
    guard
      try GuardianArtifactValidation.check(metadata, directory: false) <= 65536
    else { throw MuxError(.resourceLimit, "gateway manifest too large") }
    let fd = Darwin.open(
      metadata.path,
      O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
    )
    guard fd >= 0 else {
      throw MuxError(.unauthorized, "cannot open gateway manifest")
    }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o022 == 0
    else { throw MuxError(.unauthorized, "unsafe gateway manifest") }
    let data = try handle.read(upToCount: 65537) ?? Data()
    guard data.count <= 65536 else {
      throw MuxError(.resourceLimit, "gateway manifest too large")
    }
    let manifest = try JSONDecoder().decode(Manifest.self, from: data)
    guard manifest.schema == 1, Self.isBuildIdentifier(manifest.build),
      manifest.guardianProtocol > 0, manifest.nativeControlProtocol > 0,
      !manifest.workerProtocols.isEmpty, manifest.workerProtocols.count <= 64,
      Set(manifest.workerProtocols).count == manifest.workerProtocols.count,
      manifest.workerProtocols.allSatisfy({ $0 > 0 })
    else { throw MuxError(.invalidRequest, "invalid gateway build manifest") }
    try GuardianArtifactValidation.validateSignature(
      executable.path,
      requirement: executableRequirement
    )
    try GuardianArtifactValidation.validateSignature(
      bundle.path,
      requirement: bundleRequirement
    )
    // Bind the declaration to the resource still present at the validated path.
    // Installation still must own an immutable staged copy and revalidate it.
    var current = stat()
    guard lstat(metadata.path, &current) == 0, current.st_dev == info.st_dev,
      current.st_ino == info.st_ino
    else {
      throw MuxError(
        .unauthorized,
        "gateway manifest changed during validation"
      )
    }
    try handle.seek(toOffset: 0)
    guard try handle.read(upToCount: 65537) == data else {
      throw MuxError(
        .unauthorized,
        "gateway manifest changed during validation"
      )
    }
    for (url, bytes) in installationMetadata {
      guard try GatewayInstallationPolicy.readMetadata(url) == bytes else {
        throw MuxError(
          .unauthorized,
          "gateway installation metadata changed during validation"
        )
      }
    }
    return Self(bundle: bundle, manifest: manifest, installation: installation)
  }

  package static func isBuildIdentifier(_ build: String) -> Bool {
    !build.isEmpty && build.utf8.count <= 128 && !build.hasPrefix(".")
      && build.utf8.allSatisfy {
        (48 ... 57).contains($0) || (65 ... 90).contains($0)
          || (97 ... 122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
      }
  }

}
