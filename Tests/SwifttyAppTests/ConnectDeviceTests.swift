import CoreTestSupport
import AppKit
import CoreImage
import CryptoKit
import SwiftUI
import Foundation
import HostConnection
@testable import Swiftty
import Testing

/// Records registrations instead of touching DNS-SD.
@MainActor
private final class FakeRegistrar: ServiceRegistering {
  var registrations: [(name: String, port: UInt16, txt: [UInt8])] = []
  var cancels = 0
  var update: (@MainActor (HostAdvertiser.State) -> Void)?

  func register(
    name: String,
    port: UInt16,
    txt: [UInt8],
    update: @escaping @MainActor (HostAdvertiser.State) -> Void
  ) {
    registrations.append((name, port, txt))
    self.update = update
  }

  func cancel() {
    cancels += 1
    update = nil
  }
}

/// The native Connect a Device panel (spec.connection-setup.md D2–D4,
/// acceptance T4, T6, T9).
@MainActor
@Suite
struct ConnectDeviceTests {
  static let key = HostConnectionDescriptor.HostKey(
    algorithm: "ssh-ed25519",
    sha256: "SHA256:" + String(repeating: "A", count: 43)
  )

  func draft(_ host: String, port: String = "22") -> ConnectionDraft {
    ConnectionDraft(host: host, port: port, username: "chris")
  }

  @Test
  func `wildcard and loopback addresses are never offered`() {
    for host in [
      "0.0.0.0", "::", "::1", "localhost", "127.0.0.1", "a.localhost",
    ] { #expect(draft(host).problem == .unusableAddress, "\(host)") }
    #expect(draft("ssh://mac.local").problem == .invalidHost)
    #expect(draft("macbook.local").problem == nil)
    #expect(draft("vpn.example.com").problem == nil)
  }

  @Test
  func `a nondefault SSH port needs confirmation`() {
    var value = draft("macbook.local", port: "2222")
    #expect(value.needsPortConfirmation)
    #expect(value.problem == .portUnconfirmed)
    #expect(value.descriptor(name: "Mac", hostKeys: [Self.key]) == nil)
    value.portConfirmed = true
    #expect(value.problem == nil)
    #expect(value.descriptor(name: "Mac", hostKeys: [Self.key])?.port == 2222)
    #expect(draft("macbook.local", port: "0").problem == .invalidPort)
  }

  @Test
  func `local-only addresses are labelled honestly`() {
    #expect(draft("macbook.local").isLocalOnly)
    #expect(draft("192.168.1.4").isLocalOnly)
    #expect(draft("172.20.0.9").isLocalOnly)
    #expect(!draft("172.40.0.9").isLocalOnly)
    #expect(!draft("mac.example.com").isLocalOnly)
  }

  @Test
  func `no code is offered without SSH host keys`() {
    #expect(draft("macbook.local").descriptor(name: "Mac", hostKeys: []) == nil)
  }

  @Test
  func `exported code round-trips through the shared decoder`() throws {
    let descriptor = try #require(
      draft("macbook.local")
        .descriptor(name: "Chris's\nMac", hostKeys: [Self.key])
    )
    let decoded = try HostConnectionDescriptor.decode(
      descriptor.encodedString()
    )
    #expect(decoded == descriptor)
    #expect(decoded.name == "Chris's Mac")
    #expect(decoded.host == "macbook.local")
    #expect(decoded.username == "chris")
    #expect(PairingCodeView.qrImage(try descriptor.encodedString()) != nil)
  }

  // MARK: Host keys

  func keyLine(_ algorithm: String = "ssh-ed25519") -> (String, String) {
    var blob = Data()
    let name = Array(algorithm.utf8)
    blob.append(
      contentsOf: withUnsafeBytes(of: UInt32(name.count).bigEndian, Array.init)
    )
    blob.append(contentsOf: name)
    let raw = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
    blob.append(
      contentsOf: withUnsafeBytes(of: UInt32(raw.count).bigEndian, Array.init)
    )
    blob.append(raw)
    var digest = Data(SHA256.hash(data: blob)).base64EncodedString()
    while digest.last == "=" { digest.removeLast() }
    return (
      "\(algorithm) \(blob.base64EncodedString()) root@mac", "SHA256:" + digest
    )
  }

  @Test
  func `fingerprints match the clients' canonical SHA-256 form`() throws {
    let (line, expected) = keyLine()
    let key = try #require(LocalConnectionInfo.hostKey(publicKeyLine: line))
    #expect(key.algorithm == "ssh-ed25519")
    #expect(key.sha256 == expected)
    #expect(HostConnectionDescriptor.isValidFingerprint(key.sha256))
  }

  @Test
  func `unsupported or mislabelled keys are skipped`() {
    let (line, _) = keyLine()
    #expect(
      LocalConnectionInfo.hostKey(
        publicKeyLine: line.replacingOccurrences(
          of: "ssh-ed25519 ",
          with: "ssh-rsa "
        )
      ) == nil
    )
    #expect(
      LocalConnectionInfo.hostKey(
        publicKeyLine: line.replacingOccurrences(
          of: "ssh-ed25519 ",
          with: "ecdsa-sha2-nistp256 "
        )
      ) == nil
    )
    #expect(
      LocalConnectionInfo.hostKey(publicKeyLine: "ssh-ed25519 !!!") == nil
    )
  }

  @Test
  func `only public host key files are read`() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let (line, expected) = keyLine()
    try line.write(
      to: directory.appendingPathComponent("ssh_host_ed25519_key.pub"),
      atomically: true,
      encoding: .utf8
    )
    // A private key file whose content is a valid public line must still
    // be ignored: only `.pub` names are opened.
    let (other, otherPrint) = keyLine()
    try other.write(
      to: directory.appendingPathComponent("ssh_host_ed25519_key"),
      atomically: true,
      encoding: .utf8
    )
    try FileManager.default.createSymbolicLink(
      at: directory.appendingPathComponent("ssh_host_ecdsa_key.pub"),
      withDestinationURL: directory.appendingPathComponent(
        "ssh_host_ed25519_key"
      )
    )
    let keys = LocalConnectionInfo.hostKeys(in: directory)
    #expect(keys.map(\.sha256) == [expected])
    #expect(!keys.map(\.sha256).contains(otherPrint))
  }

  @Test
  func `roaming configuration is reported as configured, not verified`() throws
  {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.json")
    #expect(LocalConnectionInfo.roamingConfiguration(at: url) == .absent)
    try
      #"{"bindAddress":"0.0.0.0","advertisedHost":"mac.vpn.example","port":4000}"#
      .write(to: url, atomically: true, encoding: .utf8)
    #expect(
      LocalConnectionInfo.roamingConfiguration(at: url)
        == .configured(.init(advertisedHost: "mac.vpn.example", port: 4000))
    )
    try "not json".write(to: url, atomically: true, encoding: .utf8)
    #expect(LocalConnectionInfo.roamingConfiguration(at: url) == .unreadable)
  }

  // MARK: Advertisement

  @Test
  func `advertisement uses the chosen SSH port and bounded TXT`() {
    let registrar = FakeRegistrar()
    let advertiser = HostAdvertiser(registrar: registrar)
    advertiser.start(name: "Chris's\u{0} Mac", port: 2222)
    #expect(registrar.registrations.count == 1)
    #expect(registrar.registrations[0].port == 2222)
    #expect(registrar.registrations[0].name == "Chris's Mac")
    let txt = registrar.registrations[0].txt
    #expect(txt.count <= HostDiscovery.maxTXTBytes)
    let text = String(decoding: txt, as: UTF8.self)
    #expect(text.contains("product=swiftty"))
    #expect(!text.contains("chris"))
    registrar.update?(.advertising(name: "Chris's Mac", port: 2222))
    #expect(advertiser.state == .advertising(name: "Chris's Mac", port: 2222))
    advertiser.stop()
    #expect(advertiser.state == .stopped)
    #expect(registrar.cancels >= 1)
  }

  @Test
  func `late registration updates after withdrawal are ignored`() {
    let registrar = FakeRegistrar()
    let advertiser = HostAdvertiser(registrar: registrar)
    advertiser.start(name: "Mac", port: 22)
    let late = registrar.update
    advertiser.stop()
    late?(.advertising(name: "Mac", port: 22))
    #expect(advertiser.state == .stopped)
  }

  fileprivate func panel(
    _ registrar: FakeRegistrar,
    checks: Counter = Counter()
  ) -> ConnectDeviceModel {
    ConnectDeviceModel(
      advertiser: HostAdvertiser(registrar: registrar),
      host: "macbook.local",
      username: "chris",
      computerName: "Chris's Mac",
      readKeys: { [Self.key] },
      readRoaming: { .absent },
      probeSSH: { _ in
        checks.bump();
        return .ok("ok")
      },
      probeHelper: {
        checks.bump();
        return .unavailable("no")
      }
    )
  }

  final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
  }

  @Test
  func `closing the panel withdraws discovery and nothing else`() async throws {
    let registrar = FakeRegistrar()
    let model = panel(registrar)
    model.refresh()
    model.setDiscoverable(true)
    #expect(registrar.registrations.map(\.port) == [22])
    model.close()
    #expect(!model.discoverable)
    #expect(registrar.cancels >= 1)
    #expect(registrar.update == nil)
  }

  @Test
  func `editing the endpoint withdraws the advertisement and the code`() {
    let registrar = FakeRegistrar()
    let model = panel(registrar)
    model.refresh()
    model.showsCode = true
    model.setDiscoverable(true)
    model.draft.port = "2222"
    #expect(!model.discoverable)
    #expect(!model.showsCode)
    // Unconfirmed nondefault port: not advertised.
    model.setDiscoverable(true)
    #expect(!model.discoverable)
    model.draft.portConfirmed = true
    model.setDiscoverable(true)
    #expect(registrar.registrations.last?.port == 2222)
    model.close()
  }

  @Test
  func `opening the panel runs read-only checks only`() async throws {
    let registrar = FakeRegistrar()
    let checks = Counter()
    let model = panel(registrar, checks: checks)
    model.refresh()
    let deadline = ContinuousClock.now + .seconds(5)
    while checks.count < 2, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(checks.count == 2)
    #expect(registrar.registrations.isEmpty)
    #expect(model.descriptor?.hostKeys == [Self.key])
    model.close()
  }

  /// The panel as shown: rendered pixels carry a QR code that decodes to
  /// the exported descriptor (spec.connection-setup.md D2, D4).
  @Test
  func `the shown pairing code renders and scans back to the descriptor`()
    throws
  {
    let model = panel(FakeRegistrar())
    model.refresh()
    model.showsCode = true
    let expected = try #require(model.descriptor)
    let text = try expected.encodedString()
    let view = NSHostingView(rootView: PairingCodeView(text: text))
    view.frame = NSRect(x: 0, y: 0, width: 320, height: 360)
    view.layoutSubtreeIfNeeded()
    let rep = try #require(
      view.bitmapImageRepForCachingDisplay(in: view.bounds)
    )
    view.cacheDisplay(in: view.bounds, to: rep)
    let image = try #require(CIImage(bitmapImageRep: rep))
    let detector = try #require(
      CIDetector(
        ofType: CIDetectorTypeQRCode,
        context: nil,
        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
      )
    )
    let payloads = detector.features(in: image)
      .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    #expect(payloads == [text])
    #expect(try HostConnectionDescriptor.decode(payloads[0]) == expected)
    // The panel itself lays out with the code shown.
    let panelView = NSHostingView(rootView: ConnectDeviceView(model: model))
    panelView.frame = NSRect(x: 0, y: 0, width: 520, height: 900)
    panelView.layoutSubtreeIfNeeded()
    #expect(panelView.fittingSize.height > 0)
    model.close()
  }

  /// The real registration advertises the chosen SSH port and TXT, and
  /// withdrawing it removes the record (T4). Resolved with the system's
  /// `dns-sd` tool, a separate process.
  @Test
  func `real registration advertises the chosen port and withdraws`()
    async throws
  {
    let advertiser = HostAdvertiser()
    let name = "Swiftty Test \(UInt16.random(in: 1000 ... 9999))"
    advertiser.start(name: name, port: 2222)
    let deadline = ContinuousClock.now + .seconds(10)
    while case .registering = advertiser.state, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(advertiser.state == .advertising(name: name, port: 2222))
    let resolved = try await Self.resolve(name)
    #expect(resolved.contains(":2222"))
    #expect(resolved.contains("product=swiftty"))
    #expect(resolved.contains("txtvers=1"))
    advertiser.stop()
    try await Task.sleep(for: .milliseconds(500))
    #expect(!(try await Self.browse()).contains(name))
  }

  /// `dns-sd -L` output for a few seconds.
  static func resolve(_ name: String) async throws -> String {
    try await run(["-L", name, "_swiftty._tcp", "local"])
  }

  static func browse() async throws -> String {
    try await run(["-B", "_swiftty._tcp", "local"])
  }

  static func run(_ arguments: [String]) async throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    try await Task.sleep(for: .seconds(3))
    process.terminate()
    process.waitUntilExit()
    return String(
      decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
      as: UTF8.self
    )
  }

  /// With `SWIFTTY_PAIRING_PNG=<path>`, writes the pairing code exactly as
  /// the panel renders it for this Mac's real details, for a physical scan.
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["SWIFTTY_PAIRING_PNG"] != nil
    )
  )
  func `export this Mac's rendered pairing code for a device scan`() throws {
    let path = try #require(
      ProcessInfo.processInfo.environment["SWIFTTY_PAIRING_PNG"]
    )
    let model = ConnectDeviceModel()
    model.refresh()
    let descriptor = try #require(model.descriptor, "no host keys or host name")
    let view = NSHostingView(
      rootView: PairingCodeView(text: try descriptor.encodedString())
    )
    view.frame = NSRect(x: 0, y: 0, width: 320, height: 360)
    view.layoutSubtreeIfNeeded()
    let rep = try #require(
      view.bitmapImageRepForCachingDisplay(in: view.bounds)
    )
    view.cacheDisplay(in: view.bounds, to: rep)
    try #require(rep.representation(using: .png, properties: [:]))
      .write(to: URL(fileURLWithPath: path))
    print("pairing code: \(try descriptor.encodedString())")
    model.close()
  }
}
