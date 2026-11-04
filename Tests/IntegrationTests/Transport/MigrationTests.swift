#if os(macOS)
@testable import AppleTransport
import Darwin
import Foundation
import ScreenProtocol
import SessionCore
import Synchronization
import Testing

/// A loopback UDP relay between one QUIC client and the server. `rebind()`
/// moves the server-facing side to a new local port, so the server sees
/// the client's address change mid-connection, as when a phone moves
/// from Wi-Fi to cellular behind NAT (RFC 9000 §9).
///
/// Old server-facing sockets stay open and silently discard traffic, as
/// a NAT drops packets for an abandoned mapping. (Closing them makes the
/// loopback stack answer with ICMP port-unreachable, which a real path
/// change seldom produces.)
final class RebindingUDPRelay: @unchecked Sendable {
  let port: UInt16
  private let listenFD: Int32
  private let server: sockaddr_in
  private final class WorkerState: Sendable {
    let value = Mutex<
      (upstream: Int32, client: sockaddr_in?, rebinds: Int, retired: [Int32])
    >((-1, nil, 0, []))
    let running = Atomic<Bool>(true)
  }

  private let state = WorkerState()
  private let thread: Thread
  private let workerFinished = DispatchSemaphore(value: 0)
  private let stopLock = NSLock()

  init(serverPort: UInt16) throws {
    func loopback(_ port: UInt16) -> sockaddr_in {
      var a = sockaddr_in()
      a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      a.sin_family = sa_family_t(AF_INET)
      a.sin_port = port.bigEndian
      a.sin_addr.s_addr = inet_addr("127.0.0.1")
      return a
    }
    let fd = try Self.newUpstream()
    var bound = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &bound) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(fd, $0, &length)
      }
    }
    guard named == 0 else {
      let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      close(fd)
      throw error
    }
    listenFD = fd
    port = UInt16(bigEndian: bound.sin_port)
    server = loopback(serverPort)
    let upstream: Int32
    do { upstream = try Self.newUpstream() } catch {
      close(fd)
      throw error
    }
    state.value.withLock { $0.upstream = upstream }
    let state = state
    let finished = workerFinished
    let destination = server
    thread = Thread {
      defer { finished.signal() }
      Self.pump(listenFD: fd, server: destination, state: state)
    }
    thread.start()
  }

  deinit { stop() }

  private static func newUpstream() throws -> Int32 {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var any = sockaddr_in()
    any.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    any.sin_family = sa_family_t(AF_INET)
    any.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &any) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0 else {
      let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      close(fd)
      throw error
    }
    return fd
  }

  /// The server now sees packets from a different address (new port).
  func rebind() throws {
    let fresh = try Self.newUpstream()
    state.value.withLock { s in
      guard state.running.load(ordering: .relaxed) else {
        close(fresh)
        return
      }
      s.retired.append(s.upstream)
      s.upstream = fresh
      s.rebinds += 1
    }
  }

  func stop() {
    stopLock.lock()
    defer { stopLock.unlock() }
    guard state.running.load(ordering: .relaxed) else { return }
    state.running.store(false, ordering: .relaxed)
    // The poll timeout wakes the worker without closing descriptors it
    // may still be using. Only release them once its last I/O finishes.
    workerFinished.wait()
    close(listenFD)
    state.value.withLock { s in
      close(s.upstream)
      for fd in s.retired { close(fd) }
    }
  }

  private static func pump(
    listenFD: Int32,
    server: sockaddr_in,
    state: WorkerState
  ) {
    var buffer = [UInt8](repeating: 0, count: 65536)
    var server = server
    while state.running.load(ordering: .relaxed) {
      let upstream = state.value.withLock { $0.upstream }
      var fds = [
        pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0),
        pollfd(fd: upstream, events: Int16(POLLIN), revents: 0),
      ]
      guard poll(&fds, 2, 50) > 0 else { continue }
      if fds[0].revents & Int16(POLLIN) != 0 {
        var from = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &from) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            recvfrom(listenFD, &buffer, buffer.count, 0, $0, &length)
          }
        }
        if n > 0 {
          state.value.withLock { $0.client = from }
          _ = withUnsafePointer(to: &server) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
              sendto(
                upstream,
                buffer,
                n,
                0,
                $0,
                socklen_t(MemoryLayout<sockaddr_in>.size)
              )
            }
          }
        }
      }
      if fds[1].revents & Int16(POLLIN) != 0 {
        let n = recv(upstream, &buffer, buffer.count, 0)
        if n > 0, var client = state.value.withLock({ $0.client }) {
          _ = withUnsafePointer(to: &client) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
              sendto(
                listenFD,
                buffer,
                n,
                0,
                $0,
                socklen_t(MemoryLayout<sockaddr_in>.size)
              )
            }
          }
        }
      }
    }
  }
}

/// Network framework's QUIC listener (OS 27 SDK) accepts packets from a
/// client's new address on the same connection, but keeps sending to the
/// old address: server-to-client traffic does not follow the migration.
/// The roaming client therefore relies on reattachment after a path
/// change (spec §7.1, §9), covered end to end by `RoamingEndToEndTests`.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct MigrationTests {
  @Test
  func `dropping a relay stops its worker`() throws {
    weak var reference: RebindingUDPRelay?
    do {
      let relay = try RebindingUDPRelay(serverPort: 1)
      reference = relay
    }
    #expect(reference == nil)
  }

  @Test
  func `stopping the relay twice preserves newly opened descriptors`() throws {
    let relay = try RebindingUDPRelay(serverPort: 1)
    relay.stop()
    var descriptors: [Int32] = [-1, -1]
    try #require(pipe(&descriptors) == 0)
    defer { for fd in descriptors { close(fd) } }
    relay.stop()
    for fd in descriptors { #expect(fcntl(fd, F_GETFD) >= 0) }
  }

  /// macOS 27.0.1 (the GitHub xcode-27 runner) drops the client's traffic
  /// from its new address entirely; 27.2 delivers it. This asserts the OS
  /// listener's behavior, so it only runs where that behavior exists.
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(
          majorVersion: 27,
          minorVersion: 2,
          patchVersion: 0
        )
      ),
      "Network framework before macOS 27.2 does not deliver migrated traffic"
    )
  )
  func `client traffic reaches the same connection after its address changes`()
    async throws
  {
    let (listener, accepted) = try await startListener()
    defer { listener.stop() }
    let relay = try RebindingUDPRelay(serverPort: listener.port)
    defer { relay.stop() }

    let client = try await connector()
      .connectQUIC(
        host: "127.0.0.1",
        port: relay.port,
        pin: loopbackIdentity.pin
      )
    defer { client.close() }
    let clientInbox = Inbox()
    client.start(clientInbox.handler)

    try await client.sendControl(
      ControlRecord.encode(.ping(epoch: 1, nonce: 1))
    )
    try await transportEventually { accepted.count == 1 }
    let (_, serverInbox) = try #require(accepted.all.first)
    try await transportEventually { serverInbox.messages.count == 1 }

    // After the move the server still receives on the same connection.
    // (With no acknowledgements reaching the client's new address, its
    // sending soon stalls; that is the reattachment case.)
    try relay.rebind()
    try await client.sendControl(
      ControlRecord.encode(.ping(epoch: 1, nonce: 2))
    )
    try await transportEventually { serverInbox.messages.count == 2 }
    #expect(accepted.count == 1)
    #expect(!serverInbox.closed)
    #expect(
      serverInbox.messages == [
        .ping(epoch: 1, nonce: 1), .ping(epoch: 1, nonce: 2),
      ]
    )
  }
}
#endif
