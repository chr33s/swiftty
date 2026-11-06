#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Testing
@testable import Swsh

/// Arithmetic, heredocs, lists, control flow, and `set` policies, checked
/// without launching a process.
@Suite
struct LanguageGrowthSyntaxTests {
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

  @Test(
    arguments: [
      ("1 + 2 * 3", 7), ("(1 + 2) * 3", 9), ("-7 / 2", -3), ("-7 % 2", -1),
      ("1 << 4 | 1", 17), ("6 & 3 ^ 1", 3), ("2 < 3 == 1", 1), ("!0 + ~0", 0),
      ("0 && 1 / 0", 0), ("1 || 1 / 0", 1), ("0 ? 1 / 0 : 5", 5),
      ("0x1f + 010", 41), ("n * n", 25), ("$n + ${n}", 10), ("unset + 1", 1),
      ("list[1] + ${list[0]}", 30), ("${#list[@]} - $((n - 3))", 0),
      ("1 <= 1 && 2 >= 3", 0), ("3 != 3", 0), ("- - 4", 4),
    ] as [(String, Int)]
  )
  func arithmeticValues(_ source: String, _ expected: Int) throws {
    var state = ShellState(variables: ["n": bytes("5")])
    state.arrays["list"] = [bytes("10"), bytes("20")]
    #expect(
      try arguments("echo $((\(source)))", state: state) == [
        "echo", String(expected),
      ]
    )
  }

  @Test(arguments: [
    "1 / 0", "1 % 0", "9223372036854775807 + 1", "-9223372036854775807 - 2",
    "1 << 64", "word + 1", "list[2]", "list + 1", "99999999999999999999",
  ])
  func arithmeticFailuresAreDiagnostics(_ source: String) throws {
    var state = ShellState(variables: ["word": bytes("abc")])
    state.arrays["list"] = [bytes("10"), bytes("20")]
    let parsed = Parser().parse("echo $((\(source)))")
    guard case .complete = parsed else {
      // An unrepresentable literal is rejected before anything runs.
      guard case .invalid = parsed else {
        Issue.record("expected a diagnostic: \(source)")
        return
      }
      return
    }
    #expect(throws: ShellDiagnostic.self) {
      try arguments("echo $((\(source)))", state: state)
    }
  }

  @Test(arguments: [
    "echo $((1 +))", "echo $((1 2))", "echo $(( ))", "echo $((1 ? 2))",
    "echo $((1[1))", "echo ${a[\n}", "a[@]=1", "a[0]=(1)", "cat << ;",
    "cat <<$x\n$x\n", "then", "if true; fi", "if true; then fi",
    "while true; done", "for 1 in a; do :; done", "for x; do :; done",
    "if true; then cat <<E; fi\nx\nE", "(cat <<E)\nx\nE",
    "if true; then :; fi extra", "echo $((1)) )",
  ])
  func invalid(_ source: String) {
    guard case .invalid = Parser().parse(source) else {
      Issue.record("expected invalid: \(source)")
      return
    }
  }

  @Test(arguments: [
    "if true; then echo; fi", "if a; then b; elif c; then d; else e; fi",
    "if a\nthen b\nfi", "while a; do b; done", "until a\ndo\nb\ndone",
    "for x in a b; do echo $x; done", "for x in\ndo :; done",
    "for x in ${a[@]}; do :; done | cat", "! true", "! a | b && c",
    "if true; then cat <<E\nx\nE\nfi", "f() { while true; do break; done; }",
    "a=(1 2) b=() c+=(3) d+=x e[0]=y", "a=(\n1 # note\n2\n)",
    "echo fi done then", "cat <<A <<B\na\nA\nb\nB\necho after",
    "cat <<'E' # tail 'quote\nx\nE", "cat <<'E' |# tail 'quote\nx\nE\ncat",
    "echo 'a\nb' <<E\nx\nE",
  ])
  func complete(_ source: String) {
    guard case .complete = Parser().parse(source) else {
      Issue.record("expected complete: \(source)")
      return
    }
  }

  @Test
  func heredocBodiesExpandUnlessTheDelimiterIsQuoted() throws {
    let state = ShellState(variables: ["n": bytes("5")])
    func body(_ source: String) throws -> String {
      let prepared = try Expander(state: state)
        .prepare(try program(source).commands[0].pipeline[0])
      guard case .data(let descriptor, let data) = prepared.redirects[0] else {
        throw ShellDiagnostic(offset: 0, message: "not a heredoc")
      }
      #expect(descriptor == (source.hasPrefix("cat 3") ? 3 : 0))
      return String(decoding: data, as: UTF8.self)
    }
    #expect(
      try body("cat <<E\n$n $((n + 1)) \\$n \\\\ a\\\nb\nE") == "5 6 $n \\ ab\n"
    )
    #expect(try body("cat <<'E'\n$n \\$n\nE\n") == "$n \\$n\n")
    #expect(try body("cat <<\\E\n$n\nE") == "$n\n")
    #expect(try body("cat <<-E\n\t\tone\n\ttwo \t\n\tE\n") == "one\ntwo \t\n")
    #expect(try body("cat <<E\n\tkept\nE") == "\tkept\n")
    #expect(try body("cat 3<<E\nE") == "")
    #expect(try body("cat <<E\n E\nEE\nE") == " E\nEE\n")
  }

  @Test
  func commandsAfterHeredocBodiesResume() throws {
    let parsed = try program("cat <<A; cat <<B\none\nA\ntwo\nB\necho after\n")
    #expect(parsed.commands.count == 3)
    #expect(try arguments("x <<A\n$((1+1))\nA") == ["x"])
    let last = try Expander(state: ShellState())
      .prepare(parsed.commands[2].pipeline[0])
    #expect(last.arguments == [bytes("echo"), bytes("after")])
    let second = try Expander(state: ShellState())
      .prepare(parsed.commands[1].pipeline[0])
    #expect(second.redirects == [.data(descriptor: 0, bytes: bytes("two\n"))])
  }

  @Test
  func oversizedHeredocIsRejectedBeforeLaunch() throws {
    let source =
      "cat <<E\n"
      + String(repeating: "x", count: DescriptorAction.maximumHeredocBytes)
      + "\nE"
    #expect(throws: ShellDiagnostic.self) { try arguments(source) }
  }

  @Test
  func listsExpandOnlyAsWholeWords() throws {
    var state = ShellState(variables: ["scalar": bytes("s")])
    state.arrays["list"] = [bytes("a b"), bytes("*"), []]
    state.arrays["empty"] = []
    #expect(
      try arguments("x ${list[@]} \"${list[@]}\"", state: state) == [
        "x", "a b", "*", "", "a b", "*", "",
      ]
    )
    #expect(
      try arguments("x ${empty[@]} ${unset[@]} end", state: state) == [
        "x", "end",
      ]
    )
    #expect(
      try arguments(
        "x ${#list[@]} ${#empty[@]} ${#unset[@]} ${list[0]} ${list[$((1 + 1))]}",
        state: state
      ) == ["x", "3", "0", "0", "a b", ""]
    )
    for source in [
      "x a${list[@]}", "x \"${list[@]} \"", "x $list", "x ${list[3]}",
      "x ${list[-1]}", "x ${scalar[@]}", "x ${#scalar[@]}", "x ${scalar[0]}",
      "x >${list[@]}", "v=${list[@]}",
    ] {
      #expect(throws: ShellDiagnostic.self, "\(source)") {
        try arguments(source, state: state)
      }
    }
  }

  @Test
  func listUpdatesCommitTogether() throws {
    var state = ShellState(variables: ["v": bytes("s")], exported: ["v"])
    func apply(_ source: String) throws {
      let prepared = try Expander(state: state)
        .prepare(try program(source).commands[0].pipeline[0])
      var next = state
      next.assign(prepared.assignments)
      try next.apply(prepared.updates)
      state = next
    }
    try apply("a=(one 'two words') s=x")
    #expect(state.arrays["a"] == [bytes("one"), bytes("two words")])
    try apply("a+=(three) a[0]=ONE a[3]=four s+=y")
    #expect(
      state.arrays["a"] == ["ONE", "two words", "three", "four"].map(bytes)
    )
    #expect(state.variables["s"] == bytes("xy"))
    // A failing update leaves every earlier update of the command unapplied.
    #expect(throws: ShellDiagnostic.self) { try apply("a[0]=x a[9]=y") }
    #expect(state.arrays["a"]?[0] == bytes("ONE"))
    #expect(throws: ShellDiagnostic.self) { try apply("a+=scalar") }
    #expect(throws: ShellDiagnostic.self) { try apply("s+=(list)") }
    #expect(throws: ShellDiagnostic.self) { try apply("s[0]=x") }
    #expect(throws: ShellDiagnostic.self) { try apply("v=(exported)") }
    #expect(throws: ShellDiagnostic.self) { try apply("b=(1) /bin/echo") }
    try apply("a=scalar")
    #expect(state.arrays["a"] == nil)
    #expect(state.variables["a"] == bytes("scalar"))
    try apply("s=(now a list)")
    #expect(state.variables["s"] == nil)
    #expect(state.arrays["s"]?.count == 3)
  }

  @Test
  func unsetNamesFailOnlyUnderNounset() throws {
    var state = ShellState(variables: ["set": []])
    #expect(
      try arguments("x $missing ${#missing[@]} $((missing))", state: state) == [
        "x", "", "0", "0",
      ]
    )
    state.options.nounset = true
    #expect(try arguments("x $set", state: state) == ["x", ""])
    for source in [
      "x $missing", "x ${missing[@]}", "x ${#missing[@]}", "x $((missing))",
      "x $1",
    ] {
      #expect(throws: ShellDiagnostic.self, "\(source)") {
        try arguments(source, state: state)
      }
    }
  }

  @Test
  func setValidatesBeforeChangingPolicies() throws {
    var state = ShellState()
    var directory = try WorkingDirectory()
    let sink = try OwnedFD.open(Array("/dev/null".utf8), flags: O_WRONLY)
    sink.withDescriptor { fd in
      let io = BuiltinIO(output: fd, error: fd)
      func set(_ arguments: String...) -> EvaluationControl {
        BuiltinEvaluator()
          .run(
            .set,
            arguments: arguments.map(bytes),
            state: &state,
            directory: &directory,
            io: io
          )
      }
      #expect(set("-eu", "-o", "pipefail") == .continuing(0))
      #expect(
        state.options
          == ShellOptions(errexit: true, nounset: true, pipefail: true)
      )
      #expect(set("+e", "+o", "nounset") == .continuing(0))
      #expect(
        state.options
          == ShellOptions(errexit: false, nounset: false, pipefail: true)
      )
      for invalid in [
        ["-e", "-x"], ["-o"], ["-o", "nope"], ["-oe", "errexit"], ["e"], ["-"],
        ["--", "a"],
      ] {
        let before = state.options
        #expect(
          BuiltinEvaluator()
            .run(
              .set,
              arguments: invalid.map(bytes),
              state: &state,
              directory: &directory,
              io: io
            ) == .continuing(2)
        )
        #expect(state.options == before)
      }
      #expect(set() == .continuing(0))
    }
  }

  @Test
  func pipefailReportsTheLastFailingStage() {
    var job = JobRecord(
      id: JobID(value: 1),
      stages: [
        .finished(.exited(3)), .finished(.signaled(SIGTERM)),
        .finished(.exited(0)),
      ]
    )
    job.assembling = false
    #expect(job.disposition == .completed(.exited(0)))
    job.pipefail = true
    #expect(job.disposition == .completed(.signaled(SIGTERM)))
    job.stages = [.finished(.exited(0)), .finished(.exited(0))]
    #expect(job.disposition == .completed(.exited(0)))
    job.stages = [.finished(.exited(1)), .finished(.exited(2))]
    #expect(job.disposition == .completed(.exited(2)))
  }

  @Test
  func negationAndControlFlowKeepTheirStructure() throws {
    let parsed = try program("! a | b && c; if x; then y; else z; fi")
    #expect(parsed.commands.map(\.negated) == [true, false, false])
    #expect(parsed.commands[0].pipeline.count == 2)
    guard
      case .conditional(let branches, let otherwise, let source) =
        parsed.commands[2].pipeline[0].compound
    else {
      Issue.record("expected a conditional")
      return
    }
    #expect(branches.count == 1)
    #expect(otherwise?.commands.count == 1)
    #expect(source == bytes("if x; then y; else z; fi"))
    #expect(Builtin(rawValue: "break") == .break)
    for builtin in [Builtin.set, .trap, .break, .continue] {
      #expect(!BuiltinWorkerContext.supports(builtin))
    }
  }
}
