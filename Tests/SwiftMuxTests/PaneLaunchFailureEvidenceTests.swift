import SwiftMuxGuardian
import Darwin
import Foundation
import SwiftMuxProtocol
@testable import SwiftMuxService
import TestSupport
import Testing

@Suite(.serialized)
struct PaneLaunchFailureEvidenceTests {
  @Test(
    arguments: [
      "", "S exec 0", "S fixture 0\n", "S exec 1\n", "S \n", "S exec 0\u{0}\n",
      "W chdir 2\n", String(repeating: "x", count: 600), "S exec 0\nE",
      "S exec 0\njunk\n", "S exec 0\nS exec 1\n",
    ]
    .map { TestFixture($0) }
  )
  func incompleteSuccessReportsAreRejectedWithBoundedEvidence(
    _ fixture: TestFixture<String>
  ) throws {
    let report = fixture.value
    try withLauncher(report: report) { launcher, pidFile in
      do {
        let child = try launch(launcher)
        discard(child)
        Issue.record("Incomplete success report was accepted")
      } catch {
        let error = try #require(error as? MuxError)
        #expect(error.code == .launchFailed)
        #expect(error.message.contains("missing complete success report"))
        #expect(error.message.contains("report bytes=\(report.utf8.count)"))
        let hex = report.utf8.prefix(32).map { String(format: "%02x", $0) }
          .joined()
        #expect(error.message.contains("hex=\(hex)"))
        #expect(error.message.contains("pre-cleanup child="))
        #expect(error.message.contains("collected "))
        #expect(error.message.utf8.count < 512)
      }
      try expectReaped(pidFile)
    }
  }

  @Test(arguments: [false, true])
  func absentReportsRetainCleanupEvidenceForLiveAndSignaledChildren(
    _ signaled: Bool
  ) throws {
    let tail = signaled ? "kill -TERM $$\n" : "exec 4>&-\nexec /bin/sleep 3\n"
    try withLauncher(report: "", tail: tail) { launcher, pidFile in
      do {
        let child = try launch(launcher)
        discard(child)
        Issue.record("Unreported launch was accepted")
      } catch {
        let error = try #require(error as? MuxError)
        #expect(error.code == .launchFailed)
        #expect(error.message.contains("report bytes=0 hex="))
        #expect(error.message.contains("pre-cleanup child="))
        #expect(error.message.contains("collected signal="))
        if !signaled {
          #expect(error.message.contains("pre-cleanup child=not-waitable"))
          #expect(error.message.contains("collected signal=9"))
        }
      }
      try expectReaped(pidFile)
    }
  }

  @Test(arguments: ["S exec 0\n", "W chdir 2\nS exec 0\n"])
  func completeSuccessAndWarningsRemainAccepted(_ report: String) throws {
    try withLauncher(report: report) { launcher, pidFile in
      let child = try launch(launcher)
      defer { discard(child) }
      #expect(child.warnings == (report.hasPrefix("W") ? ["W chdir 2"] : []))
      let owned = OwnedChildWait(child.pid)
      #expect(owned.collect() == 23 << 8)
      try expectReaped(pidFile)
    }
  }

  @Test
  func execFailureAfterSuccessTakesPriority() throws {
    try withLauncher(report: "S exec 0\nE exec 13\n") { launcher, pidFile in
      do {
        let child = try launch(launcher)
        discard(child)
        Issue.record("Reported exec failure was accepted")
      } catch {
        let error = try #require(error as? MuxError)
        #expect(error.code == .launchFailed)
        #expect(
          error.message.hasPrefix("exec: \(String(cString: strerror(EACCES)))")
        )
        #expect(error.message.contains("pre-cleanup child="))
        #expect(error.message.contains("collected "))
      }
      try expectReaped(pidFile)
    }
  }

  @Test(arguments: [false, true])
  func cleanupPreservesObservedTerminationAndSkipsCollectedChildren(
    _ signaled: Bool
  ) throws {
    let tail = signaled ? "kill -TERM $$\n" : "exit 23\n"
    try withLauncher(report: "S exec 0\n", tail: tail) { launcher, pidFile in
      let child = try launch(launcher)
      defer { discard(child) }
      let deadline = ContinuousClock.now + .seconds(2)
      var info = siginfo_t()
      repeat {
        let result = waitid(
          P_PID,
          id_t(child.pid),
          &info,
          WEXITED | WNOHANG | WNOWAIT
        )
        #expect(result == 0)
        if result != 0 || info.si_pid == child.pid { break }
        usleep(1000)
      } while ContinuousClock.now < deadline
      #expect(info.si_pid == child.pid)
      let expected = signaled ? "signal=15" : "exit=23"
      let evidence = PaneLauncher.stopFailedLauncher(child.pid)
      #expect(
        evidence == "pre-cleanup child=\(expected); collected \(expected)"
      )
      try expectReaped(pidFile)
      let alreadyCollected = PaneLauncher.stopFailedLauncher(child.pid)
      #expect(
        alreadyCollected
          == "pre-cleanup waitid errno=\(ECHILD); cleanup skipped"
      )
    }
  }

  private func launch(
    _ fixture: PaneLauncher
  ) throws(MuxError) -> LaunchedProcess {
    // Execute the installed interpreter directly. Executing each freshly
    // written script can spend the handshake budget on macOS launch checks.
    // The fake launcher uses the directory argument slot for its script path.
    var launcher = fixture
    launcher.launcherPath = "/bin/sh"
    return try launcher.launch(
      LaunchSpec(
        command: ["/usr/bin/true"],
        workingDirectory: fixture.launcherPath
      ),
      pane: PaneID(),
      workspace: WorkspaceID(),
      columns: 10,
      rows: 2
    )
  }

  private func discard(_ child: LaunchedProcess) {
    close(child.master)
    close(child.slave)
    #expect(OwnedChildWait(child.pid).terminate())
  }

  private func expectReaped(_ pidFile: URL) throws {
    let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
    var status: Int32 = 0
    #expect(waitpid(pid, &status, WNOHANG) == -1)
    #expect(errno == ECHILD)
  }

  private func withLauncher(
    report: String,
    tail: String = "exit 23\n",
    body: (PaneLauncher, URL) throws -> Void
  ) throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pane-report-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appendingPathComponent("pid")
    let executable = directory.appendingPathComponent("launcher")
    // Only fixed fixture bytes and a private UUID path enter this script.
    let escaped = report.utf8.map { String(format: "\\%03o", $0) }.joined()
    let source =
      "#!/bin/sh\nprintf '%s' $$ > '\(pidFile.path)'\n"
      + "printf '\(escaped)' >&4\n" + tail
    try source.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: executable.path
    )
    var launcher = PaneLauncher(
      launcherPath: executable.path,
      innerTerm: "xterm-256color"
    )
    launcher.launchTimeout = .seconds(1)
    try body(launcher, pidFile)
  }
}
