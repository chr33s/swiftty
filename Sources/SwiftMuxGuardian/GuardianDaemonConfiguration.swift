import Darwin
import Foundation
import SwiftMuxProtocol

/// Private local installation configuration. Neither gateway clients nor worker
/// bootstrap records may replace these paths or choose their signing policy.
package struct GuardianDaemonConfiguration: Codable, Sendable {
  package var schema = 1
  package let workerMachService: String
  package let gatewayMachService: String
  package let gatewayIdentifier: String
  package let buildRoot: String
  package let launcherPath: String

  package init(
    workerMachService: String,
    gatewayMachService: String,
    gatewayIdentifier: String,
    buildRoot: String,
    launcherPath: String
  ) {
    self.workerMachService = workerMachService
    self.gatewayMachService = gatewayMachService
    self.gatewayIdentifier = gatewayIdentifier
    self.buildRoot = buildRoot
    self.launcherPath = launcherPath
  }

  package static func load(path: String) throws -> Self {
    guard canonicalPath(path) else {
      throw MuxError(.unauthorized, "unsafe guardian configuration path")
    }
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else {
      throw MuxError(.unauthorized, "cannot open guardian configuration")
    }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? file.close() }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == geteuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1,
      info.st_size > 0, info.st_size <= 16384
    else { throw MuxError(.unauthorized, "unsafe guardian configuration file") }
    let data = try file.read(upToCount: 16385) ?? Data()
    guard data.count <= 16384 else {
      throw MuxError(.resourceLimit, "guardian configuration too large")
    }
    let value = try JSONDecoder().decode(Self.self, from: data)
    try value.validate()
    return value
  }

  package func validate() throws {
    guard schema == 1, Self.identifier(workerMachService),
      Self.identifier(gatewayMachService), Self.identifier(gatewayIdentifier),
      workerMachService != gatewayMachService, Self.canonicalPath(buildRoot),
      Self.canonicalPath(launcherPath)
    else {
      throw MuxError(
        .invalidRequest,
        "invalid guardian installation configuration"
      )
    }
  }

  package func gatewayRequirement(teamRequirement: String) -> String {
    // validate() restricts the identifier to literal ASCII characters.
    "(\(teamRequirement)) and identifier \"\(gatewayIdentifier)\""
  }

  private static func identifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 255
      && value.utf8.allSatisfy {
        (48 ... 57).contains($0) || (65 ... 90).contains($0)
          || (97 ... 122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
      }
  }

  private static func canonicalPath(_ value: String) -> Bool {
    guard value.hasPrefix("/"), !value.utf8.contains(0),
      !value.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    else { return false }
    let url = URL(fileURLWithPath: value)
    // Foundation canonicalizes macOS's /private/var and /var aliases. Compare
    // its normalized forms, while rejecting lexical traversal above.
    return url.standardizedFileURL.path == url.resolvingSymlinksInPath().path
  }
}
