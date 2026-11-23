import Observation
import SwiftMuxProtocol

/// Passive window presentation. Terminal metadata can be forged or coalesced;
/// neither these values nor observation callbacks authorize process operations
/// or represent exactly-once completion. The coordinator handles service events.
@MainActor
@Observable
final class WorkspaceDisplayState {
  /// Sanitized titles supplied by terminal programs and workspace snapshots.
  var titles: [PaneID: String] = [:]
  /// Foreground programs the service reports (`MuxEvent.program`).
  var programs: [PaneID: String] = [:]
  /// Panes with output the user has not seen (hidden tabs, bells).
  var activity: Set<PaneID> = []
}
