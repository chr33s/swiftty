import Darwin
import Foundation
import SwiftMuxGuardian
import SwiftMuxProtocol

/// A process/resource reference, distinct from persistent installation choices.
/// Keep this alive until the corresponding gateway has actually retired.
package final class GatewayBuildPin: Sendable {
  package let artifact: GatewayUpdateArtifact
  private let registry: GatewayBuildRegistry

  fileprivate init(
    _ artifact: GatewayUpdateArtifact,
    registry: GatewayBuildRegistry
  ) {
    self.artifact = artifact
    self.registry = registry
  }

  deinit { registry.release(artifact.manifest.build) }
}

/// Single installation owner per version root. Staging may publish additional
/// immutable versions concurrently; only this owner changes choices or collects.
/// Registration/readiness and recovery of process pins belong to the updater.
/// Sendable: mutable choice and pins are guarded by `lock`.
package final class GatewayBuildRegistry: @unchecked Sendable {
  private let root: URL
  private let staging: GatewayUpdateStaging
  private let store: ImmutableBuildSelectionStore
  private let ownership: FileHandle
  private let lock = NSRecursiveLock()
  private var choice: ImmutableBuildSelectionStore.Selection?
  private var pins: [String: Int] = [:]

  package init(
    root: URL,
    bundleRequirement: String,
    executableRequirement: String,
    installation: GatewayInstallationPolicy
  ) throws {
    self.root = root.standardizedFileURL
    staging = try GatewayUpdateStaging(
      root: root,
      bundleRequirement: bundleRequirement,
      executableRequirement: executableRequirement,
      installation: installation
    )
    store = ImmutableBuildSelectionStore(root: self.root)
    ownership = try Self.acquireOwnership(self.root)
    choice = try store.load()
    if let choice {
      _ = try staging.load(choice.selected)
      if let rollback = choice.rollback { _ = try staging.load(rollback) }
    }
  }

  package func selection() -> ImmutableBuildSelectionStore.Selection? {
    lock.lock()
    defer { lock.unlock() }
    return choice
  }

  package func pin(_ build: String) throws -> GatewayBuildPin {
    lock.lock()
    defer { lock.unlock() }
    let artifact = try staging.load(build)
    pins[build, default: 0] += 1
    return GatewayBuildPin(artifact, registry: self)
  }

  /// Persists installation intent only. It does not register or start a gateway.
  package func select(_ build: String) throws {
    lock.lock()
    defer { lock.unlock() }
    let validated = try staging.load(build)
    guard choice?.selected != validated.manifest.build else { return }
    let next = ImmutableBuildSelectionStore.Selection(
      selected: validated.manifest.build,
      rollback: choice?.selected
    )
    try store.save(next)
    choice = next
  }

  package func selectRollback() throws {
    lock.lock()
    defer { lock.unlock() }
    guard let rollback = choice?.rollback else {
      throw MuxError(.notFound, "no gateway rollback retained")
    }
    try select(rollback)
  }

  package func clearRollback() throws {
    lock.lock()
    defer { lock.unlock() }
    guard let choice, choice.rollback != nil else { return }
    // Revalidate the remaining selected artifact before dropping rollback.
    _ = try staging.load(choice.selected)
    let next = ImmutableBuildSelectionStore.Selection(
      selected: choice.selected,
      rollback: nil
    )
    try store.save(next)
    self.choice = next
  }

  /// Explicit collection only. The updater must have reconciled live gateway
  /// references before invoking this after an installation-owner restart.
  package func remove(_ build: String) throws {
    lock.lock()
    defer { lock.unlock() }
    guard choice?.selected != build, choice?.rollback != build,
      pins[build, default: 0] == 0
    else { throw MuxError(.quiescing, "gateway build remains retained") }
    let artifact = try staging.load(build)
    let directory = artifact.bundle.deletingLastPathComponent()
    try GuardianArtifactValidation.validateTree(directory)
    try FileManager.default.removeItem(at: directory)
  }

  fileprivate func release(_ build: String) {
    lock.lock()
    defer { lock.unlock() }
    precondition(pins[build, default: 0] > 0)
    if pins[build] == 1 {
      pins.removeValue(forKey: build)
    } else {
      pins[build, default: 0] -= 1
    }
  }

  private static func acquireOwnership(_ root: URL) throws -> FileHandle {
    // Never unlink the lock file: a second inode would allow competing owners.
    let fd = open(
      root.appendingPathComponent(".installation.lock").path,
      O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC,
      0o600
    )
    guard fd >= 0 else {
      throw MuxError(.unauthorized, "cannot open gateway installation lock")
    }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    do {
      var info = stat()
      guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
        info.st_uid == geteuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1
      else { throw MuxError(.unauthorized, "unsafe gateway installation lock") }
      guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
        throw MuxError(.quiescing, "gateway installation already has an owner")
      }
      return handle
    } catch {
      try? handle.close()
      throw error
    }
  }
}
