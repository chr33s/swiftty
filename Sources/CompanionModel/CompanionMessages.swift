import Foundation

/// Opaque correlation token for one watch request.
public struct CompanionRequestID: Hashable, Sendable, Codable,
  CustomStringConvertible
{
  public let rawValue: String

  public init?(rawValue: String) {
    guard !rawValue.isEmpty,
      rawValue.utf8.count <= CompanionLimits.maxRequestIDBytes,
      rawValue.unicodeScalars.allSatisfy({
        $0.isASCII && !CompanionText.isDisallowed($0)
      })
    else { return nil }
    self.rawValue = rawValue
  }

  public static func random() -> CompanionRequestID {
    CompanionRequestID(rawValue: UUID().uuidString)!
  }

  public var description: String { rawValue }

  public init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    guard let id = CompanionRequestID(rawValue: raw) else {
      throw CompanionCodecError.invalid("request id")
    }
    self = id
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.singleValueContainer()
    try c.encode(rawValue)
  }
}

/// Watch -> iPhone request. Only two operations exist; neither can start
/// an SSH login, an RST attachment, or deliver input of any kind.
public struct CompanionRequest: Hashable, Sendable {
  public enum Kind: String, Hashable, Sendable, Codable {
    /// Latest iPhone-observed status.
    case refresh
    /// Latest status plus, if opted in and the iPhone app is in the
    /// foreground, one bounded text preview.
    case preview
  }

  public let id: CompanionRequestID
  public let kind: Kind

  public init(id: CompanionRequestID = .random(), kind: Kind) {
    self.id = id
    self.kind = kind
  }
}

/// Why a preview request was answered with status only.
public enum CompanionPreviewUnavailable: String, Hashable, Sendable, Codable {
  /// The user has not opted in on the iPhone (the default).
  case notEnabled
  /// The iPhone app is not in the foreground; previews are only served
  /// from a foreground app.
  case phoneNotForeground
  /// No screen has been observed for the selected session.
  case noScreen
}

/// iPhone -> watch reply to one `CompanionRequest`.
public enum CompanionReply: Hashable, Sendable {
  case status(
    CompanionRequestID,
    CompanionStatus,
    previewUnavailable: CompanionPreviewUnavailable?,
    revision: UInt64 = 0,
    publisherID: UUID
  )
  case preview(
    CompanionRequestID,
    CompanionStatus,
    CompanionPreview,
    revision: UInt64 = 0,
    publisherID: UUID
  )
  /// Companion sharing is turned off on the iPhone; the watch must clear
  /// everything it cached.
  case disabled(
    CompanionRequestID,
    clearedAt: Date,
    revision: UInt64 = 0,
    publisherID: UUID
  )

  /// Publication order, independent of observation/capture time.
  public var revision: UInt64 {
    switch self {
    case .status(_, _, _, let revision, _), .preview(_, _, _, let revision, _),
      .disabled(_, _, let revision, _):
      revision
    }
  }

  public var publisherID: UUID {
    switch self {
    case .status(_, _, _, _, let publisher),
      .preview(_, _, _, _, let publisher), .disabled(_, _, _, let publisher):
      publisher
    }
  }

  public var requestID: CompanionRequestID {
    switch self {
    case .status(let id, _, _, _, _), .preview(let id, _, _, _, _),
      .disabled(let id, _, _, _):
      id
    }
  }
}

/// Latest-state application context (iPhone -> watch).
///
/// Only non-sensitive status can be represented: there is no case, field
/// or encoding that carries preview text, so preview content can never be
/// queued for background delivery.
public enum CompanionApplicationContext: Hashable, Sendable {
  case status(CompanionStatus, revision: UInt64 = 0, publisherID: UUID)
  /// Companion sharing was turned off; clear cached companion data.
  case cleared(at: Date, revision: UInt64 = 0, publisherID: UUID)

  /// Publication order, shared with immediate replies and attention batches.
  public var revision: UInt64 {
    switch self {
    case .status(_, let revision, _), .cleared(_, let revision, _): revision
    }
  }

  public var publisherID: UUID {
    switch self {
    case .status(_, _, let publisher), .cleared(_, _, let publisher): publisher
    }
  }

  public static let dictionaryKey = "swiftty.companion.context"

  /// The `WCSession.updateApplicationContext` dictionary.
  public func dictionary() throws(CompanionCodecError) -> [String: Data] {
    [Self.dictionaryKey: try CompanionCodec.encode(self)]
  }

  /// Decodes a received application context. Any extra key, wrong value
  /// type, or invalid payload is rejected.
  public init(dictionary: [String: Any]) throws(CompanionCodecError) {
    guard dictionary.count == 1,
      let data = dictionary[Self.dictionaryKey] as? Data
    else { throw .malformed }
    self = try CompanionCodec.decodeContext(data)
  }
}

// MARK: - Wire representation

enum WireType: String, Codable {
  case refresh, preview, status, disabled, cleared
}

enum EnvelopeKeys: String, CodingKey, CaseIterable {
  case v, type, id, status, preview, previewUnavailable, clearedAt, revision,
    publisher
}

extension KeyedDecodingContainer where K == EnvelopeKeys {
  /// Checks the version before anything else is interpreted.
  func header() throws -> WireType {
    let version = try decode(Int.self, forKey: .v)
    guard version == CompanionLimits.version else {
      throw CompanionCodecError.unsupportedVersion(version)
    }
    return try decode(WireType.self, forKey: .type)
  }
}

private func checkOnly(
  _ decoder: any Decoder,
  _ allowed: Set<EnvelopeKeys>
) throws {
  let c = try decoder.container(keyedBy: StrictKeys.AnyKey.self)
  let names = Set(allowed.map(\.stringValue))
  for key in c.allKeys where !names.contains(key.stringValue) {
    throw CompanionCodecError.invalid("unexpected field")
  }
}

extension CompanionRequest: Codable {
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: EnvelopeKeys.self)
    let type = try c.header()
    try checkOnly(decoder, [.v, .type, .id])
    let kind: Kind =
      switch type {
      case .refresh: .refresh
      case .preview: .preview
      default: throw CompanionCodecError.invalid("not a request")
      }
    self.init(
      id: try c.decode(CompanionRequestID.self, forKey: .id),
      kind: kind
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: EnvelopeKeys.self)
    try c.encode(CompanionLimits.version, forKey: .v)
    try c.encode(kind == .refresh ? WireType.refresh : .preview, forKey: .type)
    try c.encode(id, forKey: .id)
  }
}

extension CompanionReply: Codable {
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: EnvelopeKeys.self)
    let type = try c.header()
    let id = try c.decode(CompanionRequestID.self, forKey: .id)
    let revision = try c.decode(UInt64.self, forKey: .revision)
    let publisher = try c.decode(UUID.self, forKey: .publisher)
    switch type {
    case .status:
      try checkOnly(
        decoder,
        [.v, .type, .id, .status, .previewUnavailable, .revision, .publisher]
      )
      self = .status(
        id,
        try c.decode(CompanionStatus.self, forKey: .status),
        previewUnavailable: try c.decodeIfPresent(
          CompanionPreviewUnavailable.self,
          forKey: .previewUnavailable
        ),
        revision: revision,
        publisherID: publisher
      )
    case .preview:
      try checkOnly(
        decoder,
        [.v, .type, .id, .status, .preview, .revision, .publisher]
      )
      self = .preview(
        id,
        try c.decode(CompanionStatus.self, forKey: .status),
        try c.decode(CompanionPreview.self, forKey: .preview),
        revision: revision,
        publisherID: publisher
      )
    case .disabled:
      try checkOnly(
        decoder,
        [.v, .type, .id, .clearedAt, .revision, .publisher]
      )
      self = .disabled(
        id,
        clearedAt: try CompanionTime.decode(c, .clearedAt),
        revision: revision,
        publisherID: publisher
      )
    default: throw CompanionCodecError.invalid("not a reply")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: EnvelopeKeys.self)
    try c.encode(CompanionLimits.version, forKey: .v)
    try c.encode(revision, forKey: .revision)
    try c.encode(publisherID, forKey: .publisher)
    switch self {
    case .status(let id, let status, let reason, _, _):
      try c.encode(WireType.status, forKey: .type)
      try c.encode(id, forKey: .id)
      try c.encode(status, forKey: .status)
      try c.encodeIfPresent(reason, forKey: .previewUnavailable)
    case .preview(let id, let status, let preview, _, _):
      try c.encode(WireType.preview, forKey: .type)
      try c.encode(id, forKey: .id)
      try c.encode(status, forKey: .status)
      try c.encode(preview, forKey: .preview)
    case .disabled(let id, let clearedAt, _, _):
      try c.encode(WireType.disabled, forKey: .type)
      try c.encode(id, forKey: .id)
      try c.encode(CompanionTime.wire(clearedAt), forKey: .clearedAt)
    }
  }
}

extension CompanionApplicationContext: Codable {
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: EnvelopeKeys.self)
    let type = try c.header()
    let revision = try c.decode(UInt64.self, forKey: .revision)
    let publisher = try c.decode(UUID.self, forKey: .publisher)
    switch type {
    case .status:
      try checkOnly(decoder, [.v, .type, .status, .revision, .publisher])
      self = .status(
        try c.decode(CompanionStatus.self, forKey: .status),
        revision: revision,
        publisherID: publisher
      )
    case .cleared:
      try checkOnly(decoder, [.v, .type, .clearedAt, .revision, .publisher])
      self = .cleared(
        at: try CompanionTime.decode(c, .clearedAt),
        revision: revision,
        publisherID: publisher
      )
    default: throw CompanionCodecError.invalid("not an application context")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: EnvelopeKeys.self)
    try c.encode(CompanionLimits.version, forKey: .v)
    try c.encode(revision, forKey: .revision)
    try c.encode(publisherID, forKey: .publisher)
    switch self {
    case .status(let status, _, _):
      try c.encode(WireType.status, forKey: .type)
      try c.encode(status, forKey: .status)
    case .cleared(let date, _, _):
      try c.encode(WireType.cleared, forKey: .type)
      try c.encode(CompanionTime.wire(date), forKey: .clearedAt)
    }
  }
}
