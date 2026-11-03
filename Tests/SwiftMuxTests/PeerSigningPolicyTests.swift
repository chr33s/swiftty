import Foundation
import Security
import Testing

@testable import SwiftMuxGuardian
@testable import SwiftMuxService

struct PeerSigningPolicyTests {
  enum Stage: String, CaseIterable, Sendable {
    case current, validity, `static`, information

    var operation: String {
      switch self {
      case .current: "SecCodeCopySelf"
      case .validity: "SecCodeCheckValidity"
      case .static: "SecCodeCopyStaticCode"
      case .information: "SecCodeCopySigningInformation"
      }
    }
  }

  @Test(arguments: Stage.allCases)
  func lookupFailuresNeverEnableDevelopmentAccess(_ stage: Stage) throws {
    var api = PeerSigningPolicy.SecurityCalls()
    switch stage {
    case .current: api.copySelf = { _ in errSecNotAvailable }
    case .validity: api.validate = { _ in errSecNotAvailable }
    case .static: api.copyStatic = { _, _ in errSecNotAvailable }
    case .information: api.signingInformation = { _, _ in errSecNotAvailable }
    }
    #expect(
      throws: PeerSigningPolicy.Failure.lookup(
        stage.operation,
        errSecNotAvailable
      )
    ) { try PeerSigningPolicy.requirement(using: api) }
  }

  @Test(arguments: [Stage.current, .static, .information])
  func missingSuccessfulResultsAreErrors(_ stage: Stage) throws {
    var api = PeerSigningPolicy.SecurityCalls()
    let field: String
    switch stage {
    case .current:
      api.copySelf = { _ in errSecSuccess }
      field = "code reference"
    case .static:
      api.copyStatic = { _, _ in errSecSuccess }
      field = "static code reference"
    case .information:
      api.signingInformation = { _, _ in errSecSuccess }
      field = "information"
    case .validity: return
    }
    #expect(throws: PeerSigningPolicy.Failure.incomplete(field)) {
      try PeerSigningPolicy.requirement(using: api)
    }
  }

  @Test
  func explicitUnsignedValidityAllowsDevelopmentAccess() throws {
    var api = PeerSigningPolicy.SecurityCalls()
    api.validate = { _ in errSecCSUnsigned }
    api.copyStatic = { _, _ in
      Issue.record("unsigned identity must not depend on later metadata")
      return errSecNotAvailable
    }
    #expect(try PeerSigningPolicy.requirement(using: api) == nil)
  }

  @Test(arguments: [Stage.current, .static, .information])
  func unsignedErrorsOutsideValidityCannotWeakenPolicy(_ stage: Stage) throws {
    var api = PeerSigningPolicy.SecurityCalls()
    switch stage {
    case .current: api.copySelf = { _ in errSecCSUnsigned }
    case .static: api.copyStatic = { _, _ in errSecCSUnsigned }
    case .information: api.signingInformation = { _, _ in errSecCSUnsigned }
    case .validity: return
    }
    #expect(
      throws: PeerSigningPolicy.Failure.lookup(
        stage.operation,
        errSecCSUnsigned
      )
    ) { try PeerSigningPolicy.requirement(using: api) }
  }

  @Test
  func invalidCodeNeverReachesMetadataFallback() throws {
    var api = PeerSigningPolicy.SecurityCalls()
    api.validate = { _ in errSecCSSignatureFailed }
    api.signingInformation = { _, _ in
      Issue.record("invalid code must not supply partial metadata")
      return errSecSuccess
    }
    #expect(
      throws: PeerSigningPolicy.Failure.lookup(
        "SecCodeCheckValidity",
        errSecCSSignatureFailed
      )
    ) { try PeerSigningPolicy.requirement(using: api) }
  }

  private var signed: [String: Any] {
    [
      kSecCodeInfoIdentifier as String: "owned.agent",
      kSecCodeInfoFlags as String: NSNumber(value: 0),
      kSecCodeInfoTeamIdentifier as String: "ABCDEFGHIJ",
    ]
  }

  @Test(arguments: ["identifier", "flags", "teamid"])
  func incompleteSignedMetadataNeverEnablesDevelopmentAccess(
    _ field: String
  ) throws {
    var information = signed
    let key: String
    switch field {
    case "identifier": key = kSecCodeInfoIdentifier as String
    case "flags": key = kSecCodeInfoFlags as String
    default: key = kSecCodeInfoTeamIdentifier as String
    }
    information.removeValue(forKey: key)
    #expect(throws: PeerSigningPolicy.Failure.self) {
      try PeerSigningPolicy.requirement(from: information)
    }
  }

  @Test(arguments: 0 ..< 8)
  func malformedSignedMetadataIsRejected(_ scenario: Int) throws {
    var information = signed
    let values: [(String, Any)] = [
      (kSecCodeInfoIdentifier as String, ""),
      (kSecCodeInfoIdentifier as String, 7),
      (kSecCodeInfoFlags as String, true), (kSecCodeInfoFlags as String, -1),
      (kSecCodeInfoFlags as String, UInt64(UInt32.max) + 1),
      (kSecCodeInfoFlags as String, 2.5),
      (kSecCodeInfoTeamIdentifier as String, ""),
      (kSecCodeInfoTeamIdentifier as String, 7),
    ]
    let (key, value) = values[scenario]
    information[key] = value
    #expect(throws: PeerSigningPolicy.Failure.self) {
      try PeerSigningPolicy.requirement(from: information)
    }
  }

  @Test
  func validAdHocMetadataAllowsDevelopmentAccess() throws {
    var information = signed
    information[kSecCodeInfoFlags as String] = NSNumber(
      value: SecCodeSignatureFlags.adhoc.rawValue
    )
    information.removeValue(forKey: kSecCodeInfoTeamIdentifier as String)
    #expect(try PeerSigningPolicy.requirement(from: information) == nil)
  }

  @Test
  func teamSignedMetadataRequiresItsLiteralTeam() throws {
    #expect(
      try PeerSigningPolicy.requirement(from: signed)
        == "anchor apple generic and certificate leaf[subject.OU] = \"ABCDEFGHIJ\""
    )
    var information = signed
    information[kSecCodeInfoTeamIdentifier as String] = "A\" or true or \"B"
    let result = try PeerSigningPolicy.requirement(from: information)
    let requirement = try #require(result)
    #expect(requirement.hasSuffix("\"A\\\" or true or \\\"B\""))
    var parsed: SecRequirement?
    #expect(
      SecRequirementCreateWithString(requirement as CFString, [], &parsed)
        == errSecSuccess
    )
    var code: SecCode?
    #expect(SecCodeCopySelf([], &code) == errSecSuccess)
    let current = try #require(code)
    let parsedRequirement = try #require(parsed)
    // Embedded syntax cannot turn this requirement into an unconditional match.
    #expect(
      SecCodeCheckValidity(current, [], parsedRequirement) != errSecSuccess
    )
  }

  @Test
  func unrepresentableRequirementDataIsRejected() throws {
    var information = signed
    information[kSecCodeInfoTeamIdentifier as String] = "A\\B"
    #expect(throws: PeerSigningPolicy.Failure.self) {
      try PeerSigningPolicy.requirement(from: information)
    }
  }
}
