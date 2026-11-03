import SwiftMuxProtocol

/// Explicit topology selection. Reject mixtures before any legacy registration
/// command can execute. Normal macOS launch arguments keep their existing path.
struct GatewayLaunchOptions {
  static func service(arguments: [String]) throws -> String? {
    guard arguments.contains("--gateway-service") else { return nil }
    guard arguments.count == 2, arguments[0] == "--gateway-service" else {
      throw MuxError(.invalidRequest, "usage: swiftty --gateway-service NAME")
    }
    let value = arguments[1]
    guard !value.isEmpty, value.utf8.count <= 255,
      value.utf8.allSatisfy({
        (48 ... 57).contains($0) || (65 ... 90).contains($0)
          || (97 ... 122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
      })
    else { throw MuxError(.invalidRequest, "invalid gateway service name") }
    return value
  }
}
