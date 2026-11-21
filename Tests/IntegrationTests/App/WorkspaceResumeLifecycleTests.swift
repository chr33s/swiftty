import Foundation
import NIOSSH
@testable import RoamingApp
import ScreenProtocol
import SessionCore
import SSHIdentity
import Testing

private actor WorkspaceBootstrapGate {
  private var request: BootstrapRequest?
  private var release: CheckedContinuation<Void, Never>?
  private var released = false

  func reply(to bytes: [UInt8]) async -> [UInt8] {
    guard
      let request = try? BootstrapEnvelope.decode(
        BootstrapRequest.self,
        from: bytes
      )
    else { return [] }
    self.request = request
    if !released { await withCheckedContinuation { release = $0 } }
    return
      (try? BootstrapEnvelope.encode(BootstrapResponse.failure(.unknownSession)))
      ?? []
  }

  func observed() -> BootstrapRequest? { request }

  func resume() {
    released = true
    release?.resume()
    release = nil
  }
}

extension MainActorIntegrationTests.IdentityAccountBoundaryTests {
  @Test(arguments: [
    "unchanged", "rename", "key", "case", "accountReturn", "endpointReturn",
  ])
  func validWorkspaceChoicesSurviveReopening(change: String) async throws {
    let suite = "resume-reopen-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    let model = resumeApp(defaults)
    await select("account-a", in: model)
    let original = HostProfile(nickname: "A", host: "a.local", username: "me")
    #expect(try model.save(original))
    let first = SessionID.random()
    model.openWorkspace(original, intent: .resume(first, nil))
    model.close()
    var host = original
    switch change {
    case "rename": host.nickname = "New display name"
    case "case": host.host = "A.LOCAL"
    case "key":
      let key = try await model.identityStore.generate(
        name: "New key",
        policy: .deviceOnly
      )
      host.auth = .key(identityID: key.id)
    case "accountReturn", "endpointReturn":
      let replacement = try await replaceResumeHost(
        original,
        change: change == "accountReturn" ? "account" : "endpoint",
        in: model
      )
      model.openWorkspace(replacement, intent: .resume(.random(), nil))
      model.close()
      if change == "accountReturn" { await select("account-a", in: model) }
    default: break
    }
    #expect(try model.save(host))
    #expect(model.resumableSessionID(for: host) == first)
    #expect(model.resumableHosts.contains(host.id))
    let reopened = resumeApp(defaults)
    #expect(reopened.resumableSessionID(for: host) == first)
    #expect(reopened.resumableHosts.contains(host.id))
    #expect(reopened.resumeLastWorkspace(host))
    #expect(
      reopened.activeSession?.takeWorkspaceIntent() == .resume(first, nil)
    )
    reopened.close()
  }

  @Test(arguments: [false, true])
  func legacyWorkspaceChoicesNeedAnExplicitSelection(cloud: Bool) async throws {
    let suite = "resume-legacy-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    let model = resumeApp(defaults)
    if cloud { await select("account-a", in: model) }
    let host = HostProfile(nickname: "A", host: "a.local", username: "me")
    #expect(try model.save(host))
    let legacy = SessionID.random()
    let store = SessionResumeStore(defaults: defaults)
    store.set(legacy, for: host.id)
    let reopened = resumeApp(defaults)
    #expect(reopened.resumableSessionID(for: host) == nil)
    #expect(!reopened.resumableHosts.contains(host.id))
    #expect(!reopened.resumeLastWorkspace(host))
    // Choosing the listed workspace is sufficient; no data is silently adopted.
    reopened.openWorkspace(host, intent: .resume(legacy, nil))
    #expect(reopened.resumableSessionID(for: host) == legacy)
    #expect(reopened.resumableHosts.contains(host.id))
    reopened.close()
    #expect(resumeApp(defaults).resumableSessionID(for: host) == legacy)
    #expect(store.sessionID(for: host.id) == legacy)
  }

  @Test(arguments: ["account", "endpoint"], [false, true])
  func retainedWorkspaceUpdatesStayWithTheirOwner(
    change: String,
    forget: Bool
  ) async throws {
    let suite = "resume-update-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    let model = resumeApp(defaults)
    await select("account-a", in: model)
    let original = HostProfile(nickname: "A", host: "a.local", username: "me")
    #expect(try model.save(original))
    model.openWorkspace(original, intent: .resume(.random(), nil))
    let oldSelection = try #require(model.activeSession?.selection)
    let replacement = try await replaceResumeHost(
      original,
      change: change,
      in: model
    )
    let newSelection = model.connectionSelection(for: replacement)
    let newChoice = SessionID.random()
    model.rememberSession(newChoice, for: newSelection)
    let lateChoice = SessionID.random()
    if forget {
      model.forgetSession(for: oldSelection)
    } else {
      model.rememberSession(lateChoice, for: oldSelection)
    }
    #expect(model.resumableSessionID(for: replacement) == newChoice)
    #expect(model.resumableHosts.contains(replacement.id))
    model.close()
    if change == "account" { await select("account-a", in: model) }
    #expect(try model.save(original))
    #expect(
      model.resumableSessionID(for: original) == (forget ? nil : lateChoice)
    )
    #expect(model.resumableHosts.contains(original.id) == !forget)
    #expect(model.resumableSessionID(for: newSelection) == newChoice)
  }

  @Test(arguments: ["unchanged", "account", "endpoint"])
  func lateBootstrapFailureCannotForgetAReplacementWorkspace(
    change: String
  ) async throws {
    let suite = "resume-bootstrap-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    let model = resumeApp(defaults)
    await select("account-a", in: model)
    let identity = try await model.identityStore.generate(
      name: "A",
      policy: .deviceOnly
    )
    let secret = try await model.identityStore.resolve(identity.id)
    let server = try await TestSSHServer.start(authorizedKeys: [
      NIOSSHPrivateKey(ed25519Key: secret.ed25519PrivateKey!).publicKey
    ])
    let gate = WorkspaceBootstrapGate()
    server.state.bootstrapForwarder.withLock {
      $0 = { await gate.reply(to: $0) }
    }
    let host = HostProfile(
      nickname: "A",
      host: "127.0.0.1",
      port: server.port,
      username: TestSSHServer.username,
      auth: .key(identityID: identity.id)
    )
    #expect(try model.save(host))
    let initial = SessionID.random()
    model.openWorkspace(host, intent: .resume(initial, nil))
    let screen = try #require(model.activeSession)
    let controller = RoamingTerminalController(model: screen, app: model)
    do {
      try await model.ssh.trustFile.setTrustedKey(
        server.hostKeyLine,
        for: server.identity
      )
      controller.start()
      let arrived = await eventually { @Sendable in await gate.observed() != nil
      }
      try #require(arrived)
      let request = try #require(await gate.observed())
      #expect(request.operation == .resume)
      #expect(request.sessionID == initial)
      let replacement = try await replaceResumeHost(
        host,
        change: change,
        in: model
      )
      let newChoice = SessionID.random()
      if change != "unchanged" {
        model.rememberSession(
          newChoice,
          for: model.connectionSelection(for: replacement)
        )
      }
      await gate.resume()
      #expect(
        await eventually { @MainActor in
          if case .failed = controller.phase { return true }
          return false
        }
      )
      // Drain the actual client status callbacks as well as the failed start.
      #expect(
        await eventually { @MainActor in screen.connectionState == .sessionLost
        }
      )
      #expect(
        model.resumableSessionID(for: replacement)
          == (change == "unchanged" ? nil : newChoice)
      )
      #expect(
        model.resumableHosts.contains(replacement.id) == (change != "unchanged")
      )
      #expect(server.state.authRequests.withLock { $0 } == 2)
    } catch {
      await gate.resume()
      await controller.close(.detach)
      model.close()
      await server.shutdown()
      throw error
    }
    await controller.close(.detach)
    model.close()
    await server.shutdown()
  }
}
