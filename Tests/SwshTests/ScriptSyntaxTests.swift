import Testing
@testable import Swsh

/// Arithmetic assignment, bracket patterns, `shift`, and positional
/// parameters, checked without launching a process.
@Suite
struct ScriptSyntaxTests {
  private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

  private func program(_ source: String) throws -> Program {
    guard case .complete(let program) = Parser().parse(source) else {
      throw ShellDiagnostic(offset: 0, message: "did not parse: \(source)")
    }
    return program
  }

  private func arguments(
    _ source: String,
    state: ShellState = ShellState()
  ) throws -> [String] {
    try Expander(state: state)
      .prepare(try program(source).commands[0].pipeline[0]).arguments
      .map { String(decoding: $0, as: UTF8.self) }
  }

  /// Variables for one expression; unset names read as 0.
  private final class Store: Arithmetic.Values {
    var scalars: [String: Int64] = ["n": 5]
    var lists: [String: [Int64]] = ["list": [10, 20]]
    func integer(_ name: String) -> Int64 { scalars[name] ?? 0 }
    func integer(_ name: String, at index: Int64) throws -> Int64 {
      guard let list = lists[name], list.indices.contains(Int(index)) else {
        throw Arithmetic.Failure(message: "index out of range")
      }
      return list[Int(index)]
    }
    func count(_ name: String) -> Int64 { Int64(lists[name]?.count ?? 0) }
    func assign(_ name: String, at index: Int64?, _ value: Int64) {
      if let index {
        lists[name]![Int(index)] = value
      } else {
        scalars[name] = value
      }
    }
  }

  @Test(
    arguments: [
      ("n = 7", 7, 7), ("n += 2", 7, 7), ("n -= 2", 3, 3), ("n *= 3", 15, 15),
      ("n /= 2", 2, 2), ("n %= 3", 2, 2), ("n <<= 2", 20, 20),
      ("n >>= 1", 2, 2), ("n &= 4", 4, 4), ("n |= 2", 7, 7), ("n ^= 1", 4, 4),
      ("n++", 5, 6), ("n--", 5, 4), ("++n", 6, 6), ("--n", 4, 4),
      ("n++ + n", 11, 6), ("n-- - -n", 9, 4), ("n - -n", 10, 5),
      ("n+++n", 11, 6), ("a = n = 2", 2, 2), ("(n = 2) + n", 4, 2),
      ("n == 5 ? n = 1 : (n = 2)", 1, 1), ("n = 1, n + 1", 2, 1),
      ("0 && (n = 9)", 0, 5), ("1 || n++", 1, 5), ("n = n == 5", 1, 1),
      ("n <= 5", 1, 5), ("n != 5", 0, 5), ("n ++", 5, 6), ("- -n", 5, 5),
    ] as [(String, Int, Int)]
  )
  func arithmeticAssignment(_ source: String, _ value: Int, _ n: Int) throws {
    let store = Store()
    let parsed = try Arithmetic.parse(bytes(source))
    #expect(try parsed.evaluate(store) == Int64(value))
    #expect(store.scalars["n"] == Int64(n))
  }

  @Test
  func arithmeticAssignsElementsAndReportsMutation() throws {
    let store = Store()
    #expect(try Arithmetic.parse(bytes("list[1] += n")).evaluate(store) == 25)
    #expect(try Arithmetic.parse(bytes("list[n - 5]++")).evaluate(store) == 10)
    #expect(
      try Arithmetic.parse(bytes("--list[list[0] - 11]")).evaluate(store) == 10
    )
    #expect(store.lists["list"] == [10, 25])
    #expect(try Arithmetic.parse(bytes("list[0] = 1")).mutates)
    #expect(try Arithmetic.parse(bytes("list[n++]")).mutates)
    #expect(try Arithmetic.parse(bytes("1 ? 2 : (n = 3)")).mutates)
    #expect(try !Arithmetic.parse(bytes("n == 5 && list[1] <= 3")).mutates)
    for source in [
      "5 = 1", "n + 1 = 2", "$n = 1", "n = ", "= 1", "n++ ++", "++5 = 1",
      "n =+= 1", "${n}++", "1,", ", 1", "list[0 = 1",
    ] {
      #expect(throws: Arithmetic.Failure.self, "\(source)") {
        try Arithmetic.parse(bytes(source))
      }
    }
    // Deep chains are rejected instead of exhausting the stack.
    #expect(throws: Arithmetic.Failure.self) {
      try Arithmetic.parse(bytes(String(repeating: "n = ", count: 100) + "1"))
    }
  }

  @Test
  func pureExpansionRejectsAssignmentButKeepsReads() throws {
    let state = ShellState(variables: ["n": bytes("5")])
    #expect(
      try arguments("x $((n + 1)) $((n == 5))", state: state) == [
        "x", "6", "1",
      ]
    )
    for source in ["x $((n = 1))", "x $((n++))", "x $((m += 1))"] {
      #expect(throws: ShellDiagnostic.self, "\(source)") {
        try arguments(source, state: state)
      }
    }
    #expect(
      SessionDriver.mutates(
        try program("x $((n++))").commands[0].pipeline[0].words[1].parts
      )
    )
    #expect(
      SessionDriver.mutates(
        try program("x ${a:-${b:=c}}").commands[0].pipeline[0].words[1].parts
      )
    )
    #expect(
      !SessionDriver.mutates(
        try program("x $((n + 1)) ${a:-b}").commands[0].pipeline[0].words[1]
          .parts
      )
    )
  }

  @Test
  func bracketExpressionsAreParts() throws {
    func parts(_ source: String) throws -> [Word.Part] {
      try program("x \(source)").commands[0].pipeline[0].words[1].parts
    }
    #expect(try parts("[ab]") == [.bracket(bytes("[ab]"))])
    #expect(
      try parts("a[!0-9]*") == [
        .literal(bytes("a")), .bracket(bytes("[!0-9]")), .wildcard(42),
      ]
    )
    #expect(try parts("[]a]") == [.bracket(bytes("[]a]"))])
    #expect(try parts("[!]]") == [.bracket(bytes("[!]]"))])
    #expect(try parts("[a^]") == [.bracket(bytes("[a^]"))])
    #expect(try parts("[[:alpha:]_]") == [.bracket(bytes("[[:alpha:]_]"))])
    #expect(try parts("[*?]") == [.bracket(bytes("[*?]"))])
    // Without a closing bracket in the word, both characters are literal.
    #expect(try parts("[") == [.literal(bytes("["))])
    #expect(try parts("]") == [.literal(bytes("]"))])
    #expect(
      try parts("a[b") == [
        .literal(bytes("a")), .literal(bytes("[")), .literal(bytes("b")),
      ]
    )
    #expect(
      try parts("[!]") == [
        .literal(bytes("[")), .literal(bytes("!")), .literal(bytes("]")),
      ]
    )
    #expect(try parts("\"[ab]\"").contains(.bracket(bytes("[ab]"))) == false)
    let commands = try program("[ -f x ] && echo [a;b]")
    #expect(commands.commands[0].pipeline[0].words.count == 4)
    for source in [
      "x [$v]", "x [a\"b\"]", "x [a\\]]", "x ['a']", "x [a$(b)]", "x [^a]",
    ] {
      guard case .invalid = Parser().parse(source) else {
        Issue.record("expected invalid: \(source)")
        continue
      }
    }
  }

  @Test
  func bracketsArePatternsOnlyWhenWritten() throws {
    let state = ShellState(variables: ["v": bytes("[ab]")])
    let word = try program("x $v[c-d]\"[e]\"").commands[0].pipeline[0].words[1]
    let expanded = try Expander(state: state).scalar(word)
    #expect(expanded.hasPattern)
    #expect(expanded.bytes == bytes("[ab][c-d][e]"))
    #expect(expanded.pattern == bytes("\\[ab\\][c-d]\\[e\\]"))
    #expect(
      try arguments("x [ ] a[ $v", state: state) == [
        "x", "[", "]", "a[", "[ab]",
      ]
    )
    #expect(throws: ShellDiagnostic.self) {
      try arguments("x /nonexistent-swsh/[ab]", state: state)
    }
    #expect(throws: ShellDiagnostic.self) {
      try arguments("x /[[:alpha:]]*", state: state)
    }
    #expect(try arguments("x /[d]ev /de[!x]") == ["x", "/dev", "/dev"])
  }

  @Test
  func shiftAndUnsetPositionalParameters() throws {
    var state = ShellState()
    var directory = try WorkingDirectory()
    let io = BuiltinIO(output: -1, error: -1)
    func shift(_ count: String?) -> EvaluationControl {
      BuiltinEvaluator()
        .run(
          .shift,
          arguments: count.map { [bytes($0)] } ?? [],
          state: &state,
          directory: &directory,
          io: io
        )
    }
    state.setArguments((1 ... 11).map { bytes("p\($0)") })
    #expect(shift(nil) == .continuing(0))
    #expect(
      try arguments("x $1 $9 $#", state: state) == ["x", "p2", "p10", "10"]
    )
    #expect(shift("8") == .continuing(0))
    #expect(
      try arguments("x $@ ${3-unset} $#", state: state) == [
        "x", "p10", "p11", "unset", "2",
      ]
    )
    for count in ["3", "-1", "x", ""] {
      #expect(shift(count) == .continuing(2), "\(count)")
    }
    #expect(shift("0") == .continuing(0))
    #expect(shift("2") == .continuing(0))
    #expect(state.arrays["@"] == [])
    #expect(shift(nil) == .continuing(2))
    state.options.nounset = true
    #expect(throws: ShellDiagnostic.self) {
      try arguments("x $1", state: state)
    }
    #expect(
      try arguments("x $# ${1:-none}", state: state) == ["x", "0", "none"]
    )
    #expect(!BuiltinWorkerContext.supports(.shift))
    #expect(!BuiltinWorkerContext.supports(.local))
  }

  @Test(arguments: [
    "f() { local a=1 b; shift 2; }", "echo $((i++)) $((x = y = 2))", "a[i++]=x",
    "case $x in [a-c]*|[!x]) ;; esac", "echo [ab] ] [", "[ -n x ]", "echo a]b",
  ])
  func complete(_ source: String) {
    guard case .complete = Parser().parse(source) else {
      Issue.record("expected complete: \(source)")
      return
    }
  }
}
