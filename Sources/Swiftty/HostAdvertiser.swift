import Foundation
import HostConnection
import dnssd

/// Registers the Mac's existing SSH endpoint as `_swiftty._tcp` in the
/// local domain while the Connect a Device panel asks for it
/// (spec.connection-setup.md D3). It advertises; it listens on nothing,
/// starts no SSH or pairing server and requests no NAT mapping.
@MainActor
protocol ServiceRegistering: AnyObject {
  /// Registers `name` for the SSH `port`; `update` reports the outcome.
  func register(
    name: String,
    port: UInt16,
    txt: [UInt8],
    update: @escaping @MainActor (HostAdvertiser.State) -> Void
  )
  /// Withdraws the registration; no update follows.
  func cancel()
}

/// The foreground app's one registration. Withdrawing it never touches
/// the agent, its sessions or existing attachments.
@MainActor
final class HostAdvertiser {
  enum State: Equatable {
    case stopped
    case registering
    /// The system's final name (it may rename on a collision).
    case advertising(name: String, port: UInt16)
    /// The system reported a Local Network policy denial.
    case denied
    case failed(Int32)
  }

  private(set) var state: State = .stopped
  var onChange: (@MainActor (State) -> Void)?
  private let registrar: any ServiceRegistering
  private var generation = 0

  init(registrar: (any ServiceRegistering)? = nil) {
    self.registrar = registrar ?? DNSSDRegistrar()
  }

  /// Advertises `port`, the Mac's existing SSH port, under a sanitized
  /// display name. Replaces any current registration.
  func start(name: String, port: UInt16) {
    stop()
    guard port != 0 else { return }
    generation += 1
    let generation = generation
    let display = HostDiscovery.sanitizedName(name)
    set(.registering)
    registrar.register(
      name: display.isEmpty ? "Mac" : display,
      port: port,
      txt: HostDiscovery.txtRecord(HostDiscovery.advertisedTXT)
    ) { [weak self] state in
      guard let self, generation == self.generation else { return }
      self.set(state)
    }
  }

  func stop() {
    generation += 1
    registrar.cancel()
    set(.stopped)
  }

  private func set(_ next: State) {
    guard next != state else { return }
    state = next
    onChange?(next)
  }
}

/// `DNSServiceRegister` for an existing service endpoint, on the main
/// queue, restricted to the `local.` domain.
@MainActor
final class DNSSDRegistrar: ServiceRegistering {
  /// Sendable: none: immutable after init. Created, scheduled on, and
  /// deallocated by the main-actor registrar on the main queue only; the
  /// `DNSServiceRef` lives until `cancel` or the isolated `deinit`.
  private struct Reference: @unchecked Sendable { let ref: DNSServiceRef }
  private var reference: Reference?
  private var box: Unmanaged<CallbackBox>?

  /// Carries the update closure through the C callback context.
  private final class CallbackBox {
    let update: @MainActor (HostAdvertiser.State) -> Void
    let port: UInt16
    init(
      update: @escaping @MainActor (HostAdvertiser.State) -> Void,
      port: UInt16
    ) {
      self.update = update
      self.port = port
    }
  }

  func register(
    name: String,
    port: UInt16,
    txt: [UInt8],
    update: @escaping @MainActor (HostAdvertiser.State) -> Void
  ) {
    cancel()
    let box = Unmanaged.passRetained(CallbackBox(update: update, port: port))
    var ref: DNSServiceRef?
    let error = txt.withUnsafeBytes { bytes in
      DNSServiceRegister(
        &ref,
        0,
        0,
        name,
        HostDiscovery.serviceType,
        HostDiscovery.domain,
        nil,
        port.bigEndian,
        UInt16(bytes.count),
        bytes.baseAddress,
        { _, _, error, name, _, _, context in
          guard let context else { return }
          let box = Unmanaged<CallbackBox>.fromOpaque(context)
            .takeUnretainedValue()
          let registered = name.map { String(cString: $0) } ?? ""
          let state: HostAdvertiser.State =
            switch Int(error) {
            case Int(kDNSServiceErr_NoError):
              .advertising(name: registered, port: box.port)
            case Int(kDNSServiceErr_PolicyDenied): .denied
            default: .failed(error)
            }
          MainActor.assumeIsolated { box.update(state) }
        },
        box.toOpaque()
      )
    }
    guard error == kDNSServiceErr_NoError, let ref else {
      box.release()
      update(
        Int(error) == Int(kDNSServiceErr_PolicyDenied)
          ? .denied : .failed(error)
      )
      return
    }
    reference = Reference(ref: ref)
    self.box = box
    DNSServiceSetDispatchQueue(ref, .main)
  }

  func cancel() {
    if let reference { DNSServiceRefDeallocate(reference.ref) }
    reference = nil
    box?.release()
    box = nil
  }

  isolated deinit { cancel() }
}
