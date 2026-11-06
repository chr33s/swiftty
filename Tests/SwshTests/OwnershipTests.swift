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
struct OwnershipTests {
  @Test
  func descriptorTransferAndCloseOnExec() throws {
    let owner = try OwnedFD.open(Array("/dev/null".utf8), flags: O_RDWR)
    let raw = owner.withDescriptor { $0 }
    #expect(fcntl(raw, F_GETFD) & FD_CLOEXEC != 0)
    let duplicate = try owner.withDescriptor { try OwnedFD.duplicate($0) }
    let transferred = duplicate.transfer()
    defer { systemClose(transferred) }
    try owner.close()
    #expect(fcntl(transferred, F_GETFD) & FD_CLOEXEC != 0)
  }

  @Test
  func nulPathNeverReachesOpen() {
    #expect(throws: SystemFailure.self) {
      try OwnedFD.open([47, 0, 120], flags: O_RDONLY).close()
    }
  }
}
