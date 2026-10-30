import Foundation
import SessionCore

/// Non-secret workspace choices. Owned entries live separately from legacy UUID
/// entries, whose account/endpoint cannot be inferred safely. The chooser lets
/// users select an existing workspace again after fresh SSH authorization (§9).
///
/// Sendable: the stored `defaults` and `key` are immutable; every read/modify/
/// write of the persisted dictionaries holds the process-wide `access` lock.
/// The retained `UserDefaults` is itself thread-safe.
public struct SessionResumeStore: @unchecked Sendable {
  public static let key = "roaming.resume.v1"
  // UserDefaults synchronizes individual operations, not read/modify/write.
  // Share ownership across instances, including separate handles for one suite.
  // Recursive locking permits synchronous defaults observers to read the store.
  private static let access = NSRecursiveLock()
  let defaults: UserDefaults
  let key: String

  public init(
    defaults: UserDefaults = .standard,
    key: String = SessionResumeStore.key,
  ) {
    self.defaults = defaults
    self.key = key
  }

  private var ownedKey: String { key + ".owners.v1" }

  private func entryKey(_ owner: HostDataOwner) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return (try? encoder.encode(owner))?.base64EncodedString()
  }

  func sessionID(for owner: HostDataOwner) -> SessionID? {
    Self.access.lock()
    defer { Self.access.unlock() }
    guard let name = entryKey(owner),
      let hex = defaults.dictionary(forKey: ownedKey)?[name] as? String
    else { return nil }
    return SessionID(hex: hex)
  }

  func set(_ session: SessionID?, for owner: HostDataOwner) {
    Self.access.lock()
    defer { Self.access.unlock() }
    guard let name = entryKey(owner) else { return }
    var raw = defaults.dictionary(forKey: ownedKey) ?? [:]
    raw[name] = session?.hex
    defaults.set(raw, forKey: ownedKey)
  }

  /// Legacy host UUID entries, skipping malformed values. Kept for inspection;
  /// application resume lookups always supply the full owner.
  public func all() -> [UUID: SessionID] {
    Self.access.lock()
    defer { Self.access.unlock() }
    guard let raw = defaults.dictionary(forKey: key) else { return [:] }
    var out: [UUID: SessionID] = [:]
    for (host, session) in raw {
      if let session = session as? String, let host = UUID(uuidString: host),
        let session = SessionID(hex: session)
      {
        out[host] = session
      }
    }
    return out
  }

  public func sessionID(for host: UUID) -> SessionID? { all()[host] }

  public func set(_ session: SessionID?, for host: UUID) {
    Self.access.lock()
    defer { Self.access.unlock() }
    var raw = defaults.dictionary(forKey: key) ?? [:]
    raw[host.uuidString] = session?.hex
    defaults.set(raw, forKey: key)
  }
}
