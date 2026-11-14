import Foundation

/// Where the app keeps non-secret state: trusted host public keys,
/// transfer manifests and staged files. tvOS offers no durable local
/// storage, so it uses Caches there (spec §2.3).
package enum RoamingStorage {
  package static var directory: URL {
    if let override = UITesting.storageDirectory { return override }
    #if os(tvOS)
    let base = URL.cachesDirectory
    #else
    let base = URL.applicationSupportDirectory
    #endif
    return base.appending(path: "Swiftty", directoryHint: .isDirectory)
  }

  /// Trusted SSH host keys (public keys only).
  package static var knownHostsURL: URL {
    directory.appending(path: "known_hosts.json", directoryHint: .notDirectory)
  }
}
