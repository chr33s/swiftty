#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Hard bounds shared by every protocol built on this codec.
package enum WireLimits {
  package static let frameBytes = 1 << 20
  package static let identifierBytes = 64
  package static let pathBytes = 4096
  static let nesting = 8
  static let values = 16384
}

package enum Outcome: String, Sendable {
  case invalidRequest = "invalid_request"
  case unsupportedProtocol = "unsupported_protocol"
  case unsupportedOperation = "unsupported_operation"
  case policyDenied = "policy_denied"
  case unsupportedEnforcement = "unsupported_enforcement"
  case requestConflict = "request_conflict"
  case budgetExhausted = "budget_exhausted"
  case unknownContext = "unknown_context"
  /// A client could not reach the service; it ran nothing instead.
  case serviceUnavailable = "service_unavailable"
  /// The runner was not handed an execution context; it ran nothing.
  case noContext = "no_context"
  case runtimeFailure = "runtime_failure"
  case executionUnknown = "execution_unknown"
  /// A pure description of a request; nothing ran.
  case previewed
  // Reserved for backends and runners that can run a workload.
  case completed, timeout, cancelled
  case outputExhausted = "output_exhausted"
  case cleanupIncomplete = "cleanup_incomplete"
}

/// A request that was not accepted, with the ID to echo when one was readable.
package struct Rejected: Error, Equatable {
  package let requestID: String?
  package let outcome: Outcome
  package let reason: String

  package init(requestID: String?, outcome: Outcome, reason: String) {
    self.requestID = requestID
    self.outcome = outcome
    self.reason = reason
  }
}

/// Why a field was refused, before the request ID is attached.
package struct Rejection: Error {
  package let outcome: Outcome
  package let reason: String

  package init(outcome: Outcome, reason: String) {
    self.outcome = outcome
    self.reason = reason
  }

  package static func invalid(_ reason: String) -> Rejection {
    Rejection(outcome: .invalidRequest, reason: reason)
  }
}

/// The members of one JSON object. Every member must be consumed, so a field
/// such as `approved` or `effectivePolicy` is an error, not ignored input.
package struct Fields {
  package let context: String
  var values: [String: JSONValue]

  package init(_ value: JSONValue?, _ context: String) throws {
    guard case .object(let values)? = value else {
      throw Rejection.invalid("\(context): expected an object")
    }
    self.context = context
    self.values = values
  }

  package mutating func take(_ key: String) -> JSONValue? {
    values.removeValue(forKey: key)
  }

  package func name(_ key: String) -> String { "\(context).\(key)" }

  package mutating func string(_ key: String) throws -> String {
    guard case .string(let text)? = take(key) else {
      throw Rejection.invalid("\(name(key)): expected a string")
    }
    return text
  }

  package mutating func identifier(_ key: String) throws -> String {
    guard case .string(let text)? = take(key), Wire.isIdentifier(text) else {
      throw Rejection.invalid(
        "\(name(key)): expected 1 to \(WireLimits.identifierBytes) characters from A-Z a-z 0-9 . _ -"
      )
    }
    return text
  }

  package mutating func positive(_ key: String) throws -> Int? {
    guard let value = take(key) else { return nil }
    guard case .integer(let number) = value, number > 0,
      number <= Int64(Int32.max)
    else {
      throw Rejection.invalid("\(name(key)): expected a positive integer")
    }
    return Int(number)
  }

  package func finish() throws {
    guard let key = values.keys.sorted().first else { return }
    throw Rejection.invalid("\(context): unknown field \"\(key.prefix(32))\"")
  }
}

package enum Wire {
  package static func isIdentifier(_ text: String) -> Bool {
    let bytes = Array(text.utf8)
    return (1 ... WireLimits.identifierBytes).contains(bytes.count)
      && bytes.allSatisfy {
        (48 ... 57).contains($0) || (65 ... 90).contains($0)
          || (97 ... 122).contains($0) || [45, 46, 95].contains($0)
      }
  }

  /// Reads the envelope shared by every request: one bounded JSON object with
  /// `protocol` and `requestId`. `body` consumes the remaining members.
  package static func decode<Request>(
    _ frame: [UInt8],
    version: String,
    body: (inout Fields, _ requestID: String) throws -> Request
  ) throws -> Request {
    guard frame.count <= WireLimits.frameBytes else {
      throw Rejected(
        requestID: nil,
        outcome: .invalidRequest,
        reason: "frame exceeds \(WireLimits.frameBytes) bytes"
      )
    }
    var requestID: String?
    do {
      var fields = try Fields(try JSONValue.parse(frame), "request")
      if case .string(let text)? = fields.values["requestId"],
        isIdentifier(text)
      {
        requestID = text
      }
      guard case .string(let named)? = fields.take("protocol") else {
        throw Rejection.invalid("request.protocol: expected a string")
      }
      guard named == version else {
        throw Rejection(
          outcome: .unsupportedProtocol,
          reason: "this endpoint speaks \(version)"
        )
      }
      let request = try body(&fields, try fields.identifier("requestId"))
      try fields.finish()
      return request
    } catch let failure as JSONValue.Failure {
      throw Rejected(
        requestID: nil,
        outcome: .invalidRequest,
        reason: failure.message
      )
    } catch let rejection as Rejection {
      throw Rejected(
        requestID: requestID,
        outcome: rejection.outcome,
        reason: rejection.reason
      )
    }
  }

  /// A UTF-8 string, or `{"base64": "..."}` for other bytes, without NUL. The
  /// budget is checked against the encoded length before anything is decoded.
  package static func bytes(
    _ value: JSONValue,
    _ name: String,
    remaining: inout Int,
    limit: Int
  ) throws -> [UInt8] {
    let exceeded = Rejection.invalid("\(name): exceeds \(limit) bytes in total")
    let bytes: [UInt8]
    switch value {
    case .string(let text): bytes = Array(text.utf8)
    case .object(let object):
      guard object.count == 1, case .string(let text)? = object["base64"] else {
        throw Rejection.invalid(
          "\(name): expected a string or {\"base64\": string}"
        )
      }
      guard text.utf8.count / 4 * 3 <= remaining + 2 else { throw exceeded }
      guard let decoded = Base64.decode(text) else {
        throw Rejection.invalid("\(name): invalid base64")
      }
      bytes = decoded
    default:
      throw Rejection.invalid(
        "\(name): expected a string or {\"base64\": string}"
      )
    }
    guard !bytes.contains(0) else {
      throw Rejection.invalid("\(name): NUL byte")
    }
    remaining -= bytes.count
    guard remaining >= 0 else { throw exceeded }
    return bytes
  }

  /// A relative path without empty or `..` components; `.` is dropped.
  package static func components(
    _ path: String,
    _ name: String
  ) throws -> [String] {
    guard !path.isEmpty, path.utf8.count <= WireLimits.pathBytes,
      !path.utf8.contains(0)
    else { throw Rejection.invalid("\(name): expected a non-empty path") }
    guard path.utf8.first != 47 else {
      throw Rejection.invalid("\(name): must be a relative path")
    }
    let parts = path.utf8.split(separator: 47, omittingEmptySubsequences: false)
      .map { String(decoding: $0, as: UTF8.self) }
    guard !parts.contains(""), !parts.contains("..") else {
      throw Rejection.invalid(
        "\(name): empty and \"..\" components are rejected"
      )
    }
    return parts.filter { $0 != "." }
  }

  /// ASCII only, so no text taken from a request can carry a terminal control
  /// sequence or a line break into a control channel.
  package static func quote(_ text: String) -> String {
    var output = "\""
    for unit in text.utf16 {
      switch unit {
      case 34: output += "\\\""
      case 92: output += "\\\\"
      case 32 ... 126: output.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
      default:
        let digits = String(unit, radix: 16)
        output +=
          "\\u" + String(repeating: "0", count: 4 - digits.count) + digits
      }
    }
    return output + "\""
  }

  package static func quote(_ text: String?) -> String {
    text.map { quote($0) } ?? "null"
  }
}

/// SHA-256 over decoded values in a fixed order, each length-prefixed. Key
/// order, whitespace, and string-versus-base64 spelling do not change it; any
/// byte that would reach a workload does.
package struct Canonical {
  private var bytes: [UInt8] = []

  package init() {}

  package mutating func field(_ value: some Sequence<UInt8>) {
    let value = Array(value)
    withUnsafeBytes(of: UInt32(value.count).bigEndian) {
      bytes.append(contentsOf: $0)
    }
    bytes.append(contentsOf: value)
  }

  package mutating func text(_ value: String) { field(value.utf8) }
  package mutating func number(_ value: Int?) { text(String(value ?? 0)) }

  package var digest: String {
    SHA256.hash(data: bytes)
      .map { byte in
        let digits = String(byte, radix: 16)
        return digits.count == 1 ? "0" + digits : digits
      }
      .joined()
  }
}
