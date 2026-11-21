import Foundation
@testable import RoamingApp
import SSHClient
@testable import SSHIdentity
import Testing

/// An in-memory private database with change tags and a change log, per
/// account (spec.ssh-identity.md §8).
actor FakeCloud: ConnectionCloudDatabase {
  struct Zone {
    var records: [String: (record: CloudRecord, tag: Int)] = [:]
    var log: [(seq: Int, name: String)] = []
    var seq = 0
  }

  var account: String? = "acct-a"
  var zones: [String: Zone] = [:]
  var fetchFailure: CloudSyncError?
  var saveFailure: CloudSyncError?
  var beforeFetch: (@Sendable () async -> Void)?
  var beforeAccount: (@Sendable () async -> Void)?
  /// Runs once, before the next save is applied.
  var beforeSave: (@Sendable () async -> Void)?
  private(set) var saveCount = 0

  func setAccount(_ value: String?) { account = value }
  func failNextFetch(_ error: CloudSyncError?) { fetchFailure = error }
  func failNextSave(_ error: CloudSyncError?) { saveFailure = error }
  func onNextFetch(_ work: (@Sendable () async -> Void)?) { beforeFetch = work }
  func onNextAccount(_ work: (@Sendable () async -> Void)?) {
    beforeAccount = work
  }
  func onNextSave(_ work: (@Sendable () async -> Void)?) { beforeSave = work }
  func records(_ account: String) -> [CloudRecord] {
    zones[account]?.records.values.map(\.record) ?? []
  }

  private func checkedAccountID() throws(CloudSyncError) -> String {
    guard let account else { throw .accountRequired }
    return account
  }

  func accountID() async throws(CloudSyncError) -> String {
    let account = try checkedAccountID()
    if let work = beforeAccount {
      beforeAccount = nil
      await work()
    }
    return account
  }

  func createZone() throws(CloudSyncError) {
    let account = try checkedAccountID()
    if zones[account] == nil { zones[account] = Zone() }
  }

  func fetchChanges(
    since token: Data?
  ) async throws(CloudSyncError) -> CloudChangePage {
    if let work = beforeFetch {
      beforeFetch = nil
      await work()
    }
    if let fetchFailure {
      self.fetchFailure = nil
      throw fetchFailure
    }
    let account = try checkedAccountID()
    guard let zone = zones[account] else { throw .zoneNotFound }
    let since = token.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
    let names = Set(zone.log.filter { $0.seq > since }.map(\.name))
    return CloudChangePage(
      changed: names.sorted().compactMap { zone.records[$0]?.record },
      deleted: [],
      token: Data(String(zone.seq).utf8),
      moreComing: false
    )
  }

  func save(
    _ records: [CloudRecord]
  ) async throws(CloudSyncError) -> [String: Result<
    CloudRecord, CloudSyncError
  >] {
    if let work = beforeSave {
      beforeSave = nil
      await work()
    }
    if let saveFailure {
      self.saveFailure = nil
      throw saveFailure
    }
    saveCount += 1
    let account = try checkedAccountID()
    guard var zone = zones[account] else { throw .zoneNotFound }
    var results: [String: Result<CloudRecord, CloudSyncError>] = [:]
    for record in records {
      let sentTag = record.systemFields.flatMap {
        Int(String(decoding: $0, as: UTF8.self))
      }
      if let existing = zone.records[record.name], sentTag != existing.tag {
        results[record.name] = .failure(.conflict(existing.record))
        continue
      }
      let tag = (zone.records[record.name]?.tag ?? 0) + 1
      var saved = record
      saved.systemFields = Data(String(tag).utf8)
      zone.seq += 1
      zone.records[record.name] = (saved, tag)
      zone.log.append((zone.seq, record.name))
      results[record.name] = .success(saved)
    }
    zones[account] = zone
    return results
  }
}

extension MainActorIntegrationTests {
  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(1)))
  struct ConnectionSyncTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "sync-" + UUID().uuidString
    )

    func device(_ name: String, cloud: FakeCloud) -> RoamingAppModel {
      let model = RoamingAppModel(
        profile: .profile(for: .mobile),
        store: ConnectionStore(
          fileURL: root.appendingPathComponent(name)
            .appendingPathComponent("hosts.json")
        ),
        secrets: InMemoryIdentitySecretStore(),
        legacyKeys: InMemoryLegacyKeySource(),
        cloud: cloud
      )
      model.load()
      model.sync?.setActive(false)
      model.identityStore.currentICloudAccount = {
        try? await cloud.accountID()
      }
      return model
    }

    func sync(_ model: RoamingAppModel) async {
      await model.sync?.refresh()?.value
    }

    func enable(_ models: RoamingAppModel...) async throws {
      for model in models {
        try await #require(model.sync).setMetadataSync(true)
        await sync(model)
      }
    }

    static func host(
      _ name: String,
      auth: AuthMethodReference = .password
    ) -> HostProfile {
      HostProfile(
        nickname: name,
        host: name.lowercased() + ".local",
        username: "me",
        auth: auth
      )
    }

    @Test(arguments: [false, true])
    func accountChangesWhileSyncIsOffStillQuarantineAndRestore(
      signOut: Bool
    ) async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let model = device("a", cloud: cloud)
      let coordinator = try #require(model.sync)
      #expect(try model.save(Self.host("Original")))
      try await enable(model)
      let original = model.hosts
      try await coordinator.setMetadataSync(false)
      let saves = await cloud.saveCount
      await cloud.setAccount(signOut ? nil : "acct-b")
      coordinator.accountDidChange()
      #expect(model.hosts.isEmpty)
      await sync(model)
      #expect(model.connections.boundAccount == nil)
      #expect(model.hosts.isEmpty)
      #expect(!model.connections.settings.metadataSync)
      #expect(await cloud.saveCount == saves)
      await cloud.setAccount("acct-a")
      coordinator.accountDidChange()
      await sync(model)
      #expect(model.hosts == original)
      #expect(model.connections.boundAccount == "acct-a")
      #expect(!model.connections.settings.metadataSync)
      #expect(await cloud.saveCount == saves)
    }

    @Test
    func syncIsOffByDefaultAndUploadsNothing() async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let a = device("a", cloud: cloud)
      #expect(try a.save(Self.host("Mac")))
      await sync(a)
      #expect(a.sync?.status == .off)
      #expect(await cloud.saveCount == 0)
    }

    @Test(
      arguments: ["enable", "confirm", "recover"],
      ["disable", "account", "cancel"]
    )
    func supersededAccountLookupCannotCommit(
      operation: String,
      interruption: String
    ) async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let a = device("a", cloud: cloud)
      let coordinator = try #require(a.sync)
      if operation != "enable" { try await enable(a) }
      if operation == "recover" {
        #expect(a.commitConnections { $0.accounts["acct-a"]?.zoneLost = true })
      }
      let (started, signalStart) = AsyncStream<Void>.makeStream()
      let (resume, signalResume) = AsyncStream<Void>.makeStream()
      await cloud.onNextAccount {
        signalStart.yield(())
        signalStart.finish()
        for await _ in resume { break }
      }
      let pending = Task {
        switch operation {
        case "enable": try await coordinator.setMetadataSync(true)
        case "confirm": try await coordinator.confirmCurrentAccount()
        default: try await coordinator.recoverZone()
        }
      }
      for await _ in started { break }
      switch interruption {
      case "disable": try await coordinator.setMetadataSync(false)
      case "account":
        await cloud.setAccount("acct-b")
        coordinator.accountDidChange()
        await sync(a)
      default: pending.cancel()
      }
      let before = a.connections
      let accountBefore = coordinator.currentAccount
      signalResume.yield(())
      signalResume.finish()
      try await pending.value
      #expect(a.connections == before)
      #expect(coordinator.currentAccount == accountBefore)
      if interruption == "disable" { #expect(coordinator.status == .off) }
      await coordinator.refresh()?.value
    }

    @Test
    func failedTrustDisablePersistenceCannotRestoreConsent() async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let model = device("a", cloud: cloud)
      try await enable(model)
      let coordinator = try #require(model.sync)
      let endpoint = try #require(HostIdentity(host: "server.local", port: 22))
      let key = SSHEd25519Key.authorizedKeysLine(
        for: SSHEd25519Key.generate().publicKey
      )
      #expect(coordinator.setTrustSync(true, trustedKeys: [endpoint: key]))
      let file = root.appendingPathComponent("a/hosts.json")
      let saved = try Data(contentsOf: file)
      try FileManager.default.removeItem(at: file)
      try FileManager.default.createDirectory(
        at: file,
        withIntermediateDirectories: false
      )
      #expect(!coordinator.setTrustSync(false, trustedKeys: [:]))
      #expect(model.lastError != nil)
      #expect(!coordinator.trustSyncEnabled)
      #expect(!coordinator.setTrustSync(true, trustedKeys: [:]))
      await sync(model)
      #expect(await cloud.saveCount == 0)
      #expect(await cloud.records("acct-a").isEmpty)
      try FileManager.default.removeItem(at: file)
      try saved.write(to: file)
      await sync(model)
      #expect(await cloud.saveCount == 0)
      #expect(await cloud.records("acct-a").isEmpty)
      #expect(!model.connections.settings.trustSync)
      #expect(device("a", cloud: cloud).sync?.trustSyncEnabled == false)
      // Profile sync is still consented; only trust must remain queued.
      #expect(coordinator.metadataSyncEnabled)
      #expect(try model.save(Self.host("Profile")))
      await sync(model)
      #expect(
        await cloud.records("acct-a").map(\.type) == [ConnectionRecords.host]
      )
      #expect(coordinator.setTrustSync(true, trustedKeys: [:]))
      await sync(model)
      #expect(await cloud.records("acct-a").count == 2)
    }

    @Test
    func failedTrustRevocationBlocksPendingTrustAdoption() async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let model = device("a", cloud: cloud)
      try await enable(model)
      let coordinator = try #require(model.sync)
      #expect(coordinator.setTrustSync(true, trustedKeys: [:]))
      let endpoint = try #require(HostIdentity(host: "remote.local", port: 22))
      let key = SSHEd25519Key.authorizedKeysLine(
        for: SSHEd25519Key.generate().publicKey
      )
      let name = ConnectionSnapshot.knownHostRecord(
        host: endpoint.host,
        port: endpoint.port
      )
      #expect(
        model.commitConnections { snapshot in
          snapshot.trustInbox[name] = KnownHostRecord(
            host: endpoint.host,
            port: endpoint.port,
            publicKey: key,
            fingerprint: SSHPublicKeyFormat.fingerprint(openSSHPublicKey: key)
              ?? "",
            provenance: .synced(deviceID: UUID()),
            revision: snapshot.tick()
          )
          snapshot.scopes[name] = "acct-a"
        }
      )
      let file = root.appendingPathComponent("a/hosts.json")
      let saved = try Data(contentsOf: file)
      try FileManager.default.removeItem(at: file)
      try FileManager.default.createDirectory(
        at: file,
        withIntermediateDirectories: false
      )
      #expect(!coordinator.setTrustSync(false, trustedKeys: [:]))
      await sync(model)
      #expect(try await model.ssh.trustFile.trustedKey(for: endpoint) == nil)
      #expect(model.connections.trustInbox[name] != nil)
      try FileManager.default.removeItem(at: file)
      try saved.write(to: file)
      await sync(model)
      #expect(try await model.ssh.trustFile.trustedKey(for: endpoint) == nil)
      #expect(coordinator.setTrustSync(true, trustedKeys: [:]))
      await sync(model)
      #expect(try await model.ssh.trustFile.trustedKey(for: endpoint) == key)
    }

    @Test
    func disablingTrustSyncStopsLaterSaveBatches() async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let a = device("a", cloud: cloud)
      let coordinator = try #require(a.sync)
      let key = SSHEd25519Key.authorizedKeysLine(
        for: SSHEd25519Key.generate().publicKey
      )
      var trusted: [HostIdentity: String] = [:]
      for index in 0 ... ConnectionSyncCoordinator.batchSize {
        trusted[
          try #require(HostIdentity(host: "host-\(index).local", port: 22))
        ] = key
      }
      coordinator.setTrustSync(true, trustedKeys: trusted)
      await cloud.onNextSave {
        await coordinator.setTrustSync(false, trustedKeys: [:])
      }
      try await enable(a)
      // The first request was already submitted; the remaining record must stay queued.
      #expect(
        await cloud.records("acct-a").count
          == ConnectionSyncCoordinator.batchSize
      )
      #expect(a.connections.accounts["acct-a"]?.outbox.count == 1)
      #expect(!a.connections.settings.trustSync)
    }

    @Test
    func pendingTrustFromAnotherAccountStaysQuarantined() async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let writer = device("writer", cloud: cloud)
      let reader = device("reader", cloud: cloud)
      let endpoint = try #require(
        HostIdentity(host: "account-a.local", port: 22)
      )
      let key = SSHEd25519Key.authorizedKeysLine(
        for: SSHEd25519Key.generate().publicKey
      )
      let publisher = try #require(writer.sync)
      let subscriber = try #require(reader.sync)
      publisher.setTrustSync(true, trustedKeys: [endpoint: key])
      try await enable(writer, reader)
      #expect(reader.connections.trustInbox.count == 1)
      #expect(try await reader.ssh.trustFile.trustedKey(for: endpoint) == nil)
      await cloud.setAccount("acct-b")
      subscriber.accountDidChange()
      await sync(reader)
      try await subscriber.confirmCurrentAccount()
      await sync(reader)
      subscriber.setTrustSync(true, trustedKeys: [:])
      await sync(reader)
      #expect(reader.connections.boundAccount == "acct-b")
      #expect(try await reader.ssh.trustFile.trustedKey(for: endpoint) == nil)
      #expect(reader.connections.trustInbox.count == 1)
      // Returning to the original account can apply its deferred trust.
      await cloud.setAccount("acct-a")
      subscriber.accountDidChange()
      await sync(reader)
      #expect(try await reader.ssh.trustFile.trustedKey(for: endpoint) == key)
      #expect(reader.connections.trustInbox.isEmpty)
    }

    @Test
    func matchingHostIDsKeepAccountDataAndPendingEditsSeparate() async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let first = device("first", cloud: cloud)
      var hostA = Self.host("account-a")
      for index in 0 ..< 4 {
        hostA.nickname = "Account A \(index)"
        #expect(try first.save(hostA))
      }
      try await enable(first)
      var reader = device("reader", cloud: cloud)
      try await enable(reader)
      var pendingA = hostA
      pendingA.nickname = "A pending edit"
      #expect(try reader.save(pendingA))

      await cloud.setAccount("acct-b")
      let second = device("second", cloud: cloud)
      var hostB = hostA
      hostB.nickname = "Account B"
      hostB.host = "b.local"
      #expect(try second.save(hostB))
      try await enable(second)
      reader.sync?.accountDidChange()
      await sync(reader)
      try await #require(reader.sync).confirmCurrentAccount()
      await sync(reader)
      #expect(reader.hosts == [hostB])
      let name = ConnectionSnapshot.hostRecord(hostA.id)
      #expect(
        await cloud.records("acct-b").first { $0.name == name }?
          .fields["nickname"] == .string("Account B")
      )
      #expect(reader.connections.accounts["acct-a"]?.outbox[name] != nil)
      #expect(reader.connections.hiddenCount == 1)

      // The displaced cache and pending revision must survive a process restart.
      reader = device("reader", cloud: cloud)
      await cloud.setAccount("acct-a")
      reader.sync?.accountDidChange()
      await sync(reader)
      #expect(reader.hosts == [pendingA])
      #expect(
        await cloud.records("acct-a").first { $0.name == name }?
          .fields["nickname"] == .string("A pending edit")
      )
      await cloud.setAccount("acct-b")
      reader.sync?.accountDidChange()
      await sync(reader)
      #expect(reader.hosts == [hostB])
    }

    @Test
    func matchingTrustEndpointsRetainEachAccountsDeferredRecord() async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let endpoint = try #require(HostIdentity(host: "same.local", port: 22))
      let keyA = SSHEd25519Key.authorizedKeysLine(
        for: SSHEd25519Key.generate().publicKey
      )
      let keyB = SSHEd25519Key.authorizedKeysLine(
        for: SSHEd25519Key.generate().publicKey
      )
      let first = device("first", cloud: cloud)
      first.sync?.setTrustSync(true, trustedKeys: [endpoint: keyA])
      try await enable(first)
      var reader = device("reader", cloud: cloud)
      try await enable(reader)
      let name = ConnectionSnapshot.knownHostRecord(
        host: endpoint.host,
        port: endpoint.port
      )
      #expect(reader.connections.trustInbox[name]?.publicKey == keyA)
      await cloud.setAccount("acct-b")
      let second = device("second", cloud: cloud)
      second.sync?.setTrustSync(true, trustedKeys: [endpoint: keyB])
      try await enable(second)
      reader.sync?.accountDidChange()
      await sync(reader)
      try await #require(reader.sync).confirmCurrentAccount()
      await sync(reader)
      #expect(reader.connections.trustInbox[name]?.publicKey == keyB)
      reader = device("reader", cloud: cloud)
      await cloud.setAccount("acct-a")
      reader.sync?.accountDidChange()
      await sync(reader)
      #expect(reader.connections.trustInbox[name]?.publicKey == keyA)
      reader.sync?.setTrustSync(true, trustedKeys: [:])
      await sync(reader)
      #expect(try await reader.ssh.trustFile.trustedKey(for: endpoint) == keyA)
      await cloud.setAccount("acct-b")
      reader.sync?.accountDidChange()
      await sync(reader)
      // A conflicting key from B must be reviewed against the existing pin.
      #expect(try await reader.ssh.trustFile.trustedKey(for: endpoint) == keyA)
      #expect(
        reader.connections.trustReviews[name]?.kind
          == .conflictingKey(
            remoteKey: keyB,
            remoteFingerprint: SSHPublicKeyFormat.fingerprint(
              openSSHPublicKey: keyB
            )!
          )
      )
    }

    @Test
    func accountSwitchHidesUnresolvedHostAndTrustReviews() async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let model = device("reader", cloud: cloud)
      let host = Self.host("conflicted")
      #expect(try model.save(host))
      try await enable(model)
      let name = ConnectionSnapshot.knownHostRecord(
        host: host.host,
        port: host.port
      )
      let review = TrustReview(
        recordName: name,
        host: host.host,
        port: host.port,
        kind: .removedElsewhere,
        localFingerprint: nil
      )
      #expect(
        model.commitConnections { snapshot in
          snapshot.hostConflicts[host.id] = HostConflict(
            remote: host,
            remoteRevision: snapshot.tick()
          )
          snapshot.trustReviews[name] = review
          snapshot.scopes[name] = "acct-a"
        }
      )
      #expect(model.hostConflicts.count == 1)
      #expect(model.trustReviews.count == 1)
      await cloud.setAccount("acct-b")
      let coordinator = try #require(model.sync)
      coordinator.accountDidChange()
      await sync(model)
      #expect(model.hostConflicts.isEmpty)
      #expect(model.trustReviews.isEmpty)
      // A stale row action must not mutate quarantined state either.
      let before = model.connections
      coordinator.resolveConflict(host: host.id, keepLocal: true)
      await coordinator.resolve(review)
      await sync(model)
      #expect(model.connections == before)
    }

    @Test(arguments: [false, true])
    func failedDisablePersistenceCannotRestoreUploadConsent(
      signOut: Bool
    ) async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let model = device("a", cloud: cloud)
      try await enable(model)
      #expect(try model.save(Self.host("Queued")))
      let coordinator = try #require(model.sync)
      let file = root.appendingPathComponent("a/hosts.json")
      let saved = try Data(contentsOf: file)
      try FileManager.default.removeItem(at: file)
      try FileManager.default.createDirectory(
        at: file,
        withIntermediateDirectories: false
      )
      // Real filesystem failure, rather than a fake persistence callback.
      await #expect(throws: CloudSyncError.settingsNotSaved) {
        try await coordinator.setMetadataSync(false)
      }
      #expect(model.lastError != nil)
      #expect(coordinator.status == .off)
      #expect(!coordinator.metadataSyncEnabled)
      coordinator.setActive(true)
      coordinator.localChange()
      #expect(coordinator.status == .off)
      await sync(model)
      #expect(await cloud.saveCount == 0)
      #expect(await cloud.records("acct-a").isEmpty)
      // A failed explicit opt-in must not bypass the pending durable revocation.
      await #expect(throws: CloudSyncError.settingsNotSaved) {
        try await coordinator.setMetadataSync(true)
      }
      #expect(!coordinator.metadataSyncEnabled)
      if signOut {
        await cloud.setAccount(nil)
        coordinator.accountDidChange()
        await sync(model)
      }
      // Making storage writable again must not silently re-enable uploads.
      try FileManager.default.removeItem(at: file)
      try saved.write(to: file)
      await sync(model)
      #expect(await cloud.saveCount == 0)
      #expect(await cloud.records("acct-a").isEmpty)
      #expect(!model.connections.settings.metadataSync)
      #expect(coordinator.status == .off)
      // The retry persists even while signed out, so a new model starts off.
      let reloaded = device("a", cloud: cloud)
      #expect(!reloaded.connections.settings.metadataSync)
      #expect(reloaded.sync?.metadataSyncEnabled == false)
      if signOut {
        await cloud.setAccount("acct-a")
        coordinator.accountDidChange()
        await sync(model)
      }
      try await enable(model)
      #expect(coordinator.metadataSyncEnabled)
      #expect(await cloud.records("acct-a").count == 1)
    }

    @Test
    func failedEnablePersistenceReportsErrorAndKeepsSyncOff() async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let model = device("a", cloud: cloud)
      #expect(try model.save(Self.host("Queued")))
      let coordinator = try #require(model.sync)
      let file = root.appendingPathComponent("a/hosts.json")
      try FileManager.default.removeItem(at: file)
      try FileManager.default.createDirectory(
        at: file,
        withIntermediateDirectories: false
      )
      await #expect(throws: CloudSyncError.settingsNotSaved) {
        try await coordinator.setMetadataSync(true)
      }
      #expect(!coordinator.metadataSyncEnabled)
      await sync(model)
      #expect(await cloud.saveCount == 0)
      #expect(await cloud.records("acct-a").isEmpty)
    }

    // SYN-01
    @Test(arguments: [false, true])
    func cancelledFetchCannotStartAnUpload(disableSync: Bool) async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let a = device("a", cloud: cloud)
      let coordinator = try #require(a.sync)
      #expect(try a.save(Self.host("Queued")))
      let (started, signalStart) = AsyncStream<Void>.makeStream()
      let (resume, signalResume) = AsyncStream<Void>.makeStream()
      await cloud.onNextFetch {
        signalStart.yield(())
        signalStart.finish()
        for await _ in resume { break }
      }
      try await coordinator.setMetadataSync(true)
      let running = try #require(coordinator.refresh())
      for await _ in started { break }
      if disableSync {
        try await coordinator.setMetadataSync(false)
      } else {
        running.cancel()
      }
      signalResume.yield(())
      signalResume.finish()
      await running.value
      #expect(await cloud.saveCount == 0)
      #expect(await cloud.records("acct-a").isEmpty)
      #expect(a.connections.accounts["acct-a"]?.outbox.count == 1)
      if disableSync { #expect(coordinator.status == .off) }
      // Queued metadata remains available for a later, consented run.
      try await enable(a)
      #expect(await cloud.records("acct-a").count == 1)
    }

    @Test(arguments: [false, true])
    func cancellationStopsLaterUploadBatches(disableSync: Bool) async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let model = device("a", cloud: cloud)
      let coordinator = try #require(model.sync)
      for index in 0 ... ConnectionSyncCoordinator.batchSize {
        #expect(try model.save(Self.host("Queued-\(index)")))
      }
      let (started, signalStart) = AsyncStream<Void>.makeStream()
      let (resume, signalResume) = AsyncStream<Void>.makeStream()
      await cloud.onNextSave {
        signalStart.yield(())
        signalStart.finish()
        for await _ in resume { break }
      }
      try await coordinator.setMetadataSync(true)
      let running = try #require(coordinator.refresh())
      for await _ in started { break }
      if disableSync {
        try await coordinator.setMetadataSync(false)
      } else {
        running.cancel()
      }
      signalResume.yield(())
      signalResume.finish()
      await running.value
      // The submitted request can finish, but no later batch may start.
      #expect(await cloud.saveCount == 1)
      #expect(
        await cloud.records("acct-a").count
          == ConnectionSyncCoordinator.batchSize
      )
      if disableSync { #expect(coordinator.status == .off) }
      try await enable(model)
      #expect(
        await cloud.records("acct-a").count == ConnectionSyncCoordinator
          .batchSize + 1
      )
    }

    // SYN-01
    @Test
    func profilesAndPublicMetadataSyncButDeviceOnlySecretsDoNot() async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let a = device("a", cloud: cloud)
      let b = device("b", cloud: cloud)
      let key = try await a.identityStore.generate(
        name: "A's key",
        policy: .deviceOnly
      )
      #expect(try a.save(Self.host("Mac", auth: .key(identityID: key.id))))
      try await enable(a, b)
      #expect(b.hosts.map(\.nickname) == ["Mac"])
      #expect(b.identities.map(\.fingerprint) == [key.fingerprint])
      #expect(
        await b.identityStore.availability(key.id) == .unavailableOnThisDevice
      )
      await #expect(throws: IdentityResolutionError.unavailableOnThisDevice) {
        _ = try await b.identityStore.resolve(key.id)
      }
      // No private material in any cloud field.
      let secret = try await a.identityStore.resolve(key.id)
      let raw = secret.ed25519PrivateKey!.rawRepresentation
      for record in await cloud.records("acct-a") {
        for value in record.fields.values {
          if case .bytes(let data) = value {
            #expect(data.range(of: raw) == nil)
          }
          if case .string(let text) = value {
            #expect(!text.contains(raw.base64EncodedString()))
          }
        }
      }
      if case .upToDate = a.sync?.status {
      } else {
        Issue.record("not up to date")
      }
    }

    // SYN-03
    @Test
    func anAcknowledgmentCannotDiscardANewerEdit() async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let a = device("a", cloud: cloud)
      try await enable(a)
      var host = Self.host("Mac")
      #expect(try a.save(host))
      host.nickname = "Edited in flight"
      let edited = host
      await cloud.onNextSave { @Sendable in
        await MainActor.run { _ = try? a.save(edited) }
      }
      await sync(a)
      let account = try #require(a.connections.boundAccount)
      let name = ConnectionSnapshot.hostRecord(host.id)
      #expect(a.connections.accounts[account]?.outbox[name] != nil)
      await sync(a)
      #expect(a.connections.accounts[account]?.outbox[name] == nil)
      let stored = await cloud.records(account).first { $0.name == name }
      #expect(stored?.fields["nickname"] == .string("Edited in flight"))
    }

    // SYN-03, SYN-04: an offline edit survives process death; a failed
    // fetch does not advance the checkpoint or drop queued work.
    @Test
    func failuresKeepQueuedWorkAndCheckpoints() async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      var a = device("a", cloud: cloud)
      try await enable(a)
      let account = try #require(a.connections.boundAccount)
      let token = a.connections.accounts[account]?.changeToken
      await cloud.failNextFetch(.networkUnavailable)
      #expect(try a.save(Self.host("Offline")))
      await sync(a)
      #expect(a.sync?.status == .offline)
      #expect(a.connections.accounts[account]?.changeToken == token)
      #expect(a.connections.accounts[account]?.outbox.count == 1)
      // Relaunch; the retry window is cleared for the test.
      a = device("a", cloud: cloud)
      #expect(a.commitConnections { $0.accounts[account]?.retryAt = nil })
      #expect(a.connections.accounts[account]?.outbox.count == 1)
      await cloud.failNextSave(.quotaExceeded)
      await sync(a)
      #expect(a.sync?.status == .error(CloudSyncError.quotaExceeded.message))
      #expect(a.connections.accounts[account]?.outbox.count == 1)
      await sync(a)
      #expect(a.connections.accounts[account]?.outbox.isEmpty == true)
    }

    // SYN-05
    @Test
    func renamesConvergeAndTupleConflictsNeedReview() async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let a = device("a", cloud: cloud)
      let b = device("b", cloud: cloud)
      let original = Self.host("Mac")
      #expect(try a.save(original))
      try await enable(a, b)
      var renamedA = original
      renamedA.nickname = "From A"
      var renamedB = original
      renamedB.nickname = "From B"
      #expect(try a.save(renamedA))
      #expect(try b.save(renamedB))
      await sync(a)
      await sync(b)
      await sync(a)
      #expect(a.hosts.first?.nickname == b.hosts.first?.nickname)

      var movedA = try #require(a.hosts.first)
      movedA.host = "a-network.local"
      var movedB = try #require(b.hosts.first)
      movedB.host = "b-network.local"
      #expect(try a.save(movedA))
      #expect(try b.save(movedB))
      await sync(a)
      await sync(b)
      #expect(
        b.connections.hostConflicts[original.id]?.remote.host
          == "a-network.local"
      )
      #expect(b.hosts.first?.host == "b-network.local")
      b.sync?.resolveConflict(host: original.id, keepLocal: false)
      await sync(b)
      #expect(b.hosts.first?.host == "a-network.local")
      #expect(b.connections.hostConflicts.isEmpty)
    }

    /// The agreed base is what the server received: an edit made while a
    /// save was in flight still conflicts with a concurrent remote edit.
    @Test
    func anInFlightEditStillConflictsWithAConcurrentRemoteEdit() async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let a = device("a", cloud: cloud)
      let b = device("b", cloud: cloud)
      let original = Self.host("Mac")
      #expect(try a.save(original))
      try await enable(a, b)
      var sent = original
      sent.host = "sent.local"
      var inFlight = original
      inFlight.host = "in-flight.local"
      let edit = inFlight
      #expect(try a.save(sent))
      await cloud.onNextSave { @Sendable in
        await MainActor.run { _ = try? a.save(edit) }
      }
      await sync(a)
      await sync(b)
      #expect(b.hosts.first?.host == "sent.local")
      var remote = try #require(b.hosts.first)
      remote.host = "remote.local"
      #expect(try b.save(remote))
      await sync(b)
      await sync(a)
      #expect(a.hosts.first?.host == "in-flight.local")
      #expect(
        a.connections.hostConflicts[original.id]?.remote.host == "remote.local"
      )
    }

    @Test
    func sameUUIDWithDifferentKeyMaterialIsQuarantined() async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let a = device("a", cloud: cloud)
      let b = device("b", cloud: cloud)
      let key = try await a.identityStore.generate(
        name: "Key",
        policy: .deviceOnly
      )
      try await enable(a, b)
      let forged = SSHIdentityMetadata(
        id: key.id,
        name: "Forged",
        publicKey: SSHEd25519Key.generate().publicKey,
        storage: .deviceOnly,
        revision: LogicalRevision(counter: 999, deviceID: UUID())
      )
      _ = try await cloud.save([
        CloudRecord(
          name: ConnectionSnapshot.identityRecord(key.id),
          type: ConnectionRecords.identity,
          fields: ConnectionRecords.encode(identity: forged),
          systemFields: Data("1".utf8)
        )
      ])
      await sync(a)
      #expect(a.identity(key.id)?.publicKey == key.publicKey)
      #expect(a.connections.identityConflicts[key.id] != nil)
      await #expect(throws: IdentityResolutionError.integrityConflict) {
        _ = try await a.identityStore.resolve(key.id)
      }
    }

    // SYN-06
    @Test
    func aStaleDeviceCannotResurrectATombstone() async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let a = device("a", cloud: cloud)
      let b = device("b", cloud: cloud)
      let host = Self.host("Mac")
      #expect(try a.save(host))
      try await enable(a, b)
      a.delete(host)
      await sync(a)
      var stale = try #require(b.hosts.first)
      stale.nickname = "Stale edit"
      #expect(try b.save(stale))
      await sync(b)
      await sync(a)
      #expect(a.hosts.isEmpty)
      #expect(b.hosts.isEmpty)
      #expect(b.connections.hostTombstones[host.id] != nil)
      // Disabling sync keeps local data and deletes nothing remotely.
      try await #require(b.sync).setMetadataSync(false)
      #expect(await cloud.records("acct-a").count == 1)
    }

    // SYN-07
    @Test
    func anAccountSwitchQuarantinesThePreviousAccountsData() async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let a = device("a", cloud: cloud)
      #expect(try a.save(Self.host("Synced")))
      try await enable(a)
      await cloud.setAccount("acct-b")
      a.sync?.accountDidChange()
      await sync(a)
      #expect(a.sync?.status == .accountChanged)
      #expect(a.hosts.isEmpty)
      #expect(a.connections.hiddenCount == 1)
      #expect(try a.save(Self.host("Local")))
      try await #require(a.sync).confirmCurrentAccount()
      await sync(a)
      let uploaded = await cloud.records("acct-b")
        .compactMap { $0.fields["nickname"] }
      #expect(uploaded == [.string("Local")])
      // Signing back in to the first account restores its data.
      await cloud.setAccount("acct-a")
      a.sync?.accountDidChange()
      await sync(a)
      #expect(a.hosts.map(\.nickname).contains("Synced"))
    }

    @Test
    func signingOutQuarantinesUntilTheSameAccountReturns() async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let a = device("a", cloud: cloud)
      #expect(try a.save(Self.host("Synced")))
      try await enable(a)
      await cloud.setAccount(nil)
      a.sync?.accountDidChange()
      await sync(a)
      #expect(a.sync?.status == .accountRequired)
      #expect(a.hosts.isEmpty)
      await cloud.setAccount("acct-a")
      a.sync?.accountDidChange()
      await sync(a)
      #expect(a.hosts.map(\.nickname) == ["Synced"])
    }

    @Test
    func zoneLossNeedsExplicitRecovery() async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let a = device("a", cloud: cloud)
      #expect(try a.save(Self.host("Mac")))
      try await enable(a)
      await cloud.failNextFetch(.zoneNotFound)
      await sync(a)
      #expect(a.sync?.status == .zoneRecoveryRequired)
      let saves = await cloud.saveCount
      await sync(a)
      #expect(await cloud.saveCount == saves)
      try await #require(a.sync).recoverZone()
      await sync(a)
      if case .upToDate = a.sync?.status {
      } else {
        Issue.record("not recovered")
      }
    }

    @Test
    func unsupportedAndMalformedRecordsAreKeptApart() async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let a = device("a", cloud: cloud)
      try await enable(a)
      _ = try await cloud.save([
        CloudRecord(
          name: "future-1",
          type: "SwifttyFutureV9",
          fields: ["schema": .int(9)]
        ),
        CloudRecord(
          name: ConnectionSnapshot.hostRecord(UUID()),
          type: ConnectionRecords.host,
          fields: ["schema": .int(1)]
        ),
      ])
      await sync(a)
      let account = try #require(a.connections.boundAccount)
      #expect(a.connections.accounts[account]?.opaque["future-1"] != nil)
      #expect(a.connections.accounts[account]?.quarantine.count == 1)
      #expect(a.hosts.isEmpty)
    }

    // Known-host conflicts block rather than overwrite (§8.3).
    @Test
    func trustConflictsKeepTheLocalPin() async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let a = device("a", cloud: cloud)
      let b = device("b", cloud: cloud)
      try await enable(a, b)
      let endpoint = try #require(HostIdentity(host: "mac.local", port: 22))
      let keyA = SSHEd25519Key.authorizedKeysLine(
        for: SSHEd25519Key.generate().publicKey
      )
      let keyB = SSHEd25519Key.authorizedKeysLine(
        for: SSHEd25519Key.generate().publicKey
      )
      try await a.ssh.trustStore.setTrustedKey(keyA, for: endpoint)
      try await b.ssh.trustStore.setTrustedKey(keyB, for: endpoint)
      try #require(a.sync)
        .setTrustSync(true, trustedKeys: try await a.ssh.trustFile.entries())
      try #require(b.sync)
        .setTrustSync(true, trustedKeys: try await b.ssh.trustFile.entries())
      await sync(a)
      await sync(b)
      #expect(try await b.ssh.trustFile.trustedKey(for: endpoint) == keyB)
      #expect(b.connections.trustReviews.count == 1)

      // A third device with no pin adopts the delegated trust.
      let c = device("c", cloud: cloud)
      try await enable(c)
      try #require(c.sync).setTrustSync(true, trustedKeys: [:])
      await sync(c)
      let adopted = try await c.ssh.trustFile.trustedKey(for: endpoint)
      #expect(adopted == keyA || adopted == keyB)
    }
  }
}
