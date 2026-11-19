import Foundation
import SessionCore

/// Bounded, typed failure codes. Never carries stack traces or secrets.
public enum RSTErrorCode: String, Hashable, Sendable, Codable {
  case malformed
  case unsupported
  case notAttached
  case unauthorized
  case expired
  case unknownSession
  case wrongInstance
  case staleEpoch
  /// Another writer still has admitted input; takeover refused.
  case writerBusy
  case inputWrongWriter
  case inputGap
  case inputConflict
  case inputBackpressure
  case inputInvalid
  case limitExceeded
  case sessionExited
  case internalError
  /// `CopySelection`: a selected screen row changed since the client saw it.
  case selectionChanged
  /// `CopySelection`: the history generation changed or a row was evicted.
  case historyUnavailable
  /// `CopySelection`: another copy is still in flight on this attachment.
  case busy

  public init(_ rejection: HostInputLedger.Rejection) {
    switch rejection {
    case .wrongWriter: self = .inputWrongWriter
    case .gap: self = .inputGap
    case .conflict: self = .inputConflict
    case .backpressure: self = .inputBackpressure
    case .invalid: self = .inputInvalid
    }
  }
}

/// RST/1 control-stream messages (spec §7.2).
public enum ControlMessage: Hashable, Sendable {
  case attach(Attach)
  case attached(Attached)
  case input(Input)
  case inputAck(epoch: UInt64, sequence: UInt64)
  case screenAck(epoch: UInt64, screenRevision: UInt64)
  case ping(epoch: UInt64, nonce: UInt64)
  case pong(epoch: UInt64, nonce: UInt64)
  case detach(epoch: UInt64)
  case detached(epoch: UInt64)
  case terminate(epoch: UInt64)
  case terminated(epoch: UInt64)
  case sessionExited(epoch: UInt64, status: Int32, finalScreenRevision: UInt64)
  /// Client to host, with `historyViewport`: move this attachment's own
  /// window through the session's history by `lines` (positive reveals
  /// older lines). The host clamps it; input returns it to live output.
  case viewport(epoch: UInt64, lines: Int64)
  /// Client to host, with `screenDeltas`: a delta could not be applied;
  /// discard delta state and send a full screen of current state (§7.4).
  case requestFullScreen(epoch: UInt64)
  /// Client to host, with `copySelection` (§7.5).
  case copySelection(CopySelection)
  /// Host to client: one ordered piece of a copy's text.
  case copyChunk(epoch: UInt64, requestID: UInt64, index: UInt64, text: String)
  /// Host to client: ends a copy, with its total bytes or a failure.
  case copyResult(
    epoch: UInt64,
    requestID: UInt64,
    totalBytes: UInt64?,
    error: RSTErrorCode?
  )
  case error(RSTError)

  /// Bytes of text in one `CopyChunk`, under the control-record limit.
  public static let maxCopyChunkBytes = 48 * 1024
  /// Total text one copy may return; never truncated.
  public static let maxCopyBytes = 2 * 1024 * 1024
  /// Screen rows one `CopySelection` may list.
  public static let maxCopyScreenRows = 1024

  /// A selection in absolute history rows (§7.5).
  public struct CopySelection: Hashable, Sendable {
    public enum Unit: String, Hashable, Sendable, Codable {
      case character, word, line
    }

    public var attachmentEpoch: UInt64
    public var requestID: UInt64
    public var generation: UInt64
    public var alternateScreen: Bool
    public var startRow: UInt64
    public var startColumn: UInt64
    public var endRow: UInt64
    public var endColumn: UInt64
    public var unit: Unit
    /// `[row, version]` of selected screen rows as the client saw them.
    public var screenRowVersions: [[UInt64]]

    public init(
      attachmentEpoch: UInt64,
      requestID: UInt64,
      generation: UInt64,
      alternateScreen: Bool,
      startRow: UInt64,
      startColumn: UInt64,
      endRow: UInt64,
      endColumn: UInt64,
      unit: Unit,
      screenRowVersions: [[UInt64]]
    ) {
      self.attachmentEpoch = attachmentEpoch
      self.requestID = requestID
      self.generation = generation
      self.alternateScreen = alternateScreen
      self.startRow = startRow
      self.startColumn = startColumn
      self.endRow = endRow
      self.endColumn = endColumn
      self.unit = unit
      self.screenRowVersions = screenRowVersions
    }
  }

  /// Largest `viewport` movement one message may request.
  public static let maxViewportLines: Int64 = 1_000_000

  public struct Attach: Hashable, Sendable {
    public var sessionID: SessionID
    public var serverInstanceID: ServerInstanceID
    public var writerID: WriterID
    public var applicationToken: ApplicationToken
    /// Additions the client can receive (§5.3); empty from older clients.
    public var features: RSTFeatures

    public init(
      sessionID: SessionID,
      serverInstanceID: ServerInstanceID,
      writerID: WriterID,
      applicationToken: ApplicationToken,
      features: RSTFeatures = []
    ) {
      self.sessionID = sessionID
      self.serverInstanceID = serverInstanceID
      self.writerID = writerID
      self.applicationToken = applicationToken
      self.features = features
    }
  }

  public struct Attached: Hashable, Sendable {
    public var attachmentEpoch: UInt64
    public var writerID: WriterID
    public var lastFullyAppliedInputSequence: UInt64
    /// An admitted operation whose bytes are not all written yet.
    public var partialInputSequence: UInt64?
    public var resizeRevision: UInt64
    /// Additions the host accepts; omitted (empty) from older hosts.
    public var features: RSTFeatures

    public init(
      attachmentEpoch: UInt64,
      writerID: WriterID,
      lastFullyAppliedInputSequence: UInt64,
      partialInputSequence: UInt64? = nil,
      resizeRevision: UInt64,
      features: RSTFeatures = []
    ) {
      self.attachmentEpoch = attachmentEpoch
      self.writerID = writerID
      self.lastFullyAppliedInputSequence = lastFullyAppliedInputSequence
      self.partialInputSequence = partialInputSequence
      self.resizeRevision = resizeRevision
      self.features = features
    }
  }

  public struct Input: Hashable, Sendable {
    public var attachmentEpoch: UInt64
    public var sequence: UInt64
    public var operation: InputOperation

    public init(
      attachmentEpoch: UInt64,
      sequence: UInt64,
      operation: InputOperation
    ) {
      self.attachmentEpoch = attachmentEpoch
      self.sequence = sequence
      self.operation = operation
    }
  }

  public struct RSTError: Hashable, Sendable, Error {
    public var code: RSTErrorCode
    /// The input sequence concerned, if any.
    public var sequence: UInt64?
    /// Short fixed diagnostic; never user data.
    public var message: String?

    public init(
      _ code: RSTErrorCode,
      sequence: UInt64? = nil,
      message: String? = nil
    ) {
      self.code = code
      self.sequence = sequence
      self.message = message.map { String($0.prefix(200)) }
    }
  }

  public var typeName: String {
    switch self {
    case .attach: "Attach"
    case .attached: "Attached"
    case .input: "Input"
    case .inputAck: "InputAck"
    case .screenAck: "ScreenAck"
    case .ping: "Ping"
    case .pong: "Pong"
    case .detach: "Detach"
    case .detached: "Detached"
    case .terminate: "Terminate"
    case .terminated: "Terminated"
    case .sessionExited: "SessionExited"
    case .viewport: "Viewport"
    case .requestFullScreen: "RequestFullScreen"
    case .copySelection: "CopySelection"
    case .copyChunk: "CopyChunk"
    case .copyResult: "CopyResult"
    case .error: "Error"
    }
  }

  /// The epoch a post-attachment message is scoped to.
  public var epoch: UInt64? {
    switch self {
    case .attach, .error: nil
    case let .attached(a): a.attachmentEpoch
    case let .input(i): i.attachmentEpoch
    case let .inputAck(e, _), let .screenAck(e, _), let .ping(e, _),
      let .pong(e, _), let .detach(e), let .detached(e), let .terminate(e),
      let .terminated(e), let .sessionExited(e, _, _), let .viewport(e, _),
      let .requestFullScreen(e), let .copyChunk(e, _, _, _),
      let .copyResult(e, _, _, _):
      e
    case let .copySelection(c): c.attachmentEpoch
    }
  }
}

extension ControlMessage: Codable {
  enum Keys: String, CodingKey {
    case type, sessionID, serverInstanceID, writerID, applicationToken,
      attachmentEpoch, lastFullyAppliedInputSequence, partialInputSequence,
      resizeRevision, sequence, operation, screenRevision, nonce, status,
      finalScreenRevision, code, message, features, lines, requestID,
      generation, alternateScreen, startRow, startColumn, endRow, endColumn,
      unit, screenRowVersions, index, text, totalBytes, error
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    func u64(_ key: Keys) throws -> UInt64 {
      try c.decode(WireUInt64.self, forKey: key).value
    }
    let type = try c.decode(String.self, forKey: .type)
    switch type {
    case "Attach":
      self = .attach(
        Attach(
          sessionID: try c.decode(SessionID.self, forKey: .sessionID),
          serverInstanceID: try c.decode(
            ServerInstanceID.self,
            forKey: .serverInstanceID
          ),
          writerID: try c.decode(WriterID.self, forKey: .writerID),
          applicationToken: try c.decode(
            ApplicationToken.self,
            forKey: .applicationToken
          ),
          features: RSTFeatures(
            names: try c.decodeIfPresent([String].self, forKey: .features) ?? []
          )
        )
      )
    case "Attached":
      self = .attached(
        Attached(
          attachmentEpoch: try u64(.attachmentEpoch),
          writerID: try c.decode(WriterID.self, forKey: .writerID),
          lastFullyAppliedInputSequence: try u64(
            .lastFullyAppliedInputSequence
          ),
          partialInputSequence: try c.decodeIfPresent(
            WireUInt64.self,
            forKey: .partialInputSequence
          )?
          .value,
          resizeRevision: try u64(.resizeRevision),
          features: RSTFeatures(
            names: try c.decodeIfPresent([String].self, forKey: .features) ?? []
          )
        )
      )
    case "Input":
      self = .input(
        Input(
          attachmentEpoch: try u64(.attachmentEpoch),
          sequence: try u64(.sequence),
          operation: try c.decode(InputOperation.self, forKey: .operation)
        )
      )
    case "InputAck":
      self = .inputAck(
        epoch: try u64(.attachmentEpoch),
        sequence: try u64(.sequence)
      )
    case "ScreenAck":
      self = .screenAck(
        epoch: try u64(.attachmentEpoch),
        screenRevision: try u64(.screenRevision)
      )
    case "Ping":
      self = .ping(epoch: try u64(.attachmentEpoch), nonce: try u64(.nonce))
    case "Pong":
      self = .pong(epoch: try u64(.attachmentEpoch), nonce: try u64(.nonce))
    case "Detach": self = .detach(epoch: try u64(.attachmentEpoch))
    case "Detached": self = .detached(epoch: try u64(.attachmentEpoch))
    case "Terminate": self = .terminate(epoch: try u64(.attachmentEpoch))
    case "Terminated": self = .terminated(epoch: try u64(.attachmentEpoch))
    case "SessionExited":
      self = .sessionExited(
        epoch: try u64(.attachmentEpoch),
        status: try c.decode(Int32.self, forKey: .status),
        finalScreenRevision: try u64(.finalScreenRevision)
      )
    case "Viewport":
      let lines = try c.decode(Int64.self, forKey: .lines)
      guard lines.magnitude <= Self.maxViewportLines.magnitude else {
        throw DecodingError.dataCorruptedError(
          forKey: .lines,
          in: c,
          debugDescription: "viewport movement too large"
        )
      }
      self = .viewport(epoch: try u64(.attachmentEpoch), lines: lines)
    case "RequestFullScreen":
      self = .requestFullScreen(epoch: try u64(.attachmentEpoch))
    case "CopySelection":
      let rows = try c.decode([[WireUInt64]].self, forKey: .screenRowVersions)
      guard rows.count <= Self.maxCopyScreenRows,
        rows.allSatisfy({ $0.count == 2 })
      else {
        throw DecodingError.dataCorruptedError(
          forKey: .screenRowVersions,
          in: c,
          debugDescription: "screen row versions"
        )
      }
      self = .copySelection(
        CopySelection(
          attachmentEpoch: try u64(.attachmentEpoch),
          requestID: try u64(.requestID),
          generation: try u64(.generation),
          alternateScreen: try c.decode(Bool.self, forKey: .alternateScreen),
          startRow: try u64(.startRow),
          startColumn: try u64(.startColumn),
          endRow: try u64(.endRow),
          endColumn: try u64(.endColumn),
          unit: try c.decode(CopySelection.Unit.self, forKey: .unit),
          screenRowVersions: rows.map { $0.map(\.value) }
        )
      )
    case "CopyChunk":
      let text = try c.decode(String.self, forKey: .text)
      guard text.utf8.count <= Self.maxCopyChunkBytes else {
        throw DecodingError.dataCorruptedError(
          forKey: .text,
          in: c,
          debugDescription: "copy chunk too long"
        )
      }
      self = .copyChunk(
        epoch: try u64(.attachmentEpoch),
        requestID: try u64(.requestID),
        index: try u64(.index),
        text: text
      )
    case "CopyResult":
      self = .copyResult(
        epoch: try u64(.attachmentEpoch),
        requestID: try u64(.requestID),
        totalBytes: try c.decodeIfPresent(WireUInt64.self, forKey: .totalBytes)?
          .value,
        error: try c.decodeIfPresent(RSTErrorCode.self, forKey: .error)
      )
    case "Error":
      let message = try c.decodeIfPresent(String.self, forKey: .message)
      guard (message?.utf8.count ?? 0) <= 1024 else {
        throw DecodingError.dataCorruptedError(
          forKey: .message,
          in: c,
          debugDescription: "message too long"
        )
      }
      self = .error(
        RSTError(
          try c.decode(RSTErrorCode.self, forKey: .code),
          sequence: try c.decodeIfPresent(WireUInt64.self, forKey: .sequence)?
            .value,
          message: message
        )
      )
    default:
      // Unknown message types are rejected in version 1.
      throw DecodingError.dataCorruptedError(
        forKey: .type,
        in: c,
        debugDescription: "unknown message type"
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: Keys.self)
    try c.encode(typeName, forKey: .type)
    func u64(_ value: UInt64, _ key: Keys) throws {
      try c.encode(WireUInt64(value), forKey: key)
    }
    switch self {
    case let .attach(a):
      try c.encode(a.sessionID, forKey: .sessionID)
      try c.encode(a.serverInstanceID, forKey: .serverInstanceID)
      try c.encode(a.writerID, forKey: .writerID)
      try c.encode(a.applicationToken, forKey: .applicationToken)
      if !a.features.isEmpty {
        try c.encode(a.features.names, forKey: .features)
      }
    case let .attached(a):
      try u64(a.attachmentEpoch, .attachmentEpoch)
      try c.encode(a.writerID, forKey: .writerID)
      try u64(a.lastFullyAppliedInputSequence, .lastFullyAppliedInputSequence)
      if let p = a.partialInputSequence { try u64(p, .partialInputSequence) }
      try u64(a.resizeRevision, .resizeRevision)
      if !a.features.isEmpty {
        try c.encode(a.features.names, forKey: .features)
      }
    case let .input(i):
      try u64(i.attachmentEpoch, .attachmentEpoch)
      try u64(i.sequence, .sequence)
      try c.encode(i.operation, forKey: .operation)
    case let .inputAck(e, s):
      try u64(e, .attachmentEpoch)
      try u64(s, .sequence)
    case let .screenAck(e, r):
      try u64(e, .attachmentEpoch)
      try u64(r, .screenRevision)
    case let .ping(e, n), let .pong(e, n):
      try u64(e, .attachmentEpoch)
      try u64(n, .nonce)
    case let .detach(e), let .detached(e), let .terminate(e),
      let .terminated(e):
      try u64(e, .attachmentEpoch)
    case let .sessionExited(e, status, revision):
      try u64(e, .attachmentEpoch)
      try c.encode(status, forKey: .status)
      try u64(revision, .finalScreenRevision)
    case let .viewport(e, lines):
      try u64(e, .attachmentEpoch)
      try c.encode(lines, forKey: .lines)
    case let .requestFullScreen(e): try u64(e, .attachmentEpoch)
    case let .copySelection(s):
      try u64(s.attachmentEpoch, .attachmentEpoch)
      try u64(s.requestID, .requestID)
      try u64(s.generation, .generation)
      try c.encode(s.alternateScreen, forKey: .alternateScreen)
      try u64(s.startRow, .startRow)
      try u64(s.startColumn, .startColumn)
      try u64(s.endRow, .endRow)
      try u64(s.endColumn, .endColumn)
      try c.encode(s.unit, forKey: .unit)
      try c.encode(
        s.screenRowVersions.map { $0.map { WireUInt64($0) } },
        forKey: .screenRowVersions
      )
    case let .copyChunk(e, request, index, text):
      try u64(e, .attachmentEpoch)
      try u64(request, .requestID)
      try u64(index, .index)
      try c.encode(text, forKey: .text)
    case let .copyResult(e, request, total, error):
      try u64(e, .attachmentEpoch)
      try u64(request, .requestID)
      if let total { try u64(total, .totalBytes) }
      try c.encodeIfPresent(error, forKey: .error)
    case let .error(error):
      try c.encode(error.code, forKey: .code)
      if let s = error.sequence { try u64(s, .sequence) }
      try c.encodeIfPresent(error.message, forKey: .message)
    }
  }
}

/// Additive RST/1 behaviour a host advertises in `Attached`. Older peers
/// ignore the field; names this build does not know are ignored.
public struct RSTFeatures: OptionSet, Hashable, Sendable {
  public var rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  /// `kp:<key>` key names. Clients send the main-keyboard key without it.
  public static let keypadKeys = RSTFeatures(rawValue: 1 << 0)
  /// The host accepts `Viewport` and presents the requested history
  /// window to this attachment only; the host's own view never moves.
  public static let historyViewport = RSTFeatures(rawValue: 1 << 1)
  /// Screens in the shared frame model, `SMXB/1` encodings 2 and 3 (§6, §7.2).
  public static let paneFrames = RSTFeatures(rawValue: 1 << 2)
  /// Deltas against the last acknowledged screen; needs `paneFrames` (§7.4).
  public static let screenDeltas = RSTFeatures(rawValue: 1 << 3)
  /// `CopySelection`; needs `paneFrames` and `historyViewport` (§7.5).
  public static let copySelection = RSTFeatures(rawValue: 1 << 4)

  public static let supported: RSTFeatures = [
    .keypadKeys, .historyViewport, .paneFrames, .screenDeltas, .copySelection,
  ]

  private static let wireNames: [(String, RSTFeatures)] = [
    ("keypadKeys", .keypadKeys), ("historyViewport", .historyViewport),
    ("paneFrames", .paneFrames), ("screenDeltas", .screenDeltas),
    ("copySelection", .copySelection),
  ]

  /// What both peers listed, with dependent features dropped when the
  /// feature they need is missing.
  public func agreed(with other: RSTFeatures) -> RSTFeatures {
    var both = intersection(other)
    if !both.contains(.paneFrames) {
      both.subtract([.screenDeltas, .copySelection])
    }
    if !both.contains(.historyViewport) { both.remove(.copySelection) }
    return both
  }

  public init(names: [String]) {
    self = Self.wireNames.reduce(into: []) { result, entry in
      if names.contains(entry.0) { result.insert(entry.1) }
    }
  }

  public var names: [String] {
    Self.wireNames.compactMap { contains($0.1) ? $0.0 : nil }
  }
}
