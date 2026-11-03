import Darwin
import Dispatch
import Foundation
import SwiftMuxProtocol

/// Delivered on descriptor 3, never in argv, environment, or a session file.
/// The worker reads it once before starting its workspace/terminal queues.
package struct GuardianWorkerBootstrap: Codable, Sendable {
  package let version: Int
  package let workspace: WorkspaceID
  package let token: UUID
  package let guardianPID: Int32
  package let machService: String
  package let build: String
  package let peerRequirement: String?

  package static func read() throws -> Self {
    let fd: Int32 = 3
    defer { Darwin.close(fd) }
    guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
      throw MuxError(.invalidRequest, "missing worker bootstrap descriptor")
    }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while true {
      let count = Darwin.read(fd, &buffer, buffer.count)
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw MuxError(.connectionLost, "worker bootstrap read failed")
      }
      guard count <= 4096 - data.count else {
        throw MuxError(.resourceLimit, "worker bootstrap exceeds limit")
      }
      data.append(contentsOf: buffer.prefix(count))
    }
    let value = try JSONDecoder().decode(Self.self, from: data)
    guard value.version == GuardianWire.version, value.guardianPID == getppid(),
      value.guardianPID > 1, !value.machService.isEmpty, !value.build.isEmpty
    else { throw MuxError(.unauthorized, "invalid worker bootstrap authority") }
    return value
  }

  package func connect(
    queue: DispatchQueue,
    handlers: GuardianWorkerConnection.Handlers
  ) throws -> GuardianWorkerConnection {
    try GuardianWorkerConnection(
      channel: .connect(machService: machService, queue: queue),
      workspace: workspace,
      token: token,
      peerRequirement: peerRequirement,
      expectedGuardianPID: guardianPID,
      handlers: handlers
    )
  }
}
