import CryptoKit
import Darwin
import Foundation
import HostConnection
import Network
import Synchronization
import SystemConfiguration

/// Read-only facts the Connect a Device panel shows (spec.connection-
/// setup.md D2). Nothing here changes Remote Login, the firewall,
/// `authorized_keys`, the agent or the roaming configuration.
enum LocalConnectionInfo {
  /// `<LocalHostName>.local`, the Bonjour host name; `nil` when unset.
  /// Not the Mac's display name, which may not resolve.
  static func localHostName() -> String? {
    guard let name = SCDynamicStoreCopyLocalHostName(nil) as String?,
      !name.isEmpty
    else { return nil }
    let host = name + ".local"
    return HostConnectionDescriptor.isValidHost(host) ? host : nil
  }

  /// The Mac's display name, sanitized; display only.
  static func computerName() -> String {
    let name = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? ""
    let sanitized = HostDiscovery.sanitizedName(name)
    return sanitized.isEmpty ? "Mac" : sanitized
  }

  static func accountName() -> String { NSUserName() }

  // MARK: SSH host public keys

  static let hostKeyDirectory = URL(fileURLWithPath: "/etc/ssh")

  /// Fingerprints of the SSH server's configured host *public* keys, in
  /// the clients' canonical `SHA256:` format. Only `ssh_host_*_key.pub`
  /// files are opened; private keys are never requested.
  static func hostKeys(
    in directory: URL = hostKeyDirectory
  ) -> [HostConnectionDescriptor.HostKey] {
    guard
      let names = try? FileManager.default.contentsOfDirectory(
        atPath: directory.path
      )
    else { return [] }
    var keys: [HostConnectionDescriptor.HostKey] = []
    for name in names.sorted()
    where name.hasPrefix("ssh_host_") && name.hasSuffix("_key.pub") {
      let url = directory.appendingPathComponent(name)
      guard let line = readSmallFile(url),
        let key = hostKey(publicKeyLine: line), !keys.contains(key)
      else { continue }
      keys.append(key)
      if keys.count == HostConnectionDescriptor.maxHostKeys { break }
    }
    return keys
  }

  /// The algorithm and fingerprint of an OpenSSH public-key line, when
  /// the direct clients can verify that algorithm.
  static func hostKey(
    publicKeyLine line: String
  ) -> HostConnectionDescriptor.HostKey? {
    let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
    guard parts.count >= 2,
      HostConnectionDescriptor.supportedAlgorithms.contains(String(parts[0])),
      let blob = Data(base64Encoded: String(parts[1])), !blob.isEmpty,
      blobAlgorithm(blob) == String(parts[0])
    else { return nil }
    return HostConnectionDescriptor.HostKey(
      algorithm: String(parts[0]),
      sha256: fingerprint(blob: blob)
    )
  }

  /// `SHA256:` plus the unpadded base64 digest of the key's wire blob,
  /// matching the clients' trust store.
  static func fingerprint(blob: Data) -> String {
    var digest = Data(SHA256.hash(data: blob)).base64EncodedString()
    while digest.last == "=" { digest.removeLast() }
    return "SHA256:" + digest
  }

  /// The algorithm string a wire blob starts with.
  private static func blobAlgorithm(_ blob: Data) -> String? {
    let bytes = [UInt8](blob)
    guard bytes.count >= 4 else { return nil }
    let length =
      Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8
      | Int(bytes[3])
    guard length > 0, length <= 64, bytes.count >= 4 + length else {
      return nil
    }
    return String(bytes: bytes[4 ..< 4 + length], encoding: .ascii)
  }

  /// A regular file of at most 16 KiB, read without following it if it
  /// is a symlink to something else.
  private static func readSmallFile(_ url: URL) -> String? {
    let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_size > 0, info.st_size <= 16 * 1024
    else { return nil }
    var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
    let count = bytes.withUnsafeMutableBytes {
      read(fd, $0.baseAddress, $0.count)
    }
    guard count > 0 else { return nil }
    return String(bytes: bytes.prefix(count), encoding: .utf8)
  }

  // MARK: Roaming configuration (configured, not verified)

  /// The roaming endpoint the SwiftMux service's configuration file
  /// advertises in grants. Present ≠ reachable.
  struct RoamingEndpoint: Hashable, Sendable {
    var advertisedHost: String
    var port: UInt16
  }

  enum RoamingConfiguration: Hashable, Sendable {
    case configured(RoamingEndpoint)
    case absent
    case unreadable
  }

  static var roamingConfigurationURL: URL {
    if let path = ProcessInfo.processInfo.environment[
      "SWIFTMUX_ROAMING_CONFIG"
    ], !path.isEmpty {
      return URL(fileURLWithPath: path)
    }
    return URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent(
        "Library/Application Support/SwiftMux/roaming/config.json"
      )
  }

  static func roamingConfiguration(
    at url: URL = roamingConfigurationURL
  ) -> RoamingConfiguration {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return .absent
    }
    struct File: Decodable {
      var port: UInt16?
      var advertisedHost: String
    }
    guard let text = readConfiguration(url),
      let file = try? JSONDecoder().decode(File.self, from: Data(text.utf8)),
      !file.advertisedHost.isEmpty, file.advertisedHost.utf8.count <= 255,
      file.port != 0
    else { return .unreadable }
    return .configured(
      RoamingEndpoint(
        advertisedHost: file.advertisedHost,
        port: file.port ?? 51222
      )
    )
  }

  private static func readConfiguration(_ url: URL) -> String? {
    guard
      let values = try? url.resourceValues(forKeys: [
        .isRegularFileKey, .fileSizeKey,
      ]), values.isRegularFile == true, (values.fileSize ?? .max) <= 64 * 1024,
      let data = try? Data(contentsOf: url)
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  // MARK: Runtime checks (verified now, locally)

  enum Check: Hashable, Sendable {
    case checking
    case ok(String)
    case unavailable(String)
  }

  /// Whether an SSH server answers on `port` on this Mac: connects to the
  /// loopback address and reads the protocol banner. A local answer does
  /// not prove reachability from another device.
  static func probeSSH(
    port: Int,
    timeout: Duration = .seconds(3)
  ) async -> Check {
    guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)),
      (1 ... 65_535).contains(port)
    else { return .unavailable("Not a valid port.") }
    let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
    let queue = DispatchQueue(label: "dev.swiftty.connect.ssh-probe")
    let banner = await withTaskGroup(of: String?.self) { group in
      group.addTask {
        await withCheckedContinuation { continuation in
          let once = OnceFlag()
          connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
              connection.receive(minimumIncompleteLength: 4, maximumLength: 255)
              { data, _, _, _ in
                if once.claim() {
                  continuation.resume(
                    returning: data.flatMap {
                      String(data: $0, encoding: .utf8)
                    }
                  )
                }
              }
            case .failed, .cancelled, .waiting:
              if once.claim() { continuation.resume(returning: nil) }
            default: break
            }
          }
          connection.start(queue: queue)
        }
      }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      connection.cancel()
      return first
    }
    guard let banner, banner.hasPrefix("SSH-") else {
      return .unavailable("No SSH server answered on port \(port) on this Mac.")
    }
    return .ok("An SSH server answers on port \(port) on this Mac.")
  }

  static let helperPath = "/usr/local/libexec/swifttyd"

  /// `swifttyd status`: asks the service for its workspace list over the
  /// control socket (read-only; mints no grant and creates nothing).
  static func helperStatus(
    path: String = helperPath,
    timeout: Duration = .seconds(5)
  ) async -> Check {
    guard FileManager.default.isExecutableFile(atPath: path) else {
      return .unavailable("The roaming helper is not installed at \(path).")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = ["status"]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let status: Int32? = await withCheckedContinuation { continuation in
      let once = OnceFlag()
      process.terminationHandler = { process in
        if once.claim() {
          continuation.resume(returning: process.terminationStatus)
        }
      }
      do { try process.run() } catch {
        if once.claim() { continuation.resume(returning: nil) }
        return
      }
      Task {
        try? await Task.sleep(for: timeout)
        if once.claim() {
          process.terminate()
          continuation.resume(returning: nil)
        }
      }
    }
    switch status {
    case 0?: return .ok("SwiftMux is serving roaming clients.")
    case nil: return .unavailable("The roaming helper did not answer.")
    default:
      return .unavailable(
        "SwiftMux is not serving roaming clients on this Mac."
      )
    }
  }
}

/// Resumes a continuation once across racing callbacks.
final class OnceFlag: Sendable {
  private let claimed = Atomic<Bool>(false)
  func claim() -> Bool {
    !claimed.exchange(true, ordering: .acquiringAndReleasing)
  }
}
