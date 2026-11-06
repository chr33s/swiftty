#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Testing
@testable import Swsh

@Suite
struct LauncherPayloadTests {
  private func payload() -> LauncherPayload {
    LauncherPayload(
      build: "test-build",
      executable: Array("/usr/bin/true".utf8),
      arguments: [
        Array("true".utf8), [UInt8](repeating: 120, count: 256 * 1024),
      ],
      environment: [[65, 61, 255]],
      redirects: [.open(descriptor: 1, path: [255], mode: .write)]
    )
  }

  @Test
  func largePayloadIsUnlinkedPrivateAndRoundTrips() throws {
    let expected = payload()
    let file = try expected.write()
    try file.withDescriptor { fd in
      var info = stat()
      #expect(fstat(fd, &info) == 0)
      #expect(info.st_nlink == 0)
      #expect(info.st_mode & 0o777 == 0o600)
      #expect(info.st_size > 256 * 1024)
      let decoded = try LauncherPayload.read(
        descriptor: fd,
        build: "test-build"
      )
      #expect(decoded == expected)
    }
  }

  @Test
  func truncatedAndWrongBuildRejected() throws {
    let file = try payload().write()
    file.withDescriptor { fd in
      #expect(throws: SystemFailure.self) {
        try LauncherPayload.read(descriptor: fd, build: "other-build")
      }
      #expect(lseek(fd, 0, SEEK_SET) == 0)
      #expect(ftruncate(fd, 20) == 0)
      #expect(throws: SystemFailure.self) {
        try LauncherPayload.read(descriptor: fd, build: "test-build")
      }
    }
  }

  @Test
  func claimedLengthIsValidatedBeforeAllocation() throws {
    let file = try OwnedFD.temporaryPayload()
    try file.withDescriptor { fd in
      try writeBytes(
        LauncherPayload.magic + [UInt8](repeating: 255, count: 8),
        to: fd
      )
      #expect(lseek(fd, 0, SEEK_SET) == 0)
      #expect(throws: SystemFailure.self) {
        try LauncherPayload.read(descriptor: fd, build: "test-build")
      }
    }
  }
}
