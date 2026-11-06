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
  /// Line-ending newline offset to the offset after that line's heredoc bodies.
  var heredocSkips: [Int: Int] = [:]
  /// Operator offset and body end of every heredoc, for containment checks.
  var heredocs: [(operation: Int, end: Int)] = []
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
  /// Consumes a line ending together with any heredoc bodies that follow it.
  mutating func newline() { index = heredocSkips[index] ?? index + 1 }
  mutating func newlines() {
    spaces()
    while current == 10 {
      newline()
      spaces()
    }
  }
  /// A bare lowercase word at command position, such as `then` or `done`.
  func keyword() -> String? {
    var end = index
    while end < bytes.count, (97 ... 122).contains(bytes[end]) { end += 1 }
    guard end > index, end == bytes.count || isBoundary(bytes[end]) else {
      return nil
    }
    return String(decoding: bytes[index ..< end], as: UTF8.self)
  }
  mutating func expect(_ word: String) throws {
    guard keyword() == word else {
      throw fail("expected '\(word)'", incomplete: current == nil)
    }
    index += word.utf8.count
  }
  /// A non-empty command list ending before one of `terminators`.
  mutating func list(_ terminators: Set<String>) throws -> Program {
    let parsed = try program(terminators: terminators)
    guard !parsed.commands.isEmpty else {
      throw fail("expected command", incomplete: current == nil)
    }
    return parsed
  }
  mutating func program(
    until closing: UInt8? = nil,
    terminators: Set<String> = [],
    clause: Bool = false
  ) throws -> Program {
    guard depth < 16 else { throw fail("syntax nesting limit exceeded") }
    depth += 1
    defer { depth -= 1 }
    var entries: [CommandListEntry] = []
    var condition = CommandListEntry.Condition.always
    newlines()
    while current != nil && current != closing
      && !(keyword().map(terminators.contains) ?? false)
      && !(clause && current == 59 && peek() == 59)
    {
      var negated = false
      if current == 33, let next = peek(), next == 32 || next == 9 {
        index += 1
        negated = true
      }
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
          background: background,
          negated: negated
        )
      )
      condition = .always
      guard let byte = current, byte != closing else { break }
      if (byte == 38 && peek() == 38) || (byte == 124 && peek() == 124) {
        condition = byte == 38 ? .success : .failure
        index += 2
        try continuation()
      } else if clause && byte == 59 && peek() == 59 {
        break
      } else if byte == 59 || byte == 10 || background {
        if byte == 10 { newline() } else { index += 1 }
        newlines()
      } else {
        throw fail("expected command separator")
      }
    }
    return Program(source: bytes, commands: entries)
  }
  func peek() -> UInt8? { index + 1 < bytes.count ? bytes[index + 1] : nil }
  mutating func continuation() throws {
    newlines()
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
    } else if current == 123 {
      let start = index + 1
      index += 1
      let list = try program(until: 125)
      guard current == 125 else {
        throw fail("unterminated compound command", incomplete: true)
      }
      guard !list.commands.isEmpty else { throw fail("expected command") }
      try containHeredocs(from: start)
      compound = .group(list, source: Array(bytes[start ..< index]))
      index += 1
    } else if let word = keyword(),
      ["if", "while", "until", "for", "case"].contains(word)
    {
      compound = try controlFlow(word)
    } else if let word = keyword(),
      ["then", "elif", "else", "fi", "do", "done", "esac"].contains(word)
    {
      throw fail("unexpected '\(word)'")
    } else if let byte = current, isNameStart(byte) {
      let start = index
      index += 1
      while let byte = current, isNameStart(byte) || (48 ... 57).contains(byte)
      { index += 1 }
      let name = String(decoding: bytes[start ..< index], as: UTF8.self)
      spaces()
      if current == 40 && peek() == 41 {
        index += 2
        newlines()
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
        let name = String(decoding: bytes[start ..< index], as: UTF8.self)
        if let assignment = try assignment(name) {
          assignments.append(assignment)
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
        } else if current == 60 && input {
          index += 1
          redirects.append(try heredoc(descriptor: descriptor, at: start))
          continue
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
      case 39, 34: try quoted(into: &parts)
      case 92: try escape(into: &parts, quoted: false)
      case 36: try expansion(into: &parts)
      case 42, 63:
        parts.append(.wildcard(byte));
        index += 1
      case 91:
        if let end = try bracketEnd() {
          parts.append(.bracket(Array(bytes[index ..< end])))
          index = end
        } else {
          parts.append(.literal([byte]))
          index += 1
        }
      case 96, 40, 41, 123, 125:
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
  /// The end of the bracket expression that opens at the cursor, or nil when
  /// no `]` closes it within the word and the `[` is therefore literal.
  func bracketEnd() throws -> Int? {
    var next = index + 1
    if next < bytes.count, bytes[next] == 94 {
      // glob(3) and fnmatch(3) disagree about `^`, so only `!` negates.
      throw fail(
        "negate a bracket pattern with '!'; quote '[' to use it literally"
      )
    }
    if next < bytes.count, bytes[next] == 33 { next += 1 }
    // A `]` in first position is a member, not the end.
    if next < bytes.count, bytes[next] == 93 { next += 1 }
    while next < bytes.count {
      let byte = bytes[next]
      if byte == 93 { return next + 1 }
      if isBoundary(byte) || [96, 40, 123].contains(byte) { return nil }
      if [39, 34, 92, 36].contains(byte) {
        throw fail(
          "a bracket pattern holds literal characters only; quote '[' to use it literally"
        )
      }
      if byte == 91, next + 1 < bytes.count, bytes[next + 1] == 58 {
        // `[:class:]` contains a `]` that does not end the expression.
        var close = next + 2
        while close + 1 < bytes.count, !isBoundary(bytes[close]),
          !(bytes[close] == 58 && bytes[close + 1] == 93)
        { close += 1 }
        if close + 1 < bytes.count, bytes[close] == 58, bytes[close + 1] == 93 {
          next = close + 2
          continue
        }
      }
      next += 1
    }
    return nil
  }
  /// A single- or double-quoted section, with the cursor on its opening quote.
  mutating func quoted(into parts: inout [Word.Part]) throws {
    let quote = bytes[index]
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
  }
  /// The word of `${name-word}`, up to its closing brace. Spaces are literal
  /// and wildcards are not patterns.
  mutating func operand() throws -> [Word.Part] {
    var parts: [Word.Part] = []
    while let byte = current, byte != 125 {
      switch byte {
      case 39, 34: try quoted(into: &parts)
      case 92: try escape(into: &parts, quoted: false)
      case 36: try expansion(into: &parts)
      default:
        parts.append(.literal([byte]))
        index += 1
      }
    }
    guard current != nil else {
      throw fail("expected closing variable brace", incomplete: true)
    }
    return parts
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
    if current == 36 || current == 64 {
      parts.append(current == 36 ? .processID : .list("@"))
      index += 1
      return
    }
    if current == 40 && peek() == 40 {
      let start = index
      do {
        parts.append(.arithmetic(try arithmeticSource()))
        return
      } catch let failure as ParseFailure {
        // `$((command))` stays a substituted subshell. Text that starts like
        // an expression keeps its arithmetic diagnostic.
        let first = bytes[(start + 2)...].first { ![32, 9, 10].contains($0) }
        guard let first, first != 41, !(48 ... 57).contains(first),
          ![45, 43, 33, 126, 40, 36].contains(first)
        else { throw failure }
        index = start
      }
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
    let counted = braced && current == 35
    if counted { index += 1 }
    let start = index
    if braced, !counted, current == 64, peek() == 125 {
      parts.append(.list("@"))
      index += 2
      return
    }
    let positional = braced && current.map((48 ... 57).contains) == true
    guard let byte = current, isNameStart(byte) || positional else {
      throw fail("expected variable name", incomplete: current == nil && braced)
    }
    index += 1
    while !positional, let byte = current,
      isNameStart(byte) || (48 ... 57).contains(byte)
    { index += 1 }
    let name = String(decoding: bytes[start ..< index], as: UTF8.self)
    var part = Word.Part.variable(name)
    if braced, !counted, let byte = current,
      [58, 45, 61, 63, 43].contains(byte)
    {
      let colon = byte == 58
      if colon { index += 1 }
      let operation: Word.ParameterOperation
      switch current {
      case 45: operation = .useDefault
      case 61: operation = .assign
      case 63: operation = .fail
      case 43: operation = .alternate
      default:
        throw fail(
          "expected -, =, ?, or + after ':'",
          incomplete: current == nil
        )
      }
      guard operation != .assign || !positional else {
        throw fail("a positional parameter cannot be assigned")
      }
      index += 1
      part = .parameter(name, operation, colon: colon, try operand())
    } else if braced && current == 91 && !positional {
      let source = try bracketed()
      if source == [64] {
        part = counted ? .count(name) : .list(name)
      } else if counted {
        throw fail("expected ${#name[@]}")
      } else {
        part = .element(name, source)
      }
    } else if counted {
      part = .length(name)
    }
    if braced {
      guard current == 125 else {
        throw fail(
          "expected closing variable brace",
          incomplete: current == nil
        )
      }
      index += 1
    }
    parts.append(part)
  }
  /// The source between `[` and its `]`, validated as `@` or arithmetic.
  mutating func bracketed() throws -> [UInt8] {
    precondition(current == 91)
    index += 1
    let start = index
    var nesting = 0
    while let byte = current, byte != 93 || nesting > 0 {
      guard byte != 10 else { throw fail("unterminated index") }
      if byte == 91 { nesting += 1 }
      if byte == 93 { nesting -= 1 }
      index += 1
    }
    guard current == 93 else {
      throw fail("unterminated index", incomplete: true)
    }
    let source = Array(bytes[start ..< index])
    index += 1
    if source != [64] { try validateArithmetic(source, at: start) }
    return source
  }
  func validateArithmetic(_ source: [UInt8], at offset: Int) throws {
    do { _ = try Arithmetic.parse(source) } catch let error
      as Arithmetic.Failure
    {
      throw ParseFailure(
        diagnostic: ShellDiagnostic(offset: offset, message: error.message),
        incomplete: false
      )
    }
  }
  /// `$(( expression ))`. The caller falls back to a substituted subshell when
  /// the text is a command instead.
  mutating func arithmeticSource() throws -> [UInt8] {
    index += 2
    let start = index
    var nesting = 0
    while let byte = current {
      if byte == 40 {
        nesting += 1
      } else if byte == 41 {
        if nesting == 0 { break }
        nesting -= 1
      }
      index += 1
    }
    guard current != nil else {
      throw fail("unterminated arithmetic expansion", incomplete: true)
    }
    guard peek() == 41 else { throw fail("expected '))'") }
    let source = Array(bytes[start ..< index])
    index += 2
    try validateArithmetic(source, at: start)
    return source
  }
  /// Called after a name at command position; nil when it is not an assignment.
  mutating func assignment(_ name: String) throws -> Assignment? {
    var position: [UInt8]?
    if current == 91 {
      // `name[...]` that is not followed by `=` is left to the word parser.
      guard let close = bytes[index...].firstIndex(of: 93),
        close + 1 < bytes.count, bytes[close + 1] == 61
      else { return nil }
      position = try bracketed()
      guard position != [64] else { throw fail("expected element index") }
    }
    let append = position == nil && current == 43 && peek() == 61
    if append { index += 1 }
    guard current == 61 else { return nil }
    index += 1
    guard current == 40 else {
      return Assignment(
        name: name,
        value: try word(),
        index: position,
        append: append
      )
    }
    guard position == nil else { throw fail("an element cannot hold a list") }
    let start = index
    index += 1
    var elements: [Word] = []
    while true {
      newlines()
      guard let byte = current else {
        throw fail("unterminated list", incomplete: true)
      }
      if byte == 41 { break }
      guard !isBoundary(byte) else { throw fail("expected list element") }
      elements.append(try word())
    }
    index += 1
    return Assignment(
      name: name,
      value: Word(range: start ..< index, parts: []),
      elements: elements,
      append: append
    )
  }
  /// First newline that ends the current line, skipping quotes and escapes.
  func lineEnd(from start: Int) -> Int? {
    var position = start
    var quote: UInt8?
    while position < bytes.count {
      let byte = bytes[position]
      if let open = quote {
        if byte == 92 && open == 34 {
          position += 1
        } else if byte == open {
          quote = nil
        }
      } else if byte == 92 {
        position += 1
      } else if byte == 39 || byte == 34 {
        quote = byte
      } else if byte == 35, position > 0,
        [32, 9, 13, 10, 59, 38, 124, 40].contains(bytes[position - 1])
      {
        while position < bytes.count, bytes[position] != 10 { position += 1 }
        continue
      } else if byte == 10 {
        return position
      }
      position += 1
    }
    return nil
  }
  /// `<<word` or `<<-word`, with the cursor after the operator. The body starts
  /// after the current line; a quoted delimiter makes it literal.
  mutating func heredoc(descriptor: Int32, at operation: Int) throws -> Redirect
  {
    let strip = current == 45
    if strip { index += 1 }
    spaces()
    guard let first = current, !isBoundary(first) else {
      throw fail("expected heredoc delimiter", incomplete: current == nil)
    }
    let start = index
    let marker = try word()
    var delimiter: [UInt8] = []
    for part in marker.parts {
      guard case .literal(let bytes) = part else {
        index = start
        throw fail("heredoc delimiter must be literal")
      }
      delimiter.append(contentsOf: bytes)
    }
    let literal = bytes[start ..< index].contains { [39, 34, 92].contains($0) }
    guard !delimiter.isEmpty, !delimiter.contains(10) else {
      index = start
      throw fail("heredoc delimiter must be a non-empty single line")
    }
    guard let end = lineEnd(from: index) else {
      throw fail("expected heredoc body", incomplete: true)
    }
    var position = heredocSkips[end] ?? end + 1
    let bodyStart = position
    var body: [UInt8] = []
    while true {
      guard position < bytes.count else {
        index = bytes.count
        throw fail("unterminated heredoc", incomplete: true)
      }
      var stop = position
      while stop < bytes.count, bytes[stop] != 10 { stop += 1 }
      var line = bytes[position ..< stop]
      if strip { line = line.drop(while: { $0 == 9 }) }
      position = min(stop + 1, bytes.count)
      if Array(line) == delimiter { break }
      body.append(contentsOf: line)
      body.append(10)
    }
    heredocSkips[end] = position
    heredocs.append((operation, position))
    var parts: [Word.Part] = [.literal(body)]
    if !literal {
      var inner = Cursor(bytes: body)
      inner.depth = depth
      parts = []
      do {
        while let byte = inner.current {
          if byte == 36 {
            try inner.expansion(into: &parts)
          } else if byte == 92, let next = inner.peek(),
            [36, 92, 10].contains(next)
          {
            if next != 10 { parts.append(.literal([next])) }
            inner.index += 2
          } else {
            parts.append(.literal([byte]))
            inner.index += 1
          }
        }
      } catch let failure as ParseFailure {
        throw ParseFailure(
          diagnostic: ShellDiagnostic(
            offset: bodyStart + (strip ? 0 : failure.diagnostic.offset),
            message: "heredoc body: \(failure.diagnostic.message)"
          ),
          incomplete: false
        )
      }
    }
    return Redirect(
      descriptor: descriptor,
      operation: .heredoc,
      target: Word(range: bodyStart ..< position, parts: parts)
    )
  }
  /// A worker reparses compound source, so its heredoc bodies must be inside.
  func containHeredocs(from start: Int) throws {
    if heredocs.contains(where: { $0.operation >= start && $0.end > index }) {
      throw fail("a heredoc body must end inside its compound command")
    }
  }
  /// `if`, `while`, `until`, and `for`, with the cursor on the keyword.
  mutating func controlFlow(_ kind: String) throws -> Compound {
    guard depth < 16 else { throw fail("syntax nesting limit exceeded") }
    let start = index
    index += kind.utf8.count
    func source(_ cursor: Cursor) throws -> [UInt8] {
      try cursor.containHeredocs(from: start)
      return Array(cursor.bytes[start ..< cursor.index])
    }
    switch kind {
    case "case":
      spaces()
      guard let byte = current, !isBoundary(byte) else {
        throw fail("expected case word", incomplete: current == nil)
      }
      let subject = try word()
      newlines()
      try expect("in")
      var clauses: [Compound.Clause] = []
      while true {
        newlines()
        if keyword() == "esac" { break }
        if current == 40 { index += 1 }
        var patterns: [Word] = []
        while true {
          spaces()
          guard let byte = current, !isBoundary(byte) else {
            throw fail("expected case pattern", incomplete: current == nil)
          }
          patterns.append(try word())
          spaces()
          guard current == 124 else { break }
          index += 1
        }
        guard current == 41 else {
          throw fail(
            "expected ')' after case pattern",
            incomplete: current == nil
          )
        }
        index += 1
        let body = try program(terminators: ["esac"], clause: true)
        clauses.append(Compound.Clause(patterns: patterns, body: body))
        if current == 59 && peek() == 59 { index += 2 }
      }
      try expect("esac")
      return .select(subject, clauses, source: try source(self))
    case "if":
      var branches: [Compound.Branch] = []
      var otherwise: Program?
      while true {
        let condition = try list(["then"])
        try expect("then")
        let body = try list(["elif", "else", "fi"])
        branches.append(Compound.Branch(condition: condition, body: body))
        if keyword() == "elif" {
          index += 4
          continue
        }
        if keyword() == "else" {
          index += 4
          otherwise = try list(["fi"])
        }
        try expect("fi")
        break
      }
      return .conditional(
        branches,
        otherwise: otherwise,
        source: try source(self)
      )
    case "for":
      spaces()
      let nameStart = index
      while let byte = current,
        isNameStart(byte) || (index > nameStart && (48 ... 57).contains(byte))
      { index += 1 }
      guard index > nameStart else {
        throw fail("expected loop variable name", incomplete: current == nil)
      }
      let name = String(decoding: bytes[nameStart ..< index], as: UTF8.self)
      spaces()
      try expect("in")
      var words: [Word] = []
      while true {
        spaces()
        guard let byte = current else {
          throw fail("expected 'do'", incomplete: true)
        }
        if byte == 59 || byte == 10 { break }
        guard !isBoundary(byte) else { throw fail("expected loop word") }
        words.append(try word())
      }
      if current == 59 { index += 1 }
      newlines()
      try expect("do")
      let body = try list(["done"])
      try expect("done")
      return .forEach(
        name: name,
        words: words,
        body: body,
        source: try source(self)
      )
    default:
      let condition = try list(["do"])
      try expect("do")
      let body = try list(["done"])
      try expect("done")
      return .loop(
        until: kind == "until",
        condition: condition,
        body: body,
        source: try source(self)
      )
    }
  }
  mutating func body(open: UInt8, close: UInt8) throws -> [UInt8] {
    precondition(current == open)
    index += 1
    let start = index
    _ = try program(until: close)
    guard current == close else {
      throw fail("unterminated compound command", incomplete: true)
    }
    try containHeredocs(from: start)
    let source = Array(bytes[start ..< index])
    index += 1
    return source
  }
  func isNameStart(_ byte: UInt8) -> Bool {
    byte == 95 || (65 ... 90).contains(byte) || (97 ... 122).contains(byte)
  }
}
