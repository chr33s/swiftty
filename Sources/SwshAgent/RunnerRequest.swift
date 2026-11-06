import SwifttyExec

/// Hard bounds of runner protocol version 1.
enum RunnerLimits {
  static let argumentBytes = 64 << 10
  static let stages = 8
  static let argumentsPerStage = 1024
  static let sourceBytes = 256 << 10
}

/// One decoded request to swsh's headless interface. It says exactly what
/// would run and with which bytes. It says nothing about whether that is
/// allowed or where it runs: both belong to the execution context swsh is
/// handed. Every value is literal data; decoding expands, looks up, and opens
/// nothing.
struct RunnerRequest: Equatable, Sendable {
  static let version = "swsh.run/1"

  enum Work: Equatable, Sendable {
    /// Literal stages. `argv[0]` names the program; no value is ever syntax.
    case pipeline([[[UInt8]]])
    /// Shell source, with ordinary shell semantics inside the context.
    case source([UInt8])
  }
  enum Operation: String, Sendable {
    case run
    /// A pure description: no effect anywhere, and no context needed.
    case preview
  }

  let requestID: String
  let operation: Operation
  let work: Work
  /// Relative to the context's working directory.
  let cwd: [String]

  static func decode(_ frame: [UInt8]) throws -> RunnerRequest {
    try Wire.decode(frame, version: version) { fields, requestID in
      guard let operation = Operation(rawValue: try fields.string("operation"))
      else {
        throw Rejection(
          outcome: .unsupportedOperation,
          reason: "operations are run and preview"
        )
      }
      let work: Work
      switch (fields.take("pipeline"), fields.take("source")) {
      case (let stages?, nil): work = .pipeline(try pipeline(stages))
      case (nil, let text?):
        var remaining = RunnerLimits.sourceBytes
        work = .source(
          try Wire.bytes(
            text,
            "request.source",
            remaining: &remaining,
            limit: RunnerLimits.sourceBytes
          )
        )
      default:
        throw Rejection.invalid(
          "request: expected exactly one of pipeline and source"
        )
      }
      var cwd: [String] = []
      if let value = fields.take("cwd") {
        guard case .string(let path) = value else {
          throw Rejection.invalid("request.cwd: expected a string")
        }
        cwd = try Wire.components(path, "request.cwd")
      }
      return RunnerRequest(
        requestID: requestID,
        operation: operation,
        work: work,
        cwd: cwd
      )
    }
  }

  private static func pipeline(_ value: JSONValue) throws -> [[[UInt8]]] {
    guard case .array(let entries) = value,
      (1 ... RunnerLimits.stages).contains(entries.count)
    else {
      throw Rejection.invalid(
        "request.pipeline: expected 1 to \(RunnerLimits.stages) stages"
      )
    }
    var remaining = RunnerLimits.argumentBytes
    return try entries.enumerated()
      .map { index, entry in
        var stage = try Fields(entry, "request.pipeline[\(index)]")
        guard case .array(let values)? = stage.take("argv"),
          (1 ... RunnerLimits.argumentsPerStage).contains(values.count)
        else {
          throw Rejection.invalid(
            "\(stage.name("argv")): expected 1 to \(RunnerLimits.argumentsPerStage) arguments"
          )
        }
        let argv = try values.map {
          try Wire.bytes(
            $0,
            "request.pipeline",
            remaining: &remaining,
            limit: RunnerLimits.argumentBytes
          )
        }
        guard !argv[0].isEmpty else {
          throw Rejection.invalid("\(stage.name("argv")): empty program name")
        }
        try stage.finish()
        return argv
      }
  }

  var identity: String {
    var canonical = Canonical()
    canonical.text(Self.version)
    canonical.text(requestID)
    canonical.text(operation.rawValue)
    switch work {
    case .pipeline(let stages):
      canonical.text("pipeline")
      canonical.number(stages.count)
      for argv in stages {
        canonical.number(argv.count)
        for argument in argv { canonical.field(argument) }
      }
    case .source(let text):
      canonical.text("source")
      canonical.field(text)
    }
    canonical.number(cwd.count)
    for component in cwd { canonical.text(component) }
    return canonical.digest
  }
}

/// What swsh reports for one request. swsh authors no statement about policy:
/// nothing here says a request was approved or confined.
struct RunnerResult: Equatable, Sendable {
  var requestID: String?
  var outcome: Outcome
  var reason: String?
  var identity: String?
  /// For a preview: each stage's arguments, exactly as they would be passed.
  var stages: [[[UInt8]]]?

  init(_ rejected: Rejected) {
    requestID = rejected.requestID
    outcome = rejected.outcome
    reason = rejected.reason
  }

  init(_ request: RunnerRequest, _ outcome: Outcome, _ reason: String?) {
    requestID = request.requestID
    identity = request.identity
    self.outcome = outcome
    self.reason = reason
  }

  /// Text when the bytes are UTF-8, base64 otherwise; never a lossy rendering.
  private static func value(_ bytes: [UInt8]) -> String {
    if let text = String(validating: bytes, as: UTF8.self) {
      return "{\"text\":" + Wire.quote(text) + "}"
    }
    return "{\"base64\":" + Wire.quote(Base64.encode(bytes)) + "}"
  }

  /// One line of ASCII JSON. Nothing started for any result this build can
  /// produce, so `effects` is always "none".
  func encoded() -> [UInt8] {
    var members = [
      "\"protocol\":" + Wire.quote(RunnerRequest.version),
      "\"requestId\":" + Wire.quote(requestID),
      "\"outcome\":" + Wire.quote(outcome.rawValue),
      "\"reason\":" + Wire.quote(reason),
      "\"requestIdentity\":" + Wire.quote(identity), "\"effects\":\"none\"",
    ]
    if let stages {
      let rendered = stages.map { argv in
        "{\"argv\":[" + argv.map(Self.value).joined(separator: ",")
          + "],\"unresolved\":[]}"
      }
      members.append("\"stages\":[" + rendered.joined(separator: ",") + "]")
    } else {
      members.append("\"stages\":null")
    }
    return Array(("{" + members.joined(separator: ",") + "}\n").utf8)
  }
}
