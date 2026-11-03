import SwiftMuxGuardian
import Darwin
import Foundation
import SwiftMuxProtocol
@testable import SwiftMuxService
import TestSupport
import Testing

// These cases spawn real PTYs. Keep the path matrix from consuming the
// failure fixture's one-second handshake deadline with 32 sibling launches.
@Suite(.serialized)
struct PaneLauncherTests {
  @Test(
    arguments: [
      "bin", ".", "", ":/missing", "/missing:", "/missing::/missing",
      "absolute", "direct",
    ],
    0 ..< 4
  )
  func pathLookupUsesThePaneDirectory(path: String, directoryMode: Int) throws {
    let useHome = directoryMode & 1 != 0
    let relativeDirectory = directoryMode & 2 != 0
    let relativePath = ".build/pane-launch-" + UUID().uuidString
    let directory =
      relativeDirectory
      ? URL(fileURLWithPath: relativePath, isDirectory: true)
      : FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString
      )
    let searchDirectory = directory.appendingPathComponent(
      path == "bin" || path == "absolute" ? "bin" : "."
    )
    try FileManager.default.createDirectory(
      at: searchDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let name = "pane-command-" + UUID().uuidString
    let executable = searchDirectory.appendingPathComponent(name)
    try "#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$1\" > \"$2\"\n"
      .write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: executable.path
    )
    let output = directory.appendingPathComponent("output")
    let argument = "one argument with spaces and '$'"
    let workingDirectory = relativeDirectory ? relativePath : directory.path
    let spec = LaunchSpec(
      command: [path == "direct" ? "./" + name : name, argument, output.path],
      workingDirectory: useHome ? nil : workingDirectory,
      environment: [
        "PATH": path == "absolute" ? searchDirectory.path : path,
        "HOME": workingDirectory,
      ]
    )
    let launcher = PaneLauncher(
      launcherPath: try launcherPath(),
      innerTerm: "xterm-256color"
    )
    let child = try launcher.launch(
      spec,
      pane: PaneID(),
      workspace: WorkspaceID(),
      columns: 80,
      rows: 24
    )
    let owned = OwnedChildWait(child.pid)
    defer {
      close(child.master)
      close(child.slave)
      #expect(owned.terminate())
    }
    let status = try #require(owned.collect(), "pane command did not exit")
    #expect(status == 0)
    let actual = try String(contentsOf: output, encoding: .utf8)
    let canonical = try #require(realpath(directory.path, nil))
    defer { free(canonical) }
    let expected = "\(String(cString: canonical))\n\(argument)\n"
    #expect(actual == expected)
  }

  @Test(arguments: [false, true])
  func aFailedHandshakeIsBoundedAndReapsTheLauncher(oversized: Bool) throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appendingPathComponent("pid")
    let executable = directory.appendingPathComponent("launcher")
    // Arguments are fixed except this UUID path; no shell input comes
    // from a caller. Sleep is finite so the pre-fix regression cannot hang.
    let body =
      "#!/bin/sh\nprintf '%s' $$ > '\(pidFile.path)'\n"
      + (oversized
        ? "{ printf 'S exec 0\\n'; /bin/dd if=/dev/zero bs=8192 count=1 2>/dev/null; } >&4\n"
        : "") + "exec /bin/sleep 3\n"
    try body.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: executable.path
    )
    var launcher = PaneLauncher(
      // Start the signed interpreter directly so cold script launch checks
      // do not consume the deadline this fixture is testing.
      launcherPath: "/bin/sh",
      innerTerm: "xterm-256color",
      terminfoDirectory: nil
    )
    launcher.launchTimeout = .seconds(1)
    var spec = shellLaunch()
    // /bin/sh receives the fixture script in the launcher's directory slot.
    spec.workingDirectory = executable.path
    let start = ContinuousClock.now
    do {
      let child = try launcher.launch(
        spec,
        pane: PaneID(),
        workspace: WorkspaceID(),
        columns: 80,
        rows: 24
      )
      let owned = OwnedChildWait(child.pid)
      close(child.master)
      close(child.slave)
      #expect(owned.terminate())
      Issue.record("Invalid launcher report was accepted")
    } catch let error {
      #expect(error.code == .launchFailed)
      #expect(error.message.contains(oversized ? "report limit" : "timed out"))
    }
    #expect(ContinuousClock.now - start < .seconds(2))
    let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
    #expect(kill(pid, 0) == -1)
    #expect(errno == ESRCH)
    var status: Int32 = 0
    #expect(waitpid(pid, &status, WNOHANG) == -1)
    #expect(errno == ECHILD)
  }
}
