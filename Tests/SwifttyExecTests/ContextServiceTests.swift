import Testing
@testable import SwifttyExec

/// spec.shell.md §11.6, step B1: the service manages execution contexts.
/// Bounded decoding and admission ordering are checked against a backend that
/// cannot start one.
@Suite
struct ContextServiceTests {
  private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

  private func create(
    request: String = "req-1",
    session: String = "session-7",
    image: String = "toolchain-1",
    snapshots: String = #"["snapshot-31"]"#,
    extra: String = ""
  ) -> String {
    """
    {"protocol": "swiftty.exec/1", "requestId": "\(request)", "sessionId": "\(session)",
     "operation": "create", "image": "\(image)", "snapshots": \(snapshots),
     "network": "none"\(extra)}
    """
  }

  private func control(_ operation: String, _ extra: String = "") -> String {
    #"{"protocol": "swiftty.exec/1", "requestId": "c", "sessionId": "session-7", "operation": "\#(operation)", "contextId": "context-1"\#(extra)}"#
  }

  private func rejection(_ frame: String) -> Rejected? {
    do {
      _ = try ContextRequest.decode(bytes(frame))
      return nil
    } catch { return error as? Rejected }
  }

  /// Advertises every control, counts creations, and still starts nothing.
  private final class CountingBackend: ContextBackend {
    let name = "fake"
    var features = Set(BackendFeature.allCases)
    var outcome = CreateOutcome.notStarted("fake backend starts nothing")
    var created: [AdmittedContext] = []
    func create(_ context: AdmittedContext) -> CreateOutcome {
      created.append(context)
      return outcome
    }
  }

  private func grant() -> Grant {
    Grant(
      sessionID: "session-7",
      images: ["toolchain-1"],
      snapshots: ["snapshot-31", "snapshot-32"],
      maximumWallMilliseconds: 120_000,
      maximumOutputBytes: 1 << 20,
      sessionWallMilliseconds: 300_000,
      maximumRequests: 8
    )
  }

  @Test
  func decodesEveryOperation() throws {
    let request = try ContextRequest.decode(
      bytes(
        create(
          extra:
            #", "limits": {"wallMilliseconds": 120000, "outputBytes": 1048576}"#
        )
      )
    )
    #expect(request.requestID == "req-1")
    #expect(
      request.operation
        == .create(
          .init(
            image: "toolchain-1",
            snapshots: ["snapshot-31"],
            limits: .init(wallMilliseconds: 120000, outputBytes: 1 << 20)
          )
        )
    )
    func operation(_ frame: String) throws -> ContextRequest.Operation {
      try ContextRequest.decode(bytes(frame)).operation
    }
    #expect(
      try operation(control("attach", #", "channel": "terminal""#))
        == .attach(context: "context-1", channel: .terminal)
    )
    #expect(try operation(control("status")) == .status(context: "context-1"))
    #expect(try operation(control("cancel")) == .cancel(context: "context-1"))
    #expect(
      try operation(control("export", #", "paths": ["out/./a.txt", "b"]"#))
        == .export(context: "context-1", paths: [["out", "a.txt"], ["b"]])
    )
  }

  @Test
  func identityCoversDecodedValuesNotSpelling() throws {
    let plain = try ContextRequest.decode(bytes(create()))
    let respelled = try ContextRequest.decode(
      bytes(
        """
        {"snapshots":["snapshot\\u002d31"],"image":"toolchain-1","operation":"create",
        "sessionId":"session-7","requestId":"req-1","protocol":"swiftty.exec/1"}
        """
      )
    )
    #expect(plain == respelled)
    #expect(plain.identity == respelled.identity)
    #expect(plain.identity.count == 64)
    for other in [
      create(request: "req-2"), create(image: "toolchain-2"),
      create(snapshots: #"["snapshot-32"]"#),
      create(snapshots: #"["snapshot-31", "snapshot-32"]"#),
      create(snapshots: "[]"),
      create(extra: #", "limits": {"outputBytes": 5}"#),
    ] {
      #expect(
        try ContextRequest.decode(bytes(other)).identity != plain.identity
      )
    }
  }

  @Test
  func malformedAndOversizedRequestsAreRejected() {
    let cases: [(String, Outcome)] = [
      ("", .invalidRequest), ("[]", .invalidRequest), ("{", .invalidRequest),
      (#"{"protocol": "swiftty.exec/2"}"#, .unsupportedProtocol),
      (#"{"protocol": "swsh.run/1"}"#, .unsupportedProtocol),
      // The service has no operation that names a command.
      (control("execute"), .unsupportedOperation),
      (control("shell"), .unsupportedOperation),
      (create(extra: #", "pipeline": [{"argv": ["true"]}]"#), .invalidRequest),
      (create(extra: #", "source": "true""#), .invalidRequest),
      (create(extra: #", "approved": true"#), .invalidRequest),
      (create(extra: #", "effectivePolicy": {}"#), .invalidRequest),
      (create(extra: #", "backendVerified": true"#), .invalidRequest),
      (create(extra: #", "limits": {"wallMilliseconds": 0}"#), .invalidRequest),
      (
        create(extra: #", "limits": {"wallMilliseconds": 1.5}"#),
        .invalidRequest
      ), (create(extra: #", "limits": {"cpus": 64}"#), .invalidRequest),
      (create(extra: #", "requestId": "again""#), .invalidRequest),
      (create(request: "bad id"), .invalidRequest),
      (create(request: String(repeating: "r", count: 65)), .invalidRequest),
      (create(image: "/var/images/x"), .invalidRequest),
      (create(snapshots: #"["../home"]"#), .invalidRequest),
      (create(snapshots: #"["a", "a"]"#), .invalidRequest),
      (create(snapshots: #"[1]"#), .invalidRequest),
      (
        create(
          snapshots: "["
            + (0 ..< 17).map { "\"s\($0)\"" }.joined(separator: ",") + "]"
        ), .invalidRequest
      ),
      (
        create().replacing(#""network": "none""#, with: #""network": "host""#),
        .invalidRequest
      ), (control("attach", #", "channel": "host""#), .invalidRequest),
      (control("attach"), .invalidRequest),
      (control("export", #", "paths": []"#), .invalidRequest),
      (control("export", #", "paths": ["/etc/passwd"]"#), .invalidRequest),
      (control("export", #", "paths": ["a/../../b"]"#), .invalidRequest),
      (control("export", #", "paths": ["a//b"]"#), .invalidRequest),
      (control("export", #", "paths": ["a\u0000b"]"#), .invalidRequest),
      (control("status", #", "paths": ["a"]"#), .invalidRequest),
      (String(repeating: "[", count: 64), .invalidRequest),
      (
        String(repeating: " ", count: WireLimits.frameBytes + 1),
        .invalidRequest
      ),
    ]
    for (frame, outcome) in cases {
      #expect(rejection(frame)?.outcome == outcome, "\(frame.prefix(160))")
    }
    // A readable ID is echoed; text from the request cannot leave ASCII.
    #expect(
      rejection(create(extra: #", "approved": true"#))?.requestID == "req-1"
    )
    let hostile = ContextResult(
      rejection(create(extra: ", \"\\u001b]0;approved\\u0007\\n\": 1"))!
    )
    .encoded()
    #expect(hostile.last == 10)
    #expect(hostile.dropLast().allSatisfy { (32 ... 126).contains($0) })
    let text = String(decoding: hostile, as: UTF8.self)
    #expect(
      text.hasPrefix(
        #"{"protocol":"swiftty.exec/1","requestId":"req-1","outcome":"invalid_request""#
      )
    )
    #expect(
      text.contains(
        #""effects":"none","cleanup":"not_needed","replayed":false"#
      )
    )
  }

  @Test
  func noGrantAndNoBackendFailClosedBeforeAnyCreation() throws {
    let request = try ContextRequest.decode(bytes(create()))
    let backend = CountingBackend()
    let ungranted = ContextService(grants: [], backend: backend) { 0 }
    let denied = ungranted.handle(request)
    #expect(denied.outcome == .policyDenied)
    #expect(denied.effects == .none)
    #expect(denied.scope == nil)
    #expect(backend.created.isEmpty)

    let refusing = ContextService(grants: [grant()], backend: RefusingBackend())
    { 0 }
    let unsupported = refusing.handle(request)
    #expect(unsupported.outcome == .unsupportedEnforcement)
    #expect(
      unsupported.missingFeatures
        == BackendFeature.allCases.map(\.rawValue).sorted()
    )
    #expect(unsupported.effects == .none)
    #expect(unsupported.backend == "none")
    #expect(refusing.remainingWallMilliseconds(session: "session-7") == 300_000)

    // One missing control is enough; there is no weaker fallback.
    backend.features.remove(.networkDisabled)
    let partial = ContextService(grants: [grant()], backend: backend) { 0 }
    #expect(partial.handle(request).missingFeatures == ["network_disabled"])
    #expect(backend.created.isEmpty)
  }

  @Test
  func grantsBoundImagesSnapshotsLimitsAndExpiry() throws {
    let backend = CountingBackend()
    var clock: UInt64 = 10
    var limited = grant()
    limited.expiresAt = 20
    let service = ContextService(grants: [limited], backend: backend) { clock }
    func outcome(_ frame: String) throws -> ContextResult {
      service.handle(try ContextRequest.decode(bytes(frame)))
    }
    #expect(
      try outcome(create(request: "a", image: "toolchain-9")).outcome
        == .policyDenied
    )
    #expect(
      try outcome(create(request: "b", snapshots: #"["snapshot-31", "home"]"#))
        .outcome == .policyDenied
    )
    #expect(
      try outcome(create(request: "d", session: "session-8")).outcome
        == .policyDenied
    )
    #expect(backend.created.isEmpty)

    // A request can lower a limit and cannot raise one.
    let raised = try outcome(
      create(
        request: "e",
        extra: #", "limits": {"wallMilliseconds": 999999, "outputBytes": 10}"#
      )
    )
    #expect(raised.scope?.wallMilliseconds == 120_000)
    #expect(raised.scope?.outputBytes == 10)
    #expect(raised.outcome == .runtimeFailure)
    #expect(raised.effects == .none)
    #expect(backend.created.count == 1)
    #expect(backend.created[0].wallMilliseconds == 120_000)
    // No context exists, so the reservation was returned.
    #expect(service.remainingWallMilliseconds(session: "session-7") == 300_000)

    for operation in ["status", "cancel"] {
      #expect(
        try outcome(
          control(operation).replacing(#""c""#, with: "\"\(operation)\"")
        )
        .outcome == .unknownContext
      )
    }
    clock = 20
    #expect(try outcome(create(request: "g")).outcome == .policyDenied)
    #expect(backend.created.count == 1)
  }

  @Test
  func replaysAndBudgetsCannotBeResetByTheCaller() throws {
    let backend = CountingBackend()
    backend.outcome = .unknown("lost contact with the context")
    let service = ContextService(grants: [grant()], backend: backend) { 0 }
    func outcome(_ frame: String) throws -> ContextResult {
      service.handle(try ContextRequest.decode(bytes(frame)))
    }
    let first = try outcome(create(request: "a"))
    #expect(first.outcome == .executionUnknown)
    #expect(first.effects == .unknown)
    #expect(first.cleanup == .unknown)
    // Unknown state stays charged.
    #expect(service.remainingWallMilliseconds(session: "session-7") == 180_000)

    var replay = try outcome(create(request: "a"))
    #expect(replay.replayed)
    replay.replayed = false
    #expect(replay == first)
    #expect(backend.created.count == 1)
    #expect(service.remainingWallMilliseconds(session: "session-7") == 180_000)
    #expect(
      try outcome(create(request: "a", snapshots: "[]")).outcome
        == .requestConflict
    )
    #expect(backend.created.count == 1)

    // New request IDs draw on the same session budget.
    #expect(try outcome(create(request: "b")).outcome == .executionUnknown)
    let exhausted = try outcome(create(request: "c"))
    #expect(exhausted.outcome == .budgetExhausted)
    #expect(exhausted.effects == .none)
    #expect(backend.created.count == 2)
    #expect(
      try outcome(
        create(request: "d", extra: #", "limits": {"wallMilliseconds": 60000}"#)
      )
      .outcome == .executionUnknown
    )
    #expect(service.remainingWallMilliseconds(session: "session-7") == 0)
    for id in ["e", "f", "g", "h"] {
      #expect(try outcome(create(request: id)).outcome == .budgetExhausted)
    }
    // The request count is bounded as well, and replays still answer.
    #expect(
      try outcome(create(request: "i")).reason
        == "the session's request budget is spent"
    )
    #expect(try outcome(create(request: "a")).replayed)
    #expect(backend.created.count == 3)
  }
}
