import Foundation

public enum ConfigDiscovery {
  public static func defaultURL(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  ) -> URL {
    let root =
      environment["XDG_CONFIG_HOME"]
      .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
      ?? home.appendingPathComponent(".config")
    return root.appendingPathComponent("swiftty/config.jsonc")
  }

  /// An explicit path wins even when missing: the loader must report that error.
  public static func resolve(
    arguments: [String] = CommandLine.arguments,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  ) throws -> URL? {
    if let index = arguments.firstIndex(of: "--config") {
      guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--"),
        !arguments[index + 1].isEmpty
      else {
        throw ConfigError(
          url: defaultURL(environment: environment, home: home),
          source: "",
          offset: 0,
          detail: "--config requires a path"
        )
      }
      return URL(
        fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath
      )
    }
    let candidates = [
      defaultURL(environment: environment, home: home),
      home.appendingPathComponent(".swiftty.jsonc"),
      home.appendingPathComponent(".config/swiftty/config.json"),
    ]
    return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
  }

  public static func load(
    arguments: [String] = CommandLine.arguments,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  ) throws -> SwifttyConfig {
    guard
      let url = try resolve(
        arguments: arguments,
        environment: environment,
        home: home
      )
    else { return .default }
    return try ConfigLoader.load(from: url)
  }
}
