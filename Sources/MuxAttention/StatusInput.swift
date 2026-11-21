import Foundation
import SwiftMuxProtocol

/// One OSC 7501 record as a pane's terminal reports it, before identity
/// and context are attached. Text is untrusted display data.
public struct StatusRecord: Sendable, Equatable, Codable {
  /// Record id; `""` is the root.
  public var path: String
  public var state: AttentionState
  public var kind: AttentionBlockedKind?
  public var progress: UInt8?
  public var app: String?
  public var title: String?
  public var message: String?

  public init(
    path: String = "",
    state: AttentionState,
    kind: AttentionBlockedKind? = nil,
    progress: UInt8? = nil,
    app: String? = nil,
    title: String? = nil,
    message: String? = nil
  ) {
    self.path = path
    self.state = state
    self.kind = kind
    self.progress = progress
    self.app = app
    self.title = title
    self.message = message
  }

}

/// One change to a pane's records, in terminal stream order. A terminal
/// reset is not a change: it arrives as a new `TerminalEpochID`.
public enum StatusChange: Sendable, Equatable {
  /// The record at `path` was written (whole-record replacement).
  case report(StatusRecord)
  /// Records removed by a clear, prompt start, process exit or eviction.
  /// Silence never removes a record.
  case removed([String])
  /// Every current record, after intermediate changes were lost (a
  /// journal overflow): paths not listed are removed.
  case sync([StatusRecord])
}

/// Where a pane lives when its status changes.
public struct AttentionContext: Sendable, Equatable {
  public var workspace: WorkspaceID
  public var tab: TabID?

  public init(workspace: WorkspaceID, tab: TabID?) {
    self.workspace = workspace
    self.tab = tab
  }
}

/// What an exact `AttentionReference` names now.
public enum AttentionLookup: Sendable, Equatable {
  /// A current request, or an unreviewed failure or result of a live pane.
  case available(AttentionItem)
  /// Resolved, superseded or reviewed; kept in bounded history.
  case stale(AttentionItem)
  /// The pane exited (its final failure or result may be unreviewed).
  case paneExited(AttentionItem)
  /// Never known, evicted, or from another service epoch.
  case missing

  public var item: AttentionItem? {
    switch self {
    case let .available(i), let .stale(i), let .paneExited(i): i
    case .missing: nil
    }
  }

  public var availability: AttentionLocation.Availability {
    switch self {
    case .available: .available
    case .stale: .stale
    case .paneExited: .paneExited
    case .missing: .missing
    }
  }
}
