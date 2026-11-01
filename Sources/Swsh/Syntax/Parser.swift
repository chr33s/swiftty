/// A concrete, synchronous parser. Syntax retains source bytes, never cursor borrows.
public struct Parser {
  public init() {}

  public func parse(_ source: String) -> ParseResult {
    parse(Array(source.utf8))
  }

  public func parse(_ source: [UInt8]) -> ParseResult {
    guard String(validating: source, as: UTF8.self) != nil else {
      return .invalid(
        ShellDiagnostic(offset: 0, message: "source is not valid UTF-8")
      )
    }
    if let offset = source.firstIndex(of: 0) {
      return .invalid(ShellDiagnostic(offset: offset, message: "NUL in source"))
    }
    var cursor = Cursor(bytes: source)
    do { return .complete(try cursor.program()) } catch let failure
      as ParseFailure
    {
      return failure.incomplete
        ? .incomplete(failure.diagnostic) : .invalid(failure.diagnostic)
    } catch { preconditionFailure("unexpected parser error") }
  }
}

private struct ParseFailure: Error {
  let diagnostic: ShellDiagnostic
  let incomplete: Bool
}

private struct Cursor {
  let bytes: [UInt8]
  var index = 0
  var depth = 0
  var current: UInt8? {
    let view = bytes.span
    return index < view.count ? view[index] : nil
  }
  func fail(_ message: String, incomplete: Bool = false) -> ParseFailure {
    ParseFailure(
      diagnostic: ShellDiagnostic(offset: index, message: message),
      incomplete: incomplete
    )
  }
  mutating func spaces() {
    while true {
      if current == 32 || current == 9 || current == 13 {
        index += 1
      } else if current == 92 && peek() == 10 {
        index += 2
      } else {
        break
      }
    }
    if current == 35 { while let byte = current, byte != 10 { index += 1 } }
  }
  mutating func program(until closing: UInt8? = nil) throws -> Program {
    guard depth < 16 else { throw fail("syntax nesting limit exceeded") }
    depth += 1
    defer { depth -= 1 }
    var entries: [CommandListEntry] = []
    var condition = CommandListEntry.Condition.always
    spaces()
    while current == 10 {
      index += 1;
      spaces()
    }
    while current != nil && current != closing {
      var pipeline = [try command()]
      spaces()
      while current == 124 && peek() != 124 {
        index += 1
        try continuation()
        pipeline.append(try command())
        spaces()
      }
      let background = current == 38 && peek() != 38
      entries.append(
        CommandListEntry(
          condition: condition,
          pipeline: pipeline,
          background: background
        )
      )
      condition = .always
      guard let byte = current, byte != closing else { break }
      if (byte == 38 && peek() == 38) || (byte == 124 && peek() == 124) {
        condition = byte == 38 ? .success : .failure
        index += 2
        try continuation()
      } else if byte == 59 || byte == 10 || background {
        index += 1
        spaces()
        while current == 10 {
          index += 1;
          spaces()
        }
      } else {
        throw fail("expected command separator")
      }
    }
    return Program(source: bytes, commands: entries)
  }
  func peek() -> UInt8? { index + 1 < bytes.count ? bytes[index + 1] : nil }
  mutating func continuation() throws {
    spaces()
    while current == 10 {
      index += 1;
      spaces()
    }
    if current == nil { throw fail("expected command", incomplete: true) }
    if current == 41 || current == 125 { throw fail("expected command") }
  }
  mutating func command() throws -> SimpleCommand {
    var assignments: [Assignment] = []
    var words: [Word] = []
    var redirects: [Redirect] = []
    var compound: Compound?
    spaces()
    if current == 40 {
      compound = .subshell(try body(open: 40, close: 41))
    } else if let byte = current, isNameStart(byte) {
      let start = index
      index += 1
      while let byte = current, isNameStart(byte) || (48 ... 57).contains(byte)
      { index += 1 }
      let name = String(decoding: bytes[start ..< index], as: UTF8.self)
      spaces()
      if current == 40 && peek() == 41 {
        index += 2
        spaces()
        while current == 10 {
          index += 1;
          spaces()
        }
        guard current == 123 else {
          throw fail("expected function body", incomplete: current == nil)
        }
        compound = .function(name, try body(open: 123, close: 125))
      } else {
        index = start
      }
    }
    while true {
      spaces()
      guard let byte = current, ![10, 59, 38, 124, 41, 125].contains(byte)
      else { break }
      let start = index
      if words.isEmpty, isNameStart(byte) {
        index += 1
        while let byte = current,
          isNameStart(byte) || (48 ... 57).contains(byte)
        { index += 1 }
        if current == 61 {
          let name = String(decoding: bytes[start ..< index], as: UTF8.self)
          index += 1
          assignments.append(Assignment(name: name, value: try word()))
          continue
        }
        index = start
      }
      while let digit = current, digit >= 48 && digit <= 57 { index += 1 }
      let numberEnd = index
      if current == 60 || current == 62 {
        let input = current == 60
        let descriptor: Int32
        if numberEnd > start {
          guard
            let value = Int32(
              String(decoding: bytes[start ..< numberEnd], as: UTF8.self)
            )
          else { throw fail("descriptor out of range") }
          descriptor = value
        } else {
          descriptor = input ? 0 : 1
        }
        index += 1
        var operation: Redirect.Operation = input ? .read : .write
        if current == 38 {
          operation = input ? .duplicateInput : .duplicateOutput;
          index += 1
        } else if current == 62 && !input {
          operation = .append;
          index += 1
        } else if current == 60 {
          throw fail("heredocs are not supported")
        }
        spaces()
        guard let target = current else {
          throw fail("expected redirect target", incomplete: true)
        }
        guard !isBoundary(target) else {
          throw fail("expected redirect target")
        }
        redirects.append(
          Redirect(
            descriptor: descriptor,
            operation: operation,
            target: try word()
          )
        )
      } else {
        index = start
        guard compound == nil else {
          throw fail("unexpected word after compound command")
        }
        words.append(try word())
      }
    }
    guard
      !words.isEmpty || !redirects.isEmpty || !assignments.isEmpty
        || compound != nil
    else { throw fail("expected command") }
    return SimpleCommand(
      assignments: assignments,
      words: words,
      redirects: redirects,
      compound: compound
    )
  }
  func isBoundary(_ byte: UInt8) -> Bool {
    [32, 9, 13, 10, 59, 38, 124, 60, 62, 41, 125].contains(byte)
  }
  mutating func word() throws -> Word {
    let start = index
    var parts: [Word.Part] = []
    while let byte = current, !isBoundary(byte) {
      switch byte {
      case 39, 34:
        let quote = byte
        index += 1
        parts.append(.literal([]))
        while let inner = current, inner != quote {
          if quote == 34 && inner == 36 {
            try expansion(into: &parts)
          } else if quote == 34 && inner == 92 {
            try escape(into: &parts, quoted: true)
          } else {
            parts.append(.literal([inner]));
            index += 1
          }
        }
        guard current != nil else {
          throw fail("unterminated quote", incomplete: true)
        }
        index += 1
      case 92: try escape(into: &parts, quoted: false)
      case 36: try expansion(into: &parts)
      case 42, 63:
        parts.append(.wildcard(byte));
        index += 1
      case 96, 40, 41, 123, 125, 91, 93:
        throw fail(
          "unsupported syntax; quote this character to use it literally"
        )
      default:
        parts.append(.literal([byte]));
        index += 1
      }
    }
    return Word(range: start ..< index, parts: parts)
  }
  mutating func escape(into parts: inout [Word.Part], quoted: Bool) throws {
    index += 1
    guard let byte = current else {
      throw fail("unfinished escape", incomplete: true)
    }
    if byte != 10 {
      if quoted && ![36, 34, 92].contains(byte) {
        parts.append(.literal([92]))
      }
      parts.append(.literal([byte]))
    }
    index += 1
  }
  mutating func expansion(into parts: inout [Word.Part]) throws {
    index += 1
    if current == 63 {
      parts.append(.status);
      index += 1;
      return
    }
    if current == 40 {
      parts.append(.substitution(try body(open: 40, close: 41)))
      return
    }
    if let byte = current, (48 ... 57).contains(byte) || byte == 35 {
      parts.append(.variable(String(UnicodeScalar(byte))))
      index += 1
      return
    }
    let braced = current == 123
    if braced { index += 1 }
    let start = index
    guard let byte = current, isNameStart(byte) else {
      throw fail("expected variable name", incomplete: current == nil && braced)
    }
    index += 1
    while let byte = current, isNameStart(byte) || (48 ... 57).contains(byte) {
      index += 1
    }
    let name = String(decoding: bytes[start ..< index], as: UTF8.self)
    if braced {
      guard current == 125 else {
        throw fail(
          "expected closing variable brace",
          incomplete: current == nil
        )
      }
      index += 1
    }
    parts.append(.variable(name))
  }
  mutating func body(open: UInt8, close: UInt8) throws -> [UInt8] {
    precondition(current == open)
    index += 1
    let start = index
    _ = try program(until: close)
    guard current == close else {
      throw fail("unterminated compound command", incomplete: true)
    }
    let source = Array(bytes[start ..< index])
    index += 1
    return source
  }
  func isNameStart(_ byte: UInt8) -> Bool {
    byte == 95 || (65 ... 90).contains(byte) || (97 ... 122).contains(byte)
  }
}
