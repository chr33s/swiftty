#if os(macOS)
import Darwin
import Foundation
import ScreenProtocol
import Testing

@testable import TerminalHost

@Suite(.timeLimit(.minutes(1)))
struct ControlSocketNameTests {
  @Test(arguments: [
    "", ".", "..", "../outside.sock", "/absolute.sock", "nested/socket",
    "control.sock/", "prefix\0suffix",
  ])
  func invalidNamesCannotCreateASocketOrOwnershipLock(_ name: String) throws {
    let base = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let directory = base.appendingPathComponent("owned")
    try ControlDirectory.prepare(directory)
    #expect(throws: ControlSocketError.invalidName) {
      try ControlSocketServer(directory: directory, name: name) { _ in [] }
    }
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: directory.path)
        .isEmpty
    )
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: base.path) == [
        "owned"
      ]
    )
    #expect(throws: ControlSocketError.invalidName) {
      try ControlSocketServer(
        directory: base.appendingPathComponent("absent"),
        name: name
      ) { _ in [] }
    }
  }

  @Test(arguments: [
    "alternate.sock", ".hidden.sock", "with space", "子.sock", "literal%2F.sock",
  ])
  func validSingleComponentNamesRemainUsable(_ name: String) async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let reply = try BootstrapEnvelope.encode(BootstrapResponse.sessions([]))
    let server = try ControlSocketServer(directory: directory, name: name) {
      _ in reply
    }
    try server.start()
    defer { server.stop() }
    #expect(server.path == directory.appendingPathComponent(name).path)
    let request = try BootstrapEnvelope.encode(
      BootstrapRequest(operation: .list)
    )
    let received = BootstrapService.forward(
      envelope: request,
      socketPath: server.path
    )
    #expect(
      try BootstrapEnvelope.decode(BootstrapResponse.self, from: received)
        == .sessions([])
    )
  }

  @Test(arguments: ["", "prefix\0suffix"])
  func invalidClientPathsAreRejectedBeforeConnect(_ path: String) throws {
    #expect(throws: ControlSocketError.invalidPath) {
      try ControlSocketServer.address(path)
    }
    #expect(throws: ControlSocketError.invalidPath) {
      try ControlSocketClient.exchange(path: path, envelope: [])
    }
  }

  @Test
  func unixPathCapacityIncludesItsTerminatingNul() throws {
    let capacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    let exact = String(repeating: "a", count: capacity - 3) + "子"
    #expect(exact.utf8.count == capacity)
    #expect(throws: ControlSocketError.pathTooLong) {
      try ControlSocketServer.address(exact)
    }
    #expect(throws: ControlSocketError.pathTooLong) {
      try ControlSocketClient.exchange(path: exact, envelope: [])
    }
    let accepted = String(exact.dropFirst())
    let address = try ControlSocketServer.address(accepted)
    #expect(address.sun_family == sa_family_t(AF_UNIX))
    #expect(accepted.utf8.count == capacity - 1)
  }
}
#endif
