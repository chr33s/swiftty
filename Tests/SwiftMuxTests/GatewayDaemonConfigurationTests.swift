import SwiftMuxGateway
import SwiftMuxProtocol
import Testing

@Suite
struct GatewayDaemonConfigurationTests {
  private var arguments: [String] {
    [
      "--guardian-service", "test.guardian.control", "--guardian-identifier",
      "test.guardian.app", "--control-service", "test.gateway.control",
    ]
  }

  @Test
  func explicitRolesBuildALiteralGuardianRequirement() throws {
    let value = try GatewayDaemonConfiguration(arguments: arguments)
    #expect(value.guardianService == "test.guardian.control")
    #expect(value.controlService == "test.gateway.control")
    #expect(
      value.guardianRequirement(teamRequirement: "anchor apple generic")
        == "(anchor apple generic) and identifier \"test.guardian.app\""
    )
    let reordered = Array(arguments[4 ... 5]) + Array(arguments[0 ... 3])
    #expect(
      try GatewayDaemonConfiguration(arguments: reordered).guardianIdentifier
        == value.guardianIdentifier
    )
  }

  @Test(arguments: [
    "missing", "extra", "unknown", "duplicate", "sameService", "injection",
    "nul", "empty", "oversized", "unicode",
  ])
  func ambiguousOrUnsafeLaunchArgumentsAreRejected(mode: String) {
    var values = arguments
    switch mode {
    case "missing": values.removeLast()
    case "extra": values += ["--guardian-service", "other"]
    case "unknown": values[0] = "--unknown"
    case "duplicate": values[2] = "--guardian-service"
    case "sameService": values[5] = values[1]
    case "injection": values[3] = "test\" or true or identifier \"x"
    case "nul": values[1] = "test\u{0}service"
    case "empty": values[3] = ""
    case "oversized": values[3] = String(repeating: "a", count: 256)
    default: values[3] = "tést.guardian"
    }
    #expect(throws: MuxError.self) {
      try GatewayDaemonConfiguration(arguments: values)
    }
  }
}
