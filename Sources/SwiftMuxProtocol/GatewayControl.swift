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
  /// C1: output carried into a reopened workspace's pane, in pages.
  case previousOutput(WorkspaceID, pane: PaneID, offset: Int)
  /// Nil pane discards every pane's previous output.
  case discardPreviousOutput(WorkspaceID, pane: PaneID?)
  /// Installer state (spec.durability.md §9): the guardian incarnation and
  /// every workspace it retains, available or not.
  case installationStatus
  /// The ordinary update (§5.2): this gateway pauses, settles, checks the
  /// staged candidate under the barrier and hands over to the installer.
  case prepareUpdate(GatewayUpdateRequest)
}

public struct GatewayUpdateRequest: Codable, Sendable, Equatable {
  /// The staged candidate bundle, revalidated by the gateway.
  public let candidate: String
  /// The worker build to select once the candidate runs, and its protocol.
  public let workerBuild: String?
  public let workerProtocol: Int?
  public init(candidate: String, workerBuild: String?, workerProtocol: Int?) {
    self.candidate = candidate
    self.workerBuild = workerBuild
    self.workerProtocol = workerProtocol
  }
}

public enum GatewayUpdateResult: Codable, Sendable, Equatable {
  /// Admission is paused in `replacing`; install `build` now.
  case handedOver(build: String)
  /// Selections unchanged, admission resumed.
  case deferred(MuxError)
}

/// What an installer needs before guardian maintenance or uninstall.
public struct GatewayInstallationStatus: Codable, Sendable, Equatable {
  public let guardianIncarnation: UUID
  /// Running, unavailable and retained-exit workspaces; the empty-state
  /// barrier holds only when this is zero.
  public let workspaces: Int
  /// Admission is paused for a gateway replacement the successor has not
  /// finished (§5.2).
  public let updatePending: Bool?
  public init(
    guardianIncarnation: UUID,
    workspaces: Int,
    updatePending: Bool? = nil
  ) {
    self.guardianIncarnation = guardianIncarnation
    self.workspaces = workspaces
    self.updatePending = updatePending
  }
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
  case previousOutput(SavedOutputPage)
  case installation(GatewayInstallationStatus)
  case update(GatewayUpdateResult)
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
