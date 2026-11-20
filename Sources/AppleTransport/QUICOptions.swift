import Foundation
import Network
import ScreenProtocol
import Security
import SessionCore
import Synchronization

/// Network framework QUIC/TLS parameters for RST/1 (spec §5.3, §7.1).
///
/// Both sides use TLS 1.3 only, ALPN `rst/1`, no session tickets, no
/// resumption, and no fast open, so no attach, input, resize, or close
/// can ever travel as 0-RTT early data. QUIC DATAGRAM stays disabled.
enum QUICOptions {
  /// Per-stream receive window for snapshot streams. Flow control, not
  /// a size bound; the accumulator enforces sizes.
  static let snapshotStreamWindow = 1 << 20
  /// Server snapshot streams the client allows at once. QUIC stream
  /// credit is cumulative; the client raises it as streams are released.
  static let concurrentSnapshotStreams = 4

  static func harden(_ options: sec_protocol_options_t) {
    sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
    sec_protocol_options_set_max_tls_protocol_version(options, .TLSv13)
    sec_protocol_options_set_tls_tickets_enabled(options, false)
    sec_protocol_options_set_tls_resumption_enabled(options, false)
    sec_protocol_options_set_tls_false_start_enabled(options, false)
    sec_protocol_options_set_tls_renegotiation_enabled(options, false)
  }

  static func parameters(
    _ quic: NWProtocolQUIC.Options,
    migration: Bool = false
  ) -> NWParameters {
    let parameters = NWParameters(quic: quic)
    parameters.allowFastOpen = false
    parameters.includePeerToPeer = false
    // QUIC connection migration (RFC 9000 §9) is opt-in in Network
    // framework: `.handover` lets a client move to a new path (Wi-Fi to
    // cellular) without a new handshake (spec §9). Only clients migrate.
    if migration { parameters.multipathServiceType = .handover }
    return parameters
  }

  /// Flow-control and idle settings this side configured, for lifecycle
  /// diagnostics. Built from the values set here because Network traps when
  /// reading a limit that was never set.
  static func describe(
    role: String,
    idleTimeout: Duration,
    initialMaxData: Int? = nil
  ) -> String {
    let limits =
      role == "client"
      ? "initialMaxStreamsUni=\(concurrentSnapshotStreams),"
        + "initialMaxStreamDataUni=\(snapshotStreamWindow)"
      : "initialMaxStreamsBidi=4"
    return "role=\(role),idleTimeout=\(idleTimeout),\(limits),"
      + "initialMaxData=\(initialMaxData.map(String.init) ?? "default")"
  }

  /// Options for a server-initiated unidirectional stream within a group.
  static func unidirectionalStream() -> NWProtocolQUIC.Options {
    let options = NWProtocolQUIC.Options()
    options.direction = .unidirectional
    return options
  }

  static func idleMilliseconds(_ duration: Duration) throws -> Int {
    guard duration >= .zero, duration <= .milliseconds(Int64(UInt32.max)) else {
      throw RSTTransportError.handshake("invalid idle timeout")
    }
    let (seconds, attoseconds) = duration.components
    let unit: Int64 = 1_000_000_000_000_000
    // Round up so a positive fraction cannot become zero (idle disabled).
    return Int(
      seconds * 1000 + attoseconds / unit + (attoseconds % unit == 0 ? 0 : 1)
    )
  }

  /// Client options whose TLS verify block accepts only the pinned leaf.
  ///
  /// The verify block replaces system trust: no `SecTrustEvaluate`, no
  /// anchors, fail closed on any error. The TLS stack still enforces TLS 1.3
  /// CertificateVerify (proof of possession of the pinned key).
  static func client(
    pin: CertificatePin,
    alpn: String,
    idleTimeout: Duration,
    verdict: PinVerdict,
    queue: DispatchQueue
  ) throws -> NWProtocolQUIC.Options {
    let milliseconds = try idleMilliseconds(idleTimeout)
    let quic = NWProtocolQUIC.Options(alpn: [alpn])
    quic.idleTimeout = milliseconds
    // Concurrent snapshot streams the server may open; `MAX_STREAMS`
    // credit returns as streams finish.
    quic.initialMaxStreamsUnidirectional = concurrentSnapshotStreams
    quic.initialMaxStreamDataUnidirectional = snapshotStreamWindow
    let security = quic.securityProtocolOptions
    harden(security)
    sec_protocol_options_set_verify_block(
      security,
      { _, trust, complete in
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
        let chain =
          SecTrustCopyCertificateChain(secTrust) as? [SecCertificate] ?? []
        let leaf = chain.first.map { SecCertificateCopyData($0) as Data }
        do throws(CertificatePinError) {
          try pin.validate(leafDER: leaf)
          verdict.record(nil)
          complete(true)
        } catch {
          verdict.record(error)
          complete(false)
        }
      },
      queue
    )
    return quic
  }

  #if os(macOS)
  static func server(
    identity: sec_identity_t,
    alpn: String,
    idleTimeout: Duration
  ) throws -> NWProtocolQUIC.Options {
    let milliseconds = try idleMilliseconds(idleTimeout)
    let quic = NWProtocolQUIC.Options(alpn: [alpn])
    quic.idleTimeout = milliseconds
    // RST/1 needs one client bidirectional stream (control), but Network's
    // multiplex group consumes stream 0, so control is typically ID 4. The
    // connection rejects any bidirectional stream after the first.
    quic.initialMaxStreamsBidirectional = 4
    let security = quic.securityProtocolOptions
    harden(security)
    sec_protocol_options_set_local_identity(security, identity)
    sec_protocol_options_set_peer_authentication_required(security, false)
    return quic
  }
  #endif
}

/// Outcome of the client's pin check, recorded by the verify block so a
/// failed handshake reports `pinMismatch` and a "ready" group whose verify
/// block never approved the peer is still refused.
final class PinVerdict: Sendable {
  private enum Value {
    case pending, accepted
    case rejected(CertificatePinError)
  }
  private let value = Mutex(Value.pending)
  private let onReject: @Sendable () -> Void

  /// `onReject` runs on the first rejection, so the connector can fail
  /// immediately instead of waiting for Network to give up.
  init(onReject: @escaping @Sendable () -> Void = {}) {
    self.onReject = onReject
  }

  func record(_ error: CertificatePinError?) {
    let rejectedNow = value.withLock { v -> Bool in
      // A rejection is final.
      if case .rejected = v { return false }
      v = error.map { .rejected($0) } ?? .accepted
      return error != nil
    }
    if rejectedNow { onReject() }
  }

  var accepted: Bool {
    value.withLock { if case .accepted = $0 { true } else { false } }
  }

  var rejection: CertificatePinError? {
    value.withLock { if case let .rejected(e) = $0 { e } else { nil } }
  }
}
