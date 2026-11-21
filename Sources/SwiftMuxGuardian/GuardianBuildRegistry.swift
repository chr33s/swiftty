import Darwin
import Foundation
import SwiftMuxProtocol

/// Installation metadata, not session persistence. Stored inside the signed
/// Worker.app resource seal. Resource paths are fixed by the bundle layout.
package struct GuardianBuildManifest: Codable, Sendable {
  package let schema: Int
  package let build: String
  package let guardianProtocol: Int
  package let workerProtocol: Int

  package init(
    build: String,
    guardianProtocol: Int = GuardianWire.version,
    workerProtocol: Int = SMX.protocolVersion,
    schema: Int = 1
  ) {
    self.schema = schema
    self.build = build
    self.guardianProtocol = guardianProtocol
    self.workerProtocol = workerProtocol
  }
}

/// A retained reference protects the complete immutable build, including shell
/// resources, even after its worker exits. Only guardian-owned retirement drops
/// the last reference; gateway loss never releases a workspace's build.
package final class GuardianBuildPin: Sendable {
  package let build: String
  package let bundle: URL
  package let manifest: GuardianBuildManifest
  package var workerPath: String {
    bundle.appendingPathComponent("Contents/MacOS/swiftmux-worker").path
  }
  package var launcherPath: String {
    bundle.appendingPathComponent("Contents/MacOS/swmux-launcher").path
  }
  package var shellPath: String {
    bundle.appendingPathComponent("Contents/MacOS/swsh").path
  }
  package var terminfoPath: String {
    bundle.appendingPathComponent("Contents/Resources/terminfo").path
  }
  private let registry: GuardianBuildRegistry

  fileprivate init(
    build: String,
    bundle: URL,
    manifest: GuardianBuildManifest,
    registry: GuardianBuildRegistry
  ) {
    self.build = build
    self.bundle = bundle
    self.manifest = manifest
    self.registry = registry
  }
  deinit { registry.release(build) }
}

/// One registry belongs to the guardian. Installation publishes complete signed
/// version directories; it must never replace a published directory in place.
/// All validation/pinning/collection is serialized off the guardian I/O queue.
/// Sendable: pins and selection are guarded by `lock`.
package final class GuardianBuildRegistry: @unchecked Sendable {
  private let root: URL
  private let requirement: String?
  private let lock = NSRecursiveLock()
  private var pins: [String: Int] = [:]
  private var selected: String?
  private var rollback: String?
  private var selectionOwner: UUID?
  private let selectionStore: ImmutableBuildSelectionStore

  package init(root: URL, peerRequirement: String?) throws {
    self.root = root.standardizedFileURL
    requirement = peerRequirement
    selectionStore = ImmutableBuildSelectionStore(
      root: root.standardizedFileURL
    )
    try validateRoot()
    if let choice = try selectionStore.load() {
      _ = try pin(choice.selected)
      if let rollback = choice.rollback { _ = try pin(rollback) }
      selected = choice.selected
      rollback = choice.rollback
    }
  }

  package func selection() throws -> GuardianWorkerSelection {
    guard lock.try() else {
      throw MuxError(.quiescing, "build registry is busy")
    }
    defer { lock.unlock() }
    return GuardianWorkerSelection(selected: selected, rollback: rollback)
  }

  /// A serving guardian owns selection changes for this registry lifetime.
  /// Rebinding the same guardian is allowed when its control listener restarts.
  package func claimSelection(for guardian: UUID) {
    lock.lock()
    defer { lock.unlock() }
    precondition(selectionOwner == nil || selectionOwner == guardian)
    selectionOwner = guardian
  }

  func select(_ build: String, guardian: UUID) throws {
    lock.lock()
    defer { lock.unlock() }
    guard selectionOwner == guardian else {
      throw MuxError(.unauthorized, "guardian does not own worker selection")
    }
    try publishSelection(build)
  }

  /// Selection is a local installer decision before guardian ownership.
  /// No caller-supplied path enters the gateway protocol. The previous selection remains a protected rollback.
  package func select(_ build: String) throws {
    lock.lock();
    defer { lock.unlock() }
    guard selectionOwner == nil else {
      throw MuxError(.unauthorized, "live guardian owns worker selection")
    }
    try publishSelection(build)
  }

  private func publishSelection(_ build: String) throws {
    let validated = try pin(build)
    guard selected != validated.build else { return }
    try selectionStore.save(
      .init(selected: validated.build, rollback: selected)
    )
    rollback = selected
    selected = validated.build
  }

  package func selectRollback() throws {
    lock.lock();
    defer { lock.unlock() }
    guard let rollback else {
      throw MuxError(.notFound, "no rollback build retained")
    }
    try select(rollback)
  }

  /// Explicitly release the installation's rollback retention; live pins still
  /// protect that build. This does not remove any files.
  func clearRollback(guardian: UUID) throws {
    lock.lock()
    defer { lock.unlock() }
    guard selectionOwner == guardian else {
      throw MuxError(.unauthorized, "guardian does not own rollback retention")
    }
    try publishClearedRollback()
  }

  package func clearRollback() throws {
    lock.lock();
    defer { lock.unlock() }
    guard selectionOwner == nil else {
      throw MuxError(.unauthorized, "live guardian owns rollback retention")
    }
    try publishClearedRollback()
  }

  private func publishClearedRollback() throws {
    guard let selected, rollback != nil else { return }
    try validateRoot()
    try selectionStore.save(.init(selected: selected, rollback: nil))
    rollback = nil
  }

  /// Copy and validate privately, then publish a new immutable version with
  /// no replacement. Failure cannot alter existing versions or selection.
  package func install(bundle source: URL, build: String) throws {
    lock.lock();
    defer { lock.unlock() }
    try validateRoot()
    let destination = try versionDirectory(build)
    let source = source.standardizedFileURL
    guard source.isFileURL, source.path == source.resolvingSymlinksInPath().path
    else {
      throw MuxError(.unauthorized, "installation source contains a symlink")
    }
    try validateBundle(source, build: build)
    let staging = root.appendingPathComponent(
      ".install-" + UUID().uuidString,
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: staging,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: staging) }
    let copy = staging.appendingPathComponent("Worker.app", isDirectory: true)
    try FileManager.default.copyItem(at: source, to: copy)
    try validateBundle(copy, build: build)
    guard renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0
    else {
      throw MuxError(
        .launchFailed,
        "cannot publish worker build; existing versions are never replaced"
      )
    }
  }

  package func pinSelected() throws -> GuardianBuildPin {
    lock.lock();
    defer { lock.unlock() }
    guard let selected else {
      throw MuxError(.notFound, "no worker build selected")
    }
    return try pin(selected)
  }

  package func pin(_ build: String) throws -> GuardianBuildPin {
    lock.lock();
    defer { lock.unlock() }
    try validateRoot()
    let directory = try versionDirectory(build)
    try GuardianArtifactValidation.check(
      directory,
      directory: true,
      privateDirectory: true
    )
    let bundle = directory.appendingPathComponent(
      "Worker.app",
      isDirectory: true
    )
    let manifest = try validateBundle(bundle, build: build)
    pins[build, default: 0] += 1
    return GuardianBuildPin(
      build: build,
      bundle: bundle,
      manifest: manifest,
      registry: self
    )
  }

  @discardableResult
  private func validateBundle(
    _ bundle: URL,
    build: String
  ) throws -> GuardianBuildManifest {
    try GuardianArtifactValidation.validateTree(bundle)
    let manifestURL = bundle.appendingPathComponent(
      "Contents/Resources/build.json"
    )
    let size = try GuardianArtifactValidation.check(
      manifestURL,
      directory: false
    )
    guard size <= 65536 else {
      throw MuxError(.resourceLimit, "build manifest too large")
    }
    let manifest = try JSONDecoder()
      .decode(GuardianBuildManifest.self, from: Data(contentsOf: manifestURL))
    guard manifest.schema == 1, manifest.build == build,
      manifest.guardianProtocol == GuardianWire.version,
      SMX.compatibleVersions.contains(manifest.workerProtocol)
    else { throw MuxError(.incompatibleVersion, "incompatible worker build") }
    for name in ["swiftmux-worker", "swmux-launcher", "swsh"] {
      let file = bundle.appendingPathComponent("Contents/MacOS/" + name)
      try GuardianArtifactValidation.check(file, directory: false)
      guard access(file.path, X_OK) == 0 else {
        throw MuxError(.unauthorized, "build executable is not executable")
      }
      if let requirement {
        try GuardianWorkerProcess.validateSignature(
          file.path,
          requirement: requirement
        )
      }
    }
    try GuardianArtifactValidation.check(
      bundle.appendingPathComponent("Contents/Resources/terminfo"),
      directory: true
    )
    if let requirement {
      try GuardianWorkerProcess.validateSignature(
        bundle.path,
        requirement: requirement
      )
    }
    return manifest
  }

  /// Explicit installer collection only. Selected, live, unavailable and
  /// pending-launch references all prevent removal.
  package func remove(_ build: String) throws {
    lock.lock();
    defer { lock.unlock() }
    guard selected != build, rollback != build, pins[build, default: 0] == 0
    else { throw MuxError(.quiescing, "worker build remains pinned") }
    try validateRoot()
    let directory = try versionDirectory(build)
    try GuardianArtifactValidation.check(
      directory,
      directory: true,
      privateDirectory: true
    )
    try GuardianArtifactValidation.validateTree(directory)
    try FileManager.default.removeItem(at: directory)
  }

  fileprivate func release(_ build: String) {
    lock.lock();
    defer { lock.unlock() }
    precondition(pins[build, default: 0] > 0)
    pins[build]! -= 1
    if pins[build] == 0 { pins.removeValue(forKey: build) }
  }

  private func versionDirectory(_ build: String) throws -> URL {
    guard !build.isEmpty, build.utf8.count <= 128, !build.hasPrefix("."),
      build.utf8.allSatisfy({
        (48 ... 57).contains($0) || (65 ... 90).contains($0)
          || (97 ... 122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
      })
    else { throw MuxError(.invalidRequest, "invalid build identifier") }
    return root.appendingPathComponent(build, isDirectory: true)
  }

  private func validateRoot() throws {
    guard root.isFileURL, root.path == root.resolvingSymlinksInPath().path
    else { throw MuxError(.unauthorized, "build root contains a symlink") }
    try GuardianArtifactValidation.check(
      root,
      directory: true,
      privateDirectory: true
    )
  }

}
