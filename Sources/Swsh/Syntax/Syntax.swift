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
}

public struct Assignment: Equatable, Sendable {
  public let name: String
  public let value: Word
}

public struct Word: Equatable, Sendable {
  public enum Part: Equatable, Sendable {
    case literal([UInt8])
    case variable(String)
    case substitution([UInt8])
    case status
    case wildcard(UInt8)
  }
  public let range: Range<Int>
  public let parts: [Part]
}

public struct Redirect: Equatable, Sendable {
  public enum Operation: Equatable, Sendable {
    case read, write, append, duplicateInput, duplicateOutput
  }
  public let descriptor: Int32
  public let operation: Operation
  public let target: Word
}
