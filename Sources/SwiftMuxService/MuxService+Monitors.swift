import CryptoKit
import Darwin
import Dispatch
import Foundation
import HostConnection
import Network
import SwifttyConfig
import SwifttyJS

/// Environment monitors behind service-level script events. Each starts
/// only once a script listens, so an unobserved service never browses the
/// network, polls the settings file or watches interfaces.
///
/// Sendable: every property is read and written on `queue`; results reach
/// the service through `onQueue`.
final class AutomationMonitors: @unchecked Sendable {
  private let queue = DispatchQueue(
    label: "swiftmux.automation.monitors",
    qos: .utility
  )
  private weak var service: MuxService?
  private var configuration: DispatchSourceTimer?
  private var configurationHash: String?
  private var configurationGeneration: UInt64 = 0
  private var browser: NWBrowser?
  private var hostNames: [String]?
  private var path: NWPathMonitor?
  private var tailscale: (running: Bool, addresses: [String])?

  static let configurationInterval: DispatchTimeInterval = .seconds(2)
  static let maxConfigurationBytes = 1 << 20

  init(service: MuxService) { self.service = service }

  deinit {
    configuration?.cancel()
    browser?.cancel()
    path?.cancel()
  }

  func start(_ events: Set<JavaScriptEvent.Name>) {
    queue.async { [self] in
      if events.contains(.configuration) { startConfiguration() }
      if events.contains(.hosts) { startHosts() }
      if events.contains(.tailscale) { startTailscale() }
    }
  }

  func stop() {
    queue.async { [self] in
      configuration?.cancel()
      configuration = nil
      browser?.cancel()
      browser = nil
      path?.cancel()
      path = nil
    }
  }

  private func emit(_ event: JavaScriptEvent) {
    service?.onQueue { $0.automationRuntime?.emit(event) }
  }

  // MARK: Settings file

  /// The file the app loads, resolved without the agent's own arguments.
  static var settingsURL: URL {
    ((try? ConfigDiscovery.resolve(arguments: [])) ?? nil)
      ?? ConfigDiscovery.defaultURL()
  }

  /// SHA-256 of the settings file, or "" when it is missing or too large
  /// to be a settings file.
  static func digest(_ url: URL) -> String {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: maxConfigurationBytes + 1),
      data.count <= maxConfigurationBytes
    else { return "" }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func startConfiguration() {
    guard configuration == nil else { return }
    configurationHash = Self.digest(Self.settingsURL)
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(
      deadline: .now() + Self.configurationInterval,
      repeating: Self.configurationInterval
    )
    timer.setEventHandler { [weak self] in self?.checkConfiguration() }
    configuration = timer
    timer.resume()
  }

  private func checkConfiguration() {
    let url = Self.settingsURL
    let hash = Self.digest(url)
    guard hash != configurationHash else { return }
    configurationHash = hash
    configurationGeneration &+= 1
    emit(
      .configurationChanged(
        generation: configurationGeneration,
        hash: hash,
        path: url.path
      )
    )
  }

  // MARK: Hosts

  private func startHosts() {
    guard browser == nil else { return }
    let browser = NWBrowser(
      for: .bonjour(type: HostDiscovery.serviceType, domain: nil),
      using: NWParameters()
    )
    browser.browseResultsChangedHandler = { [weak self] results, _ in
      self?.hostsChanged(results)
    }
    browser.stateUpdateHandler = { state in
      if case let .failed(error) = state {
        NSLog("Swiftty JavaScript hosts: %@", String(describing: error))
      }
    }
    self.browser = browser
    browser.start(queue: queue)
  }

  private func hostsChanged(_ results: Set<NWBrowser.Result>) {
    var names: [String] = []
    for result in results.prefix(HostDiscovery.maxCandidates) {
      if case let .service(name, _, _, _) = result.endpoint {
        names.append(HostDiscovery.sanitizedName(name))
      }
    }
    names = Array(Set(names)).sorted()
    guard names != hostNames else { return }
    hostNames = names
    let hash = SHA256.hash(data: Data(names.joined(separator: "\n").utf8))
      .map { String(format: "%02x", $0) }.joined()
    emit(.hostsChanged(names, hash: hash))
  }

  // MARK: Tailscale

  private func startTailscale() {
    guard path == nil else { return }
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] _ in self?.checkTailscale() }
    path = monitor
    monitor.start(queue: queue)
  }

  private func checkTailscale() {
    let addresses = Self.tailscaleAddresses()
    let status = (running: !addresses.isEmpty, addresses: addresses)
    guard tailscale.map({ $0 != status }) ?? true else { return }
    tailscale = status
    emit(.tailscaleStatusChanged(running: status.running, addresses: addresses))
  }

  /// Tailscale's tunnel is a `utun` interface carrying an address from its
  /// 100.64.0.0/10 range (or its fd7a:115c:a1e0::/48 IPv6 prefix).
  static func tailscaleAddresses() -> [String] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let head else { return [] }
    defer { freeifaddrs(head) }
    var found: [String] = []
    var cursor: UnsafeMutablePointer<ifaddrs>? = head
    while let entry = cursor {
      defer { cursor = entry.pointee.ifa_next }
      let name = String(cString: entry.pointee.ifa_name)
      guard name.hasPrefix("utun"),
        entry.pointee.ifa_flags & UInt32(IFF_UP) != 0,
        let address = entry.pointee.ifa_addr
      else { continue }
      if let text = Self.tailscaleAddress(address) { found.append(text) }
    }
    return Array(Set(found)).sorted()
  }

  static func tailscaleAddress(
    _ address: UnsafeMutablePointer<sockaddr>
  ) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    switch Int32(address.pointee.sa_family) {
    case AF_INET:
      return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
        var value = $0.pointee.sin_addr
        let host = UInt32(bigEndian: value.s_addr)
        // 100.64.0.0/10
        guard host & 0xFFC0_0000 == 0x6440_0000,
          inet_ntop(AF_INET, &value, &buffer, socklen_t(buffer.count)) != nil
        else { return nil }
        return String(cString: buffer)
      }
    case AF_INET6:
      return address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
        var value = $0.pointee.sin6_addr
        let prefix: [UInt8] = [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]
        let matches = withUnsafeBytes(of: &value) {
          Array($0.prefix(6)) == prefix
        }
        guard matches,
          inet_ntop(AF_INET6, &value, &buffer, socklen_t(buffer.count)) != nil
        else { return nil }
        return String(cString: buffer)
      }
    default: return nil
    }
  }
}
