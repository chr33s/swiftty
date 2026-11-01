import Foundation

/// Validated OSC 7501 data. Revisions are decimal strings so JavaScript does
/// not round the engine's UInt64 revision counters.
public struct JavaScriptProgramStatus: Codable, Sendable, Equatable {
  public var id: String
  public var state: String
  public var kind: String?
  public var progress: UInt8?
  public var app: String?
  public var title: String?
  public var message: String?
  public var revision: String

  public init(
    id: String,
    state: String,
    kind: String?,
    progress: UInt8?,
    app: String?,
    title: String?,
    message: String?,
    revision: String
  ) {
    self.id = id
    self.state = state
    self.kind = kind
    self.progress = progress
    self.app = app
    self.title = title
    self.message = message
    self.revision = revision
  }
}

public struct JavaScriptStatusChange: Codable, Sendable, Equatable {
  public enum Kind: String, Codable, Sendable {
    case report, removed, reset, sync
  }
  public var type: Kind
  public var paneId: String
  public var terminalEpoch: String
  public var record: JavaScriptProgramStatus?
  public var ids: [String]?
  public var records: [JavaScriptProgramStatus]?

  public init(
    type: Kind,
    paneId: String,
    terminalEpoch: String,
    record: JavaScriptProgramStatus? = nil,
    ids: [String]? = nil,
    records: [JavaScriptProgramStatus]? = nil
  ) {
    self.type = type
    self.paneId = paneId
    self.terminalEpoch = terminalEpoch
    self.record = record
    self.ids = ids
    self.records = records
  }
}
