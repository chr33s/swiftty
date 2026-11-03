import Darwin
import Foundation
import SwiftMuxGuardian
import SwiftMuxProtocol
import Testing

@Suite(.serialized)
struct GuardianDaemonConfigurationTests {
  @Test
  func privateConfigurationNamesSeparateRolesAndCanonicalResources() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let value = try GuardianDaemonConfiguration.load(path: fixture.file.path)
    #expect(value.workerMachService == "test.guardian.worker")
    #expect(value.gatewayMachService == "test.guardian.gateway")
    var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
    #expect(realpath(fixture.file.path, &resolved) != nil)
    let physical = String(
      decoding: resolved.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
      as: UTF8.self
    )
    #expect(
      try GuardianDaemonConfiguration.load(path: physical).buildRoot
        == value.buildRoot
    )
    #expect(
      value.gatewayRequirement(teamRequirement: "anchor apple generic")
        == "(anchor apple generic) and identifier \"test.gateway.app\""
    )
    #expect(throws: MuxError.self) {
      try GuardianHost(configuration: value, signingRequirement: "anchor apple")
    }
  }

  @Test(arguments: [
    "schema", "sameService", "identifier", "relative", "noncanonical", "nul",
  ])
  func invalidInstallationValuesAreRejected(kind: String) throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    var object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: fixture.file))
        as? [String: Any]
    )
    switch kind {
    case "schema": object["schema"] = 2
    case "sameService":
      object["gatewayMachService"] = object["workerMachService"]
    case "identifier":
      object["gatewayIdentifier"] = "test\" or true or \"gateway"
    case "relative": object["launcherPath"] = "launcher"
    case "noncanonical":
      object["buildRoot"] = fixture.root.path + "/../elsewhere"
    default: object["workerMachService"] = "test\u{0}service"
    }
    try JSONSerialization.data(withJSONObject: object).write(to: fixture.file)
    #expect(throws: MuxError.self) {
      try GuardianDaemonConfiguration.load(path: fixture.file.path)
    }
  }

  @Test(arguments: [
    "symlink", "parentSymlink", "hardlink", "permissions", "directory",
    "oversized", "truncated",
  ])
  func unsafeConfigurationFilesAreRejected(kind: String) throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    var path = fixture.file.path
    switch kind {
    case "symlink":
      let alias = fixture.root.appendingPathComponent("alias")
      try FileManager.default.createSymbolicLink(
        at: alias,
        withDestinationURL: fixture.file
      )
      path = alias.path
    case "parentSymlink":
      let alias = fixture.root.appendingPathComponent("parent-alias")
      try FileManager.default.createSymbolicLink(
        at: alias,
        withDestinationURL: fixture.root
      )
      path = alias.appendingPathComponent("guardian.json").path
    case "hardlink":
      #expect(
        link(
          fixture.file.path,
          fixture.root.appendingPathComponent("alias").path
        ) == 0
      )
    case "permissions": #expect(chmod(fixture.file.path, 0o644) == 0)
    case "directory": path = fixture.root.path
    case "oversized":
      try Data(repeating: 32, count: 16385).write(to: fixture.file)
    default: try Data("{".utf8).write(to: fixture.file)
    }
    #expect(throws: (any Error).self) {
      try GuardianDaemonConfiguration.load(path: path)
    }
  }

  private struct Fixture {
    let root: URL
    let file: URL
    init() throws {
      root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("guardian-configuration-" + UUID().uuidString)
      try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      file = root.appendingPathComponent("guardian.json")
      let launcher = root.appendingPathComponent("swmux-launcher")
      try Data("not signed code".utf8).write(to: launcher)
      let value = GuardianDaemonConfiguration(
        workerMachService: "test.guardian.worker",
        gatewayMachService: "test.guardian.gateway",
        gatewayIdentifier: "test.gateway.app",
        buildRoot: root.path,
        launcherPath: launcher.path
      )
      try JSONEncoder().encode(value).write(to: file)
      #expect(chmod(file.path, 0o600) == 0)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
  }
}
