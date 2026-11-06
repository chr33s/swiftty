/// Diagnostics always address byte offsets in the original UTF-8 source.
public struct ShellDiagnostic: Error, Equatable, Sendable {
  public let offset: Int
  public let message: String
}

public enum ParseResult: Equatable, Sendable {
  case complete(Program)
  case incomplete(ShellDiagnostic)
  case invalid(ShellDiagnostic)
}

public struct Program: Equatable, Sendable {
  public let source: [UInt8]
  public let commands: [CommandListEntry]
}

public struct CommandListEntry: Equatable, Sendable {
  public enum Condition: Equatable, Sendable { case always, success, failure }
  public let condition: Condition
  public let pipeline: [SimpleCommand]
  public let background: Bool
  /// `! pipeline` inverts the status and is exempt from `set -e`.
  var negated = false
}

public struct SimpleCommand: Equatable, Sendable {
  public let assignments: [Assignment]
  public let words: [Word]
  public let redirects: [Redirect]
  var compound: Compound? = nil
}

enum Compound: Equatable, Sendable {
  case function(String, [UInt8])
  case subshell([UInt8])
  /// Control flow keeps parsed lists for evaluation in the current shell and
  /// its exact source for a pipeline, background, or redirected worker.
  case conditional([Branch], otherwise: Program?, source: [UInt8])
  case loop(until: Bool, condition: Program, body: Program, source: [UInt8])
  case forEach(name: String, words: [Word], body: Program, source: [UInt8])
  /// `{ list; }`; `source` is the list between the braces.
  case group(Program, source: [UInt8])
  /// `case word in pattern) list ;; esac`.
  case select(Word, [Clause], source: [UInt8])

  struct Branch: Equatable, Sendable {
    let condition: Program
    let body: Program
  }

  struct Clause: Equatable, Sendable {
    let patterns: [Word]
    let body: Program
  }

  /// Control flow and groups run in the current shell when they stand alone.
  var runsInParent: Bool {
    switch self {
    case .function, .subshell: false
    case .conditional, .loop, .forEach, .group, .select: true
    }
  }

  /// Source evaluated by a worker when the compound cannot run in the parent.
  var workerSource: [UInt8]? {
    switch self {
    case .function: nil
    case .subshell(let source), .conditional(_, _, let source),
      .loop(_, _, _, let source), .forEach(_, _, _, let source),
      .group(_, let source), .select(_, _, let source):
      source
    }
  }
}

public struct Assignment: Equatable, Sendable {
  public let name: String
  public let value: Word
  /// `name=(words)` or `name+=(words)`; `value` is then empty.
  var elements: [Word]? = nil
  /// Arithmetic source of `name[index]=value`.
  var index: [UInt8]? = nil
  /// `name+=value` or `name+=(words)`.
  var append = false
}

public struct Word: Equatable, Sendable {
  public enum Part: Equatable, Sendable {
    case literal([UInt8])
    case variable(String)
    case substitution([UInt8])
    case status
    case wildcard(UInt8)
    /// An unquoted bracket expression such as `[a-z]` or `[!0-9]`, kept as
    /// written for pathname expansion and `case` patterns.
    case bracket([UInt8])
    /// `$(( expression ))`, retaining the exact expression source.
    case arithmetic([UInt8])
    /// `${name[index]}` with an arithmetic index.
    case element(String, [UInt8])
    /// `${name[@]}`: every element as its own argument.
    case list(String)
    /// `${#name[@]}`.
    case count(String)
    /// `$$`: the process ID of the session's shell, also inside workers.
    case processID
    /// `${#name}`: the value's length in bytes.
    case length(String)
    /// `${name-word}`, `=`, `?`, `+`, and their `:` forms that also treat an
    /// empty value as unset.
    case parameter(String, ParameterOperation, colon: Bool, [Part])
  }
  public enum ParameterOperation: Equatable, Sendable {
    case useDefault, assign, fail, alternate
  }
  public let range: Range<Int>
  public let parts: [Part]
}

public struct Redirect: Equatable, Sendable {
  public enum Operation: Equatable, Sendable {
    case read, write, append, duplicateInput, duplicateOutput
    /// `<<` and `<<-`: `target` holds the body, not a path.
    case heredoc
  }
  public let descriptor: Int32
  public let operation: Operation
  public let target: Word
}
