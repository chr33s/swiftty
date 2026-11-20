import Foundation
import RoamingApp
import SSHClient
import SSHIdentity
import XCTest

/// spec.ssh-identity.md SYN-01 across two signed devices on one iCloud
/// account (Scripts/test-cloud-signed.sh). The writer publishes a host, an
/// iCloud Keychain identity and a device-only identity; the reader, on the
/// other device, must receive the profile and both public records, must
/// never get the device-only private key, and should receive the iCloud
/// one. Development CloudKit environment only: not REL-01 evidence.
@MainActor
final class CloudSyncRuntimeTests: XCTestCase {
  static let container = "iCloud.dev.chr33s.swiftty"

  private func environment(_ name: String) throws -> String {
    guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty
    else { throw XCTSkip("\(name) not set; run Scripts/test-cloud-signed.sh") }
    return value
  }

  private func model(_ role: String, run: String) -> RoamingAppModel {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "swiftty-cloud-\(role)-\(run)",
      directoryHint: .isDirectory
    )
    #if targetEnvironment(macCatalyst)
    let profile = PlatformProfile.profile(for: .catalyst)
    #else
    let profile = PlatformProfile.profile(for: .mobile)
    #endif
    let model = RoamingAppModel(
      profile: profile,
      store: ConnectionStore(fileURL: directory.appending(path: "hosts.json")),
      secrets: KeychainIdentitySecretStore(accessGroup: nil),
      legacyKeys: InMemoryLegacyKeySource(),
      cloud: CloudKitConnectionDatabase(containerIdentifier: Self.container)
    )
    model.load()
    return model
  }

  private func refresh(
    _ model: RoamingAppModel,
    seconds: Int,
    until done: () async -> Bool
  ) async -> Bool {
    let deadline = Date.now.addingTimeInterval(TimeInterval(seconds))
    while Date.now < deadline {
      await model.sync?.refresh()?.value
      if await done() { return true }
      try? await Task.sleep(for: .seconds(3))
    }
    return await done()
  }

  func testCloudSyncRole() async throws {
    let role = try environment("SWIFTTY_CLOUD_ROLE")
    let run = try environment("SWIFTTY_CLOUD_RUN")
    let account = try await CloudKitConnectionDatabase(
      containerIdentifier: Self.container
    )
    .accountID()
    print("CLOUD role=\(role) run=\(run) account=\(account)")
    let model = model(role, run: run)
    let sync = try XCTUnwrap(model.sync)
    try await sync.setMetadataSync(true)
    switch role {
    case "writer": try await write(model, run: run)
    case "reader": try await read(model, run: run)
    default: XCTFail("unknown role \(role)")
    }
  }

  private func write(_ model: RoamingAppModel, run: String) async throws {
    let cloud = try await model.identityStore.generate(
      name: "cloud-\(run)",
      policy: .iCloudKeychain
    )
    let local = try await model.identityStore.generate(
      name: "local-\(run)",
      policy: .deviceOnly
    )
    XCTAssertTrue(
      try model.save(
        HostProfile(
          nickname: "cloud-\(run)",
          host: "cloud-\(run).invalid",
          username: "me",
          auth: .key(identityID: cloud.id)
        )
      )
    )
    let sent = await refresh(model, seconds: 120) {
      if case .upToDate = model.sync?.status { return true }
      return false
    }
    print(
      "CLOUD wrote sent=\(sent) status=\(model.sync?.status.summary ?? "-") "
        + "icloud=\(cloud.fingerprint) local=\(local.fingerprint)"
    )
    XCTAssertTrue(sent)
  }

  private func read(_ model: RoamingAppModel, run: String) async throws {
    let wait =
      Int(ProcessInfo.processInfo.environment["SWIFTTY_CLOUD_KEY_WAIT"] ?? "")
      ?? 300
    let arrived = await refresh(model, seconds: 180) {
      model.hosts.contains { $0.nickname == "cloud-\(run)" }
        && model.identities.contains { $0.name == "cloud-\(run)" }
        && model.identities.contains { $0.name == "local-\(run)" }
    }
    print(
      "CLOUD metadata arrived=\(arrived) status=\(model.sync?.status.summary ?? "-")"
    )
    XCTAssertTrue(arrived, "profile and public metadata did not arrive")
    guard arrived,
      let cloud = model.identities.first(where: { $0.name == "cloud-\(run)" }),
      let local = model.identities.first(where: { $0.name == "local-\(run)" })
    else { return }
    let host = try XCTUnwrap(
      model.hosts.first { $0.nickname == "cloud-\(run)" }
    )
    XCTAssertEqual(host.auth, .key(identityID: cloud.id))
    XCTAssertEqual(cloud.storage, .iCloudKeychain)
    XCTAssertEqual(local.storage, .deviceOnly)
    let localAvailability = await model.identityStore.availability(local.id)
    print("CLOUD local availability=\(localAvailability.summary)")
    XCTAssertEqual(localAvailability, .unavailableOnThisDevice)

    // iCloud Keychain delivery is system-managed and may lag.
    let deadline = Date.now.addingTimeInterval(TimeInterval(wait))
    var availability = await model.identityStore.availability(cloud.id)
    while availability != .available, Date.now < deadline {
      try? await Task.sleep(for: .seconds(10))
      availability = await model.identityStore.availability(cloud.id)
    }
    print("CLOUD icloud availability=\(availability.summary) after<=\(wait)s")
    XCTAssertEqual(availability, .available)
    if availability == .available {
      let secret = try await model.identityStore.resolve(cloud.id)
      XCTAssertEqual(
        SSHEd25519Key.fingerprint(of: secret.publicKey),
        cloud.fingerprint
      )
    }
    // The device-only key is still unavailable here.
    let localAfter = await model.identityStore.availability(local.id)
    XCTAssertEqual(localAfter, .unavailableOnThisDevice)

    // Clean up: tombstones for the test records; deleting the iCloud
    // identity removes its synchronizable item.
    model.delete(host)
    try await model.identityStore.delete(cloud.id)
    try await model.identityStore.delete(local.id)
    _ = await refresh(model, seconds: 60) {
      if case .upToDate = model.sync?.status { return true }
      return false
    }
  }
}
