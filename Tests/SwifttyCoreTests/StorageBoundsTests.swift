import Darwin
import Foundation
import Testing
import TestSupport

// Debug assertions print diagnostics; Release traps may omit them.
#if DEBUG
private final class StorageProbeBundle: NSObject {}

struct StorageBoundsTests {
  @Test(arguments: 0 ..< 14)
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
    let command = try #require(executable)
    let errorsURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("storage-probe-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: errorsURL) }
    try Data().write(to: errorsURL)
    let errors = try FileHandle(forWritingTo: errorsURL)
    let reader = try FileHandle(forReadingFrom: errorsURL)
    defer {
      try? errors.close()
      try? reader.close()
    }
    // Debugger hosts may hold a trap instead of letting the child exit.
    // Read finite chunks from a regular file; stop once its diagnostic lands.
    // The deadline only bounds a missing diagnostic; loaded CI runners have
    // taken over five seconds to launch the probe and reach its trap.
    var diagnostic = Data()
    _ = try TestCommand.run(
      command.path,
      arguments: [String(operation)],
      timeout: .seconds(30),
      stderr: errors.fileDescriptor,
      maxOutputBytes: 16 << 10,
      until: {
        let remaining = (16 << 10) - diagnostic.count
        if remaining > 0, let chunk = try reader.read(upToCount: remaining) {
          diagnostic.append(chunk)
        }
        return diagnostic.contains(0x0A)
      }
    )
    if diagnostic.count < 16 << 10,
      let tail = try reader.read(upToCount: (16 << 10) - diagnostic.count)
    {
      diagnostic.append(tail)
    }
    #expect(
      String(decoding: diagnostic, as: UTF8.self)
        .contains("Precondition failed")
    )
  }
}

#endif
