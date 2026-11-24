import Foundation
@testable import SwiftMuxService
import Testing

@Suite
struct ForegroundProgramTests {
  @Test
  func versionNumbers() {
    #expect(ForegroundProgram.isVersion("2.1.296"))
    #expect(ForegroundProgram.isVersion("v1.2"))
    #expect(ForegroundProgram.isVersion("3"))
    #expect(!ForegroundProgram.isVersion("claude"))
    #expect(!ForegroundProgram.isVersion("python3.12"))
    #expect(!ForegroundProgram.isVersion("vim"))
    #expect(!ForegroundProgram.isVersion("v"))
    #expect(!ForegroundProgram.isVersion("2to3"))
  }

  @Test
  func versionedExecutableIsNamedByItsInvocation() {
    let executable = "/Users/me/.local/share/claude/versions/2.1.296"
    #expect(
      ForegroundProgram.versionedName(
        arguments: ["claude", "--resume"],
        executable: executable
      ) == "claude"
    )
    #expect(
      ForegroundProgram.versionedName(
        arguments: ["/Users/me/.local/bin/claude"],
        executable: executable
      ) == "claude"
    )
    // Run by its own path: the installation directory names it.
    #expect(
      ForegroundProgram.versionedName(
        arguments: [executable],
        executable: executable
      ) == "claude"
    )
    #expect(
      ForegroundProgram.versionedName(arguments: [], executable: executable)
        == "claude"
    )
    #expect(
      ForegroundProgram.versionedName(
        arguments: ["2.1.296"],
        executable: "/opt/tool/v2/2.1.296"
      ) == "tool"
    )
    #expect(
      ForegroundProgram.versionedName(
        arguments: ["1.0"],
        executable: "/Application Support/1.0"
      ) == nil
    )
    #expect(
      ForegroundProgram.versionedName(arguments: [], executable: nil) == nil
    )
  }

  @Test
  func liveVersionedProcessIsNamedBySymlink() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "foreground-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let versions = root.appendingPathComponent("tool/versions")
    try FileManager.default.createDirectory(
      at: versions,
      withIntermediateDirectories: true
    )
    let binary = versions.appendingPathComponent("1.2.3")
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "/bin/sleep"),
      to: binary
    )
    let link = root.appendingPathComponent("tool-link")
    try FileManager.default.createSymbolicLink(
      at: link,
      withDestinationURL: binary
    )

    let process = Process()
    process.executableURL = link
    process.arguments = ["30"]
    try process.run()
    defer {
      process.terminate();
      process.waitUntilExit()
    }

    let pid = process.processIdentifier
    #expect(ForegroundProgram.processName(pid) == "1.2.3")
    #expect(ForegroundProgram.programName(pid) == "tool-link")
  }
}
