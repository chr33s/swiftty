import RoamingKit
import Foundation
import AppleTransport
import ScreenProtocol

/// Connects to the endpoint in an SSH-delivered grant over QUIC, trusting
/// only the exact certificate the grant carries and, when present, its
/// SPKI pin (spec §5.2; spec.inbox.md §1.8). A mismatch fails the TLS
/// handshake, so the caller's `Attach` (carrying the token) is never sent.
///
/// With `fallbackHost` (the host SSH reached), that host is raced against
/// the advertised one after a short head start: an advertised LAN address
/// is unroutable over cellular or a VPN such as Tailscale, while the SSH
/// host is known to reach the Mac. The pin, not the address, authenticates
/// the server, so either path is equally trusted.
public struct QUICGrantConnector: RSTConnector {
  public var connector: QUICRSTConnector
  public var fallbackHost: String?
  /// How long the advertised host runs alone before the fallback starts.
  public var fallbackDelay: Duration

  public init(
    connector: QUICRSTConnector = QUICRSTConnector(),
    fallbackHost: String? = nil,
    fallbackDelay: Duration = .milliseconds(300)
  ) {
    self.connector = connector
    self.fallbackHost = fallbackHost
    self.fallbackDelay = fallbackDelay
  }

  public func connect(
    to grant: BootstrapGrant
  ) async throws -> any RSTConnection {
    let pin = try CertificatePin(
      certificateDER: grant.serverCertificateDER,
      sha256: grant.serverCertificateSHA256,
      spkiSHA256: grant.serverSPKISHA256
    )
    let advertised = grant.endpoint.host
    guard let fallback = fallbackHost, !fallback.isEmpty,
      Self.normalized(fallback) != Self.normalized(advertised)
    else {
      return try await connector.connect(
        host: advertised,
        port: grant.endpoint.port,
        pin: pin,
        limits: grant.limits
      )
    }
    return try await race(
      [(advertised, .zero), (fallback, fallbackDelay)],
      port: grant.endpoint.port,
      pin: pin,
      limits: grant.limits
    )
  }

  private enum Outcome: Sendable {
    case connected(any RSTConnection)
    case failed(index: Int, any Error)
  }

  /// First handshake to complete wins; later winners are closed before any
  /// application byte. When all fail, a pin mismatch is reported first,
  /// then the advertised host's error.
  private func race(
    _ candidates: [(host: String, delay: Duration)],
    port: UInt16,
    pin: CertificatePin,
    limits: NegotiatedLimits
  ) async throws -> any RSTConnection {
    let connector = connector
    let result = await withTaskGroup(
      of: Outcome.self,
      returning: Result<any RSTConnection, any Error>.self
    ) { group in
      for (index, candidate) in candidates.enumerated() {
        group.addTask {
          do {
            if candidate.delay > .zero {
              try await Task.sleep(for: candidate.delay)
            }
            return .connected(
              try await connector.connect(
                host: candidate.host,
                port: port,
                pin: pin,
                limits: limits
              )
            )
          } catch { return .failed(index: index, error) }
        }
      }
      var errors: [Int: any Error] = [:]
      var winner: (any RSTConnection)?
      for await outcome in group {
        switch outcome {
        case let .connected(connection):
          if winner == nil {
            winner = connection
            group.cancelAll()
          } else {
            connection.close()
          }
        case let .failed(index, error): errors[index] = error
        }
      }
      if let winner { return .success(winner) }
      if Task.isCancelled { return .failure(RSTTransportError.canceled) }
      if errors.values.contains(where: {
        ($0 as? RSTTransportError) == .pinMismatch
      }) {
        return .failure(RSTTransportError.pinMismatch)
      }
      return .failure(errors[0] ?? RSTTransportError.canceled)
    }
    return try result.get()
  }

  private static func normalized(_ host: String) -> String {
    host.trimmingCharacters(in: ["[", "]"]).lowercased()
  }
}
