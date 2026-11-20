import Foundation
@testable import RoamingApp
import SSHClient
import Synchronization
import Testing

/// Holds the decision even after cancellation, then deliberately approves late.
private final class HeldTrustDecision: HostTrustDecider {
  let continuation = Mutex<CheckedContinuation<HostTrustDecision, Never>?>(nil)
  let cancelled = Mutex(false)
  let finished = Mutex(false)

  func decide(_ request: HostTrustRequest) async -> HostTrustDecision {
    let decision = await withTaskCancellationHandler {
      await withCheckedContinuation { next in
        continuation.withLock { $0 = next }
      }
    } onCancel: {
      self.cancelled.withLock { $0 = true }
    }
    finished.withLock { $0 = true }
    return decision
  }

  func release() {
    let next = continuation.withLock { value in
      let next = value
      value = nil
      return next
    }
    next?.resume(returning: .trustAndRemember)
  }
}

extension MainActorIntegrationTests {
  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(1)))
  struct HostVerificationLifetimeTests {
    private func eventually(_ condition: () -> Bool) async throws -> Bool {
      let deadline = ContinuousClock.now + .seconds(2)
      while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try await Task.sleep(for: .milliseconds(5))
      }
      return true
    }

    @Test
    func approvalAfterDisconnectDoesNotRememberTheKey() async throws {
      let server = try await TestSSHServer.start()
      let decider = HeldTrustDecision()
      do {
        let store = InMemoryHostTrustStore()
        let request = Task {
          try await SSHConnection.connect(
            configuration: server.configuration(),
            credential: .password(TestSSHServer.password),
            trustStore: store,
            trustDecider: decider,
          )
        }
        #expect(
          try await eventually { decider.continuation.withLock { $0 != nil } }
        )
        await server.shutdown()
        if case let .success(connection) = await request.result {
          Issue.record("Disconnected connection authenticated")
          await connection.close()
        }
        #expect(decider.cancelled.withLock { $0 })
        decider.release()
        #expect(try await eventually { decider.finished.withLock { $0 } })
        // Give an erroneous post-decision write time to appear. The cancellation
        // flag plus the evaluate checkpoints establish the lifetime invariant.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await store.trustedKey(for: server.identity) == nil)
        #expect(server.state.authRequests.withLock { $0 } == 0)
      } catch {
        decider.release()
        await server.shutdown()
        throw error
      }
      decider.release()
      await server.shutdown()
    }

    @Test(arguments: [false, true])
    func appReportsCancelledSignIn(preflight: Bool) async throws {
      let server = try await TestSSHServer.start()
      let suite = "app-cancellation-\(UUID().uuidString)"
      do {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = RoamingAppModel(
          resumeStore: SessionResumeStore(defaults: defaults)
        )
        let directory = FileManager.default.temporaryDirectory
          .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let access = SSHAccess(
          app: app,
          trustStore: FileHostTrustStore(
            fileURL: directory.appendingPathComponent("trust.json")
          ),
        )
        let host = HostProfile(
          nickname: "Test",
          host: "127.0.0.1",
          port: server.port,
          username: TestSSHServer.username,
        )
        let request = Task {
          let connection: SSHConnection =
            if preflight { try await access.connect(host) } else {
              try await access.connect(
                host,
                credential: .password(TestSSHServer.password),
              )
            }
          await connection.close()
        }
        request.cancel()
        if case let .failure(error) = await request.result {
          #expect(error as? SSHAccessError == .cancelled)
        } else {
          Issue.record("Cancelled sign-in succeeded")
        }
        #expect(app.pendingTrust == nil)
        #expect(app.pendingPassword == nil)
        #expect(server.state.authRequests.withLock { $0 } == 0)
      } catch {
        await server.shutdown()
        throw error
      }
      await server.shutdown()
    }

    @Test(arguments: [false, true])
    func anAlreadyCancelledAttemptDoesNotConnect(verifyOnly: Bool) async throws
    {
      let server = try await TestSSHServer.start()
      let request = Task {
        if verifyOnly {
          _ = try await SSHConnection.verifyHostKey(
            configuration: server.configuration(),
            trustStore: server.trustingStore(),
            trustDecider: RejectUnknownHostKeys(),
          )
        } else {
          let connection = try await SSHConnection.connect(
            configuration: server.configuration(),
            credential: .password(TestSSHServer.password),
            trustStore: server.trustingStore(),
            trustDecider: RejectUnknownHostKeys(),
          )
          await connection.close()
        }
      }
      // Both tasks inherit MainActor: cancellation precedes the first step.
      request.cancel()
      if case let .failure(error) = await request.result {
        #expect(error is CancellationError)
      } else {
        Issue.record("An already-cancelled attempt connected")
      }
      #expect(server.state.connections.withLock { $0.channels.isEmpty })
      #expect(server.state.authRequests.withLock { $0 } == 0)
      await server.shutdown()
    }

    @Test(arguments: [false, true])
    func cancellingAnAttemptRemovesThePrompt(verifyOnly: Bool) async throws {
      let server = try await TestSSHServer.start()
      do {
        let suite = "verification-cancellation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = RoamingAppModel(
          resumeStore: SessionResumeStore(defaults: defaults)
        )
        let host = HostProfile(
          nickname: "Test",
          host: "127.0.0.1",
          port: server.port,
          username: "test",
        )
        let store = InMemoryHostTrustStore()
        let decider = ClosureHostTrustDecider { request in
          await app.requestTrust(
            TrustPrompt(
              host: host,
              kind: .unknownKey,
              keyAlgorithm: request.keyType,
              fingerprint: request.fingerprint,
            )
          ) == .trust ? .trustAndRemember : .reject
        }
        let request = Task {
          if verifyOnly {
            _ = try await SSHConnection.verifyHostKey(
              configuration: server.configuration(),
              trustStore: store,
              trustDecider: decider,
            )
          } else {
            let connection = try await SSHConnection.connect(
              configuration: server.configuration(),
              credential: .password(TestSSHServer.password),
              trustStore: store,
              trustDecider: decider,
            )
            await connection.close()
          }
        }
        #expect(try await eventually { app.pendingTrust != nil })
        request.cancel()
        #expect(try await eventually { app.pendingTrust == nil })
        #expect(
          try await eventually {
            server.state.connections.withLock { $0.channels.isEmpty }
          }
        )
        // Release the original implementation (cancellation left SSH open).
        app.resolveTrust(.reject)
        await server.shutdown()
        if case let .failure(error) = await request.result {
          #expect(error is CancellationError)
        } else {
          Issue.record("Cancelled connection attempt succeeded")
        }
        #expect(await store.trustedKey(for: server.identity) == nil)
        #expect(server.state.authRequests.withLock { $0 } == 0)
      } catch {
        await server.shutdown()
        throw error
      }
      await server.shutdown()
    }

    @Test(arguments: [false, true])
    func closingDuringVerificationRemovesThePrompt(timeout: Bool) async throws {
      let server = try await TestSSHServer.start()
      do {
        let suite = "verification-lifetime-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = RoamingAppModel(
          resumeStore: SessionResumeStore(defaults: defaults)
        )
        let host = HostProfile(
          nickname: "Test",
          host: "127.0.0.1",
          port: server.port,
          username: "test",
        )
        let store = InMemoryHostTrustStore()
        var configuration = server.configuration()
        configuration.connectTimeout = timeout ? .seconds(1) : .seconds(5)
        let request = Task {
          try await SSHConnection.verifyHostKey(
            configuration: configuration,
            trustStore: store,
            trustDecider: ClosureHostTrustDecider { request in
              await app.requestTrust(
                TrustPrompt(
                  host: host,
                  kind: .unknownKey,
                  keyAlgorithm: request.keyType,
                  fingerprint: request.fingerprint,
                )
              ) == .trust ? .trustAndRemember : .reject
            },
          )
        }
        let visible = try await eventually { app.pendingTrust != nil }
        #expect(visible)
        if !timeout { await server.shutdown() }
        let outcome = await request.result
        if case .success = outcome {
          Issue.record("Closed connection verified its host")
        }
        if timeout, case let .failure(error) = outcome {
          #expect(error as? SSHClientError == .connectTimeout)
        }
        let removed = try await eventually { app.pendingTrust == nil }
        #expect(removed)
        // Release the old detached verifier so a regression leaks no task.
        app.resolveTrust(.reject)
        await server.shutdown()
        #expect(await store.trustedKey(for: server.identity) == nil)
      } catch {
        await server.shutdown()
        throw error
      }
      await server.shutdown()
    }
  }
}
