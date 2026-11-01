import Dispatch
import Foundation
import SwiftMuxProtocol
import SwifttyEngine
import SwifttyJS

public struct MuxServiceConfiguration: Sendable {
  /// The shared automation VM. The host installs callbacks before creating the service.
  public var javaScriptRuntime: JavaScriptRuntime?
  /// Production config, evaluated once before the first pane starts.
  public var javaScriptDirectory: URL?
  /// Private fixture observation; production callers leave this nil.
  var observePaneIO: (@Sendable (PaneID, PaneIOObservation) -> Void)?
  public var launcherPath: String
  public var limits = MuxLimits.standard
  public var innerTerm = SMX.fallbackInnerTerm
  public var terminfoDirectory: String?
  /// Code-signing requirement every peer must satisfy (shipping builds).
  public var peerRequirement: String?
  /// Exit delay once the service reaches its empty-state barrier; nil
  /// keeps the service running (tests, foreground use). Invalid delays
  /// also keep it running rather than triggering an immediate exit.
  public var idleExitDelay: TimeInterval?
  /// Compress idle pane history where supported. Local policy only: pane
  /// budgets, `MuxLimits` and SMX messages are unchanged.
  public var scrollbackCompression = true
  /// Runs on the pane queue before each launch (tests hold a launch open).
  package var beforeLaunch: (@Sendable () -> Void)?

  public init(launcherPath: String) { self.launcherPath = launcherPath }
}

struct Tab {
  var id = TabID()
  var name: String
  var layout: LayoutNode
  var activePane: PaneID
  var zoomedPane: PaneID?

  var snapshot: TabSnapshot {
    TabSnapshot(
      id: id,
      name: name,
      layout: layout,
      activePane: activePane,
      zoomedPane: zoomedPane
    )
  }
}

struct Workspace {
  var id = WorkspaceID()
  var name: String
  var createdAt = Date()
  var tabs: [Tab]
  var activeTab: TabID
  var remainOnExit: Bool
  /// Local use survives detach; remote reservation expiry must not end
  /// a workspace that another frontend has already used.
  var wasAttachedLocally = false
  /// Environment snapshot taken at creation; new panes reuse it.
  var launch: LaunchSpec
  var layoutRevision: UInt64 = 1

  func tabIndex(containing pane: PaneID) -> Int? {
    tabs.firstIndex { $0.layout.contains(pane) }
  }

  var allPanes: [PaneID] { tabs.flatMap(\.layout.panes) }
}

struct PaneRecord {
  let runtime: PaneRuntime
  let workspace: WorkspaceID
  var columns: Int
  var rows: Int
  var title = ""
  var workingDirectory: String?
  var exitStatus: Int32?
  /// Removed from the layout; kept only until its process is reaped.
  var detachedFromLayout = false

  func summary(_ id: PaneID) -> PaneSummary {
    PaneSummary(
      id: id,
      columns: columns,
      rows: rows,
      title: title,
      pid: runtime.pid > 0 ? runtime.pid : nil,
      exitStatus: exitStatus,
      workingDirectory: workingDirectory
    )
  }
}

/// How the service reaches a client.
enum ClientTransport {
  case xpc(SMXChannel)
  /// In-process (the roaming bridge): values, never encoded.
  case local(LocalClientSink)
}

final class Client {
  let id: UUID
  let transport: ClientTransport
  var hello: Hello?
  /// Receives `workspaces` events (metadata only, no lease).
  var observesWorkspaces = false
  /// Receives `inbox` events.
  var subscribesInbox = false
  /// Bridged from the roaming transport rather than local XPC.
  var remote = false

  init(channel: SMXChannel) {
    id = UUID()
    transport = .xpc(channel)
  }

  init(id: UUID, local sink: LocalClientSink, remote: Bool) {
    self.id = id
    transport = .local(sink)
    self.remote = remote
  }

  var local: LocalClientSink? {
    if case let .local(sink) = transport { sink } else { nil }
  }

  func cancel() {
    switch transport {
    case let .xpc(channel): channel.cancel()
    case let .local(sink): sink.onClosed("closed by service")
    }
  }
}

/// A frame sent to a client and not yet acknowledged.
struct SentFrame {
  var revision: UInt64
  var bytes: Int
  var geometry: UInt64
  /// The viewport revision it shows: a viewer's window, or the
  /// controller's scroll position and search.
  var viewport: UInt64
}

struct QueuedFrame {
  var frame: SentFrame
  var data: Data
}

struct FrameSlot {
  var dirty = true
  /// Output while the tab was hidden but its old subscription remained.
  var hiddenActivity = false
  /// Token of the capture in progress; a completion carrying any other
  /// token belongs to an earlier subscription and is dropped.
  var capture: UInt64?
  /// Captures with a token up to this one used a window or size that has
  /// since changed. Their failures are not reported; the slot recaptures
  /// (a moved window marks it dirty, a resize when the runtime applies it).
  var supersededThrough: UInt64 = 0
  /// Budget held for `capture` until it completes or the slot goes.
  var reserved = 0
  var inflight: SentFrame?
  /// Newest complete frame waiting behind the one in flight. Replaced,
  /// never queued deeper than one.
  var queued: QueuedFrame?
  var lastSent: UInt64 = 0
  var lastCapture: UInt64 = 0

  /// Records `frame` as sent now.
  mutating func sent(_ frame: SentFrame) {
    inflight = frame
    lastSent = DispatchTime.now().uptimeNanoseconds
  }
}

/// Initial-frame gate. Which panes it waits on is derived when Ready is
/// published (`MuxService.readyFrames`): the subscribed visible panes,
/// less those whose capture failed. Hidden panes are never required.
struct Readiness {
  var enabled = false
  /// The client has named a subscription since attaching.
  var armed = false
  /// Acknowledged frames of subscribed panes, visible or not, so a pane
  /// that becomes visible is already counted.
  var installed: [PaneID: (frame: UInt64, geometry: UInt64, viewport: UInt64)] =
    [:]
  /// Panes whose last capture failed (reported through
  /// `frameUnavailable`); Ready does not wait on them.
  var failed: Set<PaneID> = []
  /// Per resized pane, the geometry generation a frame must carry to
  /// count; frames at an older size never do.
  var minimumGeometry: [PaneID: UInt64] = [:]
  var sent = false

  /// Starts gating with the subscription the client just named.
  mutating func arm(_ panes: [PaneID]) {
    guard enabled, !sent else { return }
    armed = true
    failed.formIntersection(panes)
    installed = installed.filter { panes.contains($0.key) }
  }

  /// A resize produces a new frame; only that one counts, and a pane that
  /// had failed is waited on again.
  mutating func resized(_ pane: PaneID, to geometry: UInt64) {
    guard enabled, !sent else { return }
    installed.removeValue(forKey: pane)
    failed.remove(pane)
    minimumGeometry[pane] = geometry
  }

  /// A failed pane is captured again (its window moved); Ready waits for
  /// the new frame.
  mutating func retry(_ pane: PaneID) {
    guard failed.remove(pane) != nil else { return }
    installed.removeValue(forKey: pane)
  }

  /// Forgets a pane that left the layout.
  mutating func forget(_ pane: PaneID) {
    installed.removeValue(forKey: pane)
    failed.remove(pane)
    minimumGeometry.removeValue(forKey: pane)
  }

  /// Records an acknowledged frame of the pane's current `window` unless
  /// Ready is out or the frame predates a resize. True when recorded (Ready
  /// may now be due). A window that moves later is checked on publish.
  mutating func install(
    _ pane: PaneID,
    _ frame: SentFrame,
    window: UInt64,
  ) -> Bool {
    guard enabled, !sent, frame.viewport == window,
      frame.geometry >= minimumGeometry[pane, default: 0]
    else { return false }
    installed[pane] = (frame.revision, frame.geometry, frame.viewport)
    failed.remove(pane)
    return true
  }
}

/// A search match a viewer selected. Its rows are absolute, so they only
/// identify the match in the history generation it came from.
struct SelectedMatch: Sendable {
  var range: TerminalRange
  /// Position in the match list, kept when rows are renumbered.
  var index: Int
  /// Advances on reflow, clear and alternate-screen switches.
  var historyGeneration: UInt64
}

/// One viewer's window, also what each of its captures applies. Display
/// size never changes the PTY.
struct ViewerViewport: Sendable {
  /// This window's subscription; unique in the service, so a move or
  /// search issued for an earlier one is never applied to it.
  let id: UInt64
  var followTail: Bool
  var historyGeneration: UInt64
  var anchorRow: Int?
  var rows: Int?
  var columns: Int?
  /// The last completed search; a step continues it.
  var searchQuery: String?
  /// Match selected by the last search reply. Capture reselects it after
  /// `search` clears the engine selection.
  var searchSelected: SelectedMatch?
  var revision: UInt64 = 1
}

extension ViewerViewport {
  /// This window as a request for `pane`.
  func request(_ pane: PaneID) -> ViewportRequest {
    ViewportRequest(
      pane: pane,
      anchorRow: anchorRow,
      followTail: followTail,
      historyGeneration: historyGeneration,
      rows: rows,
      columns: columns,
    )
  }
}

struct ActivePaste {
  var pane: PaneID
  var bytes = 0
}

/// One interactive lease on one workspace (spec.inbox.md §2). A client
/// holds at most one; a workspace has at most one holder.
struct Lease {
  let client: UUID
  let attachment = AttachmentID()
  var workspace: WorkspaceID
  /// The workspace's lease generation when this lease was granted.
  var generation: UInt64
  var holder: LeaseHolder
  /// Next input sequence this attachment may submit (watermark + 1).
  var nextInput: UInt64 = 1
  var subscriptions: [PaneID] = []
  var frames: [PaneID: FrameSlot] = [:]
  /// Rotates which subscribed pane is captured first.
  var paneCursor = 0
  var geometryGeneration: UInt64 = 0
  var pastes: [UInt64: ActivePaste] = [:]
  /// Unsubscribed panes already reported through `activity`.
  var reportedActivity: Set<PaneID> = []
  var readiness = Readiness()
}

/// A window command waiting its turn, with its own reply so it can be
/// failed early when its window goes.
struct WaitingWindowCommand {
  let run: (isolated MuxService) -> Void
  let reply: MuxService.Reply
}

/// One pane's window commands for a viewer: whether one is running, and
/// those waiting behind it.
struct WindowCommandQueue {
  var running = false
  var waiting: [WaitingWindowCommand] = []

  /// Removes and returns the waiting commands (to fail with
  /// `failWindowCommands`); the running one replies itself.
  mutating func takeWaiting() -> [WaitingWindowCommand] {
    defer { waiting = [] }
    return waiting
  }
}

/// Read-only attachment. It never holds the writer lease or a paste.
struct Viewer {
  let client: UUID
  let attachment = AttachmentID()
  let workspace: WorkspaceID
  var subscriptions: [PaneID] = []
  var frames: [PaneID: FrameSlot] = [:]
  var paneCursor = 0
  var viewports: [PaneID: ViewerViewport] = [:]
  var readiness = Readiness()
  /// Panes already told their history anchor is stale; one notice each
  /// until the viewer moves.
  var staleAnchorReported: Set<PaneID> = []
  /// Window commands per pane: present while one runs, holding those
  /// waiting behind it (`MuxService.inWindowOrder`).
  var windowCommands: [PaneID: WindowCommandQueue] = [:]
  /// Frame bytes this observer holds against the shared budget.
  var heldFrameBytes: Int {
    frames.values.reduce(0) {
      $0 + ($1.inflight?.bytes ?? 0) + ($1.queued?.frame.bytes ?? 0)
        + $1.reserved
    }
  }
}
