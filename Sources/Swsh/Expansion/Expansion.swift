import Darwin

/// Runtime values are bytes. UTF-8 validation applies to source, not Unix data.
public struct ShellState: Equatable, Codable, Sendable {
  public var variables: [String: [UInt8]]
  public var exported: Set<String>
  var executionDepth = 0
  var functions: [String: [UInt8]] = [:]
  var completionFunctions: [String: String] = [:]
  var completions: [String: [[UInt8]]] = [:]
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
      case .variable(let name): value = state.variables[name] ?? []
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

  func paths(_ word: Word) throws -> [[UInt8]] {
    let expanded = try scalar(word)
    guard expanded.hasPattern else { return [expanded.bytes] }
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
