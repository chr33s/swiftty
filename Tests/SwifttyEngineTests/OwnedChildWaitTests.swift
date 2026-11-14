#if os(macOS)
import Darwin
@testable import SwifttyEngine
import Testing
import TestSupport

struct OwnedChildWaitTests {
  @Test(arguments: [0, 7])
  func collectionPreservesStatusAndCleanupIsIdempotent(code: Int32) throws {
    let child = try PTYProcess.spawn(
      SessionConfiguration(command: ["/bin/sh", "-c", "exit \(code)"]),
      columns: 10,
      rows: 2,
    )
    let owned = OwnedChildWait(child.pid)
    defer { #expect(owned.terminate()) }
    let status = try #require(owned.collect())
    #expect(status == code << 8)
    #expect(owned.terminate())
    var info = siginfo_t()
    #expect(
      waitid(P_PID, id_t(child.pid), &info, WEXITED | WNOHANG | WNOWAIT) == -1,
    )
    #expect(errno == ECHILD)
  }

  @Test
  func timedWaitLeavesALiveChildForFiniteCleanup() throws {
    let child = try PTYProcess.spawn(
      SessionConfiguration(command: ["/bin/sleep", "30"]),
      columns: 10,
      rows: 2,
    )
    let owned = OwnedChildWait(child.pid)
    defer { #expect(owned.terminate()) }
    let started = ContinuousClock.now
    #expect(owned.collect(timeout: .milliseconds(50)) == nil)
    #expect(ContinuousClock.now - started < .seconds(1))
    #expect(kill(child.pid, 0) == 0)
    #expect(owned.terminate())
    var info = siginfo_t()
    #expect(
      waitid(P_PID, id_t(child.pid), &info, WEXITED | WNOHANG | WNOWAIT) == -1,
    )
    #expect(errno == ECHILD)
  }
}
#endif
