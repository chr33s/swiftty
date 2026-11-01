import Foundation

/// Editor support is bundled with the application; no package manager is needed.
public enum JavaScriptConfiguration {
  public static var defaultDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      ".config/swiftty",
      isDirectory: true
    )
  }

  /// Refresh host-owned declarations, preserving both user-editable files.
  public static func provision(
    at directory: URL = defaultDirectory
  ) throws -> URL {
    let files = FileManager.default
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    for name in ["swiftty.d.ts", "jsconfig.json", "config.js"] {
      let destination = directory.appendingPathComponent(name)
      if name != "swiftty.d.ts", files.fileExists(atPath: destination.path) {
        continue
      }
      let source = Bundle.module.resourceURL!
        .appendingPathComponent("Resources/\(name)")
      let data = try Data(contentsOf: source)
      try data.write(to: destination, options: .atomic)
    }
    return directory.appendingPathComponent("config.js")
  }
}
