import Foundation

/// Native gateway bootstrap/control. Terminal traffic uses the returned SMX
/// route; this protocol is never accepted on a worker or roaming connection.
public enum GatewayControl {
  public static let version = 1
  public static let recordLimit = 4 << 20
  public static let maxPeers = 64
  public static let maxJobs = 64
  public static let retainedByteLimit = 8 << 20
  public static let maxWorkspaces = 4096
}

public enum GatewayControlRequest: Codable, Sendable, Equatable {
  case hello(version: Int)
  case command(
    gateway: ServerInstanceID,
    sequence: UInt64,
    body: GatewayControlCommand
  )
  case acknowledge(sequence: UInt64)
}

public enum GatewayControlCommand: Codable, Sendable, Equatable {
  case listWorkspaces
  case route(WorkspaceSelector, role: AttachmentRole)
  case create(WorkspaceID, NewWorkspaceRequest)
  case end(WorkspaceSelector)
  // Saved layouts (spec.durability.md §12.2). Local native frontends only.
  /// Lists saved records; marks Saved ones as offered.
  case savedWorkspaces
  case reopenSaved(SavedReopenRequest)
  case setSavedPolicy(SavedLayoutPolicy, expectedRevision: UInt64)
  /// Nil deletes every record and the key.
  case deleteSaved(WorkspaceID?)
}

public enum GatewayControlEvent: Codable, Sendable {
  case welcome(version: Int, gateway: ServerInstanceID)
  case result(sequence: UInt64, value: GatewayControlResult)
  case refused(MuxError)
}

public enum GatewayControlResult: Codable, Sendable {
  case success(GatewayControlReply)
  case failure(MuxError)
}

public enum GatewayControlReply: Codable, Sendable {
  case workspaces([GatewayWorkspaceRecord])
  /// This reply must carry exactly one XPC endpoint. Other replies carry none.
  case route(GatewayRouteDescriptor)
  case created(WorkspaceID)
  case ended
  case savedWorkspaces(SavedWorkspaceList)
  case reopened(WorkspaceID, WorkspaceTemplateOutcome)
  case savedPolicy(SavedLayoutPolicy)
  case deletedSaved
}

public struct GatewayRouteDescriptor: Codable, Sendable, Equatable {
  public let workspace: WorkspaceID
  public let server: ServerInstanceID
  public init(workspace: WorkspaceID, server: ServerInstanceID) {
    self.workspace = workspace
    self.server = server
  }
}

public struct GatewayWorkspaceRecord: Codable, Sendable {
  public enum State: Codable, Sendable, Equatable {
    case starting, discovering, empty, available
    case unavailable(MuxError)
  }
  public let workspace: WorkspaceID
  public let state: State
  /// Last known metadata; availability is determined by state, not this value.
  public let summary: WorkspaceSummary?
  public init(workspace: WorkspaceID, state: State, summary: WorkspaceSummary?)
  {
    self.workspace = workspace
    self.state = state
    self.summary = summary
  }
}
