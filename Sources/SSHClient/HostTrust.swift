import Crypto
import Foundation
import NIOCore
import NIOSSH
import Synchronization

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The configured host identity and port that trust is scoped to
/// (spec §5.1). Never a resolved IP address unless the user configured
/// one.
public struct HostIdentity: Hashable, Sendable, Codable, CustomStringConvertible
{
  /// Lowercased configured host name or address literal.
  public let host: String
  public let port: Int

  /// Returns `nil` for an empty host, whitespace/control characters or a
  /// port outside 1...65535.
  public init?(host: String, port: Int) {
    let normalized = host.lowercased()
    guard !normalized.isEmpty, normalized.utf8.count <= 255,
      (1 ... 65535).contains(port),
      normalized.unicodeScalars.allSatisfy({
        $0.value > 0x20 && $0.value != 0x7F && !$0.properties.isWhitespace
      })
    else { return nil }
    self.host = normalized
    self.port = port
  }

  public var description: String {
    host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
  }
}

/// SSH public-key helpers shared by host trust and key export.
public enum SSHPublicKeyFormat {
  /// OpenSSH fingerprint `SHA256:<unpadded base64>` of the key blob in an
  /// `"<type> <base64>"` public-key line.
  public static func fingerprint(openSSHPublicKey line: String) -> String? {
    guard let blob = keyBlob(openSSHPublicKey: line) else { return nil }
    return fingerprint(blob: blob)
  }

  public static func fingerprint(blob: [UInt8]) -> String {
    let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
    var trimmed = Substring(digest)
    while trimmed.last == "=" { trimmed.removeLast() }
    return "SHA256:" + trimmed
  }

  /// The decoded key blob of a `"<type> <base64>"` line.
  public static func keyBlob(openSSHPublicKey line: String) -> [UInt8]? {
    let parts = line.split(separator: " ", omittingEmptySubsequences: true)
    guard parts.count >= 2, let data = Data(base64Encoded: String(parts[1]))
    else { return nil }
    return Array(data)
  }

  static func openSSHLine(_ key: NIOSSHPublicKey) -> String {
    String(openSSHPublicKey: key)
  }

  /// Key algorithm name, such as `ssh-ed25519`.
  public static func keyType(openSSHPublicKey line: String) -> String {
    String(line.split(separator: " ").first ?? "")
  }
}

/// Trusted SSH host public keys keyed by `HostIdentity`. Stores public
/// keys only.
public protocol HostTrustStore: Sendable {
  /// The trusted OpenSSH public-key line (`"<type> <base64>"`), if any.
  func trustedKey(for host: HostIdentity) async throws -> String?
  /// Records an explicitly approved key. Callers replace an existing key
  /// only after an explicit user decision.
  func setTrustedKey(
    _ openSSHPublicKey: String,
    for host: HostIdentity,
  ) async throws
  /// Atomically records an approved unknown key only if no key is present.
  /// Returns the existing key or the newly recorded key. A concurrent
  /// approval must never replace a different key. Implementations must
  /// coordinate this operation with reads, replacement and removal.
  func trustKeyIfAbsent(
    _ openSSHPublicKey: String,
    for host: HostIdentity,
  ) async throws -> String
  func removeTrustedKey(for host: HostIdentity) async throws
}

/// Volatile trust store for tests and "trust once" sessions.
public actor InMemoryHostTrustStore: HostTrustStore {
  private var keys: [HostIdentity: String]

  public init(keys: [HostIdentity: String] = [:]) { self.keys = keys }

  public func trustedKey(for host: HostIdentity) -> String? { keys[host] }

  public func setTrustedKey(_ openSSHPublicKey: String, for host: HostIdentity)
  { keys[host] = openSSHPublicKey }

  public func trustKeyIfAbsent(
    _ openSSHPublicKey: String,
    for host: HostIdentity,
  ) -> String {
    if let existing = keys[host] { return existing }
    keys[host] = openSSHPublicKey
    return openSSHPublicKey
  }

  public func removeTrustedKey(for host: HostIdentity) { keys[host] = nil }
}

/// JSON-file trust store holding public keys only. Writes are atomic;
/// a corrupt or oversized file fails closed rather than being treated
/// as empty. All instances in this process coordinate file access; changes
/// are read from disk instead of keeping an instance-local cache.
public actor FileHostTrustStore: HostTrustStore {
  public static let maxFileBytes = 1024 * 1024
  public static let maxEntries = 4096

  struct Entry: Codable, Hashable {
    var host: String
    var port: Int
    var publicKey: String
  }

  struct Contents: Codable {
    var version = 1
    var entries: [Entry] = []
  }

  public enum StoreError: Error, Equatable {
    case corrupt, tooLarge, tooManyEntries
  }

  public let fileURL: URL
  private static let fileAccess = NSLock()

  public init(fileURL: URL) { self.fileURL = fileURL }

  public func trustedKey(for host: HostIdentity) throws -> String? {
    try Self.fileAccess.withLock { try load()[host] }
  }

  public func setTrustedKey(
    _ openSSHPublicKey: String,
    for host: HostIdentity,
  ) throws {
    try Self.fileAccess.withLock {
      var keys = try load()
      keys[host] = openSSHPublicKey
      guard keys.count <= Self.maxEntries else {
        throw StoreError.tooManyEntries
      }
      try save(keys)
    }
  }

  public func trustKeyIfAbsent(
    _ openSSHPublicKey: String,
    for host: HostIdentity,
  ) throws -> String {
    try Self.fileAccess.withLock {
      var keys = try load()
      if let existing = keys[host] { return existing }
      keys[host] = openSSHPublicKey
      guard keys.count <= Self.maxEntries else {
        throw StoreError.tooManyEntries
      }
      try save(keys)
      return openSSHPublicKey
    }
  }

  /// Every trusted key, for opt-in trust sync.
  public func entries() throws -> [HostIdentity: String] {
    try Self.fileAccess.withLock { try load() }
  }

  public func removeTrustedKey(for host: HostIdentity) throws {
    try Self.fileAccess.withLock {
      var keys = try load()
      keys[host] = nil
      try save(keys)
    }
  }

  private func load() throws -> [HostIdentity: String] {
    guard let data = try readContents() else { return [:] }
    guard let contents = try? JSONDecoder().decode(Contents.self, from: data),
      contents.version == 1, contents.entries.count <= Self.maxEntries
    else { throw StoreError.corrupt }
    var keys: [HostIdentity: String] = [:]
    for entry in contents.entries {
      guard let id = HostIdentity(host: entry.host, port: entry.port),
        SSHPublicKeyFormat.keyBlob(openSSHPublicKey: entry.publicKey) != nil
      else { throw StoreError.corrupt }
      keys[id] = entry.publicKey
    }
    return keys
  }

  /// Size checks and reads use the same opened file. Follow regular-file
  /// aliases as before. Retain at most the byte cap and read one extra byte
  /// only to detect growth beyond it.
  private func readContents() throws -> Data? {
    guard fileURL.isFileURL, !fileURL.path.utf8.contains(0) else {
      throw StoreError.corrupt
    }
    let descriptor = open(fileURL.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 0 else {
      let code = errno
      if code == ENOENT {
        var info = stat()
        if lstat(fileURL.path, &info) == 0 { throw StoreError.corrupt }
        if errno == ENOENT { return nil }
      }
      throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    defer { _ = close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
      throw StoreError.corrupt
    }
    guard info.st_size <= Self.maxFileBytes else { throw StoreError.tooLarge }
    var data = Data()
    data.reserveCapacity(Int(info.st_size))
    var buffer = [UInt8](repeating: 0, count: 16 << 10)
    while true {
      let count = buffer.withUnsafeMutableBytes {
        read(
          descriptor,
          $0.baseAddress,
          min($0.count, Self.maxFileBytes - data.count + 1)
        )
      }
      if count < 0 {
        if errno == EINTR { continue }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      if count == 0 { return data }
      guard count <= Self.maxFileBytes - data.count else {
        throw StoreError.tooLarge
      }
      data.append(contentsOf: buffer.prefix(count))
    }
  }

  private func save(_ keys: [HostIdentity: String]) throws {
    var contents = Contents()
    contents.entries =
      keys.map {
        Entry(host: $0.key.host, port: $0.key.port, publicKey: $0.value)
      }
      .sorted { ($0.host, $0.port) < ($1.host, $1.port) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(contents)
    guard data.count <= Self.maxFileBytes else { throw StoreError.tooLarge }
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true,
    )
    try data.write(to: fileURL, options: [.atomic])
  }
}

/// Presented to the user when a host key is not yet trusted.
public struct HostTrustRequest: Sendable, Hashable {
  public let host: HostIdentity
  /// Key algorithm, e.g. `ssh-ed25519`.
  public let keyType: String
  /// OpenSSH `SHA256:<base64>` fingerprint.
  public let fingerprint: String
  /// The presented OpenSSH public-key line.
  public let publicKey: String
}

public enum HostTrustDecision: Sendable, Hashable {
  /// Trust and record the key in the store.
  case trustAndRemember
  /// Trust for this connection only.
  case trustOnce
  case reject
}

/// Explicit decision for an unknown host key. The connection waits for
/// the answer; nothing is sent to the server until it arrives.
/// The decision task is cancelled when the connection closes. Implementations
/// should return `.reject` promptly after cancellation to release their resources.
public protocol HostTrustDecider: Sendable {
  func decide(_ request: HostTrustRequest) async -> HostTrustDecision
}

public struct ClosureHostTrustDecider: HostTrustDecider {
  let body: @Sendable (HostTrustRequest) async -> HostTrustDecision
  public init(
    _ body: @escaping @Sendable (HostTrustRequest) async -> HostTrustDecision
  ) { self.body = body }
  public func decide(_ request: HostTrustRequest) async -> HostTrustDecision {
    await body(request)
  }
}

/// Rejects every unknown key; use for automatic reconnection, which must
/// never prompt.
public struct RejectUnknownHostKeys: HostTrustDecider {
  public init() {}
  public func decide(_ request: HostTrustRequest) async -> HostTrustDecision {
    .reject
  }
}

/// NIOSSH host-key callback: completes only after the store/decider
/// approve, so user authentication never starts for an untrusted key.
final class HostKeyVerifier: NIOSSHClientServerAuthenticationDelegate, Sendable
{
  let host: HostIdentity
  let store: any HostTrustStore
  let decider: any HostTrustDecider
  /// Pairing-code fingerprints the presented key must match, if any.
  let expected: Set<String>?
  /// The first trust failure, reported by `connect` instead of the
  /// generic NIO error.
  let failure = Mutex<SSHClientError?>(nil)
  /// Key accepted during this connection, so a rekey must present the
  /// same key.
  let accepted = Mutex<String?>(nil)
  private struct Pending {
    let id: UUID
    let task: Task<Void, Never>
    let promise: EventLoopPromise<Void>
  }

  private struct Lifetime {
    var closed = false
    var pending: Pending?
  }

  private let lifetime = Mutex(Lifetime())

  init(
    host: HostIdentity,
    store: any HostTrustStore,
    decider: any HostTrustDecider,
    expected: Set<String>? = nil
  ) {
    self.host = host
    self.store = store
    self.decider = decider
    self.expected = expected
  }

  func validateHostKey(
    hostKey: NIOSSHPublicKey,
    validationCompletePromise: EventLoopPromise<Void>
  ) {
    guard !lifetime.withLock({ $0.closed }) else {
      validationCompletePromise.fail(SSHClientError.connectionClosed)
      return
    }
    let line = SSHPublicKeyFormat.openSSHLine(hostKey)
    if let previous = accepted.withLock({ $0 }) {
      if previous == line {
        validationCompletePromise.succeed()
      } else {
        fail(
          .hostKeyChanged(
            host: host,
            expected: SSHPublicKeyFormat.fingerprint(openSSHPublicKey: previous)
              ?? "",
            presented: SSHPublicKeyFormat.fingerprint(openSSHPublicKey: line)
              ?? ""
          ),
          validationCompletePromise
        )
      }
      return
    }
    let started = lifetime.withLock { state in
      // NIOSSH waits for one validation before completing key exchange.
      guard !state.closed, state.pending == nil else { return false }
      let id = UUID()
      let task = Task { [self] in
        let result: SSHClientError?
        do { result = try await evaluate(line) } catch is CancellationError {
          result = .connectionClosed
        } catch { result = .trustStoreUnavailable }
        validationCompletePromise.futureResult.eventLoop.execute {
          self.complete(id, line: line, result: result)
        }
      }
      state.pending = Pending(
        id: id,
        task: task,
        promise: validationCompletePromise
      )
      return true
    }
    if !started {
      validationCompletePromise.fail(SSHClientError.connectionClosed)
    }
  }

  // Called on the channel's event loop, including while validation is suspended.
  func connectionClosed() {
    let pending = lifetime.withLock { state in
      state.closed = true
      let pending = state.pending
      state.pending = nil
      return pending
    }
    pending?.task.cancel()
    pending?.promise.fail(SSHClientError.connectionClosed)
  }

  private func complete(_ id: UUID, line: String, result: SSHClientError?) {
    let pending = lifetime.withLock { state in
      guard state.pending?.id == id else { return Optional<Pending>.none }
      let pending = state.pending
      state.pending = nil
      return pending
    }
    // A closed connection already failed the promise. A late task cannot
    // complete it twice or change the connection's accepted key/failure.
    guard let pending else { return }
    if let result {
      fail(result, pending.promise)
    } else {
      accepted.withLock { $0 = line }
      pending.promise.succeed()
    }
  }

  /// Returns the failure, or `nil` when the key is trusted.
  private func evaluate(_ line: String) async throws -> SSHClientError? {
    try Task.checkCancellation()
    let presented = SSHPublicKeyFormat.fingerprint(openSSHPublicKey: line) ?? ""
    // A pairing expectation is enforced first, for known and unknown keys
    // alike: neither the store nor the decider can accept another key.
    if let expected, !expected.contains(presented) {
      return .hostKeyMismatch(host: host, presented: presented)
    }
    let trusted = try await store.trustedKey(for: host)
    try Task.checkCancellation()
    if let trusted {
      guard trusted == line else {
        return .hostKeyChanged(
          host: host,
          expected: SSHPublicKeyFormat.fingerprint(openSSHPublicKey: trusted)
            ?? "",
          presented: presented
        )
      }
      return nil
    }
    let request = HostTrustRequest(
      host: host,
      keyType: SSHPublicKeyFormat.keyType(openSSHPublicKey: line),
      fingerprint: presented,
      publicKey: line
    )
    let decision = await decider.decide(request)
    try Task.checkCancellation()
    switch decision {
    case .trustAndRemember:
      // A separate read followed by set can overwrite a concurrent approval.
      let trusted = try await store.trustKeyIfAbsent(line, for: host)
      try Task.checkCancellation()
      if trusted != line {
        return .hostKeyChanged(
          host: host,
          expected: SSHPublicKeyFormat.fingerprint(openSSHPublicKey: trusted)
            ?? "",
          presented: presented
        )
      }
      return nil
    case .trustOnce: return nil
    case .reject: return .hostKeyRejected(host: host, fingerprint: presented)
    }
  }

  private func fail(_ error: SSHClientError, _ promise: EventLoopPromise<Void>)
  {
    failure.withLock { if $0 == nil { $0 = error } }
    promise.fail(error)
  }
}
