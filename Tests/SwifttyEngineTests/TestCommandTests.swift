#if os(macOS)
import Darwin
import Foundation
import Testing
import TestSupport

@Suite(.serialized)
struct TestCommandTests {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "test-command-" + UUID().uuidString
    )
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true,
    )
    return url
  }

  @Test
  func exitStatusAndCapturedOutputArePreserved() throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("output")
    try Data().write(to: url)
    let output = try FileHandle(forWritingTo: url)
    defer { try? output.close() }
    let status = try TestCommand.run(
      "/bin/sh",
      arguments: ["-c", "printf 'stdout'; printf 'stderr' >&2; exit 7"],
      stdout: output.fileDescriptor,
      stderr: output.fileDescriptor
    )
    #expect(status == 7)
    #expect(try String(contentsOf: url, encoding: .utf8) == "stdoutstderr")
    do {
      _ = try TestCommand.run("/missing/test-command", arguments: [])
      Issue.record("Missing executable was spawned")
    } catch let error as TestCommand.Failure {
      #expect(error == .systemCall(ENOENT))
    }
  }

  @Test
  func timeoutKillsTheOwnedGroupAndCollectsItsLeader() throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appendingPathComponent("pids")
    let program = #"""
      import os,sys,subprocess,time
      child=subprocess.Popen(['/bin/sleep','5'])
      with open(sys.argv[1],'w') as f: f.write(str(os.getpid())+' '+str(child.pid))
      time.sleep(5)
      """#
    let start = ContinuousClock.now
    do {
      _ = try TestCommand.run(
        "/usr/bin/python3",
        arguments: ["-c", program, pidFile.path],
        timeout: .seconds(1),
      )
      Issue.record("Stalled command completed")
    } catch let error as TestCommand.Failure { #expect(error == .timedOut) }
    #expect(ContinuousClock.now - start < .seconds(4))
    let pids = try String(contentsOf: pidFile, encoding: .utf8)
      .split(separator: " ").compactMap { pid_t($0) }
    try #require(pids.count == 2)
    var info = siginfo_t()
    #expect(
      waitid(P_PID, id_t(pids[0]), &info, WEXITED | WNOHANG | WNOWAIT) == -1
    )
    #expect(errno == ECHILD)
    let deadline = ContinuousClock.now + .seconds(3)
    while kill(pids[1], 0) == 0, ContinuousClock.now < deadline { usleep(1000) }
    #expect(kill(pids[1], 0) == -1)
    #expect(errno == ESRCH)
  }

  @Test
  func oversizedOutputAndEarlyDiagnosticStopAreFinite() throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("output")
    try Data().write(to: url)
    let output = try FileHandle(forWritingTo: url)
    defer { try? output.close() }
    do {
      _ = try TestCommand.run(
        "/usr/bin/python3",
        arguments: ["-c", "print('x'*65536)"],
        stdout: output.fileDescriptor,
        maxOutputBytes: 1024,
      )
      Issue.record("Oversized output was accepted")
    } catch let error as TestCommand.Failure { #expect(error == .outputLimit) }
    try output.truncate(atOffset: 0)
    try output.seek(toOffset: 0)
    let start = ContinuousClock.now
    let status = try TestCommand.run(
      "/usr/bin/python3",
      arguments: [
        "-c", "import os,time;os.write(1,b'diagnostic\\n');time.sleep(5)",
      ],
      stdout: output.fileDescriptor,
      until: { try Data(contentsOf: url).contains(0x0A) }
    )
    #expect(status == 128 + SIGKILL)
    #expect(ContinuousClock.now - start < .seconds(2))
  }
}
#endif
