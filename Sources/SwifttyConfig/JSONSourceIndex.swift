import Foundation

/// Validates JSON grammar and indexes value starts by coding path. Foundation
/// still owns decoding; this index provides stable diagnostics across OS releases.
struct JSONSourceIndex {
  let bytes: [UInt8]
  var cursor = 0
  var positions: [[String]: Int] = [:]

  init(_ data: Data) throws {
    bytes = Array(data)
    try value(path: [], depth: 0)
    whitespace()
    guard cursor == bytes.count else {
      throw failure("Unexpected content after JSON value")
    }
  }

  func offset(for path: [String]) -> Int {
    var path = path
    while positions[path] == nil && !path.isEmpty { path.removeLast() }
    return positions[path] ?? 0
  }

  private func failure(_ message: String) -> SourceFailure {
    SourceFailure(offset: cursor, message: message)
  }

  private mutating func whitespace() {
    while cursor < bytes.count && [9, 10, 13, 32].contains(bytes[cursor]) {
      cursor += 1
    }
  }

  private mutating func consume(_ byte: UInt8) -> Bool {
    whitespace()
    guard cursor < bytes.count, bytes[cursor] == byte else { return false }
    cursor += 1
    return true
  }

  private mutating func string() throws -> String {
    whitespace()
    let start = cursor
    guard consume(34) else { throw failure("Expected a quoted string") }
    while cursor < bytes.count {
      let byte = bytes[cursor]
      cursor += 1
      if byte == 34 {
        do {
          return try JSONDecoder()
            .decode(String.self, from: Data(bytes[start ..< cursor]))
        } catch {
          throw SourceFailure(
            offset: start,
            message: "Invalid JSON string escape"
          )
        }
      }
      if byte < 32 {
        throw SourceFailure(
          offset: cursor - 1,
          message: "Control character in string"
        )
      }
      if byte == 92 {
        guard cursor < bytes.count else { break }
        let escape = bytes[cursor]
        guard [34, 47, 92, 98, 102, 110, 114, 116, 117].contains(escape) else {
          throw failure("Invalid JSON string escape")
        }
        cursor += 1
        if escape == 117 {
          let escapeStart = cursor - 2
          let scalar = try hexQuad()
          if (0xD800 ... 0xDBFF).contains(scalar) {
            guard cursor + 1 < bytes.count, bytes[cursor] == 92,
              bytes[cursor + 1] == 117
            else { throw failure("Expected a low surrogate escape") }
            cursor += 2
            let lowStart = cursor
            guard (0xDC00 ... 0xDFFF).contains(try hexQuad()) else {
              throw SourceFailure(
                offset: lowStart,
                message: "Expected a low surrogate"
              )
            }
          } else if (0xDC00 ... 0xDFFF).contains(scalar) {
            throw SourceFailure(
              offset: escapeStart,
              message: "Unpaired low surrogate"
            )
          }
        }
      }
    }
    throw SourceFailure(offset: start, message: "Unterminated string")
  }

  private mutating func hexQuad() throws -> UInt16 {
    var result: UInt16 = 0
    for _ in 0 ..< 4 {
      guard cursor < bytes.count else {
        throw failure("Expected four hexadecimal digits")
      }
      let digit: UInt8
      switch bytes[cursor] {
      case 48 ... 57: digit = bytes[cursor] - 48
      case 65 ... 70: digit = bytes[cursor] - 55
      case 97 ... 102: digit = bytes[cursor] - 87
      default: throw failure("Expected four hexadecimal digits")
      }
      result = result * 16 + UInt16(digit)
      cursor += 1
    }
    return result
  }

  private mutating func value(path: [String], depth: Int) throws {
    whitespace()
    guard depth < 128 else {
      throw failure("Configuration nesting exceeds 128 levels")
    }
    positions[path] = cursor
    guard cursor < bytes.count else { throw failure("Expected a JSON value") }
    switch bytes[cursor] {
    case 123:
      cursor += 1
      if consume(125) { return }
      var keys: Set<String> = []
      repeat {
        let key = try string()
        guard keys.insert(key).inserted else {
          throw failure("Duplicate key '\(key)'")
        }
        guard consume(58) else { throw failure("Expected ':'") }
        try value(path: path + [key], depth: depth + 1)
        if consume(125) { return }
        guard consume(44) else { throw failure("Expected ',' or '}'") }
      } while true
    case 91:
      cursor += 1
      if consume(93) { return }
      var index = 0
      repeat {
        try value(path: path + [String(index)], depth: depth + 1)
        index += 1
        if consume(93) { return }
        guard consume(44) else { throw failure("Expected ',' or ']'") }
      } while true
    case 34: _ = try string()
    case 116, 102, 110:
      let token =
        bytes[cursor] == 116 ? "true" : bytes[cursor] == 102 ? "false" : "null"
      for byte in token.utf8 {
        guard cursor < bytes.count, bytes[cursor] == byte else {
          throw failure("Invalid JSON literal")
        }
        cursor += 1
      }
    default: try number()
    }
  }

  private mutating func number() throws {
    let start = cursor
    if cursor < bytes.count && bytes[cursor] == 45 { cursor += 1 }
    guard cursor < bytes.count else { throw failure("Expected a number") }
    if bytes[cursor] == 48 { cursor += 1 } else { try digits() }
    if cursor < bytes.count && bytes[cursor] == 46 {
      cursor += 1
      try digits()
    }
    if cursor < bytes.count && (bytes[cursor] == 101 || bytes[cursor] == 69) {
      cursor += 1
      if cursor < bytes.count && (bytes[cursor] == 43 || bytes[cursor] == 45) {
        cursor += 1
      }
      try digits()
    }
    guard
      let number = Double(
        String(decoding: bytes[start ..< cursor], as: UTF8.self)
      ), number.isFinite
    else {
      throw SourceFailure(
        offset: start,
        message: "Number is outside the supported finite range"
      )
    }
  }

  private mutating func digits() throws {
    let start = cursor
    while cursor < bytes.count && (48 ... 57).contains(bytes[cursor]) {
      cursor += 1
    }
    guard cursor > start else { throw failure("Expected a digit") }
  }
}
