import Foundation
import SwifttyConfig
import Testing
@testable import SwifttyCore

struct ShellProfileTests {
  @Test(arguments: [ShellKind.bash, .zsh, .swsh, .custom])
  func preservesLiteralLaunchInputs(_ kind: ShellKind) {
    var config = Configuration()
    config.preferredShell = kind
    config.shellProfiles[kind.rawValue] = ShellLaunchProfile(
      executable: "/tmp/shell with spaces",
      arguments: ["--login", "$literal", ""],
      environment: ["LOCAL": "a b"],
      workingDirectory: "/tmp/a directory"
    )
    let session = config.sessionConfiguration()
    #expect(
      session.command == ["/tmp/shell with spaces", "--login", "$literal", ""]
    )
    #expect(session.environment == ["LOCAL": "a b"])
    #expect(session.workingDirectory == "/tmp/a directory")
  }

  @Test
  func nativePathAndSystemPolicy() {
    var config = Configuration()
    config.preferredShell = .swsh
    #expect(
      config.sessionConfiguration(nativeShellPath: "/bundle/swsh").command == [
        "/bundle/swsh"
      ]
    )
    config.preferredShell = .system
    #expect(config.sessionConfiguration().command == nil)
  }

  @Test
  func switchingPreservesSavedProfiles() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString
    )
    defer { try? FileManager.default.removeItem(at: url) }
    try
      #"{"terminal":{"preferred_shell":"bash","shell_profiles":{"bash":{"arguments":["--login"],"environment":{"KEEP":"yes"}},"custom":{"executable":"/tmp/custom"}}}}"#
      .write(to: url, atomically: true, encoding: .utf8)
    let original = Configuration.load(from: url)
    #expect(original.diagnostics.isEmpty)
    try ConfigurationEditor.apply([("shell-profile", "swsh")], to: url)
    let updated = Configuration.load(from: url)
    #expect(updated.diagnostics.isEmpty)
    #expect(updated.preferredShell == .swsh)
    #expect(updated.shellProfiles == original.shellProfiles)
    try ConfigurationEditor.apply([("shell-profile", "bash")], to: url)
    #expect(
      Configuration.load(from: url).sessionConfiguration().command == [
        "/bin/bash", "--login",
      ]
    )
  }

  @Test(arguments: [
    #"{"preferred_shell":"unknown"}"#, #"{"preferred_shell":"custom"}"#,
    #"{"shell_profiles":{"unknown":{}}}"#,
    #"{"shell_profiles":{"bash":{"argument":[]}}}"#,
    #"{"shell_profiles":{"system":{"arguments":["-i"]}}}"#,
    #"{"shell_profiles":{"custom":{}}}"#,
    #"{"shell_profiles":{"bash":{"environment":{"A=B":"x"}}}}"#,
    #"{"shell_profiles":{"bash":{"arguments":["\u0000"]}}}"#,
  ])
  func rejectsInvalidProfiles(_ terminal: String) {
    #expect(throws: (any Error).self) {
      try ConfigLoader.decode("{\"terminal\":" + terminal + "}")
    }
  }
}
