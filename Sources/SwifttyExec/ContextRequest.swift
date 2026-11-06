/// Bounds of service protocol version 1. A grant can only narrow them.
package enum ContextLimits {
  static let snapshots = 16
  static let exportPaths = 256
}

/// One decoded service request. The service manages execution contexts, not
/// commands: nothing here names a program, an argument, or shell source. What
/// runs inside a context is between the client and the runner attached to it.
package struct ContextRequest: Equatable, Sendable {
  package static let version = "swiftty.exec/1"

  struct Limits: Equatable, Sendable {
    var wallMilliseconds: Int?
    var outputBytes: Int?
  }
  struct Create: Equatable, Sendable {
    /// The pinned runtime image the context starts from.
    let image: String
    /// Immutable input snapshots, in mount order.
    let snapshots: [String]
    let limits: Limits
  }
  enum Channel: String, Sendable {
    /// The runner's framed control channel plus bounded output.
    case control
    /// One PTY, for a confined pane.
    case terminal
  }
  enum Operation: Equatable, Sendable {
    case create(Create)
    case attach(context: String, channel: Channel)
    case status(context: String)
    case cancel(context: String)
    /// Resource-relative paths in the context's workspace.
    case export(context: String, paths: [[String]])
  }

  package let requestID: String
  let sessionID: String
  let operation: Operation

  package static func decode(_ frame: [UInt8]) throws -> ContextRequest {
    try Wire.decode(frame, version: version) { fields, requestID in
      let session = try fields.identifier("sessionId")
      let operation: Operation
      switch try fields.string("operation") {
      case "create": operation = .create(try create(&fields))
      case "attach":
        let context = try fields.identifier("contextId")
        guard let channel = Channel(rawValue: try fields.string("channel"))
        else {
          throw Rejection.invalid(
            "request.channel: expected \"control\" or \"terminal\""
          )
        }
        operation = .attach(context: context, channel: channel)
      case "status":
        operation = .status(context: try fields.identifier("contextId"))
      case "cancel":
        operation = .cancel(context: try fields.identifier("contextId"))
      case "export":
        let context = try fields.identifier("contextId")
        guard case .array(let entries)? = fields.take("paths"),
          (1 ... ContextLimits.exportPaths).contains(entries.count)
        else {
          throw Rejection.invalid(
            "request.paths: expected 1 to \(ContextLimits.exportPaths) paths"
          )
        }
        let paths = try entries.map { entry -> [String] in
          guard case .string(let path) = entry else {
            throw Rejection.invalid("request.paths: expected strings")
          }
          return try Wire.components(path, "request.paths")
        }
        operation = .export(context: context, paths: paths)
      default:
        throw Rejection(
          outcome: .unsupportedOperation,
          reason: "operations are create, attach, status, cancel, and export"
        )
      }
      return ContextRequest(
        requestID: requestID,
        sessionID: session,
        operation: operation
      )
    }
  }

  private static func create(_ fields: inout Fields) throws -> Create {
    let image = try fields.identifier("image")
    guard case .array(let entries)? = fields.take("snapshots"),
      entries.count <= ContextLimits.snapshots
    else {
      throw Rejection.invalid(
        "request.snapshots: expected at most \(ContextLimits.snapshots) snapshots"
      )
    }
    let snapshots = try entries.map { entry -> String in
      guard case .string(let name) = entry, Wire.isIdentifier(name) else {
        throw Rejection.invalid("request.snapshots: expected identifiers")
      }
      return name
    }
    guard Set(snapshots).count == snapshots.count else {
      throw Rejection.invalid("request.snapshots: a snapshot is repeated")
    }
    // Offline is the only profile; a request cannot ask for a network.
    if let network = fields.take("network"), network != .string("none") {
      throw Rejection.invalid("request.network: only \"none\" is supported")
    }
    var limits = Limits()
    if let value = fields.take("limits") {
      var entries = try Fields(value, "request.limits")
      limits.wallMilliseconds = try entries.positive("wallMilliseconds")
      limits.outputBytes = try entries.positive("outputBytes")
      try entries.finish()
    }
    return Create(image: image, snapshots: snapshots, limits: limits)
  }

  package var identity: String {
    var canonical = Canonical()
    canonical.text(Self.version)
    canonical.text(requestID)
    canonical.text(sessionID)
    switch operation {
    case .create(let create):
      canonical.text("create")
      canonical.text(create.image)
      canonical.number(create.snapshots.count)
      for snapshot in create.snapshots { canonical.text(snapshot) }
      canonical.text("none")
      canonical.number(create.limits.wallMilliseconds)
      canonical.number(create.limits.outputBytes)
    case .attach(let context, let channel):
      canonical.text("attach")
      canonical.text(context)
      canonical.text(channel.rawValue)
    case .status(let context):
      canonical.text("status")
      canonical.text(context)
    case .cancel(let context):
      canonical.text("cancel")
      canonical.text(context)
    case .export(let context, let paths):
      canonical.text("export")
      canonical.text(context)
      canonical.number(paths.count)
      for path in paths {
        canonical.number(path.count)
        for component in path { canonical.text(component) }
      }
    }
    return canonical.digest
  }
}
