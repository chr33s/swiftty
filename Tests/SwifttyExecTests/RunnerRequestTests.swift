import SwifttyExec
import Testing
@testable import SwshAgent

/// swsh's headless request format: exact bytes, bounded input, pure previews,
/// and no execution without a context.
@Suite
struct RunnerRequestTests {
  private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

  private func run(
    request: String = "req-1",
    operation: String = "run",
    work: String = #""pipeline": [{"argv": ["git", "diff", "--", "Sources"]}]"#,
    extra: String = ""
  ) -> String {
    #"{"protocol": "swsh.run/1", "requestId": "\#(request)", "operation": "\#(operation)", \#(work)\#(extra)}"#
  }

  private func rejection(_ frame: String) -> Rejected? {
    do {
      _ = try RunnerRequest.decode(bytes(frame))
      return nil
    } catch { return error as? Rejected }
  }

  private func text(_ result: RunnerResult?) -> String {
    String(decoding: result?.encoded() ?? [], as: UTF8.self)
  }

  @Test
  func argumentsAreExactBytesAndNeverSyntax() throws {
    let request = try RunnerRequest.decode(
      bytes(
        run(
          work:
            #""pipeline": [{"argv": ["sh", "$(touch x) > y; `z` *", "a\nb", {"base64": "//4="}, "", "‮gnp.exe"]}, {"argv": ["wc"]}]"#,
          extra: #", "cwd": "Sources/./Swsh""#
        )
      )
    )
    #expect(
      request.work
        == .pipeline([
          [
            bytes("sh"), bytes("$(touch x) > y; `z` *"), bytes("a\nb"),
            [0xFF, 0xFE], [], bytes("\u{202E}gnp.exe"),
          ], [bytes("wc")],
        ])
    )
    #expect(request.cwd == ["Sources", "Swsh"])
    let source = try RunnerRequest.decode(
      bytes(run(work: #""source": "echo $(date) > out""#))
    )
    #expect(source.work == .source(bytes("echo $(date) > out")))
  }

  @Test
  func identityCoversDecodedValuesNotSpelling() throws {
    let plain = try RunnerRequest.decode(
      bytes(run(work: #""pipeline": [{"argv": ["é", "b"]}]"#))
    )
    let respelled = try RunnerRequest.decode(
      bytes(
        #"{"pipeline":[{"argv":[{"base64":"w6k="},"b"]}],"operation":"run","requestId":"req-1","protocol":"swsh.run/1","cwd":"."}"#
      )
    )
    #expect(plain == respelled)
    #expect(plain.identity == respelled.identity)
    for other in [
      run(work: #""pipeline": [{"argv": ["é", "c"]}]"#),
      run(work: #""pipeline": [{"argv": ["éb"]}]"#),
      run(work: #""pipeline": [{"argv": ["é", "b", ""]}]"#),
      run(work: #""pipeline": [{"argv": ["é"]}, {"argv": ["b"]}]"#),
      run(work: #""source": "é b""#),
      run(request: "req-2", work: #""pipeline": [{"argv": ["é", "b"]}]"#),
      run(operation: "preview", work: #""pipeline": [{"argv": ["é", "b"]}]"#),
      run(
        work: #""pipeline": [{"argv": ["é", "b"]}]"#,
        extra: #", "cwd": "x""#
      ),
    ] {
      #expect(try RunnerRequest.decode(bytes(other)).identity != plain.identity)
    }
  }

  @Test
  func malformedAndOversizedRequestsAreRejected() {
    let big = String(repeating: "a", count: RunnerLimits.argumentBytes + 1)
    let stage = #"{"argv": ["t"]}"#
    let cases: [(String, Outcome)] = [
      (#"{"protocol": "swiftty.exec/1"}"#, .unsupportedProtocol),
      (run(operation: "create"), .unsupportedOperation),
      (run(work: #""pipeline": [], "source": "x""#), .invalidRequest),
      (run(work: #""requestId": "req-1""#), .invalidRequest),
      (run(extra: #", "approved": true"#), .invalidRequest),
      (run(extra: #", "sessionId": "session-7""#), .invalidRequest),
      (run(extra: #", "limits": {"wallMilliseconds": 5}"#), .invalidRequest),
      (run(extra: #", "cwd": "/etc""#), .invalidRequest),
      (run(extra: #", "cwd": "a/../..""#), .invalidRequest),
      (run(extra: #", "cwd": """#), .invalidRequest),
      (run(work: #""pipeline": []"#), .invalidRequest),
      (run(work: #""pipeline": [{"argv": []}]"#), .invalidRequest),
      (run(work: #""pipeline": [{"argv": [""]}]"#), .invalidRequest),
      (
        run(work: #""pipeline": [{"argv": ["a"], "tool": "x"}]"#),
        .invalidRequest
      ), (run(work: #""pipeline": [{"argv": ["a\u0000b"]}]"#), .invalidRequest),
      (
        run(work: #""pipeline": [{"argv": [{"base64": "AA=="}]}]"#),
        .invalidRequest
      ),
      (
        run(work: #""pipeline": [{"argv": [{"base64": "//5="}]}]"#),
        .invalidRequest
      ), (run(work: #""pipeline": [{"argv": [1]}]"#), .invalidRequest),
      (run(work: #""pipeline": [{"argv": ["\ud800"]}]"#), .invalidRequest),
      (run(work: "\"pipeline\": [{\"argv\": [\"\(big)\"]}]"), .invalidRequest),
      (
        run(
          work: "\"pipeline\": [{\"argv\": ["
            + Array(repeating: "\"a\"", count: 1025).joined(separator: ",")
            + "]}]"
        ), .invalidRequest
      ),
      (
        run(
          work: "\"pipeline\": ["
            + Array(repeating: stage, count: 9).joined(separator: ",") + "]"
        ), .invalidRequest
      ),
      (
        run(
          work: "\"source\": \""
            + String(repeating: "a", count: RunnerLimits.sourceBytes + 1) + "\""
        ), .invalidRequest
      ), (run(work: #""source": "a\u0000b""#), .invalidRequest),
    ]
    for (frame, outcome) in cases {
      #expect(rejection(frame)?.outcome == outcome, "\(frame.prefix(160))")
    }
  }

  @Test
  func previewsArePureAndRunNeedsAContext() {
    let preview = text(
      AgentMain.respond(
        bytes(
          run(
            operation: "preview",
            work:
              #""pipeline": [{"argv": ["printf", "$(x) *", {"base64": "//4="}]}]"#
          )
        )
      )
    )
    #expect(preview.contains(#""outcome":"previewed""#))
    #expect(
      preview.contains(
        #""stages":[{"argv":[{"text":"printf"},{"text":"$(x) *"},{"base64":"//4="}],"unresolved":[]}]"#
      )
    )
    // Shell source can need execution to resolve; no value is guessed.
    let source = text(
      AgentMain.respond(
        bytes(run(operation: "preview", work: #""source": "echo $(date)""#))
      )
    )
    #expect(source.contains(#""outcome":"unsupported_operation""#))
    #expect(source.contains(#""stages":null"#))
    for work in [#""pipeline": [{"argv": ["true"]}]"#, #""source": "true""#] {
      let refused = text(AgentMain.respond(bytes(run(work: work))))
      #expect(refused.contains(#""outcome":"no_context""#))
      #expect(refused.contains(#""effects":"none""#))
    }
    #expect(AgentMain.respond(bytes(" \t\r")) == nil)
    let hostile = AgentMain.respond(
      bytes(run(extra: ", \"\\u001b]0;approved\\u0007\\n\": 1"))
    )!
    .encoded()
    #expect(hostile.last == 10)
    #expect(hostile.dropLast().allSatisfy { (32 ... 126).contains($0) })
  }
}
