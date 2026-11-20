#if os(macOS)
import Darwin
import Foundation
import ScreenProtocol

/// Roaming configuration of the SwiftMux service (spec §4). The bind
/// address and advertised endpoint are explicit; nothing changes firewall
/// policy.
public struct HostConfiguration: Sendable, Hashable, Codable {
  /// Project default, not an assigned service port.
  public static let defaultPort: UInt16 = 51222

  /// Local address the QUIC/UDP listener binds (e.g. `0.0.0.0`, a LAN or
  /// VPN address).
  public var bindAddress: String
  public var port: UInt16
  /// Host name or address placed in grants for clients to connect to.
  public var advertisedHost: String
  /// Owner-only state directory holding the control socket. File loading
  /// resolves relative paths against the configuration file's parent.
  /// Directly constructed configurations use the shared roaming directory.
  public var stateDirectory: String?

  public init(
    bindAddress: String,
    port: UInt16 = Self.defaultPort,
    advertisedHost: String,
    stateDirectory: String? = nil
  ) {
    self.bindAddress = bindAddress
    self.port = port
    self.advertisedHost = advertisedHost
    self.stateDirectory = stateDirectory
  }

  enum CodingKeys: String, CodingKey {
    case bindAddress, port, advertisedHost, stateDirectory
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    bindAddress = try c.decode(String.self, forKey: .bindAddress)
    port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? Self.defaultPort
    advertisedHost = try c.decode(String.self, forKey: .advertisedHost)
    stateDirectory = try c.decodeIfPresent(String.self, forKey: .stateDirectory)
    guard !bindAddress.isEmpty, bindAddress.utf8.count <= 255,
      !bindAddress.utf8.contains(0), !advertisedHost.isEmpty,
      advertisedHost.utf8.count <= 255, !advertisedHost.utf8.contains(0),
      port != 0
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .bindAddress,
        in: c,
        debugDescription: "bind address, advertised host and port required"
      )
    }
    if let stateDirectory,
      stateDirectory.isEmpty || stateDirectory.utf8.contains(0)
    {
      throw DecodingError.dataCorruptedError(
        forKey: .stateDirectory,
        in: c,
        debugDescription: "state directory must be a nonempty NUL-free path"
      )
    }
  }

  public var stateDirectoryURL: URL {
    stateDirectory.map {
      Self.directoryURL($0, relativeTo: ControlDirectory.defaultURL)
    } ?? ControlDirectory.defaultURL
  }

  private static func directoryURL(_ path: String, relativeTo base: URL) -> URL
  {
    let directory = URL(fileURLWithPath: base.path, isDirectory: true)
    return URL(fileURLWithPath: path, isDirectory: true, relativeTo: directory)
      .absoluteURL
  }

  public var socketPath: String {
    stateDirectoryURL.appendingPathComponent("control.sock").path
  }

  public static var defaultConfigurationURL: URL {
    ControlDirectory.defaultURL.appendingPathComponent("config.json")
  }

  /// Loads a regular local file of at most 64 KiB, with bounded reads even
  /// if the file grows while being read.
  public static func load(from url: URL) throws -> HostConfiguration {
    guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
    let path = url.path(percentEncoded: false)
    guard !path.utf8.contains(0) else { throw POSIXError(.EINVAL) }
    let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    // Configuration is a regular file, never a blocking pipe or device.
    guard info.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EINVAL) }
    let limit = 64 * 1024
    guard info.st_size <= limit else { throw CocoaError(.fileReadTooLarge) }
    // Read one excess byte to detect growth after fstat without ever reading
    // the whole enlarged file. Short reads and interruptions remain valid.
    var bytes = [UInt8](repeating: 0, count: limit + 1)
    var count = 0
    while count < bytes.count {
      let readCount = bytes.withUnsafeMutableBytes {
        Darwin.read(fd, $0.baseAddress! + count, $0.count - count)
      }
      if readCount > 0 {
        count += readCount
      } else if readCount == 0 {
        break
      } else if errno != EINTR {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    }
    guard count <= limit else { throw CocoaError(.fileReadTooLarge) }
    var configuration = try JSONDecoder()
      .decode(HostConfiguration.self, from: Data(bytes.prefix(count)))
    if let path = configuration.stateDirectory {
      configuration.stateDirectory =
        directoryURL(
          path,
          relativeTo: url.absoluteURL.deletingLastPathComponent()
        )
        .path
    }
    return configuration
  }
}

extension HostConfiguration {
  /// Overrides the configuration location for both the service and the
  /// bootstrap helper (tests, side-by-side development installs).
  public static let environmentKey = "SWIFTMUX_ROAMING_CONFIG"

  /// The configuration both `swiftmux-agent` and `swifttyd bootstrap`
  /// use, so they agree on the control socket.
  public static func resolvedConfigurationURL(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    if let path = environment[environmentKey], !path.isEmpty {
      return URL(fileURLWithPath: path)
    }
    return defaultConfigurationURL
  }

  /// Loads the agent's selected configuration before service startup. Only
  /// an absent optional default disables roaming; explicit selections and
  /// other failures must be reported. A nil URL means roaming was disabled.
  public static func loadForStartup(
    from url: URL?,
    required: Bool
  ) throws -> HostConfiguration? {
    guard let url else { return nil }
    do { return try load(from: url) } catch let error as POSIXError
      where error.code == .ENOENT && !required
    { return nil }
  }

  /// Control socket selected by the bootstrap helper's configuration.
  /// Only an absent default configuration permits the default socket;
  /// explicit paths and other load failures propagate to the caller.
  public static func resolvedSocketPath(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> String {
    do {
      return try load(from: resolvedConfigurationURL(environment: environment))
        .socketPath
    } catch let error as POSIXError
      where error.code == .ENOENT && (environment[environmentKey] ?? "").isEmpty
    {
      // Without a configuration, status may still ask the default service
      // whether roaming is available. Explicit paths must never fall back.
      return ControlDirectory.defaultURL.appendingPathComponent("control.sock")
        .path
    }
  }
}
#endif
