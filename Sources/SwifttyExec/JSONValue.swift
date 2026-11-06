/// A strict, bounded JSON reader for protocol frames. Unlike a general decoder it
/// rejects duplicate keys, non-integer numbers, and lone surrogates, so two
/// readers cannot disagree about what a request says.
package enum JSONValue: Equatable, Sendable {
  case null
  case bool(Bool)
  case integer(Int64)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  package struct Failure: Error, Equatable { let message: String }

  static func parse(_ bytes: [UInt8]) throws -> JSONValue {
    guard String(validating: bytes, as: UTF8.self) != nil else {
      throw Failure(message: "frame is not valid UTF-8")
    }
    var reader = Reader(bytes: bytes)
    let value = try reader.value(depth: 0)
    reader.spaces()
    guard reader.index == bytes.count else {
      throw Failure(message: "unexpected data after the JSON value")
    }
    return value
  }

  private struct Reader {
    let bytes: [UInt8]
    var index = 0
    var values = 0
    var current: UInt8? { index < bytes.count ? bytes[index] : nil }

    mutating func spaces() {
      while let byte = current, [32, 9, 10, 13].contains(byte) { index += 1 }
    }

    mutating func value(depth: Int) throws -> JSONValue {
      guard depth < WireLimits.nesting else {
        throw Failure(message: "JSON nesting exceeds \(WireLimits.nesting)")
      }
      values += 1
      guard values <= WireLimits.values else {
        throw Failure(
          message: "JSON holds more than \(WireLimits.values) values"
        )
      }
      spaces()
      switch current {
      case 123:
        index += 1
        var object: [String: JSONValue] = [:]
        spaces()
        if current == 125 {
          index += 1
          return .object(object)
        }
        while true {
          spaces()
          guard current == 34 else { throw Failure(message: "expected a key") }
          let key = try string()
          spaces()
          guard current == 58 else { throw Failure(message: "expected ':'") }
          index += 1
          guard
            object.updateValue(try value(depth: depth + 1), forKey: key) == nil
          else { throw Failure(message: "duplicate key") }
          spaces()
          if current == 125 { break }
          guard current == 44 else {
            throw Failure(message: "expected ',' or '}'")
          }
          index += 1
        }
        index += 1
        return .object(object)
      case 91:
        index += 1
        var array: [JSONValue] = []
        spaces()
        if current == 93 {
          index += 1
          return .array(array)
        }
        while true {
          array.append(try value(depth: depth + 1))
          spaces()
          if current == 93 { break }
          guard current == 44 else {
            throw Failure(message: "expected ',' or ']'")
          }
          index += 1
        }
        index += 1
        return .array(array)
      case 34: return .string(try string())
      case 116: return try literal("true", .bool(true))
      case 102: return try literal("false", .bool(false))
      case 110: return try literal("null", .null)
      default: return try number()
      }
    }

    mutating func literal(
      _ text: String,
      _ value: JSONValue
    ) throws -> JSONValue {
      let expected = Array(text.utf8)
      guard index + expected.count <= bytes.count,
        Array(bytes[index ..< index + expected.count]) == expected
      else { throw Failure(message: "unexpected JSON token") }
      index += expected.count
      return value
    }

    mutating func number() throws -> JSONValue {
      let start = index
      if current == 45 { index += 1 }
      guard let first = current, (48 ... 57).contains(first) else {
        throw Failure(message: "unexpected JSON token")
      }
      index += 1
      if first != 48 {
        while let byte = current, (48 ... 57).contains(byte) { index += 1 }
      }
      if let byte = current,
        [46, 101, 69].contains(byte) || (48 ... 57).contains(byte)
      {
        throw Failure(message: "numbers must be plain integers")
      }
      guard
        let value = Int64(
          String(decoding: bytes[start ..< index], as: UTF8.self)
        )
      else { throw Failure(message: "integer out of range") }
      return .integer(value)
    }

    mutating func unit() throws -> UInt32 {
      guard index + 4 <= bytes.count,
        let value = UInt32(
          String(decoding: bytes[index ..< index + 4], as: UTF8.self),
          radix: 16
        ), bytes[index ..< index + 4].allSatisfy({ $0 != 43 && $0 != 45 })
      else { throw Failure(message: "invalid \\u escape") }
      index += 4
      return value
    }

    mutating func string() throws -> String {
      index += 1
      var output: [UInt8] = []
      while true {
        guard let byte = current else {
          throw Failure(message: "unterminated string")
        }
        index += 1
        if byte == 34 { break }
        guard byte >= 32 else {
          throw Failure(message: "control character in string")
        }
        guard byte == 92 else {
          output.append(byte)
          continue
        }
        guard let escape = current else {
          throw Failure(message: "unterminated string")
        }
        index += 1
        switch escape {
        case 34, 92, 47: output.append(escape)
        case 98: output.append(8)
        case 102: output.append(12)
        case 110: output.append(10)
        case 114: output.append(13)
        case 116: output.append(9)
        case 117:
          var scalar = try unit()
          if (0xD800 ..< 0xDC00).contains(scalar) {
            guard current == 92, index + 1 < bytes.count,
              bytes[index + 1] == 117
            else { throw Failure(message: "lone surrogate in string") }
            index += 2
            let low = try unit()
            guard (0xDC00 ..< 0xE000).contains(low) else {
              throw Failure(message: "lone surrogate in string")
            }
            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
          }
          guard let value = Unicode.Scalar(scalar) else {
            throw Failure(message: "lone surrogate in string")
          }
          output.append(contentsOf: Array(String(Character(value)).utf8))
        default: throw Failure(message: "invalid string escape")
        }
      }
      return String(decoding: output, as: UTF8.self)
    }
  }
}

package enum Base64 {
  package static func encode(_ bytes: [UInt8]) -> String {
    let alphabet = Array(
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8
    )
    var output: [UInt8] = []
    output.reserveCapacity((bytes.count + 2) / 3 * 4)
    var index = 0
    while index < bytes.count {
      let count = min(3, bytes.count - index)
      var group = UInt32(bytes[index]) << 16
      if count > 1 { group |= UInt32(bytes[index + 1]) << 8 }
      if count > 2 { group |= UInt32(bytes[index + 2]) }
      output.append(alphabet[Int(group >> 18)])
      output.append(alphabet[Int(group >> 12 & 63)])
      output.append(count > 1 ? alphabet[Int(group >> 6 & 63)] : 61)
      output.append(count > 2 ? alphabet[Int(group & 63)] : 61)
      index += 3
    }
    return String(decoding: output, as: UTF8.self)
  }

  /// Standard alphabet with required padding and no whitespace.
  static func decode(_ text: String) -> [UInt8]? {
    let input = Array(text.utf8)
    guard input.count % 4 == 0 else { return nil }
    func value(_ byte: UInt8) -> UInt32? {
      switch byte {
      case 65 ... 90: UInt32(byte - 65)
      case 97 ... 122: UInt32(byte - 97 + 26)
      case 48 ... 57: UInt32(byte - 48 + 52)
      case 43: 62
      case 47: 63
      default: nil
      }
    }
    var output: [UInt8] = []
    output.reserveCapacity(input.count / 4 * 3)
    var index = 0
    while index < input.count {
      let last = index + 4 == input.count
      let padding =
        last
        ? (input[index + 3] == 61 ? (input[index + 2] == 61 ? 2 : 1) : 0) : 0
      var group: UInt32 = 0
      for offset in 0 ..< 4 {
        if offset >= 4 - padding {
          group <<= 6
          continue
        }
        guard let digit = value(input[index + offset]) else { return nil }
        group = group << 6 | digit
      }
      // Bits that fall into the padding must be zero: one encoding per value.
      if padding == 1, group & 0xFF != 0 { return nil }
      if padding == 2, group & 0xFFFF != 0 { return nil }
      output.append(UInt8(group >> 16))
      if padding < 2 { output.append(UInt8(group >> 8 & 0xFF)) }
      if padding < 1 { output.append(UInt8(group & 0xFF)) }
      index += 4
    }
    return output
  }
}
