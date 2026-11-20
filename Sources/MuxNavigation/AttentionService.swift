import Foundation
import SwiftMuxProtocol

/// A host the recipient configured themselves. Only an opaque ID and a
/// display name reach navigation; endpoints and credentials stay with
/// the platform's host store.
public struct NavigationHost: Sendable, Hashable, Identifiable {
  public var id: UUID
  /// User-chosen nickname, for host pickers.
  public var name: String

  public init(id: UUID, name: String) {
    self.id = id
    self.name = name
  }
}

/// The recipient's configured hosts (step 2). Links never add to it.
public protocol AttentionHostDirectory: Sendable {
  func configuredHosts() async -> [NavigationHost]
}

/// A fixed list, for tests and single-host platforms.
public struct StaticHostDirectory: AttentionHostDirectory {
  public var hosts: [NavigationHost]
  public init(_ hosts: [NavigationHost]) { self.hosts = hosts }
  public func configuredHosts() async -> [NavigationHost] { hosts }
}

/// Where to activate: the pane and the workspace/tab that hold it.
public struct PaneTarget: Sendable, Hashable {
  public var workspace: WorkspaceID
  public var tab: TabID?
  public var pane: PaneID

  public init(workspace: WorkspaceID, tab: TabID?, pane: PaneID) {
    self.workspace = workspace
    self.tab = tab
    self.pane = pane
  }
}

/// A workspace's interactive lease as a takeover prompt needs it.
public struct LeaseState: Sendable, Equatable {
  /// The generation `takeover` must name.
  public var generation: UInt64
  public var holder: LeaseHolder?

  public init(generation: UInt64, holder: LeaseHolder?) {
    self.generation = generation
    self.holder = holder
  }
}

public enum AttentionServiceError: Error, Sendable, Equatable {
  /// Not reachable now; retrying may succeed.
  case offline(String)
  case unauthorized
  /// The service no longer knows this item, pane or workspace.
  case notFound
  /// The service restarted: every old handle is invalid.
  case serviceRestarted
  /// Another attachment controls the workspace.
  case leaseHeld
  /// The lease generation moved since the user saw the prompt.
  case leaseChanged
  /// The pane exited while opening.
  case paneExited
  /// This transport cannot serve attention requests (yet).
  case unsupported(String)
  case other(String)
}

/// One authenticated connection to a host's attention metadata and
/// workspace activation (steps 3–7). Metadata calls never take a lease.
public protocol AttentionService: Sendable {
  /// The service instance this connection authenticated to.
  func serviceEpoch() async throws(AttentionServiceError) -> ServerInstanceID
  /// Reads an occurrence without taking an interactive lease.
  func locate(
    _ reference: AttentionReference
  ) async throws(AttentionServiceError) -> AttentionLocation
  func leaseState(
    of workspace: WorkspaceID
  ) async throws(AttentionServiceError) -> LeaseState
  /// Attaches (or, with `expectedLease`, explicitly takes over) and
  /// activates `target`'s tab and pane. Without `expectedLease` this must
  /// fail with `.leaseHeld` rather than displace another holder.
  func open(
    _ target: PaneTarget,
    takeover expectedLease: UInt64?
  ) async throws(AttentionServiceError)
  /// Marks exactly this occurrence seen; never resolves it.
  func markSeen(
    _ reference: AttentionReference
  ) async throws(AttentionServiceError)
  func close() async
}

/// Authenticates to a configured host (local XPC or remote SSH/RST).
public protocol AttentionServiceConnector: Sendable {
  func connect(
    to host: NavigationHost
  ) async throws(AttentionServiceError) -> any AttentionService
}

/// A connector for transports that cannot resolve attention yet: every
/// connection reports a recoverable unavailable state.
public struct UnavailableAttentionConnector: AttentionServiceConnector {
  public var reason: String
  public init(reason: String) { self.reason = reason }
  public func connect(
    to host: NavigationHost
  ) async throws(AttentionServiceError) -> any AttentionService {
    throw .unsupported(reason)
  }
}
