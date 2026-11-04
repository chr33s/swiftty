#if os(macOS)
import AppleTransport
import Foundation
import ScreenProtocol
import SessionCore
import Synchronization
@testable import TerminalHost
import TestSupport
import Testing

/// The service never idle-exits while roaming, so the QUIC certificate
/// must be renewed while it runs (spec.inbox.md §1.8).
@Suite(.timeLimit(.minutes(1)))
struct RenewalTests {
  final class RenewalListener: RSTListener {
    let port: UInt16
    let callback = Mutex<(@Sendable (any RSTConnection) -> Void)?>(nil)
    private let fails: Bool
    let started = Mutex(false)
    let stops = Mutex(0)
    private let gate:
      Mutex<(open: Bool, waiter: CheckedContinuation<Void, Never>?)>

    init(port: UInt16, open: Bool, fails: Bool = false) {
      self.port = port
      self.fails = fails
      gate = Mutex((open, nil))
    }

    func start(
      onConnection: @escaping @Sendable (any RSTConnection) -> Void
    ) async throws {
      callback.withLock { $0 = onConnection }
      started.withLock { $0 = true }
      await withCheckedContinuation { continuation in
        let ready = gate.withLock { value in
          if value.open { return true }
          value.waiter = continuation
          return false
        }
        if ready { continuation.resume() }
      }
      if fails { throw RSTTransportError.handshake("injected renewal failure") }
    }

    func release() {
      let waiter = gate.withLock { value in
        value.open = true
        defer { value.waiter = nil }
        return value.waiter
      }
      waiter?.resume()
    }

    func stop() {
      stops.withLock { $0 += 1 }
      release()
    }
  }

  @Test
  func overlappingRenewalsCannotPublishCompetingTransports() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let listeners = [
      RenewalListener(port: 50000, open: true),
      RenewalListener(port: 50001, open: false),
      RenewalListener(port: 50002, open: true),
    ]
    defer { for listener in listeners { listener.stop() } }
    let calls = Mutex(0)
    let certificate = testIdentity().certificate
    let host = try await RoamingHost.start(
      service: makeService(),
      configuration: HostConfiguration(
        bindAddress: "127.0.0.1",
        advertisedHost: "127.0.0.1",
        stateDirectory: directory.path
      ),
      transportFactory: { _, now in
        let index = calls.withLock { value in
          defer { value += 1 };
          return value
        }
        return (
          listeners[min(index, listeners.count - 1)], certificate,
          now.addingTimeInterval(30 * 86400)
        )
      }
    )
    let future = Date().addingTimeInterval(28 * 86400)
    let first = Task { await host.renewIfNeeded(now: future) }
    do {
      try await hostEventually("renewal listener startup") {
        listeners[1].started.withLock { $0 } ? true : nil
      }
      #expect(await host.renewIfNeeded(now: future) == false)
      #expect(calls.withLock { $0 } == 2)
      #expect(listeners[0].stops.withLock { $0 } == 1)
      listeners[1].release()
      #expect(await first.value)
      #expect(host.registry.identity.endpoint.port == 50001)
      #expect(await host.renewIfNeeded(now: future) == false)
      #expect(calls.withLock { $0 } == 2)
    } catch {
      first.cancel()
      listeners[1].release()
      _ = await first.value
      throw error
    }
  }

  @Test(arguments: [false, true])
  func unsuccessfulRenewalReleasesOwnershipForRetry(_ cancel: Bool) async throws
  {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let listeners = [
      RenewalListener(port: 50010, open: true),
      RenewalListener(port: 50011, open: false, fails: !cancel),
      RenewalListener(port: 50012, open: true),
    ]
    defer { for listener in listeners { listener.stop() } }
    let calls = Mutex(0)
    let certificate = testIdentity().certificate
    let host = try await RoamingHost.start(
      service: makeService(),
      configuration: HostConfiguration(
        bindAddress: "127.0.0.1",
        advertisedHost: "127.0.0.1",
        stateDirectory: directory.path
      ),
      transportFactory: { _, now in
        let index = calls.withLock { value in
          defer { value += 1 };
          return value
        }
        return (
          listeners[min(index, listeners.count - 1)], certificate,
          now.addingTimeInterval(30 * 86400)
        )
      }
    )
    let future = Date().addingTimeInterval(28 * 86400)
    let attempt = Task { await host.renewIfNeeded(now: future) }
    do {
      try await hostEventually("failed renewal startup") {
        listeners[1].started.withLock { $0 } ? true : nil
      }
      if cancel { attempt.cancel() }
      listeners[1].release()
      #expect(await attempt.value == false)
      #expect(host.registry.identity.endpoint.port == 50010)
      #expect(listeners[1].stops.withLock { $0 } == 1)
      #expect(await host.renewIfNeeded(now: future))
      #expect(host.registry.identity.endpoint.port == 50012)
      #expect(calls.withLock { $0 } == 3)
    } catch {
      attempt.cancel()
      listeners[1].release()
      _ = await attempt.value
      throw error
    }
  }

  final class AdmissionConnection: RSTConnection {
    var isClosed: Bool { closed.withLock { $0 } }
    let starts = Mutex(0)
    let closed = Mutex(false)

    func start(_ handler: RSTConnectionHandler) { starts.withLock { $0 += 1 } }
    func sendControl(_ record: [UInt8]) async throws {}
    func sendSnapshot(_ payload: [UInt8], stream id: UInt64) async throws {}
    func cancelSnapshot(stream id: UInt64) {}
    func close() { closed.withLock { $0 = true } }
  }

  @Test(arguments: [false, true])
  func releasedHostRejectsRetainedListenerCallbacks(_ renew: Bool) async throws
  {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let listener = RenewalListener(port: 50020, open: true)
    defer { listener.stop() }
    let certificate = testIdentity().certificate
    var host: RoamingHost? = try await RoamingHost.start(
      service: makeService(),
      configuration: HostConfiguration(
        bindAddress: "127.0.0.1",
        advertisedHost: "127.0.0.1",
        stateDirectory: directory.path
      ),
      transportFactory: { _, now in
        (listener, certificate, now.addingTimeInterval(30 * 86400))
      }
    )
    let initial = try #require(listener.callback.withLock { $0 })
    if renew {
      #expect(
        await host?.renewIfNeeded(now: Date().addingTimeInterval(28 * 86400))
          == true
      )
    }
    let current = try #require(listener.callback.withLock { $0 })
    weak let weakHost = host
    host = nil
    #expect(weakHost == nil)
    for callback in [initial, current] {
      let connection = AdmissionConnection()
      defer { connection.close() }
      callback(connection)
      #expect(connection.closed.withLock { $0 })
      #expect(connection.starts.withLock { $0 } == 0)
    }
  }

  enum StartupFailure: Sendable { case listener, cancellation, control }

  final class StartupListener: RSTListener {
    let port: UInt16 = 51222
    let failure: StartupFailure
    let pair = InMemoryRSTConnection.pair()
    let stopped = Mutex(false)
    let earlyClosed = Mutex(false)

    init(_ failure: StartupFailure) { self.failure = failure }

    func start(
      onConnection: @escaping @Sendable (any RSTConnection) -> Void
    ) async throws {
      onConnection(pair.server)
      do { try await pair.client.sendControl([]) } catch RSTTransportError
        .closed
      { earlyClosed.withLock { $0 = true } }
      switch failure {
      case .listener:
        throw RSTTransportError.handshake("injected startup failure")
      case .cancellation: throw CancellationError()
      case .control: break
      }
    }

    func stop() {
      stopped.withLock { $0 = true }
      pair.server.close()
    }
  }

  @Test(arguments: [StartupFailure.listener, .cancellation, .control])
  func startupFailureReleasesTransportAndEarlyConnections(
    _ failure: StartupFailure
  ) async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = HostConfiguration(
      bindAddress: "127.0.0.1",
      port: 0,
      advertisedHost: "127.0.0.1",
      stateDirectory: directory.path
    )
    if case .control = failure {
      try Data("preserve".utf8)
        .write(to: directory.appendingPathComponent("control.sock"))
    }
    let listener = StartupListener(failure)
    defer {
      listener.stop();
      listener.pair.client.close()
    }
    let certificate = testIdentity().certificate
    await #expect(throws: (any Error).self) {
      try await RoamingHost.start(
        service: makeService(),
        configuration: config,
        transportFactory: { _, now in
          (listener, certificate, now.addingTimeInterval(86400))
        }
      )
    }
    #expect(listener.stopped.withLock { $0 })
    #expect(listener.earlyClosed.withLock { $0 })
    if case .control = failure {
      #expect(
        try String(
          contentsOf: directory.appendingPathComponent("control.sock"),
          encoding: .utf8
        ) == "preserve"
      )
    }
  }

  @Test
  func releasingHostStopsItsListeners() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = HostConfiguration(
      bindAddress: "127.0.0.1",
      port: 0,
      advertisedHost: "127.0.0.1",
      stateDirectory: directory.path
    )
    let listener = StartupListener(.control)
    defer {
      listener.stop();
      listener.pair.client.close()
    }
    let certificate = testIdentity().certificate
    var host: RoamingHost? = try await RoamingHost.start(
      service: makeService(),
      configuration: config,
      transportFactory: { _, now in
        (listener, certificate, now.addingTimeInterval(86400))
      }
    )
    weak let weakHost = host
    #expect(host != nil)
    #expect(!listener.stopped.withLock { $0 })
    host = nil
    #expect(weakHost == nil)
    #expect(listener.stopped.withLock { $0 })
    #expect(!FileManager.default.fileExists(atPath: config.socketPath))
  }

  @Test
  func `the certificate is renewed before it expires and new grants pin it`()
    async throws
  {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = HostConfiguration(
      bindAddress: "127.0.0.1",
      port: 0,
      advertisedHost: "127.0.0.1",
      stateDirectory: directory.appendingPathComponent("state").path
    )
    let host = try await RoamingHost.start(
      service: try makeService(),
      configuration: config
    )
    let before = host.registry.identity.certificate
    // Not yet within the renewal margin: nothing changes.
    #expect(await host.renewIfNeeded() == false)
    #expect(host.registry.identity.certificate == before)

    // Four weeks on, inside the three-day margin of a 30-day certificate.
    #expect(
      await host.renewIfNeeded(now: Date().addingTimeInterval(28 * 24 * 3600))
    )
    let after = host.registry.identity.certificate
    #expect(after != before)
    let grant = try await host.registry.create(
      grid: GridSize(columns: 80, rows: 24)
    )
    #expect(grant.serverCertificateDER == after.der)
    #expect(grant.endpoint.port == host.registry.identity.endpoint.port)
    await host.registry.terminate(grant.sessionID)
  }
}
#endif
