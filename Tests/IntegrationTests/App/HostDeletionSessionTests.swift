import Foundation
import NIOSSH
@testable import RoamingApp
import SessionCore
import SSHIdentity
import Testing

extension MainActorIntegrationTests.IdentityAccountBoundaryTests {
  @Test(arguments: ["unchanged", "account", "endpoint"])
  func deletingAReplacementHostPreservesTheAuthenticatedShell(
    change: String
  ) async throws {
    let suite = "delete-shell-\(UUID().uuidString)"
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
    let key = try await model.identityStore.resolve(identity.id)
    let server = try await TestSSHServer.start(authorizedKeys: [
      NIOSSHPrivateKey(ed25519Key: key.ed25519PrivateKey!).publicKey
    ])
    let host = HostProfile(
      nickname: "A",
      host: "127.0.0.1",
      port: server.port,
      username: TestSSHServer.username,
      auth: .key(identityID: identity.id)
    )
    #expect(try model.save(host))
    model.open(host, kind: .ordinarySSH)
    let screen = try #require(model.activeSession)
    let controller = SSHShellController(model: screen, app: model)
    screen.controller = controller
    do {
      try await model.ssh.trustFile.setTrustedKey(
        server.hostKeyLine,
        for: server.identity
      )
      controller.start()
      try #require(
        await eventually { @MainActor in controller.phase == .running }
      )
      let connection = try #require(controller.connection)
      let replacement = try await replaceResumeHost(
        host,
        change: change,
        in: model
      )
      model.delete(
        replacement,
        expecting: model.hostMutationContext(for: replacement)
      )
      if change == "unchanged" {
        #expect(model.activeSession == nil)
        #expect(await eventually { @Sendable in !connection.isActive })
      } else {
        #expect(model.activeSession === screen)
        #expect(connection.isActive)
        controller.session.send(.text("retained-owner"))
        #expect(
          await eventually { @MainActor in
            controller.session.withState {
              $0.screenLines.joined().contains("retained-owner")
            }
          }
        )
      }
      #expect(server.state.authRequests.withLock { $0 } == 1)
    } catch {
      model.close()
      await controller.close(.detach)
      await server.shutdown()
      throw error
    }
    model.close()
    await controller.close(.detach)
    await server.shutdown()
  }

  @Test(arguments: [
    "account", "binding", "endpoint", "port", "username", "unchanged", "rename",
    "key", "case", "roundTrip",
  ])
  func deletingAHostClosesOnlyItsOwnTerminal(change: String) async throws {
    let suite = "delete-owner-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    let model = resumeApp(defaults)
    if change != "binding" { await select("account-a", in: model) }
    let original = HostProfile(nickname: "A", host: "a.local", username: "me")
    #expect(try model.save(original))
    let workspace = SessionID.random()
    model.openWorkspace(original, intent: .resume(workspace, nil))
    let terminal = try #require(model.activeSession)
    let originalSelection = try #require(terminal.selection)
    var host = try await replaceResumeHost(original, change: change, in: model)
    switch change {
    case "rename": host.nickname = "Renamed"
    case "case": host.host = host.host.uppercased()
    case "key": host.auth = .key(identityID: UUID())
    case "roundTrip":
      await select("account-b", in: model)
      await select("account-a", in: model)
    default: break
    }
    #expect(try model.save(host))
    let sameOwner = ["unchanged", "rename", "key", "case", "roundTrip"]
      .contains(change)
    let selected = model.connectionSelection(for: host)
    if !sameOwner { model.rememberSession(.random(), for: selected) }
    model.delete(host, expecting: selected.context)
    #expect(!model.hosts.contains(where: { $0.id == host.id }))
    #expect(terminal.isClosed == sameOwner)
    #expect((model.activeSession === terminal) == !sameOwner)
    #expect(model.resumableSessionID(for: selected) == nil)
    #expect(
      model.resumableSessionID(for: originalSelection)
        == (sameOwner ? nil : workspace)
    )
    model.close()
  }
}
