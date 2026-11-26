import Foundation

/// An opaque identity. Names and indexes are display labels; these are not.
public struct MuxID<Tag>: Hashable, Sendable, Codable, CustomStringConvertible {
  public let rawValue: UUID

  public init() { rawValue = UUID() }
  public init(rawValue: UUID) { self.rawValue = rawValue }

  public init?(_ string: String) {
    guard let uuid = UUID(uuidString: string) else { return nil }
    rawValue = uuid
  }

  public init(from decoder: any Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(UUID.self)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public var description: String { rawValue.uuidString }
  /// First eight hex digits, for logs and terse displays.
  public var short: String { String(rawValue.uuidString.prefix(8)) }
}

public enum ServerInstanceTag: Sendable {}
public enum WorkspaceTag: Sendable {}
public enum TabTag: Sendable {}
public enum PaneTag: Sendable {}
public enum LayerTag: Sendable {}
public enum AttachmentTag: Sendable {}

/// A new service process receives a new instance; old handles are invalid.
public typealias ServerInstanceID = MuxID<ServerInstanceTag>
public typealias WorkspaceID = MuxID<WorkspaceTag>
public typealias TabID = MuxID<TabTag>
public typealias PaneID = MuxID<PaneTag>
public typealias LayerID = MuxID<LayerTag>
public typealias AttachmentID = MuxID<AttachmentTag>
