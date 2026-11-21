import Foundation
@testable import RoamingApp
import SSHIdentity
import Testing

extension MainActorIntegrationTests {
  /// A Keychain password is offered only for a saved host and does not
  /// outlive that host or its endpoint, however the change arrived.
  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(1)))
  struct SavedPasswordLifecycleTests {
    @Test(arguments: [false, true])
    func onlyASavedUnchangedHostOffersToSave(edited: Bool) async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      let app = fixture.app
      var host = fixture.host
      if edited { host.port = 2222 }
      let request = Task { await app.password(for: host, retry: false) }
      #expect(try await eventually { app.pendingPassword != nil })
      #expect(app.pendingPassword?.canSave == !edited)
      app.resolvePassword("secret", remember: true)
      #expect(await request.value == "secret")
      #expect(await fixture.passwords.count == (edited ? 0 : 1))
    }

    @Test
    func anUnsavedHostNeverOffersToSave() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      let app = fixture.app
      let draft = HostProfile(
        nickname: "Quick",
        host: "quick.example",
        username: "test"
      )
      let request = Task { await app.password(for: draft, retry: false) }
      #expect(try await eventually { app.pendingPassword != nil })
      #expect(app.pendingPassword?.canSave == false)
      app.resolvePassword("secret", remember: true)
      #expect(await request.value == "secret")
      #expect(await fixture.passwords.count == 0)
    }

    /// A deletion merged from another device goes through the same commit
    /// as the sync coordinator's, not `delete(_:)`.
    @Test
    func aSyncedDeletionRemovesTheSavedPassword() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      try await fixture.savePassword()
      #expect(
        fixture.app.commitConnections(notifySync: false) {
          $0.deleteHost(fixture.host.id)
        }
      )
      #expect(try await eventually { await fixture.passwords.count == 0 })
    }

    @Test(arguments: [false, true])
    func anEndpointEditRemovesTheSavedPassword(endpoint: Bool) async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      try await fixture.savePassword()
      var edited = fixture.host
      if endpoint {
        edited.host = "moved.example"
      } else {
        edited.nickname = "Renamed"
      }
      #expect(try fixture.app.save(edited))
      if endpoint {
        #expect(try await eventually { await fixture.passwords.count == 0 })
      } else {
        try await Task.sleep(for: .milliseconds(50))
        #expect(await fixture.passwords.count == 1)
      }
    }

    private func eventually(_ condition: () async -> Bool) async throws -> Bool
    {
      let deadline = ContinuousClock.now + .seconds(2)
      while !(await condition()) {
        guard ContinuousClock.now < deadline else { return false }
        try await Task.sleep(for: .milliseconds(5))
      }
      return true
    }
  }
}

@MainActor
private struct Fixture {
  let directory: URL
  let defaults: UserDefaults
  let suite: String
  let passwords = InMemorySavedPasswordStore()
  let app: RoamingAppModel
  let host: HostProfile

  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "saved-password-" + UUID().uuidString
    )
    suite = "saved-password-" + UUID().uuidString
    defaults = try #require(UserDefaults(suiteName: suite))
    app = RoamingAppModel(
      store: ConnectionStore(
        fileURL: directory.appendingPathComponent("hosts.json")
      ),
      resumeStore: SessionResumeStore(defaults: defaults),
      savedPasswords: passwords,
      settingsDefaults: defaults,
    )
    host = HostProfile(nickname: "Host", host: "host.example", username: "test")
    #expect(try app.save(host))
  }

  func savePassword() async throws {
    await passwords.save(
      SavedPassword(
        host: host.host,
        port: host.port,
        username: host.username,
        password: "secret"
      ),
      host: host.id
    )
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: directory)
    defaults.removePersistentDomain(forName: suite)
  }
}
