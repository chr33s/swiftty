import Foundation

/// The version-1 `hosts.json` format, read only to migrate it into a
/// `ConnectionStore` snapshot (spec.ssh-identity.md §9). Never written.
public enum HostProfileStore {
  public static let version = 1
  public static let maxHosts = 256
  public static let maxFileBytes = 1 << 20

  package struct File: Codable {
    package var version: Int
    package var hosts: [HostProfile]

    package init(
      version: Int,
      hosts: [HostProfile]
    ) {
      self.version = version
      self.hosts = hosts
    }
  }

  /// Decodes a version-1 file. Key labels become `.legacyKey`.
  package static func decode(_ data: Data) throws(ConnectionStore.StoreError) -> [HostProfile] {
    guard data.count <= maxFileBytes else { throw .tooLarge }
    guard let file = try? JSONDecoder().decode(File.self, from: data) else {
      throw .malformed
    }
    guard file.version == version else {
      throw .unsupportedVersion(file.version)
    }
    guard file.hosts.count <= maxHosts else { throw .tooManyHosts }
    // Invalid entries and duplicate identities in hand-edited files
    // are skipped. Keep the first valid entry for each saved host.
    var identities: Set<UUID> = []
    return file.hosts.filter { $0.isValid && identities.insert($0.id).inserted }
  }
}
