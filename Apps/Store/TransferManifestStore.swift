#if !os(tvOS)
import Darwin
import Foundation
import SessionCore
import Synchronization

/// Non-secret transfer checkpoints, one bounded JSON file per manifest.
package struct TransferManifestStore: Sendable {
  package let directory: URL
  package var owner: HostDataOwner?

  package init(
    directory: URL,
    owner: HostDataOwner? = nil
  ) {
    self.directory = directory
    self.owner = owner
  }

  private struct Envelope: Codable {
    let version: Int
    let owner: HostDataOwner
    let manifest: TransferManifest
  }

  package enum StoreError: Error { case changedOwner, invalidCheckpoint }
  // Serializes ownership checks and replacement across browser instances.
  private static let mutations = NSLock()
  private static let active = Mutex<Set<URL>>([])

  private func useKey(_ id: UUID) -> URL {
    url(for: id).standardizedFileURL.resolvingSymlinksInPath()
  }

  package func isInUse(_ id: UUID) -> Bool {
    Self.active.withLock { $0.contains(useKey(id)) }
  }

  package func owns(_ id: UUID) -> Bool {
    guard let current = checkpoint(at: url(for: id)) else { return false }
    return current.owner == owner
  }

  /// Acquire the latest checkpoint and retain ownership until its I/O settles.
  /// A browser's cached progress may predate another browser's completed work.
  package func beginUse(_ id: UUID) -> TransferManifest? {
    Self.mutations.lock()
    defer { Self.mutations.unlock() }
    guard let current = checkpoint(at: url(for: id)), current.owner == owner,
      Self.active.withLock({ $0.insert(useKey(id)).inserted })
    else { return nil }
    return current.manifest
  }

  package func endUse(_ id: UUID) { Self.active.withLock { _ = $0.remove(useKey(id)) } }

  private func url(for id: UUID) -> URL {
    directory.appending(
      path: id.uuidString + ".json",
      directoryHint: .notDirectory
    )
  }

  package func save(_ manifest: TransferManifest) throws {
    Self.mutations.lock()
    defer { Self.mutations.unlock() }
    let path = url(for: manifest.id)
    if FileManager.default.fileExists(atPath: path.path) {
      guard let current = checkpoint(at: path), current.owner == owner else {
        throw StoreError.changedOwner
      }
    }
    try write(manifest)
  }

  private func write(_ manifest: TransferManifest) throws {
    // Check progress and the complete encoded envelope before touching disk.
    let data: Data
    if let owner {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      data = try encoder.encode(
        Envelope(version: 1, owner: owner, manifest: manifest)
      )
      guard manifest.hasValidProgress,
        data.count <= TransferManifest.maxEncodedBytes
      else { throw StoreError.invalidCheckpoint }
    } else {
      data = try manifest.encoded()
    }
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    try data.write(to: url(for: manifest.id), options: [.atomic])
  }

  package func remove(_ id: UUID) {
    Self.mutations.lock()
    defer { Self.mutations.unlock() }
    guard owns(id) else { return }
    try? FileManager.default.removeItem(at: url(for: id))
  }

  /// Unbound callers inspect all records (including legacy store tests). The
  /// browser always supplies an owner and receives only that owner's transfers.
  package func loadAll() -> [TransferManifest] {
    checkpoints().filter { owner == nil || $0.owner == owner }.map(\.manifest)
  }

  package func recoverable() -> [SavedTransfer] {
    guard let owner else { return [] }
    return checkpoints().filter { $0.canRecover(for: owner) }
  }

  /// Claim only the exact checkpoint the user reviewed. A second browser cannot
  /// adopt a record that the first browser has already claimed or updated.
  package func recover(_ reviewed: SavedTransfer, as manifest: TransferManifest) throws
  {
    Self.mutations.lock()
    defer { Self.mutations.unlock() }
    guard !Self.active.withLock({ $0.contains(useKey(reviewed.id)) }),
      let owner, reviewed.canRecover(for: owner), manifest.id == reviewed.id,
      checkpoint(at: url(for: reviewed.id)) == reviewed
    else { throw StoreError.changedOwner }
    try write(manifest)
  }

  private func checkpoints() -> [SavedTransfer] {
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
      )) ?? []
    return files.filter { $0.pathExtension == "json" }
      .compactMap { checkpoint(at: $0) }
  }

  private func checkpoint(at file: URL) -> SavedTransfer? {
    guard let data = read(file) else { return nil }
    if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
      guard envelope.version == 1, envelope.manifest.hasValidProgress else {
        return nil
      }
      return SavedTransfer(owner: envelope.owner, manifest: envelope.manifest)
    }
    // A corrupt/newer owned envelope must never downgrade to an unowned record.
    if let object = try? JSONSerialization.jsonObject(with: data)
      as? [String: Any],
      object["version"] != nil || object["owner"] != nil
        || object["manifest"] != nil
    {
      return nil
    }
    guard let manifest = try? TransferManifest.decode(data) else { return nil }
    return SavedTransfer(owner: nil, manifest: manifest)
  }

  /// Metadata and reads use one descriptor, including regular-file aliases.
  /// Nonblocking open makes FIFOs safe to reject before attempting a read.
  private func read(_ file: URL) -> Data? {
    guard file.isFileURL, !file.path.utf8.contains(0) else { return nil }
    let descriptor = Darwin.open(file.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 0 else { return nil }
    defer { Darwin.close(descriptor) }
    var info = Darwin.stat()
    let limit = TransferManifest.maxEncodedBytes
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_size >= 0, info.st_size <= limit
    else { return nil }
    var data = Data()
    data.reserveCapacity(Int(info.st_size))
    var chunk = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
      let count = chunk.withUnsafeMutableBytes {
        Darwin.read(
          descriptor,
          $0.baseAddress,
          min($0.count, limit - data.count + 1)
        )
      }
      if count < 0 {
        if errno == EINTR { continue }
        return nil
      }
      if count == 0 { return data }
      guard count <= limit - data.count else { return nil }
      data.append(contentsOf: chunk.prefix(count))
    }
  }
}
#endif
