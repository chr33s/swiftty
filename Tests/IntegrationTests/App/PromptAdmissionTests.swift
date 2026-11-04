import Foundation
import NIOSSH
@testable import RoamingApp
import SSHClient
import Testing

extension MainActorIntegrationTests {
  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(1)))
  struct PromptAdmissionTests {
    @Test
    func repeatedNoticesLeaveTheNextTrustDecisionIntact() async throws {
      let app = RoamingAppModel()
      let helper = ConnectionPromptTests()
      let changed = helper.host("changed")
      var decisions: [TrustDecision] = []
      app.onTrustDecision = { _, decision in decisions.append(decision) }
      for _ in 0 ..< 100 {
        app.notifyChangedKey(
          TrustPrompt(
            host: changed,
            kind: .changedKey,
            keyAlgorithm: "ssh-ed25519",
            fingerprint: "SHA256:changed",
          )
        )
      }
      let noticeID = try #require(app.pendingTrust?.id)
      var started = false
      let unknown = helper.host("unknown")
      let request = Task {
        started = true
        return await helper.answer(app, host: unknown, trust: true)
      }
      #expect(try await eventually { started })
      app.resolveTrust(.trust, for: noticeID)
      #expect(app.pendingTrust?.host.id == unknown.id)
      app.resolveTrust(.trust)
      #expect(await request.value)
      #expect(decisions == [.reject, .trust])
      #expect(app.pendingTrust == nil)
    }

    @Test
    func changedKeyNoticesAreBoundedAndFreeCapacityWhenDismissed() {
      let app = RoamingAppModel()
      let helper = ConnectionPromptTests()
      for index in 0 ..< 100 {
        app.notifyChangedKey(
          TrustPrompt(
            host: helper.host("changed-\(index)"),
            kind: .changedKey,
            keyAlgorithm: "ssh-ed25519",
            fingerprint: "SHA256:\(index)",
          )
        )
      }
      var displayed = 0
      while app.pendingTrust != nil {
        displayed += 1
        app.resolveTrust(.trust)
      }
      #expect(displayed == 32)
      app.notifyChangedKey(
        TrustPrompt(
          host: helper.host("next"),
          kind: .changedKey,
          keyAlgorithm: "ssh-ed25519",
          fingerprint: "SHA256:next",
        )
      )
      #expect(app.pendingTrust != nil)
      app.resolveTrust(.reject)
      #expect(app.pendingTrust == nil)
    }

    @Test
    func duplicatePromptIDIsRejectedWithoutAnsweringTheOriginal() async throws {
      let app = RoamingAppModel()
      let helper = ConnectionPromptTests()
      let prompt = TrustPrompt(
        host: helper.host("same"),
        kind: .unknownKey,
        keyAlgorithm: "ssh-ed25519",
        fingerprint: "SHA256:same",
      )
      let first = Task { await app.requestTrust(prompt) }
      #expect(try await eventually { app.pendingTrust?.id == prompt.id })
      var duplicateFinished = false
      let duplicate = Task {
        defer { duplicateFinished = true }
        return await app.requestTrust(prompt)
      }
      #expect(try await eventually { duplicateFinished })
      #expect(app.pendingTrust?.id == prompt.id)
      app.resolveTrust(.trust, for: prompt.id)
      #expect(await first.value == .trust)
      // Also resolve the original implementation's duplicate waiter if present.
      app.resolveTrust(.reject, for: prompt.id)
      #expect(await duplicate.value == .reject)
      #expect(app.pendingTrust == nil)
    }

    private func eventually(_ condition: () -> Bool) async throws -> Bool {
      let deadline = ContinuousClock.now + .seconds(1)
      while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try await Task.sleep(for: .milliseconds(5))
      }
      return true
    }

    @Test(arguments: [false, true])
    func promptQueuesRejectOverflowAndRecoverCapacity(trust: Bool) async throws
    {
      let app = RoamingAppModel()
      let helper = ConnectionPromptTests()
      let limit = 32
      var started = 0
      var requests: [Task<Bool, Never>] = []
      for index in 0 ..< limit {
        let host = helper.host("queued-\(index)")
        requests.append(
          Task {
            started += 1
            return await helper.answer(app, host: host, trust: trust)
          }
        )
        #expect(try await eventually { started == index + 1 })
      }
      let visible = helper.pendingHost(app, trust: trust)
      var overflowFinished = false
      let overflow = Task {
        defer { overflowFinished = true }
        return await helper.answer(
          app,
          host: helper.host("overflow"),
          trust: trust,
        )
      }
      #expect(try await eventually { overflowFinished })
      #expect(helper.pendingHost(app, trust: trust) == visible)
      // Also release the original implementation without leaving a waiting task.
      overflow.cancel()
      #expect(await !(overflow.value))
      requests.last?.cancel()
      #expect(try await !(#require(requests.last?.value)))
      var replacementStarted = false
      let replacement = Task {
        replacementStarted = true
        return await helper.answer(
          app,
          host: helper.host("replacement"),
          trust: trust,
        )
      }
      #expect(try await eventually { replacementStarted })
      while helper.pendingHost(app, trust: trust) != nil {
        helper.resolve(app, trust: trust, allow: true)
      }
      for request in requests.dropLast() { #expect(await request.value) }
      #expect(await replacement.value)
      #expect(helper.pendingHost(app, trust: trust) == nil)
    }

    @Test
    func changedKeyNoticeDoesNotKeepTheAppAlive() async throws {
      let server = try await TestSSHServer.start()
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("changed-key-notice-" + UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      do {
        var app: RoamingAppModel? = RoamingAppModel()
        weak let observedApp = app
        let store = FileHostTrustStore(
          fileURL: directory.appendingPathComponent("keys.json")
        )
        let other = String(
          openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: .init()).publicKey
        )
        try await store.setTrustedKey(other, for: server.identity)
        let access = try SSHAccess(app: #require(app), trustStore: store)
        let host = HostProfile(
          nickname: "Changed",
          host: "127.0.0.1",
          port: server.port,
          username: TestSSHServer.username,
        )
        await #expect(throws: SSHAccessError.hostKeyChanged) {
          _ = try await access.connect(
            host,
            credential: .password(TestSSHServer.password),
          )
        }
        #expect(
          try await eventually {
            observedApp?.pendingTrust?.kind == .changedKey
          }
        )
        #expect(server.state.authRequests.withLock { $0 } == 0)
        app = nil
        let released = try await eventually { observedApp == nil }
        #expect(released)
        // Release the old notification task too, so a failing probe owns cleanup.
        observedApp?.resolveTrust(.reject)
        #expect(try await eventually { observedApp == nil })
      } catch {
        await server.shutdown()
        throw error
      }
      await server.shutdown()
    }
  }
}
