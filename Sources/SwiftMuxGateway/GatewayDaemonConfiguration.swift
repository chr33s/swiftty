import SwiftMuxProtocol

/// Fixed launchd arguments, never frontend-controlled service names or signing
/// expressions. The guardian identifier is a literal within the verified team.
package struct GatewayDaemonConfiguration: Sendable {
  package let guardianService: String
  package let guardianIdentifier: String
  package let controlService: String

  package init(arguments: [String]) throws {
    guard arguments.count == 6 else {
      throw MuxError(
        .invalidRequest,
        "expected three gateway installation options"
      )
    }
    var options: [String: String] = [:]
    for index in stride(from: 0, to: arguments.count, by: 2) {
      let key = arguments[index]
      guard
        ["--guardian-service", "--guardian-identifier", "--control-service"]
          .contains(key), options[key] == nil,
        Self.identifier(arguments[index + 1])
      else {
        throw MuxError(.invalidRequest, "invalid gateway installation option")
      }
      options[key] = arguments[index + 1]
    }
    guard let guardian = options["--guardian-service"],
      let identifier = options["--guardian-identifier"],
      let control = options["--control-service"], guardian != control
    else {
      throw MuxError(.invalidRequest, "gateway service roles must be distinct")
    }
    guardianService = guardian
    guardianIdentifier = identifier
    controlService = control
  }

  package func guardianRequirement(teamRequirement: String) -> String {
    "(\(teamRequirement)) and identifier \"\(guardianIdentifier)\""
  }

  package static func identifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 255
      && value.utf8.allSatisfy {
        (48 ... 57).contains($0) || (65 ... 90).contains($0)
          || (97 ... 122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
      }
  }
}
