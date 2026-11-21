import CryptoKit
import Darwin
import Foundation
import Security
import SwiftMuxProtocol
import Synchronization

// Sealed record files (spec.durability.md §12.2.4).

/// One plaintext section of a sealed record.
package struct SavedLayoutSection: Sendable, Equatable {
  package enum Kind: UInt8, Sendable {
    /// Header, workspace and panes as canonical JSON.
    case record = 1
    /// C1 output for one slot.
    case output = 2
    /// C1 output carried over from the record this workspace reopened.
    case previousOutput = 3
  }

  package var kind: Kind
  package var bytes: Data

  package init(kind: Kind, bytes: Data) {
    self.kind = kind
    self.bytes = bytes
  }
}

package enum SavedLayoutSeal {
  static let magic = Data("SMXS".utf8)
  static let formatVersion: UInt16 = 1
  /// Plaintext bound: layout, output and previous output together.
  package static let plaintextLimit = 64 << 20

  /// AES-256-GCM. The authenticated data binds the file to its record
  /// identity and generation, so a renamed file fails authentication.
  package static func seal(
    _ sections: [SavedLayoutSection],
    workspace: WorkspaceID,
    generation: UInt64,
    key: SymmetricKey
  ) throws -> Data {
    var plaintext = Data()
    append(UInt16(sections.count), to: &plaintext)
    for section in sections {
      plaintext.append(section.kind.rawValue)
      append(UInt32(section.bytes.count), to: &plaintext)
      plaintext.append(section.bytes)
    }
    guard plaintext.count <= plaintextLimit else {
      throw MuxError(.resourceLimit, "saved layout record too large")
    }
    let header = self.header()
    let box = try AES.GCM.seal(
      plaintext,
      using: key,
      authenticating: header
        + authenticated(workspace: workspace, generation: generation)
    )
    guard let combined = box.combined else {
      throw MuxError(.invalidRequest, "cannot seal saved layout record")
    }
    return header + combined
  }

  package static func open(
    _ data: Data,
    workspace: WorkspaceID,
    generation: UInt64,
    key: SymmetricKey
  ) throws -> [SavedLayoutSection] {
    let header = self.header()
    guard data.count > header.count + 28,
      data.count <= plaintextLimit + header.count + 28,
      data.prefix(header.count) == header
    else { throw MuxError(.invalidRequest, "not a saved layout record") }
    let box = try AES.GCM.SealedBox(combined: data.dropFirst(header.count))
    let plaintext = try AES.GCM.open(
      box,
      using: key,
      authenticating: header
        + authenticated(workspace: workspace, generation: generation)
    )
    var reader = Reader(plaintext)
    let count = try reader.uint16()
    guard count <= 1 + 2 * 64 else {
      throw MuxError(.invalidRequest, "too many saved layout sections")
    }
    var sections: [SavedLayoutSection] = []
    for _ in 0 ..< count {
      guard let kind = SavedLayoutSection.Kind(rawValue: try reader.uint8())
      else { throw MuxError(.invalidRequest, "unknown saved layout section") }
      let length = Int(try reader.uint32())
      sections.append(
        SavedLayoutSection(kind: kind, bytes: try reader.bytes(length))
      )
    }
    guard reader.isAtEnd else {
      throw MuxError(.invalidRequest, "trailing saved layout bytes")
    }
    return sections
  }

  private static func header() -> Data {
    var data = magic
    append(formatVersion, to: &data)
    append(UInt16(0), to: &data)  // flags
    return data
  }

  private static func authenticated(
    workspace: WorkspaceID,
    generation: UInt64
  ) -> Data { Data("\(workspace.description).\(generation)".utf8) }

  static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
  }

  struct Reader {
    let data: Data
    var offset: Int
    init(_ data: Data) {
      self.data = data
      offset = data.startIndex
    }
    var isAtEnd: Bool { offset == data.endIndex }
    mutating func bytes(_ count: Int) throws -> Data {
      guard count >= 0, count <= data.endIndex - offset else {
        throw MuxError(.invalidRequest, "truncated saved layout record")
      }
      defer { offset += count }
      return data[offset ..< offset + count]
    }
    mutating func uint8() throws -> UInt8 { try bytes(1).first! }
    mutating func uint16() throws -> UInt16 {
      try bytes(2).reduce(0) { $0 << 8 | UInt16($1) }
    }
    mutating func uint32() throws -> UInt32 {
      try bytes(4).reduce(0) { $0 << 8 | UInt32($1) }
    }
  }

  /// Canonical JSON for record sections.
  package static func encode(_ record: SavedLayoutRecord) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .millisecondsSince1970
    return try encoder.encode(record)
  }

  /// Distinguishes a newer schema from corruption before full decoding.
  package static func decode(_ data: Data) throws -> SavedLayoutRecord {
    struct Probe: Decodable { let schema: Int }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    let probe = try decoder.decode(Probe.self, from: data)
    guard probe.schema <= SavedLayoutRecord.schema else {
      throw SavedLayoutNewerSchema(schema: probe.schema)
    }
    return try decoder.decode(SavedLayoutRecord.self, from: data)
  }
}

package struct SavedLayoutNewerSchema: Error, Sendable {
  package let schema: Int
}

// MARK: Key

package enum SavedLayoutKeyLookup: Sendable {
  case found(SymmetricKey)
  /// Only `errSecItemNotFound`: the key is gone.
  case notFound
  /// Locked, denied, interaction not allowed or an I/O error: retry later.
  case unavailable(String)
}

package protocol SavedLayoutKeyStore: Sendable {
  func lookup() -> SavedLayoutKeyLookup
  func create() throws -> SymmetricKey
  func delete() throws
}

/// The user's login keychain. An item the signed gateway creates is
/// partitioned to its team by default; the gateway never shows UI.
package struct LoginKeychainKeyStore: SavedLayoutKeyStore {
  package let service: String
  private let account = "saved-workspaces"

  package init(service: String) { self.service = service }

  private var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service, kSecAttrAccount as String: account,
    ]
  }

  package func lookup() -> SavedLayoutKeyLookup {
    var request = query
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    request[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    switch status {
    case errSecSuccess:
      guard let data = result as? Data, data.count == 32 else {
        return .unavailable("saved layout key has an invalid size")
      }
      return .found(SymmetricKey(data: data))
    case errSecItemNotFound: return .notFound
    default: return .unavailable("keychain status \(status)")
    }
  }

  package func create() throws -> SymmetricKey {
    let key = SymmetricKey(size: .bits256)
    var item = query
    item[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
    item[kSecAttrLabel as String] = "Swiftty saved workspaces"
    item[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw MuxError(.unauthorized, "cannot store saved layout key (\(status))")
    }
    return key
  }

  package func delete() throws {
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw MuxError(
        .unauthorized,
        "cannot delete saved layout key (\(status))"
      )
    }
  }
}

/// Test key store; `unavailable` simulates a locked keychain.
package final class MemoryKeyStore: SavedLayoutKeyStore {
  private let state = Mutex<(key: SymmetricKey?, unavailable: String?)>(
    (nil, nil)
  )

  package init() {}

  package func setUnavailable(_ reason: String?) {
    state.withLock { $0.unavailable = reason }
  }
  package func removeKey() { state.withLock { $0.key = nil } }
  package var hasKey: Bool { state.withLock { $0.key != nil } }

  package func lookup() -> SavedLayoutKeyLookup {
    state.withLock { value in
      if let reason = value.unavailable { return .unavailable(reason) }
      return value.key.map(SavedLayoutKeyLookup.found) ?? .notFound
    }
  }
  package func create() throws -> SymmetricKey {
    try state.withLock { value in
      if let reason = value.unavailable {
        throw MuxError(.unauthorized, reason)
      }
      let key = SymmetricKey(size: .bits256)
      value.key = key
      return key
    }
  }
  package func delete() throws {
    try state.withLock { value in
      if let reason = value.unavailable {
        throw MuxError(.unauthorized, reason)
      }
      value.key = nil
    }
  }
}

// MARK: Files

/// `<root>/saved/workspaces/<workspace>.<generation>.smxs`, the quarantine
/// and `<root>/saved-policy.json`. Not thread-safe: one owner serializes it.
package final class SavedLayoutFiles: @unchecked Sendable {
  package let root: URL
  package var saved: URL { root.appendingPathComponent("saved") }
  package var workspaces: URL { saved.appendingPathComponent("workspaces") }
  package var quarantine: URL { saved.appendingPathComponent("quarantine") }
  package var policy: URL { root.appendingPathComponent("saved-policy.json") }
  private let fileManager = FileManager.default
  static let suffix = ".smxs"
  static let quarantineFiles = 8
  static let quarantineBytes = 64 << 20

  package init(root: URL) { self.root = root }

  /// Creates owner-only directories excluded from backups and removes
  /// temporary files a crash left behind.
  package func prepare() throws {
    for directory in [root, saved, workspaces, quarantine] {
      try fileManager.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    }
    try fileManager.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: saved.path
    )
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var url = saved
    try url.setResourceValues(values)
    for name in try fileManager.contentsOfDirectory(atPath: workspaces.path)
    where name.hasPrefix(".tmp-") {
      try? fileManager.removeItem(at: workspaces.appendingPathComponent(name))
    }
  }

  /// Generations per record, newest last. Unparseable names are ignored.
  package func generations() throws -> [WorkspaceID: [UInt64]] {
    var result: [WorkspaceID: [UInt64]] = [:]
    for name in try fileManager.contentsOfDirectory(atPath: workspaces.path)
    where name.hasSuffix(Self.suffix) && !name.hasPrefix(".") {
      let stem = name.dropLast(Self.suffix.count)
      let parts = stem.split(separator: ".", omittingEmptySubsequences: false)
      guard parts.count == 2, let id = WorkspaceID(String(parts[0])),
        let generation = UInt64(parts[1]), generation > 0
      else { continue }
      result[id, default: []].append(generation)
    }
    return result.mapValues { $0.sorted() }
  }

  private func url(_ id: WorkspaceID, _ generation: UInt64) -> URL {
    workspaces.appendingPathComponent(
      "\(id.description).\(generation)\(Self.suffix)"
    )
  }

  package func read(_ id: WorkspaceID, generation: UInt64) throws -> Data {
    let url = url(id, generation)
    let size =
      (try fileManager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    guard size <= SavedLayoutSeal.plaintextLimit + 64 else {
      throw MuxError(.resourceLimit, "saved layout file too large")
    }
    return try Data(contentsOf: url)
  }

  /// Temporary file, `F_BARRIERFSYNC`, rename, directory flush. A torn write
  /// leaves the previous generation intact.
  package func write(_ data: Data, _ id: WorkspaceID, generation: UInt64) throws
  {
    let temporary = workspaces.appendingPathComponent(
      ".tmp-\(UUID().uuidString)"
    )
    let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard fd >= 0 else { throw posix("create") }
    var written = 0
    let failure: MuxError? = data.withUnsafeBytes { raw in
      while written < raw.count {
        let n = Darwin.write(
          fd,
          raw.baseAddress! + written,
          raw.count - written
        )
        if n < 0 {
          if errno == EINTR { continue }
          return posix("write")
        }
        written += n
      }
      if fcntl(fd, F_BARRIERFSYNC) != 0 && fsync(fd) != 0 {
        return posix("flush")
      }
      return nil
    }
    close(fd)
    if let failure {
      unlink(temporary.path)
      throw failure
    }
    guard rename(temporary.path, url(id, generation).path) == 0 else {
      let error = posix("rename")
      unlink(temporary.path)
      throw error
    }
    let directory = open(workspaces.path, O_RDONLY)
    if directory >= 0 {
      _ = fsync(directory)
      close(directory)
    }
  }

  package func remove(_ id: WorkspaceID, generation: UInt64) {
    try? fileManager.removeItem(at: url(id, generation))
  }

  package func removeAll(_ id: WorkspaceID) throws {
    for generation in try generations()[id] ?? [] {
      remove(id, generation: generation)
    }
  }

  package func removeEverything() throws {
    if fileManager.fileExists(atPath: saved.path) {
      try fileManager.removeItem(at: saved)
    }
  }

  /// Keeps the newest few unreadable files for diagnostics.
  package func quarantine(_ id: WorkspaceID, generation: UInt64) {
    let source = url(id, generation)
    let target = quarantine.appendingPathComponent(
      "\(id.description).\(generation).\(Int(Date().timeIntervalSince1970))"
    )
    if (try? fileManager.moveItem(at: source, to: target)) == nil {
      try? fileManager.removeItem(at: source)
    }
    let entries =
      ((try? fileManager.contentsOfDirectory(
        at: quarantine,
        includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
      )) ?? [])
      .sorted {
        let a =
          (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate ?? .distantPast
        let b =
          (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate ?? .distantPast
        return a > b
      }
    var bytes = 0
    for (index, entry) in entries.enumerated() {
      bytes +=
        (try? entry.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
      if index >= Self.quarantineFiles || bytes > Self.quarantineBytes {
        try? fileManager.removeItem(at: entry)
      }
    }
  }

  package func totalBytes() -> Int {
    let entries =
      (try? fileManager.contentsOfDirectory(
        at: workspaces,
        includingPropertiesForKeys: [.fileSizeKey]
      )) ?? []
    return entries.reduce(0) {
      $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
  }

  // MARK: Policy

  /// Nil when missing (defaults). Throws when unreadable or invalid.
  package func readPolicy() throws -> SavedLayoutPolicy? {
    guard fileManager.fileExists(atPath: policy.path) else { return nil }
    let data = try Data(contentsOf: policy)
    guard data.count <= 64 << 10 else {
      throw MuxError(.invalidRequest, "saved layout policy too large")
    }
    let value = try JSONDecoder().decode(SavedLayoutPolicy.self, from: data)
    guard value.isValid else {
      throw MuxError(.invalidRequest, "invalid saved layout policy")
    }
    return value
  }

  package func writePolicy(_ value: SavedLayoutPolicy) throws {
    try fileManager.createDirectory(
      at: root,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let data = try encoder.encode(value)
    let temporary = root.appendingPathComponent(".saved-policy-\(UUID())")
    guard
      fileManager.createFile(
        atPath: temporary.path,
        contents: data,
        attributes: [.posixPermissions: 0o600]
      )
    else { throw posix("create policy") }
    guard rename(temporary.path, policy.path) == 0 else {
      let error = posix("rename policy")
      unlink(temporary.path)
      throw error
    }
  }

  private func posix(_ operation: String) -> MuxError {
    MuxError(
      .resourceLimit,
      "saved layout \(operation) failed: \(String(cString: strerror(errno)))"
    )
  }
}
