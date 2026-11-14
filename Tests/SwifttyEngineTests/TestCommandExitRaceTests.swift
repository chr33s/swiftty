#if os(macOS)
import Foundation
import Testing
import TestSupport

struct TestCommandExitRaceTests {
  @Test
  func fastExitingOutputLimitFailuresKeepTheirOriginalError() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "command-exit-race-" + UUID().uuidString
    )
    defer { try? FileManager.default.removeItem(at: url) }
    try Data().write(to: url)
    let output = try FileHandle(forWritingTo: url)
    defer { try? output.close() }
    for attempt in 0 ..< 100 {
      try output.truncate(atOffset: 0)
      try output.seek(toOffset: 0)
      do {
        _ = try TestCommand.run(
          "/usr/bin/python3",
          arguments: ["-c", "print('x'*65536)"],
          stdout: output.fileDescriptor,
          maxOutputBytes: 1024,
        )
        Issue.record("Oversized command output was accepted")
      } catch let error as TestCommand.Failure {
        #expect(error == .outputLimit, "exit race attempt \(attempt)")
      }
    }
  }
}
#endif
