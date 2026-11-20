#if os(macOS)
import Darwin
import Foundation
import ScreenProtocol
import SessionCore

/// Bootstrap glue (spec §5.1): the agent-side envelope handler for the
/// control socket and the `bootstrap --stdio` client path.
public struct BootstrapService: Sendable {
  public let registry: SessionRegistry

  public init(registry: SessionRegistry) { self.registry = registry }

  /// Agent side: one request envelope in, one response envelope out.
  /// Malformed lengths and unsupported versions are rejected before any
  /// session is created.
  public func respond(toEnvelope bytes: [UInt8]) async -> [UInt8] {
    let response: BootstrapResponse
    switch Self.decodeRequest(bytes) {
    case let .success(request): response = await registry.handle(request)
    case let .failure(code): response = .failure(code)
    }
    return Self.envelope(response)
  }

  public static func decodeRequest(
    _ bytes: [UInt8]
  ) -> Result<BootstrapRequest, BootstrapErrorCode> {
    let request: BootstrapRequest
    do {
      request = try BootstrapEnvelope.decode(BootstrapRequest.self, from: bytes)
    } catch { return .failure(.malformed) }
    do { try request.validate() } catch {
      switch error {
      case .unsupportedProtocol, .tooManyProtocols:
        return .failure(.unsupportedVersion)
      case .missingSession, .invalidGrid, .missingAttention:
        return .failure(.malformed)
      }
    }
    return .success(request)
  }

  static func envelope(_ response: BootstrapResponse) -> [UInt8] {
    if let bytes = try? BootstrapEnvelope.encode(response) { return bytes }
    do {
      return try BootstrapEnvelope.encode(
        BootstrapResponse.failure(.internalError)
      )
    } catch { preconditionFailure("Cannot encode bootstrap failure: \(error)") }
  }

  /// `bootstrap --stdio` core: validates one request envelope, forwards
  /// it to the agent's control socket and returns only the response
  /// envelope (a failure envelope when anything is wrong). Never creates
  /// anything for an invalid request.
  public static func forward(
    envelope bytes: [UInt8],
    socketPath: String,
    timeout: Duration = .seconds(10)
  ) -> [UInt8] {
    let request: BootstrapRequest
    switch decodeRequest(bytes) {
    case let .success(value): request = value
    case let .failure(code): return envelope(.failure(code))
    }
    guard let canonical = try? BootstrapEnvelope.encode(request) else {
      return envelope(.failure(.malformed))
    }
    let reply: [UInt8]
    do {
      reply = try ControlSocketClient.exchange(
        path: socketPath,
        envelope: canonical,
        timeout: timeout
      )
    } catch { return envelope(.failure(.agentUnavailable)) }
    // Forward only a well-formed response.
    guard
      (try? BootstrapEnvelope.decode(BootstrapResponse.self, from: reply))
        != nil
    else { return envelope(.failure(.agentUnavailable)) }
    return reply
  }

  /// Reads exactly one bounded envelope from `fd` (stdin). A length over
  /// the limit is rejected before the body is read.
  public static func readEnvelope(
    from fd: Int32
  ) throws(FramingError) -> [UInt8] { try TerminalHost.readEnvelope(fd) }
}
#endif
