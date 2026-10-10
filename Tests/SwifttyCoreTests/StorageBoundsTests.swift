import Darwin
import Foundation
import Testing

// Debug assertions print diagnostics; Release traps may omit them.
#if DEBUG
private final class StorageProbeBundle: NSObject {}

struct StorageBoundsTests {
  @Test(arguments: 0 ..< 12)
  func invalidStorageArgumentsTrap(_ operation: Int) throws {
    var directory = Bundle(for: StorageProbeBundle.self).bundleURL
    var executable: URL?
    for _ in 0 ..< 6 {
      let candidate = directory.appendingPathComponent("StorageBoundsProbe")
      if FileManager.default.isExecutableFile(atPath: candidate.path) {
        executable = candidate
        break
      }
      directory.deleteLastPathComponent()
    }
    let process = Process()
    process.executableURL = try #require(executable)
    process.arguments = [String(operation)]
    process.standardOutput = FileHandle.nullDevice
    let errors = Pipe()
    process.standardError = errors
    try process.run()
    // Debugger hosts may hold a trap instead of letting the child exit.
    var diagnostic = Data()
    while diagnostic.last != 0x0A {
      let chunk = errors.fileHandleForReading.availableData
      if chunk.isEmpty { break }
      diagnostic.append(chunk)
    }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
    #expect(
      String(decoding: diagnostic, as: UTF8.self)
        .contains("Precondition failed")
    )
  }
}

#endif
