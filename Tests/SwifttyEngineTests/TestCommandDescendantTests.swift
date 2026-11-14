#if os(macOS)
import Darwin
import Foundation
import Testing
import TestSupport

struct TestCommandDescendantTests {
  @Test
  func normalLeaderExitKillsItsLiveDescendantAndPreservesStatus() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "command-descendant-" + UUID().uuidString
    )
    defer { try? FileManager.default.removeItem(at: url) }
    let program = #"""
      import os,subprocess,sys
      child=subprocess.Popen(['/bin/sleep','30'])
      with open(sys.argv[1],'w') as f:
          f.write(str(os.getpid())+' '+str(child.pid))
      os._exit(7)
      """#
    let start = ContinuousClock.now
    let status = try TestCommand.run(
      "/usr/bin/python3",
      arguments: ["-c", program, url.path],
      timeout: .seconds(5),
    )
    #expect(status == 7)
    #expect(ContinuousClock.now - start < .seconds(3))
    let pids = try String(contentsOf: url, encoding: .utf8)
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
}
#endif
