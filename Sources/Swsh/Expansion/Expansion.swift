#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Runtime values are bytes. UTF-8 validation applies to source, not Unix data.
public struct ShellState: Equatable, Codable, Sendable {
  public var variables: [String: [UInt8]]
  public var exported: Set<String>
  var executionDepth = 0
  var functions: [String: [UInt8]] = [:]
  var completionFunctions: [String: String] = [:]
  var completions: [String: [[UInt8]]] = [:]
  /// Indexed lists. A name is a scalar or a list, never both.
  var arrays: [String: [[UInt8]]] = [:]
  var options = ShellOptions()
  /// `$$`. Workers keep the value of the shell that started them.
  var processID: Int32 = 0
  public var status: Int32
  // Entries with non-UTF-8 names cannot be addressed by source identifiers,
  // but must survive inheritance without decoding/re-encoding their bytes.
  var opaqueEnvironment: [[UInt8]] = []

  public init(
    variables: [String: [UInt8]] = [:],
    exported: Set<String> = [],
    status: Int32 = 0
  ) {
    self.variables = variables
    self.exported = exported
    self.status = status
  }
}

/// `set` policies. Workers inherit them with the rest of the snapshot.
struct ShellOptions: Equatable, Codable, Sendable {
  /// `-e`: a failed command outside a condition exits the shell.
  var errexit = false
  /// `-u`: expanding an unset name is an error.
  var nounset = false
  /// `-o pipefail`: a pipeline reports its last failing stage.
  var pipefail = false

  static let names = ["errexit", "nounset", "pipefail"]

  subscript(name: String) -> Bool? {
    get {
      switch name {
      case "errexit": errexit
      case "nounset": nounset
      case "pipefail": pipefail
      default: nil
      }
    }
    set {
      guard let newValue else { return }
      switch name {
      case "errexit": errexit = newValue
      case "nounset": nounset = newValue
      case "pipefail": pipefail = newValue
      default: break
      }
    }
  }
}

struct ExpandedWord: Equatable {
  let bytes: [UInt8]
  let pattern: [UInt8]
  let hasPattern: Bool
}

struct Expander {
  let state: ShellState

  func scalar(_ word: Word) throws -> ExpandedWord {
    var bytes: [UInt8] = []
    var pattern: [UInt8] = []
    var hasPattern = false
    for part in word.parts {
      let value: [UInt8]
      switch part {
      case .literal(let literal): value = literal
      case .variable(let name): value = try variable(name, in: word)
      case .arithmetic(let source):
        value = Array(String(try integer(source, in: word)).utf8)
      case .element(let name, let source):
        value = try element(name, at: try integer(source, in: word), in: word)
      case .count(let name):
        value = Array(String(try list(name, in: word).count).utf8)
      case .list(let name):
        throw failure(
          name == "@"
            ? "$@ must be a whole word" : "${name[@]} must be a whole word",
          in: word
        )
      case .processID: value = Array(String(state.processID).utf8)
      case .length(let name):
        value = Array(String(try variable(name, in: word).count).utf8)
      case .parameter(let name, let operation, let colon, let operand):
        let current = try usable(name, colon: colon, in: word)
        func alternative() throws -> [UInt8] {
          try scalar(Word(range: word.range, parts: operand)).bytes
        }
        switch operation {
        case .useDefault: value = try current ?? alternative()
        case .alternate: value = current == nil ? [] : try alternative()
        case .assign:
          guard let current else {
            throw failure(
              "${\(name)=word} requires the execution driver",
              in: word
            )
          }
          value = current
        case .fail:
          guard let current else {
            let message = String(decoding: try alternative(), as: UTF8.self)
            throw failure(
              "\(name): "
                + (message.isEmpty ? "parameter is unset or empty" : message),
              in: word
            )
          }
          value = current
        }
      case .substitution:
        throw ShellDiagnostic(
          offset: word.range.lowerBound,
          message: "command substitution requires the execution driver"
        )
      case .status: value = Array(String(state.status).utf8)
      case .wildcard(let wildcard):
        bytes.append(wildcard)
        pattern.append(wildcard)
        hasPattern = true
        continue
      case .bracket(let expression):
        bytes.append(contentsOf: expression)
        pattern.append(contentsOf: expression)
        hasPattern = true
        continue
      }
      bytes.append(contentsOf: value)
      for byte in value {
        // glob(3) must not interpret syntax contributed by scalar values.
        if [92, 42, 63, 91, 93].contains(byte) { pattern.append(92) }
        pattern.append(byte)
      }
    }
    guard !bytes.contains(0) else {
      throw ShellDiagnostic(
        offset: word.range.lowerBound,
        message: "NUL in expanded argument"
      )
    }
    return ExpandedWord(bytes: bytes, pattern: pattern, hasPattern: hasPattern)
  }

  func failure(_ message: String, in word: Word) -> ShellDiagnostic {
    ShellDiagnostic(offset: word.range.lowerBound, message: message)
  }

  /// The value `${name-word}` keeps: nil when unset, or empty with `colon`.
  func usable(_ name: String, colon: Bool, in word: Word) throws -> [UInt8]? {
    guard state.arrays[name] == nil else {
      throw failure("\(name) is a list", in: word)
    }
    guard let value = state.variables[name], !(colon && value.isEmpty) else {
      return nil
    }
    return value
  }

  func variable(_ name: String, in word: Word) throws -> [UInt8] {
    if let value = state.variables[name] { return value }
    guard state.arrays[name] == nil else {
      throw failure(
        "\(name) is a list; use ${\(name)[@]} or ${\(name)[index]}",
        in: word
      )
    }
    guard !state.options.nounset else {
      throw failure("\(name): unset variable", in: word)
    }
    return []
  }

  func list(_ name: String, in word: Word) throws -> [[UInt8]] {
    if let values = state.arrays[name] { return values }
    // No positional parameters is an empty list, not an unset name.
    if name == "@" { return [] }
    guard state.variables[name] == nil else {
      throw failure("\(name) is not a list", in: word)
    }
    guard !state.options.nounset else {
      throw failure("\(name): unset variable", in: word)
    }
    return []
  }

  func element(_ name: String, at index: Int64, in word: Word) throws -> [UInt8]
  {
    let values = try list(name, in: word)
    guard index >= 0, index < Int64(values.count) else {
      throw failure("\(name)[\(index)]: index out of range", in: word)
    }
    return values[Int(index)]
  }

  func integer(_ source: [UInt8], in word: Word) throws -> Int64 {
    try Self.integer(source, in: word, current: { self }, store: nil)
  }

  /// `current` supplies the state for each read, so an expression sees its own
  /// assignments. Without `store`, an assignment is an error.
  static func integer(
    _ source: [UInt8],
    in word: Word,
    current: @escaping () -> Expander,
    store: ((String, Int64?, Int64) throws -> Void)?
  ) throws -> Int64 {
    struct Values: Arithmetic.Values {
      let current: () -> Expander
      let word: Word
      let store: ((String, Int64?, Int64) throws -> Void)?
      func integer(_ name: String) throws -> Int64 {
        try number(current().variable(name, in: word), name)
      }
      func integer(_ name: String, at index: Int64) throws -> Int64 {
        try number(current().element(name, at: index, in: word), name)
      }
      func count(_ name: String) throws -> Int64 {
        Int64(try current().list(name, in: word).count)
      }
      func assign(_ name: String, at index: Int64?, _ value: Int64) throws {
        guard let store else {
          throw current()
            .failure(
              "arithmetic assignment requires the execution driver",
              in: word
            )
        }
        try store(name, index, value)
      }
      func number(_ bytes: [UInt8], _ name: String) throws -> Int64 {
        guard let value = Arithmetic.integer(bytes) else {
          throw current().failure("\(name): not an integer", in: word)
        }
        return value
      }
    }
    do {
      return try Arithmetic.parse(source)
        .evaluate(Values(current: current, word: word, store: store))
    } catch let error as Arithmetic.Failure {
      throw current().failure(error.message, in: word)
    }
  }

  func paths(_ word: Word) throws -> [[UInt8]] {
    let parts = word.parts.filter { $0 != .literal([]) }
    if parts.count == 1, case .list(let name) = parts[0] {
      return try list(name, in: word)
    }
    let expanded = try scalar(word)
    guard expanded.hasPattern else { return [expanded.bytes] }
    for case .bracket(let expression) in parts
    where zip(expression, expression.dropFirst())
      .contains(where: { $0 == 91 && $1 == 58 })
    {
      // glob(3) on macOS matches `[:class:]` as ordinary members.
      throw failure(
        "character classes are supported in case patterns only",
        in: word
      )
    }
    var matches = glob_t()
    let result = (expanded.pattern + [0])
      .withUnsafeBytes { buffer in
        glob(
          buffer.baseAddress!.assumingMemoryBound(to: CChar.self),
          GLOB_NOSORT,
          nil,
          &matches
        )
      }
    defer { globfree(&matches) }
    guard result == 0, let paths = matches.gl_pathv else {
      throw ShellDiagnostic(
        offset: word.range.lowerBound,
        message: result == GLOB_NOMATCH
          ? "pattern has no matches" : "pathname expansion failed"
      )
    }
    return (0 ..< Int(matches.gl_pathc))
      .map { index in
        let path = paths[index]!
        return Array(UnsafeRawBufferPointer(start: path, count: strlen(path)))
      }
      .sorted { $0.lexicographicallyPrecedes($1) }
  }

  func redirectPath(_ word: Word) throws -> [UInt8] {
    let expanded = try paths(word)
    guard expanded.count == 1 else {
      throw ShellDiagnostic(
        offset: word.range.lowerBound,
        message: "redirect requires exactly one path"
      )
    }
    return expanded[0]
  }
}
