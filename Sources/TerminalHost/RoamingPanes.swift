#if os(macOS)
import Dispatch
import Foundation
import ScreenProtocol
import SessionCore
import SwiftMuxClient
import SwiftMuxExport
import SwiftMuxXPC
import SwiftMuxProtocol
import SwiftMuxService

/// One SMX connection a roaming session drives: requests, sequenced input
/// and events, plus the pane reads RST/1 needs (screens, copy, history
/// window). Every method and callback runs on the session's queue.
///
/// In process the reads borrow the pane's terminal state; through a
/// durable gateway they come from the frames the worker sends this
/// connection.
package protocol RoamingMux: AnyObject {
  var onEvent: ((MuxEvent) -> Void)? { get set }
  var onPaneChanged: ((PaneID) -> Void)? { get set }
  var onClosed: ((String) -> Void)? { get set }
  var welcome: Welcome? { get }
  /// False once closed or rejected: requests then fail immediately.
  var isOpen: Bool { get }

  /// Connects and says hello; requests may be issued immediately after.
  func connect()
  func request(
    _ command: MuxCommand,
    expiresAt: ContinuousClock.Instant?,
    isAdmitted: (@Sendable () -> Bool)?,
    _ completion: @escaping (MuxResult) -> Void
  )
  /// Input sequences restart at one for each attachment.
  func resetInput()
  func input(
    _ payload: InputPayload,
    attachment: AttachmentID,
    pane: PaneID,
    _ completion: @escaping (MuxError?) -> Void
  )
  /// Releases any lease held through this connection. Pending callbacks
  /// complete with `connectionLost`; `then` waits for disconnection.
  func close(then completion: (() -> Void)?)

  /// The pane's screen as RST/1 sends it, for the history window starting
  /// at absolute row `window.top` when its generation still matches. Nil
  /// when the pane is gone or not yet shown.
  func capture(
    pane: PaneID,
    stamp: ScreenExporter.Stamp,
    window: (top: Int, generation: UInt64)?,
    _ completion: @escaping @Sendable (RoamingSession.CapturedScreen?) -> Void
  )
  /// Text of a selection the client saw. Nil when the pane is gone.
  func copy(
    pane: PaneID,
    _ request: CopySelectionRequest,
    _ completion: @escaping @Sendable (Result<String, MuxError>?) -> Void
  )
  /// The history window top after moving `lines` from `top` (nil: live),
  /// with the addressing generation it is in. Nil when the pane is gone.
  func historyTop(
    pane: PaneID,
    from top: Int?,
    generation: UInt64,
    moving lines: Int,
    _ completion: @escaping @Sendable ((top: Int?, generation: UInt64)?) -> Void
  )
  /// Shows the history window starting at `top` (nil: live output).
  func present(pane: PaneID, top: Int?, generation: UInt64)
}

extension RoamingMux {
  package func request(
    _ command: MuxCommand,
    _ completion: @escaping (MuxResult) -> Void
  ) { request(command, expiresAt: nil, isAdmitted: nil, completion) }

  package func close() { close(then: nil) }
}

/// Where a roaming host's sessions reach their panes: the in-process
/// SwiftMux service, or the workers behind a durable gateway.
package protocol RoamingPanes: Sendable {
  /// A new, unconnected connection for one attachment of `workspace`.
  func makeMux(workspace: WorkspaceID, queue: DispatchQueue) -> any RoamingMux
  /// Tells scripts a device's session changed state.
  func sessionChanged(_ id: String, workspace: WorkspaceID, state: String)
}

/// An in-process SwiftMux service, reached over SMX exactly as a durable
/// gateway reaches its workers: one forwarding listener, frames for
/// screens, `setViewport` and `copySelection`.
///
/// Not the installed topology (the gateway serves roaming): tests, and
/// `swiftmux-agent --roaming-config` for development.
final class LocalRoamingPanes: RoamingPanes {
  let service: MuxService
  private let endpoint: SMXEndpoint

  init(service: MuxService) {
    self.service = service
    endpoint = service.listenForwarding()
  }

  func makeMux(workspace: WorkspaceID, queue: DispatchQueue) -> any RoamingMux {
    let endpoint = endpoint
    return SMXRoamingMux(queue: queue) {
      try await MuxConnection.connect(
        endpoint: endpoint,
        frontend: .native,
        forwardedTransport: .remote
      )
    }
  }

  func sessionChanged(_ id: String, workspace: WorkspaceID, state: String) {
    service.roamingSessionChanged(id, workspace: workspace, state: state)
  }
}
#endif

#if os(macOS)
/// Everything a roaming registry asks of SwiftMux beyond its sessions'
/// panes: the service epoch grants name, workspace-wide control requests
/// (`newWorkspace`, `endWorkspace`, `listWorkspaces`, attention and inbox),
/// and the cleanup checks a sweep runs atomically with ending a workspace.
package protocol RoamingWorkspaces: RoamingPanes {
  /// The epoch grants are bound to; a new one invalidates every grant.
  var instance: SwiftMuxProtocol.ServerInstanceID { get }
  /// Never holds a lease, so `leaseHeldElsewhere` reports any holder.
  func control(_ command: MuxCommand) async -> MuxResult
  /// Starts a workspace; `resourceLimit` when no more may start.
  func create(
    _ request: NewWorkspaceRequest
  ) async -> Result<WorkspaceID, MuxError>
  /// Ends `workspace` only if every pane exited (`onlyIfExited`), or only
  /// if no native frontend ever used it, checked in service order.
  func endIfUnused(_ workspace: WorkspaceID, onlyIfExited: Bool) async -> Bool
  /// Control requests still awaiting a reply (tests).
  var pendingControlRequestCount: Int { get }
  func close()
}

/// An in-process SwiftMux service, through one control client. Tests and
/// development roaming only, like `LocalRoamingPanes`.
final class LocalRoamingWorkspaces: RoamingWorkspaces {
  let service: MuxService
  private let panes: LocalRoamingPanes
  private let session: MuxLocalSession

  init(service: MuxService, control: MuxLocalSession) {
    self.service = service
    panes = LocalRoamingPanes(service: service)
    session = control
    control.queue.sync {
      control.connect(to: service, frontend: .control, remote: true)
    }
  }

  var instance: SwiftMuxProtocol.ServerInstanceID { service.instance }

  func control(_ command: MuxCommand) async -> MuxResult {
    await session.request(command)
  }

  func create(
    _ request: NewWorkspaceRequest
  ) async -> Result<WorkspaceID, MuxError> {
    switch await session.request(.newWorkspace(request)) {
    case let .success(.created(ws)): .success(ws.id)
    case let .failure(error): .failure(error)
    case .success: .failure(MuxError(.invalidRequest, "unexpected reply"))
    }
  }

  func endIfUnused(_ workspace: WorkspaceID, onlyIfExited: Bool) async -> Bool {
    await withCheckedContinuation { continuation in
      if onlyIfExited {
        service.endExitedWorkspace(workspace) {
          continuation.resume(returning: $0)
        }
      } else {
        service.endReservedWorkspace(workspace) {
          continuation.resume(returning: $0)
        }
      }
    }
  }

  var pendingControlRequestCount: Int {
    session.queue.sync { session.pendingRequestCount }
  }

  func close() {
    let session = session
    session.queue.async { session.close() }
  }

  func makeMux(workspace: WorkspaceID, queue: DispatchQueue) -> any RoamingMux {
    panes.makeMux(workspace: workspace, queue: queue)
  }

  func sessionChanged(_ id: String, workspace: WorkspaceID, state: String) {
    panes.sessionChanged(id, workspace: workspace, state: state)
  }
}
#endif
