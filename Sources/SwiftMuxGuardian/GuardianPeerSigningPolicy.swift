#if os(macOS)
import Foundation
import Security

/// Derives the local peer requirement from a verified process identity.
/// Same-user-only development access requires confirmed unsigned/ad-hoc code.
public enum GuardianPeerSigningPolicy {
  public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
    case lookup(String, OSStatus)
    case incomplete(String)

    public var description: String {
      switch self {
      case let .lookup(operation, status):
        "\(operation) failed (OSStatus \(status))"
      case let .incomplete(field): "missing or invalid signing \(field)"
      }
    }
  }

  public static func requirementForCurrentProcess() throws -> String? {
    try requirement(using: SecurityCalls())
  }

  /// Keeps OS failures and successful-but-missing values independently testable.
  struct SecurityCalls {
    var copySelf: (inout SecCode?) -> OSStatus = { SecCodeCopySelf([], &$0) }
    var validate: (SecCode) -> OSStatus = { SecCodeCheckValidity($0, [], nil) }
    var copyStatic: (SecCode, inout SecStaticCode?) -> OSStatus = {
      SecCodeCopyStaticCode($0, [], &$1)
    }
    var signingInformation: (SecStaticCode, inout CFDictionary?) -> OSStatus = {
      SecCodeCopySigningInformation(
        $0,
        SecCSFlags(rawValue: kSecCSSigningInformation),
        &$1
      )
    }
  }

  static func requirement(using api: SecurityCalls) throws -> String? {
    var code: SecCode?
    try check(api.copySelf(&code), operation: "SecCodeCopySelf")
    guard let code else { throw Failure.incomplete("code reference") }

    // CopySigningInformation may return partial corrupt metadata. Establish
    // validity first; only its explicit unsigned result permits that fallback.
    let validity = api.validate(code)
    if validity == errSecCSUnsigned { return nil }
    try check(validity, operation: "SecCodeCheckValidity")

    var staticCode: SecStaticCode?
    try check(
      api.copyStatic(code, &staticCode),
      operation: "SecCodeCopyStaticCode"
    )
    guard let staticCode else {
      throw Failure.incomplete("static code reference")
    }
    var information: CFDictionary?
    try check(
      api.signingInformation(staticCode, &information),
      operation: "SecCodeCopySigningInformation"
    )
    guard let information = information as? [String: Any] else {
      throw Failure.incomplete("information")
    }
    return try requirement(from: information)
  }

  /// Called only after successful validity and metadata lookup.
  static func requirement(from information: [String: Any]) throws -> String? {
    guard
      let identifier = information[kSecCodeInfoIdentifier as String] as? String,
      !identifier.isEmpty
    else { throw Failure.incomplete("identifier") }
    guard let number = information[kSecCodeInfoFlags as String] as? NSNumber,
      CFGetTypeID(number) == CFNumberGetTypeID(),
      let flags = UInt32(exactly: number.int64Value),
      number.doubleValue == Double(flags)
    else { throw Failure.incomplete("flags") }
    if flags & SecCodeSignatureFlags.adhoc.rawValue != 0 { return nil }
    guard
      let team = information[kSecCodeInfoTeamIdentifier as String] as? String,
      !team.isEmpty
    else { throw Failure.incomplete("team identifier") }

    // Treat metadata as a literal, never as requirement-language syntax.
    let literal = team.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    let requirement =
      "anchor apple generic and certificate leaf[subject.OU] = \"\(literal)\""
    var parsed: SecRequirement?
    try check(
      SecRequirementCreateWithString(requirement as CFString, [], &parsed),
      operation: "SecRequirementCreateWithString"
    )
    guard parsed != nil else { throw Failure.incomplete("peer requirement") }
    return requirement
  }

  private static func check(_ status: OSStatus, operation: String) throws {
    guard status == errSecSuccess else {
      throw Failure.lookup(operation, status)
    }
  }
}
#endif
