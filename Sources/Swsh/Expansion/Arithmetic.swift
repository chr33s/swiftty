/// Checked signed 64-bit integer arithmetic for `$(( ))` and array indices.
/// Parsing is separate from evaluation so syntax is rejected before any command
/// runs and unselected `&&`, `||`, and `?:` operands are never evaluated.
indirect enum Arithmetic: Equatable, Sendable {
  case number(Int64)
  case variable(String)
  case element(String, Arithmetic)
  case count(String)
  case unary(UInt8, Arithmetic)
  case binary(String, Arithmetic, Arithmetic)
  case ternary(Arithmetic, Arithmetic, Arithmetic)
  /// `name = value`, `name[index] op= value`, and `++`/`--`. `post` yields the
  /// value from before the assignment.
  case assign(String, Arithmetic?, String?, Arithmetic, post: Bool)

  struct Failure: Error, Equatable { let message: String }

  protocol Values {
    func integer(_ name: String) throws -> Int64
    func integer(_ name: String, at index: Int64) throws -> Int64
    func count(_ name: String) throws -> Int64
    func assign(_ name: String, at index: Int64?, _ value: Int64) throws
  }

  /// Whether evaluation can assign a variable.
  var mutates: Bool {
    switch self {
    case .number, .variable, .count: false
    case .element(_, let index): index.mutates
    case .unary(_, let operand): operand.mutates
    case .binary(_, let left, let right): left.mutates || right.mutates
    case .ternary(let condition, let first, let second):
      condition.mutates || first.mutates || second.mutates
    case .assign: true
    }
  }

  static func parse(_ source: [UInt8]) throws -> Arithmetic {
    var reader = Reader(bytes: source)
    let value = try reader.sequence()
    reader.spaces()
    guard reader.current == nil else {
      throw Failure(message: "unexpected arithmetic token")
    }
    return value
  }

  func evaluate(_ values: some Values) throws -> Int64 {
    switch self {
    case .number(let value): return value
    case .variable(let name): return try values.integer(name)
    case .count(let name): return try values.count(name)
    case .element(let name, let index):
      return try values.integer(name, at: try index.evaluate(values))
    case .unary(let operation, let operand):
      let value = try operand.evaluate(values)
      switch operation {
      case 45: return try checked(Int64(0).subtractingReportingOverflow(value))
      case 33: return value == 0 ? 1 : 0
      case 126: return ~value
      default: return value
      }
    case .ternary(let condition, let first, let second):
      return try condition.evaluate(values) != 0
        ? first.evaluate(values) : second.evaluate(values)
    case .assign(let name, let index, let operation, let operand, let post):
      let position = try index?.evaluate(values)
      var old: Int64 = 0
      if operation != nil {
        old =
          try position.map { try values.integer(name, at: $0) }
          ?? values.integer(name)
      }
      var value = try operand.evaluate(values)
      if let operation {
        value = try Arithmetic.binary(operation, .number(old), .number(value))
          .evaluate(values)
      }
      try values.assign(name, at: position, value)
      return post ? old : value
    case .binary(let operation, let left, let right):
      let a = try left.evaluate(values)
      if operation == "&&" {
        guard a != 0 else { return 0 }
        return try right.evaluate(values) != 0 ? 1 : 0
      }
      if operation == "||" {
        guard a == 0 else { return 1 }
        return try right.evaluate(values) != 0 ? 1 : 0
      }
      let b = try right.evaluate(values)
      switch operation {
      case "+": return try checked(a.addingReportingOverflow(b))
      case "-": return try checked(a.subtractingReportingOverflow(b))
      case "*": return try checked(a.multipliedReportingOverflow(by: b))
      case "/", "%":
        guard b != 0 else { throw Failure(message: "division by zero") }
        return try checked(
          operation == "/"
            ? a.dividedReportingOverflow(by: b)
            : a.remainderReportingOverflow(dividingBy: b)
        )
      case "<<", ">>":
        guard (0 ..< 64).contains(b) else {
          throw Failure(message: "shift count must be 0 through 63")
        }
        return operation == "<<" ? a << b : a >> b
      case "<": return a < b ? 1 : 0
      case "<=": return a <= b ? 1 : 0
      case ">": return a > b ? 1 : 0
      case ">=": return a >= b ? 1 : 0
      case "==": return a == b ? 1 : 0
      case "!=": return a != b ? 1 : 0
      case "&": return a & b
      case "^": return a ^ b
      case ",": return b
      default: return a | b
      }
    }
  }

  private func checked(
    _ result: (partialValue: Int64, overflow: Bool)
  ) throws -> Int64 {
    guard !result.overflow else {
      throw Failure(message: "arithmetic overflow")
    }
    return result.partialValue
  }

  /// Integer text in shell values: optional sign, then decimal or `0x` hex.
  static func integer(_ bytes: [UInt8]) -> Int64? {
    var text = Substring(String(decoding: bytes, as: UTF8.self))
    while let first = text.first, first == " " || first == "\t" {
      text.removeFirst()
    }
    while let last = text.last, last == " " || last == "\t" {
      text.removeLast()
    }
    if text.isEmpty { return 0 }
    let negative = text.first == "-"
    if negative || text.first == "+" { text.removeFirst() }
    guard let first = text.first, first.isASCII, first.isNumber else {
      return nil
    }
    let sign = negative ? "-" : ""
    if text.hasPrefix("0x") || text.hasPrefix("0X") {
      return Int64(sign + String(text.dropFirst(2)), radix: 16)
    }
    return Int64(sign + String(text), radix: 10)
  }

  private struct Reader {
    let bytes: [UInt8]
    var index = 0
    var depth = 0
    var current: UInt8? { index < bytes.count ? bytes[index] : nil }

    mutating func spaces() {
      while let byte = current, [32, 9, 10, 13].contains(byte) { index += 1 }
    }

    /// Longest match first, so `<<` is never read as two comparisons.
    mutating func take(_ operators: [String]) -> String? {
      spaces()
      for candidate in operators {
        let text = Array(candidate.utf8)
        guard index + text.count <= bytes.count,
          Array(bytes[index ..< index + text.count]) == text
        else { continue }
        // A lone `&` or `|` must not consume half of `&&` or `||`.
        if text.count == 1, [38, 124].contains(text[0]),
          index + 1 < bytes.count, bytes[index + 1] == text[0]
        {
          continue
        }
        index += text.count
        return candidate
      }
      return nil
    }

    /// `first, second`: both run in order and the last is the value.
    mutating func sequence() throws -> Arithmetic {
      var value = try expression()
      while take([","]) != nil { value = .binary(",", value, try expression()) }
      return value
    }

    /// Assignment binds loosest and to the right: `a = b = 1`.
    mutating func expression() throws -> Arithmetic {
      guard depth < 64 else {
        throw Failure(message: "arithmetic nesting limit exceeded")
      }
      depth += 1
      defer { depth -= 1 }
      spaces()
      guard let operation = assignmentOperator() else {
        let condition = try binary(0)
        guard take(["?"]) != nil else { return condition }
        let first = try expression()
        guard take([":"]) != nil else {
          throw Failure(message: "expected ':' in arithmetic conditional")
        }
        return .ternary(condition, first, try expression())
      }
      let (name, position) = try target()
      spaces()
      index += operation.utf8.count + 1
      return .assign(
        name,
        position,
        operation.isEmpty ? nil : operation,
        try expression(),
        post: false
      )
    }

    /// Looks ahead for `name op=` or `name[...] op=` without consuming it.
    /// An empty result is plain `=`; `==` is a comparison.
    func assignmentOperator() -> String? {
      var next = index
      guard next < bytes.count, isNameByte(bytes[next]),
        !(48 ... 57).contains(bytes[next])
      else { return nil }
      while next < bytes.count, isNameByte(bytes[next]) { next += 1 }
      if next < bytes.count, bytes[next] == 91 {
        var nesting = 0
        while next < bytes.count {
          if bytes[next] == 91 { nesting += 1 }
          if bytes[next] == 93 { nesting -= 1 }
          next += 1
          if nesting == 0 { break }
        }
      }
      while next < bytes.count, [32, 9, 10, 13].contains(bytes[next]) {
        next += 1
      }
      for candidate in ["<<", ">>", "+", "-", "*", "/", "%", "&", "^", "|", ""]
      {
        let text = Array(candidate.utf8) + [61]
        guard next + text.count <= bytes.count,
          Array(bytes[next ..< next + text.count]) == text
        else { continue }
        let after = next + text.count
        if after < bytes.count, bytes[after] == 61 { return nil }
        return candidate
      }
      return nil
    }

    /// An assignable `name` or `name[index]`.
    mutating func target() throws -> (String, Arithmetic?) {
      let start = index
      guard let first = current, isNameByte(first), !(48 ... 57).contains(first)
      else { throw Failure(message: "expected a variable to assign") }
      while let next = current, isNameByte(next) { index += 1 }
      let name = String(decoding: bytes[start ..< index], as: UTF8.self)
      guard current == 91 else { return (name, nil) }
      index += 1
      let position = try expression()
      guard take(["]"]) != nil else {
        throw Failure(message: "expected ']' in arithmetic")
      }
      return (name, position)
    }

    /// `++` or `--` at `offset`, followed by `operand` or by anything else.
    func step(at offset: Int, operand: Bool) -> (String, Int)? {
      guard offset + 1 < bytes.count, [43, 45].contains(bytes[offset]),
        bytes[offset + 1] == bytes[offset]
      else { return nil }
      var next = offset + 2
      while next < bytes.count, [32, 9, 10, 13].contains(bytes[next]) {
        next += 1
      }
      let follows = next < bytes.count ? bytes[next] : 0
      let name = isNameByte(follows) && !(48 ... 57).contains(follows)
      let starts = isNameByte(follows) || follows == 36 || follows == 40
      guard operand ? name : !starts else { return nil }
      return (bytes[offset] == 43 ? "+" : "-", next)
    }

    private static let levels: [[String]] = [
      ["||"], ["&&"], ["|"], ["^"], ["&"], ["==", "!="],
      ["<=", ">=", "<", ">"], ["<<", ">>"], ["+", "-"], ["*", "/", "%"],
    ]

    mutating func binary(_ level: Int) throws -> Arithmetic {
      guard level < Self.levels.count else { return try unary() }
      var left = try binary(level + 1)
      while true {
        // Comparisons must not swallow the first byte of a shift.
        if level == 6 {
          spaces()
          if index + 1 < bytes.count, [60, 62].contains(bytes[index]),
            bytes[index + 1] == bytes[index]
          {
            return left
          }
        }
        guard let operation = take(Self.levels[level]) else { return left }
        left = .binary(operation, left, try binary(level + 1))
      }
    }

    mutating func unary() throws -> Arithmetic {
      guard depth < 64 else {
        throw Failure(message: "arithmetic nesting limit exceeded")
      }
      depth += 1
      defer { depth -= 1 }
      spaces()
      if let (operation, next) = step(at: index, operand: true) {
        index = next
        let (name, position) = try target()
        return .assign(name, position, operation, .number(1), post: false)
      }
      if let byte = current, [45, 43, 33, 126].contains(byte) {
        index += 1
        return .unary(byte, try unary())
      }
      return try primary()
    }

    mutating func primary() throws -> Arithmetic {
      spaces()
      guard let byte = current else {
        throw Failure(message: "expected arithmetic operand")
      }
      if byte == 40 {
        index += 1
        let value = try sequence()
        guard take([")"]) != nil else {
          throw Failure(message: "expected ')' in arithmetic")
        }
        return value
      }
      if (48 ... 57).contains(byte) {
        let start = index
        while let next = current, isNameByte(next) { index += 1 }
        guard let value = Arithmetic.integer(Array(bytes[start ..< index]))
        else { throw Failure(message: "invalid arithmetic number") }
        return .number(value)
      }
      var braced = false
      var counted = false
      if byte == 36 {
        index += 1
        if current == 40, index + 1 < bytes.count, bytes[index + 1] == 40 {
          // A nested `$(( ))` is a parenthesized expression.
          index += 2
          let value = try sequence()
          guard take([")"]) != nil, current == 41 else {
            throw Failure(message: "expected '))' in arithmetic")
          }
          index += 1
          return value
        }
        if current == 123 {
          braced = true
          index += 1
          if current == 35 {
            counted = true
            index += 1
          }
        }
      }
      let start = index
      if let digit = current, byte == 36, !braced, (48 ... 57).contains(digit) {
        index += 1
        return .variable(String(UnicodeScalar(digit)))
      }
      guard let first = current, isNameByte(first), !(48 ... 57).contains(first)
      else { throw Failure(message: "expected arithmetic operand") }
      while let next = current, isNameByte(next) { index += 1 }
      let name = String(decoding: bytes[start ..< index], as: UTF8.self)
      var value = Arithmetic.variable(name)
      if counted {
        let suffix = Array("[@]}".utf8)
        guard index + suffix.count <= bytes.count,
          Array(bytes[index ..< index + suffix.count]) == suffix
        else { throw Failure(message: "expected ${#name[@]}") }
        index += suffix.count
        return .count(name)
      }
      var position: Arithmetic?
      if current == 91 {
        index += 1
        let element = try expression()
        guard take(["]"]) != nil else {
          throw Failure(message: "expected ']' in arithmetic")
        }
        value = .element(name, element)
        position = element
      }
      if byte != 36 {
        var after = index
        while after < bytes.count, [32, 9].contains(bytes[after]) { after += 1 }
        if let (operation, next) = step(at: after, operand: false) {
          index = next
          return .assign(name, position, operation, .number(1), post: true)
        }
      }
      if braced {
        guard current == 125 else {
          throw Failure(message: "expected '}' in arithmetic")
        }
        index += 1
      }
      return value
    }

    func isNameByte(_ byte: UInt8) -> Bool {
      byte == 95 || (48 ... 57).contains(byte) || (65 ... 90).contains(byte)
        || (97 ... 122).contains(byte)
    }
  }
}
