import Testing
@testable import Swsh

/// `case`, brace groups, `$@`, `$$`, and parameter operators, checked without
/// launching a process.
@Suite
struct ParameterSyntaxTests {
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

  @Test(arguments: [
    "case x in", "case x in a)", "case x in a) echo", "case x in a) echo ;;",
    "case x", "{ echo", "{ echo;", "echo ${x:-", "echo ${x:-'a", "echo ${x:",
    "echo \"${x:-a", "case",
  ])
  func incomplete(_ source: String) {
    guard case .incomplete = Parser().parse(source) else {
      Issue.record("expected incomplete: \(source)")
      return
    }
  }

  @Test(arguments: [
    "case x in esac", "case x in a) esac", "case x in a) ;; esac",
    "case $x in a|b) echo;; (c) echo; echo\n;;\n*) echo\nesac",
    "case x\nin\na) echo ;;\nesac | cat", "case x in a) echo & ;; esac",
    "{ echo; }", "{ echo }", "{\necho\n} > out", "{ { echo; }; } | cat",
    "f() { { echo; }; case x in x) return;; esac; }",
    "echo $$ $@ \"$@\" ${@} ${1} ${1:-x} ${#x} ${#1}",
    "echo ${x-} ${x:=a b} ${x:?} ${x+'}'} ${x:-${y:-$(echo z)}} ${x:-\\}}",
    "echo ${x:-\"a } b\"} ${x:-$((1 + 2))} ${x:-*?}",
    "while true; do break 2; continue 1; done", "echo esac case in",
  ])
  func complete(_ source: String) {
    guard case .complete = Parser().parse(source) else {
      Issue.record("expected complete: \(source)")
      return
    }
  }

  @Test(arguments: [
    "esac", "case x in a) echo ;; ;; esac", "case x in ) echo ;; esac",
    "case x in a b) echo ;; esac", "case x in a) echo ;; esac extra",
    "case in a) echo ;; esac", "case x of a) echo ;; esac", "}", "{ }",
    "{ echo; } extra", "echo ${x:x}", "echo ${x:}", "echo ${1:=x}",
    "echo ${x:-a}b}", "echo ${#x:-a}", "echo ${@:-a}", "echo ${12}",
    "echo ${x%y}", "echo ;; pwd",
  ])
  func invalid(_ source: String) {
    guard case .invalid = Parser().parse(source) else {
      Issue.record("expected invalid: \(source)")
      return
    }
  }

  @Test
  func parameterOperatorsSelectByUnsetAndEmpty() throws {
    var state = ShellState(variables: [
      "set": bytes("v"), "empty": [], "glob": bytes("*"),
    ])
    state.arrays["list"] = [bytes("a")]
    #expect(
      try arguments(
        "x ${unset-d} ${unset:-d} =${empty-d}= ${empty:-d} ${set-d} ${set:-d}",
        state: state
      ) == ["x", "d", "d", "==", "d", "v", "v"]
    )
    #expect(
      try arguments(
        "x =${unset+a}= =${unset:+a}= =${empty+a}= =${empty:+a}= =${set:+a}=",
        state: state
      ) == ["x", "==", "==", "=a=", "==", "=a="]
    )
    #expect(
      try arguments("x ${set?m} ${set:?m} =${empty?m}=", state: state) == [
        "x", "v", "v", "==",
      ]
    )
    #expect(
      try arguments(
        "x ${unset:-a  b} ${unset:-'q }'} ${unset:-$set$set} ${unset:-${glob}}",
        state: state
      ) == ["x", "a  b", "q }", "vv", "*"]
    )
    // The word of an operator is a value: it is never a pattern.
    #expect(
      try arguments("x ${unset:-*} ${unset:-?}", state: state) == [
        "x", "*", "?",
      ]
    )
    #expect(
      try arguments("x ${#set} ${#empty} ${#glob} ${set:=n}", state: state) == [
        "x", "1", "0", "1", "v",
      ]
    )
    for source in [
      "x ${unset?}", "x ${unset:?m}", "x ${empty:?m}", "x ${list:-d}",
      "x ${list+a}", "x ${#list}", "x ${unset:=needs-driver}",
    ] {
      #expect(throws: ShellDiagnostic.self, "\(source)") {
        try arguments(source, state: state)
      }
    }
    do {
      _ = try arguments("x ${unset:?custom $set}", state: state)
      Issue.record("expected a diagnostic")
    } catch let error as ShellDiagnostic {
      #expect(error.message == "unset: custom v")
    }
    // Operators answer for an unset name, so `set -u` does not apply to them.
    state.options.nounset = true
    #expect(
      try arguments("x ${unset:-d} =${unset+a}=", state: state) == [
        "x", "d", "==",
      ]
    )
    #expect(throws: ShellDiagnostic.self) {
      try arguments("x ${#unset}", state: state)
    }
  }

  @Test
  func positionalListAndProcessID() throws {
    var state = ShellState()
    state.processID = 4242
    #expect(
      try arguments("x $@ \"$@\" ${@} $$ \"a$$\"", state: state) == [
        "x", "4242", "a4242",
      ]
    )
    state.setArguments([bytes("two words"), [], bytes("*")])
    #expect(
      try arguments("x $@ \"$@\" $# ${2:-empty} ${3}", state: state) == [
        "x", "two words", "", "*", "two words", "", "*", "3", "empty", "*",
      ]
    )
    for source in ["x a$@", "x \"$@ \"", "v=$@", "x >$@"] {
      #expect(throws: ShellDiagnostic.self, "\(source)") {
        try arguments(source, state: state)
      }
    }
    // No positional parameters is an empty list even under `set -u`.
    state = ShellState()
    state.options.nounset = true
    #expect(try arguments("x $@ end", state: state) == ["x", "end"])
  }

  @Test
  func caseAndGroupKeepTheirStructure() throws {
    let parsed = try program(
      "case $v in (a|\"b c\") one; two ;; *) ;; esac; { x; y; } >out"
    )
    guard
      case .select(let subject, let clauses, let source) = parsed.commands[0]
        .pipeline[0].compound
    else {
      Issue.record("expected a case command")
      return
    }
    #expect(subject.parts == [.variable("v")])
    #expect(clauses.map(\.patterns.count) == [2, 1])
    #expect(clauses.map(\.body.commands.count) == [2, 0])
    #expect(clauses[1].patterns[0].parts == [.wildcard(42)])
    #expect(source == bytes("case $v in (a|\"b c\") one; two ;; *) ;; esac"))
    let group = parsed.commands[1].pipeline[0]
    guard case .group(let body, let inner) = group.compound else {
      Issue.record("expected a group")
      return
    }
    #expect(body.commands.count == 2)
    #expect(inner == bytes(" x; y; "))
    #expect(group.redirects.count == 1)
    #expect(group.compound?.runsInParent == true)
    #expect(Compound.subshell([]).runsInParent == false)
    #expect(!BuiltinWorkerContext.supports(.read))
  }
}
